from __future__ import annotations

import re
import uuid
from pathlib import Path
from typing import Iterable


BEGIN_TASK_FILE_MARKER = "--- BEGIN TASK FILE ---"
END_TASK_FILE_MARKER = "--- END TASK FILE ---"
TASK_WRITER_RESULT_HEADER = "### Task Writer Result:"
RANKED_FINDINGS_HEADING = "## Ranked Findings"

_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")
_FINDING_TITLE_RE = re.compile(r"^### Finding:\s*(.*\S)\s*$")
_FILE_REF_RE = re.compile(
    r"`?"
    r"((?:src|tests|scripts|docs|frontend|alembic)/"
    r"[A-Za-z0-9_/.+-]+"
    r"\.(?:py|ts|tsx|js|jsx|md|sh|sql|yaml|yml|json|toml|cfg|ini|html|css))"
    r"(?::(\d+)(?:-(\d+))?)?"
    r"`?"
)
_EXTENSION_LANGUAGES: dict[str, str] = {
    ".py": "python", ".ts": "typescript", ".tsx": "typescript",
    ".js": "javascript", ".jsx": "javascript", ".sh": "bash",
    ".sql": "sql", ".md": "markdown", ".yaml": "yaml", ".yml": "yaml",
    ".json": "json", ".toml": "toml", ".html": "html", ".css": "css",
}


def parse_findings_manifest(manifest_path: Path) -> list[tuple[str, str, str, str]]:
    if not manifest_path.exists() or manifest_path.stat().st_size == 0:
        return []

    findings: list[tuple[str, str, str, str]] = []
    for raw_line in manifest_path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            continue
        parts = raw_line.split("\t", 3)
        if len(parts) != 4:
            continue
        rank, severity, category, title = (part.strip() for part in parts)
        if rank and severity and category and title:
            findings.append((rank, severity, category, title))
    return findings


def extract_task_file_content(agent_output: str) -> str | None:
    capture = False
    begin_seen = False
    end_seen = False
    nested_begin = False
    lines: list[str] = []

    for line in agent_output.splitlines():
        normalized = line.strip()
        if normalized == BEGIN_TASK_FILE_MARKER:
            if capture:
                nested_begin = True
                continue
            begin_seen = True
            capture = True
            continue
        if normalized == END_TASK_FILE_MARKER:
            if capture:
                end_seen = True
                capture = False
                break
            continue
        if capture:
            lines.append(line)

    if not begin_seen or not end_seen or nested_begin or not lines:
        return None
    return "\n".join(lines)


def parse_task_writer_result(agent_output: str) -> str | None:
    result_line = _task_writer_result_line(agent_output)
    if result_line is None:
        return None
    suffix = result_line[len(TASK_WRITER_RESULT_HEADER):].strip()
    if suffix.startswith("CREATED"):
        return "CREATED"
    if suffix.startswith("REJECTED"):
        return "REJECTED"
    return None


def extract_task_writer_rejection_reason(agent_output: str) -> str | None:
    result_line = _task_writer_result_line(agent_output)
    if result_line is None:
        return None
    suffix = result_line[len(TASK_WRITER_RESULT_HEADER):].strip()
    if not suffix.startswith("REJECTED"):
        return None
    reason = suffix[len("REJECTED"):].strip()
    if reason.startswith(("—", "-")):
        reason = reason[1:].strip()
    return reason or None


def slug_from_title(title: str) -> str:
    normalized = _NON_ALNUM_RE.sub("-", title.lower()).strip("-")
    normalized = re.sub(r"-{2,}", "-", normalized)
    normalized = normalized[:60].strip("-")
    return normalized


def resolve_target_path(base_dir: Path, run_date: str, slug: str) -> Path | None:
    candidate_dir = base_dir / f"nightshift-{run_date}-{slug}"
    if not candidate_dir.exists():
        return candidate_dir / "task.md"

    for suffix in range(2, 100):
        candidate_dir = base_dir / f"nightshift-{run_date}-{slug}-{suffix}"
        if not candidate_dir.exists():
            return candidate_dir / "task.md"
    return None


def write_task_file(target_path: Path, content: str) -> None:
    rendered = content.rstrip() + "\n"
    _atomic_write(target_path, rendered)


def write_task_manifest(manifest_path: Path, created_paths: Iterable[Path]) -> None:
    body = "".join(f"{path}\n" for path in created_paths)
    _atomic_write(manifest_path, body)


def extract_file_references(
    text: str, *, max_files: int = 4,
) -> list[tuple[str, int | None, int | None]]:
    """Extract (path, start_line, end_line) from finding text.

    Returns at most *max_files* unique paths in first-seen order.
    """
    seen: dict[str, tuple[int | None, int | None]] = {}
    for match in _FILE_REF_RE.finditer(text):
        path = match.group(1)
        if path in seen:
            continue
        start = int(match.group(2)) if match.group(2) else None
        end = int(match.group(3)) if match.group(3) else None
        seen[path] = (start, end)
        if len(seen) >= max_files:
            break
    return [(p, s, e) for p, (s, e) in seen.items()]


def read_source_context(
    file_refs: list[tuple[str, int | None, int | None]],
    *,
    repo_dir: Path,
    max_lines_per_file: int = 200,
    context_window: int = 50,
) -> str:
    """Read referenced files and return a formatted ``## Source Context`` block."""
    sections: list[str] = []
    for rel_path, start, end in file_refs:
        abs_path = repo_dir / rel_path
        if not abs_path.is_file():
            continue
        try:
            all_lines = abs_path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        if not all_lines:
            continue

        total = len(all_lines)
        if start is not None:
            range_start = max(0, start - 1 - context_window)
            range_end = min(total, (end or start) + context_window)
        else:
            range_start = 0
            range_end = total
        if range_end - range_start > max_lines_per_file:
            range_end = range_start + max_lines_per_file

        selected = all_lines[range_start:range_end]
        numbered = [f"{range_start + i + 1}: {line}" for i, line in enumerate(selected)]
        lang = _EXTENSION_LANGUAGES.get(Path(rel_path).suffix.lower(), "")
        header = f"### `{rel_path}` (lines {range_start + 1}-{range_end})"
        sections.append(f"{header}\n```{lang}\n" + "\n".join(numbered) + "\n```")

    if not sections:
        return ""
    return "## Source Context\n\n" + "\n\n".join(sections)


def build_finding_text(
    rank: str,
    severity: str,
    category: str,
    title: str,
    *,
    digest_path: Path,
    findings_dir: Path,
    repo_dir: Path | None = None,
    existing_open_tasks_context: str = "",
) -> str:
    digest_row = _manager_digest_table_row_by_rank(digest_path, rank)
    if digest_row is None:
        finding_context = (
            f"Rank: {rank}\n"
            f"Severity: {severity}\n"
            f"Category: {category}\n"
            f"Title: {title}\n"
        )
    else:
        finding_context = (
            f"Rank: {rank}\n"
            f"Severity: {severity}\n"
            f"Category: {category}\n"
            f"Title: {title}\n"
            f"Full table row: {digest_row}\n"
        )

    finding_block = _find_matching_block(findings_dir, title)
    result = f"{finding_context}{finding_block}" if finding_block else finding_context

    if repo_dir is not None:
        file_refs = extract_file_references(result)
        if file_refs:
            source_block = read_source_context(file_refs, repo_dir=repo_dir)
            if source_block:
                result = f"{result}\n\n{source_block}"

    if existing_open_tasks_context:
        result = f"{result}\n\n{existing_open_tasks_context}"

    return result


def _task_writer_result_line(agent_output: str) -> str | None:
    for line in agent_output.splitlines():
        normalized = line.strip()
        if normalized.startswith(TASK_WRITER_RESULT_HEADER):
            return normalized
    return None


def _atomic_write(target_path: Path, content: str) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = target_path.parent / f".{target_path.name}.{uuid.uuid4().hex}.tmp"
    try:
        tmp_path.write_text(content, encoding="utf-8")
        tmp_path.replace(target_path)
    finally:
        tmp_path.unlink(missing_ok=True)


def _manager_digest_table_row_by_rank(digest_path: Path, wanted_rank: str) -> str | None:
    if not digest_path.exists():
        return None

    in_table = False
    header_seen = False
    rank_col = -1
    for line in digest_path.read_text(encoding="utf-8").splitlines():
        if line == RANKED_FINDINGS_HEADING:
            in_table = True
            continue
        if in_table and line.startswith("## "):
            break
        if not in_table or not line.startswith("|") or line.startswith("|---") or line.startswith("| ---"):
            continue

        columns = [column.strip() for column in line.split("|")]
        if not header_seen:
            for index, column in enumerate(columns):
                if column.lower() == "#":
                    rank_col = index
                    break
            if rank_col >= 0:
                header_seen = True
            continue

        if rank_col >= len(columns):
            continue
        if columns[rank_col] == wanted_rank:
            return line
    return None


def _finding_blocks(findings_dir: Path) -> list[tuple[Path, str]]:
    blocks: list[tuple[Path, str]] = []
    for findings_path in sorted(findings_dir.glob("*-findings.md")):
        block_lines: list[str] = []
        capture = False
        for line in findings_path.read_text(encoding="utf-8").splitlines():
            if line.startswith("## Source:"):
                if capture and block_lines:
                    blocks.append((findings_path, "\n".join(block_lines)))
                    block_lines = []
                capture = False
                continue
            if line.startswith("### Finding:"):
                if capture and block_lines:
                    blocks.append((findings_path, "\n".join(block_lines)))
                block_lines = [line]
                capture = True
                continue
            if capture:
                block_lines.append(line)
        if capture and block_lines:
            blocks.append((findings_path, "\n".join(block_lines)))
    return blocks


def _finding_block_title(finding_block: str) -> str | None:
    for line in finding_block.splitlines():
        match = _FINDING_TITLE_RE.match(line)
        if match:
            return match.group(1)
    return None


def _casefold_match_text(text: str) -> str:
    return text.lower()


def _normalize_match_text(text: str) -> str:
    parts = [" ".join(line.lower().split()) for line in text.splitlines()]
    return " ".join(part for part in parts if part)


def _find_matching_block(findings_dir: Path, title: str) -> str | None:
    all_blocks = _finding_blocks(findings_dir)
    for match_mode in ("header", "nocase", "normalized"):
        matches: list[tuple[Path, str, str]] = []
        for findings_path, finding_block in all_blocks:
            block_title = _finding_block_title(finding_block)
            if not block_title:
                continue
            if match_mode == "header" and block_title != title:
                continue
            if match_mode == "nocase" and _casefold_match_text(block_title) != _casefold_match_text(title):
                continue
            if match_mode == "normalized" and _normalize_match_text(block_title) != _normalize_match_text(title):
                continue
            matches.append((findings_path, block_title, finding_block))

        if len(matches) == 1:
            return matches[0][2]
        if len(matches) <= 1:
            continue

        first_title = matches[0][1]
        title_keys = {
            "header": first_title,
            "nocase": _casefold_match_text(first_title),
            "normalized": _normalize_match_text(first_title),
        }
        expected_key = title_keys[match_mode]
        same_title = True
        seen_paths: set[Path] = set()
        unique_paths = True
        for findings_path, block_title, _finding_block in matches:
            current_key = {
                "header": block_title,
                "nocase": _casefold_match_text(block_title),
                "normalized": _normalize_match_text(block_title),
            }[match_mode]
            if current_key != expected_key:
                same_title = False
                break
            if findings_path in seen_paths:
                unique_paths = False
                break
            seen_paths.add(findings_path)
        if same_title and unique_paths:
            return "\n\n".join(block for _path, _title, block in matches)
    return None

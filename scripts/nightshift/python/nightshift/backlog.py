from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Iterable

from .subprocess_runner import run_subprocess


TaskRecord = tuple[Path, str, dict[str, str]]
_EXPLICIT_DEPENDENCY_RE = re.compile(r"(docs/tasks/(open|closed)/[^`\s]+(?:\.md|/task\.md))")
_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*")
_TASK_LIST_ROW_RE = re.compile(r"^(?P<rank>\d+)\|(?P<path>[^|]+)\|(?P<goal>[^|]+)\|(?P<complexity>[^|]+)$")


def scan_open_tasks(tasks_dir: Path) -> list[TaskRecord]:
    repo_root = tasks_dir.resolve().parents[2]
    records: list[TaskRecord] = []
    for task_path in sorted(tasks_dir.rglob("*.md")):
        if "competitive" in task_path.parts:
            continue
        metadata = {
            "rel_path": str(task_path.resolve().relative_to(repo_root)),
            "execution_mode": extract_field_value(task_path, "execution mode", "mode"),
            "depends_on": dependency_body(task_path),
        }
        status = normalize_status(extract_field_value(task_path, "status"))
        records.append((task_path.resolve(), status, metadata))
    return records


def resolve_dependencies(task_path: Path, open_tasks: Iterable[TaskRecord]) -> list[str]:
    return [issue["display"] for issue in _dependency_issues(task_path.resolve(), open_tasks)]


def is_pickable(
    task_path: Path,
    task_status: str,
    run_date: str,
    manager_task_paths: Iterable[Path],
    bridge_task_paths: Iterable[Path],
    open_tasks: Iterable[TaskRecord],
) -> tuple[bool, str | None]:
    task_path = task_path.resolve()
    rel_path = relative_task_path(task_path)

    if not task_path.exists():
        return False, f"Skipping {rel_path}: task file no longer exists"

    status = normalize_status(task_status)
    if status != "not started":
        return False, f"Skipping {rel_path}: status is '{status or 'unknown'}'"

    manager_task_set = {Path(path).resolve() for path in manager_task_paths}
    if task_path in manager_task_set:
        return False, f"Skipping {rel_path}: same-run manager task"

    bridge_task_set = {Path(path).resolve() for path in bridge_task_paths}
    if task_path in bridge_task_set or task_path_to_slug(task_path).startswith(f"nightshift-bridge-{run_date}-"):
        return False, f"Skipping {rel_path}: bridge runtime task"

    execution_mode = extract_field_value(task_path, "execution mode", "mode").lower()
    if re.search(r"(^|[^a-z0-9])(agent-team|team)([^a-z0-9]|$)", execution_mode):
        return False, f"Skipping {rel_path}: execution mode '{execution_mode}' requires team coordination"

    issues = _dependency_issues(task_path, open_tasks)
    if issues:
        return False, issues[0]["reason"]

    return True, None


def parse_task_list_block(lauren_output: str) -> list[tuple[int, str, str, str]]:
    rows: list[tuple[int, str, str, str]] = []
    for line in task_list_section(lauren_output).splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        match = _TASK_LIST_ROW_RE.match(stripped)
        if match is None:
            continue
        rows.append(
            (
                int(match.group("rank")),
                match.group("path").strip(),
                match.group("goal").strip(),
                match.group("complexity").strip(),
            )
        )
    return rows


def run_lauren_ranking(
    repo_root: Path,
    tasks_dir: Path,
    timeout: int,
    *,
    env: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    _ = tasks_dir
    return run_subprocess(
        ["bash", str(repo_root / "lauren-loop.sh"), "next"],
        cwd=repo_root,
        env=env,
        timeout_seconds=timeout,
        phase_name="Backlog Ranking",
    )


def build_backlog_digest_section(results: list[dict[str, object]]) -> str:
    lines = ["## Backlog Burndown"]
    if not results:
        lines.append("- (none)")
        return "\n".join(lines) + "\n"

    for entry in results:
        task_path = relative_task_path(Path(entry["task_path"])) if isinstance(entry.get("task_path"), Path) else str(entry.get("task_path", "unknown"))
        slug = str(entry.get("slug", "unknown"))
        outcome = str(entry.get("status", "unknown"))
        cost = str(entry.get("cost_usd", "0.0000"))
        lines.append(f"- `{task_path}` | slug `{slug}` | outcome `{outcome}` | cost `$%s`" % cost)
    return "\n".join(lines) + "\n"


def task_list_has_header(output: str) -> bool:
    return any(line.strip() == "## TASK_LIST" for line in output.splitlines())


def task_list_section(output: str) -> str:
    capture = False
    lines: list[str] = []
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "## TASK_LIST":
            capture = True
            continue
        if capture and stripped.startswith("## "):
            break
        if capture:
            lines.append(line)
    return "\n".join(lines)


def relative_task_path(task_path: Path | str) -> str:
    raw = str(task_path).strip()
    if not raw:
        return "docs/tasks/open/"
    if raw.startswith("/"):
        repo_root = _repo_root_from_task_path(Path(raw))
        if repo_root is not None and raw.startswith(f"{repo_root}/"):
            return raw[len(f"{repo_root}/") :]
        return raw
    if raw.startswith("docs/tasks/open/") or raw.startswith("docs/tasks/closed/"):
        return raw
    return f"docs/tasks/open/{raw.removeprefix('./')}"


def absolute_task_path(task_path: Path | str, repo_root: Path) -> Path:
    raw = str(task_path).strip()
    if raw.startswith("/"):
        return Path(raw).resolve()
    return (repo_root / relative_task_path(raw)).resolve()


def task_path_to_slug(task_path: Path | str) -> str:
    rel_path = relative_task_path(task_path)
    path_obj = Path(rel_path)
    if path_obj.name == "task.md":
        return path_obj.parent.name
    if path_obj.suffix == ".md":
        return path_obj.stem
    return path_obj.name


def extract_field_value(task_file: Path, *labels: str) -> str:
    wanted = {" ".join(label.strip().lower().split()) for label in labels}
    for raw_line in task_file.read_text(encoding="utf-8").splitlines():
        normalized = raw_line.replace("\r", "").replace("**", "").strip()
        normalized = re.sub(r"^[-*]\s*", "", normalized)
        normalized = re.sub(r"^##\s+", "", normalized)
        if ":" not in normalized:
            continue
        key, value = normalized.split(":", 1)
        key = " ".join(key.strip().lower().split())
        if key in wanted:
            return value.strip()
    return ""


def extract_section_body(task_file: Path, section_name: str) -> str:
    target = section_name.strip().lower()
    capture = False
    body: list[str] = []
    for raw_line in task_file.read_text(encoding="utf-8").splitlines():
        normalized = raw_line.replace("\r", "").replace("**", "").strip()
        lowered = normalized.lower()
        if capture and lowered.startswith("## "):
            break
        if lowered.startswith("## "):
            heading = lowered[3:].strip()
            heading = heading[:-1].strip() if heading.endswith(":") else heading
            if heading == target:
                capture = True
                continue
        if capture:
            body.append(raw_line)
    return "\n".join(body)


def normalize_status(status: str) -> str:
    compact = " ".join(status.lower().split())
    return compact.strip()


def status_is_terminal(status: str) -> bool:
    normalized = normalize_status(status)
    if not normalized or "needs verification" in normalized:
        return False
    return re.match(r"^(done|complete|completed|verified)([\s\W]|$)", normalized) is not None


def dependency_body(task_file: Path) -> str:
    body = "\n".join(
        line for line in extract_section_body(task_file, "depends on").splitlines() if line.strip()
    )
    if body:
        return body
    return extract_field_value(task_file, "depends on")


def dependency_tokens(dep_body: str) -> list[str]:
    tokens: list[str] = []
    seen: set[str] = set()
    for chunk in re.split(r"[\n,;]", dep_body.replace("**", "").replace("`", "")):
        line = re.sub(r"^\s*[-*]\s*", "", chunk).strip()
        if not line:
            continue
        lowered = line.lower()
        if lowered == "none" or lowered.startswith("unblocked"):
            continue

        explicit = _EXPLICIT_DEPENDENCY_RE.search(line)
        if explicit is not None:
            token = explicit.group(1)
        else:
            token_match = _TOKEN_RE.match(line)
            if token_match is None:
                continue
            token = token_match.group(0)
            if token.lower() in {"none", "unblocked", "task", "phase"}:
                continue

        if token not in seen:
            seen.add(token)
            tokens.append(token)
    return tokens


def _dependency_issues(task_path: Path, open_tasks: Iterable[TaskRecord]) -> list[dict[str, str]]:
    rel_path = relative_task_path(task_path)
    dep_body = dependency_body(task_path)
    if not dep_body:
        return []

    issues: list[dict[str, str]] = []
    for dep_token in dependency_tokens(dep_body):
        resolved_dep_path = _resolve_dependency_match(task_path, dep_token, open_tasks)
        if resolved_dep_path is None:
            if dep_token.startswith("/") or dep_token.startswith("docs/tasks/open/") or dep_token.startswith("docs/tasks/closed/"):
                issues.append({
                    "kind": "missing",
                    "display": dep_token,
                    "reason": f"Skipping {rel_path}: explicit dependency path '{dep_token}' is missing or does not exist",
                })
            continue

        if resolved_dep_path == task_path.resolve():
            issues.append({
                "kind": "self",
                "display": relative_task_path(resolved_dep_path),
                "reason": f"Skipping {rel_path}: task lists itself as a dependency and is malformed",
            })
            continue

        resolved_status = normalize_status(extract_field_value(resolved_dep_path, "status"))
        if not status_is_terminal(resolved_status):
            dep_rel_path = relative_task_path(resolved_dep_path)
            issues.append({
                "kind": "status",
                "display": dep_rel_path,
                "reason": f"Skipping {rel_path}: dependency at {dep_rel_path} is still '{resolved_status or 'unknown'}'",
            })
    return issues


def _resolve_dependency_match(
    task_path: Path,
    token: str,
    open_tasks: Iterable[TaskRecord],
) -> Path | None:
    repo_root = _repo_root_from_task_path(task_path)
    if repo_root is None:
        return None

    if token.startswith(f"{repo_root}/"):
        candidate = Path(token)
        return candidate.resolve() if candidate.is_file() else None

    if token.startswith("docs/tasks/open/") or token.startswith("docs/tasks/closed/"):
        candidate = (repo_root / token).resolve()
        return candidate if candidate.is_file() else None

    normalized_token = token.lower()
    matches: list[Path] = []
    for candidate_path, _status, metadata in open_tasks:
        rel_path = metadata.get("rel_path", "").lower()
        stem = candidate_path.stem.lower()
        dir_name = candidate_path.parent.name.lower()
        if rel_path == normalized_token or stem == normalized_token:
            matches.append(candidate_path.resolve())
            continue
        if candidate_path.name == "task.md" and dir_name == normalized_token:
            matches.append(candidate_path.resolve())
    if len(matches) == 1:
        return matches[0]
    return None


def _repo_root_from_task_path(task_path: Path) -> str | None:
    resolved = task_path.resolve()
    for parent in resolved.parents:
        if parent.name == "docs" and parent.parent != parent:
            return str(parent.parent)
    return None

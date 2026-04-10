from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable, Sequence

from .detective_status import DetectiveStatus, DetectiveStatusStore


# --- Fallback digest headings (used by write_fallback_digest) ---

RUN_METADATA_HEADING = "## Run Metadata"
SUMMARY_HEADING = "## Summary"
DETECTIVE_STATUS_HEADING = "## Detective Statuses"
WARNINGS_HEADING = "## Warnings"
FAILURES_HEADING = "## Failures"
RAW_FINDINGS_HEADING = "## Raw Detective Findings"

# --- Manager contract headings ---

RANKED_FINDINGS_HEADING = "## Ranked Findings"
MINOR_FINDINGS_HEADING = "## Minor & Observation Findings"
MANAGER_REQUIRED_BODY_HEADINGS = (RANKED_FINDINGS_HEADING, MINOR_FINDINGS_HEADING)

DETECTIVE_COVERAGE_HEADING = "## Detective Coverage"
DETECTIVES_SKIPPED_HEADING = "## Detectives Skipped"
ORCHESTRATOR_SUMMARY_HEADING = "## Orchestrator Summary"
ORCHESTRATOR_WARNINGS_HEADING = "## Orchestrator Warnings"
ORCHESTRATOR_FAILURES_HEADING = "## Orchestrator Failures"

SHELL_OWNED_HEADINGS = frozenset({
    RUN_METADATA_HEADING, SUMMARY_HEADING,
    DETECTIVE_COVERAGE_HEADING, "## Detectives Not Run", DETECTIVES_SKIPPED_HEADING,
    ORCHESTRATOR_SUMMARY_HEADING, ORCHESTRATOR_WARNINGS_HEADING, ORCHESTRATOR_FAILURES_HEADING,
})


FINDING_HEADING_RE = re.compile(r"^### Finding(?::|\s+\d+:)")
_NUMBERED_FINDING_RE = re.compile(r"^### Finding \d+:", re.MULTILINE)


def count_findings_in_file(path: Path) -> int:
    return sum(1 for line in path.read_text(encoding="utf-8").splitlines() if FINDING_HEADING_RE.match(line))


def count_total_findings(findings_dir: Path) -> int:
    total = 0
    for path in sorted(findings_dir.glob("*-findings.md")):
        total += count_findings_in_file(path)
    return total


def normalize_findings_text(text: str) -> str:
    return _NUMBERED_FINDING_RE.sub("### Finding:", text)


def rebuild_manager_input_file(
    findings_dir: Path,
    raw_findings_dir: Path,
    playbook_name: str,
    run_date: str,
    detective_status_store: DetectiveStatusStore,
) -> Path:
    raw_matches = sorted(raw_findings_dir.glob(f"*-{playbook_name}-findings.md"))
    status_obj = detective_status_store.read_all()
    playbook_status = "skipped"
    for s in status_obj:
        if s.playbook == playbook_name and s.status in {"success", "no_findings"}:
            playbook_status = "ran"
            break
    if raw_matches and playbook_status != "ran":
        playbook_status = "ran"
    findings_count = 0
    for raw_path in raw_matches:
        findings_count += count_findings_in_file(raw_path)
    if findings_count > 0 and playbook_status != "ran":
        playbook_status = "ran"
    canonical_path = findings_dir / f"{playbook_name}-findings.md"
    canonical_path.unlink(missing_ok=True)
    lines = [
        f"# Normalized {playbook_name} Findings — {run_date}",
        "",
        f"## Detective: {playbook_name} | status={playbook_status} | findings={findings_count}",
        "",
    ]
    if not raw_matches:
        lines.append("_Detective skipped._" if playbook_status != "ran" else "_No findings reported._")
    else:
        for raw_path in raw_matches:
            source_name = raw_path.name
            for suffix in (f"-{playbook_name}-findings.md", f"-{playbook_name}-partial.md"):
                if source_name.endswith(suffix):
                    source_name = source_name[: -len(suffix)]
                    break
            lines.append(f"## Source: {source_name}")
            lines.append("")
            lines.append(normalize_findings_text(raw_path.read_text(encoding="utf-8").rstrip()))
            lines.append("")
            lines.append("")
    canonical_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return canonical_path


def rebuild_manager_inputs(
    findings_dir: Path,
    raw_findings_dir: Path,
    detective_playbooks: Sequence[str],
    run_date: str,
    detective_status_store: DetectiveStatusStore,
) -> None:
    for stale in findings_dir.glob("*"):
        if stale.is_file():
            stale.unlink()
    for playbook_name in detective_playbooks:
        rebuild_manager_input_file(findings_dir, raw_findings_dir, playbook_name, run_date, detective_status_store)


def validate_digest_headings(digest_path: Path, required_headings: Sequence[str] = MANAGER_REQUIRED_BODY_HEADINGS) -> list[str]:
    if not digest_path.exists():
        return list(required_headings)
    lines = set(digest_path.read_text(encoding="utf-8").splitlines())
    return [h for h in required_headings if h not in lines]


def manager_top_findings_from_digest(digest_path: Path) -> list[tuple[str, str, str, str]]:
    if not digest_path.exists():
        return []
    text = digest_path.read_text(encoding="utf-8")
    in_table = False
    header_seen = False
    rank_col = sev_col = cat_col = title_col = -1
    results: list[tuple[str, str, str, str]] = []
    for line in text.splitlines():
        if line.strip() == RANKED_FINDINGS_HEADING:
            in_table = True
            continue
        if in_table and line.startswith("## "):
            break
        if not in_table:
            continue
        if line.startswith("|---") or line.startswith("| ---"):
            continue
        if not line.startswith("|"):
            continue
        cols = [c.strip() for c in line.split("|")]
        if not header_seen:
            for i, c in enumerate(cols):
                lc = c.lower()
                if lc == "#":
                    rank_col = i
                elif lc == "severity":
                    sev_col = i
                elif lc == "category":
                    cat_col = i
                elif lc == "title":
                    title_col = i
            if rank_col >= 0 and sev_col >= 0 and cat_col >= 0 and title_col >= 0:
                header_seen = True
            continue
        if max(rank_col, sev_col, cat_col, title_col) >= len(cols):
            continue
        rank, sev, cat, title = cols[rank_col], cols[sev_col], cols[cat_col], cols[title_col]
        if rank and sev and cat and title:
            results.append((rank, sev, cat, title))
    return results


def write_findings_manifest(manifest_path: Path, digest_path: Path) -> bool:
    findings = manager_top_findings_from_digest(digest_path)
    tmp_path = manifest_path.parent / f"{manifest_path.name}.tmp"
    try:
        tmp_path.write_text(
            "\n".join(f"{r}\t{s}\t{c}\t{t}" for r, s, c, t in findings) + ("\n" if findings else ""),
            encoding="utf-8",
        )
        tmp_path.rename(manifest_path)
        return True
    except OSError:
        tmp_path.unlink(missing_ok=True)
        return False


def _strip_shell_owned_sections(text: str) -> str:
    lines = text.splitlines()
    out: list[str] = []
    skip = False
    for i, line in enumerate(lines):
        if i == 0 and line.startswith("# "):
            continue
        if line.startswith("## "):
            skip = line in SHELL_OWNED_HEADINGS
        if not skip:
            out.append(line)
    return "\n".join(out)


def rewrite_manager_digest(
    digest_path: Path,
    *,
    run_date: str,
    run_id: str,
    total_findings: int,
    task_file_count: int,
    detective_playbooks: Sequence[str],
    detective_status_store: DetectiveStatusStore,
    findings_dir: Path,
) -> None:
    if not digest_path.exists():
        return
    body = _strip_shell_owned_sections(digest_path.read_text(encoding="utf-8"))
    ranked = _count_table_rows(digest_path, RANKED_FINDINGS_HEADING)
    minor = _count_table_rows(digest_path, MINOR_FINDINGS_HEADING)
    after_dedup = ranked + minor
    dupes = max(0, total_findings - after_dedup)
    ran_names = []
    for pb in detective_playbooks:
        for s in detective_status_store.read_all():
            if s.playbook == pb and s.status in {"success", "no_findings"}:
                ran_names.append(pb)
                break
    header_lines = [
        f"# Nightshift Detective Digest — {run_date}",
        "",
        RUN_METADATA_HEADING,
        f"- **Run ID:** {run_id}",
        f"- **Date:** {run_date}",
        f"- **Detectives Run:** {', '.join(ran_names) if ran_names else 'none'}",
        "",
        SUMMARY_HEADING,
        f"- **Total findings received:** {total_findings}",
        f"- **After deduplication:** {after_dedup}",
        f"- **Duplicates merged:** {dupes}",
        f"- **Task files created:** {task_file_count}",
        f"- **Minor/observation findings:** {minor} (see digest below)",
        "",
    ]
    coverage = _render_detective_coverage(detective_playbooks, detective_status_store, findings_dir)
    skipped = _render_skipped_detectives(detective_playbooks, detective_status_store)
    full = "\n".join(header_lines) + "\n" + body.strip() + "\n\n" + coverage + "\n" + skipped
    digest_path.write_text(full.rstrip() + "\n", encoding="utf-8")


def _count_table_rows(digest_path: Path, heading: str) -> int:
    if not digest_path.exists():
        return 0
    in_section = False
    header_seen = False
    count = 0
    for line in digest_path.read_text(encoding="utf-8").splitlines():
        if line.strip() == heading:
            in_section = True
            continue
        if in_section and line.startswith("## "):
            break
        if not in_section:
            continue
        if line.startswith("|---") or line.startswith("| ---"):
            continue
        if line.startswith("|"):
            if not header_seen:
                header_seen = True
                continue
            count += 1
    return count


def _render_detective_coverage(playbooks: Sequence[str], store: DetectiveStatusStore, findings_dir: Path) -> str:
    lines = [
        DETECTIVE_COVERAGE_HEADING,
        "",
        "| Detective | Status | Findings Received |",
        "|----------|--------|------------------:|",
    ]
    total_findings = 0
    ran = 0
    skipped = 0
    for pb in playbooks:
        statuses = [s for s in store.read_all() if s.playbook == pb]
        pb_status = "ran" if any(s.status in {"success", "no_findings"} for s in statuses) else "skipped"
        canonical = findings_dir / f"{pb}-findings.md"
        fc = count_findings_in_file(canonical) if canonical.exists() else 0
        total_findings += fc
        if pb_status == "ran":
            ran += 1
        else:
            skipped += 1
        lines.append(f"| {pb} | {pb_status} | {fc} |")
    lines.append(f"| **Total** | **{ran} ran / {skipped} skipped** | **{total_findings}** |")
    return "\n".join(lines)


def _render_skipped_detectives(playbooks: Sequence[str], store: DetectiveStatusStore) -> str:
    lines = [DETECTIVES_SKIPPED_HEADING, ""]
    skipped = []
    for pb in playbooks:
        statuses = [s for s in store.read_all() if s.playbook == pb]
        if not any(s.status in {"success", "no_findings"} for s in statuses):
            skipped.append(pb)
    if skipped:
        for name in skipped:
            lines.append(f"- {name}")
    else:
        lines.append("- (none)")
    return "\n".join(lines)


def append_orchestrator_summary(
    digest_path: Path,
    *,
    run_id: str,
    branch: str,
    phase_reached: str,
    total_findings: int,
    task_file_count: int,
    total_cost: str,
    warnings: Iterable[str],
    failures: Iterable[str],
) -> None:
    warning_list = list(warnings)
    failure_list = list(failures)
    lines = [
        "",
        ORCHESTRATOR_SUMMARY_HEADING,
        f"- **Run ID:** {run_id}",
        f"- **Branch:** {branch}",
        f"- **Phase Reached:** {phase_reached}",
        f"- **Total findings received:** {total_findings}",
        f"- **Task files created:** {task_file_count}",
        f"- **Total cost:** ${total_cost}",
        "",
        ORCHESTRATOR_WARNINGS_HEADING,
    ]
    lines.extend(f"- {w}" for w in warning_list) if warning_list else lines.append("- (none)")
    lines.append("")
    lines.append(ORCHESTRATOR_FAILURES_HEADING)
    lines.extend(f"- {f}" for f in failure_list) if failure_list else lines.append("- (none)")
    existing = digest_path.read_text(encoding="utf-8") if digest_path.exists() else ""
    digest_path.write_text(existing.rstrip() + "\n" + "\n".join(lines) + "\n", encoding="utf-8")


def render_notes_markdown(notes: Iterable[str]) -> str:
    rendered = [f"- {note}" for note in notes if note]
    return "\n".join(rendered) if rendered else "- (none)"


def render_detective_statuses_markdown(statuses: Iterable[DetectiveStatus]) -> str:
    rendered = [
        (
            f"- `{status.engine}/{status.playbook}`: `{status.status}` "
            f"(findings={status.findings_count}, duration={status.duration_seconds}s, cost=${status.cost_usd})"
        )
        for status in statuses
    ]
    return "\n".join(rendered) if rendered else "- (none)"


def write_fallback_digest(
    path: Path,
    *,
    run_date: str,
    run_id: str,
    mode_label: str,
    outcome_label: str,
    phase_reached: str,
    branch: str,
    total_findings: int,
    task_file_count: int,
    total_cost: str,
    warning_notes: Iterable[str],
    failure_notes: Iterable[str],
    detective_statuses: Iterable[DetectiveStatus] = (),
    raw_findings_paths: Iterable[Path] = (),
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    lines = [
        f"# Nightshift Detective Digest — {run_date}",
        "",
        RUN_METADATA_HEADING,
        f"- **Run ID:** {run_id}",
        f"- **Mode:** {mode_label}",
        f"- **Outcome:** {outcome_label}",
        f"- **Phase Reached:** {phase_reached}",
        f"- **Branch:** {branch}",
        "",
        SUMMARY_HEADING,
        f"- **Total findings received:** {total_findings}",
        f"- **Task files created:** {task_file_count}",
        f"- **Total cost:** ${total_cost}",
        "",
        DETECTIVE_STATUS_HEADING,
        render_detective_statuses_markdown(detective_statuses),
        "",
        WARNINGS_HEADING,
        render_notes_markdown(warning_notes),
        "",
        FAILURES_HEADING,
        render_notes_markdown(failure_notes),
    ]

    findings_list = [path for path in raw_findings_paths if path.exists()]
    if findings_list:
        lines.extend(["", RAW_FINDINGS_HEADING, ""])
        for findings_path in findings_list:
            lines.append(f"### {findings_path.name}")
            lines.append("")
            lines.append(findings_path.read_text(encoding="utf-8").rstrip())
            lines.append("")

    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

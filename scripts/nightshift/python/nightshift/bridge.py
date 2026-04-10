from __future__ import annotations

import re
import uuid
from pathlib import Path
from typing import Iterable, Sequence

from . import task_writer


BRIDGE_RUNTIME_SECTIONS = (
    "## Current Plan",
    "## Critique",
    "## Plan History",
    "## Execution Log",
)
_MANAGER_TASK_RE = re.compile(r"^nightshift-\d{4}-\d{2}-\d{2}-(?P<slug>.+)$")
_COLLISION_SUFFIX_RE = re.compile(r"^(?P<slug>.+)-(?P<suffix>\d+)$")


def findings_without_tasks(
    manifest_findings: Sequence[tuple[str, str, str, str]],
    task_manifest_paths: Iterable[Path | str],
) -> list[tuple[str, str, str, str]]:
    covered_slugs: set[str] = set()
    for task_path in task_manifest_paths:
        covered_slugs.update(_manager_slugs_from_task_path(Path(task_path)))

    uncovered: list[tuple[str, str, str, str]] = []
    for finding in manifest_findings:
        finding_slug = task_writer.slug_from_title(finding[3]) or f"finding-{finding[0]}"
        if finding_slug not in covered_slugs:
            uncovered.append(finding)
    return uncovered


def synthesize_bridge_task(
    base_dir: Path,
    run_date: str,
    finding: tuple[str, str, str, str],
) -> Path:
    rank, severity, category, title = finding
    slug = task_writer.slug_from_title(title) or f"finding-{rank}"
    task_dir = base_dir / f"nightshift-bridge-{run_date}-{slug}"
    task_path = task_dir / "task.md"

    if not task_path.exists():
        content = _render_bridge_task(
            run_date=run_date,
            rank=rank,
            severity=severity,
            category=category,
            title=title,
        )
        _atomic_write(task_path, content)
    else:
        rendered = _ensure_runtime_sections(task_path.read_text(encoding="utf-8"))
        _atomic_write(task_path, rendered.rstrip() + "\n")

    return task_path


def build_bridge_digest_section(results: Sequence[dict[str, object]]) -> str:
    if not results:
        return "## Bridge\n- (none)\n"

    lines = [
        "## Bridge",
        "| Finding | Task | Outcome | Cost |",
        "| --- | --- | --- | --- |",
    ]
    for entry in results:
        title = str(entry.get("title", "unknown"))
        task_path = entry.get("task_path")
        outcome = str(entry.get("status", "unknown"))
        cost = str(entry.get("cost_usd", "0.0000"))
        lines.append(
            f"| {title} | `{_display_path(task_path)}` | `{outcome}` | `${cost}` |"
        )
    return "\n".join(lines) + "\n"


def _render_bridge_task(
    *,
    run_date: str,
    rank: str,
    severity: str,
    category: str,
    title: str,
) -> str:
    body = "\n".join(
        [
            f"## Task: {title}",
            "## Status: not started",
            f"## Created: {run_date}",
            "## Execution Mode: single-agent",
            "",
            "## Motivation",
            "Night Shift bridge created this runtime task because a ranked finding did not already",
            "have a manager-authored task file in the current Python run.",
            "",
            "## Goal",
            f'Resolve the Night Shift finding titled "{title}" and leave clear verification evidence.',
            "",
            "## Scope",
            "### In Scope",
            "- Investigate and fix the ranked Night Shift finding",
            "- Keep changes scoped to the finding and its direct cause",
            "",
            "### Out of Scope",
            "- Unrelated refactors outside the finding's scope",
            "",
            "## Relevant Files",
            f"- `docs/nightshift/digests/{run_date}.md` — ranked finding source for this runtime bridge task",
            "",
            "## Context",
            f"- Rank: {rank}",
            f"- Severity: {severity}",
            f"- Category: {category}",
            "- Source: Night Shift Python bridge runtime task",
            "",
            "## Anti-Patterns",
            "- Do NOT broaden the task beyond the ranked finding",
            "- Do NOT remove the verification evidence needed to prove the fix",
            "",
            "## Done Criteria",
            f'- [ ] The finding titled "{title}" is resolved with verification evidence',
            "- [ ] Relevant tests or validation steps pass",
            "",
            "## Code Review: not started",
            "",
            "## Left Off At",
            "Created by Night Shift Python bridge for Lauren Loop follow-up.",
            "",
            "## Attempts",
            "(none)",
            "",
        ]
    )
    return _ensure_runtime_sections(body).rstrip() + "\n"


def _ensure_runtime_sections(content: str) -> str:
    rendered = content.rstrip()
    for section in BRIDGE_RUNTIME_SECTIONS:
        if section not in rendered.splitlines():
            rendered = f"{rendered}\n\n{section}"
    return rendered


def _manager_slugs_from_task_path(task_path: Path) -> tuple[str, ...]:
    task_name = task_path.parent.name if task_path.name == "task.md" else task_path.stem
    match = _MANAGER_TASK_RE.match(task_name)
    if match is None:
        return ()

    slug = match.group("slug")
    slugs = {slug}
    collision_match = _COLLISION_SUFFIX_RE.match(slug)
    if collision_match is not None:
        slugs.add(collision_match.group("slug"))
    return tuple(slugs)


def _display_path(task_path: object) -> str:
    if isinstance(task_path, Path):
        return str(task_path)
    return str(task_path or "unknown")


def _atomic_write(target_path: Path, content: str) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = target_path.parent / f".{target_path.name}.{uuid.uuid4().hex}.tmp"
    try:
        tmp_path.write_text(content, encoding="utf-8")
        tmp_path.replace(target_path)
    finally:
        tmp_path.unlink(missing_ok=True)

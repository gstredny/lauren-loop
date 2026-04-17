from __future__ import annotations

import re
from pathlib import Path

from .backlog import extract_field_value, normalize_status, relative_task_path, status_is_terminal

MAX_EXISTING_OPEN_TASKS = 50
MAX_TITLE_LENGTH = 120
TASK_METADATA_RE = re.compile(r"^(#|##)\s+Task\s*:", re.MULTILINE)
DONE_SECTION_RE = re.compile(r"^##\s+(Done Criteria|Done)\s*:?[ \t]*$", re.MULTILINE)
ATTEMPTS_SECTION_RE = re.compile(r"^##\s+Attempts\s*:?[ \t]*$", re.MULTILINE)


def normalize_title(title: str) -> str:
    compact = " ".join(title.strip().split())
    if compact.lower().startswith("task:"):
        compact = compact[5:].strip()
    return compact


def truncate_title(title: str) -> str:
    if len(title) <= MAX_TITLE_LENGTH:
        return title
    return f"{title[: MAX_TITLE_LENGTH - 3]}..."


def first_heading_title(task_file: Path) -> str:
    excluded_prefixes = (
        "task",
        "status",
        "created",
        "execution mode",
        "code review",
        "left off at",
        "attempts",
        "motivation",
        "goal",
        "scope",
        "context",
        "relevant files",
        "anti-patterns",
        "done criteria",
        "team structure",
        "file ownership map",
        "current plan",
        "problem",
        "background",
        "verify commands",
        "priority",
        "depends on",
        "complexity",
    )
    for raw_line in task_file.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if stripped.startswith("# "):
            title = normalize_title(stripped[2:])
        elif stripped.startswith("## "):
            title = normalize_title(stripped[3:])
        else:
            continue
        lowered = title.lower()
        if any(lowered == prefix or lowered.startswith(f"{prefix}:") for prefix in excluded_prefixes):
            continue
        return title
    return ""


def status_is_excluded(status: str) -> bool:
    normalized = normalize_status(status)
    return status_is_terminal(status) or normalized.startswith(("reverted", "superseded", "closed"))


def has_shape_signal(task_file: Path) -> bool:
    if task_file.name == "task.md":
        return True

    text = task_file.read_text(encoding="utf-8")
    return bool(
        TASK_METADATA_RE.search(text)
        or DONE_SECTION_RE.search(text)
        or ATTEMPTS_SECTION_RE.search(text)
    )


def collect_existing_open_tasks(tasks_dir: Path) -> list[tuple[str, str, str]]:
    if not tasks_dir.is_dir():
        return []

    rows: list[tuple[str, str, str]] = []
    for task_path in sorted(tasks_dir.rglob("*.md")):
        status = normalize_status(extract_field_value(task_path, "status"))
        if not status or status_is_excluded(status):
            continue
        if not has_shape_signal(task_path):
            continue

        title = normalize_title(extract_field_value(task_path, "task"))
        if not title:
            title = first_heading_title(task_path)
        if not title and task_path.name == "task.md":
            title = normalize_title(task_path.parent.name)
        if not title:
            continue

        rows.append((relative_task_path(task_path), truncate_title(normalize_title(title)), status))

    rows.sort(key=lambda row: row[0])
    return rows


def build_existing_open_tasks_context(tasks_dir: Path) -> str:
    rows = collect_existing_open_tasks(tasks_dir)
    lines = ["## Existing Open Tasks", ""]
    if not rows:
        lines.append("(none)")
        return "\n".join(lines)

    overflow_count = max(len(rows) - MAX_EXISTING_OPEN_TASKS, 0)
    kept_rows = rows[:MAX_EXISTING_OPEN_TASKS]
    lines.extend(f"{path}: {title} [{status}]" for path, title, status in kept_rows)
    if overflow_count:
        lines.append(f"(... and {overflow_count} more)")
    return "\n".join(lines)

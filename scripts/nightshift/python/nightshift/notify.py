from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from urllib import request

from .cost import CostTracker
from .digest import MINOR_FINDINGS_HEADING, RANKED_FINDINGS_HEADING, manager_top_findings_from_digest
from .runtime import RunContext


def build_summary(
    context: RunContext,
    cost_tracker: CostTracker,
    *,
    now: datetime | None = None,
) -> str:
    severity = _severity_counts(context.digest_path)
    top_findings = _top_findings(context.digest_path)
    duration_seconds = max(0, int(((now or datetime.now()) - context.started_at).total_seconds()))

    lines = [
        "Nightshift Detective Summary",
        f"Run date: {context.run_date}",
        f"Findings: {context.total_findings_available} findings",
        (
            "Severity: "
            f"critical={severity['critical']} "
            f"high={severity['high']} "
            f"medium={severity['medium']} "
            f"low={severity['low']}"
        ),
        f"Task files: {context.task_file_count}",
        f"Cost: ${cost_tracker.total_value()}",
        f"Duration: {_format_duration(duration_seconds)}",
        f"PR: {context.pr_url or 'none'}",
    ]

    if top_findings:
        lines.extend(["", "Top findings:"])
        lines.extend(f"- {title[:80]}" for title in top_findings)

    if context.warnings:
        lines.extend(["", "Warnings:"])
        lines.extend(f"- {warning}" for warning in context.warnings if warning)

    if context.failures:
        lines.extend(["", "Failures:"])
        lines.extend(f"- {failure}" for failure in context.failures if failure)

    return "\n".join(lines)


def send_webhook(url: str, summary: str, run_date: str, timeout: int = 10) -> bool:
    if not url:
        return False

    payload = json.dumps({"text": summary, "run_date": run_date}).encode("utf-8")
    webhook_request = request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with request.urlopen(webhook_request, timeout=timeout) as response:
            status = getattr(response, "status", None)
            return status is None or 200 <= int(status) < 300
    except Exception:
        return False


def _format_duration(seconds: int) -> str:
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    seconds = seconds % 60
    if hours > 0:
        return f"{hours}h {minutes}m {seconds}s"
    return f"{minutes}m {seconds}s"


def _top_findings(digest_path: Path | None) -> list[str]:
    if digest_path is None or not digest_path.exists():
        return []
    return [title for _rank, _severity, _category, title in manager_top_findings_from_digest(digest_path)[:3]]


def _severity_counts(digest_path: Path | None) -> dict[str, int]:
    counts = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    if digest_path is None or not digest_path.exists():
        return counts

    for severity in _table_column_values(digest_path, RANKED_FINDINGS_HEADING, "severity"):
        _increment_severity(counts, severity)
    for severity in _table_column_values(digest_path, MINOR_FINDINGS_HEADING, "severity"):
        _increment_severity(counts, severity)
    return counts


def _table_column_values(digest_path: Path, heading: str, column_name: str) -> list[str]:
    in_section = False
    header_map: dict[str, int] = {}
    values: list[str] = []

    for raw_line in digest_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line == heading:
            in_section = True
            header_map = {}
            continue
        if in_section and line.startswith("## "):
            break
        if not in_section or not line.startswith("|") or line.startswith("|---") or line.startswith("| ---"):
            continue

        columns = [column.strip() for column in raw_line.split("|")]
        if not header_map:
            for index, value in enumerate(columns):
                normalized = value.lower()
                if normalized:
                    header_map[normalized] = index
            continue

        column_index = header_map.get(column_name.lower())
        if column_index is None or column_index >= len(columns):
            continue
        value = columns[column_index].strip()
        if value:
            values.append(value)

    return values


def _increment_severity(counts: dict[str, int], severity: str) -> None:
    normalized = severity.strip().lower()
    if normalized == "critical":
        counts["critical"] += 1
    elif normalized in {"high", "major"}:
        counts["high"] += 1
    elif normalized in {"medium", "minor"}:
        counts["medium"] += 1
    elif normalized in {"low", "observation"}:
        counts["low"] += 1

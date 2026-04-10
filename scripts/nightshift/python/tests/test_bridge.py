from __future__ import annotations

from pathlib import Path

import nightshift.bridge as bridge_helpers


def test_findings_without_tasks() -> None:
    findings = [
        ("1", "critical", "regression", "Auth regression"),
        ("2", "major", "coverage", "Coverage drift"),
        ("3", "major", "retry", "Retry bug"),
    ]
    task_manifest_paths = [
        Path("/repo/docs/tasks/open/nightshift-2026-04-09-auth-regression/task.md"),
    ]

    uncovered = bridge_helpers.findings_without_tasks(findings, task_manifest_paths)

    assert uncovered == [
        ("2", "major", "coverage", "Coverage drift"),
        ("3", "major", "retry", "Retry bug"),
    ]


def test_synthesize_bridge_task(tmp_path: Path) -> None:
    finding = ("2", "major", "coverage", "Coverage drift")

    task_path = bridge_helpers.synthesize_bridge_task(tmp_path, "2026-04-09", finding)

    assert task_path == tmp_path / "nightshift-bridge-2026-04-09-coverage-drift" / "task.md"
    content = task_path.read_text(encoding="utf-8")
    assert "## Task: Coverage drift" in content
    assert "## Status: not started" in content
    assert "Severity: major" in content
    assert "Category: coverage" in content
    assert "## Current Plan" in content
    assert "## Critique" in content
    assert "## Plan History" in content
    assert "## Execution Log" in content


def test_build_bridge_digest_section() -> None:
    section = bridge_helpers.build_bridge_digest_section(
        [
            {
                "title": "Auth regression",
                "task_path": Path("/repo/docs/tasks/open/nightshift-bridge-2026-04-09-auth-regression/task.md"),
                "status": "applied",
                "cost_usd": "1.2500",
            }
        ]
    )

    assert section.startswith("## Bridge\n")
    assert "| Finding | Task | Outcome | Cost |" in section
    assert "Auth regression" in section
    assert "`applied`" in section
    assert "$1.2500" in section

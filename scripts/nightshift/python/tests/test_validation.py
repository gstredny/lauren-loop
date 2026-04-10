from __future__ import annotations

from pathlib import Path

from nightshift.validation import (
    extract_validation_failed_checks,
    mutate_task_failed,
    mutate_task_validated,
    parse_validation_result,
)


def test_parse_validation_result_validated() -> None:
    assert parse_validation_result("### Validation Result: VALIDATED") == "VALIDATED"


def test_parse_validation_result_invalid() -> None:
    assert parse_validation_result("### Validation Result: INVALID") == "INVALID"


def test_parse_validation_result_uses_final_block() -> None:
    output = (
        "### Validation Result: VALIDATED\n"
        "Failed checks:\n"
        "- (none)\n"
        "### Validation Result: INVALID\n"
        "Failed checks:\n"
        "- INVALID:path — missing.py not found\n"
    )

    assert parse_validation_result(output) == "INVALID"
    assert extract_validation_failed_checks(output) == ["- INVALID:path — missing.py not found"]


def test_mutate_task_validated(tmp_path: Path) -> None:
    task_path = tmp_path / "task.md"
    task_path.write_text("## Task: Example\n## Goal\nShip it\n", encoding="utf-8")

    mutate_task_validated(task_path, run_date="2026-04-08")

    assert "## Validation: VALIDATED" in task_path.read_text(encoding="utf-8")
    assert "Validated by Night Shift validation agent on 2026-04-08." in task_path.read_text(encoding="utf-8")


def test_mutate_task_failed_replaces_existing_section(tmp_path: Path) -> None:
    task_path = tmp_path / "task.md"
    task_path.write_text(
        "## Task: Example\n"
        "## Goal\n"
        "Ship it\n\n"
        "## Validation: VALIDATED\n\n"
        "Validated by Night Shift validation agent on 2026-04-07.\n"
        "## Left Off At\n"
        "None\n",
        encoding="utf-8",
    )

    mutate_task_failed(task_path, ["- INVALID:path — missing.py not found"])

    content = task_path.read_text(encoding="utf-8")
    assert "## Validation: FAILED" in content
    assert "- INVALID:path — missing.py not found" in content
    assert "VALIDATED" not in content

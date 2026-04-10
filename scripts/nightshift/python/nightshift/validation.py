from __future__ import annotations

import re
import uuid
from pathlib import Path
from typing import Iterable


VALIDATION_RESULT_HEADER = "### Validation Result:"
_TOP_LEVEL_HEADING_RE = re.compile(r"^## [^#]")


def parse_validation_result(agent_output: str) -> str | None:
    final_block = _final_result_block(agent_output)
    if final_block is None:
        return None
    header = final_block[0]
    status = header[len(VALIDATION_RESULT_HEADER):].strip().upper()
    if status.startswith("VALIDATED"):
        return "VALIDATED"
    if status.startswith("INVALID"):
        return "INVALID"
    return None


def extract_validation_failed_checks(agent_output: str) -> list[str]:
    final_block = _final_result_block(agent_output)
    if final_block is None:
        return []

    failed_checks: list[str] = []
    capture = False
    for line in final_block[1:]:
        if line == "Failed checks:":
            capture = True
            continue
        if not capture:
            continue
        if line == "- (none)":
            continue
        if line.startswith("- "):
            failed_checks.append(line)
            continue
        if not line.strip():
            continue
        break
    return failed_checks


def mutate_task_validated(task_path: Path, *, run_date: str | None = None) -> None:
    body = _strip_existing_validation_section(task_path.read_text(encoding="utf-8"))
    lines = [body.rstrip(), "", "## Validation: VALIDATED", ""]
    if run_date:
        lines.append(f"Validated by Night Shift validation agent on {run_date}.")
    else:
        lines.append("Validated by Night Shift validation agent.")
    _atomic_write(task_path, "\n".join(lines).rstrip() + "\n")


def mutate_task_failed(task_path: Path, reasons: Iterable[str] | str) -> None:
    if isinstance(reasons, str):
        failure_lines = [line for line in reasons.splitlines() if line.strip()]
    else:
        failure_lines = [line for line in reasons if line.strip()]
    if not failure_lines:
        failure_lines = ["- INVALID:validation — validation agent marked the task invalid without failure details"]

    body = _strip_existing_validation_section(task_path.read_text(encoding="utf-8"))
    lines = [body.rstrip(), "", "## Validation: FAILED"]
    lines.extend(failure_lines)
    _atomic_write(task_path, "\n".join(lines).rstrip() + "\n")


def _final_result_block(agent_output: str) -> list[str] | None:
    block: list[str] | None = None
    capture = False
    for line in agent_output.splitlines():
        if line.startswith(VALIDATION_RESULT_HEADER):
            block = [line]
            capture = True
            continue
        if capture and block is not None:
            block.append(line)
    return block


def _strip_existing_validation_section(content: str) -> str:
    lines = content.splitlines()
    output: list[str] = []
    in_validation = False
    for line in lines:
        if line.startswith("## Validation:"):
            in_validation = True
            continue
        if in_validation and _TOP_LEVEL_HEADING_RE.match(line):
            in_validation = False
        if not in_validation:
            output.append(line)
    return "\n".join(output).rstrip()


def _atomic_write(target_path: Path, content: str) -> None:
    tmp_path = target_path.parent / f".{target_path.name}.{uuid.uuid4().hex}.tmp"
    try:
        tmp_path.write_text(content, encoding="utf-8")
        tmp_path.replace(target_path)
    finally:
        tmp_path.unlink(missing_ok=True)

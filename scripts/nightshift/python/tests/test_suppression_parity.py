from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest
import yaml

from nightshift.suppression import apply_suppressions

from .conftest import PROJECT_ROOT
from .test_suppression import finding_block, write_canonical_findings


@dataclass(frozen=True)
class ParityCase:
    name: str
    finding_blocks: list[str]
    suppressions_text: str
    expected_raw_total: int
    expected_eligible_total: int
    expected_suppressed_count: int
    expected_warning_substrings: tuple[str, ...] = ()
    expected_suppressed_titles: tuple[str, ...] = ()
    expected_expired_fingerprints: tuple[str, ...] = ()
    expected_missing_rule_key_titles: tuple[str, ...] = ()
    expected_unsuppressed_titles: tuple[str, ...] = ()
    expect_empty_audit_arrays: bool = False


def _run_shell_apply(
    *,
    findings_dir: Path,
    suppressions_path: Path,
    digests_dir: Path,
    run_tmp_dir: Path,
) -> dict[str, object]:
    shell_script = f"""
set -euo pipefail
source "{PROJECT_ROOT}/scripts/nightshift/nightshift.conf"
source "{PROJECT_ROOT}/scripts/nightshift/nightshift.sh"
source "{PROJECT_ROOT}/scripts/nightshift/lib/suppression.sh"
REPO_ROOT="{PROJECT_ROOT}"
RUN_TMP_DIR="{run_tmp_dir}"
RUN_DATE="2026-04-16"
RUN_ID="parity-test"
NIGHTSHIFT_FINDINGS_DIR="{findings_dir}"
NIGHTSHIFT_SUPPRESSIONS_FILE="{suppressions_path}"
NIGHTSHIFT_DIGESTS_DIR="{digests_dir}"
TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
nightshift_apply_suppressions >/dev/null
cat "$(nightshift_suppression_report_path)"
"""
    completed = subprocess.run(
        ["bash", "-lc", shell_script],
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
        check=False,
        env={**os.environ, "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)


def _write_case_findings(path: Path, finding_blocks: list[str]) -> None:
    write_canonical_findings(
        path,
        "security-detective",
        finding_blocks,
    )


PARITY_CASES = (
    ParityCase(
        name="single-active-suppression",
        finding_blocks=[
            finding_block(
                title="Chat auth missing",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/api/routers/chat.py:10-20 anonymous access",
            ),
            finding_block(
                title="Feedback metrics unauthenticated",
                category="security",
                rule_key="CWE-862",
                first_evidence="src/api/routers/feedback.py:40-50 auth missing",
            ),
        ],
        suppressions_text=(
            "- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306\n"
            "  rationale: EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.\n"
            "  added_by: george\n"
            "  added_date: 2026-04-16\n"
            "  expires_date: 2026-07-15\n"
            "  scope: finding\n"
        ),
        expected_raw_total=2,
        expected_eligible_total=1,
        expected_suppressed_count=1,
        expected_suppressed_titles=("Chat auth missing",),
        expected_unsuppressed_titles=("Feedback metrics unauthenticated",),
    ),
    ParityCase(
        name="empty-suppressions",
        finding_blocks=[
            finding_block(
                title="Chat auth missing",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/api/routers/chat.py:10-20 anonymous access",
            ),
            finding_block(
                title="Feedback metrics unauthenticated",
                category="security",
                rule_key="CWE-862",
                first_evidence="src/api/routers/feedback.py:40-50 auth missing",
            ),
        ],
        suppressions_text="[]\n",
        expected_raw_total=2,
        expected_eligible_total=2,
        expected_suppressed_count=0,
        expected_unsuppressed_titles=("Chat auth missing", "Feedback metrics unauthenticated"),
        expect_empty_audit_arrays=True,
    ),
    ParityCase(
        name="malformed-yaml",
        finding_blocks=[
            finding_block(
                title="Chat auth missing",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/api/routers/chat.py:10-20 anonymous access",
            )
        ],
        suppressions_text="not: [valid\n",
        expected_raw_total=1,
        expected_eligible_total=1,
        expected_suppressed_count=0,
        expected_warning_substrings=("parse error",),
        expected_unsuppressed_titles=("Chat auth missing",),
        expect_empty_audit_arrays=True,
    ),
    ParityCase(
        name="missing-rule-key",
        finding_blocks=[
            finding_block(
                title="Chat auth missing",
                category="security",
                rule_key=None,
                first_evidence="src/api/routers/chat.py:10-20 anonymous access",
            )
        ],
        suppressions_text="[]\n",
        expected_raw_total=1,
        expected_eligible_total=1,
        expected_suppressed_count=0,
        expected_warning_substrings=("missing Rule Key",),
        expected_missing_rule_key_titles=("Chat auth missing",),
        expected_unsuppressed_titles=("Chat auth missing",),
    ),
    ParityCase(
        name="expired-suppression",
        finding_blocks=[
            finding_block(
                title="Chat auth missing",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/api/routers/chat.py:10-20 anonymous access",
            )
        ],
        suppressions_text=(
            "- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306\n"
            "  rationale: EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.\n"
            "  added_by: george\n"
            "  added_date: 2026-01-01\n"
            "  expires_date: 2026-04-01\n"
            "  scope: finding\n"
        ),
        expected_raw_total=1,
        expected_eligible_total=1,
        expected_suppressed_count=0,
        expected_warning_substrings=("expired 2026-04-01",),
        expected_expired_fingerprints=("security-detective:security:src/api/routers/chat.py:CWE-306",),
        expected_unsuppressed_titles=("Chat auth missing",),
    ),
    ParityCase(
        name="mixed-payload",
        finding_blocks=[
            finding_block(
                title="Chat auth missing",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/api/routers/chat.py:10-20 anonymous access",
            ),
            finding_block(
                title="Feedback auth accepted risk",
                category="security",
                rule_key="CWE-862",
                first_evidence="src/api/routers/feedback.py:40-50 anonymous access",
            ),
            finding_block(
                title="Legacy endpoint auth missing",
                category="security",
                rule_key="CWE-285",
                first_evidence="src/api/routers/legacy.py:10-20 anonymous access",
            ),
            finding_block(
                title="Rule key absent",
                category="security",
                rule_key=None,
                first_evidence="src/api/routers/missing.py:10-20 anonymous access",
            ),
            finding_block(
                title="Unsuppressed metrics issue",
                category="security",
                rule_key="CWE-200",
                first_evidence="src/api/routers/metrics.py:10-20 anonymous access",
            ),
            finding_block(
                title="Unsuppressed debug endpoint",
                category="security",
                rule_key="CWE-489",
                first_evidence="src/api/routers/debug.py:10-20 anonymous access",
            ),
        ],
        suppressions_text=yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:src/api/routers/chat.py:CWE-306",
                    "rationale": "EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-07-15",
                    "scope": "finding",
                },
                {
                    "fingerprint": "security-detective:security:src/api/routers/feedback.py:CWE-862",
                    "rationale": "The feedback endpoint remains accepted risk until the service-wide auth work lands.",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-07-15",
                    "scope": "finding",
                },
                {
                    "fingerprint": "security-detective:security:src/api/routers/legacy.py:CWE-285",
                    "rationale": "The legacy route suppression expired and should surface for review again immediately.",
                    "added_by": "george",
                    "added_date": "2026-01-01",
                    "expires_date": "2026-04-01",
                    "scope": "finding",
                },
            ],
            sort_keys=False,
        ),
        expected_raw_total=6,
        expected_eligible_total=4,
        expected_suppressed_count=2,
        expected_warning_substrings=("expired 2026-04-01", "missing Rule Key"),
        expected_suppressed_titles=("Chat auth missing", "Feedback auth accepted risk"),
        expected_expired_fingerprints=("security-detective:security:src/api/routers/legacy.py:CWE-285",),
        expected_missing_rule_key_titles=("Rule key absent",),
        expected_unsuppressed_titles=(
            "Legacy endpoint auth missing",
            "Rule key absent",
            "Unsuppressed metrics issue",
            "Unsuppressed debug endpoint",
        ),
    ),
)


@pytest.mark.parametrize("case", PARITY_CASES, ids=lambda case: case.name)
def test_shell_and_python_suppression_reports_match(case: ParityCase, tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    findings_dir_shell = tmp_path / "findings-shell"
    findings_dir_shell.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    run_tmp_dir = tmp_path / "run"
    run_tmp_dir.mkdir()

    _write_case_findings(findings_dir / "security-detective-findings.md", case.finding_blocks)
    _write_case_findings(findings_dir_shell / "security-detective-findings.md", case.finding_blocks)
    suppressions_path.write_text(case.suppressions_text, encoding="utf-8")

    python_result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )
    python_report = python_result.to_dict()
    shell_report = _run_shell_apply(
        findings_dir=findings_dir_shell,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_tmp_dir=run_tmp_dir,
    )

    assert shell_report == python_report
    assert python_report["raw_total"] == case.expected_raw_total
    assert python_report["eligible_total"] == case.expected_eligible_total
    assert python_report["suppressed_count"] == case.expected_suppressed_count
    assert [item["title"] for item in python_report["suppressed_findings"]] == list(case.expected_suppressed_titles)
    assert [item["fingerprint"] for item in python_report["expired_suppressions"]] == list(case.expected_expired_fingerprints)
    assert [item["title"] for item in python_report["missing_rule_key_findings"]] == list(case.expected_missing_rule_key_titles)
    assert [item["title"] for item in python_report["unsuppressed_findings"]] == list(case.expected_unsuppressed_titles)

    warnings = python_report["warnings"]
    for expected_warning in case.expected_warning_substrings:
        assert any(expected_warning in warning for warning in warnings)

    if case.expect_empty_audit_arrays:
        assert python_report["suppressed_findings"] == []
        assert python_report["expired_suppressions"] == []
        assert python_report["expiring_soon"] == []
        assert python_report["missing_rule_key_findings"] == []

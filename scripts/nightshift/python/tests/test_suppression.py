from __future__ import annotations

import io
from contextlib import redirect_stderr, redirect_stdout
from datetime import date
from pathlib import Path

import pytest
import yaml

from nightshift.cli.suppressions import main as suppression_cli_main
from nightshift.detective_status import DetectiveStatus, DetectiveStatusStore
from nightshift.digest import rewrite_manager_digest
from nightshift.suppression import (
    annotate_digest_with_fingerprints,
    apply_suppressions,
    compute_fingerprint,
    load_suppressions,
    parse_digest_rank_fingerprint,
    parse_findings_dir,
    render_expired_suppressions_section,
    render_expiring_soon_section,
    render_findings_missing_rule_key_section,
    render_suppressed_findings_section,
)


def test_fingerprint_is_deterministic_and_ignores_line_numbers(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
            finding_block(
                title="Chat auth missing",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/api/routers/chat.py:10-20 blocks anonymous auth",
            ),
            finding_block(
                title="Chat auth missing again",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/api/routers/chat.py:800-900 blocks anonymous auth",
            ),
        ],
    )

    findings = parse_findings_dir(findings_dir)
    assert findings[0].finding_fingerprint == findings[1].finding_fingerprint
    assert findings[0].finding_fingerprint == "security-detective:security:src/api/routers/chat.py:CWE-306"


def test_primary_file_override_wins_over_first_evidence_path(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
            finding_block(
                title="Override primary file",
                category="security",
                rule_key="CWE-306",
                first_evidence="src/one.py:10 first evidence path",
                primary_file="src/two.py",
            ),
        ],
    )

    finding = parse_findings_dir(findings_dir)[0]
    assert finding.primary_file == "src/two.py"
    assert finding.finding_fingerprint == "security-detective:security:src/two.py:CWE-306"


@pytest.mark.parametrize(
    ("first_evidence", "expected_primary_file"),
    [
        ("main.py:42 auth bypass", "main.py"),
        ("src/api/routers/analysis.py:100 missing validation", "src/api/routers/analysis.py"),
        ("gunicorn.conf.py:47 pool settings", "gunicorn.conf.py"),
    ],
)
def test_primary_file_extraction_accepts_repo_root_and_nested_paths(
    tmp_path: Path,
    first_evidence: str,
    expected_primary_file: str,
) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
            finding_block(
                title="Path extraction",
                category="security",
                rule_key="CWE-306",
                first_evidence=first_evidence,
            ),
        ],
    )

    finding = parse_findings_dir(findings_dir)[0]
    assert finding.primary_file == expected_primary_file
    assert finding.suppressible is True


def test_primary_file_extraction_leaves_non_path_evidence_unsuppressible(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
            finding_block(
                title="No path evidence",
                category="security",
                rule_key="CWE-306",
                first_evidence="Authentication is not enforced on the /outcome endpoint",
            ),
        ],
    )

    finding = parse_findings_dir(findings_dir)[0]
    assert finding.primary_file is None
    assert finding.suppressible is False
    assert finding.suppressible_reason == "missing-primary-file"


def test_valid_suppression_excludes_finding_and_renders_audit_section(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
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
    )
    suppressions_path.write_text(
        yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:src/api/routers/chat.py:CWE-306",
                    "rationale": "EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-07-15",
                    "scope": "finding",
                }
            ],
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert result.suppressed_count == 1
    assert result.eligible_total == 1
    assert [finding.title for finding in result.unsuppressed_findings] == ["Feedback metrics unauthenticated"]
    assert "Chat auth missing" not in (findings_dir / "security-detective-findings.md").read_text(encoding="utf-8")
    suppressed_section = render_suppressed_findings_section(result)
    assert "## Suppressed Findings (Audit Only)" in suppressed_section
    assert "security-detective:security:src/api/routers/chat.py:CWE-306" in suppressed_section
    assert "| 1 |" in suppressed_section


def test_expired_suppression_does_not_filter_and_surfaces_expired_section(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access")],
    )
    suppressions_path.write_text(
        yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:src/api/routers/chat.py:CWE-306",
                    "rationale": "EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.",
                    "added_by": "george",
                    "added_date": "2026-01-01",
                    "expires_date": "2026-04-01",
                    "scope": "finding",
                }
            ],
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert result.suppressed_count == 0
    assert result.eligible_total == 1
    assert len(result.expired_suppressions) == 1
    assert "Expired Suppressions" in render_expired_suppressions_section(result)
    assert "security-detective:security:src/api/routers/chat.py:CWE-306" in render_expired_suppressions_section(result)


def test_expiring_soon_surfaces_section(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access")],
    )
    suppressions_path.write_text(
        yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:src/api/routers/chat.py:CWE-306",
                    "rationale": "EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-04-20",
                    "scope": "finding",
                }
            ],
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert len(result.expiring_soon) == 1
    expiring_section = render_expiring_soon_section(result)
    assert "## Expiring Soon" in expiring_section
    assert "2026-04-20" in expiring_section


def test_malformed_yaml_warns_without_crashing(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    suppressions_path.write_text("not: [valid\n", encoding="utf-8")
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access")],
    )

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert result.suppressed_count == 0
    assert result.eligible_total == 1
    assert any("parse error" in warning for warning in result.warnings)


def test_short_rationale_is_rejected_at_load_time(tmp_path: Path) -> None:
    suppressions_path = tmp_path / "suppressions.yaml"
    suppressions_path.write_text(
        yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:src/api/routers/chat.py:CWE-306",
                    "rationale": "too short",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-07-15",
                    "scope": "finding",
                }
            ],
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    active, expired, expiring_soon, warnings = load_suppressions(suppressions_path, today=date(2026, 4, 16))
    assert active == []
    assert expired == []
    assert expiring_soon == []
    assert any("rationale must be at least 20 characters" in warning for warning in warnings)


def test_scope_rule_suppresses_across_multiple_files(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
            finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access"),
            finding_block(title="Another chat auth path", category="security", rule_key="CWE-306", first_evidence="src/api/routers/feedback.py:40-50 anonymous access"),
        ],
    )
    suppressions_path.write_text(
        yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:*:CWE-306",
                    "rationale": "The shared edge control makes this rule class accepted risk until the front-door policy changes.",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-07-15",
                    "scope": "rule",
                }
            ],
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert result.suppressed_count == 2
    assert result.eligible_total == 0


def test_scope_finding_suppresses_only_exact_match(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
            finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access"),
            finding_block(title="Another chat auth path", category="security", rule_key="CWE-306", first_evidence="src/api/routers/feedback.py:40-50 anonymous access"),
        ],
    )
    suppressions_path.write_text(
        yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:src/api/routers/chat.py:CWE-306",
                    "rationale": "EasyAuth blocks the main chat route at the edge but does not apply to the feedback route.",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-07-15",
                    "scope": "finding",
                }
            ],
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert result.suppressed_count == 1
    assert [finding.title for finding in result.unsuppressed_findings] == ["Another chat auth path"]


def test_missing_rule_key_flows_through_and_surfaces_digest_section(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [finding_block(title="Chat auth missing", category="security", rule_key=None, first_evidence="src/api/routers/chat.py:10-20 anonymous access")],
    )
    suppressions_path.write_text("[]\n", encoding="utf-8")

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert result.suppressed_count == 0
    assert len(result.missing_rule_key_findings) == 1
    assert any("missing Rule Key" in warning for warning in result.warnings)
    missing_section = render_findings_missing_rule_key_section(result)
    assert "## Findings Missing Rule Key" in missing_section
    assert "Chat auth missing" in missing_section


def test_prior_digest_unparseable_defaults_runs_since_added_to_one_with_warning(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    suppressions_path = tmp_path / "suppressions.yaml"
    digests_dir = tmp_path / "digests"
    digests_dir.mkdir()
    (digests_dir / "2026-04-15.md").write_text("## Suppressed Findings (Audit Only)\nnot-a-table\n", encoding="utf-8")
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access")],
    )
    suppressions_path.write_text(
        yaml.safe_dump(
            [
                {
                    "fingerprint": "security-detective:security:src/api/routers/chat.py:CWE-306",
                    "rationale": "EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.",
                    "added_by": "george",
                    "added_date": "2026-04-16",
                    "expires_date": "2026-07-15",
                    "scope": "finding",
                }
            ],
            sort_keys=False,
        ),
        encoding="utf-8",
    )

    result = apply_suppressions(
        findings_dir,
        suppressions_path=suppressions_path,
        digests_dir=digests_dir,
        run_date="2026-04-16",
    )

    assert result.suppressed_findings[0].runs_since_added == 1
    assert any("defaulted runs-since-added to 1" in warning for warning in result.warnings)


def test_digest_summary_and_index_annotation_are_safe_for_single_source_findings(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    digest_path = tmp_path / "digest.md"
    status_dir = tmp_path / "status"
    status_dir.mkdir()
    store = DetectiveStatusStore(status_dir)
    store.write(
        DetectiveStatus(
            playbook="security-detective",
            engine="claude",
            status="success",
            duration_seconds=1,
            findings_count=1,
            cost_usd="0.0001",
        )
    )
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access")],
    )
    digest_path.write_text(
        "# Nightshift Detective Digest\n\n"
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "| 1 | major | security | Chat auth missing |\n\n"
        "### 1. Chat auth missing\n\n"
        "**Source Detective:** security-detective\n\n"
        "## Minor & Observation Findings\n"
        "| # | Title | Severity | Category | Source Detective | Evidence Summary |\n"
        "|---|-------|----------|----------|-----------------|-----------------|\n",
        encoding="utf-8",
    )

    rewrite_manager_digest(
        digest_path,
        run_date="2026-04-16",
        run_id="run-1",
        total_findings=2,
        eligible_findings=1,
        suppressed_count=1,
        task_file_count=0,
        detective_playbooks=("security-detective",),
        detective_status_store=store,
        findings_dir=findings_dir,
        suppression_sections=(),
    )
    annotate_digest_with_fingerprints(digest_path, findings_dir)
    digest_text = digest_path.read_text(encoding="utf-8")

    assert "- **Ranked:** 1 (1 suppressed)" in digest_text
    fingerprint, reason = parse_digest_rank_fingerprint(digest_path, "1")
    assert reason is None
    assert fingerprint == "security-detective:security:src/api/routers/chat.py:CWE-306"


def test_cli_rejects_digest_index_for_merged_or_non_unique_findings(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    digest_path = tmp_path / "digest.md"
    suppressions_path = tmp_path / "suppressions.yaml"
    suppressions_path.write_text("[]\n", encoding="utf-8")
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [
            finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access"),
            finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/feedback.py:40-50 anonymous access"),
        ],
    )
    digest_path.write_text(
        "# Nightshift Detective Digest\n\n"
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "| 1 | major | security | Chat auth missing |\n\n"
        "### 1. Chat auth missing\n\n"
        "**Source Detectives:** security-detective, coverage-detective\n\n"
        "## Minor & Observation Findings\n"
        "| # | Title | Severity | Category | Source Detective | Evidence Summary |\n"
        "|---|-------|----------|----------|-----------------|-----------------|\n",
        encoding="utf-8",
    )

    annotate_digest_with_fingerprints(digest_path, findings_dir)
    fingerprint, reason = parse_digest_rank_fingerprint(digest_path, "1")
    assert fingerprint is None
    assert reason == "digest-rank-not-single-source"

    with pytest.raises(SystemExit, match="not suppressible from index mode"):
        suppression_cli_main(
            [
                "add-entry",
                "--suppressions-file",
                str(suppressions_path),
                "--digest-path",
                str(digest_path),
                "--index",
                "1",
                "--rationale",
                "This rationale is long enough to pass validation but the finding is intentionally merged.",
                "--added-by",
                "george",
            ]
        )


def test_cli_adds_entry_from_digest_index(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    digest_path = tmp_path / "digest.md"
    suppressions_path = tmp_path / "suppressions.yaml"
    suppressions_path.write_text("[]\n", encoding="utf-8")
    write_canonical_findings(
        findings_dir / "security-detective-findings.md",
        "security-detective",
        [finding_block(title="Chat auth missing", category="security", rule_key="CWE-306", first_evidence="src/api/routers/chat.py:10-20 anonymous access")],
    )
    digest_path.write_text(
        "# Nightshift Detective Digest\n\n"
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "| 1 | major | security | Chat auth missing |\n\n"
        "### 1. Chat auth missing\n\n"
        "**Source Detective:** security-detective\n\n"
        "## Minor & Observation Findings\n"
        "| # | Title | Severity | Category | Source Detective | Evidence Summary |\n"
        "|---|-------|----------|----------|-----------------|-----------------|\n",
        encoding="utf-8",
    )
    annotate_digest_with_fingerprints(digest_path, findings_dir)

    stdout = io.StringIO()
    with redirect_stdout(stdout):
        exit_code = suppression_cli_main(
            [
                "add-entry",
                "--suppressions-file",
                str(suppressions_path),
                "--digest-path",
                str(digest_path),
                "--index",
                "1",
                "--rationale",
                "EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.",
                "--added-by",
                "george",
                "--added-date",
                "2026-04-16",
            ]
        )

    assert exit_code == 0
    assert stdout.getvalue().strip() == "security-detective:security:src/api/routers/chat.py:CWE-306"
    entries = yaml.safe_load(suppressions_path.read_text(encoding="utf-8"))
    assert entries[0]["expires_date"] == "2026-07-15"
    assert entries[0]["fingerprint"] == "security-detective:security:src/api/routers/chat.py:CWE-306"


def test_cli_add_entry_is_idempotent_and_replaces_on_reason_change(tmp_path: Path) -> None:
    suppressions_path = tmp_path / "suppressions.yaml"
    fingerprint_a = "security-detective:security:src/api/routers/chat.py:CWE-306"
    fingerprint_b = "security-detective:security:src/api/routers/feedback.py:CWE-862"
    initial_reason = "EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth."
    updated_reason = "The route is still accepted risk, but the rationale changed after the edge-control review was refreshed."
    other_reason = "Feedback auth is accepted risk until the service-wide authorization rollout is complete."

    def run_add(*, fingerprint: str, rationale: str, expires_date: str = "2026-07-15") -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            exit_code = suppression_cli_main(
                [
                    "add-entry",
                    "--suppressions-file",
                    str(suppressions_path),
                    "--fingerprint",
                    fingerprint,
                    "--rationale",
                    rationale,
                    "--added-by",
                    "george",
                    "--added-date",
                    "2026-04-16",
                    "--expires-date",
                    expires_date,
                ]
            )
        return exit_code, stdout.getvalue().strip(), stderr.getvalue().strip()

    exit_code, stdout_value, stderr_value = run_add(fingerprint=fingerprint_a, rationale=initial_reason)
    assert exit_code == 0
    assert stdout_value == fingerprint_a
    assert stderr_value == ""
    first_file_text = suppressions_path.read_text(encoding="utf-8")
    first_entries = yaml.safe_load(first_file_text)
    assert len(first_entries) == 1
    assert first_entries[0]["rationale"] == initial_reason

    exit_code, stdout_value, stderr_value = run_add(fingerprint=fingerprint_a, rationale=initial_reason)
    assert exit_code == 0
    assert stdout_value == fingerprint_a
    assert "no changes made" in stderr_value
    second_file_text = suppressions_path.read_text(encoding="utf-8")
    assert second_file_text == first_file_text
    second_entries = yaml.safe_load(second_file_text)
    assert len(second_entries) == 1

    exit_code, stdout_value, stderr_value = run_add(fingerprint=fingerprint_a, rationale=updated_reason)
    assert exit_code == 0
    assert stdout_value == fingerprint_a
    assert "Updated existing suppression entry" in stderr_value
    third_entries = yaml.safe_load(suppressions_path.read_text(encoding="utf-8"))
    assert len(third_entries) == 1
    assert third_entries[0]["fingerprint"] == fingerprint_a
    assert third_entries[0]["rationale"] == updated_reason

    exit_code, stdout_value, stderr_value = run_add(fingerprint=fingerprint_b, rationale=other_reason)
    assert exit_code == 0
    assert stdout_value == fingerprint_b
    assert stderr_value == ""
    final_entries = yaml.safe_load(suppressions_path.read_text(encoding="utf-8"))
    assert len(final_entries) == 2
    assert [entry["fingerprint"] for entry in final_entries] == [fingerprint_a, fingerprint_b]
    assert final_entries[0]["rationale"] == updated_reason
    assert final_entries[1]["rationale"] == other_reason


def write_canonical_findings(path: Path, detective_name: str, finding_blocks: list[str]) -> None:
    lines = [
        f"# Normalized {detective_name} Findings — 2026-04-16",
        "",
        f"## Detective: {detective_name} | status=ran | findings={len(finding_blocks)}",
        "",
        "## Source: claude",
        "",
    ]
    for index, block in enumerate(finding_blocks):
        lines.extend(block.strip().splitlines())
        if index != len(finding_blocks) - 1:
            lines.extend(["", ""])
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def finding_block(
    *,
    title: str,
    category: str,
    rule_key: str | None,
    first_evidence: str,
    primary_file: str | None = None,
    severity: str = "major",
) -> str:
    lines = [
        f"### Finding: {title}",
        f"**Severity:** {severity}",
        f"**Category:** {category}",
    ]
    if rule_key is not None:
        lines.append(f"**Rule Key:** {rule_key}")
    if primary_file is not None:
        lines.append(f"**Primary File:** {primary_file}")
    lines.extend(
        [
            "**Evidence:**",
            f"- {first_evidence}",
            "**Root Cause:** Example root cause.",
            "**Proposed Fix:** Example proposed fix.",
            "**Affected Users:** Example users.",
        ]
    )
    return "\n".join(lines)

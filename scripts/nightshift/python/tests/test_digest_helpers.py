from __future__ import annotations

from pathlib import Path

from nightshift.detective_status import DetectiveStatus, DetectiveStatusStore
from nightshift.digest import (
    MANAGER_REQUIRED_BODY_HEADINGS,
    RANKED_FINDINGS_HEADING,
    append_orchestrator_summary,
    count_total_findings,
    manager_top_findings_from_digest,
    normalize_findings_text,
    rebuild_manager_input_file,
    rebuild_manager_inputs,
    rewrite_manager_digest,
    validate_digest_headings,
    write_findings_manifest,
)


def _write_status(store: DetectiveStatusStore, playbook: str, status: str = "success", findings: int = 1) -> None:
    store.write(DetectiveStatus(playbook=playbook, engine="claude", status=status, duration_seconds=5, findings_count=findings, cost_usd="0.1000"))


def test_count_total_findings(tmp_path: Path) -> None:
    d = tmp_path / "findings"
    d.mkdir()
    (d / "commit-detective-findings.md").write_text("### Finding: A\n### Finding: B\n", encoding="utf-8")
    (d / "error-detective-findings.md").write_text("### Finding 1: X\nno match\n### Finding 2: Y\n", encoding="utf-8")
    assert count_total_findings(d) == 4


def test_count_total_findings_empty_dir(tmp_path: Path) -> None:
    d = tmp_path / "findings"
    d.mkdir()
    assert count_total_findings(d) == 0


def test_normalize_findings_text() -> None:
    text = "### Finding 1: A\nsome content\n### Finding 2: B\n"
    assert normalize_findings_text(text) == "### Finding: A\nsome content\n### Finding: B\n"


def test_rebuild_manager_input_file(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    status_dir = tmp_path / "status"
    status_dir.mkdir()
    store = DetectiveStatusStore(status_dir)
    _write_status(store, "commit-detective")
    (raw_dir / "claude-commit-detective-findings.md").write_text("### Finding: Bug in auth\n", encoding="utf-8")

    result = rebuild_manager_input_file(findings_dir, raw_dir, "commit-detective", "2026-04-08", store)
    assert result.exists()
    content = result.read_text(encoding="utf-8")
    assert "# Normalized commit-detective Findings" in content
    assert "status=ran" in content
    assert "findings=1" in content
    assert "## Source: claude" in content
    assert "### Finding: Bug in auth" in content


def test_rebuild_manager_input_excludes_partial(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    status_dir = tmp_path / "status"
    status_dir.mkdir()
    store = DetectiveStatusStore(status_dir)
    _write_status(store, "commit-detective")
    (raw_dir / "claude-commit-detective-findings.md").write_text("### Finding: Complete finding\n", encoding="utf-8")
    (raw_dir / "codex-commit-detective-partial.md").write_text("### Finding: Partial finding\n", encoding="utf-8")

    result = rebuild_manager_input_file(findings_dir, raw_dir, "commit-detective", "2026-04-08", store)

    content = result.read_text(encoding="utf-8")
    assert "Complete finding" in content
    assert "Partial finding" not in content
    assert "findings=1" in content


def test_rebuild_manager_input_file_skipped(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    status_dir = tmp_path / "status"
    status_dir.mkdir()
    store = DetectiveStatusStore(status_dir)
    _write_status(store, "commit-detective", status="skipped", findings=0)

    result = rebuild_manager_input_file(findings_dir, raw_dir, "commit-detective", "2026-04-08", store)
    content = result.read_text(encoding="utf-8")
    assert "status=skipped" in content
    assert "_Detective skipped._" in content


def test_rebuild_manager_inputs_clears_dir(tmp_path: Path) -> None:
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    (findings_dir / "stale.md").write_text("old", encoding="utf-8")
    raw_dir = tmp_path / "raw"
    raw_dir.mkdir()
    status_dir = tmp_path / "status"
    status_dir.mkdir()
    store = DetectiveStatusStore(status_dir)
    _write_status(store, "commit-detective")

    rebuild_manager_inputs(findings_dir, raw_dir, ("commit-detective",), "2026-04-08", store)
    assert not (findings_dir / "stale.md").exists()
    assert (findings_dir / "commit-detective-findings.md").exists()


def test_validate_digest_headings_pass(tmp_path: Path) -> None:
    digest = tmp_path / "digest.md"
    digest.write_text("# Digest\n\n## Ranked Findings\n\n## Minor & Observation Findings\n", encoding="utf-8")
    assert validate_digest_headings(digest) == []


def test_validate_digest_headings_missing(tmp_path: Path) -> None:
    digest = tmp_path / "digest.md"
    digest.write_text("# Digest\n\n## Ranked Findings\n", encoding="utf-8")
    missing = validate_digest_headings(digest)
    assert missing == ["## Minor & Observation Findings"]


def test_validate_digest_headings_no_file(tmp_path: Path) -> None:
    digest = tmp_path / "no-such-file.md"
    missing = validate_digest_headings(digest)
    assert len(missing) == len(MANAGER_REQUIRED_BODY_HEADINGS)


def test_manager_top_findings_from_digest(tmp_path: Path) -> None:
    digest = tmp_path / "digest.md"
    digest.write_text(
        "# Digest\n\n"
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "| 1 | critical | regression | Auth regression |\n"
        "| 2 | major | error-handling | Missing error handler |\n"
        "\n## Minor & Observation Findings\n",
        encoding="utf-8",
    )
    results = manager_top_findings_from_digest(digest)
    assert len(results) == 2
    assert results[0] == ("1", "critical", "regression", "Auth regression")
    assert results[1] == ("2", "major", "error-handling", "Missing error handler")


def test_manager_top_findings_empty_table(tmp_path: Path) -> None:
    digest = tmp_path / "digest.md"
    digest.write_text(
        "# Digest\n\n"
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "\n## Minor & Observation Findings\n",
        encoding="utf-8",
    )
    assert manager_top_findings_from_digest(digest) == []


def test_manager_top_findings_no_file(tmp_path: Path) -> None:
    assert manager_top_findings_from_digest(Path("/nonexistent")) == []


def test_write_findings_manifest(tmp_path: Path) -> None:
    digest = tmp_path / "digest.md"
    digest.write_text(
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "| 1 | critical | regression | Bug A |\n"
        "| 2 | major | security | Bug B |\n",
        encoding="utf-8",
    )
    manifest = tmp_path / "manifest.txt"
    assert write_findings_manifest(manifest, digest) is True
    content = manifest.read_text(encoding="utf-8")
    lines = content.strip().split("\n")
    assert len(lines) == 2
    assert lines[0] == "1\tcritical\tregression\tBug A"
    assert lines[1] == "2\tmajor\tsecurity\tBug B"


def test_rewrite_manager_digest(tmp_path: Path) -> None:
    digest = tmp_path / "digest.md"
    digest.write_text(
        "# Nightshift Detective Digest — 2026-04-08\n\n"
        "## Run Metadata\nold metadata\n\n"
        "## Summary\nold summary\n\n"
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "| 1 | critical | regression | Bug |\n\n"
        "## Minor & Observation Findings\n"
        "| # | Title | Severity | Category | Source | Evidence |\n"
        "|---|-------|----------|----------|--------|----------|\n",
        encoding="utf-8",
    )
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    (findings_dir / "commit-detective-findings.md").write_text("### Finding: X\n", encoding="utf-8")
    status_dir = tmp_path / "status"
    status_dir.mkdir()
    store = DetectiveStatusStore(status_dir)
    _write_status(store, "commit-detective")

    rewrite_manager_digest(
        digest, run_date="2026-04-08", run_id="2026-04-08-120000-1234",
        total_findings=5, task_file_count=1,
        detective_playbooks=("commit-detective",),
        detective_status_store=store, findings_dir=findings_dir,
    )
    content = digest.read_text(encoding="utf-8")
    assert "# Nightshift Detective Digest" in content
    assert "**Run ID:** 2026-04-08-120000-1234" in content
    assert "**Total findings received:** 5" in content
    assert "## Detective Coverage" in content
    assert "## Ranked Findings" in content
    assert "old metadata" not in content


def test_append_orchestrator_summary(tmp_path: Path) -> None:
    digest = tmp_path / "digest.md"
    digest.write_text("# Digest\n", encoding="utf-8")
    append_orchestrator_summary(
        digest, run_id="run-1", branch="nightshift/2026-04-08",
        phase_reached="Manager Merge", total_findings=3, task_file_count=2,
        total_cost="1.5000", warnings=["warn1"], failures=[],
    )
    content = digest.read_text(encoding="utf-8")
    assert "## Orchestrator Summary" in content
    assert "**Run ID:** run-1" in content
    assert "## Orchestrator Warnings" in content
    assert "- warn1" in content
    assert "## Orchestrator Failures" in content
    assert "- (none)" in content

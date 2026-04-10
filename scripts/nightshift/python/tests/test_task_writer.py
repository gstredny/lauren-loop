from __future__ import annotations

from pathlib import Path

from nightshift.task_writer import (
    build_finding_text,
    extract_file_references,
    extract_task_file_content,
    parse_findings_manifest,
    parse_task_writer_result,
    read_source_context,
    resolve_target_path,
    slug_from_title,
    write_task_file,
    write_task_manifest,
)


def test_parse_findings_manifest(tmp_path: Path) -> None:
    manifest_path = tmp_path / "findings-manifest.txt"
    manifest_path.write_text(
        "1\tcritical\tregression\tAuth regression\n"
        "2\tmajor\tmissing-test\tCoverage gap\n"
        "3\tminor\tperformance\tSlow path\n",
        encoding="utf-8",
    )

    assert parse_findings_manifest(manifest_path) == [
        ("1", "critical", "regression", "Auth regression"),
        ("2", "major", "missing-test", "Coverage gap"),
        ("3", "minor", "performance", "Slow path"),
    ]


def test_parse_findings_manifest_empty(tmp_path: Path) -> None:
    manifest_path = tmp_path / "findings-manifest.txt"
    manifest_path.write_text("", encoding="utf-8")

    assert parse_findings_manifest(manifest_path) == []


def test_extract_task_file_content() -> None:
    output = (
        "Prelude\n"
        "--- BEGIN TASK FILE ---\n"
        "## Task: Example\n"
        "## Status: not started\n"
        "--- END TASK FILE ---\n"
        "### Task Writer Result: CREATED\n"
    )

    assert extract_task_file_content(output) == "## Task: Example\n## Status: not started"


def test_extract_task_file_content_no_markers() -> None:
    assert extract_task_file_content("### Task Writer Result: CREATED") is None


def test_parse_task_writer_result_created() -> None:
    assert parse_task_writer_result("### Task Writer Result: CREATED") == "CREATED"


def test_parse_task_writer_result_rejected() -> None:
    assert parse_task_writer_result("### Task Writer Result: REJECTED — duplicate task") == "REJECTED"


def test_slug_from_title() -> None:
    assert slug_from_title("Auth regression!!!") == "auth-regression"
    assert slug_from_title("  Multiple   spaces / punctuation  ") == "multiple-spaces-punctuation"


def test_resolve_target_path_no_collision(tmp_path: Path) -> None:
    base_dir = tmp_path / "docs" / "tasks" / "open"

    assert resolve_target_path(base_dir, "2026-04-08", "auth-regression") == (
        base_dir / "nightshift-2026-04-08-auth-regression" / "task.md"
    )


def test_resolve_target_path_collision(tmp_path: Path) -> None:
    base_dir = tmp_path / "docs" / "tasks" / "open"
    first_dir = base_dir / "nightshift-2026-04-08-auth-regression"
    first_dir.mkdir(parents=True)

    assert resolve_target_path(base_dir, "2026-04-08", "auth-regression") == (
        base_dir / "nightshift-2026-04-08-auth-regression-2" / "task.md"
    )


def test_write_task_file(tmp_path: Path) -> None:
    task_path = tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth" / "task.md"

    write_task_file(task_path, "## Task: Example")

    assert task_path.read_text(encoding="utf-8") == "## Task: Example\n"


def test_write_task_manifest(tmp_path: Path) -> None:
    manifest_path = tmp_path / "manager-task-manifest.txt"
    paths = [
        tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth" / "task.md",
        tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-cov" / "task.md",
    ]

    write_task_manifest(manifest_path, paths)

    assert manifest_path.read_text(encoding="utf-8") == f"{paths[0]}\n{paths[1]}\n"


def test_build_finding_text_includes_digest_row_and_matched_block(tmp_path: Path) -> None:
    digest_path = tmp_path / "docs" / "nightshift" / "digests" / "2026-04-08.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text(
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        "| 1 | critical | regression | Auth regression |\n"
        "## Minor & Observation Findings\n",
        encoding="utf-8",
    )
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    (findings_dir / "commit-detective-findings.md").write_text(
        "# Normalized commit-detective Findings — 2026-04-08\n\n"
        "## Detective: commit-detective | status=ran | findings=1\n\n"
        "## Source: claude\n\n"
        "### Finding: Auth regression\n"
        "**Severity:** critical\n",
        encoding="utf-8",
    )

    finding_text = build_finding_text(
        "1",
        "critical",
        "regression",
        "Auth regression",
        digest_path=digest_path,
        findings_dir=findings_dir,
    )

    assert "Full table row: | 1 | critical | regression | Auth regression |" in finding_text
    assert "### Finding: Auth regression" in finding_text


# --- extract_file_references tests ---


def test_extract_file_references_backtick_with_line() -> None:
    text = "Evidence: `src/services/chat_service.py:276` fails"
    assert extract_file_references(text) == [("src/services/chat_service.py", 276, None)]


def test_extract_file_references_bare_with_range() -> None:
    text = "Evidence: src/api/main.py:264-274"
    assert extract_file_references(text) == [("src/api/main.py", 264, 274)]


def test_extract_file_references_no_line_number() -> None:
    text = "Evidence: src/api/main.py has issues"
    assert extract_file_references(text) == [("src/api/main.py", None, None)]


def test_extract_file_references_dedup() -> None:
    text = (
        "`src/api/main.py:10` and later `src/api/main.py:50`"
    )
    result = extract_file_references(text)
    assert len(result) == 1
    assert result[0][0] == "src/api/main.py"


def test_extract_file_references_max_cap() -> None:
    text = "\n".join(
        f"`src/services/svc{i}.py:{i * 10}`" for i in range(6)
    )
    result = extract_file_references(text, max_files=4)
    assert len(result) == 4


def test_extract_file_references_no_match() -> None:
    text = "No file paths here, just prose about a bug."
    assert extract_file_references(text) == []


def test_extract_file_references_ignores_non_repo_paths() -> None:
    text = "See https://example.com/api/main.py:10 for details"
    assert extract_file_references(text) == []


# --- read_source_context tests ---


def _make_source_file(tmp_path: Path, rel_path: str, num_lines: int) -> None:
    abs_path = tmp_path / rel_path
    abs_path.parent.mkdir(parents=True, exist_ok=True)
    abs_path.write_text(
        "\n".join(f"line {i + 1} content" for i in range(num_lines)) + "\n",
        encoding="utf-8",
    )


def test_read_source_context_with_line_ref(tmp_path: Path) -> None:
    _make_source_file(tmp_path, "src/services/example.py", 300)
    refs = [("src/services/example.py", 150, None)]
    result = read_source_context(refs, repo_dir=tmp_path, context_window=50)

    assert "## Source Context" in result
    assert "### `src/services/example.py`" in result
    assert "```python" in result
    assert "100: line 100 content" in result
    assert "200: line 200 content" in result


def test_read_source_context_missing_file(tmp_path: Path) -> None:
    refs = [("src/nonexistent.py", 10, None)]
    assert read_source_context(refs, repo_dir=tmp_path) == ""


def test_read_source_context_caps_lines(tmp_path: Path) -> None:
    _make_source_file(tmp_path, "src/big.py", 500)
    refs = [("src/big.py", None, None)]
    result = read_source_context(refs, repo_dir=tmp_path, max_lines_per_file=200)

    assert "## Source Context" in result
    assert "(lines 1-200)" in result
    assert "201:" not in result


# --- build_finding_text source context integration ---


def test_build_finding_text_injects_source_context(tmp_path: Path) -> None:
    digest_path = tmp_path / "digest.md"
    digest_path.write_text("", encoding="utf-8")
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    (findings_dir / "commit-detective-findings.md").write_text(
        "### Finding: DB write bug\n"
        "**Evidence:** `src/api/main.py:10`\n",
        encoding="utf-8",
    )
    src_file = tmp_path / "src" / "api" / "main.py"
    src_file.parent.mkdir(parents=True, exist_ok=True)
    src_file.write_text(
        "\n".join(f"line {i + 1}" for i in range(100)) + "\n",
        encoding="utf-8",
    )

    result = build_finding_text(
        "1", "major", "regression", "DB write bug",
        digest_path=digest_path, findings_dir=findings_dir, repo_dir=tmp_path,
    )

    assert "## Source Context" in result
    assert "### `src/api/main.py`" in result
    assert "10: line 10" in result


def test_build_finding_text_no_repo_dir(tmp_path: Path) -> None:
    digest_path = tmp_path / "digest.md"
    digest_path.write_text("", encoding="utf-8")
    findings_dir = tmp_path / "findings"
    findings_dir.mkdir()
    (findings_dir / "commit-detective-findings.md").write_text(
        "### Finding: DB write bug\n"
        "**Evidence:** `src/api/main.py:10`\n",
        encoding="utf-8",
    )

    result = build_finding_text(
        "1", "major", "regression", "DB write bug",
        digest_path=digest_path, findings_dir=findings_dir,
    )

    assert "## Source Context" not in result

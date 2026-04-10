from __future__ import annotations

from pathlib import Path

import pytest

import nightshift.autofix as autofix_module
from nightshift.autofix import (
    AutofixArtifactError,
    AutofixScopeViolation,
    append_autofix_section,
    extract_goal_from_task,
    parse_lauren_manifest,
    parse_scope_triage_captured_files,
    run_lauren_loop,
    stage_autofix_changes,
)
from nightshift.subprocess_runner import CommandTimeoutError


def test_extract_goal_from_task_multiline(tmp_path: Path) -> None:
    task_path = tmp_path / "task.md"
    task_path.write_text(
        "## Task: Example\n"
        "## Goal\n"
        "Make the thing work.\n"
        "\n"
        "Without regressions.\n"
        "## Scope\n"
        "### In Scope\n",
        encoding="utf-8",
    )

    assert extract_goal_from_task(task_path) == "Make the thing work. Without regressions."


def test_extract_goal_from_task_inline(tmp_path: Path) -> None:
    task_path = tmp_path / "task.md"
    task_path.write_text("## Goal: Fix auth regression\n## Scope\n", encoding="utf-8")

    assert extract_goal_from_task(task_path) == "Fix auth regression"


def test_run_lauren_loop_success(monkeypatch, tmp_path: Path) -> None:
    captured = {}

    def fake_run_subprocess(command, *, cwd, env, timeout_seconds, phase_name, logger=None):
        captured["command"] = command
        captured["cwd"] = cwd
        captured["env"] = env
        captured["timeout_seconds"] = timeout_seconds
        captured["phase_name"] = phase_name
        class Result:
            returncode = 0
        return Result()

    monkeypatch.setattr(autofix_module, "run_subprocess", fake_run_subprocess)

    result = run_lauren_loop(
        "auth-regression",
        "Fix auth regression",
        tmp_path,
        600,
        env={"LAUREN_LOOP_NONINTERACTIVE": "1"},
    )

    assert result.returncode == 0
    assert captured["command"] == [
        "bash",
        str(tmp_path / "lauren-loop-v2.sh"),
        "auth-regression",
        "Fix auth regression",
        "--strict",
    ]
    assert captured["timeout_seconds"] == 600


def test_run_lauren_loop_timeout(monkeypatch, tmp_path: Path) -> None:
    def fake_run_subprocess(command, *, cwd, env, timeout_seconds, phase_name, logger=None):
        raise CommandTimeoutError(command, timeout_seconds)

    monkeypatch.setattr(autofix_module, "run_subprocess", fake_run_subprocess)

    with pytest.raises(CommandTimeoutError):
        run_lauren_loop("auth-regression", "Fix auth regression", tmp_path, 600, env={})


def test_parse_lauren_manifest(tmp_path: Path) -> None:
    manifest_path = tmp_path / "run-manifest.json"
    manifest_path.write_text('{"final_status": "success", "total_cost_usd": 1.25}', encoding="utf-8")

    assert parse_lauren_manifest(manifest_path) == ("success", "1.2500")


def test_parse_scope_triage_captured_files(tmp_path: Path) -> None:
    triage_path = tmp_path / "execution-scope-triage.json"
    triage_path.write_text(
        '{"captured_files": ["src/foo.py", "docs/tasks/open/nightshift-2026-04-08-auth/task.md"]}',
        encoding="utf-8",
    )

    assert parse_scope_triage_captured_files(triage_path) == [
        "src/foo.py",
        "docs/tasks/open/nightshift-2026-04-08-auth/task.md",
    ]


def test_append_autofix_section(tmp_path: Path) -> None:
    task_path = tmp_path / "task.md"
    task_path.write_text("## Task: Example\n", encoding="utf-8")

    append_autofix_section(
        task_path,
        status="applied",
        run_date="2026-04-08",
        run_id="2026-04-08-1234",
        exit_code=0,
        cost="1.2500",
    )

    content = task_path.read_text(encoding="utf-8")
    assert "## Autofix: applied" in content
    assert "- Lauren Loop exit code: 0" in content
    assert "- Cost: $1.2500" in content


def test_staging_allows_manifest_listed_files_only(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    task_dir = repo_dir / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth"
    task_dir.mkdir(parents=True)
    task_path = task_dir / "task.md"
    task_path.write_text("## Task: Example\n", encoding="utf-8")
    triage_path = task_dir / "competitive" / "execution-scope-triage.json"
    triage_path.parent.mkdir(parents=True, exist_ok=True)
    triage_path.write_text(
        '{"captured_files": ["src/foo.py", "docs/tasks/open/nightshift-2026-04-08-auth/task.md"]}',
        encoding="utf-8",
    )

    class FakeGit:
        def __init__(self) -> None:
            self.repo_dir = repo_dir
            self.staged = []

        def list_changed_files(self, left_ref, right_ref):
            return [
                "src/foo.py",
                "docs/tasks/open/nightshift-2026-04-08-auth/task.md",
                "docs/tasks/open/nightshift-2026-04-08-auth/competitive/run-manifest.json",
            ]

        def stage_paths(self, paths):
            self.staged.extend(paths)

    git = FakeGit()
    staged_paths = stage_autofix_changes(
        git,
        task_path,
        "before",
        "after",
        [],
        [],
    )

    assert staged_paths == [
        repo_dir / "src/foo.py",
        repo_dir / "docs/tasks/open/nightshift-2026-04-08-auth/task.md",
    ]
    assert git.staged == staged_paths


def test_staging_rejects_out_of_scope_changes(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    task_dir = repo_dir / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth"
    task_dir.mkdir(parents=True)
    task_path = task_dir / "task.md"
    task_path.write_text("## Task: Example\n", encoding="utf-8")
    triage_path = task_dir / "competitive" / "execution-scope-triage.json"
    triage_path.parent.mkdir(parents=True, exist_ok=True)
    triage_path.write_text(
        '{"captured_files": ["src/foo.py", "tests/test_foo.py"]}',
        encoding="utf-8",
    )

    class FakeGit:
        def __init__(self) -> None:
            self.repo_dir = repo_dir
            self.staged = []

        def list_changed_files(self, left_ref, right_ref):
            return ["src/foo.py", "tests/test_foo.py", "src/out_of_scope.py"]

        def stage_paths(self, paths):
            self.staged.extend(paths)

    git = FakeGit()

    with pytest.raises(AutofixScopeViolation) as exc_info:
        stage_autofix_changes(
            git,
            task_path,
            "before",
            "after",
            [],
            [],
        )

    assert exc_info.value.out_of_scope_paths == ["src/out_of_scope.py"]
    assert git.staged == []


def test_missing_manifest_stages_nothing(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    task_dir = repo_dir / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth"
    task_dir.mkdir(parents=True)
    task_path = task_dir / "task.md"
    task_path.write_text("## Task: Example\n", encoding="utf-8")

    class FakeGit:
        def __init__(self) -> None:
            self.repo_dir = repo_dir
            self.staged = []

        def list_changed_files(self, left_ref, right_ref):
            return ["src/foo.py"]

        def stage_paths(self, paths):
            self.staged.extend(paths)

    git = FakeGit()

    with pytest.raises(AutofixArtifactError):
        stage_autofix_changes(
            git,
            task_path,
            "before",
            "after",
            [],
            [],
        )

    assert git.staged == []

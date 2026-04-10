from __future__ import annotations

import subprocess
from pathlib import Path

import nightshift.backlog as backlog_helpers


def _write_task(
    path: Path,
    *,
    status: str = "not started",
    execution_mode: str = "single-agent",
    depends_on: str | None = None,
) -> Path:
    body = [
        "## Task: Example",
        f"## Status: {status}",
        "## Created: 2026-04-09",
        f"## Execution Mode: {execution_mode}",
        "",
        "## Goal",
        "Fix it.",
    ]
    if depends_on is not None:
        body.extend(["", "## Depends On", depends_on])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(body).rstrip() + "\n", encoding="utf-8")
    return path


def test_scan_open_tasks(tmp_path: Path) -> None:
    tasks_dir = tmp_path / "docs" / "tasks" / "open"
    task_a = _write_task(tasks_dir / "backlog-a" / "task.md")
    _write_task(tasks_dir / "backlog-a" / "competitive" / "artifact.md")
    task_b = _write_task(tasks_dir / "backlog-b.md")

    records = backlog_helpers.scan_open_tasks(tasks_dir)

    assert [path for path, _status, _metadata in records] == [task_a.resolve(), task_b.resolve()]


def test_is_pickable_not_started(tmp_path: Path) -> None:
    tasks_dir = tmp_path / "docs" / "tasks" / "open"
    task_path = _write_task(tasks_dir / "backlog-a" / "task.md")
    open_tasks = backlog_helpers.scan_open_tasks(tasks_dir)

    pickable, reason = backlog_helpers.is_pickable(
        task_path,
        "not started",
        "2026-04-09",
        [],
        [],
        open_tasks,
    )

    assert pickable is True
    assert reason is None


def test_is_pickable_in_progress(tmp_path: Path) -> None:
    tasks_dir = tmp_path / "docs" / "tasks" / "open"
    task_path = _write_task(tasks_dir / "backlog-a" / "task.md", status="in progress")
    open_tasks = backlog_helpers.scan_open_tasks(tasks_dir)

    pickable, reason = backlog_helpers.is_pickable(
        task_path,
        "in progress",
        "2026-04-09",
        [],
        [],
        open_tasks,
    )

    assert pickable is False
    assert reason == "Skipping docs/tasks/open/backlog-a/task.md: status is 'in progress'"


def test_is_pickable_same_run_task(tmp_path: Path) -> None:
    tasks_dir = tmp_path / "docs" / "tasks" / "open"
    task_path = _write_task(tasks_dir / "nightshift-2026-04-09-auth" / "task.md")
    open_tasks = backlog_helpers.scan_open_tasks(tasks_dir)

    pickable, reason = backlog_helpers.is_pickable(
        task_path,
        "not started",
        "2026-04-09",
        [task_path],
        [],
        open_tasks,
    )

    assert pickable is False
    assert reason == "Skipping docs/tasks/open/nightshift-2026-04-09-auth/task.md: same-run manager task"


def test_is_pickable_unresolved_dependency(tmp_path: Path) -> None:
    tasks_dir = tmp_path / "docs" / "tasks" / "open"
    dep_path = _write_task(tasks_dir / "dep-task" / "task.md", status="needs verification")
    task_path = _write_task(
        tasks_dir / "backlog-a" / "task.md",
        depends_on="- dep-task\n",
    )
    open_tasks = backlog_helpers.scan_open_tasks(tasks_dir)

    unresolved = backlog_helpers.resolve_dependencies(task_path, open_tasks)
    pickable, reason = backlog_helpers.is_pickable(
        task_path,
        "not started",
        "2026-04-09",
        [],
        [],
        open_tasks,
    )

    assert unresolved == ["docs/tasks/open/dep-task/task.md"]
    assert dep_path.exists()
    assert pickable is False
    assert reason == (
        "Skipping docs/tasks/open/backlog-a/task.md: dependency at "
        "docs/tasks/open/dep-task/task.md is still 'needs verification'"
    )


def test_is_pickable_resolved_dependency(tmp_path: Path) -> None:
    tasks_dir = tmp_path / "docs" / "tasks" / "open"
    _write_task(tasks_dir / "dep-task" / "task.md", status="done")
    task_path = _write_task(
        tasks_dir / "backlog-a" / "task.md",
        depends_on="- dep-task\n",
    )
    open_tasks = backlog_helpers.scan_open_tasks(tasks_dir)

    pickable, reason = backlog_helpers.is_pickable(
        task_path,
        "not started",
        "2026-04-09",
        [],
        [],
        open_tasks,
    )

    assert pickable is True
    assert reason is None


def test_parse_task_list_block() -> None:
    rows = backlog_helpers.parse_task_list_block(
        "## TASK_LIST\n"
        "1|docs/tasks/open/backlog-a/task.md|Fix backlog A|medium\n"
        "2|docs/tasks/open/backlog-b/task.md|Fix backlog B|high\n"
        "## NOTES\n"
    )

    assert rows == [
        (1, "docs/tasks/open/backlog-a/task.md", "Fix backlog A", "medium"),
        (2, "docs/tasks/open/backlog-b/task.md", "Fix backlog B", "high"),
    ]


def test_parse_task_list_no_block() -> None:
    assert backlog_helpers.parse_task_list_block("## NOTES\nnothing here\n") == []


def test_run_lauren_ranking(monkeypatch, tmp_path: Path) -> None:
    calls: list[tuple[list[str], Path, dict[str, str], int, str]] = []

    def fake_run_subprocess(command, *, cwd, env, timeout_seconds, phase_name, logger=None):
        calls.append((list(command), cwd, dict(env), timeout_seconds, phase_name))
        return subprocess.CompletedProcess(list(command), 0, "## TASK_LIST\n", "")

    monkeypatch.setattr(backlog_helpers, "run_subprocess", fake_run_subprocess)
    repo_root = tmp_path

    result = backlog_helpers.run_lauren_ranking(
        repo_root,
        repo_root / "docs" / "tasks" / "open",
        60,
        env={"LAUREN_LOOP_NONINTERACTIVE": "1"},
    )

    assert result.returncode == 0
    assert calls == [
        (
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            repo_root,
            {"LAUREN_LOOP_NONINTERACTIVE": "1"},
            60,
            "Backlog Ranking",
        )
    ]

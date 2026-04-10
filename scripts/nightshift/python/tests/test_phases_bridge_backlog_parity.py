from __future__ import annotations

import logging
import subprocess
from pathlib import Path

import nightshift.phases as phases_module
from nightshift.cost import CostTracker
from nightshift.git import GitStateMachine
from nightshift.phases import NightshiftOrchestrator
from nightshift.runtime import RunContext
from nightshift.timeout import TimeoutBudget

from .conftest import create_bare_remote_repo, run
from .test_phases import (
    ScriptedAgentRunner,
    ScriptedGit,
    _write_backlog_task,
    _write_lauren_manifest,
    _write_ranked_digest,
    _write_scope_triage,
    create_orchestrator,
)


def _create_real_git_orchestrator(
    worktree: Path,
    config_factory,
    *,
    extra_env: dict[str, str] | None = None,
) -> tuple[NightshiftOrchestrator, RunContext, GitStateMachine]:
    config = config_factory(repo_dir=worktree, extra_env=extra_env)
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=ScriptedAgentRunner(),  # type: ignore[arg-type]
        shipper=object(),  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(None),
        logger=logging.getLogger("test-phases"),
    )
    return orchestrator, context, git


def _commit_repo_file(worktree: Path, relative_path: str, content: str, *, message: str) -> Path:
    path = worktree / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    run(["git", "add", relative_path], cwd=worktree)
    run(["git", "commit", "-m", message], cwd=worktree)
    return path


def _staged_repo_paths(worktree: Path) -> list[str]:
    return [
        line.strip()
        for line in run(["git", "diff", "--cached", "--name-only"], cwd=worktree).stdout.splitlines()
        if line.strip()
    ]


def test_bridge_scope_violation_restores_worktree(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    tracked_path = _commit_repo_file(
        worktree,
        "src/bridge_scope.py",
        "value = 'original'\n",
        message="add bridge scope file",
    )
    orchestrator, context, _git = _create_real_git_orchestrator(
        worktree,
        config_factory,
        extra_env={
            "NIGHTSHIFT_BRIDGE_ENABLED": "true",
            "NIGHTSHIFT_BRIDGE_AUTO_EXECUTE": "true",
        },
    )
    _write_ranked_digest(
        context,
        [
            ("1", "critical", "regression", "Auth regression"),
            ("2", "major", "coverage", "Coverage drift"),
        ],
    )
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        if len(lauren_calls) == 1:
            tracked_path.write_text("value = 'out-of-scope'\n", encoding="utf-8")
            _write_scope_triage(hinted_task, ["src/allowed.py"])
        else:
            _write_scope_triage(hinted_task, [])
        _write_lauren_manifest(hinted_task, {"final_status": "success", "total_cost_usd": 0.50})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert lauren_calls == [
        f"nightshift-bridge-{context.run_date}-auth-regression",
        f"nightshift-bridge-{context.run_date}-coverage-drift",
    ]
    assert tracked_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert "src/bridge_scope.py" not in _staged_repo_paths(worktree)
    assert [entry["status"] for entry in context.bridge_results] == ["failed", "applied"]
    assert any("produced out-of-scope changes" in message for message in context.warnings)


def test_bridge_blocked_restores_and_halts(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    tracked_path = _commit_repo_file(
        worktree,
        "src/bridge_blocked.py",
        "value = 'original'\n",
        message="add bridge blocked file",
    )
    orchestrator, context, _git = _create_real_git_orchestrator(
        worktree,
        config_factory,
        extra_env={
            "NIGHTSHIFT_BRIDGE_ENABLED": "true",
            "NIGHTSHIFT_BRIDGE_AUTO_EXECUTE": "true",
        },
    )
    _write_ranked_digest(
        context,
        [
            ("1", "critical", "regression", "Auth regression"),
            ("2", "major", "coverage", "Coverage drift"),
        ],
    )
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        tracked_path.write_text("value = 'blocked'\n", encoding="utf-8")
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        _write_lauren_manifest(hinted_task, {"final_status": "blocked", "total_cost_usd": 0.50})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert lauren_calls == [f"nightshift-bridge-{context.run_date}-auth-regression"]
    assert tracked_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert [entry["status"] for entry in context.bridge_results] == ["blocked"]
    assert any("Bridge stopped after Lauren Loop reported blocked" in message for message in context.warnings)


def test_bridge_human_review_restores_and_halts(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    tracked_path = _commit_repo_file(
        worktree,
        "src/bridge_human_review.py",
        "value = 'original'\n",
        message="add bridge human review file",
    )
    orchestrator, context, _git = _create_real_git_orchestrator(
        worktree,
        config_factory,
        extra_env={
            "NIGHTSHIFT_BRIDGE_ENABLED": "true",
            "NIGHTSHIFT_BRIDGE_AUTO_EXECUTE": "true",
        },
    )
    _write_ranked_digest(
        context,
        [
            ("1", "critical", "regression", "Auth regression"),
            ("2", "major", "coverage", "Coverage drift"),
        ],
    )
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        tracked_path.write_text("value = 'human-review'\n", encoding="utf-8")
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        _write_lauren_manifest(hinted_task, {"final_status": "human_review", "total_cost_usd": 0.50})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert lauren_calls == [f"nightshift-bridge-{context.run_date}-auth-regression"]
    assert tracked_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert [entry["status"] for entry in context.bridge_results] == ["human_review"]
    assert any("Bridge stopped after Lauren Loop reported human_review" in message for message in context.warnings)


def test_bridge_manifest_malformed_restores_and_halts(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    tracked_path = _commit_repo_file(
        worktree,
        "src/bridge_manifest.py",
        "value = 'original'\n",
        message="add bridge manifest file",
    )
    orchestrator, context, _git = _create_real_git_orchestrator(
        worktree,
        config_factory,
        extra_env={
            "NIGHTSHIFT_BRIDGE_ENABLED": "true",
            "NIGHTSHIFT_BRIDGE_AUTO_EXECUTE": "true",
        },
    )
    _write_ranked_digest(
        context,
        [
            ("1", "critical", "regression", "Auth regression"),
            ("2", "major", "coverage", "Coverage drift"),
        ],
    )
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        tracked_path.write_text("value = 'malformed'\n", encoding="utf-8")
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        _write_lauren_manifest(hinted_task, {"final_status": "success"})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert lauren_calls == [f"nightshift-bridge-{context.run_date}-auth-regression"]
    assert tracked_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert [entry["status"] for entry in context.bridge_results] == ["failed"]
    assert any("manifest contract failure" in message for message in context.warnings)


def test_bridge_budget_exhausted_still_creates_tasks(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={
            "NIGHTSHIFT_BRIDGE_ENABLED": "true",
            "NIGHTSHIFT_BRIDGE_AUTO_EXECUTE": "true",
        },
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        raise AssertionError("Lauren Loop should not run when the bridge budget is exhausted")

    monkeypatch.setattr(orchestrator, "_remaining_budget", lambda extra_spend=0.0: 0.0)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert lauren_calls == []
    assert len(context.bridge_results) == 1
    assert context.bridge_results[0]["status"] == "prepared"
    assert context.bridge_task_paths[0].exists()
    assert context.digest_path is not None
    assert "## Bridge" in context.digest_path.read_text(encoding="utf-8")


def test_backlog_scope_violation_restores_worktree(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    tracked_path = _commit_repo_file(
        worktree,
        "src/backlog_scope.py",
        "value = 'original'\n",
        message="add backlog scope file",
    )
    orchestrator, context, _git = _create_real_git_orchestrator(
        worktree,
        config_factory,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(worktree / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(worktree / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    (worktree / "lauren-loop.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop.sh").chmod(0o755)
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return subprocess.CompletedProcess(
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            0,
            (
                "## TASK_LIST\n"
                "1|docs/tasks/open/backlog-one/task.md|Fix backlog one|medium\n"
                "2|docs/tasks/open/backlog-two/task.md|Fix backlog two|medium\n"
            ),
            "",
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        if len(lauren_calls) == 1:
            tracked_path.write_text("value = 'out-of-scope'\n", encoding="utf-8")
            _write_scope_triage(hinted_task, ["src/allowed.py"])
        else:
            _write_scope_triage(hinted_task, [])
        _write_lauren_manifest(hinted_task, {"final_status": "success", "total_cost_usd": 0.50})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert lauren_calls == ["backlog-one", "backlog-two"]
    assert tracked_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert "src/backlog_scope.py" not in _staged_repo_paths(worktree)
    assert [entry["status"] for entry in context.backlog_results] == ["failed", "success"]
    assert any("produced out-of-scope changes" in message for message in context.warnings)


def test_backlog_blocked_restores_and_halts(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    tracked_path = _commit_repo_file(
        worktree,
        "src/backlog_blocked.py",
        "value = 'original'\n",
        message="add backlog blocked file",
    )
    orchestrator, context, _git = _create_real_git_orchestrator(
        worktree,
        config_factory,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(worktree / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(worktree / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    (worktree / "lauren-loop.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop.sh").chmod(0o755)
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return subprocess.CompletedProcess(
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            0,
            (
                "## TASK_LIST\n"
                "1|docs/tasks/open/backlog-one/task.md|Fix backlog one|medium\n"
                "2|docs/tasks/open/backlog-two/task.md|Fix backlog two|medium\n"
            ),
            "",
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        tracked_path.write_text("value = 'blocked'\n", encoding="utf-8")
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        _write_lauren_manifest(hinted_task, {"final_status": "blocked", "total_cost_usd": 0.50})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert lauren_calls == ["backlog-one"]
    assert tracked_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert [entry["status"] for entry in context.backlog_results] == ["blocked"]
    assert any("Backlog stopped after Lauren Loop reported blocked" in message for message in context.warnings)


def test_backlog_manifest_malformed_restores_and_halts(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    tracked_path = _commit_repo_file(
        worktree,
        "src/backlog_manifest.py",
        "value = 'original'\n",
        message="add backlog manifest file",
    )
    orchestrator, context, _git = _create_real_git_orchestrator(
        worktree,
        config_factory,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(worktree / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(worktree / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    (worktree / "lauren-loop.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop.sh").chmod(0o755)
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return subprocess.CompletedProcess(
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            0,
            (
                "## TASK_LIST\n"
                "1|docs/tasks/open/backlog-one/task.md|Fix backlog one|medium\n"
                "2|docs/tasks/open/backlog-two/task.md|Fix backlog two|medium\n"
            ),
            "",
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        tracked_path.write_text("value = 'malformed'\n", encoding="utf-8")
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        _write_lauren_manifest(hinted_task, {"final_status": "success"})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert lauren_calls == ["backlog-one"]
    assert tracked_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert [entry["status"] for entry in context.backlog_results] == ["failed"]
    assert any("manifest contract failure" in message for message in context.warnings)

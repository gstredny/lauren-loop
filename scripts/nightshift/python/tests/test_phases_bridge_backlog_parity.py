from __future__ import annotations

import logging
import subprocess
from pathlib import Path

import nightshift.phases as phases_module
from nightshift.task_context import build_existing_open_tasks_context
from nightshift.cost import CostTracker
from nightshift.git import GitStateMachine
from nightshift.phases import NightshiftOrchestrator
from nightshift.runtime import RunContext
from nightshift.timeout import TimeoutBudget

from .conftest import NIGHTSHIFT_DIR, create_bare_remote_repo, run, write_executable
from .test_phases import (
    ScriptedAgentRunner,
    ScriptedGit,
    _completed_backlog_ranking,
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


def _write_backlog_tasks(repo_root: Path, slugs: list[str]) -> None:
    for slug in slugs:
        _write_backlog_task(repo_root / "docs" / "tasks" / "open" / slug / "task.md")


def _write_open_doc(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body.rstrip() + "\n", encoding="utf-8")
    return path


def _shell_existing_open_tasks_context(repo_root: Path) -> str:
    script = write_executable(
        repo_root / "print-shell-existing-open-tasks.sh",
        f"""#!/usr/bin/env bash
set -euo pipefail
source "{NIGHTSHIFT_DIR / 'nightshift.conf'}"
source "{NIGHTSHIFT_DIR / 'nightshift.sh'}"
REPO_ROOT="{repo_root}"
RUN_DATE="2026-03-31"
DRY_RUN=1
RUN_CLEAN=0
SETUP_FAILED=0
RUN_COST_CAP=0
RUN_FAILED=0
MANAGER_CONTRACT_FAILED=0
COST_TRACKING_READY=0
DIGEST_PATH=""
ensure_task_context_helpers >/dev/null 2>&1
context="$(task_context_existing_open_tasks_block)"
printf '%s' "${{context}}"
""",
    )
    return run(["bash", str(script)], cwd=repo_root).stdout


def _assert_existing_open_tasks_context_parity(
    repo_root: Path,
    files: dict[str, str] | None = None,
) -> str:
    for relative_path, body in (files or {}).items():
        _write_open_doc(repo_root / relative_path, body)

    shell_context = _shell_existing_open_tasks_context(repo_root)
    python_context = build_existing_open_tasks_context(repo_root / "docs" / "tasks" / "open")

    assert shell_context == python_context
    return python_context


def _shell_backlog_selected_count(
    repo_root: Path,
    *,
    attempted_count: int,
    min_tasks_per_run: int,
    run_clean: bool,
    backlog_max: int,
) -> int:
    script = write_executable(
        repo_root / "count-shell-backlog-selection.sh",
        f"""#!/usr/bin/env bash
set -euo pipefail
source "{NIGHTSHIFT_DIR / 'nightshift.conf'}"
source "{NIGHTSHIFT_DIR / 'nightshift.sh'}"
REPO_ROOT="{repo_root}"
RUN_DATE="2026-03-31"
NIGHTSHIFT_BACKLOG_ENABLED="true"
NIGHTSHIFT_BACKLOG_MAX_TASKS="{backlog_max}"
NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
NIGHTSHIFT_MIN_TASKS_PER_RUN="{min_tasks_per_run}"
NIGHTSHIFT_COST_CAP_USD="100"
AUTOFIX_ATTEMPTED_COUNT="{attempted_count}"
DRY_RUN=1
RUN_CLEAN={1 if run_clean else 0}
SETUP_FAILED=0
RUN_COST_CAP=0
RUN_FAILED=0
MANAGER_CONTRACT_FAILED=0
COST_TRACKING_READY=0
DIGEST_PATH=""
phase_backlog_burndown >/dev/null 2>&1
printf '%s\\n' "${{#BACKLOG_RESULTS[@]}}"
""",
    )
    result = run(["bash", str(script)], cwd=repo_root)
    return int(result.stdout.strip())


def _assert_backlog_selection_count_parity(
    tmp_path: Path,
    config_factory,
    monkeypatch=None,
    *,
    attempted_count: int,
    min_tasks_per_run: int,
    run_clean: bool,
    backlog_max: int,
    task_slugs: list[str],
) -> tuple[RunContext, int, int]:
    _write_backlog_tasks(tmp_path, task_slugs)
    shell_count = _shell_backlog_selected_count(
        tmp_path,
        attempted_count=attempted_count,
        min_tasks_per_run=min_tasks_per_run,
        run_clean=run_clean,
        backlog_max=backlog_max,
    )
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
        extra_env={
            "NIGHTSHIFT_BACKLOG_ENABLED": "true",
            "NIGHTSHIFT_BACKLOG_MAX_TASKS": str(backlog_max),
            "NIGHTSHIFT_MIN_TASKS_PER_RUN": str(min_tasks_per_run),
        },
    )
    context.autofix_results = [{"status": "failed"} for _ in range(attempted_count)]
    if run_clean:
        context.run_clean = True
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    write_executable(tmp_path / "lauren-loop.sh", "#!/usr/bin/env bash\n")
    write_executable(tmp_path / "lauren-loop-v2.sh", "#!/usr/bin/env bash\n")
    rows = [
        (index + 1, f"docs/tasks/open/{slug}/task.md", f"Fix {slug.replace('-', ' ')}", "medium")
        for index, slug in enumerate(task_slugs)
    ]

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return _completed_backlog_ranking(repo_root, rows)

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        class Result:
            returncode = 1

        return Result()

    if monkeypatch is not None:
        monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
        monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    python_count = len(context.backlog_results)
    return context, shell_count, python_count


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


def test_backlog_floor_inflates_selected_count_for_parity(tmp_path: Path, config_factory, monkeypatch) -> None:
    context, shell_count, python_count = _assert_backlog_selection_count_parity(
        tmp_path,
        config_factory,
        monkeypatch,
        attempted_count=1,
        min_tasks_per_run=3,
        run_clean=False,
        backlog_max=1,
        task_slugs=["backlog-one", "backlog-two", "backlog-three"],
    )
    assert shell_count == python_count
    assert shell_count == 2
    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one", "backlog-two"]


def test_backlog_uses_normal_cap_after_floor_is_met_for_parity(tmp_path: Path, config_factory, monkeypatch) -> None:
    context, shell_count, python_count = _assert_backlog_selection_count_parity(
        tmp_path,
        config_factory,
        monkeypatch,
        attempted_count=5,
        min_tasks_per_run=3,
        run_clean=False,
        backlog_max=2,
        task_slugs=["backlog-one", "backlog-two", "backlog-three"],
    )
    assert shell_count == python_count
    assert shell_count == 2
    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one", "backlog-two"]


def test_backlog_runs_on_clean_run_when_floor_is_unmet_for_parity(tmp_path: Path, config_factory, monkeypatch) -> None:
    context, shell_count, python_count = _assert_backlog_selection_count_parity(
        tmp_path,
        config_factory,
        monkeypatch,
        attempted_count=1,
        min_tasks_per_run=3,
        run_clean=True,
        backlog_max=1,
        task_slugs=["backlog-one", "backlog-two", "backlog-three"],
    )
    assert shell_count == python_count
    assert shell_count == 2
    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one", "backlog-two"]


def test_backlog_skips_clean_run_after_floor_is_met_for_parity(tmp_path: Path, config_factory) -> None:
    context, shell_count, python_count = _assert_backlog_selection_count_parity(
        tmp_path,
        config_factory,
        monkeypatch=None,
        attempted_count=3,
        min_tasks_per_run=3,
        run_clean=True,
        backlog_max=3,
        task_slugs=["backlog-one", "backlog-two"],
    )
    assert shell_count == python_count
    assert shell_count == 0
    assert context.backlog_results == []


def test_backlog_minimum_zero_disables_floor_inflation_for_parity(tmp_path: Path, config_factory, monkeypatch) -> None:
    context, shell_count, python_count = _assert_backlog_selection_count_parity(
        tmp_path,
        config_factory,
        monkeypatch,
        attempted_count=1,
        min_tasks_per_run=0,
        run_clean=False,
        backlog_max=1,
        task_slugs=["backlog-one", "backlog-two"],
    )
    assert shell_count == python_count
    assert shell_count == 1
    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one"]


def test_existing_open_tasks_context_empty_backlog_parity(tmp_path: Path) -> None:
    context = _assert_existing_open_tasks_context_parity(tmp_path)

    assert context == "## Existing Open Tasks\n\n(none)"


def test_existing_open_tasks_context_filters_mixed_files_for_parity(tmp_path: Path) -> None:
    context = _assert_existing_open_tasks_context_parity(
        tmp_path,
        {
            "docs/tasks/open/alpha.md": "## Task: Alpha\n## Status: not started\n",
            "docs/tasks/open/beta.md": (
                "# Beta backlog item\n## Status: in progress\n\n## Done Criteria\n- Included.\n"
            ),
            "docs/tasks/open/gamma-roadmap.md": "# Gamma Roadmap\n**Status:** active\n",
            "docs/tasks/open/completed.md": (
                "## Task: Completed task\n## Status: completed\n## Attempts\n- Done.\n"
            ),
        },
    )

    assert context == (
        "## Existing Open Tasks\n\n"
        "docs/tasks/open/alpha.md: Alpha [not started]\n"
        "docs/tasks/open/beta.md: Beta backlog item [in progress]"
    )


def test_existing_open_tasks_context_uses_task_md_parent_title_for_parity(tmp_path: Path) -> None:
    context = _assert_existing_open_tasks_context_parity(
        tmp_path,
        {
            "docs/tasks/open/team-alpha/task.md": "## Status: blocked\n## Goal\nFallback title.\n",
        },
    )

    assert context == (
        "## Existing Open Tasks\n\n"
        "docs/tasks/open/team-alpha/task.md: team-alpha [blocked]"
    )


def test_existing_open_tasks_context_normalizes_heading_whitespace_for_parity(tmp_path: Path) -> None:
    context = _assert_existing_open_tasks_context_parity(
        tmp_path,
        {
            "docs/tasks/open/whitespace.md": (
                "# Alpha    beta\t\tgamma\n## Status: in progress\n\n## Done Criteria\n- Included.\n"
            ),
        },
    )

    assert context == (
        "## Existing Open Tasks\n\n"
        "docs/tasks/open/whitespace.md: Alpha beta gamma [in progress]"
    )

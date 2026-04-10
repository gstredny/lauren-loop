from __future__ import annotations

import importlib
import logging
import os
import signal
import subprocess
import time
from pathlib import Path

import pytest

from nightshift.agents import AgentTimeoutError
from nightshift.cost import CostTracker
from nightshift.phases import NightshiftOrchestrator
from nightshift.runtime import RunContext
from nightshift.timeout import TimeoutBudget
import nightshift.subprocess_runner as subprocess_runner_module

from .conftest import write_executable
from .test_phases import ScriptedAgentRunner, ScriptedGit, build_result, create_orchestrator


main_module = importlib.import_module("nightshift.main")


def _wait_for_nonempty_file(path: Path, *, timeout_seconds: float = 5.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if path.exists():
            contents = path.read_text(encoding="utf-8").strip()
            if contents:
                return contents
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for {path}")


def _wait_for_pid_exit(pid: int, *, timeout_seconds: float = 5.0) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except OSError:
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for pid {pid} to exit")


def test_terminate_active_process_groups_kills_registered_child_groups(tmp_path: Path) -> None:
    parent_term_file = tmp_path / "parent.term"
    child_pid_file = tmp_path / "child.pid"
    parent_script = write_executable(
        tmp_path / "parent.sh",
        """#!/usr/bin/env bash
set -euo pipefail
sleep 30 &
child=$!
printf '%s\n' "$child" > "$CHILD_PID_FILE"
trap 'printf "TERM\n" >> "$PARENT_TERM_FILE"; exit 0' TERM
while true; do
  sleep 1
done
""",
    )

    env = {
        **os.environ,
        "CHILD_PID_FILE": str(child_pid_file),
        "PARENT_TERM_FILE": str(parent_term_file),
    }

    subprocess_runner_module.terminate_active_process_groups()
    process = subprocess.Popen(
        [str(parent_script)],
        env=env,
        text=True,
        start_new_session=True,
    )
    try:
        child_pid = int(_wait_for_nonempty_file(child_pid_file))
        subprocess_runner_module._register_active_process_group(process.pid)

        subprocess_runner_module.terminate_active_process_groups()

        process.wait(timeout=5)
        assert _wait_for_nonempty_file(parent_term_file) == "TERM"
        _wait_for_pid_exit(child_pid)
    finally:
        subprocess_runner_module.terminate_active_process_groups()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def test_main_signal_handler_terminates_children_before_releasing_lock(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = config_factory(repo_dir=tmp_path)
    events: list[str] = []
    handlers: dict[int, object] = {}

    class FakeLock:
        def acquire(self) -> None:
            events.append("acquire")

        def release(self) -> None:
            events.append("release")

    class FakeOrchestrator:
        def __init__(self, **kwargs) -> None:
            pass

        def run(self) -> int:
            handler = handlers[signal.SIGTERM]
            assert callable(handler)
            handler(signal.SIGTERM, None)
            raise AssertionError("signal handler should have exited main()")

    def fake_signal_register(signum: int, handler: object) -> None:
        handlers[signum] = handler

    class FakeGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "nightshift/2026-04-09"

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", FakeGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(
        main_module,
        "terminate_active_process_groups",
        lambda logger=None: events.append("terminate"),
    )
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", fake_signal_register)

    with pytest.raises(SystemExit) as exc_info:
        main_module.main(["--smoke"])

    assert exc_info.value.code == 1
    assert "terminate" in events
    assert "release" in events
    assert events.index("terminate") < events.index("release")


def test_main_clears_findings_only_after_lock_acquire(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = config_factory(repo_dir=tmp_path)
    events: list[str] = []

    class FakeLock:
        def acquire(self) -> None:
            events.append("acquire")

        def release(self) -> None:
            events.append("release")

    class FakeContext:
        cost_state_file = tmp_path / "cost-state.json"
        exit_code = 0

        def clear_findings_dir(self) -> None:
            events.append("clear")

    class FakeRunContext:
        @classmethod
        def create(cls, config, *, dry_run, smoke):
            events.append("create")
            return FakeContext()

    class NightshiftBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "nightshift/2026-04-09"

    class FakeOrchestrator:
        def __init__(self, **kwargs) -> None:
            pass

        def run(self) -> int:
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "RunContext", FakeRunContext)
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", NightshiftBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke"])

    assert result == 0
    assert events.index("acquire") < events.index("clear")


def test_refuses_to_run_on_main_branch(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
    caplog: pytest.LogCaptureFixture,
) -> None:
    config = config_factory(repo_dir=tmp_path)

    class MainBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "main"

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "GitStateMachine", MainBranchGit)
    monkeypatch.setattr(
        main_module,
        "PidLock",
        lambda _path: pytest.fail("PidLock should not be created when the branch guard refuses the run"),
    )

    with caplog.at_level(logging.ERROR):
        result = main_module.main(["--smoke"])

    assert result == 1
    assert "FATAL: Night Shift must not run on branch 'main'" in caplog.text


def test_allows_run_on_detached_head(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = config_factory(repo_dir=tmp_path)
    events: list[str] = []

    class FakeLock:
        def acquire(self) -> None:
            events.append("acquire")

        def release(self) -> None:
            events.append("release")

    class DetachedGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return ""

    class FakeOrchestrator:
        def __init__(self, **kwargs) -> None:
            pass

        def run(self) -> int:
            events.append("run")
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", DetachedGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke"])

    assert result == 0
    assert events == ["acquire", "run", "release"]


def test_allows_run_on_nightshift_branch(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = config_factory(repo_dir=tmp_path)
    events: list[str] = []

    class FakeLock:
        def acquire(self) -> None:
            events.append("acquire")

        def release(self) -> None:
            events.append("release")

    class NightshiftBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "nightshift/2026-04-08"

    class FakeOrchestrator:
        def __init__(self, **kwargs) -> None:
            pass

        def run(self) -> int:
            events.append("run")
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", NightshiftBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke"])

    assert result == 0
    assert events == ["acquire", "run", "release"]


def test_dry_run_exempt_from_branch_check(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = config_factory(repo_dir=tmp_path)
    events: list[str] = []

    class FakeLock:
        def acquire(self) -> None:
            events.append("acquire")

        def release(self) -> None:
            events.append("release")

    class MainBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "main"

    class FakeOrchestrator:
        def __init__(self, **kwargs) -> None:
            pass

        def run(self) -> int:
            events.append("run")
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", MainBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--dry-run"])

    assert result == 0
    assert events == ["acquire", "run", "release"]


def test_force_direct_exempt_from_branch_check(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config = config_factory(repo_dir=tmp_path)
    events: list[str] = []

    class FakeLock:
        def acquire(self) -> None:
            events.append("acquire")

        def release(self) -> None:
            events.append("release")

    class MainBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "main"

    class FakeOrchestrator:
        def __init__(self, **kwargs) -> None:
            pass

        def run(self) -> int:
            events.append("run")
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", MainBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke", "--force-direct"])

    assert result == 0
    assert events == ["acquire", "run", "release"]


def test_exit_code_0_success(tmp_path: Path, config_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    config = config_factory(repo_dir=tmp_path)

    class FakeLock:
        def acquire(self) -> None:
            pass

        def release(self) -> None:
            pass

    class NightshiftBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "nightshift/2026-04-09"

    class FakeOrchestrator:
        def __init__(self, *, context, **kwargs) -> None:
            self.context = context

        def run(self) -> int:
            self.context.cost_cap_hit = False
            return 99

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", NightshiftBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke"])

    assert result == 0


def test_exit_code_1_failure(tmp_path: Path, config_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    config = config_factory(repo_dir=tmp_path)

    class FakeLock:
        def acquire(self) -> None:
            pass

        def release(self) -> None:
            pass

    class NightshiftBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "nightshift/2026-04-09"

    class FakeOrchestrator:
        def __init__(self, *, context, **kwargs) -> None:
            self.context = context

        def run(self) -> int:
            self.context.add_failure("boom")
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", NightshiftBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke"])

    assert result == 1


def test_exit_code_2_cost_cap(tmp_path: Path, config_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    config = config_factory(repo_dir=tmp_path)

    class FakeLock:
        def acquire(self) -> None:
            pass

        def release(self) -> None:
            pass

    class NightshiftBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "nightshift/2026-04-09"

    class FakeOrchestrator:
        def __init__(self, *, context, **kwargs) -> None:
            self.context = context

        def run(self) -> int:
            self.context.cost_cap_hit = True
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", NightshiftBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke"])

    assert result == 2


def test_exit_code_3_non_shippable(tmp_path: Path, config_factory, monkeypatch: pytest.MonkeyPatch) -> None:
    config = config_factory(repo_dir=tmp_path)

    class FakeLock:
        def acquire(self) -> None:
            pass

        def release(self) -> None:
            pass

    class NightshiftBranchGit:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def is_repo(self) -> bool:
            return True

        def current_branch(self) -> str:
            return "nightshift/2026-04-09"

    class FakeOrchestrator:
        def __init__(self, *, context, **kwargs) -> None:
            self.context = context

        def run(self) -> int:
            self.context.ship_blocked_reason = "no healthy detective runs completed (timeout=1)"
            return 0

    monkeypatch.setattr(main_module, "configure_logging", lambda: logging.getLogger("test-main"))
    monkeypatch.setattr(main_module.NightshiftConfig, "load", classmethod(lambda cls: config))
    monkeypatch.setattr(main_module, "PidLock", lambda path: FakeLock())
    monkeypatch.setattr(main_module, "GitStateMachine", NightshiftBranchGit)
    monkeypatch.setattr(main_module, "CostTracker", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "AgentRunner", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "Shipper", lambda *args, **kwargs: object())
    monkeypatch.setattr(main_module, "NightshiftOrchestrator", FakeOrchestrator)
    monkeypatch.setattr(main_module.signal, "getsignal", lambda signum: f"orig-{signum}")
    monkeypatch.setattr(main_module.signal, "signal", lambda signum, handler: None)

    result = main_module.main(["--smoke"])

    assert result == 3


# ── Cross-phase integration: detective warnings vs manager merge ─────────


SAMPLE_DIGEST = (
    "# Nightshift Detective Digest — {date}\n\n"
    "## Ranked Findings\n"
    "| # | Severity | Category | Title |\n"
    "|---|----------|----------|-------|\n"
    "| 1 | critical | regression | Auth regression |\n\n"
    "## Minor & Observation Findings\n"
    "| # | Title | Severity | Category | Source | Evidence |\n"
    "|---|-------|----------|----------|--------|----------|\n"
)


def _seed_raw_findings(context: RunContext) -> None:
    context.raw_findings_dir.mkdir(parents=True, exist_ok=True)
    (context.raw_findings_dir / "claude-conversation-detective-findings.md").write_text(
        "### Finding: Auth regression\nEvidence here\n", encoding="utf-8",
    )


def test_manager_merge_runs_after_detective_timeout(tmp_path: Path, config_factory) -> None:
    timeout_exc = AgentTimeoutError(
        "codex conversation-detective exceeded 30s",
        partial_result=build_result("codex", "conversation-detective", status="timeout",
                                    findings_count=0, duration_seconds=30, cost_usd="0.0500", return_code=124),
    )
    runner = ScriptedAgentRunner(scripted={("codex", "conversation-detective"): timeout_exc})
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("conversation-detective",),
    )
    orchestrator.phase_detectives()
    assert any("exceeded 30s" in w for w in context.warnings)
    assert context.failures == []
    _seed_raw_findings(context)
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-08"

    def _write():
        context.repo_digest_path.parent.mkdir(parents=True, exist_ok=True)
        context.repo_digest_path.write_text(SAMPLE_DIGEST.format(date=context.run_date), encoding="utf-8")
    runner.side_effects["manager-merge"] = _write
    orchestrator.phase_manager_merge()
    assert "claude/manager-merge" in runner.calls
    assert context.digest_path is not None


def test_manager_merge_skips_on_real_setup_failure(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("conversation-detective",),
    )
    context.add_failure("Git state invalid: detached HEAD")
    _seed_raw_findings(context)
    orchestrator.phase_manager_merge()
    assert "claude/manager-merge" not in runner.calls
    assert context.digest_path is not None
    assert "setup-failed" in context.digest_path.read_text(encoding="utf-8")

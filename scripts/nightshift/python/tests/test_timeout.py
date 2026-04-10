from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest

import nightshift.timeout as timeout_module
from nightshift.agents import AgentRunResult, AgentRunner
from nightshift.cost import CostTracker
from nightshift.git import GitStateMachine
from nightshift.phases import NightshiftOrchestrator
from nightshift.runtime import RunContext
from nightshift.ship import ShipError, Shipper
from nightshift.subprocess_runner import CommandTimeoutError, run_subprocess
from nightshift.timeout import TimeoutBudget, TotalTimeoutExceeded

from .conftest import NIGHTSHIFT_DIR, create_bare_remote_repo, write_executable


class RecordingAgentRunner:
    def __init__(self, clock_ref: list[float], *, increment: int) -> None:
        self.clock_ref = clock_ref
        self.increment = increment
        self.calls: list[str] = []

    def run_claude(self, playbook_name: str) -> AgentRunResult:
        self.calls.append(f"claude/{playbook_name}")
        self.clock_ref[0] += self.increment
        return AgentRunResult(
            engine="claude",
            playbook_name=playbook_name,
            output_path=Path("/tmp/output.json"),
            stderr_log_path=Path("/tmp/stderr.log"),
            archived_findings_path=None,
            findings_count=1,
            duration_seconds=self.increment,
            cost_usd="0.1000",
            status="success",
            return_code=0,
        )

    def run_codex(self, playbook_name: str) -> AgentRunResult:
        self.calls.append(f"codex/{playbook_name}")
        self.clock_ref[0] += self.increment
        return AgentRunResult(
            engine="codex",
            playbook_name=playbook_name,
            output_path=Path("/tmp/output.json"),
            stderr_log_path=Path("/tmp/stderr.log"),
            archived_findings_path=None,
            findings_count=1,
            duration_seconds=self.increment,
            cost_usd="0.1000",
            status="success",
            return_code=0,
        )


def _wait_for_text(path: Path, *, timeout_seconds: float = 5.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if path.exists():
            text = path.read_text(encoding="utf-8").strip()
            if text:
                return text
        time.sleep(0.01)
    raise AssertionError(f"Timed out waiting for {path}")


def test_global_timeout_checked_after_detective(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    config = config_factory(repo_dir=worktree, extra_env={"NIGHTSHIFT_CODEX_MODEL": ""})
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    git = GitStateMachine(worktree, protected_branches=config.protected_branch_list)
    shipper = Shipper(config=config, git=git)
    now = [0.0]
    runner = RecordingAgentRunner(now, increment=10)
    budget = TimeoutBudget(total_timeout_seconds=10, clock=lambda: now[0], started_at=0)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=runner,  # type: ignore[arg-type]
        shipper=shipper,
        cost_tracker=tracker,
        timeout_budget=budget,
        logger=logging.getLogger("test-timeout"),
        detective_playbooks=("commit-detective",),
        implemented_detectives=frozenset({"commit-detective"}),
    )

    orchestrator.phase_detectives()

    assert runner.calls == ["claude/commit-detective"]
    assert any("Total runtime exceeded 10s during Detective Runs" in msg for msg in context.warnings)


def test_global_timeout_aborts_remaining_detectives(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    config = config_factory(repo_dir=worktree, extra_env={"NIGHTSHIFT_CODEX_MODEL": ""})
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    git = GitStateMachine(worktree, protected_branches=config.protected_branch_list)
    shipper = Shipper(config=config, git=git)
    now = [0.0]
    runner = RecordingAgentRunner(now, increment=10)
    budget = TimeoutBudget(total_timeout_seconds=9, clock=lambda: now[0], started_at=0)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=runner,  # type: ignore[arg-type]
        shipper=shipper,
        cost_tracker=tracker,
        timeout_budget=budget,
        logger=logging.getLogger("test-timeout"),
        detective_playbooks=("commit-detective", "coverage-detective", "security-detective"),
        implemented_detectives=frozenset({"commit-detective", "coverage-detective", "security-detective"}),
    )

    orchestrator.phase_detectives()

    assert runner.calls == ["claude/commit-detective"]


def test_timeout_budget_checkpoint_raises() -> None:
    budget = TimeoutBudget(total_timeout_seconds=5, clock=lambda: 5, started_at=0)
    try:
        budget.checkpoint("Phase 3")
    except TotalTimeoutExceeded as exc:
        assert "Phase 3" in str(exc)
    else:  # pragma: no cover - assertion guard
        raise AssertionError("Expected TotalTimeoutExceeded")


def test_timeout_budget_reserves_termination_grace_window(monkeypatch) -> None:
    monkeypatch.setattr(timeout_module, "PROCESS_TERMINATION_GRACE_SECONDS", 5)
    budget = TimeoutBudget(total_timeout_seconds=20, clock=lambda: 13, started_at=0)

    assert budget.remaining_seconds == pytest.approx(7)
    assert budget.effective_subprocess_timeout(120, phase_name="git push origin branch") == pytest.approx(2)


def test_timeout_does_not_hang_on_orphaned_grandchild(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(timeout_module, "PROCESS_TERMINATION_GRACE_SECONDS", 0.1)

    pid_file = tmp_path / "grandchild.pid"
    spawn_script = tmp_path / "spawn_orphan.py"
    spawn_script.write_text(
        """
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

pid_file = Path(sys.argv[1])
grandchild_script = (
    "from pathlib import Path; "
    "import os, sys, time; "
    "Path(sys.argv[1]).write_text(str(os.getpid()), encoding='utf-8'); "
    "print('grandchild-ready', flush=True); "
    "time.sleep(6)"
)
subprocess.Popen(
    [sys.executable, "-c", grandchild_script, str(pid_file)],
    stdout=sys.stdout,
    stderr=sys.stderr,
    start_new_session=True,
)
deadline = time.monotonic() + 5
while time.monotonic() < deadline and not pid_file.exists():
    time.sleep(0.01)
print("parent-ready", flush=True)
time.sleep(6)
""".strip()
        + "\n",
        encoding="utf-8",
    )

    started = time.monotonic()
    with pytest.raises(CommandTimeoutError) as exc_info:
        run_subprocess(
            [sys.executable, str(spawn_script), str(pid_file)],
            cwd=tmp_path,
            env=None,
            timeout_seconds=0.5,
            phase_name="timeout regression",
            logger=logging.getLogger("test-timeout"),
        )
    elapsed = time.monotonic() - started

    grandchild_pid = int(_wait_for_text(pid_file))
    os.kill(grandchild_pid, signal.SIGKILL)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(grandchild_pid, 0)
        except OSError:
            break
        time.sleep(0.01)
    else:
        raise AssertionError("Detached grandchild did not exit after cleanup")

    assert elapsed < 2.0
    assert exc_info.value.stdout
    assert "parent-ready" in exc_info.value.stdout


def test_ship_subprocess_timeout_is_clamped_after_prior_work(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "auth status" ]]; then
  printf 'authenticated\n'
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  trap 'exit 0' TERM
  while true; do
    sleep 1
  done
fi
exit 0
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    now = [20.0]
    budget = TimeoutBudget(total_timeout_seconds=30, clock=lambda: now[0], started_at=0.0)
    git = GitStateMachine(
        worktree,
        protected_branches=config.protected_branch_list,
        env=config.subprocess_env(),
        timeout_budget=budget,
        logger=logging.getLogger("test-timeout"),
    )
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))
    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")
    shipper = Shipper(config=config, git=git, timeout_budget=budget, logger=logging.getLogger("test-timeout"))

    started = time.monotonic()
    with pytest.raises(ShipError) as exc_info:
        shipper.ship(
            branch_name="nightshift/2026-04-07",
            digest_path=digest_path,
            run_date="2026-04-07",
            smoke=True,
            task_file_count=0,
            total_findings=1,
            dry_run=False,
        )
    elapsed = time.monotonic() - started

    assert isinstance(exc_info.value.__cause__, CommandTimeoutError)
    assert exc_info.value.__cause__.timeout_seconds == pytest.approx(5.0, abs=0.5)
    assert elapsed < 7.0


def test_orchestrator_records_claude_timeout_and_continues_cleanup(
    tmp_path: Path,
    config_factory,
    monkeypatch,
) -> None:
    monkeypatch.setattr(timeout_module, "PROCESS_TERMINATION_GRACE_SECONDS", 0.1)

    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    pid_file = tmp_path / "claude.pid"
    term_file = tmp_path / "claude.term"
    write_executable(
        fake_bin / "claude",
        f"""#!/usr/bin/env bash
set -euo pipefail
echo $$ > "{pid_file}"
trap 'echo TERM >> "{term_file}"' TERM
while true; do
  sleep 1
done
""",
    )
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "auth status" ]]; then
  printf 'authenticated\n'
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "$1 $2" == "label create" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr create" ]]; then
  printf 'https://github.com/example/repo/pull/456\n'
  exit 0
fi
exit 0
""",
    )
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        f'source "{NIGHTSHIFT_DIR / "nightshift.conf"}"\n'
        'NIGHTSHIFT_AGENT_TIMEOUT_SECONDS="1"\n'
        'NIGHTSHIFT_CODEX_MODEL=""\n',
        encoding="utf-8",
    )
    config = config_factory(repo_dir=worktree, conf_path=conf_path, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    budget = TimeoutBudget(120)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    git = GitStateMachine(
        worktree,
        protected_branches=config.protected_branch_list,
        env=config.subprocess_env(),
        timeout_budget=budget,
        logger=logging.getLogger("test-timeout"),
    )
    agents = AgentRunner(
        config=config,
        context=context,
        cost_tracker=tracker,
        timeout_budget=budget,
        logger=logging.getLogger("test-timeout"),
    )
    shipper = Shipper(config=config, git=git, timeout_budget=budget, logger=logging.getLogger("test-timeout"))
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=agents,
        shipper=shipper,
        cost_tracker=tracker,
        timeout_budget=budget,
        logger=logging.getLogger("test-timeout"),
        detective_playbooks=("commit-detective",),
        implemented_detectives=frozenset({"commit-detective"}),
    )

    result = orchestrator.run()

    assert result == 3
    assert any("commit-detective exceeded 1s" in msg for msg in context.warnings)
    assert context.digest_path is not None
    assert context.digest_path.exists()
    assert context.run_branch is not None
    assert context.run_branch.startswith("nightshift/smoke-")
    assert context.ship_blocked_reason == "digest not stageable; no healthy detective runs completed (skipped=1, timeout=1)"
    assert any("Ship blocked: digest not stageable" in msg for msg in context.warnings)
    digest_text = context.digest_path.read_text(encoding="utf-8")
    assert "Nightshift Detective Digest" in digest_text
    show_result = subprocess.run(
        ["git", "show", f"{context.run_branch}:docs/nightshift/digests/{context.run_date}.md"],
        cwd=worktree,
        text=True,
        capture_output=True,
        check=False,
    )
    assert show_result.returncode != 0
    assert "TERM" in term_file.read_text(encoding="utf-8")
    pid = int(pid_file.read_text(encoding="utf-8").strip())
    with pytest.raises(OSError):
        os.kill(pid, 0)

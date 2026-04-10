from __future__ import annotations

import logging
import shutil
import time
from pathlib import Path

from nightshift.detective_status import DetectiveStatus, DetectiveStatusStore
import nightshift.git as git_module
import nightshift.ship as ship_module
import nightshift.timeout as timeout_module

from nightshift.agents import AgentRunResult
from nightshift.cost import CostTracker
from nightshift.git import GitStateMachine
from nightshift.phases import NightshiftOrchestrator
from nightshift.runtime import RunContext
from nightshift.ship import ShipError, ShipResult, Shipper
from nightshift.timeout import TimeoutBudget

from .conftest import create_bare_remote_repo, write_executable


class DummyAgentRunner:
    def run_claude(self, _playbook_name: str) -> AgentRunResult:  # pragma: no cover - not used
        raise AssertionError("not expected")


class RaisingShipper:
    def __init__(self, exc: ShipError) -> None:
        self.exc = exc
        self.updated: list[tuple[int, Path]] = []

    def ship(self, **_kwargs) -> ShipResult:
        raise self.exc

    def update_pr_body(self, *, pr_number: int, digest_path: Path) -> None:
        self.updated.append((pr_number, digest_path))


class RecordingShipper:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []
        self.updated: list[tuple[int, Path]] = []

    def ship(self, **kwargs) -> ShipResult:
        self.calls.append(kwargs)
        return ShipResult(
            committed=False,
            pushed=False,
            pr_created=False,
            pr_updated=False,
            pr_number=None,
            pr_url=None,
            pushed_head=None,
        )

    def update_pr_body(self, *, pr_number: int, digest_path: Path) -> None:
        self.updated.append((pr_number, digest_path))


class RecordingRewriteGit:
    def __init__(self, *, fail_amend: bool = False, fail_push: bool = False) -> None:
        self.fail_amend = fail_amend
        self.fail_push = fail_push
        self.staged_paths: list[tuple[Path, ...]] = []
        self.amend_calls: list[str] = []
        self.force_push_calls: list[tuple[str, str | None]] = []

    def stage_paths(self, paths) -> None:
        self.staged_paths.append(tuple(paths))

    def amend_last_commit(self, *, expected_branch: str) -> None:
        self.amend_calls.append(expected_branch)
        if self.fail_amend:
            raise RuntimeError("amend failed")

    def force_push_branch(self, branch_name: str, *, expected_remote_head: str | None = None) -> str:
        self.force_push_calls.append((branch_name, expected_remote_head))
        if self.fail_push:
            raise RuntimeError("lease rejected")
        return "rewrite-head"


def _prepare_branch(worktree: Path, config, *, timeout_budget: TimeoutBudget | None = None) -> GitStateMachine:
    git = GitStateMachine(
        worktree,
        protected_branches=config.protected_branch_list,
        env=config.subprocess_env(),
        timeout_budget=timeout_budget,
        logger=logging.getLogger("test-ship"),
    )
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))
    return git


def _create_tracker(context: RunContext, config) -> CostTracker:
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    return tracker


def _write_detective_status(
    context: RunContext,
    *,
    playbook: str = "commit-detective",
    engine: str = "claude",
    status: str = "success",
    findings_count: int = 1,
) -> None:
    DetectiveStatusStore(context.detective_status_dir).write(
        DetectiveStatus(
            playbook=playbook,
            engine=engine,
            status=status,
            duration_seconds=5,
            findings_count=findings_count,
            cost_usd="0.1000",
        )
    )


def test_digest_reflects_ship_failure(tmp_path: Path, config_factory, monkeypatch) -> None:
    real_git = shutil.which("git")
    assert real_git is not None

    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    term_file = tmp_path / "git-push.term"
    write_executable(
        fake_bin / "git",
        f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "${{1:-}}" == "push" ]]; then
  trap 'echo TERM >> "{term_file}"' TERM
  while true; do sleep 1; done
fi
exec "{real_git}" "$@"
""",
    )
    monkeypatch.setattr(timeout_module, "PROCESS_TERMINATION_GRACE_SECONDS", 0.1)
    monkeypatch.setattr(git_module, "GIT_NETWORK_TIMEOUT_SECONDS", 0.2)
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = _create_tracker(context, config)
    budget = TimeoutBudget(10)
    git = _prepare_branch(worktree, config, timeout_budget=budget)
    shipper = Shipper(config=config, git=git, timeout_budget=budget, logger=logging.getLogger("test-ship"))
    digest_path = context.repo_digest_path
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")
    context.digest_path = digest_path
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,
        cost_tracker=tracker,
        timeout_budget=budget,
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    digest_text = digest_path.read_text(encoding="utf-8")
    assert "- **Outcome:** failed" in digest_text
    assert "- **Phase Reached:** Ship Results" in digest_text
    assert "Command timed out after 0.2s" in digest_text
    assert "TERM" in term_file.read_text(encoding="utf-8")


def test_pr_creation_failure_logged(tmp_path: Path, config_factory) -> None:
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
  printf '[]\n'
  exit 0
fi
if [[ "$1 $2" == "label create" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr create" ]]; then
  printf 'boom\n' >&2
  exit 1
fi
exit 0
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = _create_tracker(context, config)
    git = _prepare_branch(worktree, config)
    shipper = Shipper(config=config, git=git)
    digest_path = context.repo_digest_path
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")
    context.digest_path = digest_path
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert any("boom" in failure for failure in context.failures)
    assert "boom" in digest_path.read_text(encoding="utf-8")


def test_pr_creation_timeout_logged_without_hanging(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    term_file = tmp_path / "gh-pr.term"
    write_executable(
        fake_bin / "gh",
        f"""#!/usr/bin/env bash
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
  trap 'echo TERM >> "{term_file}"' TERM
  while true; do sleep 1; done
fi
exit 0
""",
    )
    monkeypatch.setattr(timeout_module, "PROCESS_TERMINATION_GRACE_SECONDS", 0.1)
    monkeypatch.setattr(ship_module, "GH_PR_CREATE_TIMEOUT_SECONDS", 0.2)
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = _create_tracker(context, config)
    budget = TimeoutBudget(10)
    git = _prepare_branch(worktree, config, timeout_budget=budget)
    shipper = Shipper(config=config, git=git, timeout_budget=budget, logger=logging.getLogger("test-ship"))
    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")
    context.digest_path = digest_path
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,
        cost_tracker=tracker,
        timeout_budget=budget,
        logger=logging.getLogger("test-ship"),
    )

    started = time.monotonic()
    orchestrator.phase_ship()
    elapsed = time.monotonic() - started

    assert elapsed < 1.0
    assert any("Command timed out" in failure for failure in context.failures)
    assert "TERM" in term_file.read_text(encoding="utf-8")


def test_phase_ship_skips_when_digest_not_stageable(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.digest_path.write_text("# Raw invalid digest\n", encoding="utf-8")
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = False
    _write_detective_status(context)
    shipper = RecordingShipper()
    rewrite_git = RecordingRewriteGit()
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert shipper.calls == []
    assert rewrite_git.staged_paths == []
    assert context.ship_blocked_reason == "digest not stageable"
    assert context.exit_code == 3
    assert any("Ship blocked: digest not stageable" in warning for warning in context.warnings)


def test_phase_ship_rewrite_push_uses_explicit_lease(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context)
    rewrite_git = RecordingRewriteGit()
    shipper = RaisingShipper(
        ShipError(
            "gh pr create timed out",
            partial_result=ShipResult(
                committed=True,
                pushed=True,
                pr_created=False,
                pr_updated=False,
                pr_number=321,
                pr_url="https://github.com/example/repo/pull/321",
                pushed_head="commit-a",
            ),
        )
    )
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert rewrite_git.amend_calls == ["nightshift/2026-04-07"]
    assert rewrite_git.force_push_calls == [("nightshift/2026-04-07", "commit-a")]
    assert shipper.updated == [(321, context.repo_digest_path)]
    assert any("gh pr create timed out" in failure for failure in context.failures)
    assert "gh pr create timed out" in context.repo_digest_path.read_text(encoding="utf-8")


def test_rewrite_amend_failure_records_failure_skips_pr_refresh(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context)
    rewrite_git = RecordingRewriteGit(fail_amend=True)
    shipper = RaisingShipper(
        ShipError(
            "gh auth status failed",
            partial_result=ShipResult(
                committed=True,
                pushed=True,
                pr_created=False,
                pr_updated=False,
                pr_number=654,
                pr_url="https://github.com/example/repo/pull/654",
                pushed_head="commit-a",
            ),
        )
    )
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    digest_text = context.repo_digest_path.read_text(encoding="utf-8")
    assert rewrite_git.amend_calls == ["nightshift/2026-04-07"]
    assert rewrite_git.force_push_calls == []
    assert shipper.updated == []
    assert any("gh auth status failed" in failure for failure in context.failures)
    assert any("Failed to rewrite shipped digest: amend failed" in failure for failure in context.failures)
    assert "gh auth status failed" in digest_text
    assert "Failed to rewrite shipped digest: amend failed" not in digest_text


def test_phase_ship_skips_pr_refresh_when_rewrite_push_fails(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context)
    rewrite_git = RecordingRewriteGit(fail_push=True)
    shipper = RaisingShipper(
        ShipError(
            "gh auth status failed",
            partial_result=ShipResult(
                committed=True,
                pushed=True,
                pr_created=False,
                pr_updated=False,
                pr_number=654,
                pr_url="https://github.com/example/repo/pull/654",
                pushed_head="commit-a",
            ),
        )
    )
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert shipper.updated == []
    assert any("Failed to rewrite shipped digest: lease rejected" in failure for failure in context.failures)


def test_ship_blocked_when_all_detectives_failed(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.digest_path.write_text("# Digest\n", encoding="utf-8")
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context, status="timeout", findings_count=0)
    _write_detective_status(
        context,
        playbook="coverage-detective",
        engine="codex",
        status="error",
        findings_count=0,
    )
    shipper = RecordingShipper()
    rewrite_git = RecordingRewriteGit()
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert shipper.calls == []
    assert rewrite_git.staged_paths == []
    assert context.ship_blocked_reason == "no healthy detective runs completed (error=1, timeout=1)"
    assert context.exit_code == 3
    assert any("Ship blocked: no healthy detective runs completed" in warning for warning in context.warnings)


def test_ship_blocked_when_cost_cap_hit(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.digest_path.write_text("# Digest\n", encoding="utf-8")
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    context.cost_cap_hit = True
    _write_detective_status(context)
    shipper = RecordingShipper()
    rewrite_git = RecordingRewriteGit()
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert shipper.calls == []
    assert context.ship_blocked_reason == "cost cap hit"
    assert context.exit_code == 2
    assert context.failures == []
    assert any("Ship blocked: cost cap hit" in warning for warning in context.warnings)


def test_ship_allowed_with_zero_findings_from_healthy_detectives(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.digest_path.write_text("# Digest\n", encoding="utf-8")
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    context.total_findings_available = 0
    _write_detective_status(context, status="no_findings", findings_count=0)
    shipper = RecordingShipper()
    rewrite_git = RecordingRewriteGit()
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert context.ship_blocked_reason is None
    assert context.exit_code == 0
    assert shipper.calls == [{
        "branch_name": "nightshift/2026-04-07",
        "digest_path": context.repo_digest_path,
        "run_date": context.run_date,
        "smoke": False,
        "task_file_count": 0,
        "total_findings": 0,
        "dry_run": False,
    }]


def test_ship_allowed_with_partial_detective_success(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.digest_path.write_text("# Digest\n", encoding="utf-8")
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    _write_detective_status(context, status="success")
    _write_detective_status(
        context,
        playbook="coverage-detective",
        engine="codex",
        status="timeout",
        findings_count=0,
    )
    shipper = RecordingShipper()
    rewrite_git = RecordingRewriteGit()
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert context.ship_blocked_reason is None
    assert shipper.calls


def test_phase_ship_ignores_non_gating_failures_when_health_is_otherwise_good(
    tmp_path: Path,
    config_factory,
) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = _create_tracker(context, config)
    context.digest_path = context.repo_digest_path
    context.digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.digest_path.write_text("# Digest\n", encoding="utf-8")
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-07"
    context.digest_stageable = True
    context.add_failure("validation rejected one task")
    _write_detective_status(context)
    shipper = RecordingShipper()
    rewrite_git = RecordingRewriteGit()
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=rewrite_git,  # type: ignore[arg-type]
        agents=DummyAgentRunner(),  # type: ignore[arg-type]
        shipper=shipper,  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(10),
        logger=logging.getLogger("test-ship"),
    )

    orchestrator.phase_ship()

    assert context.ship_blocked_reason is None
    assert shipper.calls
    assert context.exit_code == 1


def test_run_health_check_returns_reason(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    context = RunContext.create(config, dry_run=False, smoke=False)
    context.digest_stageable = False
    context.manager_contract_failed = True
    _write_detective_status(context, status="timeout", findings_count=0)

    shippable, reason = context.run_health_check()

    assert shippable is False
    assert reason == (
        "digest not stageable; manager contract failed; "
        "no healthy detective runs completed (timeout=1)"
    )

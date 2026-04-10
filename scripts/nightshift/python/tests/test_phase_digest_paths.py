from __future__ import annotations

import logging
from pathlib import Path

from nightshift.detective_status import DetectiveStatus, DetectiveStatusStore
from nightshift.ship import ShipResult

from .test_phases import ScriptedAgentRunner, create_orchestrator


class FailingSetupGit:
    def bootstrap_run_branch(self, *, base_branch: str, branch_name: str) -> str:
        raise RuntimeError(f"git fetch failed for {base_branch}")

    def checkout_branch(self, _branch_name: str) -> None:
        pass


class BranchReadyGit:
    def __init__(self) -> None:
        self.bootstrap_calls: list[tuple[str, str]] = []

    def bootstrap_run_branch(self, *, base_branch: str, branch_name: str) -> str:
        self.bootstrap_calls.append((base_branch, branch_name))
        return branch_name

    def checkout_branch(self, _branch_name: str) -> None:
        pass


class RecordingShipper:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

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


def _write_detective_status(context) -> None:
    DetectiveStatusStore(context.detective_status_dir).write(
        DetectiveStatus(
            playbook="commit-detective",
            engine="claude",
            status="success",
            duration_seconds=5,
            findings_count=1,
            cost_usd="0.1000",
        )
    )


def test_setup_failure_writes_digest_to_temp_not_repo(tmp_path: Path, config_factory) -> None:
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=ScriptedAgentRunner(),
        git=FailingSetupGit(),
    )

    exit_code = orchestrator.run()

    assert exit_code == 1
    assert context.branch_created is False
    assert context.digest_path == context.temp_digest_path
    assert context.temp_digest_path.exists()
    assert not context.repo_digest_path.exists()
    assert "git fetch failed" in context.temp_digest_path.read_text(encoding="utf-8")


def test_successful_setup_enables_repo_digest(tmp_path: Path, config_factory) -> None:
    git = BranchReadyGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=ScriptedAgentRunner(),
        git=git,
    )

    orchestrator.phase_setup()
    orchestrator.write_digest(phase_reached="Setup")

    assert git.bootstrap_calls
    assert context.branch_created is True
    assert context.digest_path == context.repo_digest_path
    assert context.repo_digest_path.exists()
    assert not context.temp_digest_path.exists()


def test_ship_copies_temp_digest_to_repo(tmp_path: Path, config_factory) -> None:
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=ScriptedAgentRunner(),
    )
    shipper = RecordingShipper()
    orchestrator.shipper = shipper  # type: ignore[assignment]
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-09"
    context.digest_stageable = True
    context.digest_path = context.temp_digest_path
    context.temp_digest_path.write_text("# Temp digest\n", encoding="utf-8")
    _write_detective_status(context)

    orchestrator.phase_ship()

    assert context.repo_digest_path.exists()
    assert context.repo_digest_path.read_text(encoding="utf-8") == "# Temp digest\n"
    assert context.digest_path == context.repo_digest_path
    assert shipper.calls == [{
        "branch_name": "nightshift/2026-04-09",
        "digest_path": context.repo_digest_path,
        "run_date": context.run_date,
        "smoke": False,
        "task_file_count": 0,
        "total_findings": 0,
        "dry_run": False,
    }]

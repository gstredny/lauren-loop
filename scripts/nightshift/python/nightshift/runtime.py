from __future__ import annotations

import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .config import NightshiftConfig
from .detective_status import DetectiveStatusStore


HEALTHY_DETECTIVE_STATUSES = frozenset({"success", "no_findings"})


@dataclass
class RunContext:
    config: NightshiftConfig
    dry_run: bool
    smoke: bool
    run_date: str
    run_clock: str
    run_id: str
    run_tmp_dir: Path
    raw_findings_dir: Path
    agent_output_dir: Path
    detective_status_dir: Path
    rendered_dir: Path
    cost_state_file: Path
    started_at: datetime
    current_phase: str = "bootstrap"
    run_branch: str | None = None
    digest_path: Path | None = None
    pr_url: str | None = None
    ship_blocked_reason: str | None = None
    cost_cap_hit: bool = False
    branch_created: bool = False
    total_findings_available: int = 0
    task_file_count: int = 0
    manager_contract_failed: bool = False
    digest_stageable: bool = False
    validated_tasks: list[Path] = field(default_factory=list)
    autofix_results: list[dict[str, object]] = field(default_factory=list)
    bridge_results: list[dict[str, object]] = field(default_factory=list)
    backlog_results: list[dict[str, object]] = field(default_factory=list)
    bridge_task_paths: list[Path] = field(default_factory=list)
    autofix_halted: bool = False
    autofix_halt_reason: str = ""
    warnings: list[str] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)

    @classmethod
    def create(
        cls,
        config: NightshiftConfig,
        *,
        dry_run: bool,
        smoke: bool,
        now: datetime | None = None,
    ) -> "RunContext":
        timestamp = now or datetime.now()
        run_date = timestamp.strftime("%Y-%m-%d")
        run_clock = timestamp.strftime("%H%M%S%f")
        run_id = f"{run_date}-{run_clock}-{os.getpid()}"
        run_tmp_dir = Path(f"/tmp/nightshift-{run_id}")
        raw_findings_dir = run_tmp_dir / "raw-findings"
        agent_output_dir = run_tmp_dir / "agent-outputs"
        detective_status_dir = run_tmp_dir / "detective-status"
        rendered_dir = run_tmp_dir / "rendered"
        cost_state_file = run_tmp_dir / "cost-state.json"

        context = cls(
            config=config,
            dry_run=dry_run,
            smoke=smoke,
            run_date=run_date,
            run_clock=run_clock,
            run_id=run_id,
            run_tmp_dir=run_tmp_dir,
            raw_findings_dir=raw_findings_dir,
            agent_output_dir=agent_output_dir,
            detective_status_dir=detective_status_dir,
            rendered_dir=rendered_dir,
            cost_state_file=cost_state_file,
            started_at=timestamp,
        )
        context.ensure_directories()
        return context

    def ensure_directories(self) -> None:
        self.run_tmp_dir.mkdir(parents=True, exist_ok=True)
        self.raw_findings_dir.mkdir(parents=True, exist_ok=True)
        self.agent_output_dir.mkdir(parents=True, exist_ok=True)
        self.detective_status_dir.mkdir(parents=True, exist_ok=True)
        self.rendered_dir.mkdir(parents=True, exist_ok=True)
        self.config.log_dir.mkdir(parents=True, exist_ok=True)
        self.config.findings_dir.mkdir(parents=True, exist_ok=True)

    def clear_findings_dir(self) -> None:
        """Clear shared canonical findings only after the PID lock is held."""
        self.config.findings_dir.mkdir(parents=True, exist_ok=True)
        for stale_entry in self.config.findings_dir.glob("*"):
            if stale_entry.is_file():
                stale_entry.unlink()

    def add_warning(self, message: str) -> None:
        self.warnings.append(message)

    def add_failure(self, message: str) -> None:
        self.failures.append(message)

    def run_health_check(self) -> tuple[bool, str]:
        reasons: list[str] = []

        if not self.digest_stageable:
            reasons.append("digest not stageable")
        if self.manager_contract_failed:
            reasons.append("manager contract failed")
        if self.cost_cap_hit:
            reasons.append("cost cap hit")

        detective_statuses = DetectiveStatusStore(self.detective_status_dir).read_all()
        healthy_detective_count = sum(
            1 for status in detective_statuses if status.status in HEALTHY_DETECTIVE_STATUSES
        )
        if healthy_detective_count == 0:
            if detective_statuses:
                status_counts: dict[str, int] = {}
                for status in detective_statuses:
                    status_counts[status.status] = status_counts.get(status.status, 0) + 1
                summary = ", ".join(f"{name}={status_counts[name]}" for name in sorted(status_counts))
                reasons.append(f"no healthy detective runs completed ({summary})")
            else:
                reasons.append("no healthy detective runs completed (no statuses recorded)")

        if reasons:
            return False, "; ".join(reasons)
        return True, "run healthy for shipping"

    @property
    def repo_digest_path(self) -> Path:
        return self.config.repo_dir / "docs/nightshift/digests" / f"{self.run_date}.md"

    @property
    def temp_digest_path(self) -> Path:
        return self.run_tmp_dir / "digest.md"

    @property
    def live_digest_path(self) -> Path:
        return self.repo_digest_path if self.branch_created else self.temp_digest_path

    @property
    def writable_digest_path(self) -> Path:
        return self.dry_run_digest_path if self.dry_run else self.live_digest_path

    @property
    def findings_manifest_path(self) -> Path:
        return self.run_tmp_dir / "findings-manifest.txt"

    @property
    def manager_task_manifest_path(self) -> Path:
        return self.run_tmp_dir / "manager-task-manifest.txt"

    @property
    def dry_run_digest_path(self) -> Path:
        return self.run_tmp_dir / "dry-run-digest.md"

    @property
    def mode_label(self) -> str:
        return "dry-run" if self.dry_run else "live"

    @property
    def exit_code(self) -> int:
        if self.cost_cap_hit:
            return 2
        if self.ship_blocked_reason:
            return 3
        return 1 if self.failures else 0

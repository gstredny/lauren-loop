from __future__ import annotations

import argparse
import logging
import signal
from pathlib import Path

from .agents import AgentRunner
from .config import NightshiftConfig
from .cost import CostTracker
from .git import GitStateMachine
from .lock import LockError, PidLock
from .phases import NightshiftOrchestrator
from .runtime import RunContext
from .ship import Shipper
from .subprocess_runner import terminate_active_process_groups
from .timeout import TimeoutBudget


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Night Shift Python orchestrator")
    parser.add_argument("--dry-run", action="store_true", help="Skip commit, push, and PR creation")
    parser.add_argument("--smoke", action="store_true", help="Run the one-detective smoke path")
    parser.add_argument(
        "--force-direct",
        action="store_true",
        help="Allow a live direct run from the current checkout without branch safety enforcement",
    )
    return parser


def configure_logging() -> logging.Logger:
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] [nightshift-python] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    return logging.getLogger("nightshift")


def _refuses_live_checkout(*, config: NightshiftConfig, dry_run: bool, force_direct: bool) -> str | None:
    if dry_run or force_direct:
        return None

    git = GitStateMachine(
        repo_dir=config.repo_dir,
        protected_branches=config.protected_branch_list,
        env=config.subprocess_env(),
    )
    if not git.is_repo():
        return None

    current_branch = git.current_branch()
    if current_branch == "" or current_branch.startswith("nightshift/"):
        return None
    return current_branch


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    logger = configure_logging()

    config = NightshiftConfig.load()
    try:
        refused_branch = _refuses_live_checkout(
            config=config,
            dry_run=args.dry_run,
            force_direct=args.force_direct,
        )
    except Exception as exc:
        logger.error("FATAL: Could not inspect current git branch: %s", exc)
        return 1
    if refused_branch is not None:
        logger.error(
            "FATAL: Night Shift must not run on branch '%s'. Use nightshift-bootstrap.sh or run from a detached checkout.",
            refused_branch,
        )
        return 1

    context = RunContext.create(config, dry_run=args.dry_run, smoke=args.smoke)
    lock = PidLock(Path("/tmp/nightshift.lock"))

    try:
        lock.acquire()
    except LockError as exc:
        logger.error("%s", exc)
        return 1

    # Shared findings live outside the per-run temp dir, so clearing them must happen
    # only after lock arbitration to prevent concurrent starts from both deleting them.
    context.clear_findings_dir()

    original_handlers: dict[int, signal.Handlers] = {}

    def handle_signal(signum: int, _frame: object) -> None:
        logger.warning("Received signal %s; terminating active Nightshift child process groups", signum)
        terminate_active_process_groups(logger=logger)
        lock.release()
        raise SystemExit(1)

    for sig in (signal.SIGINT, signal.SIGTERM):
        original_handlers[sig] = signal.getsignal(sig)
        signal.signal(sig, handle_signal)

    timeout_budget = TimeoutBudget(config.total_timeout_seconds)
    git = GitStateMachine(
        repo_dir=config.repo_dir,
        protected_branches=config.protected_branch_list,
        env=config.subprocess_env(),
        timeout_budget=timeout_budget,
        logger=logger,
    )
    cost_tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    agents = AgentRunner(
        config=config,
        context=context,
        cost_tracker=cost_tracker,
        timeout_budget=timeout_budget,
        logger=logger,
    )
    shipper = Shipper(config=config, git=git, timeout_budget=timeout_budget, logger=logger)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=agents,
        shipper=shipper,
        cost_tracker=cost_tracker,
        timeout_budget=timeout_budget,
        logger=logger,
    )

    try:
        orchestrator.run()
        return context.exit_code
    finally:
        for sig, handler in original_handlers.items():
            signal.signal(sig, handler)
        lock.release()

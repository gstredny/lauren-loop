from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

import nightshift.autofix as autofix_helpers
import nightshift.phases as phases_module
from nightshift.agents import AgentExecutionError, AgentRunResult, AgentRunner, AgentTimeoutError
from nightshift.cost import CostTracker
from nightshift.detective_status import DetectiveStatusStore
from nightshift.git import GitStateMachine
from nightshift.phases import NightshiftOrchestrator
from nightshift.runtime import RunContext
from nightshift.timeout import TimeoutBudget

from .conftest import create_bare_remote_repo, run, write_executable


class ScriptedAgentRunner:
    def __init__(
        self,
        scripted: dict[tuple[str, str], AgentRunResult | Exception] | None = None,
        *,
        clock_ref: list[float] | None = None,
        increment: int = 0,
        side_effects: dict[str, callable] | None = None,
    ) -> None:
        self.scripted = scripted or {}
        self.clock_ref = clock_ref
        self.increment = increment
        self.calls: list[str] = []
        self.call_kwargs: list[tuple[str, str, dict[str, object]]] = []
        self.side_effects = side_effects or {}

    def run_claude(self, playbook_name: str, **kwargs) -> AgentRunResult:
        return self._run("claude", playbook_name, **kwargs)

    def run_codex(self, playbook_name: str) -> AgentRunResult:
        return self._run("codex", playbook_name)

    def _run(self, engine: str, playbook_name: str, **kwargs) -> AgentRunResult:
        self.calls.append(f"{engine}/{playbook_name}")
        self.call_kwargs.append((engine, playbook_name, kwargs))
        if self.clock_ref is not None:
            self.clock_ref[0] += self.increment
        if playbook_name in self.side_effects:
            self.side_effects[playbook_name]()
        outcome = self.scripted.get((engine, playbook_name))
        if isinstance(outcome, Exception):
            raise outcome
        return outcome or build_result(engine, playbook_name)


class RecordingDelegatingAgentRunner:
    def __init__(self, delegate: AgentRunner) -> None:
        self.delegate = delegate
        self.calls: list[str] = []
        self.claude_execution_errors: list[tuple[str, AgentExecutionError]] = []

    def run_claude(self, playbook_name: str, **kwargs) -> AgentRunResult:
        self.calls.append(f"claude/{playbook_name}")
        try:
            return self.delegate.run_claude(playbook_name, **kwargs)
        except AgentExecutionError as exc:
            self.claude_execution_errors.append((playbook_name, exc))
            raise

    def run_codex(self, playbook_name: str) -> AgentRunResult:
        self.calls.append(f"codex/{playbook_name}")
        return self.delegate.run_codex(playbook_name)


def build_result(
    engine: str,
    playbook_name: str,
    *,
    status: str = "success",
    findings_count: int = 1,
    duration_seconds: int = 5,
    cost_usd: str = "0.1000",
    return_code: int = 0,
) -> AgentRunResult:
    return AgentRunResult(
        engine=engine,
        playbook_name=playbook_name,
        output_path=Path(f"/tmp/{engine}-{playbook_name}.json"),
        stderr_log_path=Path(f"/tmp/{engine}-{playbook_name}-stderr.log"),
        archived_findings_path=None,
        findings_count=findings_count,
        duration_seconds=duration_seconds,
        cost_usd=cost_usd,
        status=status,
        return_code=return_code,
    )


def write_claude_result(playbook_name: str, result_text: str) -> None:
    output_path = Path(f"/tmp/claude-{playbook_name}.json")
    output_path.write_text(json.dumps({"result": result_text}) + "\n", encoding="utf-8")


def extract_existing_open_tasks_block(prompt_path: Path) -> str:
    capture = False
    lines: list[str] = []
    for line in prompt_path.read_text(encoding="utf-8").splitlines():
        if line == "## Existing Open Tasks":
            capture = True
        if not capture:
            continue
        if line == "```":
            break
        lines.append(line)
    return "\n".join(lines)


class ScriptedGit:
    def __init__(self, repo_dir: Path | None = None) -> None:
        self.repo_dir = repo_dir
        self.staged_paths: list[Path] = []
        self.snapshot_values: list[str | None] = []
        self.changed_file_values: list[list[str]] = []
        self.untracked_file_values: list[list[str]] = []
        self.restored_tracked_calls: list[tuple[list[str], str | None]] = []
        self.removed_untracked_calls: list[list[str]] = []
        self.checkout_calls: list[str] = []

    def stage_paths(self, paths) -> None:
        self.staged_paths.extend(Path(path) for path in paths)

    def snapshot_tree_state(self) -> str | None:
        if self.snapshot_values:
            return self.snapshot_values.pop(0)
        return None

    def list_changed_files(self, left_ref, right_ref) -> list[str]:
        if self.changed_file_values:
            return self.changed_file_values.pop(0)
        return []

    def list_untracked_files(self) -> list[str]:
        if self.untracked_file_values:
            return self.untracked_file_values.pop(0)
        return []

    def restore_tracked_paths(self, paths, *, source_ref=None) -> None:
        self.restored_tracked_calls.append((list(paths), source_ref))

    def remove_untracked_paths(self, paths) -> None:
        self.removed_untracked_calls.append(list(paths))

    def checkout_branch(self, branch_name: str) -> None:
        self.checkout_calls.append(branch_name)


def create_orchestrator(
    tmp_path: Path,
    config_factory,
    *,
    runner: ScriptedAgentRunner,
    git=None,
    dry_run: bool = False,
    smoke: bool = False,
    detective_playbooks: tuple[str, ...] | None = None,
    extra_env: dict[str, str] | None = None,
    timeout_budget: TimeoutBudget | None = None,
) -> tuple[NightshiftOrchestrator, RunContext]:
    config = config_factory(repo_dir=tmp_path, extra_env=extra_env)
    context = RunContext.create(config, dry_run=dry_run, smoke=smoke)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    git_obj = git or ScriptedGit()
    if getattr(git_obj, "repo_dir", None) is None:
        git_obj.repo_dir = tmp_path  # type: ignore[attr-defined]
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git_obj,  # type: ignore[arg-type]
        agents=runner,  # type: ignore[arg-type]
        shipper=object(),  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=timeout_budget or TimeoutBudget(None),
        logger=logging.getLogger("test-phases"),
        detective_playbooks=detective_playbooks,
    )
    return orchestrator, context


def test_full_dispatch_order(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner)

    orchestrator.phase_detectives()

    expected = [f"codex/{playbook}" for playbook in orchestrator.detective_playbooks]
    assert runner.calls == expected
    assert context.total_findings_available == len(expected)
    assert len(list(context.detective_status_dir.glob("*.json"))) == len(expected)


def test_full_dispatch_order_with_claude_enabled(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        extra_env={"NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED": "true"},
    )

    orchestrator.phase_detectives()

    expected = [
        f"{engine}/{playbook}"
        for playbook in orchestrator.detective_playbooks
        for engine in ("claude", "codex")
    ]
    assert runner.calls == expected
    assert context.total_findings_available == len(expected)
    assert len(list(context.detective_status_dir.glob("*.json"))) == len(expected)


def test_smoke_only_commit_detective(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, _context = create_orchestrator(tmp_path, config_factory, runner=runner, smoke=True)

    orchestrator.phase_detectives()

    assert runner.calls == ["codex/commit-detective"]


def test_smoke_dry_run_logs_only_codex_commit_detective_by_default(tmp_path: Path, config_factory, caplog) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        dry_run=True,
        smoke=True,
    )

    with caplog.at_level(logging.INFO):
        orchestrator.phase_detectives()

    assert runner.calls == []
    assert "DRY RUN: would run codex/commit-detective" in caplog.messages
    assert "DRY RUN: would run claude/commit-detective" not in caplog.messages
    store = DetectiveStatusStore(context.detective_status_dir)
    assert store.read("commit-detective", "codex").status == "skipped"


def test_smoke_dry_run_logs_both_commit_detective_engines_when_claude_enabled(
    tmp_path: Path,
    config_factory,
    caplog,
) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        dry_run=True,
        smoke=True,
        extra_env={"NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED": "true"},
    )

    with caplog.at_level(logging.INFO):
        orchestrator.phase_detectives()

    assert runner.calls == []
    assert "DRY RUN: would run claude/commit-detective" in caplog.messages
    assert "DRY RUN: would run codex/commit-detective" in caplog.messages
    store = DetectiveStatusStore(context.detective_status_dir)
    assert store.read("commit-detective", "claude").status == "skipped"
    assert store.read("commit-detective", "codex").status == "skipped"


def test_detective_failure_continues_loop(tmp_path: Path, config_factory) -> None:
    failure = AgentTimeoutError(
        "conversation-detective exceeded 1s",
        partial_result=build_result(
            "claude",
            "conversation-detective",
            status="timeout",
            findings_count=0,
            duration_seconds=1,
            cost_usd="0.0500",
            return_code=124,
        ),
    )
    runner = ScriptedAgentRunner(scripted={("claude", "conversation-detective"): failure})
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        extra_env={"NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED": "true"},
    )

    orchestrator.phase_detectives()

    assert runner.calls[-1] == "codex/performance-detective"
    store = DetectiveStatusStore(context.detective_status_dir)
    assert store.read("conversation-detective", "claude").status == "timeout"
    assert any("conversation-detective exceeded 1s" in message for message in context.warnings)


def test_detective_claude_error_max_turns_records_error_and_continues_later_slots(
    tmp_path: Path,
    config_factory,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    claude_call_count_file = tmp_path / "claude-call-count.txt"
    codex_call_count_file = tmp_path / "codex-call-count.txt"
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
count_file="$FAKE_CLAUDE_CALL_COUNT_FILE"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
if [ "$count" -eq 1 ]; then
  printf '{"subtype":"error_max_turns","usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"too many turns"}\n'
  exit 0
fi
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/coverage-detective-findings.md" <<'EOF'
### Finding: Claude coverage finding
EOF
printf '{"subtype":"message_stop","usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"coverage complete"}\n'
""",
    )
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
count_file="$FAKE_CODEX_CALL_COUNT_FILE"
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
if [ "$count" -eq 1 ]; then
  target="conversation-detective-findings.md"
else
  target="coverage-detective-findings.md"
fi
cat > "$NIGHTSHIFT_FINDINGS_DIR/$target" <<'EOF'
### Finding: Codex finding
EOF
printf '{"ok":true}\n'
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={
            "AZURE_OPENAI_API_KEY": "test-key",
            "NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED": "true",
            "FAKE_CLAUDE_CALL_COUNT_FILE": str(claude_call_count_file),
            "FAKE_CODEX_CALL_COUNT_FILE": str(codex_call_count_file),
        },
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    delegate = AgentRunner(config=config, context=context, cost_tracker=tracker)
    runner = RecordingDelegatingAgentRunner(delegate)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=object(),  # type: ignore[arg-type]
        agents=runner,  # type: ignore[arg-type]
        shipper=object(),  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(None),
        logger=logging.getLogger("test-phases"),
        detective_playbooks=("conversation-detective", "coverage-detective"),
    )

    orchestrator.phase_detectives()

    assert [playbook for playbook, _exc in runner.claude_execution_errors] == ["conversation-detective"]
    assert "error_max_turns" in str(runner.claude_execution_errors[0][1])
    assert runner.calls == [
        "claude/conversation-detective",
        "codex/conversation-detective",
        "claude/coverage-detective",
        "codex/coverage-detective",
    ]
    store = DetectiveStatusStore(context.detective_status_dir)
    assert store.read("conversation-detective", "claude").status == "error"
    assert store.read("conversation-detective", "codex").status == "success"
    assert store.read("coverage-detective", "claude").status == "success"
    assert store.read("coverage-detective", "codex").status == "success"
    assert any("error_max_turns" in message for message in context.warnings)


def test_codex_gate_skips_after_failure(tmp_path: Path, config_factory) -> None:
    failure = AgentExecutionError(
        "Codex conversation-detective failed with exit 1",
        partial_result=build_result(
            "codex",
            "conversation-detective",
            status="error",
            findings_count=0,
            duration_seconds=3,
            cost_usd="0.0500",
            return_code=1,
        ),
    )
    runner = ScriptedAgentRunner(scripted={("codex", "conversation-detective"): failure})
    playbooks = (
        "commit-detective",
        "conversation-detective",
        "coverage-detective",
        "error-detective",
        "product-detective",
        "rcfa-detective",
        "security-detective",
        "performance-detective",
    )
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        detective_playbooks=playbooks,
        extra_env={"NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED": "true"},
    )

    orchestrator.phase_detectives()

    assert runner.calls == [
        "claude/commit-detective",
        "codex/commit-detective",
        "claude/conversation-detective",
        "codex/conversation-detective",
        "claude/coverage-detective",
        "claude/error-detective",
        "claude/product-detective",
        "claude/rcfa-detective",
        "claude/security-detective",
        "claude/performance-detective",
    ]
    store = DetectiveStatusStore(context.detective_status_dir)
    assert store.read("coverage-detective", "codex").status == "skipped"


def test_missing_context_guard_closes_codex_gate_and_skips_later_codex_slots(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Claude finding
EOF
cat > "$NIGHTSHIFT_FINDINGS_DIR/coverage-detective-findings.md" <<'EOF'
### Finding: Claude finding
EOF
printf '{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2},"result":"done"}\n'
""",
    )
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true}\n'
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={
            "AZURE_OPENAI_API_KEY": "",
            "NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED": "true",
        },
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=object(),  # type: ignore[arg-type]
        agents=runner,
        shipper=object(),  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(None),
        logger=logging.getLogger("test-phases"),
        detective_playbooks=("commit-detective", "coverage-detective"),
    )

    orchestrator.phase_detectives()

    store = DetectiveStatusStore(context.detective_status_dir)
    assert store.read("commit-detective", "claude").status == "success"
    assert store.read("commit-detective", "codex").status == "error"
    assert store.read("coverage-detective", "claude").status == "success"
    assert store.read("coverage-detective", "codex").status == "skipped"
    assert any("context-guard.sh is unavailable" in message for message in context.warnings)


def test_global_timeout_skips_remaining(tmp_path: Path, config_factory) -> None:
    now = [0.0]
    runner = ScriptedAgentRunner(clock_ref=now, increment=10)
    budget = TimeoutBudget(total_timeout_seconds=9, clock=lambda: now[0], started_at=0)
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        detective_playbooks=("commit-detective", "coverage-detective"),
        extra_env={
            "NIGHTSHIFT_CODEX_MODEL": "",
            "NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED": "true",
        },
        timeout_budget=budget,
    )

    orchestrator.phase_detectives()

    assert runner.calls == ["claude/commit-detective"]
    store = DetectiveStatusStore(context.detective_status_dir)
    assert store.read("coverage-detective", "claude").status == "skipped_timeout"
    assert store.read("coverage-detective", "codex").status == "skipped_timeout"


def test_dry_run_logs_without_executing(tmp_path: Path, config_factory, caplog) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, dry_run=True)
    expected_slots = len(orchestrator._detective_schedule())

    with caplog.at_level(logging.INFO):
        orchestrator.phase_detectives()

    assert runner.calls == []
    assert len([message for message in caplog.messages if message.startswith("DRY RUN: would run ")]) == expected_slots
    assert len(list(context.detective_status_dir.glob("*.json"))) == expected_slots


# ── Manager Merge phase tests ──────────────────────────────────────────


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
    """Write a raw findings file so rebuild_manager_inputs produces findings."""
    context.raw_findings_dir.mkdir(parents=True, exist_ok=True)
    (context.raw_findings_dir / "claude-commit-detective-findings.md").write_text(
        "### Finding: Auth regression\nEvidence here\n", encoding="utf-8",
    )


def _seed_raw_findings_with_partial(context: RunContext) -> None:
    _seed_raw_findings(context)
    (context.raw_findings_dir / "codex-commit-detective-partial.md").write_text(
        "### Finding: Partial regression\nThis should not reach manager input\n", encoding="utf-8",
    )


def _make_digest_writer(context: RunContext) -> callable:
    """Returns a side-effect callback that writes a valid digest."""
    def write_digest():
        path = context.live_digest_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(SAMPLE_DIGEST.format(date=context.run_date), encoding="utf-8")
    return write_digest


def _seed_findings_manifest(context: RunContext, *rows: tuple[str, str, str, str]) -> None:
    payload = "".join(f"{rank}\t{severity}\t{category}\t{title}\n" for rank, severity, category, title in rows)
    context.findings_manifest_path.write_text(payload, encoding="utf-8")


def _seed_digest_and_findings(context: RunContext) -> None:
    context.digest_path = context.repo_digest_path
    context.repo_digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.repo_digest_path.write_text(SAMPLE_DIGEST.format(date=context.run_date), encoding="utf-8")
    context.config.findings_dir.mkdir(parents=True, exist_ok=True)
    (context.config.findings_dir / "commit-detective-findings.md").write_text(
        "# Normalized commit-detective Findings\n\n"
        "## Detective: commit-detective | status=ran | findings=1\n\n"
        "## Source: claude\n\n"
        "### Finding: Auth regression\n"
        "**Severity:** critical\n",
        encoding="utf-8",
    )


def _write_ranked_digest(
    context: RunContext,
    findings: list[tuple[str, str, str, str]],
) -> None:
    ranked_rows = "\n".join(
        f"| {rank} | {severity} | {category} | {title} |"
        for rank, severity, category, title in findings
    )
    digest_text = (
        f"# Nightshift Detective Digest — {context.run_date}\n\n"
        "## Ranked Findings\n"
        "| # | Severity | Category | Title |\n"
        "|---|----------|----------|-------|\n"
        f"{ranked_rows}\n\n"
        "## Minor & Observation Findings\n"
        "| # | Title | Severity | Category | Source | Evidence |\n"
        "|---|-------|----------|----------|--------|----------|\n"
    )
    context.repo_digest_path.parent.mkdir(parents=True, exist_ok=True)
    context.repo_digest_path.write_text(digest_text, encoding="utf-8")
    context.digest_path = context.repo_digest_path


def _write_backlog_task(
    path: Path,
    *,
    status: str = "not started",
    execution_mode: str = "single-agent",
    depends_on: str | None = None,
) -> Path:
    lines = [
        "## Task: Example",
        f"## Status: {status}",
        "## Created: 2026-04-09",
        f"## Execution Mode: {execution_mode}",
        "",
        "## Goal",
        "Fix it.",
    ]
    if depends_on is not None:
        lines.extend(["", "## Depends On", depends_on])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return path


def _completed_backlog_ranking(
    repo_root: Path,
    rows: list[tuple[int, str, str, str]],
) -> subprocess.CompletedProcess[str]:
    body = "\n".join(
        f"{rank}|{task_path}|{goal}|{complexity}"
        for rank, task_path, goal, complexity in rows
    )
    stdout = "## TASK_LIST\n"
    if body:
        stdout += f"{body}\n"
    return subprocess.CompletedProcess(
        ["bash", str(repo_root / "lauren-loop.sh"), "next"],
        0,
        stdout,
        "",
    )


def _write_scope_triage(task_path: Path, captured_files: list[str]) -> Path:
    triage_path = autofix_helpers.lauren_scope_triage_path(task_path)
    triage_path.parent.mkdir(parents=True, exist_ok=True)
    triage_path.write_text(json.dumps({"captured_files": captured_files}), encoding="utf-8")
    return triage_path


def _write_lauren_manifest(task_path: Path, payload: dict[str, object]) -> Path:
    manifest_path = autofix_helpers.lauren_manifest_path(task_path)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(payload), encoding="utf-8")
    return manifest_path


def test_manager_merge_dry_run(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, dry_run=True)

    orchestrator.phase_manager_merge()

    assert "claude/manager-merge" not in runner.calls
    assert context.digest_path is not None
    assert context.digest_path.exists()
    assert "dry-run-skipped" in context.digest_path.read_text(encoding="utf-8")
    assert context.run_clean is True


def test_manager_merge_no_findings(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )

    orchestrator.phase_manager_merge()

    assert "claude/manager-merge" not in runner.calls
    assert context.digest_path is not None
    assert "no-findings" in context.digest_path.read_text(encoding="utf-8")
    assert context.run_clean is True


def test_manager_merge_agent_failure(tmp_path: Path, config_factory) -> None:
    failure = AgentExecutionError("manager-merge failed with exit 1")
    runner = ScriptedAgentRunner(scripted={("claude", "manager-merge"): failure})
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)

    orchestrator.phase_manager_merge()

    assert "claude/manager-merge" in runner.calls
    assert context.manager_contract_failed is True
    assert context.digest_stageable is True
    assert any("Manager agent failed" in f for f in context.failures)
    assert context.digest_path is not None


def test_manager_timeout_triggers_fallback(tmp_path: Path, config_factory) -> None:
    failure = AgentTimeoutError(
        "manager-merge exceeded 1s",
        partial_result=build_result(
            "claude",
            "manager-merge",
            status="timeout",
            findings_count=0,
            duration_seconds=1,
            cost_usd="0.0500",
            return_code=124,
        ),
    )
    runner = ScriptedAgentRunner(scripted={("claude", "manager-merge"): failure})
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)

    orchestrator.phase_manager_merge()

    assert context.digest_path is not None
    assert "manager-failed" in context.digest_path.read_text(encoding="utf-8")
    assert context.manager_contract_failed is True
    assert context.digest_stageable is True


def test_manager_oserror_triggers_fallback(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner(scripted={("claude", "manager-merge"): OSError("disk full")})
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)

    orchestrator.phase_manager_merge()

    assert context.digest_path is not None
    assert "manager-failed" in context.digest_path.read_text(encoding="utf-8")
    assert context.manager_contract_failed is True
    assert context.digest_stageable is True
    assert any("Manager agent failed" in failure for failure in context.failures)


def test_manager_merge_contract_headings_missing(tmp_path: Path, config_factory) -> None:
    def write_bad_digest():
        path = context.repo_digest_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# Digest\n\n## Ranked Findings\n", encoding="utf-8")

    runner = ScriptedAgentRunner(side_effects={"manager-merge": write_bad_digest})
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-09"

    orchestrator.phase_manager_merge()

    assert context.manager_contract_failed is True
    assert any("missing headings" in f for f in context.failures)


def test_manager_contract_failure_preserves_raw_output(tmp_path: Path, config_factory) -> None:
    raw_digest = "# Digest\n\n## Ranked Findings\n"

    def write_bad_digest():
        path = context.repo_digest_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(raw_digest, encoding="utf-8")

    runner = ScriptedAgentRunner(side_effects={"manager-merge": write_bad_digest})
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-09"

    orchestrator.phase_manager_merge()

    assert context.digest_path == context.repo_digest_path
    assert context.repo_digest_path.read_text(encoding="utf-8") == raw_digest
    assert context.manager_contract_failed is True
    assert context.digest_stageable is False


def test_manager_merge_contract_empty_table(tmp_path: Path, config_factory) -> None:
    def write_empty_table_digest():
        path = context.repo_digest_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "## Ranked Findings\n"
            "| # | Severity | Category | Title |\n"
            "|---|----------|----------|-------|\n\n"
            "## Minor & Observation Findings\n",
            encoding="utf-8",
        )

    runner = ScriptedAgentRunner(side_effects={"manager-merge": write_empty_table_digest})
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-09"

    orchestrator.phase_manager_merge()

    assert context.manager_contract_failed is True
    assert any("empty ranked findings" in f for f in context.failures)


def test_partial_findings_excluded_from_manager_input(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings_with_partial(context)
    runner.side_effects["manager-merge"] = _make_digest_writer(context)

    orchestrator.phase_manager_merge()

    manager_input = (context.config.findings_dir / "commit-detective-findings.md").read_text(encoding="utf-8")
    assert "Auth regression" in manager_input
    assert "Partial regression" not in manager_input


def test_manager_merge_success(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-09"
    runner.side_effects["manager-merge"] = _make_digest_writer(context)

    orchestrator.phase_manager_merge()

    assert "claude/manager-merge" in runner.calls
    assert context.manager_contract_failed is False
    assert context.digest_stageable is True
    assert context.digest_path is not None
    assert context.digest_path.exists()
    # Digest was rewritten with metadata
    digest_text = context.digest_path.read_text(encoding="utf-8")
    assert "## Run Metadata" in digest_text
    assert "## Orchestrator Summary" in digest_text
    # Manifest was written
    assert context.findings_manifest_path.exists()
    manifest = context.findings_manifest_path.read_text(encoding="utf-8")
    assert "critical\tregression\tAuth regression" in manifest


def test_run_does_not_clobber_stageable_manager_digest(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path, config_factory, runner=runner, detective_playbooks=("commit-detective",),
    )
    _seed_raw_findings(context)
    context.branch_created = True
    runner.side_effects["manager-merge"] = _make_digest_writer(context)
    context.run_branch = "nightshift/2026-04-08"
    orchestrator.phase_setup = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_detectives = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_task_writing = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_validation = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_autofix = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_bridge = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_backlog = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_ship = lambda: None  # type: ignore[method-assign]
    orchestrator.phase_cleanup = lambda: None  # type: ignore[method-assign]

    exit_code = orchestrator.run()

    digest_text = context.repo_digest_path.read_text(encoding="utf-8")
    assert exit_code == 0
    assert context.digest_stageable is True
    assert "| 1 | critical | regression | Auth regression |" in digest_text
    assert "- **Outcome:**" not in digest_text


def test_detective_cost_cap_halts_remaining_slots(tmp_path: Path, config_factory) -> None:
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=ScriptedAgentRunner(),
        detective_playbooks=("commit-detective", "coverage-detective"),
    )
    calls: list[str] = []

    def fake_run_detective(engine: str, playbook_name: str) -> AgentRunResult:
        calls.append(f"{engine}/{playbook_name}")
        context.cost_cap_hit = True
        return build_result(engine, playbook_name)

    orchestrator._run_detective = fake_run_detective  # type: ignore[method-assign]

    orchestrator.phase_detectives()

    assert calls == ["codex/commit-detective"]
    assert context.total_findings_available == 1


def test_manager_merge_cost_cap_before_call_writes_fallback_digest(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner)
    context.branch_created = True
    context.run_branch = "nightshift/2026-04-09"
    context.total_findings_available = 2
    context.cost_cap_hit = True

    orchestrator.phase_manager_merge()

    digest_text = context.repo_digest_path.read_text(encoding="utf-8")
    assert runner.calls == []
    assert context.digest_stageable is True
    assert "- **Outcome:** cost-capped" in digest_text


# ── Task Writing / Validation / Autofix phase tests ─────────────────────────


def test_task_writing_happy_path(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=git)
    _seed_digest_and_findings(context)
    _seed_findings_manifest(
        context,
        ("1", "critical", "regression", "Auth regression"),
        ("2", "major", "missing-test", "Coverage gap"),
    )

    task_outputs = [
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Auth regression\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Coverage gap\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
    ]

    def write_task_writer_output() -> None:
        write_claude_result("task-writer", task_outputs.pop(0))

    runner.side_effects["task-writer"] = write_task_writer_output

    orchestrator.phase_task_writing()

    manifest_paths = [
        Path(line.strip())
        for line in context.manager_task_manifest_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert len(manifest_paths) == 2
    assert all(path.exists() for path in manifest_paths)
    assert all(path.name == "task.md" for path in manifest_paths)
    assert context.task_file_count == 2
    assert git.staged_paths == manifest_paths
    assert runner.calls == ["claude/task-writer", "claude/task-writer"]
    assert runner.call_kwargs[0][2]["model"] == orchestrator.config.manager_model
    assert runner.call_kwargs[0][2]["artifact_suffix"] == "rank-1"
    assert runner.call_kwargs[1][2]["artifact_suffix"] == "rank-2"
    assert "Rank: 1" in runner.call_kwargs[0][2]["finding_text"]


def test_task_writing_includes_existing_open_task_context(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=git)
    _seed_digest_and_findings(context)
    _seed_findings_manifest(context, ("1", "critical", "regression", "Auth regression"))
    existing_task = tmp_path / "docs" / "tasks" / "open" / "existing-auth.md"
    existing_task.parent.mkdir(parents=True, exist_ok=True)
    existing_task.write_text("## Task: Existing auth regression\n## Status: not started\n", encoding="utf-8")

    runner.side_effects["task-writer"] = lambda: write_claude_result(
        "task-writer",
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Auth regression\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
    )

    orchestrator.phase_task_writing()

    prompt_path = context.rendered_dir / "task-writer-rank-1.md"
    block = extract_existing_open_tasks_block(prompt_path)
    assert prompt_path.exists()
    assert "docs/tasks/open/existing-auth.md: Existing auth regression [not started]" in block


def test_task_writing_one_rejected(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=ScriptedGit())
    _seed_digest_and_findings(context)
    _seed_findings_manifest(
        context,
        ("1", "critical", "regression", "Auth regression"),
        ("2", "major", "missing-test", "Coverage gap"),
    )

    task_outputs = [
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Auth regression\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
        "### Task Writer Result: REJECTED — duplicate task\n",
    ]
    runner.side_effects["task-writer"] = lambda: write_claude_result("task-writer", task_outputs.pop(0))

    orchestrator.phase_task_writing()

    manifest_lines = [
        line for line in context.manager_task_manifest_path.read_text(encoding="utf-8").splitlines() if line.strip()
    ]
    assert len(manifest_lines) == 1
    assert context.task_file_count == 1


def test_task_writing_unrelated_existing_task_does_not_block_creation(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=git)
    _seed_digest_and_findings(context)
    _seed_findings_manifest(context, ("1", "critical", "regression", "Auth regression"))
    unrelated_task = tmp_path / "docs" / "tasks" / "open" / "unrelated-task.md"
    unrelated_task.parent.mkdir(parents=True, exist_ok=True)
    unrelated_task.write_text(
        "## Task: Unrelated analytics cleanup\n## Status: not started\n",
        encoding="utf-8",
    )

    runner.side_effects["task-writer"] = lambda: write_claude_result(
        "task-writer",
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Auth regression\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
    )

    orchestrator.phase_task_writing()

    manifest_lines = [
        line for line in context.manager_task_manifest_path.read_text(encoding="utf-8").splitlines() if line.strip()
    ]
    prompt_path = context.rendered_dir / "task-writer-rank-1.md"
    block = extract_existing_open_tasks_block(prompt_path)
    assert len(manifest_lines) == 1
    assert "docs/tasks/open/unrelated-task.md: Unrelated analytics cleanup [not started]" in block


def test_task_writing_every_finding_snapshot_has_identical_existing_task_block(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=git)
    _seed_digest_and_findings(context)
    _seed_findings_manifest(
        context,
        ("1", "critical", "regression", "Auth regression"),
        ("2", "major", "missing-test", "Coverage gap"),
    )
    existing_task = tmp_path / "docs" / "tasks" / "open" / "existing-task.md"
    existing_task.parent.mkdir(parents=True, exist_ok=True)
    existing_task.write_text("## Task: Existing task\n## Status: not started\n", encoding="utf-8")

    task_outputs = [
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Auth regression\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Coverage gap\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
    ]
    runner.side_effects["task-writer"] = lambda: write_claude_result("task-writer", task_outputs.pop(0))

    orchestrator.phase_task_writing()

    prompt_one = context.rendered_dir / "task-writer-rank-1.md"
    prompt_two = context.rendered_dir / "task-writer-rank-2.md"
    block_one = extract_existing_open_tasks_block(prompt_one)
    block_two = extract_existing_open_tasks_block(prompt_two)
    assert prompt_one.exists()
    assert prompt_two.exists()
    assert block_one
    assert block_one == block_two
    assert "docs/tasks/open/existing-task.md: Existing task [not started]" in block_one


def test_task_writing_halts_after_cost_cap(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=git)
    _seed_digest_and_findings(context)
    _seed_findings_manifest(
        context,
        ("1", "critical", "regression", "Auth regression"),
        ("2", "major", "missing-test", "Coverage gap"),
    )

    outputs = [
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Auth regression\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Coverage gap\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
    ]

    def write_task_writer_output() -> None:
        if len(runner.calls) == 1:
            context.cost_cap_hit = True
        write_claude_result("task-writer", outputs.pop(0))

    runner.side_effects["task-writer"] = write_task_writer_output

    orchestrator.phase_task_writing()

    manifest_paths = [
        Path(line.strip())
        for line in context.manager_task_manifest_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert runner.calls == ["claude/task-writer"]
    assert context.task_file_count == 1
    assert len(manifest_paths) == 1


def test_task_writing_skips_on_contract_failure(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=ScriptedGit())
    context.manager_contract_failed = True

    orchestrator.phase_task_writing()

    assert runner.calls == []
    assert context.manager_task_manifest_path.exists()
    assert context.manager_task_manifest_path.read_text(encoding="utf-8") == ""


def test_task_writing_dry_run(tmp_path: Path, config_factory, caplog) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
        dry_run=True,
    )
    _seed_findings_manifest(context, ("1", "critical", "regression", "Auth regression"))

    with caplog.at_level(logging.INFO):
        orchestrator.phase_task_writing()

    assert runner.calls == []
    assert any(message.startswith("DRY RUN: would write task for: Auth regression") for message in caplog.messages)
    assert context.manager_task_manifest_path.read_text(encoding="utf-8") == ""


def test_task_writing_budget_exhausted(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
    )
    _seed_findings_manifest(context, ("1", "critical", "regression", "Auth regression"))
    orchestrator._remaining_budget = lambda extra_spend=0.0: 0.0  # type: ignore[method-assign]

    orchestrator.phase_task_writing()

    assert runner.calls == []
    assert context.task_file_count == 0


def test_smoke_mode_caps_tasks_to_one(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        smoke=True,
        extra_env={"NIGHTSHIFT_TASK_WRITER_MAX_TASKS": "5"},
    )
    _seed_digest_and_findings(context)
    _seed_findings_manifest(
        context,
        ("1", "critical", "regression", "Auth regression"),
        ("2", "major", "missing-test", "Coverage gap"),
        ("3", "minor", "style", "Style cleanup"),
        ("4", "major", "reliability", "Retry gap"),
        ("5", "critical", "security", "Auth bypass"),
    )

    runner.side_effects["task-writer"] = lambda: write_claude_result(
        "task-writer",
        (
            "--- BEGIN TASK FILE ---\n"
            "## Task: Auth regression\n"
            "## Status: not started\n"
            "--- END TASK FILE ---\n"
            "### Task Writer Result: CREATED\n"
        ),
    )

    orchestrator.phase_task_writing()

    manifest_lines = [
        line
        for line in context.manager_task_manifest_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    assert len(manifest_lines) == 1
    assert context.task_file_count == 1
    assert runner.calls == ["claude/task-writer"]


def test_validation_happy_path(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=git)
    task_a = tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth" / "task.md"
    task_b = tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-coverage" / "task.md"
    task_a.parent.mkdir(parents=True)
    task_b.parent.mkdir(parents=True)
    task_a.write_text("## Task: Auth regression\n## Goal\nFix auth\n", encoding="utf-8")
    task_b.write_text("## Task: Coverage gap\n## Goal\nAdd coverage\n", encoding="utf-8")
    context.manager_task_manifest_path.write_text(f"{task_a}\n{task_b}\n", encoding="utf-8")

    runner.side_effects["validation-agent"] = lambda: write_claude_result(
        "validation-agent",
        "### Validation Result: VALIDATED\nFailed checks:\n- (none)\n",
    )

    orchestrator.phase_validation()

    assert context.validated_tasks == [task_a, task_b]
    assert "## Validation: VALIDATED" in task_a.read_text(encoding="utf-8")
    assert git.staged_paths == [task_a, task_b]
    assert runner.call_kwargs[0][2]["artifact_suffix"] == task_a.parent.name
    assert runner.call_kwargs[1][2]["artifact_suffix"] == task_b.parent.name


def test_validation_one_invalid(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=ScriptedGit())
    task_a = tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth" / "task.md"
    task_b = tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-coverage" / "task.md"
    task_a.parent.mkdir(parents=True)
    task_b.parent.mkdir(parents=True)
    task_a.write_text("## Task: Auth regression\n## Goal\nFix auth\n", encoding="utf-8")
    task_b.write_text("## Task: Coverage gap\n## Goal\nAdd coverage\n", encoding="utf-8")
    context.manager_task_manifest_path.write_text(f"{task_a}\n{task_b}\n", encoding="utf-8")

    validation_outputs = [
        "### Validation Result: VALIDATED\nFailed checks:\n- (none)\n",
        "### Validation Result: INVALID\nFailed checks:\n- INVALID:path — missing.py not found\n",
    ]
    runner.side_effects["validation-agent"] = lambda: write_claude_result(
        "validation-agent",
        validation_outputs.pop(0),
    )

    orchestrator.phase_validation()

    assert context.validated_tasks == [task_a]
    assert "## Validation: FAILED" in task_b.read_text(encoding="utf-8")
    assert "- INVALID:path — missing.py not found" in task_b.read_text(encoding="utf-8")


def test_validation_skips_no_tasks(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=ScriptedGit())
    context.manager_task_manifest_path.write_text("", encoding="utf-8")

    orchestrator.phase_validation()

    assert runner.calls == []
    assert context.validated_tasks == []


def test_cleanup_logs_cost_summary_and_weekly_summary(tmp_path: Path, config_factory, caplog) -> None:
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=ScriptedAgentRunner(), git=git)
    orchestrator.cost_tracker.record_call(
        agent="claude-commit-detective",
        model=orchestrator.config.claude_model,
        playbook="commit-detective.md",
        input_tokens=1000,
        output_tokens=100,
    )
    context.digest_path = context.temp_digest_path
    context.digest_path.write_text("# Digest\n", encoding="utf-8")
    context.pr_url = "https://github.com/example/repo/pull/999"

    with caplog.at_level(logging.INFO):
        orchestrator.phase_cleanup()

    assert "Nightshift Cost Summary" in caplog.text
    assert "Digest artifact:" in caplog.text
    assert "PR URL:" in caplog.text
    assert "Weekly cost summary" in caplog.text
    assert git.checkout_calls == [orchestrator.config.base_branch]


def test_cleanup_calls_notify_when_webhook_configured(
    tmp_path: Path,
    config_factory,
    monkeypatch,
) -> None:
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=ScriptedAgentRunner(),
        git=git,
        extra_env={"NIGHTSHIFT_WEBHOOK_URL": "https://example.com/webhook"},
    )
    captured: dict[str, object] = {}

    monkeypatch.setattr(phases_module, "build_notify_summary", lambda ctx, tracker: f"summary:{ctx.run_date}")

    def fake_send_webhook(url: str, summary: str, run_date: str) -> bool:
        captured["url"] = url
        captured["summary"] = summary
        captured["run_date"] = run_date
        return True

    monkeypatch.setattr(phases_module, "send_webhook", fake_send_webhook)

    orchestrator.phase_cleanup()

    assert captured == {
        "url": "https://example.com/webhook",
        "summary": f"summary:{context.run_date}",
        "run_date": context.run_date,
    }


def test_cleanup_skips_notify_when_webhook_url_missing(
    tmp_path: Path,
    config_factory,
    monkeypatch,
) -> None:
    orchestrator, _context = create_orchestrator(tmp_path, config_factory, runner=ScriptedAgentRunner(), git=ScriptedGit())
    called = False

    def fake_send_webhook(url: str, summary: str, run_date: str) -> bool:
        nonlocal called
        called = True
        return True

    monkeypatch.setattr(phases_module, "send_webhook", fake_send_webhook)

    orchestrator.phase_cleanup()

    assert called is False


def test_autofix_happy_path(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={"NIGHTSHIFT_AUTOFIX_ENABLED": "true"},
    )
    task_path = tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth" / "task.md"
    task_path.parent.mkdir(parents=True)
    task_path.write_text(
        "## Task: Auth regression\n"
        "## Goal\n"
        "Fix auth regression.\n"
        "## Context\n"
        "- Severity: critical\n",
        encoding="utf-8",
    )
    context.validated_tasks = [task_path]
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        assert timeout == orchestrator.config.lauren_timeout_seconds
        manifest_path = task_path.parent / "competitive" / "run-manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text('{"final_status": "success", "total_cost_usd": 1.25}', encoding="utf-8")
        class Result:
            returncode = 0
        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)
    monkeypatch.setattr(
        phases_module.autofix_helpers,
        "stage_autofix_changes",
        lambda git_obj, task_file, before, after, before_untracked, after_untracked: [tmp_path / "src" / "service.py"],
    )

    orchestrator.phase_autofix()

    assert context.autofix_results[0]["status"] == "applied"
    assert "## Autofix: applied" in task_path.read_text(encoding="utf-8")
    assert task_path in git.staged_paths


def test_autofix_skips_smoke(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
        smoke=True,
        extra_env={"NIGHTSHIFT_AUTOFIX_ENABLED": "true"},
    )
    context.validated_tasks = [tmp_path / "task.md"]

    orchestrator.phase_autofix()

    assert context.autofix_results == []


def test_autofix_skips_disabled(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner, git=ScriptedGit())
    context.validated_tasks = [tmp_path / "task.md"]

    orchestrator.phase_autofix()

    assert context.autofix_results == []


def test_autofix_lauren_failure(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={"NIGHTSHIFT_AUTOFIX_ENABLED": "true"},
    )
    task_path = tmp_path / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth" / "task.md"
    task_path.parent.mkdir(parents=True)
    task_path.write_text(
        "## Task: Auth regression\n"
        "## Goal\n"
        "Fix auth regression.\n"
        "## Context\n"
        "- Severity: critical\n",
        encoding="utf-8",
    )
    context.validated_tasks = [task_path]
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    monkeypatch.setattr(
        phases_module.autofix_helpers,
        "run_lauren_loop",
        lambda slug, goal, repo_root, timeout, *, env: type("Result", (), {"returncode": 1})(),
    )

    orchestrator.phase_autofix()

    assert context.autofix_results[0]["status"] == "failed"
    assert "## Autofix: failed" in task_path.read_text(encoding="utf-8")
    assert task_path in git.staged_paths


def test_autofix_hardstops_on_blocked_outcome(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={"NIGHTSHIFT_AUTOFIX_ENABLED": "true"},
    )
    task_paths = []
    for slug in ("auth", "coverage", "retry"):
        task_path = tmp_path / "docs" / "tasks" / "open" / f"nightshift-2026-04-08-{slug}" / "task.md"
        task_path.parent.mkdir(parents=True, exist_ok=True)
        task_path.write_text(
            "## Task: Example\n"
            "## Goal\n"
            "Fix it.\n"
            "## Context\n"
            "- Severity: critical\n",
            encoding="utf-8",
        )
        task_paths.append(task_path)
    context.validated_tasks = task_paths
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []
    restored_calls: list[tuple[str | None, str | None, tuple[str, ...], tuple[str, ...]]] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        manifest_path = task_paths[0].parent / "competitive" / "run-manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text('{"final_status": "blocked", "total_cost_usd": 1.25}', encoding="utf-8")

        class Result:
            returncode = 0

        return Result()

    def fake_restore(git_obj, before_snapshot, after_snapshot, before_untracked, after_untracked):
        restored_calls.append((before_snapshot, after_snapshot, tuple(before_untracked), tuple(after_untracked)))
        return autofix_helpers.IterationChanges((), ())

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)
    monkeypatch.setattr(phases_module.autofix_helpers, "restore_iteration_changes", fake_restore)

    orchestrator.phase_autofix()

    assert lauren_calls == ["nightshift-2026-04-08-auth"]
    assert len(restored_calls) == 1
    assert context.autofix_halted is True
    assert "reported blocked" in context.autofix_halt_reason
    assert len(context.autofix_results) == 1
    assert context.autofix_results[0]["status"] == "blocked"


def test_autofix_hardstops_on_human_review(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={"NIGHTSHIFT_AUTOFIX_ENABLED": "true"},
    )
    task_paths = []
    for slug in ("auth", "coverage", "retry"):
        task_path = tmp_path / "docs" / "tasks" / "open" / f"nightshift-2026-04-08-{slug}" / "task.md"
        task_path.parent.mkdir(parents=True, exist_ok=True)
        task_path.write_text(
            "## Task: Example\n"
            "## Goal\n"
            "Fix it.\n"
            "## Context\n"
            "- Severity: critical\n",
            encoding="utf-8",
        )
        task_paths.append(task_path)
    context.validated_tasks = task_paths
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []
    restored_calls: list[tuple[str | None, str | None, tuple[str, ...], tuple[str, ...]]] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        manifest_path = task_paths[0].parent / "competitive" / "run-manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text('{"final_status": "human_review", "total_cost_usd": 1.25}', encoding="utf-8")

        class Result:
            returncode = 0

        return Result()

    def fake_restore(git_obj, before_snapshot, after_snapshot, before_untracked, after_untracked):
        restored_calls.append((before_snapshot, after_snapshot, tuple(before_untracked), tuple(after_untracked)))
        return autofix_helpers.IterationChanges((), ())

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)
    monkeypatch.setattr(phases_module.autofix_helpers, "restore_iteration_changes", fake_restore)

    orchestrator.phase_autofix()

    assert lauren_calls == ["nightshift-2026-04-08-auth"]
    assert len(restored_calls) == 1
    assert context.autofix_halted is True
    assert "reported human_review" in context.autofix_halt_reason
    assert len(context.autofix_results) == 1
    assert context.autofix_results[0]["status"] == "blocked"


def test_autofix_hardstops_on_manifest_contract_failure(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={"NIGHTSHIFT_AUTOFIX_ENABLED": "true"},
    )
    task_paths = []
    for slug in ("auth", "coverage", "retry"):
        task_path = tmp_path / "docs" / "tasks" / "open" / f"nightshift-2026-04-08-{slug}" / "task.md"
        task_path.parent.mkdir(parents=True, exist_ok=True)
        task_path.write_text(
            "## Task: Example\n"
            "## Goal\n"
            "Fix it.\n"
            "## Context\n"
            "- Severity: critical\n",
            encoding="utf-8",
        )
        task_paths.append(task_path)
    context.validated_tasks = task_paths
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []
    restored_calls: list[tuple[str | None, str | None, tuple[str, ...], tuple[str, ...]]] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        manifest_path = task_paths[0].parent / "competitive" / "run-manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text('{"final_status": "success"}', encoding="utf-8")

        class Result:
            returncode = 0

        return Result()

    def fake_restore(git_obj, before_snapshot, after_snapshot, before_untracked, after_untracked):
        restored_calls.append((before_snapshot, after_snapshot, tuple(before_untracked), tuple(after_untracked)))
        return autofix_helpers.IterationChanges((), ())

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)
    monkeypatch.setattr(phases_module.autofix_helpers, "restore_iteration_changes", fake_restore)

    orchestrator.phase_autofix()

    assert lauren_calls == ["nightshift-2026-04-08-auth"]
    assert len(restored_calls) == 1
    assert context.autofix_halted is True
    assert "manifest contract failure" in context.autofix_halt_reason
    assert len(context.autofix_results) == 1
    assert context.autofix_results[0]["status"] == "failed"


def test_autofix_restores_worktree_on_hardstop(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    worktree, _remote = create_bare_remote_repo(tmp_path)
    source_path = worktree / "src" / "service.py"
    source_path.parent.mkdir(parents=True, exist_ok=True)
    source_path.write_text("value = 'original'\n", encoding="utf-8")
    run(["git", "add", "src/service.py"], cwd=worktree)
    run(["git", "commit", "-m", "add service"], cwd=worktree)

    config = config_factory(
        repo_dir=worktree,
        extra_env={"NIGHTSHIFT_AUTOFIX_ENABLED": "true"},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    orchestrator = NightshiftOrchestrator(
        config=config,
        context=context,
        git=git,
        agents=runner,  # type: ignore[arg-type]
        shipper=object(),  # type: ignore[arg-type]
        cost_tracker=tracker,
        timeout_budget=TimeoutBudget(None),
        logger=logging.getLogger("test-phases"),
    )

    task_path = worktree / "docs" / "tasks" / "open" / "nightshift-2026-04-08-auth" / "task.md"
    task_path.parent.mkdir(parents=True, exist_ok=True)
    task_path.write_text(
        "## Task: Auth regression\n"
        "## Goal\n"
        "Fix auth regression.\n"
        "## Context\n"
        "- Severity: critical\n",
        encoding="utf-8",
    )
    git.stage_paths([task_path])
    context.validated_tasks = [task_path]
    (worktree / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (worktree / "lauren-loop-v2.sh").chmod(0o755)

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        source_path.write_text("value = 'lauren'\n", encoding="utf-8")
        manifest_path = task_path.parent / "competitive" / "run-manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text('{"final_status": "blocked", "total_cost_usd": 1.25}', encoding="utf-8")

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_autofix()

    assert source_path.read_text(encoding="utf-8") == "value = 'original'\n"
    assert context.autofix_halted is True
    assert context.autofix_results[0]["status"] == "blocked"


def test_bridge_happy_path(tmp_path: Path, config_factory, monkeypatch) -> None:
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
    _write_ranked_digest(
        context,
        [
            ("1", "critical", "regression", "Auth regression"),
            ("2", "major", "coverage", "Coverage drift"),
        ],
    )
    covered_task = tmp_path / "docs" / "tasks" / "open" / f"nightshift-{context.run_date}-auth-regression" / "task.md"
    covered_task.parent.mkdir(parents=True, exist_ok=True)
    covered_task.write_text("## Task: Auth regression\n## Goal\nFix it.\n", encoding="utf-8")
    context.manager_task_manifest_path.write_text(f"{covered_task}\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    git.snapshot_values = ["before", "after"]
    git.changed_file_values = [["src/bridge_fix.py"]]
    git.untracked_file_values = [[], []]

    lauren_calls: list[str] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        assert timeout == orchestrator.config.lauren_timeout_seconds
        lauren_calls.append(slug)
        hinted_task = Path(env["LAUREN_LOOP_TASK_FILE_HINT"])
        _write_scope_triage(hinted_task, ["src/bridge_fix.py"])
        _write_lauren_manifest(hinted_task, {"final_status": "success", "total_cost_usd": 1.25})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert lauren_calls == [f"nightshift-bridge-{context.run_date}-coverage-drift"]
    assert len(context.bridge_results) == 1
    assert context.bridge_results[0]["status"] == "applied"
    assert context.bridge_results[0]["title"] == "Coverage drift"
    assert context.bridge_task_paths == [
        tmp_path / "docs" / "tasks" / "open" / f"nightshift-bridge-{context.run_date}-coverage-drift" / "task.md"
    ]
    assert tmp_path / "src" / "bridge_fix.py" in git.staged_paths
    assert context.digest_path is not None
    assert "## Bridge" in context.digest_path.read_text(encoding="utf-8")
    assert context.failures == []


def test_bridge_skips_smoke(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        smoke=True,
        extra_env={"NIGHTSHIFT_BRIDGE_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])

    orchestrator.phase_bridge()

    assert context.bridge_results == []
    assert context.bridge_task_paths == []


def test_bridge_skips_disabled(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(tmp_path, config_factory, runner=runner)
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])

    orchestrator.phase_bridge()

    assert context.bridge_results == []


def test_bridge_triage_only(tmp_path: Path, config_factory, monkeypatch) -> None:
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
            "NIGHTSHIFT_BRIDGE_MAX_COST_PER_TASK": "250",
        },
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        raise AssertionError("Lauren Loop should not run in triage-only fallback")

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert lauren_calls == []
    assert len(context.bridge_results) == 1
    assert context.bridge_results[0]["status"] == "prepared"
    assert context.bridge_task_paths[0].exists()
    assert context.failures == []


def test_bridge_failure_is_warning(tmp_path: Path, config_factory, monkeypatch) -> None:
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

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        class Result:
            returncode = 1

        return Result()

    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_bridge()

    assert len(context.bridge_results) == 1
    assert context.bridge_results[0]["status"] == "failed"
    assert context.failures == []
    assert any("Bridge task" in message for message in context.warnings)


def test_backlog_happy_path(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    task_one = _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    (tmp_path / "lauren-loop.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop.sh").chmod(0o755)
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    git.snapshot_values = ["before", "after"]
    git.changed_file_values = [["src/backlog_fix.py"]]
    git.untracked_file_values = [[], []]
    lauren_calls: list[tuple[str, str]] = []

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        assert timeout == orchestrator.config.lauren_timeout_seconds
        return subprocess.CompletedProcess(
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            0,
            "## TASK_LIST\n1|docs/tasks/open/backlog-one/task.md|Fix backlog one|medium\n",
            "",
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        assert timeout == orchestrator.config.lauren_timeout_seconds
        lauren_calls.append((slug, goal))
        _write_scope_triage(task_one, ["src/backlog_fix.py"])
        _write_lauren_manifest(task_one, {"final_status": "success", "total_cost_usd": 0.50})

        class Result:
            returncode = 0

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert lauren_calls == [("backlog-one", "Fix backlog one")]
    assert len(context.backlog_results) == 1
    assert context.backlog_results[0]["status"] == "success"
    assert tmp_path / "src" / "backlog_fix.py" in git.staged_paths
    assert context.digest_path is not None
    assert "## Backlog Burndown" in context.digest_path.read_text(encoding="utf-8")
    assert context.failures == []


def test_backlog_skips_manager_contract_failure(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    git = ScriptedGit()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=git,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    context.manager_contract_failed = True
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    (tmp_path / "lauren-loop.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop.sh").chmod(0o755)
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)
    ranking_calls: list[bool] = []

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        ranking_calls.append(True)
        return subprocess.CompletedProcess(
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            0,
            "## TASK_LIST\n1|docs/tasks/open/backlog-one/task.md|Fix backlog one|medium\n",
            "",
        )

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)

    orchestrator.phase_backlog()

    assert ranking_calls == []
    assert context.backlog_results == []


def test_backlog_skips_smoke(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        smoke=True,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])

    orchestrator.phase_backlog()

    assert context.backlog_results == []


def test_backlog_skips_disabled(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "false"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])

    orchestrator.phase_backlog()

    assert context.backlog_results == []


def test_backlog_inflates_to_meet_minimum_attempt_floor(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
        extra_env={
            "NIGHTSHIFT_BACKLOG_ENABLED": "true",
            "NIGHTSHIFT_BACKLOG_MAX_TASKS": "1",
            "NIGHTSHIFT_MIN_TASKS_PER_RUN": "3",
        },
    )
    context.autofix_results = [{"status": "failed"}]
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-three" / "task.md")
    write_executable(tmp_path / "lauren-loop.sh", "#!/usr/bin/env bash\n")
    write_executable(tmp_path / "lauren-loop-v2.sh", "#!/usr/bin/env bash\n")

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return _completed_backlog_ranking(
            repo_root,
            [
                (1, "docs/tasks/open/backlog-one/task.md", "Fix backlog one", "medium"),
                (2, "docs/tasks/open/backlog-two/task.md", "Fix backlog two", "medium"),
                (3, "docs/tasks/open/backlog-three/task.md", "Fix backlog three", "medium"),
            ],
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        class Result:
            returncode = 1

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one", "backlog-two"]


def test_backlog_honors_normal_cap_when_autofix_meets_minimum(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
        extra_env={
            "NIGHTSHIFT_BACKLOG_ENABLED": "true",
            "NIGHTSHIFT_BACKLOG_MAX_TASKS": "2",
            "NIGHTSHIFT_MIN_TASKS_PER_RUN": "3",
        },
    )
    context.autofix_results = [{"status": "failed"} for _ in range(5)]
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-three" / "task.md")
    write_executable(tmp_path / "lauren-loop.sh", "#!/usr/bin/env bash\n")
    write_executable(tmp_path / "lauren-loop-v2.sh", "#!/usr/bin/env bash\n")

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return _completed_backlog_ranking(
            repo_root,
            [
                (1, "docs/tasks/open/backlog-one/task.md", "Fix backlog one", "medium"),
                (2, "docs/tasks/open/backlog-two/task.md", "Fix backlog two", "medium"),
                (3, "docs/tasks/open/backlog-three/task.md", "Fix backlog three", "medium"),
            ],
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        class Result:
            returncode = 1

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one", "backlog-two"]


def test_backlog_runs_on_clean_run_when_autofix_is_below_minimum(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
        extra_env={
            "NIGHTSHIFT_BACKLOG_ENABLED": "true",
            "NIGHTSHIFT_BACKLOG_MAX_TASKS": "1",
            "NIGHTSHIFT_MIN_TASKS_PER_RUN": "3",
        },
    )
    context.run_clean = True
    context.autofix_results = [{"status": "blocked"}]
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-three" / "task.md")
    write_executable(tmp_path / "lauren-loop.sh", "#!/usr/bin/env bash\n")
    write_executable(tmp_path / "lauren-loop-v2.sh", "#!/usr/bin/env bash\n")

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return _completed_backlog_ranking(
            repo_root,
            [
                (1, "docs/tasks/open/backlog-one/task.md", "Fix backlog one", "medium"),
                (2, "docs/tasks/open/backlog-two/task.md", "Fix backlog two", "medium"),
                (3, "docs/tasks/open/backlog-three/task.md", "Fix backlog three", "medium"),
            ],
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        class Result:
            returncode = 1

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one", "backlog-two"]


def test_backlog_skips_clean_run_when_autofix_already_meets_minimum(tmp_path: Path, config_factory) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        extra_env={
            "NIGHTSHIFT_BACKLOG_ENABLED": "true",
            "NIGHTSHIFT_MIN_TASKS_PER_RUN": "3",
        },
    )
    context.run_clean = True
    context.autofix_results = [{"status": "failed"} for _ in range(3)]
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])

    orchestrator.phase_backlog()

    assert context.backlog_results == []


def test_backlog_minimum_zero_disables_floor_inflation(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        git=ScriptedGit(),
        extra_env={
            "NIGHTSHIFT_BACKLOG_ENABLED": "true",
            "NIGHTSHIFT_BACKLOG_MAX_TASKS": "1",
            "NIGHTSHIFT_MIN_TASKS_PER_RUN": "0",
        },
    )
    context.autofix_results = [{"status": "failed"}]
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-two" / "task.md")
    write_executable(tmp_path / "lauren-loop.sh", "#!/usr/bin/env bash\n")
    write_executable(tmp_path / "lauren-loop-v2.sh", "#!/usr/bin/env bash\n")

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return _completed_backlog_ranking(
            repo_root,
            [
                (1, "docs/tasks/open/backlog-one/task.md", "Fix backlog one", "medium"),
                (2, "docs/tasks/open/backlog-two/task.md", "Fix backlog two", "medium"),
            ],
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        class Result:
            returncode = 1

        return Result()

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert [entry["slug"] for entry in context.backlog_results] == ["backlog-one"]


def test_backlog_unpickable_filtered(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(
        tmp_path / "docs" / "tasks" / "open" / "backlog-one" / "task.md",
        status="in progress",
    )
    (tmp_path / "lauren-loop.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop.sh").chmod(0o755)
    (tmp_path / "lauren-loop-v2.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop-v2.sh").chmod(0o755)

    lauren_calls: list[str] = []

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return subprocess.CompletedProcess(
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            0,
            "## TASK_LIST\n1|docs/tasks/open/backlog-one/task.md|Fix backlog one|medium\n",
            "",
        )

    def fake_run_lauren_loop(slug, goal, repo_root, timeout, *, env):
        lauren_calls.append(slug)
        raise AssertionError("Lauren Loop should not run for unpickable tasks")

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)
    monkeypatch.setattr(phases_module.autofix_helpers, "run_lauren_loop", fake_run_lauren_loop)

    orchestrator.phase_backlog()

    assert lauren_calls == []
    assert context.backlog_results == []
    assert context.digest_path is not None
    assert "## Backlog Burndown" in context.digest_path.read_text(encoding="utf-8")


def test_backlog_failure_is_warning(tmp_path: Path, config_factory, monkeypatch) -> None:
    runner = ScriptedAgentRunner()
    orchestrator, context = create_orchestrator(
        tmp_path,
        config_factory,
        runner=runner,
        extra_env={"NIGHTSHIFT_BACKLOG_ENABLED": "true"},
    )
    _write_ranked_digest(context, [("1", "critical", "regression", "Auth regression")])
    _write_backlog_task(tmp_path / "docs" / "tasks" / "open" / "backlog-one" / "task.md")
    (tmp_path / "lauren-loop.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (tmp_path / "lauren-loop.sh").chmod(0o755)

    def fake_run_lauren_ranking(repo_root, tasks_dir, timeout, *, env):
        return subprocess.CompletedProcess(
            ["bash", str(repo_root / "lauren-loop.sh"), "next"],
            1,
            "",
            "boom",
        )

    monkeypatch.setattr(phases_module.backlog_helpers, "run_lauren_ranking", fake_run_lauren_ranking)

    orchestrator.phase_backlog()

    assert context.failures == []
    assert context.backlog_results == []
    assert any("Backlog ranking failed with exit 1" in message for message in context.warnings)

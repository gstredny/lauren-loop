from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

import pytest

import nightshift.agents as agents_module
from nightshift.agents import (
    AgentExecutionError,
    AgentRunner,
    AgentTimeoutError,
    estimate_codex_cost,
    extract_claude_cost,
    extract_claude_result_text,
    read_claude_result_text,
)
from nightshift.cost import CostTracker
from nightshift.runtime import RunContext

from .conftest import NIGHTSHIFT_DIR, create_bare_remote_repo, write_executable


def test_run_claude_invokes_expected_command_and_archives_findings(
    tmp_path: Path,
    config_factory,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    args_file = tmp_path / "claude-args.txt"
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS_FILE"
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
# Commit Detective Findings — 2026-04-07
### Finding: Example finding
**Severity:** major
EOF
printf '{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25},"result":"done"}\n'
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={"FAKE_CLAUDE_ARGS_FILE": str(args_file)},
    )
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    result = runner.run_claude("commit-detective")

    args_text = args_file.read_text(encoding="utf-8")
    assert "--dangerously-skip-permissions" in args_text
    assert "--max-turns" in args_text
    assert result.engine == "claude"
    assert result.status == "success"
    assert result.findings_count == 1
    assert result.archived_findings_path is not None
    assert result.archived_findings_path.name == "claude-commit-detective-findings.md"
    assert result.archived_findings_path.exists()
    assert tracker.total() > 0


def test_run_claude_strips_claudecode_from_subprocess_env(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    env_file = tmp_path / "claude-env.txt"
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
env | sort > "$FAKE_CLAUDE_ENV_FILE"
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
# Commit Detective Findings — 2026-04-07
### Finding: Example finding
**Severity:** major
EOF
printf '{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"result":"done"}\n'
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={
            "CLAUDECODE": "enabled",
            "FAKE_CLAUDE_ENV_FILE": str(env_file),
        },
    )
    assert config.subprocess_env().get("CLAUDECODE") == "enabled"

    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    runner.run_claude("commit-detective")

    env_text = env_file.read_text(encoding="utf-8")
    assert "CLAUDECODE=" not in env_text


def test_run_claude_timeout_returns_partial_result(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
printf '{"usage":{"input_tokens":40,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}\n'
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Partial finding
EOF
sleep 2
""",
    )
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        f'source "{NIGHTSHIFT_DIR / "nightshift.conf"}"\n'
        'NIGHTSHIFT_AGENT_TIMEOUT_SECONDS="1"\n',
        encoding="utf-8",
    )
    config = config_factory(repo_dir=worktree, conf_path=conf_path, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentTimeoutError) as exc_info:
        runner.run_claude("commit-detective")

    partial = exc_info.value.partial_result
    assert partial.engine == "claude"
    assert partial.status == "timeout"
    assert partial.archived_findings_path is not None
    assert partial.archived_findings_path.name == "claude-commit-detective-partial.md"
    assert tracker.total() > 0


def test_manager_cost_uses_override_model(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Example finding
EOF
printf '{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25},"result":"done"}\n'
""",
    )
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        f'source "{NIGHTSHIFT_DIR / "nightshift.conf"}"\n'
        'NIGHTSHIFT_CLAUDE_MODEL="claude-sonnet-4"\n',
        encoding="utf-8",
    )
    config = config_factory(repo_dir=worktree, conf_path=conf_path, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    runner.run_claude("commit-detective", model="claude-3-5-sonnet")

    state = json.loads(context.cost_state_file.read_text(encoding="utf-8"))
    assert state["calls"][0]["model"] == "claude-3-5-sonnet"


def test_run_claude_sets_cost_cap_hit_when_cumulative_total_reaches_cap(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Example finding
EOF
printf '{"usage":{"input_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"result":"done"}\n'
""",
    )
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        f'source "{NIGHTSHIFT_DIR / "nightshift.conf"}"\n'
        'NIGHTSHIFT_COST_CAP_USD="0.0100"\n',
        encoding="utf-8",
    )
    config = config_factory(repo_dir=worktree, conf_path=conf_path, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    result = runner.run_claude("commit-detective")

    assert result.status == "success"
    assert context.cost_cap_hit is True


def test_run_claude_sets_cost_cap_hit_when_runaway_pattern_triggers(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Example finding
EOF
printf '{"usage":{"input_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"result":"done"}\n'
""",
    )
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        f'source "{NIGHTSHIFT_DIR / "nightshift.conf"}"\n'
        'NIGHTSHIFT_COST_CAP_USD="10.0000"\n'
        'NIGHTSHIFT_RUNAWAY_THRESHOLD_USD="0.0100"\n'
        'NIGHTSHIFT_RUNAWAY_CONSECUTIVE="1"\n',
        encoding="utf-8",
    )
    config = config_factory(repo_dir=worktree, conf_path=conf_path, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    result = runner.run_claude("commit-detective")

    assert result.status == "success"
    assert context.cost_cap_hit is True


def test_canonical_findings_cleared_before_run(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" ]]; then
  echo "stale canonical findings file was not cleared" >&2
  exit 9
fi
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Fresh finding
EOF
printf '{"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"done"}\n'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    canonical_path = config.findings_dir / "commit-detective-findings.md"
    canonical_path.parent.mkdir(parents=True, exist_ok=True)
    canonical_path.write_text("stale finding\n", encoding="utf-8")
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    result = runner.run_claude("commit-detective")

    assert result.archived_findings_path is not None
    assert result.archived_findings_path.read_text(encoding="utf-8") == "### Finding: Fresh finding\n"
    assert not canonical_path.exists()


def test_partial_archived_from_disk_not_stdout(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Disk-only partial finding
EOF
exit 7
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_claude("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.archived_findings_path is not None
    assert partial.archived_findings_path.name == "claude-commit-detective-partial.md"
    assert partial.archived_findings_path.read_text(encoding="utf-8") == "### Finding: Disk-only partial finding\n"
    assert partial.output_path.read_text(encoding="utf-8") == ""


def test_detective_without_new_findings_artifact_fails_and_does_not_leak_stale_findings(
    tmp_path: Path,
    config_factory,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    call_count_file = tmp_path / "claude-call-count.txt"
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
call_count=0
if [[ -f "$FAKE_CLAUDE_CALL_COUNT_FILE" ]]; then
  call_count="$(cat "$FAKE_CLAUDE_CALL_COUNT_FILE")"
fi
call_count=$((call_count + 1))
printf '%s' "$call_count" > "$FAKE_CLAUDE_CALL_COUNT_FILE"
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
if [[ "$call_count" -eq 1 ]]; then
  cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: First slot finding
EOF
fi
printf '{"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"done"}\n'
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={"FAKE_CLAUDE_CALL_COUNT_FILE": str(call_count_file)},
    )
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    first_result = runner.run_claude("commit-detective")
    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_claude("commit-detective")

    canonical_path = config.findings_dir / "commit-detective-findings.md"
    assert first_result.archived_findings_path is not None
    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is None
    assert "zero-exit but no usable output" in str(exc_info.value)
    assert not canonical_path.exists()


def test_run_claude_error_max_turns_is_semantic_failure_and_archives_partial(
    tmp_path: Path,
    config_factory,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Partial semantic failure finding
EOF
printf '{"subtype":"error_max_turns","usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"too many turns"}\n'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_claude("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is not None
    assert partial.archived_findings_path.name == "claude-commit-detective-partial.md"
    assert "error_max_turns" in str(exc_info.value)


@pytest.mark.parametrize("subtype", ["error_tool_use", "error_model"])
def test_run_claude_other_error_subtypes_are_semantic_failures(
    tmp_path: Path,
    config_factory,
    subtype: str,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '{{"subtype":"{subtype}","usage":{{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}},"result":"semantic failure"}}\\n'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_claude("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is None
    assert subtype in str(exc_info.value)


def test_run_claude_zero_exit_empty_stdout_is_failure(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
exit 0
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_claude("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is None
    assert "zero-exit but no usable output" in str(exc_info.value)


def test_run_claude_zero_exit_malformed_json_is_failure_and_logs_truncated_stdout(
    tmp_path: Path,
    config_factory,
    caplog,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    malformed_output = "not-json:" + ("x" * 520)
    write_executable(
        fake_bin / "claude",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' '{malformed_output}'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with caplog.at_level(logging.WARNING):
        with pytest.raises(AgentExecutionError) as exc_info:
            runner.run_claude("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is None
    assert "zero-exit but no usable output" in str(exc_info.value)
    assert malformed_output[:497] + "..." in caplog.text
    assert malformed_output not in caplog.text


def test_run_claude_zero_exit_empty_result_text_is_failure(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Partial output still wrote findings
EOF
printf '{"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":""}\n'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_claude("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is not None
    assert partial.archived_findings_path.name == "claude-commit-detective-partial.md"
    assert "zero-exit but no usable output" in str(exc_info.value)


def test_run_claude_zero_exit_meaningful_result_with_non_error_subtype_succeeds(
    tmp_path: Path,
    config_factory,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Healthy output with findings
EOF
printf '{"subtype":"message_stop","usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"meaningful result"}\n'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    result = runner.run_claude("commit-detective")

    assert result.status == "success"
    assert result.findings_count == 1
    assert result.archived_findings_path is not None
    assert result.archived_findings_path.name == "claude-commit-detective-findings.md"


def test_run_claude_artifact_suffix_preserves_task_writer_outputs(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
printf '{"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"task output"}\n'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    first = runner.run_claude(
        "task-writer",
        model=config.manager_model,
        finding_text="Rank: 1",
        artifact_suffix="rank-1",
    )
    second = runner.run_claude(
        "task-writer",
        model=config.manager_model,
        finding_text="Rank: 2",
        artifact_suffix="rank-2",
    )

    assert first.output_path.name == "claude-task-writer-rank-1.json"
    assert second.output_path.name == "claude-task-writer-rank-2.json"
    assert first.output_path.exists()
    assert second.output_path.exists()
    assert read_claude_result_text(first.output_path) == "task output"
    assert read_claude_result_text(second.output_path) == "task output"


def test_run_claude_artifact_suffix_preserves_validation_outputs(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
printf '{"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5},"result":"### Validation Result: VALIDATED"}\n'
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin)
    context = RunContext.create(config, dry_run=False, smoke=True)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)
    task_a = worktree / "docs" / "tasks" / "open" / "nightshift-2026-04-13-auth" / "task.md"
    task_b = worktree / "docs" / "tasks" / "open" / "nightshift-2026-04-13-coverage" / "task.md"
    task_a.parent.mkdir(parents=True, exist_ok=True)
    task_b.parent.mkdir(parents=True, exist_ok=True)
    task_a.write_text("## Task: Auth\n", encoding="utf-8")
    task_b.write_text("## Task: Coverage\n", encoding="utf-8")

    first = runner.run_claude(
        "validation-agent",
        model=config.manager_model,
        task_file_path=str(task_a),
        artifact_suffix=task_a.parent.name,
    )
    second = runner.run_claude(
        "validation-agent",
        model=config.manager_model,
        task_file_path=str(task_b),
        artifact_suffix=task_b.parent.name,
    )

    assert first.output_path.name == "claude-validation-agent-nightshift-2026-04-13-auth.json"
    assert second.output_path.name == "claude-validation-agent-nightshift-2026-04-13-coverage.json"
    assert first.output_path.exists()
    assert second.output_path.exists()
    assert read_claude_result_text(first.output_path) == "### Validation Result: VALIDATED"
    assert read_claude_result_text(second.output_path) == "### Validation Result: VALIDATED"


def test_run_codex_command_shape(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    args_file = tmp_path / "codex-args.txt"
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
{
  printf '%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
  printf '%s\n' "${10}"
} > "$FAKE_CODEX_ARGS_FILE"
[[ "$1" == "exec" ]]
[[ "$2" == "-p" ]]
[[ "$3" == "azure54" ]]
[[ "$4" == "-C" ]]
[[ "$5" == "$NIGHTSHIFT_REPO_DIR" ]]
[[ "$6" == "-c" ]]
[[ "$7" == 'model_reasoning_effort="high"' ]]
[[ "$8" == "--dangerously-bypass-approvals-and-sandbox" ]]
[[ "$9" == "--ephemeral" ]]
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
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
            "FAKE_CODEX_ARGS_FILE": str(args_file),
        },
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    result = runner.run_codex("commit-detective")

    args_lines = args_file.read_text(encoding="utf-8").splitlines()
    assert args_lines[:9] == [
        "exec",
        "-p",
        "azure54",
        "-C",
        str(worktree),
        "-c",
        'model_reasoning_effort="high"',
        "--dangerously-bypass-approvals-and-sandbox",
        "--ephemeral",
    ]
    assert "Commit" in args_lines[9]
    assert result.engine == "codex"
    assert result.status == "success"
    assert result.archived_findings_path is not None
    assert result.archived_findings_path.name == "codex-commit-detective-findings.md"


def test_run_codex_timeout_records_partial_output(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
printf 'partial codex output\n'
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Partial codex finding
EOF
sleep 2
""",
    )
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        f'source "{NIGHTSHIFT_DIR / "nightshift.conf"}"\n'
        'NIGHTSHIFT_AGENT_TIMEOUT_SECONDS="1"\n',
        encoding="utf-8",
    )
    config = config_factory(
        repo_dir=worktree,
        conf_path=conf_path,
        path_prefix=fake_bin,
        extra_env={"AZURE_OPENAI_API_KEY": "test-key"},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentTimeoutError) as exc_info:
        runner.run_codex("commit-detective")

    partial = exc_info.value.partial_result
    assert partial.engine == "codex"
    assert partial.status == "timeout"
    assert partial.archived_findings_path is not None
    assert partial.archived_findings_path.name == "codex-commit-detective-partial.md"
    assert tracker.total() > 0


def test_run_codex_empty_output_is_failure(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
exit 0
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={"AZURE_OPENAI_API_KEY": "test-key"},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_codex("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is None


def test_run_codex_empty_output_archives_canonical_findings_as_partial(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Disk-only codex finding
EOF
exit 0
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={"AZURE_OPENAI_API_KEY": "test-key"},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError) as exc_info:
        runner.run_codex("commit-detective")

    partial = exc_info.value.partial_result
    assert partial is not None
    assert partial.status == "error"
    assert partial.return_code == 0
    assert partial.archived_findings_path is not None
    assert partial.archived_findings_path.name == "codex-commit-detective-partial.md"
    assert partial.archived_findings_path.read_text(encoding="utf-8") == "### Finding: Disk-only codex finding\n"


def test_codex_preflight_exports_api_key_from_context_guard(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    env_file = tmp_path / "codex-env.txt"
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
env | sort > "$FAKE_CODEX_ENV_FILE"
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
### Finding: Codex finding
EOF
printf '{"ok":true}\n'
""",
    )
    home = tmp_path / "home"
    guard_script = home / ".claude/scripts/context-guard.sh"
    guard_script.parent.mkdir(parents=True, exist_ok=True)
    guard_script.write_text(
        'codex54_auth_preflight() {\n'
        '  export AZURE_OPENAI_API_KEY="guard-key"\n'
        '  return 0\n'
        '}\n',
        encoding="utf-8",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={
            "AZURE_OPENAI_API_KEY": "",
            "FAKE_CODEX_ENV_FILE": str(env_file),
        },
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    runner.run_codex("commit-detective")

    env_text = env_file.read_text(encoding="utf-8")
    assert "AZURE_OPENAI_API_KEY=guard-key" in env_text


def test_codex_preflight_failure_raises(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
printf '{"ok":true}\n'
""",
    )
    home = tmp_path / "home"
    guard_script = home / ".claude/scripts/context-guard.sh"
    guard_script.parent.mkdir(parents=True, exist_ok=True)
    guard_script.write_text(
        'codex54_auth_preflight() {\n'
        '  echo "boom" >&2\n'
        '  return 1\n'
        '}\n',
        encoding="utf-8",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={"AZURE_OPENAI_API_KEY": ""},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    with pytest.raises(AgentExecutionError):
        runner.run_codex("commit-detective")

    stderr_log = config.log_dir / "codex-commit-detective-stderr.log"
    assert stderr_log.exists()


def test_codex_preflight_cache_refreshes_after_ttl(
    tmp_path: Path,
    config_factory,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    home = tmp_path / "home"
    guard_script = home / ".claude/scripts/context-guard.sh"
    guard_script.parent.mkdir(parents=True, exist_ok=True)
    guard_script.write_text("codex54_auth_preflight() { return 0; }\n", encoding="utf-8")

    config = config_factory(
        repo_dir=worktree,
        extra_env={"AZURE_OPENAI_API_KEY": ""},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    tracker = CostTracker(state_file=context.cost_state_file, csv_file=config.cost_csv, config=config)
    tracker.init(context.run_id)
    runner = AgentRunner(config=config, context=context, cost_tracker=tracker)

    clock = [1000.0]
    monkeypatch.setattr(agents_module.time, "monotonic", lambda: clock[0])
    preflight_calls: list[int] = []

    def fake_run_subprocess(*args, **kwargs):
        preflight_calls.append(1)
        token = f"guard-key-{len(preflight_calls)}"
        return subprocess.CompletedProcess(
            args[0],
            0,
            f"AZURE_OPENAI_API_KEY={token}\0EXTRA_FLAG={len(preflight_calls)}\0",
            "",
        )

    monkeypatch.setattr(agents_module, "run_subprocess", fake_run_subprocess)

    stderr_log_path = config.log_dir / "codex-preflight-stderr.log"

    first_env, _ = runner._prepare_codex_env(
        playbook_name="commit-detective",
        stderr_log_path=stderr_log_path,
    )
    assert first_env["AZURE_OPENAI_API_KEY"] == "guard-key-1"
    assert len(preflight_calls) == 1

    clock[0] += agents_module._CODEX_ENV_CACHE_TTL_SECONDS - 1
    second_env, _ = runner._prepare_codex_env(
        playbook_name="commit-detective",
        stderr_log_path=stderr_log_path,
    )
    assert second_env["AZURE_OPENAI_API_KEY"] == "guard-key-1"
    assert len(preflight_calls) == 1

    clock[0] += 2
    third_env, _ = runner._prepare_codex_env(
        playbook_name="commit-detective",
        stderr_log_path=stderr_log_path,
    )
    assert third_env["AZURE_OPENAI_API_KEY"] == "guard-key-2"
    assert len(preflight_calls) == 2


def test_extract_claude_cost_from_json() -> None:
    usage = extract_claude_cost(
        '{"usage":{"input_tokens":123,"cache_creation_input_tokens":4,"cache_read_input_tokens":5,"output_tokens":67}}\n'
    )

    assert usage.input_tokens == 123
    assert usage.cache_create_tokens == 4
    assert usage.cache_read_tokens == 5
    assert usage.output_tokens == 67


def test_extract_claude_result_text_from_result_string() -> None:
    output_text = '{"result":"hello world"}\n'

    assert extract_claude_result_text(output_text) == "hello world"


def test_extract_claude_result_text_from_message_content_array() -> None:
    output_text = (
        '{"message":{"content":['
        '{"type":"text","text":"first block"},'
        '{"type":"tool_use","name":"ignored"},'
        '{"type":"text","text":"second block"}'
        ']}}\n'
    )

    assert extract_claude_result_text(output_text) == "first block\nsecond block"


def test_estimate_codex_cost_from_chars() -> None:
    usage = estimate_codex_cost("abcd" * 10, "efgh" * 6)

    assert usage.input_tokens == 10
    assert usage.output_tokens == 6
    assert usage.cache_create_tokens == 0
    assert usage.cache_read_tokens == 0


def test_codex_cost_uses_byte_length_not_char_length() -> None:
    prompt_text = "\u2014" * 4
    output_text = ("\u201c\u201d") * 4

    usage = estimate_codex_cost(prompt_text, output_text)

    assert usage.input_tokens == len(prompt_text.encode("utf-8")) // 4
    assert usage.output_tokens == len(output_text.encode("utf-8")) // 4
    assert usage.input_tokens > len(prompt_text) // 4
    assert usage.output_tokens > len(output_text) // 4

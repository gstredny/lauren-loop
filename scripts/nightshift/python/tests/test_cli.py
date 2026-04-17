from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from nightshift.config import NightshiftConfig
from nightshift.detective_status import VALID_DETECTIVE_STATUSES

from .conftest import PYTHON_ROOT, PROJECT_ROOT, create_bare_remote_repo, run, write_executable


def test_smoke_cli_happy_path(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    run(["git", "checkout", "--detach"], cwd=worktree)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    claude_args_log = tmp_path / "claude-args.txt"
    codex_args_log = tmp_path / "codex-args.txt"
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$FAKE_CLAUDE_ARGS_FILE"
all_args="$*"
if printf '%s' "$all_args" | grep -q "Ranked Findings"; then
  today="$(date +%Y-%m-%d)"
  digest_dir="$NIGHTSHIFT_REPO_DIR/docs/nightshift/digests"
  mkdir -p "$digest_dir"
  cat > "$digest_dir/$today.md" <<DEOF
# Nightshift Detective Digest — $today

## Ranked Findings
| # | Severity | Category | Title |
|---|----------|----------|-------|
| 1 | major | regression | Example finding |

## Minor & Observation Findings
| # | Title | Severity | Category | Source | Evidence |
|---|-------|----------|----------|--------|----------|
DEOF
  printf '{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25},"result":"manager complete"}\n'
elif printf '%s' "$all_args" | grep -q "Nightshift Agent: Task Writer"; then
  printf '%s\n' '{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25},"result":"--- BEGIN TASK FILE ---\n## Task: Example finding\n## Status: not started\n## Created: 2026-04-08\n## Execution Mode: single-agent\n\n## Motivation\nNight Shift found an example issue.\n\n## Goal\nSystem fixes the example issue.\n\n## Scope\n### In Scope\n- Example scope\n\n### Out of Scope\n- Example out of scope\n\n## Relevant Files\n- `README.md` — example file\n\n## Context\n- Severity: major\n\n## Anti-Patterns\n- Do NOT skip tests.\n\n## Done Criteria\n- [ ] Example done\n\n## Code Review: not started\n\n## Left Off At\nNot started.\n\n## Attempts\n- (none)\n--- END TASK FILE ---\n### Task Writer Result: CREATED"}'
elif printf '%s' "$all_args" | grep -q "Nightshift Validation Agent"; then
  printf '%s\n' '{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25},"result":"### Validation Result: VALIDATED\nPaths checked: 1 passed, 0 failed\nClaims checked: 1 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- (none)"}'
else
  mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
  cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
# Commit Detective Findings — 2026-04-07
### Finding: Example finding
**Severity:** major
EOF
  printf '{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25},"result":"done"}\n'
  exit 0
fi
exit 0
""",
    )
    write_executable(
        fake_bin / "codex",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_CODEX_ARGS_FILE"
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
# Commit Detective Findings — 2026-04-07
### Finding: Codex example finding
**Severity:** major
EOF
printf '{"ok":true}\n'
""",
    )
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "auth status" ]]; then
  printf 'authenticated\n'
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

    home = tmp_path / "home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "NIGHTSHIFT_DIR": str(PROJECT_ROOT / "scripts/nightshift"),
        "NIGHTSHIFT_REPO_DIR": str(worktree),
        "NIGHTSHIFT_LOG_DIR": str(tmp_path / "logs"),
        "NIGHTSHIFT_FINDINGS_DIR": str(tmp_path / "findings"),
        "NIGHTSHIFT_RENDERED_DIR": str(tmp_path / "rendered"),
        "NIGHTSHIFT_PLAYBOOKS_DIR": str(PROJECT_ROOT / "scripts/nightshift/playbooks"),
        "NIGHTSHIFT_COST_STATE_FILE": str(tmp_path / "cost-state.json"),
        "NIGHTSHIFT_COST_CSV": str(tmp_path / "logs/cost-history.csv"),
        "AZURE_OPENAI_API_KEY": "test-key",
        "FAKE_CLAUDE_ARGS_FILE": str(claude_args_log),
        "FAKE_CODEX_ARGS_FILE": str(codex_args_log),
        "FAKE_GH_LOG": str(gh_log),
    }

    result = subprocess.run(
        [sys.executable, "-m", "nightshift", "--smoke"],
        cwd=PYTHON_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    smoke_branches = subprocess.run(
        ["git", "branch", "--list", "nightshift/smoke-*"],
        cwd=worktree,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.splitlines()
    smoke_branch = smoke_branches[0].strip().lstrip("* ").strip()
    today = datetime.now().strftime("%Y-%m-%d")
    digest_text = subprocess.run(
        ["git", "show", f"{smoke_branch}:docs/nightshift/digests/{today}.md"],
        cwd=worktree,
        text=True,
        capture_output=True,
        check=True,
    ).stdout

    assert "Nightshift Detective Digest" in digest_text
    assert "pr create" in gh_log.read_text(encoding="utf-8")
    assert "--dangerously-skip-permissions" in claude_args_log.read_text(encoding="utf-8")
    assert "--dangerously-bypass-approvals-and-sandbox" in codex_args_log.read_text(encoding="utf-8")


def test_dry_run_cli_schedules_full_dispatch_and_skips_ship(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    write_executable(
        fake_bin / "claude",
        """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$NIGHTSHIFT_FINDINGS_DIR"
cat > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md" <<'EOF'
# Commit Detective Findings — 2026-04-07
### Finding: Example finding
**Severity:** major
EOF
printf '{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":25},"result":"done"}\n'
""",
    )
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
exit 0
""",
    )

    home = tmp_path / "home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "NIGHTSHIFT_DIR": str(PROJECT_ROOT / "scripts/nightshift"),
        "NIGHTSHIFT_REPO_DIR": str(worktree),
        "NIGHTSHIFT_LOG_DIR": str(tmp_path / "logs"),
        "NIGHTSHIFT_FINDINGS_DIR": str(tmp_path / "findings"),
        "NIGHTSHIFT_RENDERED_DIR": str(tmp_path / "rendered"),
        "NIGHTSHIFT_PLAYBOOKS_DIR": str(PROJECT_ROOT / "scripts/nightshift/playbooks"),
        "NIGHTSHIFT_COST_STATE_FILE": str(tmp_path / "cost-state.json"),
        "NIGHTSHIFT_COST_CSV": str(tmp_path / "logs/cost-history.csv"),
        "FAKE_GH_LOG": str(gh_log),
    }

    result = subprocess.run(
        [sys.executable, "-m", "nightshift", "--dry-run"],
        cwd=PYTHON_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    config = NightshiftConfig.load(
        conf_path=PROJECT_ROOT / "scripts/nightshift/nightshift.conf",
        env=env,
        env_file=home / ".nightshift-env",
    )
    expected_slots = len(config.detective_playbooks) * (2 if config.claude_detectives_enabled else 1)

    assert result.returncode == 0, result.stderr
    assert not gh_log.exists()
    combined_output = result.stdout + result.stderr
    assert combined_output.count("DRY RUN: would run ") == expected_slots
    digest_match = re.search(r"Digest artifact: (?P<path>\S+dry-run-digest\.md)", combined_output)
    assert digest_match is not None
    digest_path = Path(digest_match.group("path"))
    assert digest_path.exists()
    status_files = sorted((digest_path.parent / "detective-status").glob("*.json"))
    assert len(status_files) == expected_slots
    first_status = json.loads(status_files[0].read_text(encoding="utf-8"))
    assert first_status["status"] in VALID_DETECTIVE_STATUSES


def test_dry_run_cli_writes_digest_and_detective_status_artifacts(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    home = tmp_path / "home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "NIGHTSHIFT_DIR": str(PROJECT_ROOT / "scripts/nightshift"),
        "NIGHTSHIFT_REPO_DIR": str(worktree),
        "NIGHTSHIFT_LOG_DIR": str(tmp_path / "logs"),
        "NIGHTSHIFT_FINDINGS_DIR": str(tmp_path / "findings"),
        "NIGHTSHIFT_RENDERED_DIR": str(tmp_path / "rendered"),
        "NIGHTSHIFT_PLAYBOOKS_DIR": str(PROJECT_ROOT / "scripts/nightshift/playbooks"),
        "NIGHTSHIFT_COST_STATE_FILE": str(tmp_path / "cost-state.json"),
        "NIGHTSHIFT_COST_CSV": str(tmp_path / "logs/cost-history.csv"),
    }

    result = subprocess.run(
        [sys.executable, "-m", "nightshift", "--dry-run"],
        cwd=PYTHON_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    combined_output = result.stdout + result.stderr
    assert result.returncode == 0, result.stderr
    digest_match = re.search(r"Digest artifact: (?P<path>\S+dry-run-digest\.md)", combined_output)
    assert digest_match is not None
    digest_path = Path(digest_match.group("path"))
    assert digest_path.exists()
    status_files = sorted((digest_path.parent / "detective-status").glob("*.json"))
    assert status_files
    first_status = json.loads(status_files[0].read_text(encoding="utf-8"))
    assert first_status["status"] in VALID_DETECTIVE_STATUSES


def test_smoke_dry_run_cli_only_schedules_commit_detective(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    home = tmp_path / "home"
    home.mkdir()
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
        "NIGHTSHIFT_DIR": str(PROJECT_ROOT / "scripts/nightshift"),
        "NIGHTSHIFT_REPO_DIR": str(worktree),
        "NIGHTSHIFT_LOG_DIR": str(tmp_path / "logs"),
        "NIGHTSHIFT_FINDINGS_DIR": str(tmp_path / "findings"),
        "NIGHTSHIFT_RENDERED_DIR": str(tmp_path / "rendered"),
        "NIGHTSHIFT_PLAYBOOKS_DIR": str(PROJECT_ROOT / "scripts/nightshift/playbooks"),
        "NIGHTSHIFT_COST_STATE_FILE": str(tmp_path / "cost-state.json"),
        "NIGHTSHIFT_COST_CSV": str(tmp_path / "logs/cost-history.csv"),
    }

    result = subprocess.run(
        [sys.executable, "-m", "nightshift", "--smoke", "--dry-run"],
        cwd=PYTHON_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    combined_output = result.stdout + result.stderr
    assert result.returncode == 0, result.stderr
    assert combined_output.count("DRY RUN: would run ") == 1
    assert "DRY RUN: would run codex/commit-detective" in combined_output
    assert "DRY RUN: would run claude/commit-detective" not in combined_output
    assert "conversation-detective" not in combined_output

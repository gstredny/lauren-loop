from __future__ import annotations

import logging
import os
import shutil
import time
from pathlib import Path

import pytest

import nightshift.git as git_module
import nightshift.timeout as timeout_module
from nightshift.git import GitCommandError, GitStateError, GitStateMachine
from nightshift.subprocess_runner import CommandTimeoutError
from nightshift.timeout import TimeoutBudget

from .conftest import create_bare_remote_repo, run, write_executable


def test_fetch_and_detach_happy_path(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    git.fetch_origin_branch("main", retry_delays=(0,))
    git.detach_to_remote_base("main")

    assert git.current_branch() == ""
    assert git.current_head() == git.resolve_ref("origin/main")


def test_create_branch_and_verify(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    git.fetch_origin_branch("main", retry_delays=(0,))
    git.detach_to_remote_base("main")
    git.create_branch("nightshift/2026-04-07")

    assert git.current_branch() == "nightshift/2026-04-07"


def test_branch_mismatch_raises(tmp_path: Path, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    git.fetch_origin_branch("main", retry_delays=(0,))
    git.detach_to_remote_base("main")
    monkeypatch.setattr(git, "current_branch", lambda: "main")

    with pytest.raises(GitStateError):
        git.create_branch("nightshift/2026-04-07")


def test_commit_on_wrong_branch_raises(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    with pytest.raises(GitStateError):
        git.commit("nightshift: wrong branch", expected_branch="nightshift/2026-04-07")


def test_prune_stale_branches(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    run(["git", "branch", "nightshift/2026-04-07"], cwd=worktree)
    run(["git", "branch", "nightshift/2026-04-08"], cwd=worktree)

    git.prune_local_nightshift_branches()

    assert git.list_local_nightshift_branches() == []


def test_detach_failure_raises(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    with pytest.raises(GitCommandError):
        git.detach_to_remote_base("missing")


def test_setup_succeeds_when_prior_run_left_same_date_branch_and_dirty_worktree(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    run(["git", "checkout", "-b", "nightshift/2026-04-07"], cwd=worktree)
    (worktree / "README.md").write_text("dirty\n", encoding="utf-8")
    (worktree / "orphan.txt").write_text("leftover\n", encoding="utf-8")

    branch_name = git.bootstrap_run_branch(
        base_branch="main",
        branch_name="nightshift/2026-04-07",
        retry_delays=(0,),
    )

    assert branch_name == "nightshift/2026-04-07"
    assert git.current_branch() == "nightshift/2026-04-07"
    assert git.working_tree_clean() is True
    assert (worktree / "orphan.txt").exists() is False


def test_force_push_creates_remote(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))

    (worktree / "digest.md").write_text("# Digest\n", encoding="utf-8")
    git.stage_paths([worktree / "digest.md"])
    git.commit("nightshift: test", expected_branch="nightshift/2026-04-07")

    git.force_push_branch("nightshift/2026-04-07")

    assert git.remote_branch_head("nightshift/2026-04-07") == git.current_head()


def test_force_push_updates_existing_remote(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))

    (worktree / "digest.md").write_text("# Digest v1\n", encoding="utf-8")
    git.stage_paths([worktree / "digest.md"])
    git.commit("nightshift: first", expected_branch="nightshift/2026-04-07")
    git.force_push_branch("nightshift/2026-04-07")
    first_head = git.current_head()

    (worktree / "digest.md").write_text("# Digest v2\n", encoding="utf-8")
    git.stage_paths([worktree / "digest.md"])
    git.commit("nightshift: second", expected_branch="nightshift/2026-04-07")
    git.force_push_branch("nightshift/2026-04-07")

    assert git.remote_branch_head("nightshift/2026-04-07") == git.current_head()
    assert git.current_head() != first_head


def test_force_push_with_explicit_lease_succeeds_after_amend(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))

    (worktree / "digest.md").write_text("# Digest v1\n", encoding="utf-8")
    git.stage_paths([worktree / "digest.md"])
    git.commit("nightshift: first", expected_branch="nightshift/2026-04-07")
    git.force_push_branch("nightshift/2026-04-07")
    first_head = git.current_head()

    (worktree / "digest.md").write_text("# Digest v2\n", encoding="utf-8")
    git.stage_paths([worktree / "digest.md"])
    git.amend_last_commit(expected_branch="nightshift/2026-04-07")

    assert git.current_head() != first_head

    git.force_push_branch("nightshift/2026-04-07", expected_remote_head=first_head)

    assert git.remote_branch_head("nightshift/2026-04-07") == git.current_head()


def test_force_push_with_stale_explicit_lease_rejects(tmp_path: Path) -> None:
    worktree, remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))

    (worktree / "digest.md").write_text("# Digest v1\n", encoding="utf-8")
    git.stage_paths([worktree / "digest.md"])
    git.commit("nightshift: first", expected_branch="nightshift/2026-04-07")
    git.force_push_branch("nightshift/2026-04-07")
    first_head = git.current_head()

    other_worktree = tmp_path / "other-worktree"
    run(["git", "clone", str(remote), str(other_worktree)], cwd=tmp_path)
    run(["git", "config", "user.email", "nightshift@example.com"], cwd=other_worktree)
    run(["git", "config", "user.name", "Nightshift"], cwd=other_worktree)
    run(
        ["git", "checkout", "-b", "nightshift/2026-04-07", "origin/nightshift/2026-04-07"],
        cwd=other_worktree,
    )
    run(["git", "commit", "--allow-empty", "-m", "remote update"], cwd=other_worktree)
    run(["git", "push", "origin", "HEAD:nightshift/2026-04-07"], cwd=other_worktree)

    (worktree / "digest.md").write_text("# Digest v2\n", encoding="utf-8")
    git.stage_paths([worktree / "digest.md"])
    git.amend_last_commit(expected_branch="nightshift/2026-04-07")

    with pytest.raises(GitCommandError):
        git.force_push_branch("nightshift/2026-04-07", expected_remote_head=first_head)


def test_force_push_rejects_protected_branch(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    with pytest.raises(GitStateError):
        git.force_push_branch("main")


def test_push_timeout_raises_without_hanging(tmp_path: Path, monkeypatch) -> None:
    real_git = shutil.which("git")
    assert real_git is not None

    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    pid_file = tmp_path / "git-push.pid"
    term_file = tmp_path / "git-push.term"
    write_executable(
        fake_bin / "git",
        f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "${{1:-}}" == "push" ]]; then
  echo $$ > "{pid_file}"
  trap 'echo TERM >> "{term_file}"' TERM
  while true; do sleep 1; done
fi
exec "{real_git}" "$@"
""",
    )
    monkeypatch.setattr(timeout_module, "PROCESS_TERMINATION_GRACE_SECONDS", 0.1)
    monkeypatch.setattr(git_module, "GIT_NETWORK_TIMEOUT_SECONDS", 0.2)
    git = GitStateMachine(
        worktree,
        protected_branches=("main", "development", "master"),
        env={"PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}"},
        logger=logging.getLogger("test-git"),
    )
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))

    started = time.monotonic()
    with pytest.raises(CommandTimeoutError):
        git.push_branch("nightshift/2026-04-07")
    elapsed = time.monotonic() - started

    assert elapsed < 1.0
    assert "TERM" in term_file.read_text(encoding="utf-8")
    pid = int(pid_file.read_text(encoding="utf-8").strip())
    with pytest.raises(OSError):
        os.kill(pid, 0)


def test_push_timeout_is_clamped_to_remaining_budget(tmp_path: Path, monkeypatch) -> None:
    real_git = shutil.which("git")
    assert real_git is not None

    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    write_executable(
        fake_bin / "git",
        f"""#!/usr/bin/env bash
set -euo pipefail
if [[ "${{1:-}}" == "push" ]]; then
  while true; do sleep 1; done
fi
exec "{real_git}" "$@"
""",
    )
    monkeypatch.setattr(timeout_module, "PROCESS_TERMINATION_GRACE_SECONDS", 0.1)
    monkeypatch.setattr(git_module, "GIT_NETWORK_TIMEOUT_SECONDS", 10.0)
    budget = TimeoutBudget(total_timeout_seconds=0.35, clock=lambda: 0.0, started_at=0.0)
    git = GitStateMachine(
        worktree,
        protected_branches=("main", "development", "master"),
        env={"PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}"},
        timeout_budget=budget,
        logger=logging.getLogger("test-git"),
    )
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))

    started = time.monotonic()
    with pytest.raises(CommandTimeoutError) as exc_info:
        git.push_branch("nightshift/2026-04-07")
    elapsed = time.monotonic() - started

    assert exc_info.value.timeout_seconds == pytest.approx(0.25, abs=0.05)
    assert elapsed < 0.75


def test_snapshot_tree_state_returns_commit_for_dirty_worktree(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    (worktree / "README.md").write_text("dirty\n", encoding="utf-8")

    snapshot = git.snapshot_tree_state()

    assert isinstance(snapshot, str)
    assert snapshot


def test_list_changed_files_between_refs(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    (worktree / "README.md").write_text("dirty\n", encoding="utf-8")
    snapshot = git.snapshot_tree_state()

    changed_files = git.list_changed_files("HEAD", snapshot)

    assert changed_files == ["README.md"]


def test_list_untracked_files(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))

    (worktree / "new-file.txt").write_text("hello\n", encoding="utf-8")

    assert git.list_untracked_files() == ["new-file.txt"]


def test_restore_tracked_paths_restores_pre_snapshot_state(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    readme = worktree / "README.md"

    readme.write_text("pre-autofix\n", encoding="utf-8")
    git.stage_paths([readme])
    snapshot = git.snapshot_tree_state()

    readme.write_text("lauren-change\n", encoding="utf-8")

    git.restore_tracked_paths([readme], source_ref=snapshot)

    assert readme.read_text(encoding="utf-8") == "pre-autofix\n"
    assert run(["git", "diff", "--cached", "--name-only"], cwd=worktree).stdout.strip() == "README.md"


def test_remove_untracked_paths_only_removes_requested(tmp_path: Path) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    git = GitStateMachine(worktree, protected_branches=("main", "development", "master"))
    remove_me = worktree / "remove-me.txt"
    keep_me = worktree / "keep-me.txt"

    remove_me.write_text("remove\n", encoding="utf-8")
    keep_me.write_text("keep\n", encoding="utf-8")

    git.remove_untracked_paths(["remove-me.txt"])

    assert remove_me.exists() is False
    assert keep_me.exists() is True

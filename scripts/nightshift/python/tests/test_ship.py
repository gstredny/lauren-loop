from __future__ import annotations

from pathlib import Path

import pytest

from nightshift.git import GitStateMachine
from nightshift.ship import ShipError, ShipResult, Shipper

from .conftest import create_bare_remote_repo, write_executable


def _prepare_branch(worktree: Path, config) -> GitStateMachine:
    git = GitStateMachine(
        worktree,
        protected_branches=config.protected_branch_list,
        env=config.subprocess_env(),
    )
    git.bootstrap_run_branch(base_branch="main", branch_name="nightshift/2026-04-07", retry_delays=(0,))
    return git


def test_commit_push_pr_happy_path(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
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
  printf 'https://github.com/example/repo/pull/123\n'
  exit 0
fi
exit 0
""",
    )
    config = config_factory(
        repo_dir=worktree,
        path_prefix=fake_bin,
        extra_env={"FAKE_GH_LOG": str(gh_log)},
    )
    git = _prepare_branch(worktree, config)
    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")

    shipper = Shipper(config=config, git=git)
    result = shipper.ship(
        branch_name="nightshift/2026-04-07",
        digest_path=digest_path,
        run_date="2026-04-07",
        smoke=True,
        task_file_count=0,
        total_findings=1,
        dry_run=False,
    )

    assert result == ShipResult(
        committed=True,
        pushed=True,
        pr_created=True,
        pr_updated=False,
        pr_number=123,
        pr_url="https://github.com/example/repo/pull/123",
        pushed_head=git.current_head(),
    )
    assert git.remote_branch_head("nightshift/2026-04-07") == git.resolve_ref("nightshift/2026-04-07")
    gh_text = gh_log.read_text(encoding="utf-8")
    assert "pr list" in gh_text
    assert "pr create" in gh_text


def test_skip_ship_on_dry_run(tmp_path: Path, config_factory) -> None:
    config = config_factory(repo_dir=tmp_path)
    git = GitStateMachine(tmp_path, protected_branches=config.protected_branch_list)
    shipper = Shipper(config=config, git=git)

    result = shipper.ship(
        branch_name="nightshift/2026-04-07",
        digest_path=tmp_path / "digest.md",
        run_date="2026-04-07",
        smoke=True,
        task_file_count=0,
        total_findings=1,
        dry_run=True,
    )

    assert result == ShipResult(
        committed=False,
        pushed=False,
        pr_created=False,
        pr_updated=False,
        pr_number=None,
        pr_url=None,
        pushed_head=None,
    )


def test_pr_create_reuses_existing_pr(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "auth status" ]]; then
  printf 'authenticated\n'
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  printf '[{"number":456,"url":"https://github.com/example/repo/pull/456"}]\n'
  exit 0
fi
if [[ "$1 $2" == "pr edit" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr create" ]]; then
  printf 'unexpected pr create\n' >&2
  exit 1
fi
if [[ "$1 $2" == "label create" ]]; then
  exit 0
fi
exit 0
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin, extra_env={"FAKE_GH_LOG": str(gh_log)})
    git = _prepare_branch(worktree, config)
    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")

    shipper = Shipper(config=config, git=git)
    result = shipper.ship(
        branch_name="nightshift/2026-04-07",
        digest_path=digest_path,
        run_date="2026-04-07",
        smoke=True,
        task_file_count=0,
        total_findings=1,
        dry_run=False,
    )

    assert result.pr_created is False
    assert result.pr_updated is True
    assert result.pr_number == 456
    assert result.pr_url == "https://github.com/example/repo/pull/456"
    gh_text = gh_log.read_text(encoding="utf-8")
    assert "pr edit 456" in gh_text
    assert "pr create" not in gh_text


def test_pr_create_race_fallback(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    race_flag = tmp_path / "pr-exists.flag"
    write_executable(
        fake_bin / "gh",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "auth status" ]]; then
  printf 'authenticated\n'
  exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
  if [[ -f "{race_flag}" ]]; then
    printf '[{{"number":654,"url":"https://github.com/example/repo/pull/654"}}]\n'
  else
    printf '[]\n'
  fi
  exit 0
fi
if [[ "$1 $2" == "label create" ]]; then
  exit 0
fi
if [[ "$1 $2" == "pr create" ]]; then
  touch "{race_flag}"
  printf 'a pull request for branch already exists\n' >&2
  exit 1
fi
if [[ "$1 $2" == "pr edit" ]]; then
  exit 0
fi
exit 0
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin, extra_env={"FAKE_GH_LOG": str(gh_log)})
    git = _prepare_branch(worktree, config)
    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")

    shipper = Shipper(config=config, git=git)
    result = shipper.ship(
        branch_name="nightshift/2026-04-07",
        digest_path=digest_path,
        run_date="2026-04-07",
        smoke=True,
        task_file_count=0,
        total_findings=1,
        dry_run=False,
    )

    assert result.pr_created is False
    assert result.pr_updated is True
    assert result.pr_number == 654
    gh_text = gh_log.read_text(encoding="utf-8")
    assert "pr create" in gh_text
    assert "pr edit 654" in gh_text


def test_ship_returns_pushed_head_even_if_later_step_fails(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
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
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin, extra_env={"FAKE_GH_LOG": str(gh_log)})
    git = _prepare_branch(worktree, config)
    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")

    shipper = Shipper(config=config, git=git)

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

    partial_result = exc_info.value.partial_result
    assert partial_result.committed is True
    assert partial_result.pushed is True
    assert partial_result.pr_created is False
    assert partial_result.pr_updated is False
    assert partial_result.pushed_head == git.current_head()
    assert partial_result.pushed_head is not None


def test_ship_does_not_call_delete_remote(tmp_path: Path, config_factory, monkeypatch) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    write_executable(
        fake_bin / "gh",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "auth status" ]]; then exit 0; fi
if [[ "$1 $2" == "pr list" ]]; then printf '[]\n'; exit 0; fi
if [[ "$1 $2" == "label create" ]]; then exit 0; fi
if [[ "$1 $2" == "pr create" ]]; then
  printf 'https://github.com/example/repo/pull/456\n'
  exit 0
fi
exit 0
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin, extra_env={"FAKE_GH_LOG": str(gh_log)})
    git = _prepare_branch(worktree, config)

    def _boom(*_args, **_kwargs):
        raise AssertionError("delete_remote_branch_if_exists should not be called")

    monkeypatch.setattr(git, "delete_remote_branch_if_exists", _boom)

    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest\n", encoding="utf-8")

    shipper = Shipper(config=config, git=git)
    result = shipper.ship(
        branch_name="nightshift/2026-04-07",
        digest_path=digest_path,
        run_date="2026-04-07",
        smoke=True,
        task_file_count=0,
        total_findings=1,
        dry_run=False,
    )

    assert result.pushed is True
    assert result.pr_created is True


def test_same_day_rerun_force_pushes(tmp_path: Path, config_factory) -> None:
    worktree, _remote = create_bare_remote_repo(tmp_path)
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh_log = tmp_path / "gh.log"
    pr_flag = tmp_path / "pr-created.flag"
    write_executable(
        fake_bin / "gh",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == "auth status" ]]; then exit 0; fi
if [[ "$1 $2" == "pr list" ]]; then
  if [[ -f "{pr_flag}" ]]; then
    printf '[{{"number":789,"url":"https://github.com/example/repo/pull/789"}}]\n'
  else
    printf '[]\n'
  fi
  exit 0
fi
if [[ "$1 $2" == "label create" ]]; then exit 0; fi
if [[ "$1 $2" == "pr create" ]]; then
  if [[ -f "{pr_flag}" ]]; then
    printf 'already exists\n' >&2
    exit 1
  fi
  touch "{pr_flag}"
  printf 'https://github.com/example/repo/pull/789\n'
  exit 0
fi
if [[ "$1 $2" == "pr edit" ]]; then exit 0; fi
exit 0
""",
    )
    config = config_factory(repo_dir=worktree, path_prefix=fake_bin, extra_env={"FAKE_GH_LOG": str(gh_log)})
    git = _prepare_branch(worktree, config)
    digest_path = worktree / "docs/nightshift/digests/2026-04-07.md"
    digest_path.parent.mkdir(parents=True, exist_ok=True)
    digest_path.write_text("# Digest v1\n", encoding="utf-8")

    shipper = Shipper(config=config, git=git)
    shipper.ship(
        branch_name="nightshift/2026-04-07",
        digest_path=digest_path,
        run_date="2026-04-07",
        smoke=True,
        task_file_count=0,
        total_findings=1,
        dry_run=False,
    )
    first_head = git.current_head()

    digest_path.write_text("# Digest v2\n", encoding="utf-8")
    result = shipper.ship(
        branch_name="nightshift/2026-04-07",
        digest_path=digest_path,
        run_date="2026-04-07",
        smoke=True,
        task_file_count=1,
        total_findings=5,
        dry_run=False,
    )

    assert result.pushed is True
    assert result.pr_created is False
    assert result.pr_updated is True
    assert git.remote_branch_head("nightshift/2026-04-07") == git.current_head()
    assert git.current_head() != first_head
    gh_text = gh_log.read_text(encoding="utf-8")
    assert gh_text.count("pr create") == 1
    assert "pr edit 789" in gh_text

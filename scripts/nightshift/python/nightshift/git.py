from __future__ import annotations

import logging
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence

from .subprocess_runner import run_subprocess
from .timeout import TimeoutBudget


GIT_LOCAL_TIMEOUT_SECONDS = 30
GIT_NETWORK_TIMEOUT_SECONDS = 120


class GitCommandError(RuntimeError):
    """Raised when a git command fails."""

    def __init__(self, args: Sequence[str], result: subprocess.CompletedProcess[str]) -> None:
        stderr = result.stderr.strip()
        stdout = result.stdout.strip()
        message = " ".join(["git", *args])
        details = stderr or stdout or f"exit {result.returncode}"
        super().__init__(f"{message} failed: {details}")
        self.args_list = list(args)
        self.result = result


class GitStateError(RuntimeError):
    """Raised when post-mutation git verification fails."""


@dataclass
class GitStateMachine:
    repo_dir: Path
    protected_branches: Sequence[str]
    env: Mapping[str, str] | None = None
    timeout_budget: TimeoutBudget | None = None
    logger: logging.Logger | None = None

    def is_repo(self) -> bool:
        result = self._run(["rev-parse", "--is-inside-work-tree"], check=False)
        return result.returncode == 0 and result.stdout.strip() == "true"

    def current_branch(self) -> str:
        return self._run(["branch", "--show-current"]).stdout.strip()

    def current_head(self) -> str:
        return self._run(["rev-parse", "HEAD"]).stdout.strip()

    def resolve_ref(self, ref: str) -> str:
        return self._run(["rev-parse", ref]).stdout.strip()

    def working_tree_status(self) -> str:
        return self._run(["status", "--porcelain", "--untracked-files=all"]).stdout.strip()

    def snapshot_tree_state(self) -> str | None:
        result = self._run(["stash", "create"], check=False, timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        if result.returncode != 0:
            raise GitCommandError(["stash", "create"], result)
        snapshot = result.stdout.strip()
        return snapshot or None

    def list_changed_files(self, left_ref: str | None, right_ref: str | None) -> list[str]:
        left = left_ref or "HEAD"
        right = right_ref or "HEAD"
        output = self._run(
            ["diff", "--name-only", left, right],
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        ).stdout
        return [line.strip() for line in output.splitlines() if line.strip()]

    def list_untracked_files(self) -> list[str]:
        output = self._run(
            ["ls-files", "--others", "--exclude-standard"],
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        ).stdout
        return sorted(line.strip() for line in output.splitlines() if line.strip())

    def tracked_files_clean(self) -> bool:
        status = self._run(["status", "--porcelain", "--untracked-files=no"]).stdout.strip()
        return status == ""

    def working_tree_clean(self) -> bool:
        return self.working_tree_status() == ""

    def fetch_origin_branch(
        self,
        base_branch: str,
        *,
        retry_delays: Sequence[int] = (0, 30, 120),
        sleeper: callable = time.sleep,
    ) -> None:
        last_error: GitCommandError | None = None
        for index, delay in enumerate(retry_delays):
            if index > 0 and delay > 0:
                sleeper(delay)
            result = self._run(
                ["fetch", "origin", base_branch],
                check=False,
                timeout_seconds=GIT_NETWORK_TIMEOUT_SECONDS,
            )
            if result.returncode == 0:
                return
            last_error = GitCommandError(["fetch", "origin", base_branch], result)
        assert last_error is not None
        raise last_error

    def repair_dirty_worktree(self) -> None:
        original_head = self.current_head()
        self._run(["reset", "--hard", "HEAD"], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        if self.current_head() != original_head:
            raise GitStateError("git reset --hard HEAD moved HEAD unexpectedly")
        self._run(["clean", "-fd"], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        if not self.working_tree_clean():
            raise GitStateError("Working tree is still dirty after reset/clean")

    def detach_to_remote_base(self, base_branch: str) -> None:
        expected_head = self.resolve_ref(f"origin/{base_branch}")
        self._run(
            ["checkout", "--detach", f"origin/{base_branch}"],
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        )
        if self.current_branch():
            raise GitStateError("Expected detached HEAD after checkout --detach")
        if self.current_head() != expected_head:
            raise GitStateError(
                f"Detached HEAD mismatch: expected {expected_head}, got {self.current_head()}"
            )

    def prune_local_nightshift_branches(self) -> None:
        for branch in self.list_local_nightshift_branches():
            self._run(["branch", "-D", branch], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
            if branch in self.list_local_nightshift_branches():
                raise GitStateError(f"Failed to prune local branch {branch}")

    def list_local_nightshift_branches(self) -> list[str]:
        output = self._run(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads/nightshift/*"],
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        ).stdout
        return [line.strip() for line in output.splitlines() if line.strip()]

    def create_branch(self, branch_name: str) -> None:
        self.assert_safe_branch(branch_name)
        if branch_name in self.list_local_nightshift_branches():
            self._run(["branch", "-D", branch_name], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
            if branch_name in self.list_local_nightshift_branches():
                raise GitStateError(f"Failed to delete stale branch {branch_name}")
        self._run(["checkout", "-b", branch_name], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        self.assert_on_branch(branch_name)

    def checkout_branch(self, branch_name: str) -> None:
        self._run(["checkout", branch_name], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        self.assert_on_branch(branch_name)

    def assert_on_branch(self, expected_branch: str) -> None:
        current_branch = self.current_branch()
        if current_branch != expected_branch:
            raise GitStateError(
                f"Expected current branch {expected_branch!r}, got {current_branch!r}"
            )

    def assert_safe_branch(self, branch_name: str) -> None:
        if branch_name in self.protected_branches:
            raise GitStateError(f"Branch {branch_name!r} is protected")

    def stage_paths(self, paths: Iterable[Path]) -> None:
        normalized = [self._repo_relative(path) for path in paths]
        self._run(["add", "--", *normalized], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        verify = self._run(
            ["diff", "--cached", "--quiet", "--", *normalized],
            check=False,
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        )
        if verify.returncode == 0:
            raise GitStateError("No staged diff present after git add")
        if verify.returncode != 1:
            raise GitCommandError(["diff", "--cached", "--quiet", "--", *normalized], verify)

    def restore_tracked_paths(
        self,
        paths: Iterable[Path | str],
        *,
        source_ref: str | None = None,
    ) -> None:
        normalized = self._normalize_repo_paths(paths)
        if not normalized:
            return
        source = source_ref or "HEAD"
        self._run(
            ["restore", f"--source={source}", "--staged", "--worktree", "--", *normalized],
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        )
        verify = self._run(
            ["diff", "--quiet", "--", *normalized],
            check=False,
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        )
        if verify.returncode == 1:
            raise GitStateError(
                f"Tracked paths still dirty after restore: {', '.join(normalized)}"
            )
        if verify.returncode != 0:
            raise GitCommandError(["diff", "--quiet", "--", *normalized], verify)

    def remove_untracked_paths(self, paths: Iterable[Path | str]) -> None:
        normalized = self._normalize_repo_paths(paths)
        if not normalized:
            return
        self._run(
            ["clean", "-fd", "--", *normalized],
            timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS,
        )
        remaining = sorted(set(self.list_untracked_files()).intersection(normalized))
        if remaining:
            raise GitStateError(
                f"Untracked paths still present after clean: {', '.join(remaining)}"
            )

    def commit(self, message: str, *, expected_branch: str) -> None:
        if not message.startswith("nightshift: "):
            raise GitStateError("Commit message must start with 'nightshift: '")
        self.assert_on_branch(expected_branch)
        original_head = self.current_head()
        self._run(["commit", "-m", message], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        self.assert_on_branch(expected_branch)
        if self.current_head() == original_head:
            raise GitStateError("git commit did not advance HEAD")

    def amend_last_commit(self, *, expected_branch: str) -> None:
        self.assert_on_branch(expected_branch)
        original_head = self.current_head()
        self._run(["commit", "--amend", "--no-edit"], timeout_seconds=GIT_LOCAL_TIMEOUT_SECONDS)
        self.assert_on_branch(expected_branch)
        if self.current_head() == original_head:
            raise GitStateError("git commit --amend did not rewrite HEAD")

    def delete_remote_branch_if_exists(self, branch_name: str) -> None:
        if self.remote_branch_head(branch_name) is None:
            return
        self._run(
            ["push", "origin", "--delete", branch_name],
            timeout_seconds=GIT_NETWORK_TIMEOUT_SECONDS,
        )
        if self.remote_branch_head(branch_name) is not None:
            raise GitStateError(f"Remote branch {branch_name} still exists after delete")

    def push_branch(self, branch_name: str) -> None:
        self.assert_on_branch(branch_name)
        local_head = self.current_head()
        self._run(["push", "origin", branch_name], timeout_seconds=GIT_NETWORK_TIMEOUT_SECONDS)
        remote_head = self.remote_branch_head(branch_name)
        if remote_head != local_head:
            raise GitStateError(
                f"Remote branch {branch_name} head mismatch: expected {local_head}, got {remote_head}"
            )

    def force_push_branch(self, branch_name: str, *, expected_remote_head: str | None = None) -> str:
        self.assert_on_branch(branch_name)
        self.assert_safe_branch(branch_name)
        local_head = self.current_head()
        lease_arg = "--force-with-lease"
        if expected_remote_head is not None:
            lease_arg = f"--force-with-lease=refs/heads/{branch_name}:{expected_remote_head}"
        self._run(
            ["push", lease_arg, "origin", f"HEAD:{branch_name}"],
            timeout_seconds=GIT_NETWORK_TIMEOUT_SECONDS,
        )
        remote_head = self.remote_branch_head(branch_name)
        if remote_head != local_head:
            raise GitStateError(
                f"Remote branch {branch_name} head mismatch after force push: "
                f"expected {local_head}, got {remote_head}"
            )
        return local_head

    def remote_branch_head(self, branch_name: str) -> str | None:
        result = self._run(
            ["ls-remote", "--heads", "origin", branch_name],
            check=False,
            timeout_seconds=GIT_NETWORK_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            raise GitCommandError(["ls-remote", "--heads", "origin", branch_name], result)
        line = result.stdout.strip()
        if not line:
            return None
        return line.split()[0]

    def bootstrap_run_branch(
        self,
        *,
        base_branch: str,
        branch_name: str,
        retry_delays: Sequence[int] = (0, 30, 120),
        sleeper: callable = time.sleep,
    ) -> str:
        if not self.is_repo():
            raise GitStateError(f"Not inside a git working tree: {self.repo_dir}")
        if not self.working_tree_clean():
            self.repair_dirty_worktree()
        self.fetch_origin_branch(base_branch, retry_delays=retry_delays, sleeper=sleeper)
        self.detach_to_remote_base(base_branch)
        self.prune_local_nightshift_branches()
        self.create_branch(branch_name)
        return branch_name

    def _normalize_repo_paths(self, paths: Iterable[Path | str]) -> list[str]:
        normalized: list[str] = []
        seen: set[str] = set()
        for raw_path in paths:
            if isinstance(raw_path, Path):
                repo_path = self._repo_relative(raw_path) if raw_path.is_absolute() else str(raw_path)
            else:
                path_obj = Path(raw_path)
                repo_path = self._repo_relative(path_obj) if path_obj.is_absolute() else str(path_obj)
            if repo_path in {"", "."} or repo_path in seen:
                continue
            normalized.append(repo_path)
            seen.add(repo_path)
        return normalized

    def _repo_relative(self, path: Path) -> str:
        resolved = path.resolve()
        return str(resolved.relative_to(self.repo_dir.resolve()))

    def _run(
        self,
        args: Sequence[str],
        *,
        check: bool = True,
        timeout_seconds: float = GIT_LOCAL_TIMEOUT_SECONDS,
    ) -> subprocess.CompletedProcess[str]:
        result = run_subprocess(
            ["git", *args],
            cwd=self.repo_dir,
            env=None if self.env is None else dict(self.env),
            timeout_seconds=timeout_seconds,
            timeout_budget=self.timeout_budget,
            phase_name=f"git {' '.join(args)}",
            logger=self.logger,
        )
        if check and result.returncode != 0:
            raise GitCommandError(args, result)
        return result

from __future__ import annotations

import json
import logging
import shutil
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable, Mapping

from .config import NightshiftConfig
from .git import GitStateMachine
from .subprocess_runner import run_subprocess
from .timeout import TimeoutBudget


GH_AUTH_STATUS_TIMEOUT_SECONDS = 30
GH_LABEL_CREATE_TIMEOUT_SECONDS = 30
GH_PR_LIST_TIMEOUT_SECONDS = 30
GH_PR_CREATE_TIMEOUT_SECONDS = 60
GH_PR_EDIT_TIMEOUT_SECONDS = 30


@dataclass(frozen=True)
class ShipResult:
    committed: bool
    pushed: bool
    pr_created: bool
    pr_updated: bool
    pr_number: int | None
    pr_url: str | None
    pushed_head: str | None


@dataclass(frozen=True)
class PullRequestRef:
    number: int
    url: str | None


class ShipError(RuntimeError):
    def __init__(self, message: str, *, partial_result: ShipResult) -> None:
        super().__init__(message)
        self.partial_result = partial_result


class Shipper:
    def __init__(
        self,
        *,
        config: NightshiftConfig,
        git: GitStateMachine,
        timeout_budget: TimeoutBudget | None = None,
        logger: logging.Logger | None = None,
    ) -> None:
        self.config = config
        self.git = git
        self.timeout_budget = timeout_budget
        self.logger = logger or logging.getLogger("nightshift")

    def ship(
        self,
        *,
        branch_name: str,
        digest_path: Path,
        run_date: str,
        smoke: bool,
        task_file_count: int,
        total_findings: int,
        dry_run: bool,
    ) -> ShipResult:
        if dry_run:
            return ShipResult(
                committed=False,
                pushed=False,
                pr_created=False,
                pr_updated=False,
                pr_number=None,
                pr_url=None,
                pushed_head=None,
            )

        commit_message = (
            f"nightshift: {run_date} detective run - {task_file_count} tasks / {total_findings} findings"
        )
        title_prefix = "[SMOKE TEST] " if smoke else ""
        pr_title = f"{title_prefix}Nightshift {run_date}: {task_file_count} tasks / {total_findings} findings"
        partial_result = ShipResult(
            committed=False,
            pushed=False,
            pr_created=False,
            pr_updated=False,
            pr_number=None,
            pr_url=None,
            pushed_head=None,
        )

        self.git.stage_paths([digest_path])
        self.git.commit(commit_message, expected_branch=branch_name)
        partial_result = replace(partial_result, committed=True)
        try:
            pushed_head = self.git.force_push_branch(branch_name)
            partial_result = replace(
                partial_result,
                pushed=True,
                pushed_head=pushed_head,
            )
        except Exception as exc:
            raise ShipError(str(exc), partial_result=partial_result) from exc

        try:
            if shutil.which("gh", path=self.config.subprocess_path) is None:
                raise RuntimeError("gh CLI is unavailable; cannot create PR")
            auth_status = self._run_gh(
                ["auth", "status"],
                check=False,
                timeout_seconds=GH_AUTH_STATUS_TIMEOUT_SECONDS,
            )
            if auth_status.returncode != 0:
                raise RuntimeError((auth_status.stderr or auth_status.stdout).strip() or "gh auth status failed")

            existing_pr = self._find_existing_pr(branch_name)
            if existing_pr is not None:
                partial_result = replace(
                    partial_result,
                    pr_number=existing_pr.number,
                    pr_url=existing_pr.url,
                )
                try:
                    self.update_pr_body(pr_number=existing_pr.number, digest_path=digest_path)
                except Exception as exc:
                    raise ShipError(str(exc), partial_result=partial_result) from exc
                return replace(
                    partial_result,
                    pr_updated=True,
                )

            self._ensure_repo_labels()
            try:
                created_pr = self._create_pr(
                    branch_name=branch_name,
                    digest_path=digest_path,
                    pr_title=pr_title,
                )
            except RuntimeError as exc:
                message = str(exc)
                if self._is_existing_pr_error(message):
                    existing_pr = self._find_existing_pr(branch_name)
                    if existing_pr is not None:
                        partial_result = replace(
                            partial_result,
                            pr_number=existing_pr.number,
                            pr_url=existing_pr.url,
                        )
                        try:
                            self.update_pr_body(pr_number=existing_pr.number, digest_path=digest_path)
                        except Exception as update_exc:
                            raise ShipError(str(update_exc), partial_result=partial_result) from update_exc
                        return replace(partial_result, pr_updated=True)
                raise
            return replace(
                partial_result,
                pr_created=True,
                pr_number=created_pr.number,
                pr_url=created_pr.url,
            )
        except ShipError:
            raise
        except Exception as exc:
            raise ShipError(str(exc), partial_result=partial_result) from exc

    def update_pr_body(self, *, pr_number: int, digest_path: Path) -> None:
        result = self._run_gh(
            ["pr", "edit", str(pr_number), "--body-file", str(digest_path)],
            check=False,
            timeout_seconds=GH_PR_EDIT_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout).strip() or "gh pr edit failed")

    def _ensure_repo_labels(self) -> None:
        for label in self.config.pr_label_list:
            self._run_gh(
                ["label", "create", label, "--color", "0E8A16"],
                check=False,
                timeout_seconds=GH_LABEL_CREATE_TIMEOUT_SECONDS,
            )

    def _find_existing_pr(self, branch_name: str) -> PullRequestRef | None:
        result = self._run_gh(
            ["pr", "list", "--head", branch_name, "--state", "open", "--json", "number,url", "--limit", "1"],
            check=False,
            timeout_seconds=GH_PR_LIST_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout).strip() or "gh pr list failed")
        try:
            payload = json.loads(result.stdout or "[]")
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"gh pr list returned invalid JSON: {exc}") from exc
        if not payload:
            return None
        item = payload[0]
        number = item.get("number")
        if not isinstance(number, int):
            raise RuntimeError("gh pr list did not return a PR number")
        url = item.get("url")
        if url is not None and not isinstance(url, str):
            raise RuntimeError("gh pr list returned a non-string PR URL")
        return PullRequestRef(number=number, url=url)

    def _create_pr(self, *, branch_name: str, digest_path: Path, pr_title: str) -> PullRequestRef:
        args = [
            "pr",
            "create",
            "--base",
            self.config.base_branch,
            "--head",
            branch_name,
            "--title",
            pr_title,
            "--body-file",
            str(digest_path),
        ]
        for label in self.config.pr_label_list:
            args.extend(["--label", label])
        result = self._run_gh(
            args,
            check=False,
            timeout_seconds=GH_PR_CREATE_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout).strip() or "gh pr create failed")
        pr_url = result.stdout.strip() or None
        return PullRequestRef(number=self._parse_pr_number(pr_url), url=pr_url)

    def _is_existing_pr_error(self, message: str) -> bool:
        lowered = message.lower()
        return "already exists" in lowered or "a pull request for branch" in lowered

    def _parse_pr_number(self, pr_url: str | None) -> int | None:
        if not pr_url:
            return None
        pr_number_text = pr_url.rstrip("/").rsplit("/", 1)[-1]
        return int(pr_number_text) if pr_number_text.isdigit() else None

    def _run_gh(
        self,
        args: Iterable[str],
        *,
        check: bool,
        timeout_seconds: float,
        extra_env: Mapping[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        result = run_subprocess(
            ["gh", *args],
            cwd=self.config.repo_dir,
            env=self.config.subprocess_env(extra_env),
            timeout_seconds=timeout_seconds,
            timeout_budget=self.timeout_budget,
            phase_name=f"gh {' '.join(args)}",
            logger=self.logger,
        )
        if check and result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout).strip() or f"gh {' '.join(args)} failed")
        return result

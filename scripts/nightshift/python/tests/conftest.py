from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path
from typing import Callable

import pytest

from nightshift.config import NightshiftConfig


PYTHON_ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = Path(__file__).resolve().parents[4]
NIGHTSHIFT_DIR = PROJECT_ROOT / "scripts/nightshift"


def run(cmd: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True, check=True)


def write_executable(path: Path, content: str) -> Path:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def create_bare_remote_repo(tmp_path: Path) -> tuple[Path, Path]:
    remote = tmp_path / "remote.git"
    worktree = tmp_path / "worktree"
    run(["git", "init", "--bare", str(remote)], cwd=tmp_path)
    run(["git", "clone", str(remote), str(worktree)], cwd=tmp_path)
    run(["git", "config", "user.email", "nightshift@example.com"], cwd=worktree)
    run(["git", "config", "user.name", "Nightshift"], cwd=worktree)
    run(["git", "checkout", "-b", "main"], cwd=worktree)
    (worktree / "README.md").write_text("hello\n", encoding="utf-8")
    run(["git", "add", "README.md"], cwd=worktree)
    run(["git", "commit", "-m", "init"], cwd=worktree)
    run(["git", "push", "-u", "origin", "main"], cwd=worktree)
    return worktree, remote


@pytest.fixture
def config_factory(tmp_path: Path) -> Callable[..., NightshiftConfig]:
    def factory(
        *,
        repo_dir: Path | None = None,
        conf_path: Path | None = None,
        path_prefix: Path | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> NightshiftConfig:
        home = tmp_path / "home"
        home.mkdir(parents=True, exist_ok=True)
        log_dir = tmp_path / "logs"
        findings_dir = tmp_path / "findings"
        env = {
            "HOME": str(home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "NIGHTSHIFT_DIR": str(NIGHTSHIFT_DIR),
            "NIGHTSHIFT_REPO_DIR": str(repo_dir or PROJECT_ROOT),
            "NIGHTSHIFT_LOG_DIR": str(log_dir),
            "NIGHTSHIFT_FINDINGS_DIR": str(findings_dir),
            "NIGHTSHIFT_RENDERED_DIR": str(tmp_path / "rendered"),
            "NIGHTSHIFT_PLAYBOOKS_DIR": str(NIGHTSHIFT_DIR / "playbooks"),
            "NIGHTSHIFT_COST_STATE_FILE": str(tmp_path / "cost-state.json"),
            "NIGHTSHIFT_COST_CSV": str(log_dir / "cost-history.csv"),
        }
        if path_prefix is not None:
            env["PATH"] = f"{path_prefix}{os.pathsep}{env['PATH']}"
        if extra_env:
            env.update(extra_env)
        env_file = home / ".nightshift-env"
        return NightshiftConfig.load(
            conf_path=conf_path or (NIGHTSHIFT_DIR / "nightshift.conf"),
            env=env,
            env_file=env_file,
        )

    return factory

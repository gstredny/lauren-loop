from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

import nightshift.config as config_module
from nightshift.config import ConfigError, NightshiftConfig


def _write_executable(path: Path) -> None:
    path.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    path.chmod(path.stat().st_mode | 0o111)


def test_loads_from_conf_file(tmp_path: Path) -> None:
    conf_dir = tmp_path / "scripts/nightshift"
    conf_dir.mkdir(parents=True)
    conf_path = conf_dir / "nightshift.conf"
    conf_path.write_text(
        """
NIGHTSHIFT_CLAUDE_MODEL="${NIGHTSHIFT_CLAUDE_MODEL:-claude-test}"
NIGHTSHIFT_AUTOFIX_MAX_TASKS="${NIGHTSHIFT_AUTOFIX_MAX_TASKS:-7}"
NIGHTSHIFT_TASK_WRITER_MAX_TASKS="${NIGHTSHIFT_TASK_WRITER_MAX_TASKS:-${NIGHTSHIFT_AUTOFIX_MAX_TASKS:-5}}"
NIGHTSHIFT_DIR="${NIGHTSHIFT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
NIGHTSHIFT_REPO_DIR="${NIGHTSHIFT_REPO_DIR:-$(cd "$NIGHTSHIFT_DIR/../.." && pwd)}"
""".strip()
        + "\n",
        encoding="utf-8",
    )

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={"HOME": str(tmp_path / "home"), "PATH": "/usr/bin:/bin"},
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert config.claude_model == "claude-test"
    assert config.task_writer_max_tasks == 7
    assert config.repo_dir == conf_dir.parent.parent


def test_non_protected_env_overrides_fallback_conf(tmp_path: Path) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        'NIGHTSHIFT_CLAUDE_MODEL="${NIGHTSHIFT_CLAUDE_MODEL:-claude-from-conf}"\n',
        encoding="utf-8",
    )

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={
            "HOME": str(tmp_path / "home"),
            "PATH": "/usr/bin:/bin",
            "NIGHTSHIFT_CLAUDE_MODEL": "claude-from-env",
        },
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert config.claude_model == "claude-from-env"


def test_protected_tunable_from_conf_beats_caller_env(tmp_path: Path) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text('NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS="3600"\n', encoding="utf-8")

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={
            "HOME": str(tmp_path / "home"),
            "PATH": "/usr/bin:/bin",
            "NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS": "999",
        },
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert config.total_timeout_seconds == 3600
    assert config.raw_values["NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS"] == "3600"


def test_agent_timeout_protected_from_caller_env(tmp_path: Path) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text('NIGHTSHIFT_AGENT_TIMEOUT_SECONDS="600"\n', encoding="utf-8")

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={
            "HOME": str(tmp_path / "home"),
            "PATH": "/usr/bin:/bin",
            "NIGHTSHIFT_AGENT_TIMEOUT_SECONDS": "99",
        },
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert config.agent_timeout_seconds == 600
    assert config.raw_values["NIGHTSHIFT_AGENT_TIMEOUT_SECONDS"] == "600"


def test_lauren_timeout_protected_from_caller_env(tmp_path: Path) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text('NIGHTSHIFT_LAUREN_TIMEOUT_SECONDS="7200"\n', encoding="utf-8")

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={
            "HOME": str(tmp_path / "home"),
            "PATH": "/usr/bin:/bin",
            "NIGHTSHIFT_LAUREN_TIMEOUT_SECONDS": "99",
        },
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert config.lauren_timeout_seconds == 7200
    assert config.raw_values["NIGHTSHIFT_LAUREN_TIMEOUT_SECONDS"] == "7200"


def test_conf_path_prepend_is_authoritative_for_subprocesses(tmp_path: Path) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text('export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"\n', encoding="utf-8")

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={"HOME": str(tmp_path / "home"), "PATH": "/usr/bin:/bin"},
        env_file=tmp_path / "home/.nightshift-env",
    )

    path_parts = config.subprocess_path.split(os.pathsep)
    assert path_parts[0] == "/opt/homebrew/bin"
    assert path_parts[1] == "/usr/local/bin"
    assert path_parts.index("/opt/homebrew/bin") < path_parts.index("/usr/bin")
    assert path_parts.index("/usr/local/bin") < path_parts.index("/usr/bin")
    assert path_parts.index("/usr/bin") < path_parts.index("/bin")
    assert config.subprocess_env()["PATH"] == config.subprocess_path


def test_conf_path_order_controls_cli_resolution(tmp_path: Path) -> None:
    conf_bin = tmp_path / "conf-bin"
    caller_bin = tmp_path / "caller-bin"
    conf_bin.mkdir()
    caller_bin.mkdir()
    _write_executable(conf_bin / "claude")
    _write_executable(conf_bin / "gh")
    _write_executable(caller_bin / "claude")
    _write_executable(caller_bin / "gh")

    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(f'export PATH="{conf_bin}:$PATH"\n', encoding="utf-8")
    caller_path = os.pathsep.join([str(caller_bin), "/usr/bin", "/bin"])

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={"HOME": str(tmp_path / "home"), "PATH": caller_path},
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert shutil.which("claude", path=config.subprocess_path) == str(conf_bin / "claude")
    assert shutil.which("gh", path=config.subprocess_path) == str(conf_bin / "gh")


def test_missing_conf_uses_defaults(tmp_path: Path) -> None:
    config = NightshiftConfig.load(
        conf_path=tmp_path / "missing.conf",
        env={"HOME": str(tmp_path / "home"), "PATH": "/usr/bin:/bin"},
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert config.base_branch == "main"
    assert config.agent_timeout_seconds == 1800
    assert config.claude_detectives_enabled is False
    assert config.backlog_enabled is True
    assert config.lauren_timeout_seconds == 7200
    assert config.min_tasks_per_run == 3
    assert config.task_writer_max_tasks == 5
    assert config.total_timeout_seconds == 28800
    assert config.max_turns == 25


@pytest.mark.parametrize(
    ("raw_value", "expected"),
    [
        ("TRUE", True),
        ("1", True),
        ("false", False),
        ("False", False),
        ("0", False),
    ],
)
def test_claude_detectives_flag_loads_from_conf(tmp_path: Path, raw_value: str, expected: bool) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(f'NIGHTSHIFT_CLAUDE_DETECTIVES_ENABLED="{raw_value}"\n', encoding="utf-8")

    config = NightshiftConfig.load(
        conf_path=conf_path,
        env={"HOME": str(tmp_path / "home"), "PATH": "/usr/bin:/bin"},
        env_file=tmp_path / "home/.nightshift-env",
    )

    assert config.claude_detectives_enabled is expected


def test_conf_eval_timeout_raises_config_error(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text("sleep 30\n", encoding="utf-8")

    def fake_run(*args, **kwargs):
        assert kwargs["timeout"] == 10
        raise subprocess.TimeoutExpired(cmd=args[0], timeout=kwargs["timeout"])

    monkeypatch.setattr(config_module.subprocess, "run", fake_run)

    with pytest.raises(ConfigError, match=f"Timed out while evaluating {conf_path.resolve()}"):
        NightshiftConfig.load(
            conf_path=conf_path,
            env={"HOME": str(tmp_path / "home"), "PATH": "/usr/bin:/bin"},
            env_file=tmp_path / "home/.nightshift-env",
        )


@pytest.mark.parametrize("raw_value", ["-1", "16", "abc"])
def test_min_tasks_per_run_must_be_integer_in_range(tmp_path: Path, raw_value: str) -> None:
    conf_path = tmp_path / "nightshift.conf"
    conf_path.write_text(
        f'NIGHTSHIFT_MIN_TASKS_PER_RUN="{raw_value}"\n',
        encoding="utf-8",
    )

    with pytest.raises(ConfigError, match="NIGHTSHIFT_MIN_TASKS_PER_RUN"):
        NightshiftConfig.load(
            conf_path=conf_path,
            env={"HOME": str(tmp_path / "home"), "PATH": "/usr/bin:/bin"},
            env_file=tmp_path / "home/.nightshift-env",
        )

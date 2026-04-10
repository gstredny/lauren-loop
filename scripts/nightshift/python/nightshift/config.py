from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


PACKAGE_ROOT = Path(__file__).resolve().parent
PYTHON_ROOT = PACKAGE_ROOT.parent
NIGHTSHIFT_ROOT = PYTHON_ROOT.parent
REPO_ROOT = NIGHTSHIFT_ROOT.parent.parent
DEFAULT_DETECTIVE_PLAYBOOKS = (
    "commit-detective",
    "conversation-detective",
    "coverage-detective",
    "error-detective",
    "product-detective",
    "rcfa-detective",
    "security-detective",
    "performance-detective",
)

DEFAULT_CONF_PATH = NIGHTSHIFT_ROOT / "nightshift.conf"
PROTECTED_TUNABLES = (
    "NIGHTSHIFT_COST_CAP_USD",
    "NIGHTSHIFT_PER_CALL_CAP_USD",
    "NIGHTSHIFT_RUNAWAY_THRESHOLD_USD",
    "NIGHTSHIFT_RUNAWAY_CONSECUTIVE",
    "NIGHTSHIFT_PROTECTED_BRANCHES",
    "NIGHTSHIFT_MAX_PR_FILES",
    "NIGHTSHIFT_MAX_PR_LINES",
    "NIGHTSHIFT_AGENT_TIMEOUT_SECONDS",
    "NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS",
    "NIGHTSHIFT_MIN_FREE_MB",
)
_CAPTURE_ENV_SCRIPT = """
set -a
conf_path="$1"
env_file="$2"
protected=(
  NIGHTSHIFT_COST_CAP_USD
  NIGHTSHIFT_PER_CALL_CAP_USD
  NIGHTSHIFT_RUNAWAY_THRESHOLD_USD
  NIGHTSHIFT_RUNAWAY_CONSECUTIVE
  NIGHTSHIFT_PROTECTED_BRANCHES
  NIGHTSHIFT_MAX_PR_FILES
  NIGHTSHIFT_MAX_PR_LINES
  NIGHTSHIFT_AGENT_TIMEOUT_SECONDS
  NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS
  NIGHTSHIFT_MIN_FREE_MB
)
if [[ -r "$conf_path" ]]; then
  source "$conf_path"
fi
for name in "${protected[@]}"; do
  set_var="__NIGHTSHIFT_SNAPSHOT_SET_${name}"
  value_var="__NIGHTSHIFT_SNAPSHOT_VALUE_${name}"
  if [[ -n "${!name+x}" ]]; then
    printf -v "$set_var" '%s' "1"
    printf -v "$value_var" '%s' "${!name}"
  else
    printf -v "$set_var" '%s' "0"
    printf -v "$value_var" '%s' ""
  fi
done
if [[ -r "$env_file" ]]; then
  source "$env_file"
fi
for name in "${protected[@]}"; do
  set_var="__NIGHTSHIFT_SNAPSHOT_SET_${name}"
  value_var="__NIGHTSHIFT_SNAPSHOT_VALUE_${name}"
  if [[ "${!set_var}" == "1" ]]; then
    printf -v "$name" '%s' "${!value_var}"
    export "$name"
  else
    unset "$name"
  fi
done
env -0
"""


class ConfigError(RuntimeError):
    """Raised when Night Shift configuration cannot be loaded."""


def _defaults_for(nightshift_dir: Path, home: Path) -> dict[str, str]:
    repo_dir = (nightshift_dir / "../..").resolve()
    log_dir = nightshift_dir / "logs"
    return {
        "NIGHTSHIFT_CLAUDE_MODEL": "claude-opus-4-6",
        "NIGHTSHIFT_MANAGER_MODEL": "claude-opus-4-6",
        "NIGHTSHIFT_CODEX_MODEL": "azure54",
        "NIGHTSHIFT_COST_CAP_USD": "200",
        "NIGHTSHIFT_PER_CALL_CAP_USD": "25",
        "NIGHTSHIFT_RUNAWAY_THRESHOLD_USD": "15",
        "NIGHTSHIFT_RUNAWAY_CONSECUTIVE": "3",
        "NIGHTSHIFT_COMMIT_WINDOW_DAYS": "7",
        "NIGHTSHIFT_CONVERSATION_WINDOW_DAYS": "3",
        "NIGHTSHIFT_MAX_CONVERSATIONS": "50",
        "NIGHTSHIFT_RCFA_WINDOW_DAYS": "30",
        "NIGHTSHIFT_MAX_FINDINGS_PER_DETECTIVE": "10",
        "NIGHTSHIFT_MAX_TASK_FILES": "15",
        "NIGHTSHIFT_DETECTIVE_PLAYBOOKS": ",".join(DEFAULT_DETECTIVE_PLAYBOOKS),
        "NIGHTSHIFT_BRIDGE_ENABLED": "false",
        "NIGHTSHIFT_BRIDGE_MIN_SEVERITY": "major",
        "NIGHTSHIFT_BRIDGE_AUTO_EXECUTE": "false",
        "NIGHTSHIFT_BRIDGE_MAX_TASKS": "3",
        "NIGHTSHIFT_BRIDGE_MAX_COST_PER_TASK": "25",
        "NIGHTSHIFT_BACKLOG_ENABLED": "false",
        "NIGHTSHIFT_BACKLOG_MAX_TASKS": "3",
        "NIGHTSHIFT_BACKLOG_MIN_BUDGET": "20",
        "NIGHTSHIFT_TASK_WRITER_MAX_TASKS": "5",
        "NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY": "critical,major",
        "NIGHTSHIFT_TASK_WRITER_MIN_BUDGET": "20",
        "NIGHTSHIFT_AUTOFIX_ENABLED": "false",
        "NIGHTSHIFT_AUTOFIX_MAX_TASKS": "5",
        "NIGHTSHIFT_AUTOFIX_MIN_BUDGET": "20",
        "NIGHTSHIFT_AUTOFIX_SEVERITY": "critical,major",
        "NIGHTSHIFT_AGENT_TIMEOUT_SECONDS": "600",
        "NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS": "7200",
        "NIGHTSHIFT_MAX_TURNS": "25",
        "NIGHTSHIFT_MIN_FREE_MB": "1024",
        "NIGHTSHIFT_DIR": str(nightshift_dir),
        "NIGHTSHIFT_REPO_DIR": str(repo_dir),
        "NIGHTSHIFT_LOG_DIR": str(log_dir),
        "NIGHTSHIFT_FINDINGS_DIR": "/tmp/nightshift-findings",
        "NIGHTSHIFT_RENDERED_DIR": "/tmp/nightshift-rendered",
        "NIGHTSHIFT_PLAYBOOKS_DIR": str(nightshift_dir / "playbooks"),
        "NIGHTSHIFT_COST_STATE_FILE": "/tmp/nightshift-cost-state.json",
        "NIGHTSHIFT_COST_CSV": str(log_dir / "cost-history.csv"),
        "NIGHTSHIFT_DB_ADMIN_USER": "gstredny",
        "NIGHTSHIFT_DB_CONNECT_TIMEOUT": "10",
        "NIGHTSHIFT_DB_SSLMODE": "require",
        "NIGHTSHIFT_BASE_BRANCH": "main",
        "NIGHTSHIFT_PR_LABELS": "nightshift,auto-generated",
        "NIGHTSHIFT_MAX_PR_FILES": "20",
        "NIGHTSHIFT_MAX_PR_LINES": "5000",
        "NIGHTSHIFT_PROTECTED_BRANCHES": "main,development,master",
        "NIGHTSHIFT_WEBHOOK_URL": "",
        "NIGHTSHIFT_NOTIFY_EMAIL": "",
        "NIGHTSHIFT_CLAUDE_SONNET_INPUT_PRICE": "3.00",
        "NIGHTSHIFT_CLAUDE_SONNET_OUTPUT_PRICE": "15.00",
        "NIGHTSHIFT_CLAUDE_SONNET_CACHE_WRITE_PRICE": "3.75",
        "NIGHTSHIFT_CLAUDE_SONNET_CACHE_READ_PRICE": "0.30",
        "NIGHTSHIFT_CLAUDE_OPUS_INPUT_PRICE": "15.00",
        "NIGHTSHIFT_CLAUDE_OPUS_OUTPUT_PRICE": "75.00",
        "NIGHTSHIFT_CLAUDE_OPUS_CACHE_WRITE_PRICE": "18.75",
        "NIGHTSHIFT_CLAUDE_OPUS_CACHE_READ_PRICE": "1.50",
        "NIGHTSHIFT_CODEX_INPUT_PRICE": "2.00",
        "NIGHTSHIFT_CODEX_OUTPUT_PRICE": "8.00",
        "HOME": str(home),
    }


def _parse_bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes"}


def _parse_csv_tuple(value: str) -> tuple[str, ...]:
    return tuple(item.strip() for item in value.split(",") if item.strip())


def _capture_shell_env(
    *,
    conf_path: Path,
    env_file: Path,
    env: Mapping[str, str],
) -> dict[str, str]:
    try:
        completed = subprocess.run(
            ["bash", "-c", _CAPTURE_ENV_SCRIPT, "nightshift-config", str(conf_path), str(env_file)],
            capture_output=True,
            check=False,
            env=dict(env),
            timeout=10,
        )
    except subprocess.TimeoutExpired as exc:
        raise ConfigError(
            f"Timed out while evaluating {conf_path}"
        ) from exc
    if completed.returncode != 0:
        raise ConfigError(
            f"Failed to evaluate {conf_path}: {completed.stderr.decode('utf-8', errors='replace').strip()}"
        )

    shell_env: dict[str, str] = {}
    for entry in completed.stdout.split(b"\0"):
        if not entry:
            continue
        key, _, value = entry.partition(b"=")
        shell_env[key.decode("utf-8", errors="replace")] = value.decode("utf-8", errors="replace")
    return shell_env


@dataclass(frozen=True)
class NightshiftConfig:
    claude_model: str
    manager_model: str
    codex_model: str
    cost_cap_usd: float
    per_call_cap_usd: float
    runaway_threshold_usd: float
    runaway_consecutive: int
    commit_window_days: int
    conversation_window_days: int
    max_conversations: int
    rcfa_window_days: int
    max_findings_per_detective: int
    max_task_files: int
    detective_playbooks: tuple[str, ...]
    bridge_enabled: bool
    bridge_min_severity: str
    bridge_auto_execute: bool
    bridge_max_tasks: int
    bridge_max_cost_per_task: float
    backlog_enabled: bool
    backlog_max_tasks: int
    backlog_min_budget: float
    task_writer_max_tasks: int
    task_writer_min_severity: str
    task_writer_min_budget: float
    autofix_enabled: bool
    autofix_max_tasks: int
    autofix_min_budget: float
    autofix_severity: str
    agent_timeout_seconds: int
    total_timeout_seconds: int
    max_turns: int
    min_free_mb: int
    nightshift_dir: Path
    repo_dir: Path
    log_dir: Path
    findings_dir: Path
    rendered_dir: Path
    playbooks_dir: Path
    cost_state_file: Path
    cost_csv: Path
    db_admin_user: str
    db_connect_timeout: int
    db_sslmode: str
    base_branch: str
    pr_labels: str
    max_pr_files: int
    max_pr_lines: int
    protected_branches: str
    webhook_url: str
    notify_email: str
    claude_sonnet_input_price: float
    claude_sonnet_output_price: float
    claude_sonnet_cache_write_price: float
    claude_sonnet_cache_read_price: float
    claude_opus_input_price: float
    claude_opus_output_price: float
    claude_opus_cache_write_price: float
    claude_opus_cache_read_price: float
    codex_input_price: float
    codex_output_price: float
    env_file: Path
    subprocess_path: str
    shell_env: Mapping[str, str]
    raw_values: Mapping[str, str]

    @property
    def pr_label_list(self) -> tuple[str, ...]:
        return tuple(label.strip() for label in self.pr_labels.split(",") if label.strip())

    @property
    def protected_branch_list(self) -> tuple[str, ...]:
        return tuple(branch.strip() for branch in self.protected_branches.split(",") if branch.strip())

    def subprocess_env(self, extra: Mapping[str, str] | None = None) -> dict[str, str]:
        env = dict(self.shell_env)
        env["PATH"] = self.subprocess_path
        if extra:
            env.update(extra)
        return env

    @classmethod
    def load(
        cls,
        conf_path: Path | None = None,
        *,
        env: Mapping[str, str] | None = None,
        env_file: Path | None = None,
    ) -> "NightshiftConfig":
        base_env = dict(os.environ if env is None else env)
        conf_path = (conf_path or DEFAULT_CONF_PATH).resolve()
        home = Path(base_env.get("HOME", str(Path.home())))
        resolved_env_file = Path(
            env_file
            or base_env.get("NIGHTSHIFT_ENV_FILE")
            or home / ".nightshift-env"
        ).expanduser()
        nightshift_dir = conf_path.parent if conf_path.name else NIGHTSHIFT_ROOT
        raw_values = _defaults_for(nightshift_dir, home)
        shell_env = _capture_shell_env(conf_path=conf_path, env_file=resolved_env_file, env=base_env)
        raw_values.update({key: value for key, value in shell_env.items() if key.startswith("NIGHTSHIFT_")})
        if "PATH" in shell_env:
            subprocess_path = shell_env["PATH"]
        else:
            subprocess_path = base_env.get("PATH", "")
            shell_env["PATH"] = subprocess_path

        return cls(
            claude_model=raw_values["NIGHTSHIFT_CLAUDE_MODEL"],
            manager_model=raw_values["NIGHTSHIFT_MANAGER_MODEL"],
            codex_model=raw_values["NIGHTSHIFT_CODEX_MODEL"],
            cost_cap_usd=float(raw_values["NIGHTSHIFT_COST_CAP_USD"]),
            per_call_cap_usd=float(raw_values["NIGHTSHIFT_PER_CALL_CAP_USD"]),
            runaway_threshold_usd=float(raw_values["NIGHTSHIFT_RUNAWAY_THRESHOLD_USD"]),
            runaway_consecutive=int(raw_values["NIGHTSHIFT_RUNAWAY_CONSECUTIVE"]),
            commit_window_days=int(raw_values["NIGHTSHIFT_COMMIT_WINDOW_DAYS"]),
            conversation_window_days=int(raw_values["NIGHTSHIFT_CONVERSATION_WINDOW_DAYS"]),
            max_conversations=int(raw_values["NIGHTSHIFT_MAX_CONVERSATIONS"]),
            rcfa_window_days=int(raw_values["NIGHTSHIFT_RCFA_WINDOW_DAYS"]),
            max_findings_per_detective=int(raw_values["NIGHTSHIFT_MAX_FINDINGS_PER_DETECTIVE"]),
            max_task_files=int(raw_values["NIGHTSHIFT_MAX_TASK_FILES"]),
            detective_playbooks=_parse_csv_tuple(raw_values["NIGHTSHIFT_DETECTIVE_PLAYBOOKS"]),
            bridge_enabled=_parse_bool(raw_values["NIGHTSHIFT_BRIDGE_ENABLED"]),
            bridge_min_severity=raw_values["NIGHTSHIFT_BRIDGE_MIN_SEVERITY"],
            bridge_auto_execute=_parse_bool(raw_values["NIGHTSHIFT_BRIDGE_AUTO_EXECUTE"]),
            bridge_max_tasks=int(raw_values["NIGHTSHIFT_BRIDGE_MAX_TASKS"]),
            bridge_max_cost_per_task=float(raw_values["NIGHTSHIFT_BRIDGE_MAX_COST_PER_TASK"]),
            backlog_enabled=_parse_bool(raw_values["NIGHTSHIFT_BACKLOG_ENABLED"]),
            backlog_max_tasks=int(raw_values["NIGHTSHIFT_BACKLOG_MAX_TASKS"]),
            backlog_min_budget=float(raw_values["NIGHTSHIFT_BACKLOG_MIN_BUDGET"]),
            task_writer_max_tasks=int(raw_values["NIGHTSHIFT_TASK_WRITER_MAX_TASKS"]),
            task_writer_min_severity=raw_values["NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY"],
            task_writer_min_budget=float(raw_values["NIGHTSHIFT_TASK_WRITER_MIN_BUDGET"]),
            autofix_enabled=_parse_bool(raw_values["NIGHTSHIFT_AUTOFIX_ENABLED"]),
            autofix_max_tasks=int(raw_values["NIGHTSHIFT_AUTOFIX_MAX_TASKS"]),
            autofix_min_budget=float(raw_values["NIGHTSHIFT_AUTOFIX_MIN_BUDGET"]),
            autofix_severity=raw_values["NIGHTSHIFT_AUTOFIX_SEVERITY"],
            agent_timeout_seconds=int(raw_values["NIGHTSHIFT_AGENT_TIMEOUT_SECONDS"]),
            total_timeout_seconds=int(raw_values["NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS"]),
            max_turns=int(raw_values["NIGHTSHIFT_MAX_TURNS"]),
            min_free_mb=int(raw_values["NIGHTSHIFT_MIN_FREE_MB"]),
            nightshift_dir=Path(raw_values["NIGHTSHIFT_DIR"]),
            repo_dir=Path(raw_values["NIGHTSHIFT_REPO_DIR"]),
            log_dir=Path(raw_values["NIGHTSHIFT_LOG_DIR"]),
            findings_dir=Path(raw_values["NIGHTSHIFT_FINDINGS_DIR"]),
            rendered_dir=Path(raw_values["NIGHTSHIFT_RENDERED_DIR"]),
            playbooks_dir=Path(raw_values["NIGHTSHIFT_PLAYBOOKS_DIR"]),
            cost_state_file=Path(raw_values["NIGHTSHIFT_COST_STATE_FILE"]),
            cost_csv=Path(raw_values["NIGHTSHIFT_COST_CSV"]),
            db_admin_user=raw_values["NIGHTSHIFT_DB_ADMIN_USER"],
            db_connect_timeout=int(raw_values["NIGHTSHIFT_DB_CONNECT_TIMEOUT"]),
            db_sslmode=raw_values["NIGHTSHIFT_DB_SSLMODE"],
            base_branch=raw_values["NIGHTSHIFT_BASE_BRANCH"],
            pr_labels=raw_values["NIGHTSHIFT_PR_LABELS"],
            max_pr_files=int(raw_values["NIGHTSHIFT_MAX_PR_FILES"]),
            max_pr_lines=int(raw_values["NIGHTSHIFT_MAX_PR_LINES"]),
            protected_branches=raw_values["NIGHTSHIFT_PROTECTED_BRANCHES"],
            webhook_url=raw_values["NIGHTSHIFT_WEBHOOK_URL"],
            notify_email=raw_values["NIGHTSHIFT_NOTIFY_EMAIL"],
            claude_sonnet_input_price=float(raw_values["NIGHTSHIFT_CLAUDE_SONNET_INPUT_PRICE"]),
            claude_sonnet_output_price=float(raw_values["NIGHTSHIFT_CLAUDE_SONNET_OUTPUT_PRICE"]),
            claude_sonnet_cache_write_price=float(raw_values["NIGHTSHIFT_CLAUDE_SONNET_CACHE_WRITE_PRICE"]),
            claude_sonnet_cache_read_price=float(raw_values["NIGHTSHIFT_CLAUDE_SONNET_CACHE_READ_PRICE"]),
            claude_opus_input_price=float(raw_values["NIGHTSHIFT_CLAUDE_OPUS_INPUT_PRICE"]),
            claude_opus_output_price=float(raw_values["NIGHTSHIFT_CLAUDE_OPUS_OUTPUT_PRICE"]),
            claude_opus_cache_write_price=float(raw_values["NIGHTSHIFT_CLAUDE_OPUS_CACHE_WRITE_PRICE"]),
            claude_opus_cache_read_price=float(raw_values["NIGHTSHIFT_CLAUDE_OPUS_CACHE_READ_PRICE"]),
            codex_input_price=float(raw_values["NIGHTSHIFT_CODEX_INPUT_PRICE"]),
            codex_output_price=float(raw_values["NIGHTSHIFT_CODEX_OUTPUT_PRICE"]),
            env_file=resolved_env_file,
            subprocess_path=subprocess_path,
            shell_env=shell_env,
            raw_values=raw_values,
        )

from __future__ import annotations

import json
import logging
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

from .config import NightshiftConfig
from .cost import CostTracker, check_cost_cap
from .digest import count_findings_in_file
from .playbook import PlaybookRenderer
from .runtime import RunContext
from .subprocess_runner import CommandTimeoutError, run_subprocess
from .timeout import TimeoutBudget


TIMEOUT_EXIT_CODE = 124
_CODEX_ENV_CACHE_TTL_SECONDS = 1800.0
_CODEX_PREFLIGHT_CAPTURE_SCRIPT = """
guard_script="$1"
source "$guard_script"
if ! type codex54_auth_preflight >/dev/null 2>&1; then
  echo "codex54_auth_preflight is unavailable" >&2
  exit 1
fi
if ! codex54_auth_preflight; then
  exit 1
fi
env -0
"""


class AgentExecutionError(RuntimeError):
    """Raised when a detective subprocess exits non-zero."""

    def __init__(self, message: str, *, partial_result: AgentRunResult | None = None) -> None:
        self.partial_result = partial_result
        super().__init__(message)


class AgentTimeoutError(TimeoutError):
    """Raised when a detective subprocess times out."""

    def __init__(self, message: str, *, partial_result: AgentRunResult) -> None:
        self.partial_result = partial_result
        super().__init__(message)


@dataclass(frozen=True)
class AgentCost:
    input_tokens: int
    output_tokens: int
    cache_create_tokens: int
    cache_read_tokens: int


@dataclass(frozen=True)
class AgentRunResult:
    engine: str
    playbook_name: str
    output_path: Path
    stderr_log_path: Path
    archived_findings_path: Path | None
    findings_count: int
    duration_seconds: int
    cost_usd: str
    status: str
    return_code: int


def extract_claude_result_text(output_text: str) -> str | None:
    for line in output_text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        result = _payload_result_text(payload)
        if result:
            return result
    return None


def read_claude_result_text(output_path: Path) -> str | None:
    if not output_path.exists() or output_path.stat().st_size == 0:
        return None
    try:
        return extract_claude_result_text(output_path.read_text(encoding="utf-8"))
    except OSError:
        return None


def extract_claude_cost(output_text: str) -> AgentCost:
    for line in output_text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        usage = payload.get("usage") or {}
        return AgentCost(
            input_tokens=int(usage.get("input_tokens", 0) or 0),
            cache_create_tokens=int(usage.get("cache_creation_input_tokens", 0) or 0),
            cache_read_tokens=int(usage.get("cache_read_input_tokens", 0) or 0),
            output_tokens=int(usage.get("output_tokens", 0) or 0),
        )
    return AgentCost(
        input_tokens=0,
        cache_create_tokens=0,
        cache_read_tokens=0,
        output_tokens=0,
    )


def estimate_codex_cost(prompt_text: str, output_text: str) -> AgentCost:
    return AgentCost(
        input_tokens=len(prompt_text.encode("utf-8")) // 4,
        output_tokens=len(output_text.encode("utf-8")) // 4,
        cache_create_tokens=0,
        cache_read_tokens=0,
    )


class AgentRunner:
    def __init__(
        self,
        *,
        config: NightshiftConfig,
        context: RunContext,
        cost_tracker: CostTracker,
        timeout_budget: TimeoutBudget | None = None,
        logger: logging.Logger | None = None,
    ) -> None:
        self.config = config
        self.context = context
        self.cost_tracker = cost_tracker
        self.timeout_budget = timeout_budget
        self.logger = logger or logging.getLogger("nightshift")
        self.playbook_renderer = PlaybookRenderer(config=config, context=context)
        self._codex_env_cache: dict[str, str] | None = None
        self._codex_env_cache_time = 0.0

    def run_claude(self, playbook_name: str, *, model: str | None = None, finding_text: str = "", task_file_path: str = "") -> AgentRunResult:
        if shutil.which("claude", path=self.config.subprocess_path) is None:
            raise AgentExecutionError("claude CLI is not available")

        rendered_path = self.playbook_renderer.render(playbook_name, finding_text=finding_text, task_file_path=task_file_path)
        prompt_text = rendered_path.read_text(encoding="utf-8")
        output_path, stderr_log_path = self._artifact_paths("claude", playbook_name)
        self._clear_canonical_findings(playbook_name)
        effective_model = model or self.config.claude_model
        command = [
            "claude",
            "--print",
            "--output-format",
            "json",
            "--dangerously-skip-permissions",
            "--model",
            effective_model,
            "--max-turns",
            str(self.config.max_turns),
            "--system-prompt",
            prompt_text,
            "Begin investigation.",
        ]
        env = self.config.subprocess_env()
        env.pop("CLAUDECODE", None)

        start = time.monotonic()
        try:
            completed = run_subprocess(
                command,
                cwd=self.config.repo_dir,
                env=env,
                timeout_seconds=self.config.agent_timeout_seconds,
                timeout_budget=self.timeout_budget,
                phase_name=f"Claude {playbook_name}",
                logger=self.logger,
            )
        except CommandTimeoutError as exc:
            duration = int(time.monotonic() - start)
            output_text = exc.stdout or ""
            stderr_text = exc.stderr or ""
            self._write_artifacts(output_path, stderr_log_path, output_text, stderr_text)
            cost = self._record_cost(
                engine="claude",
                playbook_name=playbook_name,
                model=effective_model,
                playbook_filename=rendered_path.name,
                usage=extract_claude_cost(output_text),
            )
            partial_result = self._build_result(
                engine="claude",
                playbook_name=playbook_name,
                output_path=output_path,
                stderr_log_path=stderr_log_path,
                archived_findings_path=self.archive_findings(
                    "claude",
                    playbook_name,
                    exit_code=TIMEOUT_EXIT_CODE,
                    semantic_success=False,
                ),
                findings_count=0,
                duration_seconds=duration,
                cost_usd=cost,
                status="timeout",
                return_code=TIMEOUT_EXIT_CODE,
            )
            raise AgentTimeoutError(
                f"{playbook_name} exceeded {_format_seconds(exc.timeout_seconds)}s",
                partial_result=partial_result,
            ) from exc

        duration = int(time.monotonic() - start)
        output_text = completed.stdout or ""
        stderr_text = completed.stderr or ""
        self._write_artifacts(output_path, stderr_log_path, output_text, stderr_text)
        cost = self._record_cost(
            engine="claude",
            playbook_name=playbook_name,
            model=effective_model,
            playbook_filename=rendered_path.name,
            usage=extract_claude_cost(output_text),
        )

        if completed.returncode != 0:
            partial_result = self._build_result(
                engine="claude",
                playbook_name=playbook_name,
                output_path=output_path,
                stderr_log_path=stderr_log_path,
                archived_findings_path=self.archive_findings(
                    "claude",
                    playbook_name,
                    exit_code=completed.returncode,
                    semantic_success=False,
                ),
                findings_count=0,
                duration_seconds=duration,
                cost_usd=cost,
                status="error",
                return_code=completed.returncode,
            )
            raise AgentExecutionError(
                f"Claude {playbook_name} failed with exit {completed.returncode}: {(stderr_text or '').strip()}",
                partial_result=partial_result,
            )

        archived_findings_path = self.archive_findings(
            "claude",
            playbook_name,
            exit_code=0,
            semantic_success=True,
        )
        findings_count = count_findings_in_file(archived_findings_path) if archived_findings_path else 0
        return self._build_result(
            engine="claude",
            playbook_name=playbook_name,
            output_path=output_path,
            stderr_log_path=stderr_log_path,
            archived_findings_path=archived_findings_path,
            findings_count=findings_count,
            duration_seconds=duration,
            cost_usd=cost,
            status="success" if findings_count else "no_findings",
            return_code=0,
        )

    def run_codex(self, playbook_name: str) -> AgentRunResult:
        if not self.config.codex_model:
            raise AgentExecutionError("codex model is not configured")
        if shutil.which("codex", path=self.config.subprocess_path) is None:
            raise AgentExecutionError("codex CLI is not available")

        rendered_path = self.playbook_renderer.render(playbook_name)
        prompt_text = rendered_path.read_text(encoding="utf-8")
        output_path, stderr_log_path = self._artifact_paths("codex", playbook_name)
        self._clear_canonical_findings(playbook_name)
        env, preflight_stderr = self._prepare_codex_env(
            playbook_name=playbook_name,
            stderr_log_path=stderr_log_path,
        )
        command = [
            "codex",
            "exec",
            "-p",
            self.config.codex_model,
            "-C",
            str(self.config.repo_dir),
            "-c",
            'model_reasoning_effort="high"',
            "--dangerously-bypass-approvals-and-sandbox",
            "--ephemeral",
            prompt_text,
        ]
        start = time.monotonic()
        try:
            completed = run_subprocess(
                command,
                cwd=self.config.repo_dir,
                env=env,
                timeout_seconds=self.config.agent_timeout_seconds,
                timeout_budget=self.timeout_budget,
                phase_name=f"Codex {playbook_name}",
                logger=self.logger,
            )
        except CommandTimeoutError as exc:
            duration = int(time.monotonic() - start)
            output_text = exc.stdout or ""
            stderr_text = self._combine_stderr(preflight_stderr, exc.stderr or "")
            self._write_artifacts(output_path, stderr_log_path, output_text, stderr_text)
            cost = self._record_cost(
                engine="codex",
                playbook_name=playbook_name,
                model=_codex_cost_model(self.config.codex_model),
                playbook_filename=rendered_path.name,
                usage=estimate_codex_cost(prompt_text, output_text),
            )
            partial_result = self._build_result(
                engine="codex",
                playbook_name=playbook_name,
                output_path=output_path,
                stderr_log_path=stderr_log_path,
                archived_findings_path=self.archive_findings(
                    "codex",
                    playbook_name,
                    exit_code=TIMEOUT_EXIT_CODE,
                    semantic_success=False,
                ),
                findings_count=0,
                duration_seconds=duration,
                cost_usd=cost,
                status="timeout",
                return_code=TIMEOUT_EXIT_CODE,
            )
            raise AgentTimeoutError(
                f"{playbook_name} exceeded {_format_seconds(exc.timeout_seconds)}s",
                partial_result=partial_result,
            ) from exc

        duration = int(time.monotonic() - start)
        output_text = completed.stdout or ""
        stderr_text = self._combine_stderr(preflight_stderr, completed.stderr or "")
        self._write_artifacts(output_path, stderr_log_path, output_text, stderr_text)
        cost = self._record_cost(
            engine="codex",
            playbook_name=playbook_name,
            model=_codex_cost_model(self.config.codex_model),
            playbook_filename=rendered_path.name,
            usage=estimate_codex_cost(prompt_text, output_text),
        )

        if completed.returncode != 0:
            partial_result = self._build_result(
                engine="codex",
                playbook_name=playbook_name,
                output_path=output_path,
                stderr_log_path=stderr_log_path,
                archived_findings_path=self.archive_findings(
                    "codex",
                    playbook_name,
                    exit_code=completed.returncode,
                    semantic_success=False,
                ),
                findings_count=0,
                duration_seconds=duration,
                cost_usd=cost,
                status="error",
                return_code=completed.returncode,
            )
            raise AgentExecutionError(
                f"Codex {playbook_name} failed with exit {completed.returncode}: {(stderr_text or '').strip()}",
                partial_result=partial_result,
            )

        if not output_text.strip():
            partial_result = self._build_result(
                engine="codex",
                playbook_name=playbook_name,
                output_path=output_path,
                stderr_log_path=stderr_log_path,
                archived_findings_path=self.archive_findings(
                    "codex",
                    playbook_name,
                    exit_code=0,
                    semantic_success=False,
                ),
                findings_count=0,
                duration_seconds=duration,
                cost_usd=cost,
                status="error",
                return_code=0,
            )
            raise AgentExecutionError(
                f"Codex {playbook_name} exited 0 but produced no output",
                partial_result=partial_result,
            )

        archived_findings_path = self.archive_findings(
            "codex",
            playbook_name,
            exit_code=0,
            semantic_success=True,
        )
        findings_count = count_findings_in_file(archived_findings_path) if archived_findings_path else 0
        return self._build_result(
            engine="codex",
            playbook_name=playbook_name,
            output_path=output_path,
            stderr_log_path=stderr_log_path,
            archived_findings_path=archived_findings_path,
            findings_count=findings_count,
            duration_seconds=duration,
            cost_usd=cost,
            status="success" if findings_count else "no_findings",
            return_code=0,
        )

    def archive_findings(
        self,
        engine: str,
        playbook_name: str,
        *,
        exit_code: int,
        semantic_success: bool,
    ) -> Path | None:
        canonical_path = self._canonical_findings_path(playbook_name)
        if not canonical_path.exists():
            return None
        archive_kind = "findings" if exit_code == 0 and semantic_success else "partial"
        self.context.raw_findings_dir.mkdir(parents=True, exist_ok=True)
        archived_path = self.context.raw_findings_dir / f"{engine}-{playbook_name}-{archive_kind}.md"
        canonical_path.replace(archived_path)
        return archived_path

    def _clear_canonical_findings(self, playbook_name: str) -> None:
        self._canonical_findings_path(playbook_name).unlink(missing_ok=True)

    def _canonical_findings_path(self, playbook_name: str) -> Path:
        return self.config.findings_dir / f"{playbook_name}-findings.md"

    def _prepare_codex_env(
        self,
        *,
        playbook_name: str,
        stderr_log_path: Path,
    ) -> tuple[dict[str, str], str]:
        now = time.monotonic()
        if (
            self._codex_env_cache is not None
            and self._codex_env_cache.get("AZURE_OPENAI_API_KEY")
            and (now - self._codex_env_cache_time) < _CODEX_ENV_CACHE_TTL_SECONDS
        ):
            return dict(self._codex_env_cache), ""

        env = self.config.subprocess_env()
        if env.get("AZURE_OPENAI_API_KEY"):
            self._codex_env_cache = dict(env)
            self._codex_env_cache_time = now
            return dict(env), ""

        guard_script = Path(env.get("HOME", str(Path.home()))) / ".claude/scripts/context-guard.sh"
        if not guard_script.is_file():
            message = "Codex auth preflight failed: context-guard.sh is unavailable"
            stderr_log_path.write_text(message + "\n", encoding="utf-8")
            raise AgentExecutionError(message)

        try:
            completed = run_subprocess(
                [
                    "bash",
                    "-c",
                    _CODEX_PREFLIGHT_CAPTURE_SCRIPT,
                    "nightshift-codex-preflight",
                    str(guard_script),
                ],
                cwd=self.config.repo_dir,
                env=env,
                timeout_seconds=self.config.agent_timeout_seconds,
                timeout_budget=self.timeout_budget,
                phase_name=f"Codex auth preflight {playbook_name}",
                logger=self.logger,
            )
        except CommandTimeoutError as exc:
            stderr_text = exc.stderr or ""
            stderr_log_path.write_text(stderr_text, encoding="utf-8")
            raise AgentExecutionError(
                f"Codex auth preflight timed out after {_format_seconds(exc.timeout_seconds)}s",
            ) from exc

        stderr_text = completed.stderr or ""
        if completed.returncode != 0:
            stderr_log_path.write_text(stderr_text, encoding="utf-8")
            raise AgentExecutionError("Codex auth preflight failed")

        updated_env = dict(env)
        for entry in (completed.stdout or "").split("\0"):
            if not entry:
                continue
            key, _, value = entry.partition("=")
            updated_env[key] = value
        updated_env["PATH"] = env["PATH"]

        if not updated_env.get("AZURE_OPENAI_API_KEY"):
            stderr_log_path.write_text(stderr_text, encoding="utf-8")
            raise AgentExecutionError("Codex auth preflight succeeded but no AZURE_OPENAI_API_KEY was exported")

        self._codex_env_cache = updated_env
        self._codex_env_cache_time = time.monotonic()
        return dict(updated_env), stderr_text

    def _artifact_paths(self, engine: str, playbook_name: str) -> tuple[Path, Path]:
        self.context.agent_output_dir.mkdir(parents=True, exist_ok=True)
        self.config.log_dir.mkdir(parents=True, exist_ok=True)
        return (
            self.context.agent_output_dir / f"{engine}-{playbook_name}.json",
            self.config.log_dir / f"{engine}-{playbook_name}-stderr.log",
        )

    @staticmethod
    def _write_artifacts(output_path: Path, stderr_log_path: Path, output_text: str, stderr_text: str) -> None:
        output_path.write_text(output_text, encoding="utf-8")
        stderr_log_path.write_text(stderr_text, encoding="utf-8")

    def _record_cost(
        self,
        *,
        engine: str,
        playbook_name: str,
        model: str,
        playbook_filename: str,
        usage: AgentCost,
    ) -> str:
        cost = self.cost_tracker.record_call(
            agent=f"{engine}-{playbook_name}",
            model=model,
            playbook=playbook_filename,
            input_tokens=usage.input_tokens,
            output_tokens=usage.output_tokens,
            cache_create_tokens=usage.cache_create_tokens,
            cache_read_tokens=usage.cache_read_tokens,
        )
        self._guard_cost_after_call()
        return f"{cost:.4f}"

    def _guard_cost_after_call(self) -> None:
        if not check_cost_cap(self.cost_tracker.total(), self.config.cost_cap_usd):
            self._mark_cost_cap_hit(f"Cost cap reached during {self.context.current_phase}")
            return
        if not self.cost_tracker.check_runaway():
            self._mark_cost_cap_hit(f"Runaway cost pattern detected during {self.context.current_phase}")

    def _mark_cost_cap_hit(self, message: str) -> None:
        if self.context.cost_cap_hit:
            return
        self.context.cost_cap_hit = True
        self.logger.info("%s", message)

    @staticmethod
    def _build_result(
        *,
        engine: str,
        playbook_name: str,
        output_path: Path,
        stderr_log_path: Path,
        archived_findings_path: Path | None,
        findings_count: int,
        duration_seconds: int,
        cost_usd: str,
        status: str,
        return_code: int,
    ) -> AgentRunResult:
        return AgentRunResult(
            engine=engine,
            playbook_name=playbook_name,
            output_path=output_path,
            stderr_log_path=stderr_log_path,
            archived_findings_path=archived_findings_path,
            findings_count=findings_count,
            duration_seconds=duration_seconds,
            cost_usd=cost_usd,
            status=status,
            return_code=return_code,
        )

    @staticmethod
    def _combine_stderr(preflight_stderr: str, command_stderr: str) -> str:
        if preflight_stderr and command_stderr:
            return f"{preflight_stderr.rstrip()}\n{command_stderr}"
        return preflight_stderr or command_stderr


def _codex_cost_model(model: str) -> str:
    return "azure54/gpt-5.4" if model == "azure54" else model


def _payload_result_text(payload: dict[str, object]) -> str | None:
    result_value = payload.get("result")
    if isinstance(result_value, str) and result_value:
        return result_value

    message_value = payload.get("message")
    if isinstance(message_value, dict):
        content_value = message_value.get("content")
        if isinstance(content_value, list):
            content_text = _join_text_content_blocks(content_value)
            if content_text:
                return content_text
    elif isinstance(message_value, str) and message_value:
        return message_value

    content_value = payload.get("content")
    if isinstance(content_value, list):
        content_text = _join_text_content_blocks(content_value)
        if content_text:
            return content_text

    output_text = payload.get("output_text")
    if isinstance(output_text, str) and output_text:
        return output_text

    return None


def _join_text_content_blocks(blocks: list[object]) -> str | None:
    text_blocks: list[str] = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        block_type = block.get("type", "text")
        if block_type != "text":
            continue
        text_value = block.get("text")
        if isinstance(text_value, str) and text_value:
            text_blocks.append(text_value)
    return "\n".join(text_blocks) if text_blocks else None


def _format_seconds(seconds: float) -> str:
    return str(int(seconds)) if float(seconds).is_integer() else f"{seconds:.1f}"

from __future__ import annotations

import logging
import os
import shlex
import signal
import subprocess
import threading
from pathlib import Path
from typing import Mapping, Sequence

from . import timeout as timeout_module
from .timeout import TimeoutBudget


_ACTIVE_PROCESS_GROUPS: set[int] = set()
_ACTIVE_PROCESS_GROUPS_LOCK = threading.Lock()


class CommandTimeoutError(RuntimeError):
    """Raised when a subprocess exceeds its effective timeout."""

    def __init__(
        self,
        command: Sequence[str],
        timeout_seconds: float,
        *,
        stdout: str = "",
        stderr: str = "",
    ) -> None:
        self.command = tuple(command)
        self.timeout_seconds = timeout_seconds
        self.stdout = stdout
        self.stderr = stderr
        super().__init__(
            f"Command timed out after {_format_seconds(timeout_seconds)}s: {shlex.join(list(self.command))}"
        )


def run_subprocess(
    command: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str] | None,
    timeout_seconds: float,
    timeout_budget: TimeoutBudget | None = None,
    phase_name: str,
    logger: logging.Logger | None = None,
) -> subprocess.CompletedProcess[str]:
    effective_timeout = timeout_seconds
    if timeout_budget is not None:
        effective_timeout = timeout_budget.effective_subprocess_timeout(
            timeout_seconds,
            phase_name=phase_name,
        )

    process = subprocess.Popen(
        list(command),
        cwd=cwd,
        env=None if env is None else dict(env),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    _register_active_process_group(process.pid)

    try:
        stdout, stderr = process.communicate(timeout=effective_timeout)
    except subprocess.TimeoutExpired as exc:
        command_text = shlex.join(list(command))
        if logger is not None:
            logger.error(
                "Command timed out after %ss: %s",
                _format_seconds(effective_timeout),
                command_text,
            )
        _terminate_process_group(process, command_text=command_text, logger=logger)
        stdout = _coerce_timeout_output(exc.stdout, encoding=getattr(process.stdout, "encoding", None))
        stderr = _coerce_timeout_output(exc.stderr, encoding=getattr(process.stderr, "encoding", None))
        _close_process_pipes(process)
        _reap_process(process, timeout_seconds=5.0, command_text=command_text, logger=logger)
        raise CommandTimeoutError(
            command,
            effective_timeout,
            stdout=stdout,
            stderr=stderr,
        )
    finally:
        _unregister_active_process_group(process.pid)

    return subprocess.CompletedProcess(list(command), process.returncode, stdout or "", stderr or "")


def terminate_active_process_groups(
    *,
    logger: logging.Logger | None = None,
) -> None:
    """Best-effort termination for currently running child process groups."""
    with _ACTIVE_PROCESS_GROUPS_LOCK:
        process_group_ids = list(_ACTIVE_PROCESS_GROUPS)
        _ACTIVE_PROCESS_GROUPS.clear()

    for process_group_id in process_group_ids:
        try:
            os.killpg(process_group_id, signal.SIGTERM)
        except ProcessLookupError:
            continue
        except OSError as exc:
            if logger is not None:
                logger.warning(
                    "Failed to signal Nightshift child process group %s: %s",
                    process_group_id,
                    exc,
                )


def _register_active_process_group(process_group_id: int) -> None:
    with _ACTIVE_PROCESS_GROUPS_LOCK:
        _ACTIVE_PROCESS_GROUPS.add(process_group_id)


def _unregister_active_process_group(process_group_id: int) -> None:
    with _ACTIVE_PROCESS_GROUPS_LOCK:
        _ACTIVE_PROCESS_GROUPS.discard(process_group_id)


def _terminate_process_group(
    process: subprocess.Popen[str],
    *,
    command_text: str,
    logger: logging.Logger | None,
) -> None:
    if process.poll() is not None:
        return

    grace_seconds = timeout_module.PROCESS_TERMINATION_GRACE_SECONDS
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        process.terminate()

    try:
        process.wait(timeout=grace_seconds)
        return
    except subprocess.TimeoutExpired:
        if logger is not None:
            logger.error(
                "Command ignored SIGTERM after %ss; sending SIGKILL: %s",
                _format_seconds(grace_seconds),
                command_text,
            )

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except OSError:
        process.kill()


def _close_process_pipes(process: subprocess.Popen[str]) -> None:
    for stream in (process.stdout, process.stderr):
        if stream is not None and not stream.closed:
            stream.close()


def _coerce_timeout_output(output: str | bytes | None, *, encoding: str | None) -> str:
    if output is None:
        return ""
    if isinstance(output, bytes):
        return output.decode(encoding or "utf-8", errors="replace")
    return output


def _reap_process(
    process: subprocess.Popen[str],
    *,
    timeout_seconds: float,
    command_text: str,
    logger: logging.Logger | None,
) -> None:
    try:
        process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        if logger is not None:
            logger.warning(
                "Command still had not exited %ss after timeout cleanup; continuing without blocking: %s",
                _format_seconds(timeout_seconds),
                command_text,
            )


def _format_seconds(seconds: float) -> str:
    return str(int(seconds)) if float(seconds).is_integer() else f"{seconds:.1f}"

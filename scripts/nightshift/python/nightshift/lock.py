from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


class LockError(RuntimeError):
    """Raised when the Night Shift PID lock cannot be acquired."""


@dataclass
class PidLock:
    path: Path
    pid: int = os.getpid()
    acquired: bool = False

    def acquire(self) -> None:
        try:
            fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            try:
                os.write(fd, f"{self.pid}\n".encode("utf-8"))
            finally:
                os.close(fd)
            self.acquired = True
            return
        except FileExistsError:
            pass

        # Lock file exists — check if holder is still alive
        initial_contents = self._read_lock_marker()
        try:
            existing_pid = int((initial_contents or "").strip())
        except ValueError:
            existing_pid = 0

        if existing_pid and self._pid_is_active(existing_pid):
            raise LockError(f"Another Nightshift run is already active (pid {existing_pid})")

        # Stale lock — re-read before unlink so we only reclaim the same stale
        # marker we inspected. Residual risk remains if the OS recycles a PID
        # between checks; the atomic create below still prevents double ownership.
        current_contents = self._read_lock_marker()
        if current_contents != initial_contents:
            raise LockError("Lock changed during stale recovery")

        try:
            self.path.unlink()
        except FileNotFoundError:
            pass

        try:
            fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            try:
                os.write(fd, f"{self.pid}\n".encode("utf-8"))
            finally:
                os.close(fd)
            self.acquired = True
        except FileExistsError:
            raise LockError(
                "Lock contention: another process reclaimed the lock during stale recovery"
            )

    def _read_lock_marker(self) -> str | None:
        try:
            return self.path.read_text(encoding="utf-8").strip()
        except OSError:
            return None

    def release(self) -> None:
        if not self.acquired:
            return
        if self.path.exists():
            try:
                current_pid = int(self.path.read_text(encoding="utf-8").strip())
            except ValueError:
                current_pid = self.pid
            if current_pid in {0, self.pid}:
                self.path.unlink(missing_ok=True)
        self.acquired = False

    @staticmethod
    def _pid_is_active(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

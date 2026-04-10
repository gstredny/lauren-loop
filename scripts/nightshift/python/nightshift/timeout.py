from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable


PROCESS_TERMINATION_GRACE_SECONDS = 5


class TotalTimeoutExceeded(RuntimeError):
    """Raised when the total Night Shift runtime budget is exhausted."""


@dataclass
class TimeoutBudget:
    total_timeout_seconds: int | None
    clock: Callable[[], float] = time.monotonic
    started_at: float = field(default_factory=time.monotonic)

    def checkpoint(self, phase_name: str) -> None:
        remaining = self.remaining_seconds
        if remaining is None:
            return
        if remaining <= 0:
            raise TotalTimeoutExceeded(
                f"Total runtime exceeded {self.total_timeout_seconds}s during {phase_name}"
            )

    def effective_subprocess_timeout(
        self,
        requested_timeout_seconds: float,
        *,
        phase_name: str,
        reserve_seconds: float | None = None,
    ) -> float:
        remaining = self.remaining_seconds
        if remaining is None:
            return requested_timeout_seconds

        reserve = PROCESS_TERMINATION_GRACE_SECONDS if reserve_seconds is None else reserve_seconds
        available = remaining - reserve
        if available <= 0:
            raise TotalTimeoutExceeded(
                f"Not enough runtime remaining for {phase_name}: "
                f"{_format_seconds(remaining)}s left, need more than {_format_seconds(reserve)}s"
            )
        return min(requested_timeout_seconds, available)

    def remaining_budget(self) -> float | None:
        return self.remaining_seconds

    def check_after_detective(self) -> bool:
        remaining = self.remaining_budget()
        if remaining is None:
            return False
        return remaining <= 0

    @property
    def remaining_seconds(self) -> float | None:
        if self.total_timeout_seconds is None:
            return None
        return max(0.0, self.total_timeout_seconds - (self.clock() - self.started_at))

    @property
    def elapsed_seconds(self) -> int:
        return int(self.clock() - self.started_at)


def _format_seconds(seconds: float) -> str:
    return str(int(seconds)) if float(seconds).is_integer() else f"{seconds:.1f}"

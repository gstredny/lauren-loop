from __future__ import annotations

from dataclasses import dataclass


@dataclass
class CodexGate:
    state: str = "pending"

    def on_success(self) -> bool:
        if self.state == "pending":
            self.state = "active"
            return True
        return False

    def on_failure(self) -> None:
        self.state = "closed"

    def should_skip(self) -> bool:
        return self.state == "closed"

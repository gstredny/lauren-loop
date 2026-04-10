from __future__ import annotations

from nightshift.codex_gate import CodexGate


def test_gate_starts_pending() -> None:
    gate = CodexGate()

    assert gate.state == "pending"


def test_success_transitions_to_active() -> None:
    gate = CodexGate()

    transitioned = gate.on_success()

    assert transitioned is True
    assert gate.state == "active"


def test_failure_transitions_to_closed() -> None:
    gate = CodexGate()

    gate.on_failure()

    assert gate.state == "closed"


def test_closed_is_terminal() -> None:
    gate = CodexGate(state="closed")

    transitioned = gate.on_success()

    assert transitioned is False
    assert gate.state == "closed"


def test_should_skip_when_closed() -> None:
    gate = CodexGate(state="closed")

    assert gate.should_skip() is True

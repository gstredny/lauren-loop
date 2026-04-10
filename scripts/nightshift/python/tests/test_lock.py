from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from nightshift.lock import LockError, PidLock


def test_stale_lock_is_reclaimed(tmp_path: Path) -> None:
    lock_path = tmp_path / "nightshift.lock"
    lock_path.write_text("999999\n", encoding="utf-8")
    lock = PidLock(lock_path)

    lock.acquire()

    assert lock.acquired is True
    assert lock_path.read_text(encoding="utf-8").strip() == str(lock.pid)
    lock.release()
    assert not lock_path.exists()


def test_active_lock_blocks_second_run(tmp_path: Path) -> None:
    lock_path = tmp_path / "nightshift.lock"
    sleeper = subprocess.Popen(["sleep", "30"])
    try:
        lock_path.write_text(f"{sleeper.pid}\n", encoding="utf-8")
        lock = PidLock(lock_path)
        with pytest.raises(LockError):
            lock.acquire()
    finally:
        sleeper.terminate()
        sleeper.wait(timeout=5)


def test_corrupted_lock_file_reclaimed(tmp_path: Path) -> None:
    lock_path = tmp_path / "nightshift.lock"
    lock_path.write_text("not-a-number\n", encoding="utf-8")
    lock = PidLock(lock_path)

    lock.acquire()

    assert lock.acquired is True
    assert lock_path.read_text(encoding="utf-8").strip() == str(lock.pid)
    lock.release()


def test_stale_recovery_aborts_if_lock_marker_changes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    lock_path = tmp_path / "nightshift.lock"
    lock_path.write_text("999999\n", encoding="utf-8")
    lock = PidLock(lock_path)
    markers = iter(["999999", "123456"])

    monkeypatch.setattr(lock, "_read_lock_marker", lambda: next(markers))

    with pytest.raises(LockError, match="Lock changed during stale recovery"):
        lock.acquire()

    assert lock.acquired is False
    assert lock_path.read_text(encoding="utf-8").strip() == "999999"


def test_release_idempotent(tmp_path: Path) -> None:
    lock_path = tmp_path / "nightshift.lock"
    lock = PidLock(lock_path)

    lock.acquire()
    lock.release()
    lock.release()  # second release should not raise

    assert not lock_path.exists()


def test_release_preserves_other_process_lock(tmp_path: Path) -> None:
    lock_path = tmp_path / "nightshift.lock"
    lock = PidLock(lock_path)
    lock.acquire()

    # Simulate another process stealing the lock file
    lock_path.write_text("12345\n", encoding="utf-8")

    lock.release()

    # File should still exist — release must not remove a lock owned by another PID
    assert lock_path.exists()
    assert lock_path.read_text(encoding="utf-8").strip() == "12345"

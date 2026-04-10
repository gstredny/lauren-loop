from __future__ import annotations

import json
from pathlib import Path

from nightshift.detective_status import DetectiveStatus, DetectiveStatusStore


def test_writes_json_status(tmp_path: Path) -> None:
    store = DetectiveStatusStore(tmp_path)
    status = DetectiveStatus(
        playbook="commit-detective",
        engine="claude",
        status="success",
        duration_seconds=12,
        findings_count=3,
        cost_usd="1.2500",
    )

    path = store.write(status)

    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload == {
        "playbook": "commit-detective",
        "engine": "claude",
        "status": "success",
        "duration_seconds": 12,
        "findings_count": 3,
        "cost_usd": "1.2500",
    }


def test_reads_all_statuses(tmp_path: Path) -> None:
    store = DetectiveStatusStore(tmp_path)
    store.write(
        DetectiveStatus(
            playbook="commit-detective",
            engine="claude",
            status="success",
            duration_seconds=10,
            findings_count=1,
            cost_usd="0.1000",
        )
    )
    store.write(
        DetectiveStatus(
            playbook="commit-detective",
            engine="codex",
            status="no_findings",
            duration_seconds=8,
            findings_count=0,
            cost_usd="0.0500",
        )
    )

    statuses = store.read_all()

    assert [(status.playbook, status.engine, status.status) for status in statuses] == [
        ("commit-detective", "claude", "success"),
        ("commit-detective", "codex", "no_findings"),
    ]


def test_status_values(tmp_path: Path) -> None:
    store = DetectiveStatusStore(tmp_path)

    for value in ("success", "timeout", "error", "no_findings", "skipped", "skipped_timeout"):
        store.write(
            DetectiveStatus(
                playbook=f"{value}-playbook",
                engine="claude",
                status=value,
                duration_seconds=0,
                findings_count=0,
                cost_usd="0.0000",
            )
        )

    assert len(store.read_all()) == 6

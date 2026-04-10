from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path


VALID_DETECTIVE_STATUSES = frozenset(
    {"success", "timeout", "error", "no_findings", "skipped", "skipped_timeout"}
)


@dataclass(frozen=True)
class DetectiveStatus:
    playbook: str
    engine: str
    status: str
    duration_seconds: int
    findings_count: int
    cost_usd: str


class DetectiveStatusStore:
    def __init__(self, directory: Path) -> None:
        self.directory = directory

    def write(self, status: DetectiveStatus) -> Path:
        self._validate(status)
        self.directory.mkdir(parents=True, exist_ok=True)
        path = self.path_for(status.playbook, status.engine)
        path.write_text(json.dumps(asdict(status), indent=2), encoding="utf-8")
        return path

    def read(self, playbook: str, engine: str) -> DetectiveStatus | None:
        path = self.path_for(playbook, engine)
        if not path.exists():
            return None
        return self._from_dict(json.loads(path.read_text(encoding="utf-8")))

    def read_all(self) -> list[DetectiveStatus]:
        statuses: list[DetectiveStatus] = []
        for path in sorted(self.directory.glob("*.json")):
            statuses.append(self._from_dict(json.loads(path.read_text(encoding="utf-8"))))
        return statuses

    def read_many(self, schedule: list[tuple[str, str]]) -> list[DetectiveStatus]:
        statuses: list[DetectiveStatus] = []
        for playbook, engine in schedule:
            status = self.read(playbook, engine)
            if status is not None:
                statuses.append(status)
        return statuses

    def path_for(self, playbook: str, engine: str) -> Path:
        return self.directory / f"{playbook}-{engine}.json"

    @staticmethod
    def _from_dict(payload: dict[str, object]) -> DetectiveStatus:
        status = DetectiveStatus(
            playbook=str(payload["playbook"]),
            engine=str(payload["engine"]),
            status=str(payload["status"]),
            duration_seconds=int(payload["duration_seconds"]),
            findings_count=int(payload["findings_count"]),
            cost_usd=str(payload["cost_usd"]),
        )
        DetectiveStatusStore._validate(status)
        return status

    @staticmethod
    def _validate(status: DetectiveStatus) -> None:
        if status.status not in VALID_DETECTIVE_STATUSES:
            raise ValueError(f"Invalid detective status: {status.status}")

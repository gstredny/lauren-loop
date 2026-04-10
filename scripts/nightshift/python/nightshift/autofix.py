from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Mapping, Sequence

from .git import GitStateMachine
from .subprocess_runner import run_subprocess


class AutofixArtifactError(RuntimeError):
    """Raised when Lauren Loop artifacts fail the Python-side contract."""


class AutofixScopeViolation(RuntimeError):
    """Raised when iteration changes escape the task-scoped allow-list."""

    def __init__(self, out_of_scope_paths: Sequence[str]) -> None:
        self.out_of_scope_paths = list(out_of_scope_paths)
        super().__init__(f"out-of-scope changes detected: {', '.join(self.out_of_scope_paths)}")


@dataclass(frozen=True)
class IterationChanges:
    tracked_files: tuple[str, ...]
    new_untracked_files: tuple[str, ...]

    @property
    def all_files(self) -> tuple[str, ...]:
        return self.tracked_files + self.new_untracked_files


def extract_goal_from_task(task_path: Path) -> str | None:
    if not task_path.exists():
        return None

    found = False
    capture = False
    lines: list[str] = []
    for raw_line in task_path.read_text(encoding="utf-8").splitlines():
        normalized_line = raw_line.strip()
        if normalized_line.startswith("## Goal:"):
            inline = normalized_line[len("## Goal:"):].strip()
            found = True
            if inline:
                lines.append(inline)
                break
            capture = True
            continue
        if normalized_line == "## Goal":
            found = True
            capture = True
            continue
        if capture and normalized_line.startswith("## ") and not normalized_line.startswith("###"):
            break
        if capture:
            lines.append(raw_line)

    if not found:
        return None

    compact = " ".join(line.strip() for line in lines if line.strip()).strip()
    return compact or None


def run_lauren_loop(
    slug: str,
    goal: str,
    repo_root: Path,
    timeout: int,
    *,
    env: Mapping[str, str],
) -> object:
    return run_subprocess(
        ["bash", str(repo_root / "lauren-loop-v2.sh"), slug, goal, "--strict"],
        cwd=repo_root,
        env=env,
        timeout_seconds=timeout,
        phase_name=f"Lauren Loop {slug}",
    )


def parse_lauren_manifest(manifest_path: Path) -> tuple[str | None, str | None]:
    if not manifest_path.exists():
        return None, None
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None, None

    final_status = payload.get("final_status")
    if not isinstance(final_status, str) or not final_status:
        final_status = None

    total_cost = payload.get("total_cost_usd")
    if isinstance(total_cost, (int, float)):
        total_cost_value = f"{float(total_cost):.4f}"
    elif isinstance(total_cost, str):
        try:
            total_cost_value = f"{float(total_cost):.4f}"
        except ValueError:
            total_cost_value = None
    else:
        total_cost_value = None

    return final_status, total_cost_value


def append_autofix_section(
    task_path: Path,
    *,
    status: str,
    run_date: str,
    run_id: str,
    exit_code: int,
    cost: str,
) -> None:
    existing = task_path.read_text(encoding="utf-8").rstrip()
    lines = [
        existing,
        "",
        f"## Autofix: {status}",
        f"- Date: {run_date}",
        f"- Run ID: {run_id}",
        f"- Lauren Loop exit code: {exit_code}",
        "- Cost: unknown" if cost == "unknown" else f"- Cost: ${cost}",
    ]
    task_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def extract_task_severity(task_path: Path) -> str | None:
    if not task_path.exists():
        return None

    in_context = False
    in_severity_section = False
    for raw_line in task_path.read_text(encoding="utf-8").splitlines():
        normalized = raw_line.replace("**", "").strip()
        if raw_line == "## Context":
            in_context = True
            in_severity_section = False
            continue
        if raw_line.startswith("## ") and raw_line != "## Context":
            if in_severity_section:
                return None
            in_context = False
        if in_context:
            normalized = normalized.lstrip("-* ").strip()
            if normalized.lower().startswith("severity:"):
                severity = normalized.split(":", 1)[1].strip().lower().split()[0]
                if severity in {"critical", "major", "minor", "observation"}:
                    return severity
        if raw_line.startswith("## Severity:"):
            severity = raw_line.split(":", 1)[1].strip().lower().split()[0]
            if severity in {"critical", "major", "minor", "observation"}:
                return severity
            return None
        if raw_line == "## Severity":
            in_severity_section = True
            continue
        if in_severity_section:
            severity = normalized.lower().split()[0] if normalized else ""
            if severity in {"critical", "major", "minor", "observation"}:
                return severity
    return None


def task_artifact_dir(task_path: Path) -> Path:
    if task_path.name == "task.md":
        return task_path.parent
    if task_path.suffix == ".md":
        return task_path.with_suffix("")
    raise ValueError(f"Unsupported task path: {task_path}")


def lauren_manifest_path(task_path: Path) -> Path:
    return task_artifact_dir(task_path) / "competitive" / "run-manifest.json"


def lauren_scope_triage_path(task_path: Path) -> Path:
    return task_artifact_dir(task_path) / "competitive" / "execution-scope-triage.json"


def task_slug_from_path(task_path: Path) -> str:
    if task_path.name == "task.md":
        base_name = task_path.parent.name
    else:
        base_name = task_path.stem
    parts = base_name.split("-", 3)
    if len(parts) == 4 and all(part.isdigit() for part in parts[:3]):
        return parts[3]
    return base_name


def parse_scope_triage_captured_files(triage_path: Path) -> list[str] | None:
    if not triage_path.exists():
        return None
    try:
        payload = json.loads(triage_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None

    captured = payload.get("captured_files")
    if not isinstance(captured, list):
        return None

    normalized: list[str] = []
    seen: set[str] = set()
    for entry in captured:
        if not isinstance(entry, str):
            return None
        repo_path = _normalize_repo_path(entry)
        if repo_path is None:
            return None
        if repo_path in seen:
            continue
        normalized.append(repo_path)
        seen.add(repo_path)
    return normalized


def collect_iteration_changes(
    git: GitStateMachine,
    before_snapshot: str | None,
    after_snapshot: str | None,
    before_untracked: Sequence[str],
    after_untracked: Sequence[str],
) -> IterationChanges:
    tracked_files = tuple(_dedupe(git.list_changed_files(before_snapshot, after_snapshot)))
    before_untracked_set = set(before_untracked)
    new_untracked_files = tuple(
        repo_path
        for repo_path in _dedupe(after_untracked)
        if repo_path not in before_untracked_set
    )
    return IterationChanges(
        tracked_files=tracked_files,
        new_untracked_files=new_untracked_files,
    )


def restore_iteration_changes(
    git: GitStateMachine,
    before_snapshot: str | None,
    after_snapshot: str | None,
    before_untracked: Sequence[str],
    after_untracked: Sequence[str],
) -> IterationChanges:
    changes = collect_iteration_changes(
        git,
        before_snapshot,
        after_snapshot,
        before_untracked,
        after_untracked,
    )
    git.restore_tracked_paths(changes.tracked_files, source_ref=before_snapshot)
    git.remove_untracked_paths(changes.new_untracked_files)
    return changes


def stage_autofix_changes(
    git: GitStateMachine,
    task_path: Path,
    before_snapshot: str | None,
    after_snapshot: str | None,
    before_untracked: Sequence[str],
    after_untracked: Sequence[str],
) -> list[Path]:
    triage_path = lauren_scope_triage_path(task_path)
    allow_list = parse_scope_triage_captured_files(triage_path)
    if allow_list is None:
        raise AutofixArtifactError(
            f"scope triage artifact {triage_path} was missing or malformed"
        )

    changes = collect_iteration_changes(
        git,
        before_snapshot,
        after_snapshot,
        before_untracked,
        after_untracked,
    )
    task_dir = task_artifact_dir(task_path)
    task_dir_rel: str | None = None
    task_rel: str | None = None
    try:
        task_dir_rel = str(task_dir.resolve().relative_to(git.repo_dir.resolve()))
        task_rel = str(task_path.resolve().relative_to(git.repo_dir.resolve()))
    except ValueError:
        task_dir_rel = None
        task_rel = None

    allowed_paths = set(allow_list)
    if task_rel:
        allowed_paths.add(task_rel)

    relevant_paths: list[str] = []
    out_of_scope_paths: list[str] = []
    for repo_path in changes.all_files:
        if _should_skip_task_artifact(repo_path, task_dir_rel):
            continue
        if repo_path not in allowed_paths:
            out_of_scope_paths.append(repo_path)
            continue
        relevant_paths.append(repo_path)

    if out_of_scope_paths:
        raise AutofixScopeViolation(out_of_scope_paths)

    if not relevant_paths:
        return []

    stage_paths = [git.repo_dir / repo_path for repo_path in relevant_paths]
    git.stage_paths(stage_paths)
    return stage_paths


def _should_skip_task_artifact(repo_path: str, task_dir_rel: str | None) -> bool:
    if not task_dir_rel:
        return False
    return repo_path.startswith(f"{task_dir_rel}/competitive/") or repo_path.startswith(f"{task_dir_rel}/logs/")


def _dedupe(paths: Sequence[str]) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for repo_path in paths:
        if repo_path in seen:
            continue
        ordered.append(repo_path)
        seen.add(repo_path)
    return ordered


def _normalize_repo_path(repo_path: str) -> str | None:
    candidate = repo_path.strip().replace("\\", "/")
    if not candidate:
        return None
    normalized = str(PurePosixPath(candidate))
    if normalized in {"", "."} or normalized.startswith("/") or normalized == ".." or normalized.startswith("../"):
        return None
    return normalized

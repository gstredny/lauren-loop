from __future__ import annotations

import logging
import re
import shutil
from pathlib import Path

from . import autofix as autofix_helpers
from . import backlog as backlog_helpers
from . import bridge as bridge_helpers
from . import task_context as task_context_helpers
from . import task_writer as task_writer_helpers
from . import validation as validation_helpers
from .agents import (
    AgentExecutionError,
    AgentRunResult,
    AgentRunner,
    AgentTimeoutError,
    read_claude_result_text,
)
from .codex_gate import CodexGate
from .config import NightshiftConfig
from .cost import CostTracker, weekly_summary
from .detective_status import DetectiveStatus, DetectiveStatusStore
from .digest import (
    MANAGER_REQUIRED_BODY_HEADINGS,
    append_orchestrator_summary,
    count_digest_rows_in_section,
    count_total_findings,
    manager_top_findings_from_digest,
    rebuild_manager_inputs,
    rewrite_manager_digest,
    validate_digest_headings,
    write_empty_manager_digest_body,
    write_fallback_digest,
    write_findings_manifest,
)
from .git import GitStateMachine
from .notify import build_summary as build_notify_summary
from .notify import send_webhook
from .playbook import PlaybookRenderer
from .runtime import RunContext
from .ship import ShipError, ShipResult, Shipper
from .suppression import (
    annotate_digest_with_fingerprints,
    apply_suppressions,
    render_expired_suppressions_section,
    render_expiring_soon_section,
    render_findings_missing_rule_key_section,
    render_suppressed_findings_section,
    write_apply_artifacts,
)
from .subprocess_runner import CommandTimeoutError
from .timeout import TimeoutBudget, TotalTimeoutExceeded


class NightshiftOrchestrator:
    DETECTIVE_ENGINES = ("claude", "codex")
    _TASK_FILES_CREATED_RE = re.compile(
        r"^(- \*\*Task files created:\*\* )\d+(\s+\(critical: \d+, major: \d+\))?$"
    )
    _VALIDATED_TASKS_RE = re.compile(r"^(- \*\*Validated tasks:\*\* )\d+$")
    _INVALID_TASKS_RE = re.compile(r"^(- \*\*Invalid tasks:\*\* )\d+$")

    def __init__(
        self,
        *,
        config: NightshiftConfig,
        context: RunContext,
        git: GitStateMachine,
        agents: AgentRunner,
        shipper: Shipper,
        cost_tracker: CostTracker,
        timeout_budget: TimeoutBudget,
        logger: logging.Logger | None = None,
        detective_playbooks: tuple[str, ...] | None = None,
        implemented_detectives: frozenset[str] | None = None,
    ) -> None:
        self.config = config
        self.context = context
        self.git = git
        self.agents = agents
        self.shipper = shipper
        self.cost_tracker = cost_tracker
        self.timeout_budget = timeout_budget
        self.logger = logger or logging.getLogger("nightshift")
        self.detective_playbooks = detective_playbooks or self.config.detective_playbooks
        self.implemented_detectives = implemented_detectives or frozenset(self.detective_playbooks)
        self.detective_status_store = DetectiveStatusStore(self.context.detective_status_dir)

    def run(self) -> int:
        self.cost_tracker.init(self.context.run_id)
        try:
            self.phase_setup()
            self.phase_detectives()
            self.phase_manager_merge()
            self.phase_task_writing()
            self.phase_validation()
            self.phase_autofix()
            self.phase_bridge()
            self.phase_backlog()
            if not self._has_digest_artifact():
                self.write_digest()
            self.phase_ship()
        except Exception as exc:  # pragma: no cover - integration path
            self.context.add_failure(str(exc))
            self.logger.error("%s", exc)
        finally:
            if not self._has_digest_artifact():
                self.write_digest()
            self.phase_cleanup()
        return self.context.exit_code

    def phase_setup(self) -> None:
        self.context.current_phase = "Setup"
        self.timeout_budget.checkpoint(self.context.current_phase)
        branch_name = (
            f"nightshift/smoke-{self.context.run_date}-{self.context.run_clock}"
            if self.context.smoke
            else f"nightshift/{self.context.run_date}"
        )
        self.context.run_branch = self.git.bootstrap_run_branch(
            base_branch=self.config.base_branch,
            branch_name=branch_name,
        )
        self.context.branch_created = True
        self.logger.info("Nightshift branch ready: %s", self.context.run_branch)

    def phase_detectives(self) -> None:
        self.context.current_phase = "Detective Runs"
        self.timeout_budget.checkpoint(self.context.current_phase)
        schedule = self._detective_schedule()
        codex_gate = CodexGate(state="pending" if self.config.codex_model else "closed")

        if self.context.dry_run:
            for playbook_name, engine in schedule:
                self.logger.info("DRY RUN: would run %s/%s", engine, playbook_name)
                self._write_detective_status(
                    playbook=playbook_name,
                    engine=engine,
                    status="skipped",
                    duration_seconds=0,
                    findings_count=0,
                    cost_usd="0.0000",
                )
            return

        for index, (playbook_name, engine) in enumerate(schedule):
            try:
                self.timeout_budget.checkpoint(self.context.current_phase)
            except TotalTimeoutExceeded as exc:
                self._record_timeout_exhaustion(str(exc), schedule[index:])
                break

            if engine == "codex" and codex_gate.should_skip():
                self.logger.info("Codex gate closed, skipping %s", playbook_name)
                self._write_detective_status(
                    playbook=playbook_name,
                    engine=engine,
                    status="skipped",
                    duration_seconds=0,
                    findings_count=0,
                    cost_usd="0.0000",
                )
                continue

            try:
                result = self._run_detective(engine, playbook_name)
            except TotalTimeoutExceeded as exc:
                self._record_timeout_exhaustion(str(exc), schedule[index:])
                break
            except AgentTimeoutError as exc:
                self.context.add_warning(str(exc))
                self.logger.error("%s", exc)
                self._handle_detective_result(
                    exc.partial_result,
                    codex_gate=codex_gate,
                    error_message=str(exc),
                )
            except AgentExecutionError as exc:
                self.context.add_warning(str(exc))
                self.logger.error("%s", exc)
                result = exc.partial_result or AgentRunResult(
                    engine=engine,
                    playbook_name=playbook_name,
                    output_path=self.context.agent_output_dir / f"{engine}-{playbook_name}.json",
                    stderr_log_path=self.config.log_dir / f"{engine}-{playbook_name}-stderr.log",
                    archived_findings_path=None,
                    findings_count=0,
                    duration_seconds=0,
                    cost_usd="0.0000",
                    status="error",
                    return_code=1,
                )
                self._handle_detective_result(
                    result,
                    codex_gate=codex_gate,
                    error_message=str(exc),
                )
            else:
                self._handle_detective_result(result, codex_gate=codex_gate)

            if self.context.cost_cap_hit:
                self.logger.info("Detective runs halted because the run is already cost-capped")
                break

            if self.timeout_budget.check_after_detective():
                self._record_timeout_exhaustion(
                    self._timeout_exceeded_message(),
                    schedule[index + 1 :],
                )
                break

    def phase_manager_merge(self) -> None:
        self.context.current_phase = "Manager Merge"
        self.timeout_budget.checkpoint(self.context.current_phase)
        self.context.run_clean = False

        if self.context.dry_run:
            self.logger.info("DRY RUN: skipping manager merge")
            self.context.run_clean = True
            self._write_manager_fallback("dry-run-skipped", "Manager Merge")
            return

        if self.context.failures:
            self.logger.info("Setup failed, skipping manager merge")
            self._write_manager_fallback("setup-failed", "Manager Merge")
            return

        if self.context.cost_cap_hit:
            self.logger.info("Cost cap reached before manager merge; building fallback digest")
            self.context.task_file_count = 0
            self.write_digest(phase_reached=self.context.current_phase)
            self.context.digest_stageable = True
            return

        rebuild_manager_inputs(
            self.config.findings_dir, self.context.raw_findings_dir,
            self.detective_playbooks, self.context.run_date, self.detective_status_store,
        )
        self.context.total_findings_available = count_total_findings(self.config.findings_dir)
        suppression_result = apply_suppressions(
            self.config.findings_dir,
            suppressions_path=self.config.repo_dir / "docs/nightshift/suppressions.yaml",
            digests_dir=self.config.repo_dir / "docs/nightshift/digests",
            run_date=self.context.run_date,
        )
        write_apply_artifacts(self.context.suppression_artifacts_dir, suppression_result)
        self.context.findings_eligible_for_ranking = suppression_result.eligible_total
        self.context.suppressed_finding_count = suppression_result.suppressed_count
        for warning in suppression_result.warnings:
            self.context.add_warning(warning)
            self.logger.warning("%s", warning)

        if self.context.total_findings_available == 0:
            self.logger.info("No findings available, skipping manager merge")
            if not self.context.failures:
                self.context.run_clean = True
            self._write_manager_fallback("no-findings", "Manager Merge")
            return

        self.timeout_budget.checkpoint(self.context.current_phase)

        digest_path = self.context.writable_digest_path
        manager_failed = False
        manager_failure_detail = ""
        if self.context.findings_eligible_for_ranking == 0:
            write_empty_manager_digest_body(digest_path)
        else:
            try:
                self.agents.run_claude("manager-merge", model=self.config.manager_model)
            except Exception as exc:
                manager_failed = True
                manager_failure_detail = f"{type(exc).__name__}: {exc}"
                self.context.add_failure(f"Manager agent failed: {manager_failure_detail}")
                self.logger.error("Manager agent failed: %s", manager_failure_detail)

        if self.context.cost_cap_hit:
            if digest_path.exists() and digest_path.stat().st_size > 0:
                self.context.digest_stageable = True
                self.context.digest_path = digest_path
            else:
                self.write_digest(phase_reached=self.context.current_phase)
                self.context.digest_stageable = True
            self.logger.info("Manager merge halted because the run is already cost-capped")
            return

        if manager_failed:
            self.context.manager_contract_failed = True
            self.context.digest_stageable = True
            self._write_manager_fallback("manager-failed", "Manager Merge")
            return

        if not digest_path.exists() or digest_path.stat().st_size == 0:
            self.context.manager_contract_failed = True
            self.context.digest_stageable = True
            self.context.add_failure("Manager produced no digest artifact")
            self.logger.error("Manager produced no digest artifact")
            self._write_manager_fallback("no-digest-artifact", "Manager Merge")
            return

        missing = validate_digest_headings(digest_path)
        if missing:
            self.context.manager_contract_failed = True
            self.context.digest_stageable = False
            self.context.digest_path = digest_path
            self.context.add_failure(f"Manager digest missing headings: {', '.join(missing)}")
            self.context.add_warning("Manager output failed contract validation; raw output preserved")
            self.logger.warning("Manager output failed contract validation; raw output preserved")
            return

        top_count = len(manager_top_findings_from_digest(digest_path))
        minor_count = count_digest_rows_in_section(digest_path, "## Minor & Observation Findings")
        if self.context.findings_eligible_for_ranking > 0 and top_count + minor_count == 0:
            self.context.manager_contract_failed = True
            self.context.digest_stageable = False
            self.context.digest_path = digest_path
            self.context.add_failure("Manager digest has empty ranked findings table after suppression filtering")
            self.context.add_warning("Manager output failed contract validation; raw output preserved")
            self.logger.warning("Manager output failed contract validation; raw output preserved")
            return

        if not write_findings_manifest(self.context.findings_manifest_path, digest_path):
            self.context.manager_contract_failed = True
            self.context.digest_stageable = False
            self.context.digest_path = digest_path
            self.context.add_failure("Failed to write findings manifest")
            self.context.add_warning("Manager output failed contract validation; raw output preserved")
            self.logger.warning("Manager output failed contract validation; raw output preserved")
            return

        rewrite_manager_digest(
            digest_path, run_date=self.context.run_date, run_id=self.context.run_id,
            total_findings=self.context.total_findings_available,
            eligible_findings=self.context.findings_eligible_for_ranking,
            suppressed_count=self.context.suppressed_finding_count,
            task_file_count=self.context.task_file_count,
            detective_playbooks=self.detective_playbooks,
            detective_status_store=self.detective_status_store,
            findings_dir=self.config.findings_dir,
            suppression_sections=(
                render_suppressed_findings_section(suppression_result),
                render_expired_suppressions_section(suppression_result),
                render_expiring_soon_section(suppression_result),
                render_findings_missing_rule_key_section(suppression_result),
            ),
        )
        annotate_digest_with_fingerprints(digest_path, self.config.findings_dir)

        append_orchestrator_summary(
            digest_path, run_id=self.context.run_id,
            branch=self.context.run_branch or "not-created",
            phase_reached=self.context.current_phase,
            total_findings=self.context.total_findings_available,
            task_file_count=self.context.task_file_count,
            total_cost=self.cost_tracker.total_value(),
            warnings=self.context.warnings, failures=self.context.failures,
        )
        self.context.digest_stageable = True
        self.context.digest_path = digest_path
        self.logger.info("Manager merge complete: %s ranked findings, digest at %s", top_count, digest_path)

    def _write_manager_fallback(self, outcome: str, phase: str) -> None:
        digest_path = self.context.writable_digest_path
        write_fallback_digest(
            digest_path, run_date=self.context.run_date, run_id=self.context.run_id,
            mode_label=self.context.mode_label, outcome_label=outcome, phase_reached=phase,
            branch=self.context.run_branch or "not-created",
            total_findings=self.context.total_findings_available,
            task_file_count=self.context.task_file_count,
            total_cost=self.cost_tracker.total_value(),
            warning_notes=self.context.warnings, failure_notes=self.context.failures,
            detective_statuses=self.detective_status_store.read_many(self._detective_schedule()),
            raw_findings_paths=sorted(self.context.raw_findings_dir.glob("*-findings.md")),
        )
        self.context.digest_path = digest_path

    def phase_task_writing(self) -> None:
        self.context.current_phase = "Task Writing"
        self.timeout_budget.checkpoint(self.context.current_phase)
        self.context.task_file_count = 0

        if self.context.manager_contract_failed:
            self.logger.info("Task writing skipped because manager contract failed")
            self._write_empty_task_manifest()
            return

        if self.context.cost_cap_hit:
            self.logger.info("Task writing skipped because the run is already cost-capped")
            return

        findings_manifest_path = self.context.findings_manifest_path
        if not findings_manifest_path.exists() or findings_manifest_path.stat().st_size == 0:
            self.logger.info("Task writing: 0 findings to process")
            self._write_empty_task_manifest()
            return

        total_findings = len([line for line in findings_manifest_path.read_text(encoding="utf-8").splitlines() if line.strip()])
        parsed_findings = task_writer_helpers.parse_findings_manifest(findings_manifest_path)
        malformed_count = max(0, total_findings - len(parsed_findings))
        eligible_findings: list[tuple[str, str, str, str]] = []
        severity_skipped = 0
        for rank, severity, category, title in parsed_findings:
            normalized_severity = severity.lower()
            if not self._severity_allowed(normalized_severity, self.config.task_writer_min_severity):
                severity_skipped += 1
                continue
            eligible_findings.append((rank, normalized_severity, category, title))

        if self.context.smoke and len(eligible_findings) > 1:
            self.logger.info("Smoke mode: capping task writing to 1 task")
            eligible_findings = eligible_findings[:1]

        task_limit = min(len(eligible_findings), self.config.task_writer_max_tasks)
        cap_skipped = max(0, len(eligible_findings) - task_limit)
        eligible_findings = eligible_findings[:task_limit]

        created_paths: list[Path] = []
        created_count = 0
        rejected_count = 0
        failed_count = malformed_count
        budget_skipped = 0
        task_base_dir = self.config.repo_dir / "docs" / "tasks" / "open"
        digest_path = self.context.digest_path or self.context.writable_digest_path
        task_writer_playbook = self.config.playbooks_dir / "task-writer.md"
        if not task_writer_playbook.is_file():
            self.context.add_failure(f"Task writer playbook missing or unreadable: {task_writer_playbook}")
            self.logger.error("Task writer playbook missing or unreadable: %s", task_writer_playbook)
            self._write_empty_task_manifest()
            return

        playbook_renderer = PlaybookRenderer(config=self.config, context=self.context)
        existing_open_tasks_context = task_context_helpers.build_existing_open_tasks_context(task_base_dir)

        for index, (rank, severity, category, title) in enumerate(eligible_findings):
            remaining_budget = self._remaining_budget()
            if remaining_budget < self.config.task_writer_min_budget:
                budget_skipped = len(eligible_findings) - index
                self.logger.info(
                    "Task writing: insufficient budget remaining ($%.4f of $%.4f needed)",
                    remaining_budget,
                    self.config.task_writer_min_budget,
                )
                break

            self.timeout_budget.checkpoint(self.context.current_phase)
            finding_text = task_writer_helpers.build_finding_text(
                rank, severity, category, title,
                digest_path=digest_path,
                findings_dir=self.config.findings_dir,
                repo_dir=self.config.repo_dir,
                existing_open_tasks_context=existing_open_tasks_context,
            )
            try:
                rendered_path = playbook_renderer.render("task-writer", finding_text=finding_text)
                shutil.copyfile(rendered_path, self.context.rendered_dir / f"task-writer-rank-{rank}.md")
            except (FileNotFoundError, OSError) as exc:
                self.context.add_failure(f"Task writer prompt snapshot failed for {title}: {exc}")
                self.logger.error("Task writer prompt snapshot failed for %s: %s", title, exc)
                self._write_empty_task_manifest()
                return

            if self.context.dry_run:
                self.logger.info(
                    "DRY RUN: would write task for: %s (severity: %s, remaining: $%.4f, minimum reserve: $%.4f)",
                    title,
                    severity,
                    remaining_budget,
                    self.config.task_writer_min_budget,
                )
                continue

            try:
                result = self.agents.run_claude(
                    "task-writer",
                    model=self.config.manager_model,
                    finding_text=finding_text,
                    artifact_suffix=f"rank-{rank}",
                )
                task_writer_text = read_claude_result_text(result.output_path) or ""
            except (AgentExecutionError, AgentTimeoutError) as exc:
                partial_result = exc.partial_result
                task_writer_text = (
                    read_claude_result_text(partial_result.output_path)
                    if partial_result is not None
                    else None
                ) or ""
                self.logger.warning("Task writer failed for %s: %s", title, exc)
                failed_count += 1
            except Exception as exc:
                self.logger.warning("Task writer failed for %s: %s", title, exc)
                failed_count += 1
            else:
                result_status = task_writer_helpers.parse_task_writer_result(task_writer_text)
                if result_status == "CREATED":
                    task_content = task_writer_helpers.extract_task_file_content(task_writer_text)
                    if task_content is None:
                        self.logger.warning("Task writer malformed output for: %s", title)
                        failed_count += 1
                    else:
                        task_slug = task_writer_helpers.slug_from_title(title) or f"finding-{rank}"
                        task_path = task_writer_helpers.resolve_target_path(task_base_dir, self.context.run_date, task_slug)
                        if task_path is None:
                            self.logger.warning("Task writer could not resolve path for: %s", title)
                            failed_count += 1
                        else:
                            try:
                                task_writer_helpers.write_task_file(task_path, task_content)
                            except OSError as exc:
                                self.logger.warning("Task writer could not write task file for %s: %s", title, exc)
                                failed_count += 1
                            else:
                                created_paths.append(task_path)
                                created_count += 1
                elif result_status == "REJECTED":
                    reason = task_writer_helpers.extract_task_writer_rejection_reason(task_writer_text) or "no reason provided"
                    self.logger.info("Task writer rejected: %s — %s", title, reason)
                    rejected_count += 1
                else:
                    self.logger.warning("Task writer malformed output for: %s", title)
                    failed_count += 1

            if self.context.cost_cap_hit:
                budget_skipped = len(eligible_findings) - index - 1
                self.logger.info("Task writing halted because the run is already cost-capped")
                break

        try:
            task_writer_helpers.write_task_manifest(self.context.manager_task_manifest_path, created_paths)
        except OSError as exc:
            self.context.add_failure(f"Task writing manifest write failed: {self.context.manager_task_manifest_path} ({exc})")
            self.logger.error("Task writing manifest write failed: %s", self.context.manager_task_manifest_path)
            return

        self.context.task_file_count = created_count
        self._patch_digest_counts(task_file_count=created_count)

        if created_paths:
            self._stage_repo_paths(created_paths, failure_message="Task writing staging failed")

        self.logger.info(
            "Task writing: %s created, %s rejected, %s failed, %s skipped (severity/budget) out of %s findings",
            created_count,
            rejected_count,
            failed_count,
            severity_skipped + cap_skipped + budget_skipped,
            total_findings,
        )

    def phase_validation(self) -> None:
        self.context.current_phase = "Validation"
        self.timeout_budget.checkpoint(self.context.current_phase)
        self.context.validated_tasks = []

        if self.context.dry_run:
            self.logger.info("Dry-run enabled: skipping validation because task-writer files are not produced")
            return

        if self.context.manager_contract_failed:
            self.logger.info("Validation skipped because manager contract failed")
            return

        if self.context.cost_cap_hit:
            self.logger.info("Validation skipped because the run is already cost-capped")
            return

        manifest_path = self.context.manager_task_manifest_path
        if not manifest_path.exists():
            self.logger.info("Validation manifest missing at %s; 0 fresh tasks to validate", manifest_path)
            return
        if manifest_path.stat().st_size == 0:
            self.logger.info("Task writing produced no task files. Skipping validation.")
            return

        validation_playbook = self.config.playbooks_dir / "validation-agent.md"
        if not validation_playbook.is_file():
            self.context.add_failure(f"Validation playbook missing or unreadable: {validation_playbook}")
            self.logger.error("Validation playbook missing or unreadable: %s", validation_playbook)
            return

        task_files = [
            Path(line.strip())
            for line in manifest_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        if not task_files:
            self.logger.info("Validation: 0 validated, 0 invalid out of 0 total")
            return

        validated: list[Path] = []
        mutated_paths: list[Path] = []
        invalid_count = 0

        for index, task_path in enumerate(task_files, start=1):
            self.timeout_budget.checkpoint(self.context.current_phase)
            task_rel = self._repo_relative_display(task_path)
            if not task_path.exists():
                reasons = [f"- INVALID:path — {task_rel} not found"]
                invalid_count += 1
                try:
                    validation_helpers.mutate_task_failed(task_path, reasons)
                    mutated_paths.append(task_path)
                except OSError:
                    self.context.add_warning(f"Could not append validation failure for {task_rel}: task file is missing")
                self.logger.info("Invalid task: %s", task_rel)
                continue

            failed_checks: list[str] = []
            try:
                result = self.agents.run_claude(
                    "validation-agent",
                    model=self.config.manager_model,
                    task_file_path=str(task_path),
                    artifact_suffix=self._validation_artifact_suffix(task_path, index),
                )
                validation_text = read_claude_result_text(result.output_path) or ""
                validation_status = validation_helpers.parse_validation_result(validation_text)
                failed_checks = validation_helpers.extract_validation_failed_checks(validation_text)
            except (AgentExecutionError, AgentTimeoutError) as exc:
                partial_result = exc.partial_result
                validation_text = (
                    read_claude_result_text(partial_result.output_path)
                    if partial_result is not None
                    else None
                ) or ""
                validation_status = "INVALID"
                failed_checks = validation_helpers.extract_validation_failed_checks(validation_text)
                exit_code = partial_result.return_code if partial_result is not None else 1
                failed_checks.insert(0, f"- INVALID:validation — validation agent exited {exit_code} for {task_rel}")
                self.logger.warning("Validation failed for %s: %s", task_rel, exc)
            except Exception as exc:
                validation_status = "INVALID"
                failed_checks = [f"- INVALID:validation — validation agent failed for {task_rel}: {exc}"]
                self.logger.warning("Validation failed for %s: %s", task_rel, exc)

            if validation_status == "VALIDATED":
                validated.append(task_path)
                try:
                    validation_helpers.mutate_task_validated(task_path, run_date=self.context.run_date)
                    mutated_paths.append(task_path)
                except OSError:
                    self.context.add_warning(f"Could not append validation success for {task_rel}: task file is not writable")
                self.logger.info("Validated task: %s", task_rel)
                if self.context.cost_cap_hit:
                    self.logger.info("Validation halted because the run is already cost-capped")
                    break
                continue

            invalid_count += 1
            if validation_status is None:
                failed_checks = ["- INVALID:validation — validation agent produced no parseable '### Validation Result:' block"]
            elif not failed_checks:
                failed_checks = ["- INVALID:validation — validation agent returned INVALID without failure details"]
            try:
                validation_helpers.mutate_task_failed(task_path, failed_checks)
                mutated_paths.append(task_path)
            except OSError:
                self.context.add_warning(f"Could not append validation failure for {task_rel}: task file is not writable")
            self.logger.info("Invalid task: %s", task_rel)

            if self.context.cost_cap_hit:
                self.logger.info("Validation halted because the run is already cost-capped")
                break

        self.context.validated_tasks = validated
        self._patch_digest_counts(
            task_file_count=self.context.task_file_count,
            validated_count=len(validated),
            invalid_count=invalid_count,
        )
        if mutated_paths:
            self._stage_repo_paths(mutated_paths, failure_message="Validation staging failed")

        self.logger.info(
            "Validation: %s validated, %s invalid out of %s total",
            len(validated),
            invalid_count,
            len(task_files),
        )

    def phase_autofix(self) -> None:
        self.context.current_phase = "Autofix"
        self.timeout_budget.checkpoint(self.context.current_phase)
        self.context.autofix_results = []
        self.context.autofix_halted = False
        self.context.autofix_halt_reason = ""

        if self.context.smoke:
            self.logger.info("Smoke mode: skipping Autofix")
            return
        if self.context.dry_run:
            self.logger.info("Dry-run enabled: skipping Autofix")
            return
        if self.context.manager_contract_failed:
            self.logger.info("Autofix skipped because manager contract failed")
            return
        if not self.config.autofix_enabled:
            self.logger.info("Autofix disabled: skipping phase")
            return
        if not self.context.validated_tasks:
            self.logger.info("Autofix: 0 validated tasks")
            return
        if self.context.cost_cap_hit:
            self.logger.info("Autofix skipped because the run is already cost-capped")
            return

        lauren_script = self.config.repo_dir / "lauren-loop-v2.sh"
        is_executable = lauren_script.exists() and lauren_script.is_file() and (lauren_script.stat().st_mode & 0o111) != 0
        if not is_executable:
            self.context.add_failure(f"Lauren Loop script missing or not executable: {lauren_script}")
            self.logger.error("Lauren Loop script missing or not executable: %s", lauren_script)
            return

        autofix_spend = 0.0
        remaining_budget = self._remaining_budget(autofix_spend)
        if remaining_budget < self.config.autofix_min_budget:
            self.logger.info(
                "Autofix: insufficient budget remaining ($%.4f of $%.4f needed)",
                remaining_budget,
                self.config.autofix_min_budget,
            )
            return

        severity_buckets = {"critical": [], "major": [], "minor": [], "observation": []}
        for task_path in self.context.validated_tasks:
            severity = autofix_helpers.extract_task_severity(task_path)
            if severity is None or not self._severity_allowed(severity, self.config.autofix_severity):
                continue
            severity_buckets[severity].append(task_path)

        eligible_tasks = (
            severity_buckets["critical"]
            + severity_buckets["major"]
            + severity_buckets["minor"]
            + severity_buckets["observation"]
        )[: self.config.autofix_max_tasks]
        if not eligible_tasks:
            self.logger.info("Autofix: 0 validated tasks")
            return

        fixed_count = 0
        failed_count = 0
        blocked_count = 0

        for index, task_path in enumerate(eligible_tasks):
            self.timeout_budget.checkpoint(self.context.current_phase)
            remaining_budget = self._remaining_budget(autofix_spend)
            if remaining_budget < self.config.autofix_min_budget:
                self.logger.info(
                    "Autofix: insufficient budget remaining ($%.4f of $%.4f needed)",
                    remaining_budget,
                    self.config.autofix_min_budget,
                )
                break

            remaining_slots = len(eligible_tasks) - index
            spendable_budget = max(0.0, remaining_budget - self.config.autofix_min_budget)
            if spendable_budget <= 0:
                self.logger.info(
                    "Autofix: no spendable budget remains after reserving $%.4f for shipping",
                    self.config.autofix_min_budget,
                )
                break
            per_task_budget = spendable_budget / remaining_slots

            slug = autofix_helpers.task_slug_from_path(task_path)
            severity = autofix_helpers.extract_task_severity(task_path) or "unknown"
            goal = autofix_helpers.extract_goal_from_task(task_path)
            task_rel = self._repo_relative_display(task_path)

            if not goal:
                self.context.add_warning(
                    f"Autofix task {task_rel} is missing a Goal section; skipping Lauren invocation"
                )
                try:
                    autofix_helpers.append_autofix_section(
                        task_path,
                        status="failed",
                        run_date=self.context.run_date,
                        run_id=self.context.run_id,
                        exit_code=64,
                        cost="0.0000",
                    )
                    self._stage_repo_paths([task_path], failure_message="Autofix task metadata staging failed")
                except OSError:
                    self.context.add_warning(f"Could not append autofix metadata for {task_rel}: task file is missing")
                self.context.autofix_results.append({
                    "task_path": task_path,
                    "slug": slug,
                    "status": "failed",
                    "cost_usd": "0.0000",
                })
                failed_count += 1
                self.logger.info("Fix failed: %s", slug)
                continue

            before_snapshot = self.git.snapshot_tree_state()
            before_untracked = self.git.list_untracked_files()
            invocation_exit = 0
            manifest_cost = "0.0000"
            final_status: str | None = None

            env = self.config.subprocess_env({
                "LAUREN_LOOP_MAX_COST": f"{per_task_budget:.2f}",
                "LAUREN_LOOP_NONINTERACTIVE": "1",
                "LAUREN_LOOP_TASK_FILE_HINT": str(task_path),
            })
            try:
                invocation = autofix_helpers.run_lauren_loop(
                    slug,
                    goal,
                    self.config.repo_dir,
                    self.config.lauren_timeout_seconds,
                    env=env,
                )
                invocation_exit = int(invocation.returncode)
            except CommandTimeoutError:
                invocation_exit = 124
            except Exception as exc:
                invocation_exit = 1
                self.logger.warning("Lauren loop failed for %s: %s", slug, exc)

            after_snapshot = self.git.snapshot_tree_state()
            after_untracked = self.git.list_untracked_files()

            manifest_path = autofix_helpers.lauren_manifest_path(task_path)
            final_status, parsed_cost = autofix_helpers.parse_lauren_manifest(manifest_path)
            halt_loop = False

            if invocation_exit == 0 and (
                final_status is None
                or parsed_cost is None
                or final_status not in {"success", "human_review", "completed", "blocked"}
            ):
                self.context.add_warning(
                    f"Autofix task {task_rel} exited 0 but manifest {manifest_path} was missing required fields; treating outcome as failed"
                )
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                outcome = "failed"
                manifest_cost = "unknown"
                halt_loop = True
                self._halt_autofix(
                    f"Autofix halted after manifest contract failure for {task_rel}; remaining validated tasks were not attempted"
                )
            else:
                manifest_cost = parsed_cost or "0.0000"
                if invocation_exit != 0:
                    outcome = "failed"
                elif final_status == "success":
                    outcome = "applied"
                else:
                    outcome = "blocked"

            if invocation_exit == 0 and parsed_cost is not None:
                autofix_spend += float(parsed_cost)

            if outcome == "blocked":
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                halt_loop = True
                raw_status = final_status or "blocked"
                self._halt_autofix(
                    f"Autofix halted after Lauren Loop reported {raw_status} for {task_rel}; remaining validated tasks were not attempted"
                )
            elif outcome == "applied":
                try:
                    autofix_helpers.stage_autofix_changes(
                        self.git,
                        task_path,
                        before_snapshot,
                        after_snapshot,
                        before_untracked,
                        after_untracked,
                    )
                except autofix_helpers.AutofixScopeViolation as exc:
                    self._restore_autofix_iteration(
                        task_rel,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                    self.context.add_warning(
                        f"Autofix task {task_rel} produced out-of-scope changes: {', '.join(exc.out_of_scope_paths)}"
                    )
                    outcome = "failed"
                    manifest_cost = parsed_cost or "0.0000"
                except autofix_helpers.AutofixArtifactError as exc:
                    self._restore_autofix_iteration(
                        task_rel,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                    self.context.add_warning(
                        f"Autofix task {task_rel} exited 0 but {exc}; treating outcome as failed"
                    )
                    outcome = "failed"
                    manifest_cost = parsed_cost or "0.0000"
                    halt_loop = True
                    self._halt_autofix(
                        f"Autofix halted after scope-triage contract failure for {task_rel}; remaining validated tasks were not attempted"
                    )
                except Exception as exc:
                    self.context.add_failure(f"Autofix staging failed for {task_rel}: {exc}")
                    self.context.digest_stageable = False
                    outcome = "failed"
                    manifest_cost = parsed_cost or "0.0000"

            try:
                autofix_helpers.append_autofix_section(
                    task_path,
                    status=outcome,
                    run_date=self.context.run_date,
                    run_id=self.context.run_id,
                    exit_code=invocation_exit,
                    cost=manifest_cost,
                )
                self._stage_repo_paths([task_path], failure_message="Autofix task metadata staging failed")
            except OSError:
                self.context.add_warning(f"Could not append autofix metadata for {task_rel}: task file is missing")

            if outcome == "applied":
                fixed_count += 1
                self.logger.info("Fixed: %s", slug)
            elif outcome == "blocked":
                blocked_count += 1
                self.logger.info("Fix blocked: %s", slug)
            else:
                failed_count += 1
                self.logger.info("Fix failed: %s", slug)

            self.context.autofix_results.append({
                "task_path": task_path,
                "slug": slug,
                "status": outcome,
                "severity": severity,
                "cost_usd": manifest_cost,
            })

            if halt_loop:
                break

        skipped_count = max(0, len(self.context.validated_tasks) - fixed_count - failed_count - blocked_count)
        self.logger.info(
            "Autofix: %s fixed, %s failed, %s blocked, %s skipped (budget/severity) out of %s validated",
            fixed_count,
            failed_count,
            blocked_count,
            skipped_count,
            len(self.context.validated_tasks),
        )

    def phase_bridge(self) -> None:
        self.context.current_phase = "Bridge"
        self.timeout_budget.checkpoint(self.context.current_phase)
        self.context.bridge_results = []
        self.context.bridge_task_paths = []

        if self.context.smoke:
            self.logger.info("Smoke mode: skipping Bridge")
            return
        if self.context.dry_run:
            self.logger.info("Dry-run enabled: skipping Bridge")
            return
        if self.context.manager_contract_failed:
            self.logger.info("Bridge skipped because manager contract failed")
            return
        if not self.config.bridge_enabled:
            self.logger.info("Bridge disabled: skipping phase")
            return
        if self.context.cost_cap_hit:
            self.logger.info("Bridge skipped because the run is already cost-capped")
            return

        digest_path = self.context.digest_path or self.context.writable_digest_path
        findings = manager_top_findings_from_digest(digest_path)
        if not findings:
            self.logger.info("Bridge: 0 ranked findings")
            return

        remaining_budget = self._remaining_budget()

        eligible_findings = [
            finding
            for finding in findings
            if self._severity_meets_minimum(finding[1], self.config.bridge_min_severity)
        ]
        manager_task_paths = self._read_manifest_task_paths(self.context.manager_task_manifest_path)
        uncovered_findings = bridge_helpers.findings_without_tasks(eligible_findings, manager_task_paths)
        selected_findings = uncovered_findings[: self.config.bridge_max_tasks]

        if not selected_findings:
            self.logger.info("Bridge: no uncovered findings to materialize")
            self._append_digest_section_warning_only(
                bridge_helpers.build_bridge_digest_section(self.context.bridge_results),
                warning_message="Bridge digest staging failed",
            )
            return

        lauren_script = self.config.repo_dir / "lauren-loop-v2.sh"
        can_execute = self.config.bridge_auto_execute
        if can_execute and not self._is_executable_file(lauren_script):
            self.context.add_warning(f"Bridge Lauren Loop script missing or not executable: {lauren_script}")
            self.logger.warning("Bridge Lauren Loop script missing or not executable: %s", lauren_script)
            can_execute = False

        bridge_spend = 0.0
        bridge_stage_paths: list[Path] = []
        triage_only = not can_execute or remaining_budget < self.config.bridge_max_cost_per_task
        if triage_only:
            if self.config.bridge_auto_execute and can_execute:
                self.logger.info(
                    "Bridge entering task-only fallback: remaining budget $%.4f is below per-task cap $%.4f",
                    remaining_budget,
                    self.config.bridge_max_cost_per_task,
                )
            elif not self.config.bridge_auto_execute:
                self.logger.info("Bridge auto-execution disabled: creating runtime tasks without Lauren Loop")

        for index, finding in enumerate(selected_findings):
            self.timeout_budget.checkpoint(self.context.current_phase)
            rank, severity, category, title = finding
            task_path = bridge_helpers.synthesize_bridge_task(
                self.config.repo_dir / "docs" / "tasks" / "open",
                self.context.run_date,
                finding,
            )
            slug = autofix_helpers.task_slug_from_path(task_path)
            self.context.bridge_task_paths.append(task_path)
            bridge_stage_paths.append(task_path)

            result: dict[str, object] = {
                "rank": rank,
                "severity": severity,
                "category": category,
                "title": title,
                "task_path": task_path,
                "slug": slug,
                "status": "prepared",
                "cost_usd": "0.0000",
            }

            if triage_only:
                self.context.bridge_results.append(result)
                continue

            goal = autofix_helpers.extract_goal_from_task(task_path)
            if not goal:
                self.context.add_warning(
                    f"Bridge task {self._repo_relative_display(task_path)} is missing a Goal section; skipping Lauren invocation"
                )
                result["status"] = "failed"
                self.context.bridge_results.append(result)
                continue

            before_snapshot = self.git.snapshot_tree_state()
            before_untracked = self.git.list_untracked_files()
            invocation_exit = 0

            per_task_budget = min(
                self.config.bridge_max_cost_per_task,
                self._remaining_budget(bridge_spend) / max(1, len(selected_findings) - index),
            )
            env = self.config.subprocess_env({
                "LAUREN_LOOP_MAX_COST": f"{per_task_budget:.2f}",
                "LAUREN_LOOP_NONINTERACTIVE": "1",
                "LAUREN_LOOP_TASK_FILE_HINT": str(task_path),
            })
            try:
                invocation = autofix_helpers.run_lauren_loop(
                    slug,
                    goal,
                    self.config.repo_dir,
                    self.config.lauren_timeout_seconds,
                    env=env,
                )
                invocation_exit = int(invocation.returncode)
            except CommandTimeoutError:
                invocation_exit = 124
                self.context.add_warning(f"Bridge task {slug} timed out; continuing without blocking shipping")
            except Exception as exc:
                invocation_exit = 1
                self.context.add_warning(f"Bridge task {slug} failed: {exc}")
                self.logger.warning("Bridge task %s failed: %s", slug, exc)

            after_snapshot = self.git.snapshot_tree_state()
            after_untracked = self.git.list_untracked_files()
            manifest_path = autofix_helpers.lauren_manifest_path(task_path)
            final_status, parsed_cost = autofix_helpers.parse_lauren_manifest(manifest_path)
            if invocation_exit == 0 and parsed_cost is not None:
                bridge_spend += float(parsed_cost)
            result["cost_usd"] = parsed_cost or "0.0000"
            task_rel = self._repo_relative_display(task_path)
            halt_loop = False

            if invocation_exit == 0 and (
                final_status is None
                or parsed_cost is None
                or final_status not in {"success", "human_review", "completed", "blocked"}
            ):
                self.context.add_warning(
                    f"Bridge task {task_rel} exited 0 but manifest {manifest_path} was missing required fields; treating outcome as failed"
                )
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                result["status"] = "failed"
                halt_loop = True
                self._warn_followup_phase_halt(
                    f"Bridge stopped after manifest contract failure for {task_rel}; remaining uncovered findings were not attempted"
                )
            elif invocation_exit != 0:
                result["status"] = "failed"
                self.context.add_warning(f"Bridge task {slug} failed with exit {invocation_exit}; continuing")
            elif final_status == "success":
                try:
                    autofix_helpers.stage_autofix_changes(
                        self.git,
                        task_path,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                except autofix_helpers.AutofixScopeViolation as exc:
                    self._restore_autofix_iteration(
                        task_rel,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                    self.context.add_warning(
                        f"Bridge task {task_rel} produced out-of-scope changes: {', '.join(exc.out_of_scope_paths)}"
                    )
                    result["status"] = "failed"
                except autofix_helpers.AutofixArtifactError as exc:
                    self._restore_autofix_iteration(
                        task_rel,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                    self.context.add_warning(
                        f"Bridge task {task_rel} exited 0 but {exc}; treating outcome as failed"
                    )
                    result["status"] = "failed"
                    halt_loop = True
                    self._warn_followup_phase_halt(
                        f"Bridge stopped after scope-triage contract failure for {task_rel}; remaining uncovered findings were not attempted"
                    )
                except Exception as exc:
                    self.context.add_failure(f"Bridge staging failed for {task_rel}: {exc}")
                    self.context.digest_stageable = False
                    result["status"] = "failed"
                else:
                    result["status"] = "applied"
            elif final_status == "human_review":
                result["status"] = "human_review"
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                halt_loop = True
                self._warn_followup_phase_halt(
                    f"Bridge stopped after Lauren Loop reported human_review for {task_rel}; remaining uncovered findings were not attempted"
                )
            elif final_status in {"completed", "blocked"}:
                result["status"] = "blocked"
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                halt_loop = True
                self._warn_followup_phase_halt(
                    f"Bridge stopped after Lauren Loop reported {final_status} for {task_rel}; remaining uncovered findings were not attempted"
                )
            else:
                result["status"] = "failed"
                self.context.add_warning(
                    f"Bridge task {slug} exited 0 but the Lauren manifest was missing or malformed; treating outcome as failed"
                )

            self.context.bridge_results.append(result)
            if halt_loop:
                break

        self._stage_repo_paths_warning_only(
            bridge_stage_paths,
            warning_message="Bridge staging failed",
        )
        self._append_digest_section_warning_only(
            bridge_helpers.build_bridge_digest_section(self.context.bridge_results),
            warning_message="Bridge digest staging failed",
        )

        applied_count = sum(1 for entry in self.context.bridge_results if entry.get("status") == "applied")
        blocked_count = sum(
            1 for entry in self.context.bridge_results if entry.get("status") in {"blocked", "human_review"}
        )
        prepared_count = sum(1 for entry in self.context.bridge_results if entry.get("status") == "prepared")
        failed_count = sum(1 for entry in self.context.bridge_results if entry.get("status") == "failed")
        self.logger.info(
            "Bridge: %s applied, %s prepared, %s blocked, %s failed out of %s uncovered findings",
            applied_count,
            prepared_count,
            blocked_count,
            failed_count,
            len(selected_findings),
        )

    def phase_backlog(self) -> None:
        self.context.current_phase = "Backlog"
        self.timeout_budget.checkpoint(self.context.current_phase)
        self.context.backlog_results = []

        if self.context.smoke:
            self.logger.info("Smoke mode: skipping Backlog")
            return
        if self.context.dry_run:
            self.logger.info("Dry-run enabled: skipping Backlog")
            return
        if self.context.manager_contract_failed:
            self.logger.info("Backlog skipped because manager contract failed")
            return
        if not self.config.backlog_enabled:
            self.logger.info("Backlog disabled: skipping phase")
            return
        if self.context.cost_cap_hit:
            self.logger.info("Backlog skipped because the run is already cost-capped")
            return

        attempted_autofix, min_tasks_per_run, needed_tasks, effective_max_tasks = self._backlog_floor_state()
        self.logger.info(
            "Backlog target: attempted autofix=%s, min per run=%s, needed=%s, effective max=%s",
            attempted_autofix,
            min_tasks_per_run,
            needed_tasks,
            effective_max_tasks,
        )
        if self.context.run_clean and needed_tasks == 0:
            self.logger.info("Backlog skipped for clean run because autofix already met the minimum task floor")
            return

        if self._remaining_budget() < self.config.backlog_min_budget:
            self.logger.info(
                "Backlog skipped because remaining budget $%.4f is below minimum $%.4f",
                self._remaining_budget(),
                self.config.backlog_min_budget,
            )
            return

        tasks_dir = self.config.repo_dir / "docs" / "tasks" / "open"
        open_tasks = backlog_helpers.scan_open_tasks(tasks_dir)
        manager_task_paths = self._read_manifest_task_paths(self.context.manager_task_manifest_path)
        bridge_task_paths = list(self.context.bridge_task_paths)

        if not open_tasks:
            self.logger.info("Backlog found no open task files")
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        task_lookup: dict[Path, tuple[Path, str, dict[str, str]]] = {
            path.resolve(): (path.resolve(), status, metadata)
            for path, status, metadata in open_tasks
        }
        pickable_candidates = {
            path
            for path, status, _metadata in open_tasks
            if backlog_helpers.is_pickable(
                path,
                status,
                self.context.run_date,
                manager_task_paths,
                bridge_task_paths,
                open_tasks,
            )[0]
        }

        if not pickable_candidates:
            self.logger.info("Backlog: no pickable open tasks")
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        ranking_script = self.config.repo_dir / "lauren-loop.sh"
        if not self._is_executable_file(ranking_script):
            self.context.add_warning(f"Backlog ranking script missing or not executable: {ranking_script}")
            self.logger.warning("Backlog ranking script missing or not executable: %s", ranking_script)
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        try:
            ranking = backlog_helpers.run_lauren_ranking(
                self.config.repo_dir,
                tasks_dir,
                self.config.lauren_timeout_seconds,
                env=self.config.subprocess_env({"LAUREN_LOOP_NONINTERACTIVE": "1"}),
            )
        except CommandTimeoutError:
            self.context.add_warning("Backlog ranking timed out; skipping backlog execution")
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return
        except Exception as exc:
            self.context.add_warning(f"Backlog ranking failed: {exc}")
            self.logger.warning("Backlog ranking failed: %s", exc)
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        if ranking.returncode != 0:
            self.context.add_warning(
                f"Backlog ranking failed with exit {ranking.returncode}; skipping backlog burndown"
            )
            self.logger.warning("Backlog ranking failed with exit %s", ranking.returncode)
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        ranked_output = ranking.stdout or ""
        task_list_section = backlog_helpers.task_list_section(ranked_output)
        raw_task_list_has_content = any(line.strip() for line in task_list_section.splitlines())
        if not backlog_helpers.task_list_has_header(ranked_output):
            self.context.add_warning(
                "lauren-loop.sh next succeeded but output contained no ## TASK_LIST header; ranking output may have changed format"
            )
            self.logger.warning("Backlog ranking output contained no ## TASK_LIST header")
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        ranked_rows = backlog_helpers.parse_task_list_block(ranked_output)
        if not ranked_rows:
            if raw_task_list_has_content:
                self.context.add_warning(
                    "TASK_LIST contained rows but none matched the expected rank|path|goal|complexity format; check for format changes"
                )
                self.logger.warning("Backlog TASK_LIST rows were present but malformed")
            else:
                self.logger.info("Backlog ranking returned an empty TASK_LIST")
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        selected_candidates: list[tuple[int, Path, str, str]] = []
        for rank, task_path_text, task_goal, task_complexity in ranked_rows:
            task_path = backlog_helpers.absolute_task_path(task_path_text, self.config.repo_dir)
            task_record = task_lookup.get(task_path.resolve())
            task_status = task_record[1] if task_record is not None else ""
            pickable, _reason = backlog_helpers.is_pickable(
                task_path,
                task_status,
                self.context.run_date,
                manager_task_paths,
                bridge_task_paths,
                open_tasks,
            )
            if not pickable:
                continue
            selected_candidates.append((rank, task_path, task_goal, task_complexity))
            if len(selected_candidates) >= effective_max_tasks:
                break

        if not selected_candidates:
            self.logger.info("No ranked backlog tasks passed the pickability filters")
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        lauren_script = self.config.repo_dir / "lauren-loop-v2.sh"
        if not self._is_executable_file(lauren_script):
            self.context.add_warning(f"Backlog Lauren Loop script missing or not executable: {lauren_script}")
            self.logger.warning("Backlog Lauren Loop script missing or not executable: %s", lauren_script)
            self._append_digest_section_warning_only(
                backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
                warning_message="Backlog digest staging failed",
            )
            return

        backlog_spend = 0.0
        for rank, task_path, task_goal, task_complexity in selected_candidates:
            self.timeout_budget.checkpoint(self.context.current_phase)
            remaining_budget = self._remaining_budget(backlog_spend)
            if remaining_budget < self.config.backlog_min_budget:
                self.logger.info(
                    "Stopping backlog early: remaining budget $%.4f is below minimum $%.4f",
                    remaining_budget,
                    self.config.backlog_min_budget,
                )
                break

            remaining_slots = max(1, len(selected_candidates) - len(self.context.backlog_results))
            per_task_budget = remaining_budget / remaining_slots
            slug = backlog_helpers.task_path_to_slug(task_path)

            before_snapshot = self.git.snapshot_tree_state()
            before_untracked = self.git.list_untracked_files()
            invocation_exit = 0

            env = self.config.subprocess_env({
                "LAUREN_LOOP_MAX_COST": f"{per_task_budget:.2f}",
                "LAUREN_LOOP_NONINTERACTIVE": "1",
                "LAUREN_LOOP_TASK_FILE_HINT": str(task_path),
            })
            try:
                invocation = autofix_helpers.run_lauren_loop(
                    slug,
                    task_goal,
                    self.config.repo_dir,
                    self.config.lauren_timeout_seconds,
                    env=env,
                )
                invocation_exit = int(invocation.returncode)
            except CommandTimeoutError:
                invocation_exit = 124
                self.context.add_warning(f"Backlog task {slug} timed out; continuing")
            except Exception as exc:
                invocation_exit = 1
                self.context.add_warning(f"Backlog task {slug} failed: {exc}")
                self.logger.warning("Backlog task %s failed: %s", slug, exc)

            after_snapshot = self.git.snapshot_tree_state()
            after_untracked = self.git.list_untracked_files()
            manifest_path = autofix_helpers.lauren_manifest_path(task_path)
            final_status, parsed_cost = autofix_helpers.parse_lauren_manifest(manifest_path)
            if invocation_exit == 0 and parsed_cost is not None:
                backlog_spend += float(parsed_cost)
            task_rel = self._repo_relative_display(task_path)
            halt_loop = False

            if invocation_exit == 0 and (
                final_status is None
                or parsed_cost is None
                or final_status not in {"success", "human_review", "completed", "blocked"}
            ):
                self.context.add_warning(
                    f"Backlog task {task_rel} exited 0 but manifest {manifest_path} was missing required fields; treating outcome as failed"
                )
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                outcome = "failed"
                halt_loop = True
                self._warn_followup_phase_halt(
                    f"Backlog stopped after manifest contract failure for {task_rel}; remaining ranked tasks were not attempted"
                )
            elif invocation_exit != 0:
                outcome = "failed"
                self.context.add_warning(f"Backlog task {slug} failed with exit {invocation_exit}; continuing")
            elif final_status == "success":
                try:
                    autofix_helpers.stage_autofix_changes(
                        self.git,
                        task_path,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                except autofix_helpers.AutofixScopeViolation as exc:
                    self._restore_autofix_iteration(
                        task_rel,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                    self.context.add_warning(
                        f"Backlog task {task_rel} produced out-of-scope changes: {', '.join(exc.out_of_scope_paths)}"
                    )
                    outcome = "failed"
                except autofix_helpers.AutofixArtifactError as exc:
                    self._restore_autofix_iteration(
                        task_rel,
                        before_snapshot=before_snapshot,
                        after_snapshot=after_snapshot,
                        before_untracked=before_untracked,
                        after_untracked=after_untracked,
                    )
                    self.context.add_warning(
                        f"Backlog task {task_rel} exited 0 but {exc}; treating outcome as failed"
                    )
                    outcome = "failed"
                    halt_loop = True
                    self._warn_followup_phase_halt(
                        f"Backlog stopped after scope-triage contract failure for {task_rel}; remaining ranked tasks were not attempted"
                    )
                except Exception as exc:
                    self.context.add_failure(f"Backlog staging failed for {task_rel}: {exc}")
                    self.context.digest_stageable = False
                    outcome = "failed"
                else:
                    outcome = "success"
            elif final_status == "human_review":
                outcome = "human_review"
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                halt_loop = True
                self._warn_followup_phase_halt(
                    f"Backlog stopped after Lauren Loop reported human_review for {task_rel}; remaining ranked tasks were not attempted"
                )
            elif final_status in {"completed", "blocked"}:
                outcome = "blocked"
                self._restore_autofix_iteration(
                    task_rel,
                    before_snapshot=before_snapshot,
                    after_snapshot=after_snapshot,
                    before_untracked=before_untracked,
                    after_untracked=after_untracked,
                )
                halt_loop = True
                self._warn_followup_phase_halt(
                    f"Backlog stopped after Lauren Loop reported {final_status} for {task_rel}; remaining ranked tasks were not attempted"
                )
            else:
                outcome = "failed"
                self.context.add_warning(
                    f"Backlog task {slug} exited 0 but the Lauren manifest was missing or malformed; treating outcome as failed"
                )

            self.context.backlog_results.append({
                "task_path": task_path,
                "slug": slug,
                "status": outcome,
                "cost_usd": parsed_cost or "0.0000",
                "rank": rank,
                "complexity": task_complexity,
            })
            if halt_loop:
                break

        self._append_digest_section_warning_only(
            backlog_helpers.build_backlog_digest_section(self.context.backlog_results),
            warning_message="Backlog digest staging failed",
        )

        success_count = sum(1 for entry in self.context.backlog_results if entry.get("status") == "success")
        blocked_count = sum(
            1 for entry in self.context.backlog_results if entry.get("status") in {"blocked", "human_review"}
        )
        failed_count = sum(1 for entry in self.context.backlog_results if entry.get("status") == "failed")
        self.logger.info(
            "Backlog: %s succeeded, %s blocked, %s failed out of %s selected tasks",
            success_count,
            blocked_count,
            failed_count,
            len(self.context.backlog_results),
        )

    def _autofix_attempted_count(self) -> int:
        return len(self.context.autofix_results)

    def _backlog_floor_state(self) -> tuple[int, int, int, int]:
        attempted = self._autofix_attempted_count()
        minimum = self.config.min_tasks_per_run
        needed = 0 if minimum <= 0 or attempted >= minimum else minimum - attempted
        effective_max = max(needed, self.config.backlog_max_tasks)
        return attempted, minimum, needed, effective_max

    def write_digest(self, *, phase_reached: str | None = None) -> None:
        if phase_reached is None:
            self.context.current_phase = "Digest"
            phase_reached = self.context.current_phase
        digest_path = self.context.writable_digest_path
        if self.context.cost_cap_hit:
            outcome = "cost-capped"
        else:
            outcome = "failed" if self.context.failures or self.context.ship_blocked_reason else "success"
        write_fallback_digest(
            digest_path,
            run_date=self.context.run_date,
            run_id=self.context.run_id,
            mode_label=self.context.mode_label,
            outcome_label=outcome,
            phase_reached=phase_reached,
            branch=self.context.run_branch or "not-created",
            total_findings=self.context.total_findings_available,
            task_file_count=self.context.task_file_count,
            total_cost=self.cost_tracker.total_value(),
            warning_notes=self.context.warnings,
            failure_notes=self.context.failures,
            detective_statuses=self.detective_status_store.read_many(self._detective_schedule()),
            raw_findings_paths=sorted(self.context.raw_findings_dir.glob("*-findings.md")),
        )
        self.context.digest_path = digest_path

    def phase_ship(self) -> None:
        self.context.current_phase = "Ship Results"
        failures_before = len(self.context.failures)
        warnings_before = len(self.context.warnings)
        self.context.ship_blocked_reason = None
        if self.context.digest_path is None or self.context.run_branch is None:
            self.context.add_failure("Cannot ship without a digest and run branch")
            return
        if self.context.run_clean:
            self.logger.info("Clean run detected: no commit, push, or PR will be created")
            return
        shippable, reason = self.context.run_health_check()
        if not shippable:
            if self.context.dry_run:
                self.logger.info("Dry-run ship gate would block shipping: %s", reason)
                return
            self.context.ship_blocked_reason = reason
            message = f"Ship blocked: {reason}"
            if message not in self.context.warnings:
                self.context.add_warning(message)
            self.logger.warning("%s", message)
            return
        if not self.context.dry_run and not self._ensure_repo_digest_for_ship():
            return
        result = ShipResult(
            committed=False,
            pushed=False,
            pr_created=False,
            pr_updated=False,
            pr_number=None,
            pr_url=None,
            pushed_head=None,
        )
        try:
            self.timeout_budget.checkpoint(self.context.current_phase)
            result = self.shipper.ship(
                branch_name=self.context.run_branch,
                digest_path=self.context.digest_path,
                run_date=self.context.run_date,
                smoke=self.context.smoke,
                task_file_count=self.context.task_file_count,
                total_findings=self.context.total_findings_available,
                dry_run=self.context.dry_run,
            )
        except ShipError as exc:
            result = exc.partial_result
            self.context.add_failure(str(exc))
            self.logger.error("%s", exc)
        except Exception as exc:
            self.context.add_failure(str(exc))
            self.logger.error("%s", exc)
        self.context.pr_url = result.pr_url
        if result.pr_url:
            action = "updated" if result.pr_updated and not result.pr_created else "created"
            self.logger.info("PR %s: %s", action, result.pr_url)
        if not self._ship_digest_rewrite_needed(
            failures_before=failures_before,
            warnings_before=warnings_before,
        ):
            return
        self.write_digest(phase_reached=self.context.current_phase)
        if not result.pushed or result.pushed_head is None:
            return
        try:
            self.timeout_budget.checkpoint(self.context.current_phase)
            self.git.stage_paths([self.context.digest_path])
            self.git.amend_last_commit(expected_branch=self.context.run_branch)
            self.git.force_push_branch(
                self.context.run_branch,
                expected_remote_head=result.pushed_head,
            )
        except Exception as exc:
            self.context.add_failure(f"Failed to rewrite shipped digest: {exc}")
            self.logger.error("%s", exc)
            return
        if result.pr_number is None:
            return
        try:
            self.timeout_budget.checkpoint(self.context.current_phase)
            self.shipper.update_pr_body(
                pr_number=result.pr_number,
                digest_path=self.context.digest_path,
            )
        except Exception as exc:
            self.context.add_failure(f"Failed to refresh PR body after digest rewrite: {exc}")
            self.logger.error("%s", exc)

    def phase_cleanup(self) -> None:
        self.context.current_phase = "Cleanup"
        self.logger.info(self.cost_tracker.summary_text())
        if self.context.digest_path is not None:
            self.logger.info("Digest artifact: %s", self.context.digest_path)
        if self.context.pr_url:
            self.logger.info("PR URL: %s", self.context.pr_url)
        self._log_weekly_cost_summary()
        if self.config.webhook_url:
            summary = build_notify_summary(self.context, self.cost_tracker)
            if not send_webhook(self.config.webhook_url, summary, self.context.run_date):
                message = "Cleanup webhook delivery failed"
                self.context.add_warning(message)
                self.logger.warning("%s", message)
        try:
            self.git.checkout_branch(self.config.base_branch)
        except Exception as exc:
            self.context.add_warning(f"Cleanup could not checkout {self.config.base_branch}: {exc}")
            self.logger.warning("Cleanup could not checkout %s: %s", self.config.base_branch, exc)

    def _run_detective(self, engine: str, playbook_name: str) -> AgentRunResult:
        if engine == "claude":
            return self.agents.run_claude(playbook_name)
        return self.agents.run_codex(playbook_name)

    def _handle_detective_result(
        self,
        result: AgentRunResult,
        *,
        codex_gate: CodexGate,
        error_message: str | None = None,
    ) -> None:
        self._write_detective_status(
            playbook=result.playbook_name,
            engine=result.engine,
            status=result.status,
            duration_seconds=result.duration_seconds,
            findings_count=result.findings_count,
            cost_usd=result.cost_usd,
        )
        self.context.total_findings_available += result.findings_count

        if result.engine == "codex":
            if result.status in {"success", "no_findings"}:
                if codex_gate.on_success():
                    self.logger.info("Codex available: first Codex call succeeded")
            else:
                codex_gate.on_failure()
                self._log_codex_gate_close(result, error_message=error_message)

        self.logger.info(
            "Completed %s/%s status=%s duration=%ss findings=%s cost=$%s",
            result.engine,
            result.playbook_name,
            result.status,
            result.duration_seconds,
            result.findings_count,
            result.cost_usd,
        )

    def _write_detective_status(
        self,
        *,
        playbook: str,
        engine: str,
        status: str,
        duration_seconds: int,
        findings_count: int,
        cost_usd: str,
    ) -> None:
        self.detective_status_store.write(
            DetectiveStatus(
                playbook=playbook,
                engine=engine,
                status=status,
                duration_seconds=duration_seconds,
                findings_count=findings_count,
                cost_usd=cost_usd,
            )
        )

    def _record_timeout_exhaustion(self, message: str, remaining_schedule: list[tuple[str, str]]) -> None:
        self.context.add_warning(message)
        self.logger.error("%s", message)
        for playbook_name, engine in remaining_schedule:
            self._write_detective_status(
                playbook=playbook_name,
                engine=engine,
                status="skipped_timeout",
                duration_seconds=0,
                findings_count=0,
                cost_usd="0.0000",
            )

    def _log_codex_gate_close(self, result: AgentRunResult, *, error_message: str | None) -> None:
        if result.status == "timeout":
            self.logger.warning("Codex %s timed out — closing gate", result.playbook_name)
            return
        if result.return_code == 0:
            self.logger.warning("Codex %s exited 0 but no output — closing gate", result.playbook_name)
            return
        if error_message:
            self.logger.warning("Codex %s failed with exit %s — closing gate", result.playbook_name, result.return_code)
            return
        self.logger.warning("Codex %s failed — closing gate", result.playbook_name)

    def _detective_schedule(self) -> list[tuple[str, str]]:
        schedule: list[tuple[str, str]] = []
        engines = self._detective_engines()
        for playbook_name in self._active_playbooks():
            for engine in engines:
                schedule.append((playbook_name, engine))
        return schedule

    def _detective_engines(self) -> tuple[str, ...]:
        engines: list[str] = []
        if self.config.claude_detectives_enabled:
            engines.append("claude")
        engines.append("codex")
        return tuple(engines)

    def _active_playbooks(self) -> tuple[str, ...]:
        playbooks = ("commit-detective",) if self.context.smoke else self.detective_playbooks
        return tuple(playbook for playbook in playbooks if playbook in self.implemented_detectives)

    def _stub_phase(self, phase_name: str) -> None:
        self.context.current_phase = phase_name
        self.logger.info("Phase %s: not yet implemented", phase_name)

    def _write_empty_task_manifest(self) -> None:
        try:
            task_writer_helpers.write_task_manifest(self.context.manager_task_manifest_path, [])
        except OSError as exc:
            self.context.add_failure(f"Task writing manifest write failed: {self.context.manager_task_manifest_path} ({exc})")
            self.logger.error("Task writing manifest write failed: %s", self.context.manager_task_manifest_path)

    def _severity_allowed(self, severity: str, allowed_csv: str) -> bool:
        allowed = {item.strip().lower() for item in allowed_csv.split(",") if item.strip()}
        return severity.lower() in allowed

    def _severity_meets_minimum(self, severity: str, minimum: str) -> bool:
        ranks = {
            "critical": 4,
            "major": 3,
            "minor": 2,
            "observation": 1,
        }
        return ranks.get(severity.strip().lower(), 0) >= ranks.get(minimum.strip().lower(), 0) > 0

    def _validation_artifact_suffix(self, task_path: Path, index: int) -> str:
        candidate = task_path.parent.name or task_path.stem
        if candidate:
            return candidate
        return f"task-{index:03d}"

    def _remaining_budget(self, extra_spend: float = 0.0) -> float:
        remaining = float(self.config.cost_cap_usd) - float(self.cost_tracker.total()) - extra_spend
        return max(0.0, remaining)

    def _restore_autofix_iteration(
        self,
        task_rel: str,
        *,
        before_snapshot: str | None,
        after_snapshot: str | None,
        before_untracked: list[str],
        after_untracked: list[str],
    ) -> None:
        try:
            autofix_helpers.restore_iteration_changes(
                self.git,
                before_snapshot,
                after_snapshot,
                before_untracked,
                after_untracked,
            )
        except Exception as exc:
            self.context.add_failure(f"Autofix restore failed for {task_rel}: {exc}")
            self.context.digest_stageable = False
            self.logger.error("Autofix restore failed for %s: %s", task_rel, exc)

    def _halt_autofix(self, reason: str) -> None:
        self.context.autofix_halted = True
        self.context.autofix_halt_reason = reason
        self.context.add_warning(reason)
        self.logger.warning("%s", reason)

    def _warn_followup_phase_halt(self, reason: str) -> None:
        self.context.add_warning(reason)
        self.logger.warning("%s", reason)

    def _log_weekly_cost_summary(self) -> None:
        total_cost, day_count, breakdown = weekly_summary(
            self.config.cost_csv,
            as_of_date=self.context.run_date,
        )
        self.logger.info("Weekly cost summary (%s recent day%s):", day_count, "" if day_count == 1 else "s")
        for day, daily_total in breakdown:
            self.logger.info("  %s $%s", day, f"{daily_total:.4f}")
        self.logger.info("  Total: $%s", f"{total_cost:.4f}")

    def _stage_repo_paths(self, paths: list[Path], *, failure_message: str) -> None:
        if not paths:
            return
        try:
            self.git.stage_paths(paths)
        except Exception as exc:
            self.context.add_failure(f"{failure_message}: {exc}")
            self.context.digest_stageable = False
            self.logger.error("%s: %s", failure_message, exc)

    def _stage_repo_paths_warning_only(self, paths: list[Path], *, warning_message: str) -> None:
        unique_paths = self._dedupe_paths(paths)
        if not unique_paths:
            return
        try:
            self.git.stage_paths(unique_paths)
        except Exception as exc:
            self.context.add_warning(f"{warning_message}: {exc}")
            self.logger.warning("%s: %s", warning_message, exc)

    def _append_digest_section_warning_only(self, section_text: str, *, warning_message: str) -> None:
        digest_path = self.context.digest_path
        if digest_path is None or not digest_path.exists():
            return
        existing = digest_path.read_text(encoding="utf-8").rstrip()
        rendered = f"{existing}\n\n{section_text.rstrip()}\n"
        digest_path.write_text(rendered, encoding="utf-8")
        self._stage_repo_paths_warning_only([digest_path], warning_message=warning_message)

    def _read_manifest_task_paths(self, manifest_path: Path) -> list[Path]:
        if not manifest_path.exists() or manifest_path.stat().st_size == 0:
            return []
        paths: list[Path] = []
        for raw_line in manifest_path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line:
                continue
            candidate = Path(line)
            if not candidate.is_absolute():
                candidate = self.config.repo_dir / line
            paths.append(candidate.resolve())
        return paths

    def _dedupe_paths(self, paths: list[Path]) -> list[Path]:
        ordered: list[Path] = []
        seen: set[str] = set()
        for path in paths:
            key = str(path)
            if key in seen:
                continue
            ordered.append(path)
            seen.add(key)
        return ordered

    def _is_executable_file(self, path: Path) -> bool:
        return path.exists() and path.is_file() and (path.stat().st_mode & 0o111) != 0

    def _patch_digest_counts(
        self,
        *,
        task_file_count: int | None = None,
        validated_count: int | None = None,
        invalid_count: int | None = None,
    ) -> None:
        digest_path = self.context.digest_path
        if digest_path is None or not digest_path.exists():
            return

        updated_lines: list[str] = []
        for line in digest_path.read_text(encoding="utf-8").splitlines():
            if task_file_count is not None:
                line = self._TASK_FILES_CREATED_RE.sub(
                    lambda match: f"{match.group(1)}{task_file_count}{match.group(2) or ''}",
                    line,
                )
            if validated_count is not None:
                line = self._VALIDATED_TASKS_RE.sub(rf"\g<1>{validated_count}", line)
            if invalid_count is not None:
                line = self._INVALID_TASKS_RE.sub(rf"\g<1>{invalid_count}", line)
            updated_lines.append(line)
        digest_path.write_text("\n".join(updated_lines).rstrip() + "\n", encoding="utf-8")

    def _repo_relative_display(self, path: Path) -> str:
        try:
            return str(path.resolve().relative_to(self.config.repo_dir.resolve()))
        except ValueError:
            return str(path)

    def _ship_digest_rewrite_needed(self, *, failures_before: int, warnings_before: int) -> bool:
        return len(self.context.failures) > failures_before or len(self.context.warnings) > warnings_before

    def _ensure_repo_digest_for_ship(self) -> bool:
        if self.context.digest_path != self.context.temp_digest_path or not self.context.branch_created:
            return True
        if not self.context.temp_digest_path.exists():
            self.context.add_failure(f"Cannot ship without a digest artifact at {self.context.temp_digest_path}")
            return False
        repo_digest_path = self.context.repo_digest_path
        repo_digest_path.parent.mkdir(parents=True, exist_ok=True)
        if not repo_digest_path.exists():
            shutil.copyfile(self.context.temp_digest_path, repo_digest_path)
        self.context.digest_path = repo_digest_path
        return True

    def _has_digest_artifact(self) -> bool:
        return self.context.digest_path is not None and self.context.digest_path.exists()

    def _timeout_exceeded_message(self) -> str:
        return f"Total runtime exceeded {self.timeout_budget.total_timeout_seconds}s during {self.context.current_phase}"

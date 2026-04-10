# Lauren Loop V2

This document describes the current production-hardened behavior of [`lauren-loop-v2.sh`](/Users/gstredny/AskGeorgeProject/lauren-loop-v2.sh) and [`lib/lauren-loop-utils.sh`](/Users/gstredny/AskGeorgeProject/lib/lauren-loop-utils.sh) after Phases A-C.

## Overview

The pipeline is a seven-phase competitive shell pipeline:

1. Explore
2. Parallel planning
3. Plan evaluation plus critic loop
4. Execution
5. Parallel review
6. Review synthesis plus fix-plan authoring and critique
7. Fix execution

Primary outputs live under `docs/tasks/open/<slug>/competitive/`. Runtime logs and cost shards live under `docs/tasks/open/<slug>/logs/`.
When a slug resolves to an existing flat task file, V2 now keeps artifacts alongside that canonical
task by using a sibling `<task-stem>/competitive/` and `<task-stem>/logs/` directory instead of
creating a duplicate top-level `docs/tasks/open/<slug>/task.md`.

## CLI

Usage:

```bash
bash lauren-loop-v2.sh <slug> "<goal>" [--dry-run] [--model <model>] [--internal] [--force] [--strict]
```

Flags:

- `--dry-run`
  - Validates prompt presence, prints engines, timeouts, paths, and strict-mode state.
- `--model <model>`
  - Overrides Claude model selection.
- `--internal`
  - Reuses the parent lock in nested invocations.
- `--force`
  - Backs up prior artifacts, clears Lauren Loop-owned outputs plus preserved attempt/cycle provenance files, and reruns from Phase 1.
- `--strict`
  - Enables strict production/CI behavior.

Subcommands:

- `chaos <slug>` — Run chaos-critic against the approved plan. Emits BLOCKING/CONCERN/NOTE findings; BLOCKING halts execution.
- `verify <slug>` — Goal-backward verification against done criteria. Emits per-criterion PASS/FAIL evidence.
- `plan-check <slug>` — Validate XML plan structure. Old numbered-step plans pass with a warning.
- `progress <slug>` — Show task progress including current phase and saved state.
- `pause <slug>` — Snapshot task state to `.planning/` for later resume.
- `resume <slug>` — Restore paused task, validate artifacts, and continue from saved phase.

## Environment Surface

### Core

| Variable | Default | Meaning |
|---|---|---|
| `LAUREN_LOOP_MODEL` | `opus` | Claude model name used by `--model` if not overridden |
| `LAUREN_LOOP_STRICT` | `false` | Explicit strict-mode switch; high-risk slug/goal text can also auto-enable effective strict mode |
| `LAUREN_LOOP_MAX_COST` | `0` | Cost ceiling in USD; `<= 0` disables the ceiling |
| `LAUREN_LOOP_NOTIFY` | `0` | If set to `1`, emit one macOS terminal-state notification for live runs |
| `SINGLE_REVIEWER_POLICY` | `synthesis` | `synthesis` or `strict`; diff risk does not rewrite this setting |
| `LAUREN_LOOP_CODEX_MODEL` | `gpt-5.4` | Codex model name for cost manifests and metadata |

### Engines

| Variable | Default | Phase |
|---|---|---|
| `ENGINE_EXPLORE` | `claude` | Explore |
| `ENGINE_PLANNER_A` | `claude` | Planner A |
| `ENGINE_PLANNER_B` | `codex` | Planner B |
| `ENGINE_EVALUATOR` | `claude` | Plan evaluator, review evaluator, fix-plan author |
| `ENGINE_CRITIC` | `claude` | Plan critic and fix-plan critic |
| `ENGINE_EXECUTOR` | `claude` | Main execution |
| `ENGINE_REVIEWER_A` | `claude` | Reviewer A |
| `ENGINE_REVIEWER_B` | `codex` | Reviewer B |
| `ENGINE_FIX` | `claude` | Fix executor |

### Codex Prompt and Model Contract

Codex-routed phases receive prompts assembled by `assemble_codex_prompt()`:

1. `PROJECT_RULES` (from `prompts/project-rules.md`) — project constraints (warns if missing)
2. `---` separator
3. Prompt body (from the phase-specific prompt file)
4. `---` separator
5. Task instruction (phase-specific context)

This mirrors `assemble_claude_prompt()` which prepends the same `PROJECT_RULES` to Claude prompts.

The Codex model name used in cost manifests and metadata defaults to `gpt-5.4` and is configurable via `LAUREN_LOOP_CODEX_MODEL`.
The current primary Codex Lauren-loop profile is `azure54`, which is configured for effective reasoning `xhigh`; `azure54med` is reserved as the medium-effort fallback. Lauren loop only drops to `azure54med` after the primary profile exhausts either the stream-disconnect path or the capacity-throttling path, and it does not currently route the main executor or fix executor through Codex by default.

For Codex file-authoring roles (`planner-b`, `reviewer-b*`), each attempt now writes to an attempt-local artifact path (`plan-b.attempt-N.md`, `reviewer-b.raw.attempt-N.md`) and an attempt-local summary file in `logs/` (`planner-b.attempt-N.summary.txt`, `reviewer-b.attempt-N.summary.txt`). The canonical latest aliases (`plan-b.md`, `reviewer-b.raw.md`, `planner-b.summary.txt`, `reviewer-b.summary.txt`) are updated only by atomic promotion after a structurally complete artifact exists, so retries cannot erase a usable prior attempt.

### Timeouts

| Variable | Default |
|---|---|
| `EXPLORE_TIMEOUT` | `15m` |
| `PLANNER_TIMEOUT` | `10m` |
| `EVALUATE_TIMEOUT` | `10m` |
| `CRITIC_TIMEOUT` | `15m` |
| `EXECUTOR_TIMEOUT` | `120m` |
| `REVIEWER_TIMEOUT` | `15m` |
| `SYNTHESIZE_TIMEOUT` | `10m` |

Reviewer timeout behavior:

- If `REVIEWER_TIMEOUT` is explicitly set, that value is used for reviewer launch, one-shot reviewer fallback, and the Reviewer B Codex backstop.
- Otherwise Phase 4 diff risk scales the effective reviewer timeout to `15m`, `30m`, or `45m` for `LOW`, `MEDIUM`, and `HIGH`.
- The resolved value is logged in the task execution log as part of Phase 4.

## Production Hardening Summary

### Phase A

- Signal handling:
  - `_interrupted()` traps `INT`, `TERM`, and `HUP`.
  - `cleanup_v2()` is re-entrancy-safe.
  - interrupted runs leave deterministic task/log state.
- Locking:
  - `acquire_lock()` uses atomic `mkdir` lock directories with PID files.
  - `acquire_lock()` writes the slug to a sidecar file (`slug` inside the lock directory for V2, `${LOCK_FILE}.slug` for V1).
  - `_check_cross_version_lock()` detects when V1 and V2 target the same slug concurrently (advisory warning, non-blocking).
  - stale locks are detected and recovered.
- Cost control:
  - `_check_cost_ceiling()` warns at 80% and halts at the configured ceiling.
  - `_merge_cost_csvs()` merges per-agent shards into `logs/cost.csv`.
- Timeout escalation:
  - `_timeout()` escalates from `TERM` to `KILL` after a 5-second grace window.
- Force reruns:
  - `_backup_artifacts_on_force()` snapshots prior `.md`, `.patch`, `.json`, and mapping artifacts.
  - `_clear_force_artifacts()` removes Lauren Loop-owned outputs plus preserved attempt/cycle files only.
- Execution safety:
  - empty execution diffs are detected
  - diff-scope validation is wired after Phase 4

### Phase B

- Contract parsing:
  - `_parse_contract()` prefers `.contract.json` sidecars, then falls back to markdown parsing when non-strict.
  - `_normalize_contract_token()` canonicalizes `verdict`, `ready`, and `status` values.
- Confidence gating:
  - `_classify_diff_risk()` uses conservative path-token matching for reviewer-timeout scaling and reviewer-phase advisory logging.
  - deployment / production-cutover / security-sensitive slug-or-goal text auto-enables effective strict mode for the full runtime.
  - single-planner survival can still halt based on effective strict mode or risk.
  - single-reviewer survival now halts only when explicit strict mode is enabled; MEDIUM/HIGH diff risk is advisory-only for that path.
- Resumability:
  - `_write_cycle_state()`, `_read_cycle_state()`, `_resume_target_ready()`, and `_phase7_resume_gate_reason()` support subphase resume.
- Task resolution:
  - top-level exact matches still win first
  - exact nested `<slug>.md` and `<slug>/task.md` matches under `docs/tasks/open/` are resolved before creating a new task
  - multiple exact nested matches halt as ambiguous instead of choosing a path silently
  - flat task matches consolidate into a sibling directory layout near the canonical task rather than into a duplicate top-level slug directory
- Corruption guards:
  - `_validate_agent_output()` and `_require_valid_artifact()` reject missing, empty, or corrupt artifacts.
- Direct artifact diagnostics:
  - Phase 1 missing or invalid `exploration-summary.md` failures now log the artifact path, output state, validation reason, and the last 20 lines of the explorer log when available.
- Observability:
  - `_init_run_manifest()`, `_update_run_manifest_state()`, `_append_manifest_phase()`, `_finalize_run_manifest()`, and `_print_phase_timing()` emit `run-manifest.json`.
  - manifest state is updated on phase entry, reviewer fallback engine swaps, and terminal finalization.
- Failure semantics:
  - `_fail_phase()` includes actionable recovery hints.

### Phase C

- Test coverage:
  - `tests/test_lauren_loop_signals.sh`
  - `tests/test_lauren_loop_logic.sh`
- Prompt/runtime alignment:
  - the five routed prompts now emit JSON contract sidecars.
  - Reviewer B is path-agnostic; the runtime instruction supplies the review artifact path per attempt instead of patching a rendered prompt.
- Strict mode:
  - strict parsing disables regex fallback for routed artifacts
  - ambiguous routed signals halt
  - single-planner survival halts before evaluation/execution
  - single-reviewer survival halts only when strict mode is explicitly enabled
  - raw dual-PASS fast path is disabled
  - empty fix diffs hard-block
  - cost ceiling is required only for effective-strict live runs, not strict dry runs

## Contracts

### Routed Artifacts

| Artifact | Sidecar | Routed field |
|---|---|---|
| `plan-evaluation.md` | `plan-evaluation.contract.json` | `selected_plan_present` |
| `plan-critique.md` | `plan-critique.contract.json` | `verdict` |
| `review-synthesis.md` | `review-synthesis.contract.json` | `verdict`, `critical_count`, `major_count`, `minor_count`, `nit_count` |
| `fix-plan.md` | `fix-plan.contract.json` | `ready` |
| `fix-execution.md` | `fix-execution.contract.json` | `status` |

### Parsing Rules

- Non-strict mode:
  - sidecar first
  - regex fallback allowed
  - legacy markdown forms remain accepted
- Strict mode:
  - routed sidecar required
  - no regex fallback
  - missing or ambiguous routed values block the pipeline

### Signal Extraction

`extract_agent_signal()` now accepts:

- plain `SIGNAL: value`
- bold markdown `**SIGNAL:** value`
- leading indentation
- duplicate fields, where the last occurrence wins

`_parse_contract()` and the critic loop now require exact routed verdicts. A blocked line containing the word `execute` no longer approves a plan.

## Review and Fix Routing

### Review Phase

- At least one usable reviewer artifact is required.
- `reviewer-a.raw.md`, `reviewer-b.raw.md`, `review-a.md`, and `review-b.md` are snapshotted per cycle as `*.cycleN.md`, and `.review-mapping` is snapshotted as `.review-mapping.cycleN`.
- Reviewer timeout resolution is shared across reviewer launch, opposite-engine fallback, and the Reviewer B Codex backstop.
- If both reviewer artifacts survive:
  - non-strict mode may fast-path only when both routed verdicts are `PASS` and no critical/major findings are detected
  - strict mode always disables this fast path and forces `review-synthesis.md`
- If only one reviewer artifact survives:
  - non-strict mode may continue to synthesis even when diff risk is `MEDIUM` or `HIGH`
  - strict mode always halts for human review

### Planning Phase

- `planner-b` attempt artifacts are preserved as `plan-b.attempt-N.md`.
- A non-zero-exit planner artifact still counts if it passes structural completeness validation.
- Effective strict mode halts for human review when only one planner survives, instead of seeding `revised-plan.md` automatically.

### Review Synthesis Verdicts

| Verdict | Behavior |
|---|---|
| `PASS` | pipeline ends at `needs verification` |
| `CONDITIONAL` | enters fix cycle |
| `FAIL` | enters fix cycle |

### Fix Phase Gates

| Artifact | Routed value | Behavior |
|---|---|---|
| `fix-plan.md` | `READY: no` / `ready=false` | halt for human review |
| `fix-execution.md` | `STATUS: BLOCKED` / `status=BLOCKED` | halt for human review |
| fix diff | empty | warning in non-strict, hard block in strict |

## Cost Tracking

Runtime cost data lives in `logs/cost.csv`.

Header:

```text
timestamp,task,agent_role,engine,model,reasoning_effort,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,cost_usd,duration_sec,exit_code,status
```

The header has 14 columns (`reasoning_effort` was added between `model` and `input_tokens`). Legacy 13-column CSV files using the old header are auto-migrated by `_ensure_cost_csv_header()` — existing rows receive `n/a` for the missing column.

Behavior:

- each agent writes to its own `.cost-<role>.csv` shard
- `_merge_cost_csvs()` normalizes and merges shards
- interrupted rows are preserved
- malformed legacy files are archived and replaced
- terminal summaries show total, linear-equivalent, and premium cost

## Run Manifest and Resume Data

### `run-manifest.json`

Tracks:

- task slug
- engine selections
- `current_phase`
- `active_engines`, including reviewer fallback swaps such as `claude (fallback)`
- `diff_risk`
- `effective_timeouts.reviewer`
- per-phase start/end timestamps and status history in `phases`
- final outcome
- total merged cost

Write points:

- phase entry
- reviewer fallback engine swap
- terminal finalization

### `.cycle-state.json`

Tracks:

- `fix_cycle`
- `last_completed`
- `review_verdict`
- timestamp

Resume only proceeds when the needed downstream artifacts are still valid.

## Human Handoff

When the pipeline stops for manual review, it writes `competitive/human-review-handoff.md` with the current state and blocking reason. Common reasons include:

- `SINGLE_REVIEWER`
- `COST_CEILING`
- review-cap exhaustion
- fix-plan or fix-execution explicit blocks

## New and Changed Helper Functions

### `lib/lauren-loop-utils.sh`

Phase A-C additions and major changes:

- `_timeout`
- `notify_terminal_state`
- `_atomic_append`
- `_atomic_write`
- `_validate_agent_output`
- `_write_cycle_state`
- `_read_cycle_state`
- `_archive_round_artifact`
- `run_critic_loop`
- `extract_agent_signal`
- `_strict_contract_mode`
- `_normalize_contract_token`
- `_parse_contract`
- `check_diff_scope`

Tech debt additions:

- Cost: `_extract_claude_tokens`, `_extract_codex_tokens`, `_calculate_cost`, `_append_cost_row`, `_ensure_cost_csv_header`, `_emit_normalized_cost_rows`, `read_v1_total_cost`, `read_v2_total_cost`
- Lock: `_check_cross_version_lock`

### `lauren-loop-v2.sh`

Phase A-C additions and major changes:

- `acquire_lock`
- `release_lock`
- `cleanup_v2`
- `_interrupted`
- `_merge_cost_csvs`
- `_print_cost_summary`
- `_print_phase_timing`
- `_backup_artifacts_on_force`
- `_clear_force_artifacts`
- `_check_cost_ceiling`
- `_phase7_resume_gate_reason`
- `_resume_target_ready`
- `_resolve_reviewer_timeout`
- `_reviewer_timeout_resolution_source`
- `_init_run_manifest`
- `_update_run_manifest_state`
- `_append_manifest_phase`
- `_finalize_run_manifest`
- `lauren_loop_competitive`

Tech debt additions:

- `_is_terminal_status`

## Test Coverage

Phase C added two shell suites:

- `bash tests/test_lauren_loop_signals.sh`
  - signal extraction and verdict parsing edge cases
- `bash tests/test_lauren_loop_logic.sh`
  - critic loop return codes
  - reviewer survival routing
  - dual-PASS fast path behavior
  - checkpoint skip and force rerun
  - archive naming
  - lock contention
  - merged cost CSV integrity
  - human handoff generation
  - cycle resume
  - strict live vs dry-run cost-ceiling behavior

Tech debt added three shell suites:

- `bash tests/test_lauren_loop_cost.sh`
  - cost CSV summation, missing CSV fallback, legacy 13→14 column migration
- `bash tests/test_lauren_loop_auto.sh`
  - auto-classification, V2 resume passthrough, config-driven routing
- `bash tests/test_lauren_loop_v2_scope.sh`
  - V2 diff-scope validation

Existing regression suites still apply:

- `bash test_lauren_loop_utils.sh`
- `bash test_cost_tracking.sh`
- `bash test_interrupt_integration.sh`

## Known Limits

- Strict mode trusts routed JSON sidecars, not reviewer raw markdown.
- Reviewer A still uses the task-file bridge before extraction to `reviewer-a.raw.md`.
- Diff-risk classification is heuristic, not semantic.
- Cost values for Codex remain estimates derived from character counts.

## Terminal Notifications

`LAUREN_LOOP_NOTIFY=1` enables a single best-effort macOS notification per live run. Dry runs do not notify.

| Terminal state | Category | Sound | Example banner |
|---|---|---|---|
| PASS / pipeline complete | `pass` | `Glass` | `Pipeline complete — <slug>` |
| Human review handoff | `human-review` | `Purr` | `Human review needed — <slug>` |
| Blocked failure | `blocked` | `Basso` | `Pipeline blocked — <slug>` |
| Interrupt (`INT` / `TERM` / `HUP`) | `interrupted` | `Basso` | `Pipeline interrupted (<signal>) — <slug>` |

The notifier is shell-native only. It does not rely on Claude hooks, and it silently no-ops when `afplay` or `osascript` is unavailable.

For long-running work, use a separate idle Claude session as a watcher with the standardized `/loop` prompt below. The watcher should cancel itself after it sees `needs verification` or `blocked`.

```text
/loop 5m watch-lauren-loop:<slug> Read /Users/gstredny/AskGeorgeProject/docs/tasks/open/<slug>/task.md. If ## Status is "in progress", reply with the newest Execution Log line only. If ## Status is "needs verification" or "blocked", summarize the terminal reason using task.md and any available human-review-handoff.md or review-synthesis.md, say "LAUREN LOOP DONE", then list scheduled tasks and delete the one whose prompt contains "watch-lauren-loop:<slug>".
```

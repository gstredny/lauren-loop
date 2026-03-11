# Autonomous Pilot Architecture

Reference documentation for the lauren-loop.sh autonomous agent pipeline. Covers every phase, agent role, prompt, and status transition as implemented today.

---

## Overview

The autonomous pilot is a multi-phase agent pipeline that takes a one-line task goal and drives it through planning, critique, execution, code review, fix application, and close-out — with a task file as the communication bus between fresh `claude -p` sessions.

**7 agent roles:** Planner, Critic, Executor, Reviewer, Review Critic, Fix Agent, Next Task

**Communication pattern:** Every agent reads the same task file for context and writes only to its designated section. No agent sees another agent's session — isolation is enforced by fresh `claude -p` invocations with the `env -u CLAUDECODE` pattern to allow nested sessions.

**Human touch points:** Write the goal. Approve the plan. Close the task. Everything else is autonomous.

---

## Full Pipeline Diagram

```
You (write slug + goal)
        │
        ▼
┌────────────────────────────────────────────────────────────────────────┐
│  lauren-loop.sh <slug> "<goal>"                                        │
│                                                                        │
│  1. Create task file from template + inject context                    │
│                                                                        │
│  ┌─── PLAN-CRITIQUE LOOP (max 3 rounds) ─────────────────────────┐    │
│  │                                                                │    │
│  │  Planner (max-turns 15)                                        │    │
│  │  → writes ## Current Plan                                      │    │
│  │                                                                │    │
│  │  Critic (max-turns 25)                                         │    │
│  │  → writes ## Critique                                          │    │
│  │  → VERDICT: PASS → break    FAIL → archive + loop              │    │
│  │            exit 3 (exhausted) → retry same plan                │    │
│  │                                                                │    │
│  │  if FAIL: archive plan+critique to ## Plan History             │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  PASS → status: plan-approved     FAIL×3 → status: needs-human-review  │
└────────────────────────────────────────────────────────────────────────┘
        │
        ▼
You (review plan, say "execute" or intervene)
        │
        ▼
┌────────────────────────────────────────────────────────────────────────┐
│  lauren-loop.sh execute <slug>                                         │
│                                                                        │
│  Executor (max-turns 30)                                               │
│  → TDD vertical slices: RED → GREEN → REFACTOR                        │
│  → writes ## Execution Log                                             │
│  → commits: feat(pilot-<slug>): ...                                    │
│  → captures diff to logs/pilot/pilot-<slug>-diff.patch                 │
│                                                                        │
│  Success → status: executed     Error → status: execution-failed       │
│  BLOCKED → status: execution-blocked                                   │
└────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────────────────┐
│  lauren-loop.sh review <slug>                                          │
│                                                                        │
│  ┌─── REVIEWER-CRITIC LOOP (max 2 rounds) ───────────────────────┐    │
│  │                                                                │    │
│  │  Reviewer (max-turns 25)                                       │    │
│  │  → reads diff + changed files, writes ## Review Findings       │    │
│  │  → VERDICT: PASS | FAIL                                        │    │
│  │                                                                │    │
│  │  Review Critic (max-turns 15)                                  │    │
│  │  → evaluates review thoroughness, writes ## Review Critique    │    │
│  │  → VERDICT: PASS → accept review    FAIL → reviewer re-reviews │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  Review PASS → status: review-passed                                   │
│  Review FAIL → status: review-findings-pending                         │
└────────────────────────────────────────────────────────────────────────┘
        │ (if findings pending)
        ▼
┌────────────────────────────────────────────────────────────────────────┐
│  lauren-loop.sh fix <slug>                                             │
│                                                                        │
│  Fix Agent (max-turns 30)                                              │
│  → reads ## Review Findings, applies fixes via TDD                     │
│  → writes ## Fixes Applied                                             │
│  → commits: fix(pilot-<slug>): address review findings                 │
│  → re-captures diff                                                    │
│                                                                        │
│  Success → status: fixed     (then: lauren-loop.sh review <slug>)      │
└────────────────────────────────────────────────────────────────────────┘
        │ (when review-passed)
        ▼
You (close task, move to docs/tasks/closed/, run retro)
```

**Standalone subcommand:**

```
lauren-loop.sh next [--model <model>]
│
▼
Next Task agent (max-turns 15)
→ reads all open tasks, roadmap, retro
→ outputs ranked top-3 recommendations to stdout
```

---

## CLI Reference

### Planner-Critic Pipeline

```bash
./lauren-loop.sh <slug> "<goal>" [--dry-run] [--resume] [--model <model>]
```

| Flag | Description |
|---|---|
| `<slug>` | Task identifier. Creates `docs/tasks/open/pilot-<slug>.md` |
| `"<goal>"` | One-line task description, injected as `## Goal` |
| `--dry-run` | Create task file + inject context, skip agent runs |
| `--resume` | Require an existing task file match and resume it; error if none is found |
| `--model` | Model override (default: `$LAUREN_LOOP_MODEL` or `opus`) |

### Subcommands

```bash
./lauren-loop.sh next [--model <model>]
```

Recommend which open task to work on next. Outputs ranked top-3 to stdout.

```bash
./lauren-loop.sh execute <slug> [--model <model>]
```

Execute a plan-approved task via TDD executor. Status gate: requires `plan-approved`.

```bash
./lauren-loop.sh review <slug> [--model <model>]
```

Review an executed task's diff via reviewer + critic loop. Status gate: requires `executed` or `fixed`.

```bash
./lauren-loop.sh fix <slug> [--model <model>]
```

Apply fixes for review findings, then re-review. Status gate: requires `review-findings-pending`.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LAUREN_LOOP_MODEL` | `opus` | Default model for all agents. Overridden by `--model`. |

---

## Agent Roles

| Role | Prompt File | Max Turns | Disallowed Tools | Task File Section | Key Behavior |
|---|---|---|---|---|---|
| **Planner** | `prompts/planner.md` | 15 | Bash, WebFetch, WebSearch | `## Current Plan` | Reads codebase, writes implementation plan. No code. |
| **Critic** | `prompts/critic.md` | 25 | Bash, WebFetch, WebSearch | `## Critique` | Independently verifies planner claims. 6-dimension evaluation. |
| **Executor** | `prompts/executor.md` | 30 | WebFetch, WebSearch | `## Execution Log` + source files | TDD vertical slices. Commits on completion. |
| **Reviewer** | `prompts/reviewer.md` | 25 | WebFetch, WebSearch | `## Review Findings` | 8-dimension review of diff + full files. |
| **Review Critic** | `prompts/review-critic.md` | 15 | Bash, WebFetch, WebSearch | `## Review Critique` | 6-item checklist evaluating review thoroughness. |
| **Fix Agent** | `prompts/fix-agent.md` | 30 | WebFetch, WebSearch | `## Fixes Applied` + source files | TDD fixes for critical/major findings. Dispute protocol. |
| **Next Task** | `prompts/next-task.md` | 15 | Bash, WebFetch, WebSearch | None (stdout only) | Reads open tasks, roadmap, retro. Ranked recommendations. |

**Tool restriction pattern:** Read-only agents (planner, critic, review critic, next task) have Bash disallowed to prevent code execution. Write agents (executor, fix agent, reviewer) need Bash to run tests and inspect diffs.

**All agents** have `--permission-mode acceptEdits` and `--output-format text`.

---

## Status State Machine

```
                    ┌─────────────────────┐
                    │   pilot-planning    │  (initial, set by template)
                    └──────────┬──────────┘
                               │ lauren-loop.sh <slug> "<goal>"
                               ▼
              ┌────── PLAN-CRITIQUE LOOP ──────┐
              │                                │
              │ PASS ──────────────────┐       │ FAIL × MAX_ROUNDS
              │                        ▼       │        │
              │               ┌──────────────┐ │        ▼
              │               │plan-approved │ │ ┌──────────────────┐
              │               └──────┬───────┘ │ │needs-human-review│
              │                      │         │ └──────────────────┘
              └────────────────────────────────┘
                                     │ lauren-loop.sh execute <slug>
                                     ▼
                              ┌──────────┐
                              │executing │
                              └──────┬───┘
                       ┌─────────────┼─────────────┐
                       ▼             ▼              ▼
              ┌────────────┐ ┌──────────────┐ ┌──────────────────┐
              │  executed   │ │exec-failed   │ │execution-blocked │
              └──────┬──────┘ └──────────────┘ └──────────────────┘
                     │ lauren-loop.sh review <slug>
                     ▼
              ┌──────────┐
              │reviewing │
              └──────┬───┘
              ┌──────┴───────────────────────┐
              ▼                              ▼
     ┌───────────────┐          ┌──────────────────────────┐
     │ review-passed │          │review-findings-pending   │
     └───────────────┘          └──────────┬───────────────┘
                                           │ lauren-loop.sh fix <slug>
                                           ▼
                                    ┌──────────┐
                                    │ fixing   │
                                    └──────┬───┘
                              ┌────────────┼────────────┐
                              ▼            ▼            ▼
                       ┌──────────┐ ┌───────────┐ ┌───────────┐
                       │  fixed   │ │fix-failed │ │fix-blocked│
                       └──────┬───┘ └───────────┘ └───────────┘
                              │
                              │ lauren-loop.sh review <slug>
                              ▼
                       (back to reviewing)

     Error states at any phase:
       review-failed    (reviewer or review-critic crashed)
       pipeline-error   (planner or critic crashed)
```

**Terminal statuses (require human intervention):**
- `plan-approved` — human reviews and runs `execute`
- `review-passed` — human closes task, moves to `docs/tasks/closed/`, runs retro
- `needs-human-review` — planner couldn't satisfy critic in 3 rounds
- `*-failed` / `*-blocked` — agent error or BLOCKED protocol triggered

---

## Task File Template

Source: `templates/pilot-task.md`

```markdown
## Task: {{TASK_NAME}}
## Status: pilot-planning
## Goal: {{GOAL}}
## Tags:
## Created: {{TIMESTAMP}}

## Constraints
- No mock data — external service fails → return error message
- .env is read-only
- No new endpoints — modify existing, maintain backward compatibility
- Never recreate singletons
- Preserve LRU cache decorators
- UI changes require explicit user approval

## Current Plan
(Planner writes here)

## Critique
(Critic writes here)

## Plan History
(Archived plan+critique rounds)

## Related Context
(Auto-injected by script)

## Execution Log
(Timestamped round results)
```

**Section ownership:** Each agent writes only to its designated section. The script appends timestamped entries to `## Execution Log` for pipeline-level events (phase transitions, verdicts, errors).

**Additional sections added during pipeline:**
- `## Review Findings` — written by Reviewer
- `## Review Critique` — written by Review Critic
- `## Fixes Applied` — written by Fix Agent

---

## Context Injection

The `inject_context()` function runs after task file creation to populate `## Related Context` with project-level awareness.

### How It Works

1. **Extract keywords** from the `## Goal` line — words >3 characters, common English words filtered out, max 5 keywords
2. **Search closed tasks** — `grep -ril` each keyword against `docs/tasks/closed/`, max 3 matches per keyword
3. **Search retro patterns** — `grep -i "Pattern:.*$kw"` against `docs/tasks/RETRO.md`, max 2 matches per keyword
4. **Search open tasks** — `grep -ril` each keyword against `docs/tasks/open/` (excluding current task), max 3 matches per keyword
5. **Budget enforcement** — Total injected context capped at 2000 characters. Entries stop once budget is reached.

### Output Format

```
- Closed task: pilot-some-task.md (keyword: auth)
- Retro: **Pattern:** Always validate tokens at the boundary...
- Open task: fix-token-expiry.md (keyword: auth)
```

This gives agents situational awareness they wouldn't know to search for — related past work, lessons learned, and parallel active tasks.

---

## Bug Fixes Applied

### 1. `set -e` Critic Loop Fix

The script uses `set -e` (exit on error) at the top. Critic returning exit code 1 (FAIL verdict) would kill the pipeline instead of looping. Fixed by capturing the exit code explicitly:

```bash
local critic_result=0
run_critic "$TASK_FILE" "$round" || critic_result=$?
```

Exit codes are then checked: 0=PASS, 1=FAIL, 3=exhausted, other=error.

### 2. Max-Turns Detection on All Agents

Every agent session checks its log file for `Reached max turns` after completion. If detected:
- **Planner/Critic:** restore backup, set error status
- **Executor:** set `execution-failed` status
- **Reviewer/Review Critic:** restore backup, set `review-failed` status
- **Fix Agent:** set `fix-failed` status

This prevents half-written sections from corrupting the task file.

### 3. Critic Exhaustion Handling (Exit Code 3)

When the critic exhausts its max turns, `run_critic` returns exit code 3 (distinct from FAIL=1 and error=2). The main loop handles this by:
- **Not archiving** the current plan (it wasn't rejected)
- **Not re-planning** (the plan was never critiqued)
- **Retrying** with the same plan on the next round
- After MAX_ROUNDS: setting `needs-human-review` with an "exhausted" message clarifying the plan was not rejected

---

## Prompt Tuning

### Trust the Plan + Escape Hatch (Executor)

The executor prompt opens with:

> The plan in ## Current Plan has been independently verified by a code-reading critic. File paths, line numbers, and function names are confirmed accurate. Do NOT re-investigate what the plan already verified, unless a step's inline verification command returns an unexpected result.

This prevents the executor from wasting turns re-exploring code the planner already mapped. The escape hatch: if a verification command returns unexpected results, the executor investigates the discrepancy before proceeding.

### Round-1 Rigor Clause (Critic)

The critic prompt includes a special round-1 rule:

> On round 1, a PASS verdict requires extra justification. For each dimension you mark PASS, state the specific evidence you verified (file path, function name, line number, or concrete observation). "Looks fine" or "appears correct" is not evidence.

This combats the rubber-stamp failure mode where the critic passes a plan without genuinely verifying claims.

### VERIFY Log Format (Executor)

For plan steps with no testable behavior (file deletion, config changes), the executor uses a non-TDD log format:

```
- [timestamp] VERIFY: <what was checked> — <result>
```

This distinguishes verification-only steps from RED-GREEN-REFACTOR cycles in the execution log.

### Next-Task Output Format Fix

The next-task prompt explicitly separates the ranked recommendations from the session summary:

> Your primary output is the ranked list. The session summary is a footer, not the main content.

And:

> This section goes LAST. It exists only to satisfy the stop-hook format — it is not the main output. Place the ranked recommendations ABOVE this section, never inside it.

This prevents the agent from burying recommendations inside the summary block.

---

## Retro Hook

Source: `prompts/retro-hook.md`

The retro hook generates lessons-learned entries for closed tasks.

### Pattern: Placeholder-Then-Replace

When a task is closed, a placeholder entry is added to `docs/tasks/RETRO.md`:

```
### [YYYY-MM-DD] Task: <task-stem>
_retro pending_
```

The retro hook agent then reads the closed task file and replaces the placeholder with a real 4-section entry:

```
### [YYYY-MM-DD] Task: <task-stem>
- **What worked:** ...
- **What broke:** ...
- **Workflow friction:** ...
- **Pattern:** ...  (most important — generalizable lesson)
```

### Duplicate Guard

The agent searches for existing `_retro pending_` placeholders to find exactly where to write. It replaces only that block, preventing duplicate entries.

### Tool Restrictions

The retro hook uses only Read, Edit, Glob, and Grep — no Bash, Write, WebFetch, or WebSearch. This prevents it from accidentally modifying source code or task files.

---

## Infrastructure

### Lock File

**Path:** `/tmp/lauren-loop-pilot.lock`

Prevents concurrent pipeline runs. Contains the PID of the running process. Stale locks (PID no longer running) are automatically cleaned up. Released via `trap release_lock EXIT`.

### Backup / Restore

Every agent run follows this pattern:

```bash
cp "$task_file" "${task_file}.bak"    # before agent runs
# ... run agent ...
# if error/corruption:
cp "${task_file}.bak" "$task_file"    # restore
# if success:
rm -f "${task_file}.bak"              # clean up
```

The `validate_task_file()` function checks that all required sections (`## Task:`, `## Status:`, `## Goal:`, `## Current Plan`, `## Critique`, `## Plan History`, `## Execution Log`) still exist after an agent run.

### Log Directory Structure

```
logs/pilot/
├── pilot-<slug>-planner-r1.log
├── pilot-<slug>-planner-r2.log
├── pilot-<slug>-critic-r1.log
├── pilot-<slug>-critic-r2.log
├── pilot-<slug>-executor.log
├── pilot-<slug>-reviewer-r1.log
├── pilot-<slug>-review-critic-r1.log
├── pilot-<slug>-fix.log
└── pilot-<slug>-diff.patch
```

Each log captures the full stdout/stderr of the `claude -p` session.

### `env -u CLAUDECODE` Pattern

All `claude -p` invocations are prefixed with `env -u CLAUDECODE` to unset the CLAUDECODE environment variable. This allows nested Claude Code sessions — without it, the inner `claude -p` would detect an existing session and refuse to start.

### Template Variable Injection

The executor and fix agent prompts contain `$PROJECT_NAME`, `$TEST_CMD`, and `$LINT_CMD` placeholders. These are replaced at runtime via `sed`:

```bash
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$PROJECT_NAME|$PROJECT_NAME|g")
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$TEST_CMD|$TEST_CMD|g")
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$LINT_CMD|$LINT_CMD|g")
```

---

## Known Limitations and Future Work

### `.lauren-loop.conf` for Project-Agnostic Config

There is a TODO in the execute subcommand:

```bash
# TODO: read TEST_CMD, LINT_CMD, PROJECT_NAME from .lauren-loop.conf for project-agnostic reuse
```

Currently, `$TEST_CMD`, `$LINT_CMD`, and `$PROJECT_NAME` are hardcoded in the script. A config file would allow the pipeline to be reused across projects without modifying `lauren-loop.sh`.

### Next-Task Prompt Live Validation

The next-task agent reads `docs/tasks/open/` and `docs/tasks/RETRO.md` at runtime but has no way to validate that its file reads succeeded. If the directory is empty or files have unexpected formats, the agent may produce unhelpful recommendations without reporting the issue.

### No Automatic Close-Out

The pipeline stops at `review-passed`. Moving the task file to `docs/tasks/closed/`, running the retro hook, and updating RETRO.md are manual steps. A `close` subcommand could automate this.

### Single-Worker Only

The lock file enforces single pipeline execution. Parallel execution of independent tasks would require per-task locking instead of a global lock.

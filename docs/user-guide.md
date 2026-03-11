# Lauren Loop — User Guide

A CLI that classifies tasks by complexity and routes them to the right pipeline — a fast single-agent pipeline (V1) for simple tasks, or a competitive multi-agent pipeline (V2) for complex ones. You provide the goal; Lauren Loop handles the back-and-forth.

This guide assumes Lauren Loop is being used inside a working project. References to `docs/tasks/open/` describe the active task workspace used by the scripts you launch.

## Before You Start

Lauren Loop works from task files in `docs/tasks/open/` within that task workspace.

- `pick` and `next` only rank task files that already exist there. They do not invent tasks from scratch.
- `auto <slug> "goal"` is the direct path when you already know the task you want to run.
- If you want to write context and done criteria yourself before launching, create a task from your task template first.

## Quick Glossary

- `task` — one markdown file under `docs/tasks/open/` that stores the goal, status, context, done criteria, and progress for one unit of work
- `slug` — a short kebab-case task identifier used in filenames and commands, for example `fix-auth-timeout`
- `goal` — a one-sentence description of the work, for example `"Fix Azure auth timeout during startup"`

## Choose Your Starting Path

### Path 1 — Existing Open Tasks (Recommended)

```bash
./lauren-loop.sh pick
```

What happens:

- Lauren Loop reads the open task files already in `docs/tasks/open/`
- It ranks them using the roadmap, retro, and git context
- You choose a task by number
- Lauren Loop reuses that task file's existing `## Goal:` automatically, so you do not retype the goal

If you only want a recommendation without launching anything, use:

```bash
./lauren-loop.sh next
```

### Path 2 — Brand-New Idea

If no suitable task exists yet, start directly from a slug and goal:

```bash
./lauren-loop.sh auto fix-auth-timeout "Fix Azure auth timeout during startup"
```

What happens:

- If Lauren Loop finds a matching task in `docs/tasks/open/`, it reuses it
- If no task matches, it creates a new task file and routes to V1 or V2
- If you want richer context up front, create the task yourself from your task template before launching

## How Tasks Are Set Up

- Installed projects get a scaffolded `docs/tasks/` structure, including `open/`, `closed/`, `deferred/`, `RETRO.md`, and `TEMPLATE.md`
- Canonical task files usually live as `docs/tasks/open/<slug>.md` or `docs/tasks/open/<slug>/task.md`
- A direct V1 start for a brand-new slug usually creates `docs/tasks/open/pilot-<slug>.md`
- A V2 run stores runtime artifacts under `docs/tasks/open/<slug>/competitive/` and `docs/tasks/open/<slug>/logs/`
- `pick` and `next` work from the open task files that already exist; they are not task-creation commands
- For the full task lifecycle, verification flow, and closeout rules, see `docs/WORKFLOW.md`

## How It Works

### The Hybrid Architecture

Lauren Loop has two pipelines. A complexity classifier decides which one to use:

| Pipeline | Best for | Agents | Duration |
|----------|----------|--------|----------|
| **V1 (Simple)** | 1-3 file changes, clear approach | 1 lead + critic loop | 15-45 min |
| **V2 (Complex)** | 4+ files, cross-cutting, ambiguous | 7+ agents in competitive phases | 45-120 min |

### V1 — Simple Tasks

A single Lead agent runs in one long session:

1. **Explores** the codebase (reads files, greps patterns, understands structure)
2. **Writes a plan** to the task file (files to modify, steps, test strategy, risks)
3. **Spawns a Critic** (fresh context, independent session) that verifies every claim
4. If Critic says FAIL → Lead revises the plan and re-spawns Critic (up to 3 rounds)
5. If Critic says PASS → Lead **executes the plan** using TDD (same session, full context)
6. **Auto-reviews** the diff via Reviewer + Review Critic
7. If review passes → a direct V1 run can **auto-close** the task (moves to `closed/`, runs retro)

The key insight: the Lead keeps full context from exploration through execution. It never re-reads the codebase. The Critic gets fresh eyes (separate context window) so it can't be anchored by the planner's reasoning.

Post-fix reviews receive both the original execution diff and the fix diff, with focus on the fix changes. This lets the reviewer understand the full context without re-evaluating already-approved code.

Direct `./lauren-loop.sh <slug> "goal"` runs use auto-review by default and auto-close unless you pass `--no-close`. The `auto` wrapper used by `pick` keeps routed V1 tasks open for human verification by always adding `--no-close`.

Use `--no-review` to skip auto-review, `--no-close` to stop after a `review-passed` handoff. Up to 2 fix cycles before stopping.

### V2 — Complex Tasks

Seven phases, each with purpose-built agents:

1. **Explore** — Explorer agent reads the codebase, produces a structured summary
2. **Plan** — Two planners draft plans in parallel (independent context)
3. **Evaluate** — Evaluator picks the best plan, Critic challenges it (up to 3 rounds)
4. **Execute** — TDD executor implements the winning plan
5. **Review** — Two reviewers examine the diff in parallel
6. **Synthesize** — Review evaluator merges findings, writes fix plan if needed
7. **Fix** — Fix executor applies fixes (loops to step 5, max 2 cycles)

V2 ends at `needs verification`. Review the diff, then close manually with `./lauren-loop.sh close <slug> --force` after your verification.

See `docs/v2-reference.md` for the V2 technical reference (contracts, signals, parsing, hardening).

### The Complexity Classifier

The classifier scores five dimensions as LOW or HIGH:

| Dimension | LOW | HIGH |
|-----------|-----|------|
| **File Count** | 1-3 files, single module | 4+ files, multiple modules |
| **Cross-Cutting Risk** | One layer (e.g., just backend) | Crosses layers (API + service + DB) |
| **Approach Ambiguity** | Obvious approach, clear precedent | Multiple viable approaches, unclear trade-offs |
| **Modification Risk** | Additive changes, new code | Modifying shared code paths, changing existing behavior |
| **Pattern Novelty** | Copy-and-adapt, known patterns | First-of-its-kind in the codebase |

**Classification rule:** 0-1 HIGH → simple (V1). 2+ HIGH → complex (V2). When in doubt → complex.

## When to Use This

**Use Lauren Loop when:**
- The task is complex enough that you'd spend 30+ minutes going back and forth
- You want to run a second task in the background while you work manually
- You want independent code review without reviewing the code yourself
- You want the system to decide whether a task needs one agent or seven

**Don't use Lauren Loop when:**
- The task is simple (delete a file, fix an import, rename a variable)
- You need the work done in under 10 minutes
- The task touches the same files you're currently editing

## The Workflow (4 Steps)

### Step 1 — Pick a task

```bash
./lauren-loop.sh pick
```

Reads your existing open task files, roadmap, and retro. Outputs a ranked list with complexity color-coding (green/yellow/red). Pick a number. Lauren Loop then extracts the selected task file's existing `## Goal:` automatically.

Two-step confirmation:

1. **`"Launch pipeline? (y/n)"`** — `y` continues to route selection. `n` prints the manual command and exits.
2. **`"Route: (1) Auto-classify  (2) Simple (V1)  (3) Complex (V2)"`** — Pick 1, 2, or 3 to launch. `0` or `n` goes back to the launch question.

Use `--fresh` to force re-ranking (skips the 10-minute cache).

### Step 2 — Pipeline runs autonomously

Depending on what you chose:

- **Option 1 (Auto-classify)** — Classifier scores 5 dimensions → routes to V1 or V2
- **Option 2 (Simple)** — V1 directly
- **Option 3 (Complex)** — V2 directly

Watch progress:

```bash
tail -f logs/pilot/pilot-<slug>-lead.log          # V1
./lauren-loop.sh progress <slug>                   # Either pipeline
```

**If it uses an existing task file:** Lauren Loop searches `docs/tasks/open/` for a matching file before creating a new one. If your task already has context, done criteria, and investigation notes, they're preserved.

### Step 3 — Review results

- **Auto-routed V1 (`pick` / `auto`)** — Auto-reviews, but keeps the task open for human verification instead of auto-closing.
- **Direct V1 (`./lauren-loop.sh <slug> "goal"`)** — Auto-reviews and auto-closes by default unless you use `--no-review` or `--no-close`.
- **V2** — Ends at `needs verification`. Review the diff, then close manually after your own verification.

### Step 4 — Close the task

```bash
./lauren-loop.sh close <slug>
```

Moves the task to `docs/tasks/closed/`, runs the retro agent, and generates an entry in `docs/tasks/RETRO.md`. Use plain `close <slug>` for `review-passed` tasks. Use `--force` after manually verifying a task that still sits in `needs verification` (common for V2).

## Alternative Entry Points

For users who skip `pick` and know what they want, especially when starting from a brand-new idea:

| Command | What it does |
|---------|-------------|
| `./lauren-loop.sh next` | Read-only ranking of existing open task files (top 3, no launch prompt) |
| `./lauren-loop.sh auto <slug> "goal"` | Reuse a matching task or create one from the slug/goal pair, then route to V1 or V2 |
| `./lauren-loop.sh auto <slug> "goal" --simple` | Force V1 routing |
| `./lauren-loop.sh auto <slug> "goal" --thorough` | Force V2 routing |
| `./lauren-loop.sh <slug> "goal"` | V1 directly (legacy, still works) |

## Cost Control

Default ceiling: **$100** (set in `.lauren-loop.conf`). Both pipelines track cumulative cost across all agent phases:

- **Warns at 80%** — logs a warning, continues running
- **Halts at 100%** — sets status to `needs verification`, writes a human-review handoff

Override with the `LAUREN_LOOP_MAX_COST` environment variable or edit `.lauren-loop.conf`. Set to `0` to disable the ceiling.

### Token Pricing

The pipeline uses Claude and Codex. Rates per 1M tokens:

| Engine | Token Type | Rate per 1M tokens |
|--------|-----------|---------------------|
| **Claude Opus** | Input | $5.00 |
| | Cache write | $6.25 |
| | Cache read | $0.50 |
| | Output | $25.00 |
| **Codex** | Input | $2.50 |
| | Output | $15.00 |

Claude token counts come from stream-json logs (exact). Codex tokens are estimated from character counts (~4 chars per token). Rates are defined in `lib/lauren-loop-utils.sh` — update them there if pricing changes.

### Example Run Cost

A real V2 run (`prod-rec-3b`, ~59 minutes, 2 fix cycles). The table shows the main agent per phase; each phase may also include sub-agents (critics, evaluators, failed competitive runners) whose costs are included in the total:

| Phase | Agent | Cost | Duration | Notes |
|-------|-------|------|----------|-------|
| Explore | explorer | $0.75 | 3m 32s | Heavy cache write (62K tokens) |
| Plan | planner-a | $0.42 | 2m 48s | Codex planner failed (competitive) |
| Evaluate | plan-critic | $0.40 | 1m 57s | |
| Execute | executor | $1.43 | 13m 48s | Largest phase — 1.8M cache read tokens |
| Review | reviewer-a | $0.82 | 7m 45s | + evaluator ($0.22) |
| Fix #1 | fix-executor | $0.69 | 5m 59s | + plan-author ($0.24), critic ($0.43) |
| Re-review #1 | reviewer-a | $0.89 | 7m 07s | + evaluator ($0.25) |
| Fix #2 | fix-executor | $0.31 | 2m 35s | + plan-author ($0.29), critic ($0.46) |
| Re-review #2 | reviewer-a | $0.89 | 6m 44s | + evaluator ($0.26) |
| **Total** | | **~$8.77** | **~59 min** | 20 agent runs total |

Cache reads dominate input tokens — Claude reuses context heavily across phases. The executor phase is always the most expensive (longest session, most code generation). Each fix cycle adds ~$2.00–2.50 (fix planning + execution + re-review).

**Typical cost ranges:**
- **V1 (simple task):** $1–3 (single agent session + critic + review)
- **V2 (complex task):** $4–8 for a clean run, $8–12 with fix cycles

### Cost Summary

Every pipeline prints a cost summary when it finishes:

```
=== Cost Summary: prod-rec-3b ===
  explorer (claude/opus)       $0.75 (662K in / 117 out, 212s)
  planner-a (claude/opus)      $0.42 (254K in / 66 out, 168s)
  executor (claude/opus)       $1.43 (1.9M in / 311 out, 828s)
  ...
  ─────────────────────────────────────────
  Total:                       $8.77
  Linear equivalent:           ~$6.50
  Competitive premium:         +$2.27 (+35%)
```

- **Total** — sum of all agent costs
- **Linear equivalent** — what it would cost without competitive parallelism (V2 only)
- **Competitive premium** — extra cost from running parallel planners/reviewers

V1 routes also report total cost in the `auto` summary via `read_v1_total_cost()`, but V1 prints a single total rather than the full per-agent breakdown shown above.

## Terminal Notifications

Set `LAUREN_LOOP_NOTIFY=1` to get macOS terminal sounds when a pipeline finishes:

| State | Sound | Meaning |
|-------|-------|---------|
| pass | Glass | Pipeline completed successfully |
| human-review | Purr | Human review needed |
| blocked | Basso | Pipeline finished without success |
| interrupted | Basso | Pipeline interrupted (signal/crash) |

macOS only. Silent no-op on other platforms.

## Review Quality

The reviewer checks for two critical anti-patterns:

**Ghost mocks:** For every mocked object, the reviewer verifies the mocked method actually exists on the target class. MagicMock absorbs any attribute — a mock on a nonexistent method is dead code that creates false confidence.

**Integration coverage:** When a feature spans 3+ files, at least one test must exercise the full call chain. If every test mocks the layer below it, there's no proof the components work together.

**Your role:** After the automated review, do a manual review to validate. The automated reviewer catches mechanical issues; you catch strategy and design problems. Over time, as confidence in the reviewer grows, your manual reviews can become lighter.

## How TDD Works

Instead of "build it, then check if it works," the executor flips the order:

1. **Write a test that describes success** — before writing any code
2. **Run the test — it fails.** The feature doesn't exist yet. This proves the test works.
3. **Write the smallest code to make that one test pass.** Nothing more.
4. **Run the test — it passes.** Now you have proof the feature works.
5. **Repeat** for the next piece.

At every step there's a safety net. If something breaks later, the tests catch it immediately.

## Parallel Workflow (2x Throughput)

**Terminal 1 (you):** Manual Claude Code session on your priority task.

**Terminal 2 (Lauren Loop):** Background pipeline on a second task.

**Critical rule: Zero file overlap.** Lauren Loop's task file lists "Files to Modify." If your manual work touches any of those files, pick a different Lauren Loop task.

## Context Guard Integration

Lauren Loop optionally sources `~/.claude/scripts/context-guard.sh` and calls `setup_azure_context` at startup. If the context guard is absent, fallback stubs ensure all Claude calls work normally via the default API.

## CLI Reference

### Subcommands

| Command | What it does |
|---------|-------------|
| `pick` | Interactively pick an existing open task (ranked list with numbered selection + launch) |
| `next` | Recommend which existing open task to work on next (read-only) |
| `auto <slug> "goal"` | Reuse a matching task or create one from the slug/goal pair, then route to V1 or V2 |
| `classify <slug>` | Classify task complexity as simple or complex; use `--goal` if no task file exists yet |
| `close <slug>` | Move a `review-passed` task to `closed/`; use `--force` for a manually verified handoff still in `needs verification` |
| `execute <slug>` | Execute a plan-approved task via TDD executor |
| `review <slug>` | Review an executed task's diff via reviewer + critic loop |
| `fix <slug>` | Apply fixes for review findings, then re-review |
| `chaos <slug>` | Run chaos-critic against approved plan |
| `verify <slug>` | Goal-backward verification of task outcomes |
| `plan-check <slug>` | Validate XML plan structure |
| `progress <slug>` | Show task progress summary |
| `pause <slug>` | Snapshot task state for later resume |
| `resume <slug>` | Restore paused task and continue |
| `reset <slug>` | Reset stuck task to last stable status |
| `<slug> "goal"` | V1 planner-critic pipeline (legacy entry point) |

### Flags

| Flag | Applies to | What it does |
|------|-----------|-------------|
| `--simple` | `auto` | Force V1 routing |
| `--thorough` | `auto` | Force V2 routing |
| `--force` | `auto`, `close` | Force rerun of V2 phases / close stuck tasks |
| `--fresh` | `pick` | Re-rank tasks, skip 10-minute cache |
| `--no-review` | `auto` (V1 route only), `<slug>` (V1) | Skip auto-review after execution |
| `--no-close` | `auto` (V1 route only), `<slug>` (V1) | Skip auto-close after `review-passed` |
| `--resume` | `auto`, `<slug>` | On direct V1 commands, require an existing task match. On V2 work, resume from saved checkpoint state when a task already exists. |
| `--legacy` | `<slug>` | Use legacy planner-critic loop + separate executor |
| `--dry-run` | `auto`, `<slug>` | Skip live agent execution; V1 creates or reuses the task file only, V2 prints planned phases |
| `--model <name>` | `pick`, `next`, `auto`, `classify`, `execute`, `review`, `fix`, `chaos`, `verify`, `<slug>` | Override model (default: opus) |

## Agent Architecture

### V1 Agents

| Role | Session | Purpose |
|------|---------|---------|
| Lead | Single long-running session | Explores, plans, handles critic feedback, executes — keeps full context |
| Critic | Fresh session per round | Verifies plan against codebase with independent eyes |
| Reviewer | Fresh session | 8-dimension code review on the diff |
| Review Critic | Fresh session | Validates reviewer was thorough |
| Fix Agent | Fresh session | TDD fixes for review findings |

### V2 Agents

| Role | Session | Purpose |
|------|---------|---------|
| Explorer | Fresh session | Reads codebase, produces structured exploration summary |
| Planner A | Fresh session | Drafts plan from exploration summary |
| Planner B | Fresh session (parallel) | Drafts independent competing plan |
| Evaluator | Fresh session | Picks best plan from the two candidates |
| Critic | Fresh session per round | Challenges the chosen plan (up to 3 rounds) |
| Executor | Fresh session | TDD implementation of the approved plan |
| Reviewer A | Fresh session | Code review on the diff |
| Reviewer B | Fresh session (parallel) | Independent competing review |
| Review Evaluator | Fresh session | Merges reviews, writes fix plan if needed |
| Fix Executor | Fresh session | Applies fixes from review findings |
| Chaos Critic | Fresh session | Adversarial challenge of plan robustness |
| Goal Verifier | Fresh session | Backward verification: do outcomes satisfy the original goal? |

**Fresh eyes architecture:** Critic and Reviewer agents are brand new sessions with no shared context. They can't be influenced by prior reasoning. This architecturally eliminates confirmation bias.

**Dead drop communication:** Agents communicate through files. The planner writes the plan, the critic reads it and writes the critique, the lead reads the critique and revises. No direct communication, full audit trail.

See `docs/autonomous-pilot-architecture.md` for agent prompts and status state machine.

## File Locations

| What | Where |
|------|-------|
| Main script | `lauren-loop.sh` |
| V2 script | `lauren-loop-v2.sh` |
| Shared utilities | `lib/lauren-loop-utils.sh` |
| V1 prompts | `prompts/lead.md`, `prompts/critic.md`, `prompts/reviewer.md`, `prompts/executor.md`, `prompts/fix-executor.md` |
| V2 prompts | `prompts/planner-a.md`, `prompts/planner-b.md`, `prompts/plan-evaluator.md`, `prompts/reviewer-b.md`, `prompts/review-evaluator.md`, `prompts/fix-plan-author.md` |
| Classifier prompt | `prompts/classifier.md` |
| Chaos critic prompt | `prompts/chaos-critic.md` |
| Verifier prompt | `prompts/verifier.md` |
| Retro prompt | `prompts/retro-hook.md` |
| Next-task prompt | `prompts/next-task.md` |
| Task files | V1 slug-based commands resolve `docs/tasks/open/<slug>/task.md`, `docs/tasks/open/<slug>.md`, or `docs/tasks/open/pilot-<slug>.md` when exactly one canonical match exists |
| V2 runtime artifacts | `docs/tasks/open/<slug>/competitive/` + `docs/tasks/open/<slug>/logs/`; the task file may be `docs/tasks/open/<slug>.md` or an existing `docs/tasks/open/<slug>/task.md` |
| Closed tasks | `docs/tasks/closed/` |
| Retro entries | `docs/tasks/RETRO.md` |
| V1 logs | `logs/pilot/pilot-<slug>-*.log` |
| V1 diffs | `logs/pilot/pilot-<slug>-diff.patch` |
| V1 fix diffs | `logs/pilot/pilot-<slug>-fix-diff.patch` |
| V1 cost tracking | `logs/pilot/pilot-<slug>-cost.csv` |
| V2 logs | `docs/tasks/open/<slug>/logs/` |
| V2 cost tracking | `docs/tasks/open/<slug>/logs/cost.csv` |
| Pause/resume state | `.planning/<slug>.json` |
| Configuration | `.lauren-loop.conf` |
| Context guard | `~/.claude/scripts/context-guard.sh` |

V1 slug-based commands reject mixed slug representations. If both `docs/tasks/open/<slug>/task.md` and `docs/tasks/open/<slug>.md` exist, they emit `ERROR: ambiguous task slug` and stop. Clean up one form before running those commands.

## Configuration

Place an `.lauren-loop.conf` file in the project root to override defaults:

```bash
# .lauren-loop.conf — Project-scoped Lauren Loop configuration
# All values are optional; built-in defaults apply when unset.

# LAUREN_LOOP_MODEL="${LAUREN_LOOP_MODEL:-opus}"         # Default model
# LAUREN_LOOP_STRICT="${LAUREN_LOOP_STRICT:-false}"       # Strict mode
LAUREN_LOOP_MAX_COST="${LAUREN_LOOP_MAX_COST:-100}"       # Cost ceiling ($)
PROJECT_NAME="${PROJECT_NAME:-myproject}"                   # Project name injected into prompts
TEST_CMD="${TEST_CMD:-pytest tests/ -x -q}"                      # Test command (V1)
LINT_CMD="${LINT_CMD:-flake8 src/ ...}"                           # Lint command (V1)
# EXPLORE_TIMEOUT="${EXPLORE_TIMEOUT:-15m}"               # Explorer phase timeout
# PLANNER_TIMEOUT="${PLANNER_TIMEOUT:-10m}"               # Planner phase timeout
# EXECUTOR_TIMEOUT="${EXECUTOR_TIMEOUT:-120m}"            # Executor phase timeout
# CRITIC_TIMEOUT="${CRITIC_TIMEOUT:-15m}"                 # Critic phase timeout
# REVIEWER_TIMEOUT="${REVIEWER_TIMEOUT:-15m}"             # Reviewer phase timeout
```

**Priority:** `--model` flag > environment variable > `.lauren-loop.conf` > built-in default.

## Troubleshooting

### "Reached max turns"

The Lead ran out of turns before completing. Check the log to see how far it got:

```bash
cat logs/pilot/pilot-<slug>-lead.log | tail -50
```

If it finished planning but didn't execute, the status will be `plan-approved` and you can run `./lauren-loop.sh execute <slug>` separately.

### Critic keeps failing

If the critic fails all 3 rounds, the Lead sets status to `plan-failed`. Read the task file — all plans and critiques are preserved in `## Plan History`. Re-scope the task to something smaller or manually approve the plan.

### "Diff file not found"

V1 subcommands (`execute`, `review`, `fix`, `chaos`, `verify`) now detect V2 tasks automatically and print a redirect message pointing to `lauren-loop-v2.sh`. The workaround below is only needed for genuine missing V1 diffs.

Generate it manually:

```bash
git log --oneline -5  # Find the pre-execution commit
git diff <before-sha>..HEAD > logs/pilot/pilot-<slug>-diff.patch
```

### Status stuck

If the Lead crashed mid-run, the task file may be in a transient status. Use `reset`:

```bash
./lauren-loop.sh reset <slug>
```

### Watch progress live

```bash
tail -f logs/pilot/pilot-<slug>-lead.log           # V1
./lauren-loop.sh progress <slug>                    # Either pipeline
```

### Classifier parse error

If the classifier output can't be parsed, `auto` exits with a parse error instead of guessing. Re-run the classifier directly to inspect the raw output:

```bash
./lauren-loop.sh classify <slug> --goal "your goal"
```

If the task file already exists, omit `--goal`.

### Cost ceiling reached

Pipeline halts and sets status to `needs verification`. A human-review handoff file is written to `competitive/human-review-handoff.md`. Review the work done so far, then either close or continue manually.

### V2-to-V1 routing conflict

If a slug already has a V2 task directory (`docs/tasks/open/<slug>/competitive/`), `auto --simple` will refuse. The task is already a V2 task — use `--thorough` or omit the flag.

### Resume artifacts missing

If `resume` fails because `.planning/<slug>.json` is missing, the pause snapshot was lost. Start fresh with `auto <slug> "goal"`.

### Lock contention

Only one Lauren Loop pipeline runs at a time per version (V1 lock: `/tmp/lauren-loop-pilot.lock`, V2 lock: `/tmp/lauren-loop-v2.lock.d/`). If a previous run crashed without releasing the lock, delete it manually:

```bash
rm /tmp/lauren-loop-pilot.lock       # V1
rm -rf /tmp/lauren-loop-v2.lock.d/   # V2
```

Both pipelines now write their slug to a sidecar file (`${LOCK_FILE}.slug` for V1, `slug` inside the V2 lock directory). If V1 and V2 target the same slug concurrently, the later pipeline emits an advisory warning — it does not block, but concurrent modifications to the same task file may cause corruption.

## Tips

1. **Walk away.** The whole point is async execution. Start it, go do something else.
2. **Prefer `pick` over `next`.** `pick` shows the same ranking but lets you launch directly with two keystrokes.
3. **Let the classifier decide.** Auto-classify gets routing right most of the time. Override only when you know better.
4. **Always do a manual code review.** The automated reviewer catches mechanical issues. You catch strategy problems. Trust but verify.
5. **Use `--model sonnet` for simple tasks.** Opus is slower but better at reasoning. Save it for complex planning.
6. **Set a cost ceiling.** The default $100 ceiling prevents runaway V2 pipelines.
7. **Use `chaos` for risky plans.** Run `./lauren-loop.sh chaos <slug>` before execution if the plan touches shared code.
8. **Use `verify` after manual fixes.** Run `./lauren-loop.sh verify <slug>` to confirm outcomes still match the original goal.
9. **One task per Lauren Loop run.** Don't try to batch multiple tasks.
10. **Check zero file overlap** before starting a parallel manual session.
11. **Retro entries compound.** The more tasks you close, the better `next` recommendations get.
12. **Include file paths in the goal** for complex tasks: `"Fix X. Key files: src/services/foo.py, src/api/bar.py"`
13. **Use `--resume` only when you want a hard fail on missing tasks.** Without it, Lauren Loop will still reuse an existing matching task file automatically.

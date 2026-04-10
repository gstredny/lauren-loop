# Night Shift VM Orchestrator

Bash-based overnight orchestrator that dispatches specialized Claude agents ("detectives") to investigate the AskGeorge production system, synthesizes their findings into a ranked digest, creates task files for issues found, and optionally auto-fixes critical problems via Lauren Loop V2.

- **Operational entrypoint:** `scripts/nightshift/nightshift-bootstrap.sh`
- **Core orchestrator:** `scripts/nightshift/nightshift.sh` (~5,100 lines)
- **Direct live guard:** `bash scripts/nightshift/nightshift.sh` fails closed unless `--force-direct` is passed. Direct `--dry-run` remains allowed.
- **Config:** `scripts/nightshift/nightshift.conf`
- **Schedule:** Daily at 11 PM local VM time via cron (`scripts/nightshift/install-cron.sh`)
- **Models:** Claude Opus 4.6 (primary), Azure Codex (optional secondary)

---

## Directory Layout

```
scripts/nightshift/
├── nightshift-bootstrap.sh    Fresh-checkout wrapper for cron/manual VM runs
├── nightshift.sh              Main orchestrator (all phases)
├── nightshift.conf            All tunable parameters
├── install-cron.sh            Cron setup (daily 11 PM VM-local time)
├── uninstall-cron.sh          Cron teardown
├── refresh-secrets.sh         Azure Key Vault secret refresh
├── lib/
│   ├── agent-runner.sh        Claude/Codex agent invocation + token extraction
│   ├── cost-tracker.sh        Token/cost accounting (jq JSON state)
│   ├── db-safety.sh           PostgreSQL readonly role enforcement
│   ├── git-safety.sh          Protected branch, commit message, PR size guards
│   ├── lauren-bridge.sh       Digest → Lauren Loop V2 task materialization
│   └── notify.sh              Webhook/email notification dispatch
├── playbooks/                 Detective + manager prompt templates
│   ├── README.md              Playbook inventory and authoring guide
│   ├── commit-detective.md
│   ├── conversation-detective.md
│   ├── coverage-detective.md
│   ├── error-detective.md
│   ├── performance-detective.md
│   ├── product-detective.md
│   ├── rcfa-detective.md
│   ├── security-detective.md
│   ├── manager-merge.md       Cross-detective synthesis + digest
│   ├── task-writer.md         Per-finding task file generation
│   └── validation-agent.md    Task completeness/feasibility checks
├── permissions/
│   ├── detective-readonly.json  Read-only filesystem/git
│   ├── detective-db.json        + SELECT-only DB access
│   └── manager-write.json       + Write access for digest/task output
├── tests/                     15 shell test scripts
└── logs/                      Daily execution logs + cost CSV

docs/nightshift/               Detective knowledge base (LLM-optimized)
├── README.md                  Loading order by playbook
├── architecture.md            System overview, request flow, error points
├── db-schema-map.md           15 tables with columns, types, join keys, SQL
├── error-signals.md           Error catalog with counts and sample SQL
├── known-patterns.md          Bug categories, git history patterns
├── network-architecture.md    Network topology
├── product-catalog-reference.md  Three-tier product data model
├── qc-bot-responses.md        Bot response quality criteria
└── qc-rcfa-reports.md         RCFA report quality criteria
```

---

## Execution Phases

| Phase | Name | What Happens | Gate Condition |
|-------|------|--------------|----------------|
| 1 | Setup | Git branch creation, cost init, env validation, DB safety check | Lock acquired, env present |
| 2 | Detective Runs | 8 detectives via Claude (optional Codex secondary per detective) | Claude CLI available, no cost cap |
| 3 | Manager Merge | Dedup, cross-detective synthesis, severity ranking, digest generation | Findings exist |
| 3.5a | Task Writing | Per-finding LLM call to create grounded task files in `docs/tasks/open/nightshift/` | Findings in digest |
| 3.5b | Task Validation | Validation agent checks each task for completeness and feasibility | Task files created |
| 3.5c | Autofix | Lauren Loop V2 on validated critical/major tasks | `NIGHTSHIFT_AUTOFIX_ENABLED=true`, validated tasks exist |
| 3.6 | Lauren Bridge | Materialize and execute digest findings via Lauren Loop V2 | `NIGHTSHIFT_BRIDGE_ENABLED=true`, digest exists |
| 3.7 | Backlog Burndown | Execute previously created open tasks with remaining budget | `NIGHTSHIFT_BACKLOG_ENABLED=true`, budget remaining |
| 4 | Ship Results | `git add/commit/push`, PR creation via `gh pr create` | Stageable files exist |
| 5 | Cleanup | Cost summary, webhook/email notification, lock file release | Always runs |

Phase dependencies: Task Writing → Validation → Autofix require Manager Merge success. Bridge and Backlog are independent feature-flagged phases. A cost cap or total timeout at any point triggers a fallback digest and skips to Phase 5.

---

## Detectives

| Detective | Focus | Data Source | Permission Profile |
|-----------|-------|-------------|-------------------|
| commit | Regression and edge-case detection in recent commits | `git log`/`diff` (7-day window) | `detective-readonly.json` |
| conversation | Q&A quality evaluation | DB `conversation_messages`, `feedback_summary` (3-day window) | `detective-db.json` |
| coverage | Test coverage gap identification | Filesystem, `git log` | `detective-readonly.json` |
| error | Production error pattern investigation | DB `chat_analytics_metrics`, `rcfa_analytics`, `enhanced_rag_metrics` | `detective-db.json` |
| performance | Latency percentile and slow-path investigation | DB analytics tables, `git log` | `detective-db.json` |
| product | Product code validation against canonical catalogs | DB `product_recommendations`, JSON catalogs | `detective-db.json` |
| rcfa | RCFA report quality evaluation (Tier 1/Tier 2 evidence hierarchy) | DB `failure_analyses`, `rcfa_analytics`, `product_recommendations` (30-day window) | `detective-db.json` |
| security | Vulnerability and auth-control investigation | Filesystem, `git log`, dependency audit | `detective-readonly.json` |

Each detective outputs findings to `/tmp/nightshift-findings/<name>-findings.md`.

---

## Agent Invocation

Agents are launched via `lib/agent-runner.sh` using the Claude CLI:

```bash
claude --print --output-format json \
  --model "$model" --max-turns "$max_turns" \
  --settings "$permission_profile" --permission-mode dontAsk \
  --system-prompt "$(cat playbook.md)" \
  "Begin investigation."
```

### Permission Profile Mapping

| Profile | Playbooks |
|---------|-----------|
| `detective-readonly.json` | commit, coverage, security, validation-agent, task-writer |
| `detective-db.json` | conversation, error, performance, product, rcfa |
| `manager-write.json` | manager-merge |

Unknown playbooks fall back to `detective-readonly.json` (fail-closed).

### Template Variables

The orchestrator substitutes these in playbooks before agent invocation:

| Variable | Default | Used By |
|----------|---------|---------|
| `{{COMMIT_WINDOW_DAYS}}` | 7 | commit-detective, coverage-detective |
| `{{CONVERSATION_WINDOW_DAYS}}` | 3 | conversation-detective, error-detective, performance-detective |
| `{{MAX_CONVERSATIONS}}` | 50 | conversation-detective |
| `{{RCFA_WINDOW_DAYS}}` | 30 | rcfa-detective |
| `{{DATE}}` | run date | all |
| `{{RUN_ID}}` | unique ID | all |

### Codex Secondary Engine

When `NIGHTSHIFT_CODEX_MODEL` is set, detectives optionally run a second pass with Codex via the `codex exec` CLI. Token counts are estimated (character count / 4). Codex runs are independent of Claude runs and their findings merge into the same output directory.

---

## Finding Format

All detectives output findings in this standardized format. The manager-merge playbook parses it for deduplication and ranking.

```markdown
### Finding: <short_title>
**Severity:** critical | major | minor | observation
**Category:** regression | error-handling | data-quality | product-accuracy | missing-test | performance | security
**Evidence:**
- <file:line or SQL result that proves the issue>
**Root Cause:** <1-2 sentences>
**Proposed Fix:** <what should change -- outcome, not implementation steps>
**Affected Users:** <estimated impact from data>
```

**Rules:** Every finding requires concrete evidence. No evidence = discard. Max 10 findings per detective per run. Max 15 task files per run.

---

## Output Artifacts

| Artifact | Path Pattern | Created By |
|----------|-------------|------------|
| Detective findings | `/tmp/nightshift-findings/<name>-findings.md` | Phase 2 |
| Rendered playbooks | `/tmp/nightshift-rendered/<name>.md` | Phase 2 |
| Digest | written to PR body / digest artifact | Phase 3 |
| Findings manifest | `/tmp/nightshift-findings/findings-manifest.txt` | Phase 3 |
| Task files | `docs/tasks/open/nightshift/{date}-{slug}.md` | Phase 3.5a |
| Task manifest | `/tmp/nightshift-findings/manager-task-manifest.txt` | Phase 3.5a |
| Cost state | `/tmp/nightshift-cost-state.json` | `lib/cost-tracker.sh` |
| Cost history | `scripts/nightshift/logs/cost-history.csv` | `lib/cost-tracker.sh` |
| Daily log | `scripts/nightshift/logs/YYYY-MM-DD.log` | `nightshift.sh` |
| PR | GitHub via `gh pr create` | Phase 4 |

---

## Configuration Reference

Full config: `scripts/nightshift/nightshift.conf` (102 lines). Safety-critical tunables below cannot be overridden by environment variables.

### Cost Controls

| Variable | Default | Purpose |
|----------|---------|---------|
| `NIGHTSHIFT_COST_CAP_USD` | 200 | Hard stop for entire run |
| `NIGHTSHIFT_PER_CALL_CAP_USD` | 25 | Warning threshold per agent call |
| `NIGHTSHIFT_RUNAWAY_THRESHOLD_USD` | 15 | Per-call high-cost threshold |
| `NIGHTSHIFT_RUNAWAY_CONSECUTIVE` | 3 | Halt after N consecutive high-cost calls |

### Investigation Scope

| Variable | Default | Purpose |
|----------|---------|---------|
| `NIGHTSHIFT_COMMIT_WINDOW_DAYS` | 7 | Git history depth |
| `NIGHTSHIFT_CONVERSATION_WINDOW_DAYS` | 3 | DB query window |
| `NIGHTSHIFT_RCFA_WINDOW_DAYS` | 30 | RCFA-specific wider window |
| `NIGHTSHIFT_MAX_CONVERSATIONS` | 50 | Max Q&A samples per detective |
| `NIGHTSHIFT_MAX_FINDINGS_PER_DETECTIVE` | 10 | Cap per detective |
| `NIGHTSHIFT_MAX_TASK_FILES` | 15 | Cap on task files per run |

### Bridge, Autofix, and Backlog

| Variable | Default | Purpose |
|----------|---------|---------|
| `NIGHTSHIFT_BRIDGE_ENABLED` | false | Enable Lauren Bridge phase |
| `NIGHTSHIFT_BRIDGE_MIN_SEVERITY` | major | Minimum severity for bridge execution |
| `NIGHTSHIFT_BRIDGE_AUTO_EXECUTE` | false | Auto-execute vs prepare-only |
| `NIGHTSHIFT_BRIDGE_MAX_TASKS` | 3 | Max tasks per bridge run |
| `NIGHTSHIFT_BRIDGE_MAX_COST_PER_TASK` | 25 | USD budget per bridge task |
| `NIGHTSHIFT_AUTOFIX_ENABLED` | false | Enable autofix phase |
| `NIGHTSHIFT_AUTOFIX_MAX_TASKS` | 5 | Max autofix tasks per run |
| `NIGHTSHIFT_AUTOFIX_MIN_BUDGET` | 20 | Minimum remaining budget to attempt autofix |
| `NIGHTSHIFT_AUTOFIX_SEVERITY` | critical,major | Severities eligible for autofix |
| `NIGHTSHIFT_BACKLOG_ENABLED` | false | Enable backlog burndown phase |
| `NIGHTSHIFT_BACKLOG_MAX_TASKS` | 3 | Max backlog tasks per run |
| `NIGHTSHIFT_BACKLOG_MIN_BUDGET` | 20 | Minimum remaining budget for backlog |

### Timeouts

| Variable | Default | Purpose |
|----------|---------|---------|
| `NIGHTSHIFT_AGENT_TIMEOUT_SECONDS` | 600 | Per-agent timeout (10 min) |
| `NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS` | 7200 | Entire run timeout (2 hours) |
| `NIGHTSHIFT_MAX_TURNS` | 25 | Multi-turn limit per agent |

### Git

| Variable | Default | Purpose |
|----------|---------|---------|
| `NIGHTSHIFT_BASE_BRANCH` | main | Base branch for PRs |
| `NIGHTSHIFT_PROTECTED_BRANCHES` | main,development,master | Cannot be worked on directly |
| `NIGHTSHIFT_MAX_PR_FILES` | 20 | PR file count limit |
| `NIGHTSHIFT_MAX_PR_LINES` | 5000 | PR line count limit |

---

## Safety Guardrails

### Cost Controls (`lib/cost-tracker.sh`)
- Hard cap at `$NIGHTSHIFT_COST_CAP_USD` (default $200) halts the run
- Per-call warning at `$NIGHTSHIFT_PER_CALL_CAP_USD` (default $25)
- Runaway detection: 3 consecutive calls exceeding $15 triggers halt
- State tracked in `/tmp/nightshift-cost-state.json` (jq-managed)
- Cost history appended to `scripts/nightshift/logs/cost-history.csv`

### Database Safety (`lib/db-safety.sh`)
- Readonly role enforced: `CREATE TABLE` must fail or run aborts
- Admin user (`NIGHTSHIFT_DB_ADMIN_USER`, default `gstredny`) is rejected
- Connection timeout: 10 seconds
- SSL mode: require

### Git Safety (`lib/git-safety.sh`)
- Protected branch list: `main`, `development`, `master`
- Commit message must have `nightshift: ` prefix
- PR rejected if > 20 files or > 5,000 lines changed

### Runtime Safety
- Lock file `/tmp/nightshift.lock` prevents concurrent runs
- Minimum 1 GB free disk space check (`NIGHTSHIFT_MIN_FREE_MB=1024`)
- Total timeout (2 hours) triggers fallback digest and cleanup

---

## Lauren Bridge

`lib/lauren-bridge.sh` (622 lines) materializes Night Shift digest findings into Lauren Loop V2 tasks for automated execution.

**How it works:**
1. Parses digest for findings above severity threshold (default: `major`)
2. Creates task files with Lauren Loop V2 sections (`## Current Plan`, `## Critique`, `## Plan History`, `## Execution Log`)
3. Falls back to `manager-task-manifest.txt` when digest is triage-only
4. Invokes `lauren-loop-v2.sh` per task with non-interactive mode and per-task cost budget
5. Tracks changed paths in `BRIDGE_STAGE_PATHS[]` for Phase 4 git staging

**Config flags:** `NIGHTSHIFT_BRIDGE_ENABLED`, `NIGHTSHIFT_BRIDGE_AUTO_EXECUTE`, `NIGHTSHIFT_BRIDGE_MIN_SEVERITY`

**Related:** `lauren-loop-v2.sh` at repo root is the competitive Claude + Codex task execution pipeline.

---

## Knowledge Base

Detective-specific context files live in `docs/nightshift/`. See `docs/nightshift/README.md` for loading order by investigation type.

| File | Purpose | When to Load |
|------|---------|-------------|
| `architecture.md` | System overview, request flow, error points | Always -- load first |
| `db-schema-map.md` | 15 tables with columns, types, join keys, SQL | Always -- load second |
| `error-signals.md` | Error catalog with live counts and sample SQL | When investigating errors |
| `product-catalog-reference.md` | Three-tier product data model, validation approach | When investigating product recs |
| `known-patterns.md` | Bug categories, git history patterns, failure modes | When triaging or diagnosing |
| `qc-bot-responses.md` | Bot response quality evaluation criteria | When investigating Q&A quality |
| `qc-rcfa-reports.md` | RCFA report quality evaluation criteria | When investigating RCFA quality |
| `network-architecture.md` | Network topology | When investigating connectivity |

---

## Schedule and VM Runtime

**Cron schedule** (installed by `scripts/nightshift/install-cron.sh`):
```
0 23 * * * bash -l -c '{ cd /home/gstredny/AskGeorgeProject && bash scripts/nightshift/nightshift-bootstrap.sh; } >> /home/gstredny/AskGeorgeProject/scripts/nightshift/logs/cron.log 2>&1'
```

Daily at 11 PM on the orchestrator VM's local timezone.

**Secrets:** Stored in `~/.nightshift-env` (mode 600), refreshed from Azure Key Vault by `scripts/nightshift/refresh-secrets.sh`. Contains:
- `ANTHROPIC_API_KEY` (from Key Vault secret `Opus45Key`)
- `AZURE_OPENAI_API_KEY` (from Key Vault secret `gpt54`)
- `NIGHTSHIFT_DB_PASSWORD` (from Key Vault secret `postgres-password`)

---

## Testing

15 test scripts in `scripts/nightshift/tests/`:

**Core orchestrator:**
- `test_control_flow_bugs.sh` -- Early exit paths, fallback digests, state transitions
- `test_orchestrator_followups.sh` -- Full orchestrator flow regression (14 focused tests)

**Phase-specific:**
- `test_task_writer.sh` -- Task writing (CREATED/REJECTED/malformed parsing)
- `test_validation.sh` -- Validation phase (VALIDATED/INVALID parsing)
- `test_autofix.sh` -- Autofix invocation, Lauren Loop manifest contract
- `test_lauren_bridge.sh` -- Bridge digest parsing, task materialization, slug generation
- `test_backlog_burndown.sh` -- Backlog task picking, dependency gates
- `test_backlog_dependency_gate.sh` -- Dependency blocking, transitive checks

**Safety and guardrails:**
- `test_cost_bugs.sh` -- Cost tracking, runaway detection, per-call cap
- `test_safety_libraries.sh` -- Git/DB safety preflight validation
- `test_permission_profiles.sh` -- Permission profile mapping per playbook
- `test_secrets_hygiene.sh` -- No plaintext DB passwords in codebase
- `test_network_egress.sh` -- Network egress controls
- `test_guardrails_cron_notify.sh` -- Notification dispatch (webhook/email)

**Shared fixtures:**
- `autofix_test_lib.sh` -- Shared autofix test utilities

Run all tests: `for t in scripts/nightshift/tests/test_*.sh; do bash "$t"; done`

---

## Troubleshooting

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (may include zero findings) |
| 1 | Error (setup failure, missing tools, etc.) |
| 2 | Cost cap or runaway threshold halted the run |

### Log Locations

| Log | Path |
|-----|------|
| Daily run log | `scripts/nightshift/logs/YYYY-MM-DD.log` |
| Cost history | `scripts/nightshift/logs/cost-history.csv` |
| Cron output | `scripts/nightshift/logs/cron.log` |
| Cost state (runtime) | `/tmp/nightshift-cost-state.json` |

### Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| "Lock file exists" | Previous run crashed or is still running | Check for running process, then `rm /tmp/nightshift.lock` |
| "Cost cap reached" | Cumulative spend hit $200 | Review cost CSV, adjust cap in `nightshift.conf` if needed |
| "DB safety check failed" | Readonly role not configured or admin user detected | Verify `nightshift_readonly` PostgreSQL role exists |
| "claude: command not found" | Claude CLI not installed on VM | Install Claude CLI, ensure it's on PATH |
| "No stageable files" at Phase 4 | No findings or all detectives failed | Check detective output in `/tmp/nightshift-findings/` |
| Fallback digest generated | Total timeout exceeded or manager merge failed | Check daily log for timeout/error messages |

---

## Related Documentation

- `docs/nightshift/README.md` -- Knowledge base loading order and secrets workflow
- `scripts/nightshift/playbooks/README.md` -- Playbook inventory, finding format, authoring guide
- `docs/tasks/TEMPLATE.md` -- Task file format used by the task-writer phase
- `docs/SYSTEM_OVERVIEW.md` -- Full AskGeorge system map
- `docs/RCFA_PIPELINE.md` -- RCFA pipeline (context for rcfa-detective)
- `docs/FAILURE_ANALYSIS.md` -- RCFA behavioral spec (required by rcfa-detective)

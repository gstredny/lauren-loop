# Nightshift Detective Playbooks

Prompt templates for overnight detective agents. Each playbook is fed to a Claude Code
agent by the orchestrator (`scripts/nightshift/nightshift.sh`) via a playbook-specific
permission profile:

```bash
claude --print \
  --settings <profile-path> \
  --permission-mode dontAsk \
  --system-prompt "$(cat playbook.md)" \
  "Begin investigation."
```

Current profile selection:
- `scripts/nightshift/permissions/detective-readonly.json` for read-only detective playbooks
- `scripts/nightshift/permissions/detective-db.json` for detective playbooks that need
  SELECT-only `psql` access
- `scripts/nightshift/permissions/manager-write.json` for `manager-merge`, which needs
  write access for task and digest output

Fail-closed default:
- Unknown playbooks fall back to `detective-readonly.json` instead of inheriting a
  broader profile.

## Playbook Inventory

| Playbook | Purpose | Primary Data Source | KB Files |
|----------|---------|---------------------|----------|
| commit-detective.md | Regression and edge-case detection in recent commits | git log / diff | architecture, known-patterns |
| conversation-detective.md | Q&A quality evaluation | conversation_messages, feedback_summary | architecture, db-schema-map, error-signals, product-catalog-reference, qc-bot-responses |
| error-detective.md | Production error pattern investigation | chat_analytics_metrics, rcfa_analytics, enhanced_rag_metrics | architecture, db-schema-map, error-signals, known-patterns |
| product-detective.md | Product code validation against canonical catalogs | product_recommendations, JSON catalogs | product-catalog-reference, db-schema-map, architecture |
| coverage-detective.md | Test coverage gap identification | filesystem, git log | architecture, known-patterns |
| security-detective.md | Vulnerability and auth-control investigation | filesystem, git log, dependency audit | architecture, known-patterns, db-schema-map |
| performance-detective.md | Latency percentile and slow-path investigation | conversation_messages, rcfa_analytics, product_recommendation_analytics, git log | architecture, db-schema-map, error-signals |
| manager-merge.md | Finding dedup, ranking, task file generation | Detective output files | architecture, TEMPLATE.md |
| rcfa-detective.md | RCFA report quality evaluation | failure_analyses, rcfa_analytics, product_recommendations, JSON catalogs | qc-rcfa-reports, architecture, db-schema-map, product-catalog-reference |

## Template Variables

The orchestrator substitutes these before feeding a playbook to an agent.

| Variable | Default | Used By | Description |
|----------|---------|---------|-------------|
| `{{COMMIT_WINDOW_DAYS}}` | 7 | commit-detective, coverage-detective | Days of git history to review |
| `{{CONVERSATION_WINDOW_DAYS}}` | 3 | conversation-detective, error-detective, performance-detective | Days of DB data and recent activity to review |
| `{{MAX_CONVERSATIONS}}` | 50 | conversation-detective | Max Q&A pairs to evaluate per run |
| `{{DATE}}` | run date | all | YYYY-MM-DD format |
| `{{RUN_ID}}` | unique ID | all | Unique identifier for this run |
| `{{RCFA_WINDOW_DAYS}}` | 30 | rcfa-detective | Days of RCFA data to review (wider than conversation window due to lower RCFA volume) |

## Standardized Finding Format

Every detective playbook instructs the agent to output findings in this exact format.
The manager-merge playbook parses this format to deduplicate and rank findings.

```markdown
### Finding: <short_title>
**Severity:** critical | major | minor | observation
**Category:** regression | error-handling | data-quality | product-accuracy | missing-test | performance | security
**Evidence:**
- <file:line or SQL result that proves the issue>
**Root Cause:** <1-2 sentences>
**Proposed Fix:** <what should change — outcome, not implementation steps>
**Affected Users:** <estimated impact from data>
```

**Rules:**
- Every finding must have concrete evidence (file:line, SQL result, or git diff)
- If a finding lacks evidence, discard it — do not guess
- Max 10 findings per detective playbook per run
- Max 15 task files from manager-merge per run

## Constraints

- All SQL is SELECT-only. No INSERT, UPDATE, DELETE, DROP, ALTER, or TRUNCATE.
- All playbooks are self-contained (no cross-playbook dependencies)
- DB connection via `$NIGHTSHIFT_DB_*` env vars (nightshift_readonly role)
- Do not modify source code, create branches, or push commits
- Findings output to `/tmp/nightshift-findings/<playbook-name>-findings.md`

## Adding a New Playbook

1. Copy an existing detective playbook as a starting template
2. Update the Role section with the new investigation focus
3. Specify which `docs/nightshift/` files to load in Knowledge Base
4. Define concrete Investigation Steps with exact commands and SQL
5. Include Out of Scope and Constraints sections
6. Include the standardized finding format template verbatim
7. Add the playbook to the inventory table above
8. Document any new template variables in the table above

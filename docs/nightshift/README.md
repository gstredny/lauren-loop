# Nightshift Detective Knowledge Base

Context files for autonomous LLM agents that investigate the AskGeorge codebase and production database for bugs overnight. These docs are optimized for LLM consumption — structured data, tables, SQL queries, not narrative prose. Load the files relevant to your investigation playbook before starting work.

## Files

| File | Purpose | When to Load |
|------|---------|-------------|
| [architecture.md](architecture.md) | System overview, request flow, service map, error points | Always — load first |
| [db-schema-map.md](db-schema-map.md) | 15 detective-relevant tables with columns, types, join keys, SQL queries | Always — load second |
| [error-signals.md](error-signals.md) | Error catalog with live counts, sample data, SQL queries per signal | When investigating errors or anomalies |
| [product-catalog-reference.md](product-catalog-reference.md) | Three-tier product data model, validation approach, JSON file paths | When investigating product recommendations |
| [known-patterns.md](known-patterns.md) | Bug categories, git history patterns, common failure modes | When triaging or diagnosing issues |
| [qc-bot-responses.md](qc-bot-responses.md) | Bot response quality evaluation criteria | When investigating conversation quality |
| [qc-rcfa-reports.md](qc-rcfa-reports.md) | RCFA report quality evaluation criteria | When investigating RCFA report quality |

## Loading Order by Playbook

### General Investigation
1. `architecture.md` — understand system structure
2. `db-schema-map.md` — know what tables to query
3. `error-signals.md` — find the error signals

### RCFA Investigation
1. `architecture.md` (RCFA Pipeline section)
2. `db-schema-map.md` (rcfa_analytics, analysis_sessions, failure_analyses, product_recommendations)
3. `error-signals.md` (Signal 6: RCFA failures)
4. `product-catalog-reference.md` — validate product codes

### Product Recommendation Investigation
1. `product-catalog-reference.md` — data model and validation
2. `db-schema-map.md` (product_recommendations, product_recommendation_analytics)
3. `error-signals.md` (Signal 3: product rec failures)

### Latency / Performance Investigation
1. `architecture.md` — identify which service is slow
2. `error-signals.md` (Signal 1: GPT5 fallback, Signal 5: high latency)
3. `known-patterns.md` — check if this is a known pattern

### User Experience Investigation
1. `error-signals.md` (Signal 4: negative feedback, Signal 8: session linkage)
2. `db-schema-map.md` (feedback_summary, conversation_messages)
3. `known-patterns.md` (feedback sparsity section)

### Conversation Quality QC Investigation
1. `qc-bot-responses.md` — quality evaluation criteria
2. `db-schema-map.md` — conversation_messages, feedback_summary schemas
3. `product-catalog-reference.md` — product code validation
4. `error-signals.md` — fallback markers, latency thresholds

### RCFA Report Quality Investigation
1. `qc-rcfa-reports.md` — quality evaluation criteria
2. `architecture.md` — RCFA pipeline section
3. `db-schema-map.md` — failure_analyses, rcfa_analytics, product_recommendations schemas
4. `product-catalog-reference.md` — product code validation
5. Note: `docs/FAILURE_ANALYSIS.md` is a required companion spec (lives outside `docs/nightshift/`)

## Secrets Workflow

Night Shift keeps runtime secrets in `~/.nightshift-env`. Refresh them manually or via a
separate cron job with:

```bash
bash scripts/nightshift/refresh-secrets.sh
```

That file is the canonical Night Shift secrets file. It should stay at mode `600`, and
the Docker sandbox task must consume it via `--env-file ~/.nightshift-env` instead of
inline `--env KEY=value` flags.

To reduce the chance of typing secrets into shell history, include this pattern in the
env file or shell setup:

```bash
export HISTIGNORE="*API_KEY*:*PASSWORD*:*SECRET*"
```

## Connection

```bash
PGPASSWORD="$NIGHTSHIFT_DB_PASSWORD" \
psql "host=$NIGHTSHIFT_DB_HOST port=5432 dbname=$NIGHTSHIFT_DB_NAME user=$NIGHTSHIFT_DB_USER sslmode=require connect_timeout=10"
```

## Data Snapshot

All live counts in error-signals.md are from **2026-03-27**. Refresh by re-running the SQL queries.

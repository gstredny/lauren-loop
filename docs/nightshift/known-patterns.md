# Known Patterns and Failure Modes

Documented patterns from git history analysis (last 50 commits as of 2026-03-27) and production error signals. Organized by bug surface area.

## Bug Surface Heatmap (Most-Changed Files)

| File | Changes (last 50 commits) | Category |
|------|--------------------------|----------|
| `tests/test_synapse_query_validator.py` | 8 | Security |
| `src/services/synapse_query_validator.py` | 7 | Security |
| `src/api/routers/analysis.py` | 5 | RCFA |
| `tests/test_well_context_enrichment.py` | 5 | RCFA |
| `src/services/analysis/comprehensive_rcfa_analyzer.py` | 4 | RCFA |
| `src/services/well_context_formatter.py` | 3 | RCFA |
| `tests/test_multi_tool_sequencing.py` | 3 | Agent |

## Category 1: RCFA Pipeline Fragility (6 recent fixes)

The RCFA pipeline is the most bug-prone subsystem. Recent fixes:

| Commit | Fix | Root Cause |
|--------|-----|-----------|
| `ea0724d8` | Product guard and RCFA regression tests | Guard logic didn't account for test scenarios |
| `83d7073f` | Upload-image RCFA timeout handling | Timeout not propagated through async chain |
| `6d4c804d` | PFI-h taxonomy validation, prediction accuracy | Taxonomy mismatch between PyTorch labels and DB enums |
| `e7ccab6f` | RCFA WELL_REVIEW DAX schema drift | Power BI column names changed without code update |
| `70e0369e` | Preserve injected confidence in prompt prep | Confidence score overwritten during prompt assembly |
| `993ba416` | flow_velocity_incomplete_data in confidence rewrite skip list | Edge case: incomplete data flagged for rewrite when it shouldn't be |

**Pattern:** RCFA bugs cluster around data transformations — converting between survey JSON, LLM output, DB columns, and Power BI schemas. When any schema changes upstream, downstream code breaks silently.

**Detective signal:** `rcfa_analytics.success = false` or `analysis_sessions.status = 'failed'`

## Category 2: Synapse Query Validator Security (5 recent fixes)

Tenant isolation and SQL injection prevention in the Synapse query validator:

| Commit | Fix | Attack Vector |
|--------|-----|--------------|
| `81267075` | Scope-aware self-join detection | Self-join bypassed site_id scoping |
| `7691df36` | CTE scoping leak | CTE definitions leaked scope across query boundaries |
| `cbb47cfb` | JOIN detection in CTE outer query | LEFT/INNER/RIGHT/FULL/CROSS JOIN in CTE outer query evaded routing |
| `b89867fc` | Self-join alias preservation, unaliased rejection | Unaliased self-joins bypassed tenant isolation |
| `f42d9ee6` | UNION/EXCEPT/INTERSECT rejection | Set operations could merge data across tenant scopes |

**Pattern:** Each fix addresses a SQL parsing edge case where a query construct could bypass the `site_id` tenant isolation filter. The validator parses SQL text — it doesn't use a proper AST, so novel SQL constructs can slip through.

**Detective signal:** Not directly in DB. Look for: unusual query patterns in logs, or test regressions in `tests/test_synapse_query_validator.py`.

## Category 3: Data Type Safety (3 recent fixes)

Float/NaN/Inf handling bugs in numeric processing:

| Commit | Fix | Root Cause |
|--------|-----|-----------|
| `8ca353ad` | Guard float() crashes and NaN leakage in well context formatter | `float()` called on non-numeric strings |
| `43e1bd49` | `_coerce_to_float` NaN/inf bug | `math.isfinite()` not checked after coercion |
| `3de87ce4` | CO2 threshold boundary semantics | Boundary conditions wrong (< vs <=) |

**Pattern:** Numeric data from surveys and API responses is often strings, `None`, or `NaN`. Code that calls `float()` without try/except or `math.isfinite()` guards crashes or produces invalid DB values.

**Detective signal:** `rcfa_analytics` rows where numeric columns contain `NaN` or extreme values. Check `co2_partial_pressure`, `h2s_partial_pressure`, `flow_velocity_v_over_ve_ratio` for outliers.

## Category 4: Product Verification Guard (2 recent fixes)

| Commit | Fix | Root Cause |
|--------|-----|-----------|
| `c6151987` | Add product verification guard for RAG answers | RAG could recommend non-existent product codes |
| `cedbca36` | Fix one-shot cap to re-fire for each new unverified code | Guard only fired once, missing subsequent bad codes |

**Pattern:** The LLM can hallucinate product codes that don't exist in the canonical catalog. The product guard validates codes against `ProductOverviews/product_data.json` but had logic bugs in its firing mechanism.

**Detective signal:** `product_recommendations.product_code` values not found in `product_data.json` or `clean_product_recommendations.json`.

## Category 5: Frontend Race Conditions (2 recent fixes)

| Commit | Fix | Root Cause |
|--------|-----|-----------|
| `77dfb462` | sidebarStore delete-during-load race | Concurrent sidebar operations corrupted state |
| `b3863bef` | Reset to page 1 after conversation delete | Pagination state stale after delete |

**Pattern:** React state management issues when async operations (load, delete) overlap. The sidebar store is the primary failure point.

## Category 6: GPT5 Fallback Pattern

When the primary LLM (Azure OpenAI) times out or fails, the system falls back to an alternative. This is tracked as `gpt5_fallback` in `conversation_messages.metadata`.

**How it works:**
1. Primary LLM call times out (threshold varies by tier)
2. System triggers fallback via `TieredLLMClient` (`src/core/llm/tiered_client.py`)
3. Fallback response generated with potentially different quality
4. `metadata.gpt5_fallback` set on the response message

**Detective query:**
```sql
SELECT COUNT(*), DATE(message_timestamp) as day
FROM conversation_messages
WHERE metadata::text LIKE '%gpt5_fallback%'
GROUP BY DATE(message_timestamp)
ORDER BY day DESC LIMIT 14;
```

**Code path:** `src/core/llm/tiered_client.py` -> fallback tier selection -> `src/core/llm/router.py`

## Category 7: Session/Message Linkage Gap

~50% of `conversation_messages.session_id` values do NOT have a matching `chat_conversations.conversation_id`.

**Unresolved — detective should investigate.** `conversation_messages` rows are written before `chat_conversations` metadata is upserted (`src/api/routers/chat.py:789`, `:1069`). No foreign key exists between the two tables.

**Possible causes:** The 49% orphan rate could be a persistence bug (the later upsert silently failing), a race condition, or a legitimate schema gap where some code paths skip conversation registration. Detective should trace the write path for orphaned `session_id` values to determine root cause.

**Impact:** Session-based analytics undercount. Detective agents must use `conversation_messages.session_id` for grouping first, then verify whether the corresponding `chat_conversations` row was skipped or failed to persist.

**Detective query:**
```sql
-- Linkage ratio
SELECT
  (SELECT COUNT(DISTINCT session_id) FROM conversation_messages) as msg_sessions,
  (SELECT COUNT(*) FROM chat_conversations) as conv_sessions,
  (SELECT COUNT(DISTINCT cm.session_id) FROM conversation_messages cm
   WHERE NOT EXISTS (SELECT 1 FROM chat_conversations cc
                     WHERE cc.conversation_id = cm.session_id)) as orphaned_sessions;
```

## Category 8: Feedback Sparsity

Most chat interactions receive no user feedback. The `feedback_summary` table is sparse — only a fraction of conversations have thumbs up/down or ratings. Negative feedback (`is_helpful = false`) is the highest-value signal but rare.

**Detective approach:** When investigating a bad response, don't rely solely on feedback_summary. Cross-reference with:
- `conversation_messages.latency_ms` (slow = bad experience)
- `enhanced_rag_metrics.confidence_score` — `enhanced_rag_metrics` is currently empty despite active write paths (see [error-signals.md](error-signals.md)); if rows begin appearing, cross-reference low scores
- `rcfa_analytics.data_completeness_score` (low = incomplete input)

## Recent Fix Branch Categories

| Branch Pattern | Count | Category |
|----------------|-------|----------|
| `fix/*` or `Fix *` | 13 | Direct bug fixes |
| `claude/fix-*` | 4 | AI-assisted fixes |
| `feat(pilot-fix-*)` | 1 | Pilot program fixes |
| `rcfa-export-fixes` | 1 | Report generation |

## Cross-References

- Architecture overview: [architecture.md](architecture.md)
- DB schema for signal queries: [db-schema-map.md](db-schema-map.md)
- Error signal catalog with live counts: [error-signals.md](error-signals.md)
- Product validation: [product-catalog-reference.md](product-catalog-reference.md)

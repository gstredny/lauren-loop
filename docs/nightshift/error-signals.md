# Error Signals Catalog

Where errors surface in the AskGeorge database, what values mean "bad," and how to query them.
Data snapshot: **2026-03-27**. Refresh counts periodically — they drift.

## Table Row Counts (baseline context)

| Table | Rows | Notes |
|-------|------|-------|
| conversation_messages | 7,041 | All chat messages |
| chat_conversations | 4,936 | Session records |
| rcfa_analytics | 790 | RCFA analyses |
| product_recommendations | 3,681 | Product recs (normalized) |
| analysis_sessions | 1,453 | RCFA session state |
| failure_analyses | 1,352 | Completed RCFA reports |
| chat_analytics_metrics | 293 | Per-event metrics |
| product_recommendation_analytics | 116 | Product search metrics |
| conversation_memory | 91 | Cross-session memory |
| feedback_summary | 27 | User feedback (sparse!) |
| enhanced_rag_metrics | 0 | Active write paths exist; empty table is an investigation target |
| timeout_analytics | 0 | Insert code exists; likely unwired monitoring path |
| rag_query_analytics | 0 | Active best-effort update path exists; empty table is an investigation target |

**Note:** `enhanced_rag_metrics` and `rag_query_analytics` have live write paths in `src/api/routers/feedback.py` and/or `src/services/analytics/rag_analytics_service.py`, while `timeout_analytics` has insert code in `src/services/analytics/rag_analytics_service.py` but no confirmed live callers. Treat zero rows here as an investigation target, not proof the tables are intentionally unused.

---

## Signal 1: GPT5 Fallback

| Property | Value |
|----------|-------|
| Table | `conversation_messages` |
| Column | `metadata` (JSON) |
| Bad value | JSON contains key `gpt5_fallback` |
| Count | **1,888** (26.8% of all messages) |
| Last seen | 2026-02-24 |
| Code path | `src/core/llm/tiered_client.py` -> fallback tier -> `src/core/llm/router.py` |

**Meaning:** The primary LLM failed or timed out, and the system used a fallback model. High frequency suggests a period of LLM instability. No new fallbacks since Feb 2026 (may indicate the issue was resolved or the flag stopped being set).

```sql
-- Count
SELECT COUNT(*) FROM conversation_messages
WHERE metadata::text LIKE '%gpt5_fallback%';

-- Recent samples
SELECT id, session_id, model_used, latency_ms, message_timestamp,
       metadata->>'gpt5_fallback' as fallback_val
FROM conversation_messages
WHERE metadata::text LIKE '%gpt5_fallback%'
ORDER BY message_timestamp DESC LIMIT 10;

-- Daily trend
SELECT DATE(message_timestamp) as day, COUNT(*) as fallbacks
FROM conversation_messages
WHERE metadata::text LIKE '%gpt5_fallback%'
GROUP BY DATE(message_timestamp)
ORDER BY day DESC LIMIT 30;
```

**Sample data (most recent 3):**

| id | session_id | model_used | latency_ms | timestamp |
|----|-----------|------------|-----------|-----------|
| 5933 | conv-1771935643461-cd0ep5j6x | NULL | NULL | 2026-02-24 12:21 |
| 5930 | test-browser-500 | NULL | NULL | 2026-02-24 12:20 |
| 5927 | 18676462-0462-424d-892c-5bc87b940c79 | NULL | NULL | 2026-02-24 12:19 |

**Caveat:** Many fallback rows have NULL model_used and latency_ms — these fields weren't populated during the fallback path. The `metadata` JSON itself may contain richer error detail.

---

## Signal 2: Chat Analytics Failures

| Property | Value |
|----------|-------|
| Table | `chat_analytics_metrics` |
| Column | `success` |
| Bad value | `false` |
| Count | **28** (9.6% of 293 total) |
| Last seen | 2026-02-06 |
| Code path | Various handlers -> `ConversationManager` -> analytics persistence |

**Meaning:** A chat handler operation failed and was logged. Most are test/validation errors, not production user-facing failures.

```sql
SELECT id, metric_type, metric_name, handler_name, error_message, timestamp
FROM chat_analytics_metrics
WHERE success = false
ORDER BY timestamp DESC LIMIT 10;
```

**Sample data:**

| id | metric_type | handler_name | error_message | timestamp |
|----|------------|--------------|---------------|-----------|
| 282 | error | NULL | test_error | 2026-02-06 22:13 |
| 280 | error | input_handler | validation_error | 2026-02-06 22:12 |
| 279 | error | test_handler | test_error | 2026-02-06 22:12 |

**Caveat:** Most failures are `test_handler` / `test_error` entries from automated testing. Filter these out for real user-facing errors: `WHERE handler_name NOT LIKE 'test%'`.

---

## Signal 3: Product Recommendation Failures

| Property | Value |
|----------|-------|
| Table | `product_recommendation_analytics` |
| Column | `success` |
| Bad value | `false` |
| Count | **2** (1.7% of 116 total) |
| Last seen | 2025-09-26 |
| Code path | `src/services/ai_recommender_service.py` -> Pydantic validation |

**Meaning:** The AI recommender service returned a response that failed Pydantic validation (`AIRecommendationResponse.filters_applied` missing).

```sql
SELECT id, search_type, source, error_message, timestamp
FROM product_recommendation_analytics
WHERE success = false
ORDER BY timestamp DESC LIMIT 10;
```

**Sample data:**

| id | search_type | source | error_message | timestamp |
|----|------------|--------|---------------|-----------|
| 50 | ai_recommendation_error | ai_recommender_service | `1 validation error for AIRecommendationResponse filters_applied Field required` | 2025-09-26 |
| 48 | ai_recommendation_error | ai_recommender_service | (same) | 2025-09-26 |

**Status:** Likely fixed — only 2 occurrences, both from Sep 2025.

---

## Signal 4: Negative User Feedback

| Property | Value |
|----------|-------|
| Table | `feedback_summary` |
| Column | `is_helpful` |
| Bad value | `false` |
| Count | **12** (44.4% of 27 total feedback entries) |
| Last seen | 2026-02-27 |
| Code path | `src/api/routers/feedback.py` -> DB persistence |

**Feedback breakdown:** 1 positive, 12 negative, 14 NULL. Extremely sparse — only 27 total feedback entries across the entire system.

```sql
-- Negative feedback with context
SELECT id, feedback_type, feedback_category, feedback_text,
       LEFT(query, 100) as query_preview, LEFT(response, 100) as response_preview,
       created_at
FROM feedback_summary
WHERE is_helpful = false
ORDER BY created_at DESC LIMIT 10;

-- Overall feedback health
SELECT
  COUNT(*) as total,
  SUM(CASE WHEN is_helpful = true THEN 1 ELSE 0 END) as positive,
  SUM(CASE WHEN is_helpful = false THEN 1 ELSE 0 END) as negative
FROM feedback_summary;
```

**Caveat:** All negative feedback entries have `feedback_type = 'quick'` with NULL category, accuracy, helpfulness, clarity, and completeness fields. Users clicked thumbs-down but didn't provide detailed feedback. The query and response text are the only context available.

---

## Signal 5: High Latency Responses (>30s)

| Property | Value |
|----------|-------|
| Table | `conversation_messages` |
| Column | `latency_ms` |
| Bad value | `> 30000` |
| Count | **158** (2.2% of all messages) |
| Last seen | **2026-03-27** (today — active issue) |
| Code path | Any LLM call path, especially multi-turn agentic mode |

**Meaning:** Response took over 30 seconds. Correlated with multi-model calls (model_used contains multiple model names separated by commas, indicating retries or multi-step processing).

```sql
-- Count by time window
SELECT
  COUNT(*) FILTER (WHERE message_timestamp > NOW() - INTERVAL '24 hours') as last_24h,
  COUNT(*) FILTER (WHERE message_timestamp > NOW() - INTERVAL '7 days') as last_7d,
  COUNT(*) FILTER (WHERE message_timestamp > NOW() - INTERVAL '30 days') as last_30d,
  COUNT(*) as all_time
FROM conversation_messages WHERE latency_ms > 30000;

-- Worst offenders
SELECT id, session_id, model_used, latency_ms, message_timestamp
FROM conversation_messages
WHERE latency_ms > 30000
ORDER BY latency_ms DESC LIMIT 10;
```

**Sample data (most recent):**

| id | model_used | latency_ms | timestamp |
|----|-----------|-----------|-----------|
| 7057 | claude-sonnet-4-6, claude-sonnet-4-6 | 30,322 | 2026-03-27 19:40 |
| 7031 | claude-sonnet-4-6 x3 | 54,724 | 2026-03-27 10:45 |
| 6991 | claude-sonnet-4-6 x2 | 39,954 | 2026-03-26 14:53 |

**Pattern:** Multi-model entries (comma-separated model names) indicate the agentic mode is making multiple LLM calls per user query. The latency compounds.

---

## Signal 6: RCFA Analysis Failures

| Property | Value |
|----------|-------|
| Table | `rcfa_analytics` |
| Column | `success` |
| Bad value | `false` |
| Count | **25** (3.2% of 790 total) |
| Last seen | 2025-10-27 |
| Code path | `src/services/analysis/comprehensive_rcfa_analyzer.py` |

**Error categories:**

| Error Pattern | Count | Root Cause |
|--------------|-------|-----------|
| `could not convert string to float: ''` | 2 | Empty string in numeric survey field |
| `unexpected keyword argument 'manual_context'` | ~20 | API signature change (resolved) |
| Other | 3 | Various |

```sql
-- RCFA failures by error type
SELECT LEFT(error_message, 80) as error_pattern, COUNT(*) as occurrences,
       MIN(timestamp) as first_seen, MAX(timestamp) as last_seen
FROM rcfa_analytics
WHERE success = false
GROUP BY LEFT(error_message, 80)
ORDER BY occurrences DESC;
```

**Status:** No failures since Oct 2025 — the `manual_context` API change was fixed, and float coercion guards were added.

---

## Signal 7: Failed Analysis Sessions

| Property | Value |
|----------|-------|
| Table | `analysis_sessions` |
| Column | `status` |
| Bad value | `'failed'` |
| Count | **0** |
| Code path | `src/api/routers/analysis.py` -> session state machine |

```sql
SELECT id, session_id, status, current_step, error_message, created_at
FROM analysis_sessions
WHERE status = 'failed'
ORDER BY created_at DESC LIMIT 10;
```

**Note:** Zero failed sessions. Failures may be recorded in `rcfa_analytics.success = false` instead. The `analysis_sessions` table tracks the session state machine, while `rcfa_analytics` tracks the analysis outcome. Check both.

---

## Signal 8: Session/Message Linkage Gap

| Property | Value |
|----------|-------|
| Metric | Messages with no matching chat_conversations record |
| Count | **3,412 orphaned messages** (48.5% of 7,041) |
| Linked sessions | 962 out of 1,900 unique message session_ids |

**Unresolved — detective should investigate.** `conversation_messages` rows are written before `chat_conversations` metadata is upserted (`src/api/routers/chat.py:789`, `:1069`). No foreign key exists between the two tables.

```sql
-- Linkage summary
SELECT
  (SELECT COUNT(*) FROM chat_conversations) as conversation_records,
  (SELECT COUNT(DISTINCT session_id) FROM conversation_messages) as unique_msg_sessions,
  (SELECT COUNT(DISTINCT cm.session_id) FROM conversation_messages cm
   JOIN chat_conversations cc ON cm.session_id = cc.conversation_id) as linked_sessions,
  (SELECT COUNT(*) FROM conversation_messages cm
   WHERE NOT EXISTS (SELECT 1 FROM chat_conversations cc
                     WHERE cc.conversation_id = cm.session_id)) as orphaned_messages;
```

**Possible causes:** The 49% orphan rate could be a persistence bug (the later upsert silently failing), a race condition, or a legitimate schema gap where some code paths skip conversation registration. The `chat_conversations` table (4,936 rows) has far more records than unique message sessions (1,900), suggesting many empty sessions were created but never received messages.

**Impact for detectives:** When analyzing a conversation, always start from `conversation_messages.session_id`, don't assume a matching `chat_conversations` record exists, and trace orphaned `session_id` values through the write path to determine root cause.

---

## Signal 9: Silent Write Failures — Tables with Active Write Paths but Zero Rows

Tables with zero rows despite active or likely-active write paths are detective targets, not safe-to-ignore “unused schema.”

| Table | Rows | Write path status | Verified code path | Detective interpretation |
|-------|------|-------------------|--------------------|--------------------------|
| `enhanced_rag_metrics` | 0 | Active writers exist | `src/api/routers/feedback.py:140`, `src/services/analytics/rag_analytics_service.py:621` | BUG candidate: inserts and feedback updates exist, but the table is empty |
| `rag_query_analytics` | 0 | Active best-effort update exists | `src/api/routers/feedback.py:165` | BUG candidate: update path exists, but the table is empty |
| `timeout_analytics` | 0 | Insert code exists; no live callers confirmed | `src/services/analytics/rag_analytics_service.py:690` | Likely unwired monitoring integration; lower-confidence investigation target |

---

## Quick Reference: Error Signal Priority

Priority ranked by: active occurrence > stale, then by user-visible impact. Stale signals (no new rows in 30+ days) are downgraded regardless of total count.

| Priority | Signal | Active? | Volume |
|----------|--------|---------|--------|
| HIGH | High latency (>30s) | Yes (today) | 158 total, active |
| MEDIUM | GPT5 fallback | Stale (Feb 2026) | 1,888 total |
| MEDIUM | RCFA failures | Stale (Oct 2025) | 25 total |
| MEDIUM | Negative feedback | Sparse | 12 of 27 |
| MEDIUM | Silent write failures | Active / likely unwired | 3 empty analytics tables |
| LOW | Chat analytics failures | Stale (Feb 2026) | 28 (mostly test) |
| LOW | Product rec failures | Stale (Sep 2025) | 2 |
| INFO | Session linkage gap | Unresolved | ~49% orphaned |

## Cross-References

- DB schema details: [db-schema-map.md](db-schema-map.md)
- Known failure patterns: [known-patterns.md](known-patterns.md)
- Architecture (error points): [architecture.md](architecture.md)

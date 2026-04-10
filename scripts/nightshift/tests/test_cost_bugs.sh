#!/usr/bin/env bash
# test_cost_bugs.sh — Tests for the Bug 3 + Bug 5 cascade fix.
# Validates: status-line-resilient token extraction, 4-token cache pricing,
# fallback isolation from runaway detection, and CSV column structure.
#
# Usage: bash scripts/nightshift/tests/test_cost_bugs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the nightshift libraries
source "$NS_DIR/nightshift.conf"
source "$NS_DIR/lib/cost-tracker.sh"
source "$NS_DIR/lib/agent-runner.sh"

# Test harness
PASS=0 FAIL=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

echo "=== test_cost_bugs.sh ==="
echo ""

# ── Test 1: agent_extract_tokens parses file with status line prefix ─────────
(
    f="$TMP_DIR/with-prefix.json"
    # Simulate real Claude CLI output: status line + blank line + JSON
    printf '✓ Anthropic API / Max\n\n' > "$f"
    printf '{"type":"result","usage":{"input_tokens":100,"cache_creation_input_tokens":5000,"cache_read_input_tokens":3000,"output_tokens":50}}\n' >> "$f"

    result=$(agent_extract_tokens "$f" 2>/dev/null)
    [[ "$result" == "100 5000 3000 50" ]]
) && pass "1. agent_extract_tokens — parses file with status line prefix" \
  || fail "1. agent_extract_tokens — parses file with status line prefix" "got '$result'"

# ── Test 2: agent_extract_tokens on empty file returns 0 0 0 0 ──────────────
(
    f="$TMP_DIR/empty.json"
    touch "$f"
    result=$(agent_extract_tokens "$f" 2>/dev/null)
    [[ "$result" == "0 0 0 0" ]]
) && pass "2. agent_extract_tokens — empty file returns 0 0 0 0" \
  || fail "2. agent_extract_tokens — empty file returns 0 0 0 0" "got '$result'"

# ── Test 3: agent_extract_tokens on missing file returns 0 0 0 0 ────────────
(
    result=$(agent_extract_tokens "$TMP_DIR/nonexistent.json" 2>/dev/null)
    [[ "$result" == "0 0 0 0" ]]
) && pass "3. agent_extract_tokens — missing file returns 0 0 0 0" \
  || fail "3. agent_extract_tokens — missing file returns 0 0 0 0" "got '$result'"

# ── Test 4: agent_extract_tokens on file with no JSON returns 0 0 0 0 ───────
(
    f="$TMP_DIR/no-json.txt"
    echo "This is not JSON at all" > "$f"
    result=$(agent_extract_tokens "$f" 2>/dev/null)
    [[ "$result" == "0 0 0 0" ]]
) && pass "4. agent_extract_tokens — non-JSON file returns 0 0 0 0" \
  || fail "4. agent_extract_tokens — non-JSON file returns 0 0 0 0" "got '$result'"

# ── Test 5: agent_extract_tokens handles trailing content after JSON ─────────
(
    f="$TMP_DIR/with-trailing.json"
    printf '✓ Anthropic API / Max\n\n' > "$f"
    printf '{"type":"result","usage":{"input_tokens":200,"cache_creation_input_tokens":8000,"cache_read_input_tokens":4000,"output_tokens":75}}\n' >> "$f"
    printf 'WARNING: deprecated flag --foo will be removed in v3.0\n' >> "$f"

    result=$(agent_extract_tokens "$f" 2>/dev/null)
    [[ "$result" == "200 8000 4000 75" ]]
) && pass "5. agent_extract_tokens — handles trailing content after JSON" \
  || fail "5. agent_extract_tokens — handles trailing content after JSON" "got '$result'"

# ── Test 6: cost_record_call with real tokens → cost_source is "parsed" ─────
(
    export NIGHTSHIFT_COST_STATE_FILE="$TMP_DIR/state-parsed.json"
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/csv-parsed.csv"
    cost_init "test-parsed" 2>/dev/null

    cost_record_call "det1" "claude-sonnet-4-6" "test.md" 1000 500 2000 3000 >/dev/null 2>&1

    source_val=$(jq -r '.calls[0].cost_source' "$NIGHTSHIFT_COST_STATE_FILE")
    [[ "$source_val" == "parsed" ]]
) && pass "6. cost_record_call — real tokens → cost_source is 'parsed'" \
  || fail "6. cost_record_call — real tokens → cost_source is 'parsed'" "got '$source_val'"

# ── Test 7: cost_record_call with zero tokens → cost_source is "fallback" ───
(
    export NIGHTSHIFT_COST_STATE_FILE="$TMP_DIR/state-fallback.json"
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/csv-fallback.csv"
    cost_init "test-fallback" 2>/dev/null

    cost_record_call "det1" "claude-sonnet-4-6" "test.md" 0 0 0 0 >/dev/null 2>&1

    source_val=$(jq -r '.calls[0].cost_source' "$NIGHTSHIFT_COST_STATE_FILE")
    cost_val=$(jq -r '.calls[0].cost_usd' "$NIGHTSHIFT_COST_STATE_FILE")
    [[ "$source_val" == "fallback" ]] && [[ "$cost_val" == "25" ]]
) && pass "7. cost_record_call — zero tokens → cost_source 'fallback', cost \$25" \
  || fail "7. cost_record_call — zero tokens → cost_source 'fallback', cost \$25" "source=$source_val cost=$cost_val"

# ── Test 8: 3 consecutive fallbacks do NOT trigger runaway ──────────────────
(
    export NIGHTSHIFT_COST_STATE_FILE="$TMP_DIR/state-no-runaway.json"
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/csv-no-runaway.csv"
    cost_init "test-no-runaway" 2>/dev/null

    cost_record_call "det1" "claude-sonnet-4-6" "test.md" 0 0 0 0 >/dev/null 2>&1
    cost_record_call "det2" "claude-sonnet-4-6" "test.md" 0 0 0 0 >/dev/null 2>&1
    cost_record_call "det3" "claude-sonnet-4-6" "test.md" 0 0 0 0 >/dev/null 2>&1

    consecutive=$(jq -r '.consecutive_high_cost_count' "$NIGHTSHIFT_COST_STATE_FILE")
    cost_check_runaway 2>/dev/null
    runaway_rc=$?

    [[ "$consecutive" == "0" ]] && [[ "$runaway_rc" == "0" ]]
) && pass "8. 3 consecutive fallbacks — runaway NOT triggered (consecutive=0)" \
  || fail "8. 3 consecutive fallbacks — runaway NOT triggered" "consecutive=$consecutive rc=$runaway_rc"

# ── Test 9: 3 consecutive parsed high-cost calls DO trigger runaway ─────────
(
    export NIGHTSHIFT_COST_STATE_FILE="$TMP_DIR/state-runaway.json"
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/csv-runaway.csv"
    cost_init "test-runaway" 2>/dev/null

    # Each call: 10M input tokens at $3/M = $30 > $15 threshold
    cost_record_call "det1" "claude-sonnet-4-6" "test.md" 10000000 100000 0 0 >/dev/null 2>&1
    cost_record_call "det2" "claude-sonnet-4-6" "test.md" 10000000 100000 0 0 >/dev/null 2>&1
    cost_record_call "det3" "claude-sonnet-4-6" "test.md" 10000000 100000 0 0 >/dev/null 2>&1

    consecutive=$(jq -r '.consecutive_high_cost_count' "$NIGHTSHIFT_COST_STATE_FILE")
    cost_check_runaway 2>/dev/null
    runaway_rc=$?

    [[ "$consecutive" == "3" ]] && [[ "$runaway_rc" == "1" ]]
) && pass "9. 3 consecutive parsed high-cost calls — runaway triggered" \
  || fail "9. 3 consecutive parsed high-cost calls — runaway triggered" "consecutive=$consecutive rc=$runaway_rc"

# ── Test 10: Cache pricing — verify cost matches hand calculation ───────────
(
    export NIGHTSHIFT_COST_STATE_FILE="$TMP_DIR/state-cache.json"
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/csv-cache.csv"
    cost_init "test-cache" 2>/dev/null

    # Sonnet pricing: input=$3, output=$15, cache_write=$3.75, cache_read=$0.30
    # 1000 input + 500 output + 2000 cache_write + 10000 cache_read
    # = (1000/1M * 3) + (500/1M * 15) + (2000/1M * 3.75) + (10000/1M * 0.30)
    # = 0.003 + 0.0075 + 0.0075 + 0.003
    # = 0.021
    cost=$(cost_record_call "det1" "claude-sonnet-4-6" "test.md" 1000 500 2000 10000 2>/dev/null)

    [[ "$cost" == "0.0210" ]]
) && pass "10. Cache pricing — cost matches hand calculation (\$0.0210)" \
  || fail "10. Cache pricing — cost matches hand calculation" "got $cost, expected 0.0210"

# ── Test 11: CSV has correct column count (11 columns) ─────────────────────
(
    export NIGHTSHIFT_COST_STATE_FILE="$TMP_DIR/state-csv.json"
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/csv-cols.csv"
    cost_init "test-csv" 2>/dev/null

    cost_record_call "det1" "claude-sonnet-4-6" "test.md" 100 50 200 300 >/dev/null 2>&1

    header_cols=$(head -1 "$NIGHTSHIFT_COST_CSV" | awk -F',' '{print NF}')
    data_cols=$(tail -1 "$NIGHTSHIFT_COST_CSV" | awk -F',' '{print NF}')

    [[ "$header_cols" == "11" ]] && [[ "$data_cols" == "11" ]]
) && pass "11. CSV — header and data rows have 11 columns" \
  || fail "11. CSV — header and data rows have 11 columns" "header=$header_cols data=$data_cols"

# ── Test 12: cost_weekly_summary on missing CSV returns zero summary ────────
(
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/missing-cost-history.csv"

    summary=$(cost_weekly_summary)
    [[ "$summary" == $'date,cost_usd\ntotal,0.0000' ]]
) && pass "12. cost_weekly_summary — missing CSV returns header plus zero total" \
  || fail "12. cost_weekly_summary — missing CSV returns header plus zero total" "got '$summary'"

# ── Test 13: cost_weekly_summary aggregates a single day correctly ──────────
(
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/cost-single-day.csv"

    cat > "$NIGHTSHIFT_COST_CSV" <<'EOF'
timestamp,agent,model,playbook,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,cost_usd,cost_source,cumulative_usd
2026-03-30T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,1.2500,parsed,1.2500
2026-03-30T02:00:00-0500,det2,claude-sonnet-4-6,b.md,1,1,0,0,2.5000,parsed,3.7500
2026-03-30T03:00:00-0500,det3,claude-sonnet-4-6,c.md,1,1,0,0,3.0000,parsed,6.7500
EOF

    summary=$(cost_weekly_summary)
    line_count=$(printf '%s\n' "$summary" | wc -l | tr -d ' ')

    grep -q '^date,cost_usd$' <<<"$summary"
    grep -q '^2026-03-30,6.7500$' <<<"$summary"
    grep -q '^total,6.7500$' <<<"$summary"
    [[ "$line_count" == "3" ]]
) && pass "13. cost_weekly_summary — single-day CSV aggregates correctly" \
  || fail "13. cost_weekly_summary — single-day CSV aggregates correctly" "summary was '$summary'"

# ── Test 14: cost_weekly_summary keeps only the 7 most recent days ──────────
(
    export NIGHTSHIFT_COST_CSV="$TMP_DIR/cost-ten-days.csv"

    cat > "$NIGHTSHIFT_COST_CSV" <<'EOF'
timestamp,agent,model,playbook,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,cost_usd,cost_source,cumulative_usd
2026-04-01T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,1.0000,parsed,1.0000
2026-04-02T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,2.0000,parsed,3.0000
2026-04-03T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,3.0000,parsed,6.0000
2026-04-04T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,4.0000,parsed,10.0000
2026-04-05T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,5.0000,parsed,15.0000
2026-04-06T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,6.0000,parsed,21.0000
2026-04-07T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,7.0000,parsed,28.0000
2026-04-08T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,8.0000,parsed,36.0000
2026-04-09T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,9.0000,parsed,45.0000
2026-04-10T01:00:00-0500,det1,claude-sonnet-4-6,a.md,1,1,0,0,10.0000,parsed,55.0000
EOF

    summary=$(cost_weekly_summary)
    line_count=$(printf '%s\n' "$summary" | wc -l | tr -d ' ')

    grep -q '^2026-04-10,10.0000$' <<<"$summary"
    grep -q '^2026-04-04,4.0000$' <<<"$summary"
    ! grep -q '^2026-04-03,3.0000$' <<<"$summary"
    ! grep -q '^2026-04-02,2.0000$' <<<"$summary"
    ! grep -q '^2026-04-01,1.0000$' <<<"$summary"
    grep -q '^total,49.0000$' <<<"$summary"
    [[ "$line_count" == "9" ]]
) && pass "14. cost_weekly_summary — truncates to the 7 most recent days" \
  || fail "14. cost_weekly_summary — truncates to the 7 most recent days" "summary was '$summary'"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed (14 tests) ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

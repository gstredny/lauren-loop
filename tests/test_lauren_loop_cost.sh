#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-cost.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() {
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "${GREEN}PASS${NC}: $1"
}

fail() {
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "${RED}FAIL${NC}: $1"
    [ -n "${2:-}" ] && echo "  Detail: $2"
}

# Source utils (provides all cost functions + constants)
SCRIPT_DIR="$REPO_ROOT"
MODEL="opus"
LAUREN_LOOP_CODEX_MODEL="gpt-5.4"
source "$REPO_ROOT/lib/lauren-loop-utils.sh"

# ============================================================
# Test 1: _extract_claude_tokens
# ============================================================
(
    log_file="$TMP_ROOT/stream-json.log"
    # Create a fixture with known token counts — two messages
    cat > "$log_file" <<'EOF'
{"type":"assistant","message":{"id":"msg_001","usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":50,"output_tokens":300}}}
{"type":"assistant","message":{"id":"msg_001","usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":50,"output_tokens":350}}}
{"type":"assistant","message":{"id":"msg_002","usage":{"input_tokens":500,"cache_creation_input_tokens":100,"cache_read_input_tokens":25,"output_tokens":150}}}
EOF
    # msg_001: last row wins (1000 200 50 350)
    # msg_002: (500 100 25 150)
    # Total: 1500 300 75 500
    result=$(_extract_claude_tokens "$log_file")
    [[ "$result" == "1500 300 75 500" ]]
) && pass "1. _extract_claude_tokens — deduplicates by message.id and sums" \
  || fail "1. _extract_claude_tokens — deduplicates by message.id and sums"

(
    result=$(_extract_claude_tokens "/nonexistent/file")
    [[ "$result" == "0 0 0 0" ]]
) && pass "2. _extract_claude_tokens — missing file returns zeros" \
  || fail "2. _extract_claude_tokens — missing file returns zeros"

# ============================================================
# Test 3: _calculate_cost
# ============================================================
(
    # Claude: (1000 * 5.00 + 500 * 6.25 + 200 * 0.50 + 300 * 25.00) / 1000000
    # = (5000 + 3125 + 100 + 7500) / 1000000 = 15725 / 1000000 = 0.0157
    result=$(_calculate_cost "claude" 1000 500 200 300)
    [[ "$result" == "0.0157" ]]
) && pass "3. _calculate_cost — claude engine computes correct cost" \
  || fail "3. _calculate_cost — claude engine computes correct cost" "got: $result"

(
    # Codex: (1000 * 2.50 + 500 * 15.00) / 1000000 = (2500 + 7500) / 1000000 = 0.0100
    result=$(_calculate_cost "codex" 1000 0 0 500)
    [[ "$result" == "0.0100" ]]
) && pass "4. _calculate_cost — codex engine computes correct cost" \
  || fail "4. _calculate_cost — codex engine computes correct cost"

(
    result=$(_calculate_cost "claude" 0 0 0 0)
    [[ "$result" == "0" || "$result" == "0.0000" ]]
) && pass "5. _calculate_cost — zero tokens returns zero cost" \
  || fail "5. _calculate_cost — zero tokens returns zero cost"

# ============================================================
# Test 6: _append_cost_row writes correct CSV
# ============================================================
(
    SLUG="test-task"
    cost_csv="$TMP_ROOT/append-test-cost.csv"
    log_file="$TMP_ROOT/append-test.log"
    # Create a fixture log with known tokens
    cat > "$log_file" <<'EOF'
{"type":"assistant","message":{"id":"msg_001","usage":{"input_tokens":5000,"cache_creation_input_tokens":1000,"cache_read_input_tokens":500,"output_tokens":2000}}}
EOF
    start_ts=$(date +%s)
    sleep 1
    _append_cost_row "$cost_csv" "executor" "claude" "$start_ts" "0" "$log_file"

    # Verify header
    header=$(head -1 "$cost_csv")
    [[ "$header" == "$COST_CSV_HEADER" ]]

    # Verify data row has 14 columns
    data_row=$(tail -1 "$cost_csv")
    col_count=$(echo "$data_row" | awk -F',' '{ print NF }')
    [[ "$col_count" -eq 14 ]]

    # Verify role is "executor"
    role=$(echo "$data_row" | awk -F',' '{ print $3 }')
    [[ "$role" == "executor" ]]

    # Verify engine is "claude"
    engine=$(echo "$data_row" | awk -F',' '{ print $4 }')
    [[ "$engine" == "claude" ]]

    # Verify model is "opus"
    model=$(echo "$data_row" | awk -F',' '{ print $5 }')
    [[ "$model" == "opus" ]]

    # Verify status is "completed"
    status=$(echo "$data_row" | awk -F',' '{ print $14 }')
    [[ "$status" == "completed" ]]
) && pass "6. _append_cost_row — writes header + correct 14-column data row" \
  || fail "6. _append_cost_row — writes header + correct 14-column data row"

# ============================================================
# Test 7: _print_cost_summary with explicit CSV path
# ============================================================
(
    cost_csv="$TMP_ROOT/summary-test-cost.csv"
    SLUG="summary-test"
    printf '%s\n' "$COST_CSV_HEADER" > "$cost_csv"
    printf '2026-03-09T00:00:00+0000,summary-test,executor,claude,opus,n/a,5000,1000,500,2000,0.0837,60,0,completed\n' >> "$cost_csv"
    printf '2026-03-09T00:01:00+0000,summary-test,reviewer-r1,claude,opus,n/a,3000,500,200,1000,0.0431,30,0,completed\n' >> "$cost_csv"

    output=$(_print_cost_summary "$cost_csv" 2>&1)
    echo "$output" | grep -q 'Cost Summary'
    echo "$output" | grep -q 'executor'
    echo "$output" | grep -q 'Total:'
) && pass "7. _print_cost_summary — explicit CSV path prints formatted table" \
  || fail "7. _print_cost_summary — explicit CSV path prints formatted table"

# ============================================================
# Test 8: _cost_csv_has_data_row
# ============================================================
(
    csv_with_data="$TMP_ROOT/has-data.csv"
    csv_header_only="$TMP_ROOT/header-only.csv"

    printf '%s\n' "$COST_CSV_HEADER" > "$csv_with_data"
    printf '2026-03-09T00:00:00+0000,test,executor,claude,opus,n/a,1,0,0,1,0.0001,1,0,completed\n' >> "$csv_with_data"
    printf '%s\n' "$COST_CSV_HEADER" > "$csv_header_only"

    _cost_csv_has_data_row "$csv_with_data"
    ! _cost_csv_has_data_row "$csv_header_only"
    ! _cost_csv_has_data_row "/nonexistent/file.csv"
) && pass "8. _cost_csv_has_data_row — detects data, header-only, and missing" \
  || fail "8. _cost_csv_has_data_row — detects data, header-only, and missing"

# ============================================================
# Test 9: _ensure_cost_csv_header migration from legacy 13-col
# ============================================================
(
    legacy_csv="$TMP_ROOT/legacy-migration.csv"
    printf '%s\n' "$LEGACY_COST_CSV_HEADER" > "$legacy_csv"
    printf '2026-03-09T00:00:00+0000,test,executor,claude,opus,5000,1000,500,2000,0.0837,60,0,completed\n' >> "$legacy_csv"

    _ensure_cost_csv_header "$legacy_csv"

    # Verify header is now 14-col
    header=$(head -1 "$legacy_csv")
    [[ "$header" == "$COST_CSV_HEADER" ]]

    # Verify data row now has 14 columns with 'unknown' reasoning_effort
    data_row=$(tail -1 "$legacy_csv")
    col_count=$(echo "$data_row" | awk -F',' '{ print NF }')
    [[ "$col_count" -eq 14 ]]

    reasoning=$(echo "$data_row" | awk -F',' '{ print $6 }')
    [[ "$reasoning" == "unknown" ]]
) && pass "9. _ensure_cost_csv_header — migrates legacy 13-col to 14-col" \
  || fail "9. _ensure_cost_csv_header — migrates legacy 13-col to 14-col"

# ============================================================
# Test 10: _ensure_cost_csv_header creates new file
# ============================================================
(
    new_csv="$TMP_ROOT/new-cost.csv"
    [[ ! -f "$new_csv" ]]
    _ensure_cost_csv_header "$new_csv"
    [[ -f "$new_csv" ]]
    header=$(head -1 "$new_csv")
    [[ "$header" == "$COST_CSV_HEADER" ]]
) && pass "10. _ensure_cost_csv_header — creates new file with header" \
  || fail "10. _ensure_cost_csv_header — creates new file with header"

# ============================================================
# Test 11: _format_tokens
# ============================================================
(
    [[ "$(_format_tokens 500)" == "500" ]]
    [[ "$(_format_tokens 12500)" == "12.5K" ]]
    [[ "$(_format_tokens 1500000)" == "1.5M" ]]
) && pass "11. _format_tokens — formats small, K, and M ranges" \
  || fail "11. _format_tokens — formats small, K, and M ranges"

# ============================================================
# Test 12: _model_name_for_engine
# ============================================================
(
    [[ "$(_model_name_for_engine "claude")" == "opus" ]]
    [[ "$(_model_name_for_engine "codex")" == "gpt-5.4" ]]
) && pass "12. _model_name_for_engine — returns correct model for each engine" \
  || fail "12. _model_name_for_engine — returns correct model for each engine"

# ============================================================
# Test 13: _is_nonnegative_integer and _is_decimal_number
# ============================================================
(
    _is_nonnegative_integer "0"
    _is_nonnegative_integer "12345"
    ! _is_nonnegative_integer "-1"
    ! _is_nonnegative_integer "1.5"
    ! _is_nonnegative_integer "abc"

    _is_decimal_number "0"
    _is_decimal_number "12345"
    _is_decimal_number "1.5"
    _is_decimal_number "0.0001"
    ! _is_decimal_number "-1"
    ! _is_decimal_number "abc"
) && pass "13. _is_nonnegative_integer and _is_decimal_number — validators" \
  || fail "13. _is_nonnegative_integer and _is_decimal_number — validators"

# ============================================================
# Test 14: _archive_legacy_cost_csv
# ============================================================
(
    csv="$TMP_ROOT/archive-test-cost.csv"
    printf 'old header\nold data\n' > "$csv"
    archived=$(_archive_legacy_cost_csv "$csv")
    [[ ! -f "$csv" ]]
    [[ -f "$archived" ]]
    grep -q 'old data' "$archived"
) && pass "14. _archive_legacy_cost_csv — moves file and returns path" \
  || fail "14. _archive_legacy_cost_csv — moves file and returns path"

# ============================================================
# Test 15: read_v1_total_cost — valid CSV sums cost_usd
# ============================================================
(
    LOG_DIR="$TMP_ROOT/v1cost-valid"
    mkdir -p "$LOG_DIR"
    csv="$LOG_DIR/pilot-test-slug-cost.csv"
    echo "$COST_CSV_HEADER" > "$csv"
    echo "2025-01-01T00:00:00Z,task1,planner-r1,claude,opus,n/a,1000,0,0,500,1.5000,60,0,ok" >> "$csv"
    echo "2025-01-01T00:01:00Z,task1,critic-r1,claude,opus,n/a,800,0,0,300,2.3000,45,0,ok" >> "$csv"
    result=$(read_v1_total_cost "test-slug")
    [[ "$result" == "3.8000" ]]
) && pass "15. read_v1_total_cost — valid CSV sums cost_usd" \
  || fail "15. read_v1_total_cost — valid CSV sums cost_usd"

# ============================================================
# Test 16: read_v1_total_cost — missing CSV returns N/A
# ============================================================
(
    LOG_DIR="$TMP_ROOT/v1cost-missing"
    mkdir -p "$LOG_DIR"
    result=$(read_v1_total_cost "nonexistent-slug")
    [[ "$result" == "N/A" ]]
) && pass "16. read_v1_total_cost — missing CSV returns N/A" \
  || fail "16. read_v1_total_cost — missing CSV returns N/A"

# ============================================================
# Test 17: read_v1_total_cost — legacy 13-col CSV migrated
# ============================================================
(
    LOG_DIR="$TMP_ROOT/v1cost-legacy"
    mkdir -p "$LOG_DIR"
    csv="$LOG_DIR/pilot-legacy-slug-cost.csv"
    echo "$LEGACY_COST_CSV_HEADER" > "$csv"
    echo "2025-01-01T00:00:00Z,task1,planner-r1,claude,opus,1000,0,0,500,4.2000,60,0,ok" >> "$csv"
    result=$(read_v1_total_cost "legacy-slug")
    [[ "$result" == "4.2000" ]]
) && pass "17. read_v1_total_cost — legacy 13-col CSV migrated" \
  || fail "17. read_v1_total_cost — legacy 13-col CSV migrated"

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================="
echo "${PASSED}/${TOTAL} passed"
echo "============================="

[[ "$FAILED" -eq 0 ]]

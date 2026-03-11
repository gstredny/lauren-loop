#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-signals.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
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

SCRIPT_DIR="$REPO_ROOT"
YELLOW=''
BLUE=''
SLUG="test-slug"
source "$REPO_ROOT/lib/lauren-loop-utils.sh"

LAUREN_LOOP_STRICT=false

(
    fixture="$TMP_ROOT/plain.md"
    printf 'VERDICT: PASS\n' > "$fixture"
    [[ "$(extract_agent_signal "$fixture" VERDICT)" == "PASS" ]]
) && pass "1. extract_agent_signal — plain format" \
  || fail "1. extract_agent_signal — plain format"

(
    fixture="$TMP_ROOT/bold.md"
    printf '**VERDICT:** PASS\n' > "$fixture"
    [[ "$(extract_agent_signal "$fixture" VERDICT)" == "PASS" ]]
) && pass "2. extract_agent_signal — bold markdown" \
  || fail "2. extract_agent_signal — bold markdown"

(
    fixture="$TMP_ROOT/duplicate.md"
    printf 'VERDICT: FAIL\nVERDICT: PASS\n' > "$fixture"
    [[ "$(extract_agent_signal "$fixture" VERDICT)" == "PASS" ]]
) && pass "3. extract_agent_signal — duplicate fields last wins" \
  || fail "3. extract_agent_signal — duplicate fields last wins"

(
    fixture="$TMP_ROOT/missing.md"
    printf 'STATUS: BLOCKED\n' > "$fixture"
    [[ -z "$(extract_agent_signal "$fixture" VERDICT)" ]]
) && pass "4. extract_agent_signal — missing signal returns empty" \
  || fail "4. extract_agent_signal — missing signal returns empty"

(
    fixture="$TMP_ROOT/whitespace.md"
    printf '   **VERDICT:**   CONDITIONAL   \n' > "$fixture"
    [[ "$(extract_agent_signal "$fixture" VERDICT)" == "CONDITIONAL" ]]
) && pass "5. extract_agent_signal — extra whitespace" \
  || fail "5. extract_agent_signal — extra whitespace"

(
    fixture="$TMP_ROOT/pc-pass.md"
    printf 'VERDICT: PASS\n' > "$fixture"
    rm -f "${fixture%.*}.contract.json"
    [[ "$(_parse_contract "$fixture" "verdict")" == "PASS" ]]
) && pass "6. _parse_contract — PASS verdict" \
  || fail "6. _parse_contract — PASS verdict"

(
    fixture="$TMP_ROOT/pc-conditional.md"
    printf '**VERDICT:** CONDITIONAL\n' > "$fixture"
    rm -f "${fixture%.*}.contract.json"
    [[ "$(_parse_contract "$fixture" "verdict")" == "CONDITIONAL" ]]
) && pass "7. _parse_contract — bold CONDITIONAL" \
  || fail "7. _parse_contract — bold CONDITIONAL"

(
    fixture="$TMP_ROOT/pc-fail.md"
    printf 'VERDICT: FAIL\n' > "$fixture"
    rm -f "${fixture%.*}.contract.json"
    [[ "$(_parse_contract "$fixture" "verdict")" == "FAIL" ]]
) && pass "8. _parse_contract — FAIL" \
  || fail "8. _parse_contract — FAIL"

(
    fixture="$TMP_ROOT/pc-malformed.md"
    printf 'VERDICT maybe PASS\n' > "$fixture"
    rm -f "${fixture%.*}.contract.json"
    [[ -z "$(_parse_contract "$fixture" "verdict")" ]]
) && pass "9. _parse_contract — malformed line" \
  || fail "9. _parse_contract — malformed line"

(
    fixture="$TMP_ROOT/pc-multi.md"
    printf 'VERDICT: PASS\n**VERDICT:** CONDITIONAL\nVERDICT: FAIL\n' > "$fixture"
    rm -f "${fixture%.*}.contract.json"
    [[ "$(_parse_contract "$fixture" "verdict")" == "FAIL" ]]
) && pass "10. _parse_contract — multiple verdict lines last wins" \
  || fail "10. _parse_contract — multiple verdict lines last wins"

(
    fixture="$TMP_ROOT/pc-empty.md"
    : > "$fixture"
    rm -f "${fixture%.*}.contract.json"
    [[ -z "$(_parse_contract "$fixture" "verdict")" ]]
) && pass "11. _parse_contract — empty file" \
  || fail "11. _parse_contract — empty file"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

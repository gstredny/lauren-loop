#!/bin/bash
set -euo pipefail

# Tests the generic extract_markdown_section_to_file wrapper used by Phase 7 Review
# Findings extraction (lauren-loop-v2.sh:5085). The fence-aware Phase 3
# _extract_selected_plan_to_file parser has its own coverage in
# tests/test_lauren_loop_logic.sh cases 5a-5e.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/lib/lauren-loop-utils.sh"

eval "$(sed -n '/^extract_markdown_section_to_file() {/,/^}/p' "$REPO_ROOT/lauren-loop-v2.sh")"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_DIR="$(mktemp -d "${TMP_BASE}/plan-extract.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

PASSED=0
FAILED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo -e "${GREEN}PASS${NC}: $1"; }
fail() { FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo -e "${RED}FAIL${NC}: $1"; }

cat > "$TMP_DIR/standard.md" <<'EOF'
## Evaluation
Some evaluation text.
## Selected Plan
### Goal
Standard plan content.
## Next Section
EOF

(
    extract_markdown_section_to_file "$TMP_DIR/standard.md" "## Selected Plan" "$TMP_DIR/out1.md"
    grep -q "Standard plan content" "$TMP_DIR/out1.md"
) && pass "1. extract_markdown_section_to_file — exact-match header extracts" \
  || fail "1. extract_markdown_section_to_file — exact-match header extracts"

cat > "$TMP_DIR/lower.md" <<'EOF'
## Evaluation
Some evaluation text.
## selected plan
### Goal
Lowercase plan content.
## Next Section
EOF

(
    extract_markdown_section_to_file "$TMP_DIR/lower.md" "## Selected Plan" "$TMP_DIR/out2.md"
    grep -q "Lowercase plan content" "$TMP_DIR/out2.md"
) && pass "2. extract_markdown_section_to_file — lowercase header matches via case-insensitive fallback" \
  || fail "2. extract_markdown_section_to_file — lowercase header matches via case-insensitive fallback"

cat > "$TMP_DIR/upper.md" <<'EOF'
## Evaluation
Some evaluation text.
## SELECTED PLAN
### Goal
Uppercase plan content.
## Next Section
EOF

(
    extract_markdown_section_to_file "$TMP_DIR/upper.md" "## Selected Plan" "$TMP_DIR/out3.md"
    grep -q "Uppercase plan content" "$TMP_DIR/out3.md"
) && pass "3. extract_markdown_section_to_file — uppercase header matches via case-insensitive fallback" \
  || fail "3. extract_markdown_section_to_file — uppercase header matches via case-insensitive fallback"

cat > "$TMP_DIR/level3.md" <<'EOF'
## Evaluation
Some evaluation text.
### Selected Plan
#### Goal
Level 3 plan content.
## Next Section
EOF

(
    extract_markdown_section_to_file "$TMP_DIR/level3.md" "## Selected Plan" "$TMP_DIR/out4.md"
    grep -q "Level 3 plan content" "$TMP_DIR/out4.md"
) && pass "4. extract_markdown_section_to_file — level-3 header extracts via normalized fallback" \
  || fail "4. extract_markdown_section_to_file — level-3 header extracts via normalized fallback"

cat > "$TMP_DIR/missing.md" <<'EOF'
## Evaluation
Some evaluation text.
## Other Section
No selected plan here.
EOF

(
    ! extract_markdown_section_to_file "$TMP_DIR/missing.md" "## Selected Plan" "$TMP_DIR/out5.md" 2>/dev/null
) && pass "5. extract_markdown_section_to_file — missing header returns non-zero" \
  || fail "5. extract_markdown_section_to_file — missing header returns non-zero"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

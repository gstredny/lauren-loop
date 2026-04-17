#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-tail-spacing.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/lib/lauren-loop-utils.sh"

PASSED=0
FAILED=0
TOTAL=0

pass() {
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
    echo "PASS: $1"
}

fail() {
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    echo "FAIL: $1"
    [[ -n "${2:-}" ]] && echo "  Detail: $2"
}

assert_supported_split() {
    local command_text="$1"
    local output=""
    local producer=""
    local tail_args=""

    output=$(_split_supported_trailing_tail_consumer "$command_text")
    producer="${output%%$'\n'*}"
    tail_args="${output#*$'\n'}"

    [[ "$producer" == "producer" ]]
    [[ "$tail_args" == "-n 1" ]]
}

assert_wrapper_no_hang() {
    local command_text="$1"
    local output=""
    local rc=0
    local start=0
    local elapsed=0

    start=$(date +%s)
    output=$(_run_timeout_wrapped_verification_command "$command_text")
    rc=$?
    elapsed=$(( $(date +%s) - start ))

    [[ "$rc" -eq 0 ]]
    [[ "$elapsed" -lt 3 ]]
    printf '%s\n' "$output" | grep -Fxq 'line-30'
}

assert_normalization_rejects() {
    local command_text="$1"
    local expected_error="$2"
    local slug="$3"
    local plan_file="$TMP_ROOT/$slug/plan.md"
    local before=""
    local after=""
    local output=""
    local rc=0

    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<EOF
# Plan Artifact

## Implementation Tasks

<verify>.venv/bin/python -m pytest tests/ -x -q ${command_text}</verify>
EOF

    before="$(cat "$plan_file")"
    set +e
    output="$(_normalize_verify_tags_with_timeout_in_file "$plan_file" "$slug" 2>&1)"
    rc=$?
    set -e
    after="$(cat "$plan_file")"

    [[ "$rc" -ne 0 ]]
    printf '%s\n' "$output" | grep -Fq "$expected_error"
    [[ "$before" == "$after" ]]
}

assert_parser_rejects() {
    local command_text="$1"
    local expected_error="$2"
    local output=""
    local rc=0

    set +e
    output=$(_split_supported_trailing_tail_consumer "$command_text" 2>&1)
    rc=$?
    set -e

    [[ "$rc" -eq 2 ]]
    printf '%s\n' "$output" | grep -Fq "$expected_error"
}

(
    assert_supported_split "producer | tail -n 1"
    assert_supported_split "producer|tail -n 1"
    assert_supported_split "producer| tail -n 1"
    assert_supported_split "producer |tail -n 1"
) && pass "1. split helper accepts all supported pipe-spacing variants" \
  || fail "1. split helper accepts all supported pipe-spacing variants"

(
    base="bash -lc 'for i in {1..30}; do echo line-\$i; done; (sleep 4) &'"
    assert_wrapper_no_hang "${base} | tail -n 1"
    assert_wrapper_no_hang "${base}|tail -n 1"
    assert_wrapper_no_hang "${base}| tail -n 1"
    assert_wrapper_no_hang "${base} |tail -n 1"
) && pass "2. wrapper returns promptly for all supported pipe-spacing variants" \
  || fail "2. wrapper returns promptly for all supported pipe-spacing variants"

(
    assert_normalization_rejects "|tail -f" "unsupported streaming verify tail consumer: tail -f" "tail-f"
    assert_normalization_rejects "|tail --follow" "unsupported streaming verify tail consumer: tail --follow" "tail-follow"
) && pass "3. normalization still fails closed for no-space streaming tails" \
  || fail "3. normalization still fails closed for no-space streaming tails"

(
    assert_parser_rejects "producer|tail -F" "unsupported streaming verify tail consumer: tail -F"
    assert_parser_rejects "producer|tail -n +2" "unsupported trailing verify tail consumer: tail -n +2"
) && pass "4. parser still rejects unsupported no-space tail consumers" \
  || fail "4. parser still rejects unsupported no-space tail consumers"

(
    set +e
    _split_supported_trailing_tail_consumer "producer || tail -n 1" >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
) && pass "5. split helper does not treat || tail as a supported trailing consumer" \
  || fail "5. split helper does not treat || tail as a supported trailing consumer"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [[ "$FAILED" -gt 0 ]]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

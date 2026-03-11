#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/interrupt-integration.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

wait_for_file() {
    local path="$1" iterations="${2:-500}"
    local i
    for ((i=0; i<iterations; i++)); do
        [[ -f "$path" ]] && return 0
        sleep 0.01
    done
    return 1
}

assert_runtime_cleanup() {
    local case_dir="$1"
    ! find "$case_dir" -maxdepth 1 -name '.active-agent.*.meta' | grep -q . || {
        echo "metadata files remained after interrupt cleanup" >&2
        return 1
    }
    [[ ! -f "$case_dir/.interrupted" ]] || {
        echo "interrupt marker remained after cleanup" >&2
        return 1
    }
}

assert_all_shards_have_one_complete_row() {
    local case_dir="$1"
    local shard_count
    shard_count=$(find "$case_dir" -maxdepth 1 -name '.cost-*.csv' ! -name 'cost.csv' | wc -l | tr -d ' ')
    [[ "$shard_count" -gt 0 ]] || {
        echo "expected at least one cost shard" >&2
        return 1
    }

    local shard
    for shard in "$case_dir"/.cost-*.csv; do
        [[ -f "$shard" ]] || continue
        local row_count
        row_count=$(tail -n +2 "$shard" | awk 'NF { count++ } END { print count+0 }')
        [[ "$row_count" -eq 1 ]] || {
            echo "expected exactly one data row in $shard, got $row_count" >&2
            return 1
        }
        awk -F',' 'NR == 1 { next } NF != 13 { exit 1 }' "$shard" || {
            echo "expected only 13-column data rows in $shard" >&2
            return 1
        }
    done
}

# ============================================================
# Test 1: direct _interrupted() call writes interrupted rows and cleanup stays idempotent
# ============================================================
(
    case_dir="$TMP_ROOT/direct-interrupt"
    mkdir -p "$case_dir"

    cat > "$case_dir/child-direct.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

source "$REPO_ROOT/lib/lauren-loop-utils.sh" 2>/dev/null || true

SCRIPT_DIR="$REPO_ROOT"
MODEL="opus"
SLUG="test-slug"
RED=""
GREEN=""
YELLOW=""
BLUE=""
NC=""
AGENT_MONITOR_PIDS=""

release_lock() { :; }
stop_agent_monitor() { :; }
notify_terminal_state() {
    printf '%s|%s\n' "$1" "$2" >> "$CASE_DIR/notify.log"
}

eval "$(
    sed -n '/^# Pricing rates/,/^lauren_loop_competitive()/{ /^lauren_loop_competitive()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^setup_azure_context 2>\/dev\/null || true$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

declare -f cleanup_v2 >/dev/null 2>&1 || { echo "FAIL: extraction produced no cleanup_v2 function" >&2; exit 1; }

_print_cost_summary() { :; }

TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_FILE="$CASE_DIR/task.md"

printf '## Status: in progress\n\n## Execution Log\n\n' > "$_CURRENT_TASK_FILE"

seed_agent_instance() {
    local role="$1" state="$2" status="${3:-}"
    local meta_path instance_id cost_csv
    meta_path=$(_agent_meta_path "$role")
    _write_active_agent_meta "$role" "claude" "opus" "$(date +%s)" "5s" "$state" "$meta_path"
    instance_id=$(_agent_instance_id_from_meta_path "$meta_path")
    cost_csv=$(_cost_csv_path_for_instance "$instance_id")
    if [[ -n "$status" ]]; then
        _append_cost_csv_raw_row \
            "$cost_csv" "$(_iso_timestamp)" "$SLUG" "$role" "claude" "opus" \
            "1" "0" "0" "1" "0.0001" "1" "0" "$status"
    fi
}

orig_append_raw=$(declare -f _append_cost_csv_raw_row)
orig_append_raw=${orig_append_raw/_append_cost_csv_raw_row/__orig_append_cost_csv_raw_row}
eval "$orig_append_raw"
_append_cost_csv_raw_row() {
    sleep 0.05
    __orig_append_cost_csv_raw_row "$@"
}

orig_clear_runtime=$(declare -f _clear_active_runtime_state)
orig_clear_runtime=${orig_clear_runtime/_clear_active_runtime_state/__orig_clear_active_runtime_state}
eval "$orig_clear_runtime"
_clear_active_runtime_state() {
    local count=0
    [[ -f "$CASE_DIR/cleanup.count" ]] && read -r count < "$CASE_DIR/cleanup.count"
    printf '%s\n' "$((count + 1))" > "$CASE_DIR/cleanup.count"
    __orig_clear_active_runtime_state
}

seed_agent_instance "explorer" "running"
seed_agent_instance "planner-a" "writing_row" "completed"

_interrupted TERM
EOF
    chmod +x "$case_dir/child-direct.sh"

    (
        if wait_for_file "$case_dir/.interrupted"; then
            : > "$case_dir/marker.seen"
        fi
    ) &
    watcher_pid=$!

    set +e
    REPO_ROOT="$REPO_ROOT" CASE_DIR="$case_dir" "$case_dir/child-direct.sh"
    rc=$?
    set -e
    wait "$watcher_pid" 2>/dev/null || true

    [[ "$rc" -eq 143 ]] || { echo "expected child exit 143, got $rc" >&2; exit 1; }
    wait_for_file "$case_dir/marker.seen" || { echo "interrupt marker was never observed" >&2; exit 1; }
    [[ "$(cat "$case_dir/cleanup.count")" == "1" ]] || { echo "cleanup should run its side effects once" >&2; exit 1; }
    assert_all_shards_have_one_complete_row "$case_dir"
    assert_runtime_cleanup "$case_dir"
    awk -F',' 'NR > 1 { status[$13]++ } END { exit !(status["completed"] == 1 && status["interrupted"] == 1) }' "$case_dir"/.cost-*.csv \
        || { echo "expected one completed row and one interrupted row" >&2; exit 1; }
    grep -q '^## Status: blocked$' "$case_dir/task.md" || { echo "task file was not marked blocked" >&2; exit 1; }
    [ "$(wc -l < "$case_dir/notify.log" | tr -d ' ')" = "1" ] || { echo "expected exactly one notification" >&2; exit 1; }
    grep -q '^interrupted|Pipeline interrupted (TERM) — test-slug$' "$case_dir/notify.log" \
        || { echo "interrupt notification payload mismatch" >&2; exit 1; }
) && pass "1. _interrupted direct call — rows finish and cleanup stays idempotent" \
  || fail "1. _interrupted direct call — rows finish and cleanup stays idempotent"

# ============================================================
# Test 2: repeated TERM during interrupted-row write leaves a complete row and cleaned runtime state
# ============================================================
(
    case_dir="$TMP_ROOT/repeated-term"
    mkdir -p "$case_dir"

    cat > "$case_dir/child-signal.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

source "$REPO_ROOT/lib/lauren-loop-utils.sh" 2>/dev/null || true

SCRIPT_DIR="$REPO_ROOT"
MODEL="opus"
SLUG="test-slug"
RED=""
GREEN=""
YELLOW=""
BLUE=""
NC=""
AGENT_MONITOR_PIDS=""

release_lock() { :; }
stop_agent_monitor() { :; }
notify_terminal_state() {
    printf '%s|%s\n' "$1" "$2" >> "$CASE_DIR/notify.log"
}

eval "$(
    sed -n '/^# Pricing rates/,/^lauren_loop_competitive()/{ /^lauren_loop_competitive()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^setup_azure_context 2>\/dev\/null || true$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

declare -f cleanup_v2 >/dev/null 2>&1 || { echo "FAIL: extraction produced no cleanup_v2 function" >&2; exit 1; }

_terminate_active_jobs() { :; }
_print_cost_summary() { :; }

TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_FILE="$CASE_DIR/task.md"

printf '## Status: in progress\n\n## Execution Log\n\n' > "$_CURRENT_TASK_FILE"

orig_clear_runtime=$(declare -f _clear_active_runtime_state)
orig_clear_runtime=${orig_clear_runtime/_clear_active_runtime_state/__orig_clear_active_runtime_state}
eval "$orig_clear_runtime"
_clear_active_runtime_state() {
    local count=0
    [[ -f "$CASE_DIR/cleanup.count" ]] && read -r count < "$CASE_DIR/cleanup.count"
    printf '%s\n' "$((count + 1))" > "$CASE_DIR/cleanup.count"
    __orig_clear_active_runtime_state
}

_append_cost_csv_raw_row() {
    local cost_csv="$1" timestamp="$2" task="$3" role="$4" engine="$5" model_name="$6"
    local input_tok="$7" cache_write_tok="$8" cache_read_tok="$9" output_tok="${10}"
    local cost="${11}" duration="${12}" exit_code="${13}" status="${14}"

    _ensure_cost_csv_header "$cost_csv"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,' \
        "$timestamp" "$task" "$role" "$engine" "$model_name" \
        "$input_tok" "$cache_write_tok" "$cache_read_tok" >> "$cost_csv"
    : > "$CASE_DIR/partial-write.started"
    sleep 1
    printf '%s,%s,%s,%s,%s\n' \
        "$output_tok" "$cost" "$duration" "$exit_code" "$status" >> "$cost_csv"
}

meta_path=$(_agent_meta_path "explorer")
_write_active_agent_meta "explorer" "claude" "opus" "$(date +%s)" "5s" "running" "$meta_path"

trap '_interrupted TERM' TERM
: > "$CASE_DIR/ready"
while true; do
    sleep 1
done
EOF
    chmod +x "$case_dir/child-signal.sh"

    set +e
    REPO_ROOT="$REPO_ROOT" CASE_DIR="$case_dir" \
        perl -MPOSIX=setsid -e 'setsid() or die $!; exec @ARGV' "$case_dir/child-signal.sh" \
        >"$case_dir/out.log" 2>"$case_dir/err.log" &
    child_pid=$!
    set -e

    wait_for_file "$case_dir/ready" || { echo "signal test child never became ready" >&2; exit 1; }
    kill -TERM -- "-$child_pid"
    wait_for_file "$case_dir/partial-write.started" || { echo "interrupted write never started" >&2; exit 1; }
    kill -TERM -- "-$child_pid"

    set +e
    wait "$child_pid"
    rc=$?
    set -e

    [[ "$rc" -eq 143 ]] || { echo "expected child exit 143, got $rc" >&2; exit 1; }
    [[ "$(cat "$case_dir/cleanup.count")" == "1" ]] || { echo "cleanup should run its side effects once" >&2; exit 1; }
    assert_all_shards_have_one_complete_row "$case_dir"
    assert_runtime_cleanup "$case_dir"
    awk -F',' 'NR > 1 && $13 != "interrupted" { exit 1 }' "$case_dir"/.cost-*.csv \
        || { echo "expected interrupted status row after repeated TERM" >&2; exit 1; }
    [ "$(wc -l < "$case_dir/notify.log" | tr -d ' ')" = "1" ] || { echo "expected exactly one notification" >&2; exit 1; }
    grep -q '^interrupted|Pipeline interrupted (TERM) — test-slug$' "$case_dir/notify.log" \
        || { echo "interrupt notification payload mismatch" >&2; exit 1; }
) && pass "2. repeated TERM during interrupted write — no partial shard rows" \
  || fail "2. repeated TERM during interrupted write — no partial shard rows"

# ============================================================
# Test 3: cleanup_v2 safety net — sets "blocked" when task is still "in progress"
# ============================================================
(
    case_dir="$TMP_ROOT/cleanup-safety-net"
    mkdir -p "$case_dir"

    cat > "$case_dir/child-cleanup.sh" <<'CHILD_EOF'
#!/bin/bash
set -e

source "$REPO_ROOT/lib/lauren-loop-utils.sh" 2>/dev/null || true

SCRIPT_DIR="$REPO_ROOT"
MODEL="opus"
SLUG="test-slug"
RED=""
GREEN=""
YELLOW=""
BLUE=""
NC=""
AGENT_MONITOR_PIDS=""

release_lock() { :; }
stop_agent_monitor() { :; }
notify_terminal_state() { :; }

eval "$(
    sed -n '/^# Pricing rates/,/^lauren_loop_competitive()/{ /^lauren_loop_competitive()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^setup_azure_context 2>\/dev\/null || true$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

declare -f cleanup_v2 >/dev/null 2>&1 || { echo "FAIL: extraction produced no cleanup_v2 function" >&2; exit 1; }

_terminate_active_jobs() { :; }
_print_cost_summary() { :; }

TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_FILE="$CASE_DIR/task.md"

printf '## Status: in progress\n\n## Execution Log\n\n' > "$_CURRENT_TASK_FILE"

# Simulate an unguarded command failure under set -e.
# The EXIT trap (cleanup_v2) should detect "in progress" and set "blocked".
false
CHILD_EOF
    chmod +x "$case_dir/child-cleanup.sh"

    set +e
    REPO_ROOT="$REPO_ROOT" CASE_DIR="$case_dir" "$case_dir/child-cleanup.sh"
    rc=$?
    set -e

    [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit from set -e child" >&2; exit 1; }
    grep -q '^## Status: blocked$' "$case_dir/task.md" \
        || { echo "cleanup_v2 safety net did not set status to blocked; got: $(grep '^## Status:' "$case_dir/task.md")" >&2; exit 1; }
    grep -q 'cleanup_v2: task was still .in progress. at exit' "$case_dir/task.md" \
        || { echo "cleanup_v2 safety net did not log the status change" >&2; exit 1; }
) && pass "3. cleanup_v2 safety net — 'in progress' → 'blocked' on unhandled set -e exit" \
  || fail "3. cleanup_v2 safety net — 'in progress' → 'blocked' on unhandled set -e exit"

# ============================================================
# Test 4: cleanup_v2 safety net skips when status is already terminal
# ============================================================
(
    case_dir="$TMP_ROOT/cleanup-already-terminal"
    mkdir -p "$case_dir"

    cat > "$case_dir/child-terminal.sh" <<'CHILD_EOF'
#!/bin/bash
set -e

source "$REPO_ROOT/lib/lauren-loop-utils.sh" 2>/dev/null || true

SCRIPT_DIR="$REPO_ROOT"
MODEL="opus"
SLUG="test-slug"
RED=""
GREEN=""
YELLOW=""
BLUE=""
NC=""
AGENT_MONITOR_PIDS=""

release_lock() { :; }
stop_agent_monitor() { :; }
notify_terminal_state() { :; }

eval "$(
    sed -n '/^# Pricing rates/,/^lauren_loop_competitive()/{ /^lauren_loop_competitive()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^setup_azure_context 2>\/dev\/null || true$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

declare -f cleanup_v2 >/dev/null 2>&1 || { echo "FAIL: extraction produced no cleanup_v2 function" >&2; exit 1; }

_terminate_active_jobs() { :; }
_print_cost_summary() { :; }

TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_LOG_DIR="$CASE_DIR"
_CURRENT_TASK_FILE="$CASE_DIR/task.md"

# Task already has terminal status — safety net should NOT overwrite it
printf '## Status: needs verification\n\n## Execution Log\n\n' > "$_CURRENT_TASK_FILE"

false
CHILD_EOF
    chmod +x "$case_dir/child-terminal.sh"

    set +e
    REPO_ROOT="$REPO_ROOT" CASE_DIR="$case_dir" "$case_dir/child-terminal.sh"
    rc=$?
    set -e

    [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit" >&2; exit 1; }
    grep -q '^## Status: needs verification$' "$case_dir/task.md" \
        || { echo "safety net incorrectly overwrote terminal status; got: $(grep '^## Status:' "$case_dir/task.md")" >&2; exit 1; }
) && pass "4. cleanup_v2 safety net — skips when status is already 'needs verification'" \
  || fail "4. cleanup_v2 safety net — skips when status is already 'needs verification'"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

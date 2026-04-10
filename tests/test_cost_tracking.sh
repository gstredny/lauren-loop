#!/bin/bash
# test_cost_tracking.sh — Unit tests for cost tracking and Lauren Loop guard helpers
# Convention matches test_lauren_loop_utils.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/cost-tracking.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0
TOTAL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

pass() {
    PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1))
    echo -e "${GREEN}PASS${NC}: $1"
}
fail() {
    FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1))
    echo -e "${RED}FAIL${NC}: $1"
    [ -n "${2:-}" ] && echo "  Detail: $2"
}

single_cost_shard() {
    find "$1" -maxdepth 1 -name '.cost-*.csv' ! -name 'cost.csv' | sort | head -1
}

cost_shard_count() {
    find "$1" -maxdepth 1 -name '.cost-*.csv' ! -name 'cost.csv' | wc -l | tr -d ' '
}

single_meta_file() {
    find "$1" -maxdepth 1 -name '.active-agent.*.meta' | sort | head -1
}

# ============================================================
# Source the functions under test
# ============================================================
# Extract function defs from lauren-loop-v2.sh without running CLI entry point.
# We use awk to grab from pricing constants through the end of _print_cost_summary.

SCRIPT_DIR="$REPO_ROOT"
MODEL="opus"
SLUG="test-slug"
TASK_LOG_DIR="$TMP_ROOT"

source "$REPO_ROOT/lib/lauren-loop-utils.sh" 2>/dev/null || true

eval "$(
    sed -n '/^## Pricing constants/,/^lauren_loop_competitive()/{ /^lauren_loop_competitive()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^setup_azure_context 2>\/dev\/null || true$/d'
)"

load_lauren_loop_competitive() {
    eval "$(
        awk '
            /^lauren_loop_competitive\(\)/ { flag=1 }
            /^# CLI Entry Point$/ { flag=0 }
            flag { print }
        ' "$REPO_ROOT/lauren-loop-v2.sh"
    )"
}

write_lauren_loop_prompts() {
    local runtime_root="$1"
    mkdir -p "$runtime_root/prompts"
    local prompt
    for prompt in \
        exploration-summarizer.md planner-a.md planner-b.md plan-evaluator.md \
        critic.md reviser.md executor.md scope-triage.md reviewer.md reviewer-b.md \
        review-evaluator.md fix-plan-author.md fix-executor.md; do
        case "$prompt" in
            planner-b.md|reviewer-b.md)
                cp "$REPO_ROOT/prompts/$prompt" "$runtime_root/prompts/$prompt"
                continue
                ;;
        esac
        cat > "$runtime_root/prompts/$prompt" <<EOF
# ${prompt}

Placeholder prompt for shell integration tests.
EOF
    done
}

lauren_loop_task_dir_for_slug() {
    local slug="$1"
    printf '%s/docs/tasks/open/%s\n' "$SCRIPT_DIR" "$slug"
}

lauren_loop_task_file_for_slug() {
    local slug="$1"
    local dir_task flat_task
    dir_task="$(lauren_loop_task_dir_for_slug "$slug")/task.md"
    flat_task="$SCRIPT_DIR/docs/tasks/open/${slug}.md"
    if [[ -f "$dir_task" ]]; then
        printf '%s\n' "$dir_task"
    elif [[ -f "$flat_task" ]]; then
        printf '%s\n' "$flat_task"
    else
        printf '%s\n' "$dir_task"
    fi
}

lauren_loop_comp_dir_for_slug() {
    local slug="$1"
    printf '%s/competitive\n' "$(lauren_loop_task_dir_for_slug "$slug")"
}

setup_lauren_loop_runtime() {
    local runtime_root="$1" slug="$2"
    mkdir -p "$runtime_root/docs/tasks/open"
    write_lauren_loop_prompts "$runtime_root"

    SCRIPT_DIR="$runtime_root"
    MODEL="opus"
    DRY_RUN=false
    INTERNAL=true
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    LAUREN_LOOP_MAX_COST="0"
    AGENT_SETTINGS='{}'
    PROJECT_RULES=""
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="codex"
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    ENGINE_FIX="claude"
    SINGLE_REVIEWER_POLICY="synthesis"
    EXPLORE_TIMEOUT="1m"
    PLANNER_TIMEOUT="1m"
    EVALUATE_TIMEOUT="1m"
    CRITIC_TIMEOUT="1m"
    EXECUTOR_TIMEOUT="1m"
    REVIEWER_TIMEOUT="1m"
    SYNTHESIZE_TIMEOUT="1m"
    TASK_LOG_DIR=""
    _CURRENT_TASK_LOG_DIR=""
    _CURRENT_TASK_FILE=""
    _LOCK_ACQUIRED=false
    _CLEANUP_V2_RUNNING=false
    _CLEANUP_V2_DONE=false
    _COST_CEILING_WARNED=false
    _COST_CEILING_INTERRUPT_WARNED=false
    SLUG="$slug"
}

install_lauren_loop_test_stubs() {
    prepare_agent_request() {
        local engine="$1" prompt_file="$2" instruction="$3"
        local prompt_stub="placeholder prompt for $(basename "$prompt_file")"
        case "$(basename "$prompt_file")" in
            executor.md|fix-executor.md)
                prompt_stub="Run verification with .venv/bin/python -m pytest tests/ -x -q before finishing."
                ;;
        esac

        AGENT_PROMPT_BODY=""
        AGENT_SYSTEM_PROMPT=""
        if [[ "$engine" == "claude" ]]; then
            AGENT_SYSTEM_PROMPT="$prompt_stub"
            AGENT_PROMPT_BODY="$instruction"
        else
            AGENT_PROMPT_BODY="${prompt_stub}

---

${instruction}"
        fi
    }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    _check_cost_ceiling() { return 0; }
    _block_on_untracked_files() { return 0; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _init_run_manifest() { return 0; }
    _append_manifest_phase() { return 0; }
    _finalize_run_manifest() { return 0; }
    capture_diff_artifact() {
        local diff_file="$2"
        cat > "$diff_file" <<'EOF'
diff --git a/tmp.txt b/tmp.txt
+integration-test-change
EOF
    }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
}

write_task_review_findings() {
    local task_file="$1" verdict="$2"
    local tmp_file
    tmp_file=$(mktemp "${TMP_BASE}/review-findings.XXXXXX")
    cat > "$tmp_file" <<EOF
VERDICT: ${verdict}
EOF
    rewrite_section "$task_file" "## Review Findings" "$tmp_file"
    rm -f "$tmp_file"
}

write_valid_plan_artifact() {
    local path="$1" title="${2:-Plan Artifact}" change_label="${3:-Update}" fenced="${4:-yes}"
    local open_fence="" close_fence=""
    if [[ "$fenced" != "no" ]]; then
        open_fence='```xml'
        close_fence='```'
    fi
    cat > "$path" <<EOF
# ${title}

## Files to Modify
- \`lauren-loop-v2.sh\` — ${change_label}

## Implementation Tasks

${open_fence}
<wave number="1">
  <task type="auto">
    <name>Exercise planner artifact validation</name>
    <files>lauren-loop-v2.sh</files>
    <action>Describe the change and the test-first order without writing code.</action>
    <verify>bash test_cost_tracking.sh</verify>
    <done>The planner artifact is valid for pipeline evaluation.</done>
  </task>
</wave>
${close_fence}

## Testability Design
- Exercise the shell pipeline through \`lauren_loop_competitive\`.

## Test Strategy
- Run the Lauren Loop shell regression suite before and after the change.

## Risk Assessment
- Ensure artifact validation rejects summary-only files without discarding valid plans.

## Dependencies
- None.
EOF
}

write_valid_reviewer_b_artifact() {
    local path="$1" verdict="${2:-PASS}" findings="${3:-No findings.}"
    cat > "$path" <<EOF
# Review B

**Task:** task.md
**Focus:** Architecture / Structural Integrity
**Scope:** lauren-loop-v2.sh

## Findings

${findings}

## Done-Criteria Check

Not applicable.

## Dimension Coverage

**1. Architecture / Structural Integrity:** checked
**2. Correctness:** checked
**3. Test Quality:** checked
**4. Edge Cases:** checked
**5. Error Handling:** checked
**6. Security:** checked
**7. Performance:** checked
**8. Caller Impact:** checked
**9. Design Decision Validity:** checked

## Verdict

**VERDICT: ${verdict}**
**Blocking findings:** None
**Rationale:** test artifact
EOF
}

seed_phase7_resume_artifacts() {
    local slug="$1" critique_verdict="${2:-__missing__}"
    local comp_dir
    comp_dir=$(lauren_loop_comp_dir_for_slug "$slug")
    mkdir -p "$comp_dir"

    cat > "$comp_dir/exploration-summary.md" <<'EOF'
## Exploration Summary
Ready to resume.
EOF
    write_valid_plan_artifact "$comp_dir/plan-a.md" "Plan A" "Existing plan A"
    write_valid_plan_artifact "$comp_dir/plan-b.md" "Plan B" "Existing plan B"
    cat > "$comp_dir/revised-plan.md" <<'EOF'
## Revised Plan
- Approved plan
EOF
    cat > "$comp_dir/plan-critique.md" <<'EOF'
## Critique

VERDICT: EXECUTE
EOF
    cat > "$comp_dir/execution-diff.patch" <<'EOF'
diff --git a/tmp.txt b/tmp.txt
+phase-4-checkpoint
EOF
    cat > "$comp_dir/fix-plan.md" <<'EOF'
## Fix Plan
READY: yes
EOF
    cat > "$comp_dir/.cycle-state.json" <<'EOF'
{"fix_cycle":0,"last_completed":"phase-6c","review_verdict":"FAIL","timestamp":"2026-03-09T00:00:00Z"}
EOF

    if [[ "$critique_verdict" != "__missing__" ]]; then
        cat > "$comp_dir/fix-critique.md" <<EOF
## Fix Critique

VERDICT: ${critique_verdict}
EOF
    fi
}

# ============================================================
# Test 1: _extract_claude_tokens — sums across multiple events
# ============================================================
(
    fixture="$TMP_ROOT/claude_log.jsonl"
    # 3 events with known token counts (structure from real logs)
    cat > "$fixture" <<'FIXTURE'
{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_001","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":6103,"cache_read_input_tokens":0,"output_tokens":14,"service_tier":"standard"}}}
{"type":"result","subtype":"success","cost_usd":0.05,"duration_ms":1200,"session_id":"abc"}
{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_002","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":1,"cache_creation_input_tokens":5818,"cache_read_input_tokens":6103,"output_tokens":18,"service_tier":"standard"}}}
{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_003","type":"message","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":11921,"output_tokens":500,"service_tier":"standard"}}}
FIXTURE

    result=$(_extract_claude_tokens "$fixture")
    read -r in cw cr out <<< "$result"

    # Expected: input=3+1+10=14, cache_write=6103+5818+0=11921, cache_read=0+6103+11921=18024, output=14+18+500=532
    [[ "$in" -eq 14 ]] || { echo "input_tokens: expected 14, got $in" >&2; exit 1; }
    [[ "$cw" -eq 11921 ]] || { echo "cache_write: expected 11921, got $cw" >&2; exit 1; }
    [[ "$cr" -eq 18024 ]] || { echo "cache_read: expected 18024, got $cr" >&2; exit 1; }
    [[ "$out" -eq 532 ]] || { echo "output_tokens: expected 532, got $out" >&2; exit 1; }
) && pass "1. _extract_claude_tokens — sums across 3 events" \
  || fail "1. _extract_claude_tokens — sums across 3 events"

# ============================================================
# Test 17: _extract_claude_tokens — duplicate message IDs use final usage once
# ============================================================
(
    fixture="$TMP_ROOT/claude_duplicate_ids.jsonl"
    cat > "$fixture" <<'FIXTURE'
{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_dup","type":"message","role":"assistant","content":[{"type":"thinking"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4,"service_tier":"standard"}}}
{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_dup","type":"message","role":"assistant","content":[{"type":"text","text":"partial"}],"usage":{"input_tokens":5,"cache_creation_input_tokens":6,"cache_read_input_tokens":7,"output_tokens":8,"service_tier":"standard"}}}
{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_unique","type":"message","role":"assistant","content":[{"type":"text","text":"unique"}],"usage":{"input_tokens":19,"cache_creation_input_tokens":23,"cache_read_input_tokens":29,"output_tokens":31,"service_tier":"standard"}}}
{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_dup","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_123","name":"Read","input":{"file_path":"x"}}],"usage":{"input_tokens":7,"cache_creation_input_tokens":11,"cache_read_input_tokens":13,"output_tokens":17,"service_tier":"standard"}}}
FIXTURE

    result=$(_extract_claude_tokens "$fixture")
    read -r in cw cr out <<< "$result"

    # Expected: last msg_dup row (7/11/13/17) + msg_unique (19/23/29/31)
    [[ "$in" -eq 26 ]] || { echo "input_tokens: expected 26, got $in" >&2; exit 1; }
    [[ "$cw" -eq 34 ]] || { echo "cache_write: expected 34, got $cw" >&2; exit 1; }
    [[ "$cr" -eq 42 ]] || { echo "cache_read: expected 42, got $cr" >&2; exit 1; }
    [[ "$out" -eq 48 ]] || { echo "output_tokens: expected 48, got $out" >&2; exit 1; }
) && pass "17. _extract_claude_tokens — duplicate IDs keep only final usage" \
  || fail "17. _extract_claude_tokens — duplicate IDs keep only final usage"

# ============================================================
# Test 2: _extract_claude_tokens — empty file returns 0 0 0 0
# ============================================================
(
    fixture="$TMP_ROOT/empty_log.jsonl"
    touch "$fixture"
    result=$(_extract_claude_tokens "$fixture")
    [[ "$result" == "0 0 0 0" ]]
) && pass "2. _extract_claude_tokens — empty file returns zeros" \
  || fail "2. _extract_claude_tokens — empty file returns zeros"

# ============================================================
# Test 3: _extract_claude_tokens — missing file returns 0 0 0 0
# ============================================================
(
    result=$(_extract_claude_tokens "$TMP_ROOT/nonexistent.log")
    [[ "$result" == "0 0 0 0" ]]
) && pass "3. _extract_claude_tokens — missing file returns zeros" \
  || fail "3. _extract_claude_tokens — missing file returns zeros"

# ============================================================
# Test 4: _extract_claude_tokens — no assistant events returns 0 0 0 0
# ============================================================
(
    fixture="$TMP_ROOT/no_assistant.jsonl"
    cat > "$fixture" <<'FIXTURE'
{"type":"result","subtype":"success","cost_usd":0.05}
{"type":"system","message":"Starting session"}
FIXTURE
    result=$(_extract_claude_tokens "$fixture")
    [[ "$result" == "0 0 0 0" ]]
) && pass "4. _extract_claude_tokens — no assistant events returns zeros" \
  || fail "4. _extract_claude_tokens — no assistant events returns zeros"

# ============================================================
# Test 5: _extract_claude_tokens — malformed JSON lines skipped
# ============================================================
(
    fixture="$TMP_ROOT/malformed.jsonl"
    cat > "$fixture" <<'FIXTURE'
{"type":"assistant","message":{"id":"msg_004","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
not valid json {"type":"assistant"
{"type":"assistant","message":{"id":"msg_005","usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":75}}}
FIXTURE
    result=$(_extract_claude_tokens "$fixture")
    read -r in cw cr out <<< "$result"
    # Should get 300 input, 125 output (malformed line skipped by jq)
    [[ "$in" -eq 300 ]] || { echo "input: expected 300, got $in" >&2; exit 1; }
    [[ "$out" -eq 125 ]] || { echo "output: expected 125, got $out" >&2; exit 1; }
) && pass "5. _extract_claude_tokens — malformed JSON lines skipped" \
  || fail "5. _extract_claude_tokens — malformed JSON lines skipped"

# ============================================================
# Test 6: _extract_codex_tokens — estimates prompt + output chars
# ============================================================
(
    fixture="$TMP_ROOT/codex_output.md"
    # 400 prompt chars and 400 output chars → 100 estimated input + 100 output
    printf '%0400d' 0 > "$fixture"
    result=$(_extract_codex_tokens 400 "$fixture")
    read -r in cw cr out <<< "$result"
    [[ "$in" -eq 100 ]] && [[ "$cw" -eq 0 ]] && [[ "$cr" -eq 0 ]] && [[ "$out" -eq 100 ]]
) && pass "6. _extract_codex_tokens — estimates prompt/output chars" \
  || fail "6. _extract_codex_tokens — estimates prompt/output chars"

# ============================================================
# Test 7: _extract_codex_tokens — missing output keeps estimated input
# ============================================================
(
    result=$(_extract_codex_tokens 400 "$TMP_ROOT/nonexistent_output.md")
    [[ "$result" == "100 0 0 0" ]]
) && pass "7. _extract_codex_tokens — missing output keeps input estimate" \
  || fail "7. _extract_codex_tokens — missing output keeps input estimate"

# ============================================================
# Test 8: _calculate_cost — Claude with all 4 token fields
# ============================================================
(
    # 1000 input × $5/1M + 2000 cache_write × $6.25/1M + 10000 cache_read × $0.50/1M + 500 output × $25/1M
    # = 0.005 + 0.0125 + 0.005 + 0.0125 = 0.0350
    cost=$(_calculate_cost "claude" 1000 2000 10000 500)
    [[ "$cost" == "0.0350" ]] || { echo "expected 0.0350, got $cost" >&2; exit 1; }
) && pass "8. _calculate_cost — Claude with cache fields" \
  || fail "8. _calculate_cost — Claude with cache fields"

# ============================================================
# Test 9: _calculate_cost — Codex
# ============================================================
(
    # 0 input + 0 cache + 0 cache + 1000 output × $15/1M = 0.0150
    cost=$(_calculate_cost "codex" 0 0 0 1000)
    [[ "$cost" == "0.0150" ]] || { echo "expected 0.0150, got $cost" >&2; exit 1; }
) && pass "9. _calculate_cost — Codex output-only" \
  || fail "9. _calculate_cost — Codex output-only"

# ============================================================
# Test 10: _calculate_cost — zero tokens
# ============================================================
(
    cost=$(_calculate_cost "claude" 0 0 0 0)
    # bc may output "0" or "0.0000" — normalize
    [[ "$cost" == "0.0000" || "$cost" == "0" ]]
) && pass "10. _calculate_cost — zero tokens" \
  || fail "10. _calculate_cost — zero tokens"

# ============================================================
# Test 11: _calculate_cost — leading zero normalization
# ============================================================
(
    # 100 output × $25/1M = 0.0025 (bc would output .0025 without normalization)
    cost=$(_calculate_cost "claude" 0 0 0 100)
    [[ "$cost" == 0* ]] || { echo "expected leading zero, got $cost" >&2; exit 1; }
) && pass "11. _calculate_cost — leading zero normalization" \
  || fail "11. _calculate_cost — leading zero normalization"

# ============================================================
# Test 12: _format_tokens — K/M formatting
# ============================================================
(
    [[ "$(_format_tokens 500)" == "500" ]] || exit 1
    [[ "$(_format_tokens 12500)" == "12.5K" ]] || exit 1
    [[ "$(_format_tokens 1500000)" == "1.5M" ]] || exit 1
    [[ "$(_format_tokens 0)" == "0" ]] || exit 1
) && pass "12. _format_tokens — K/M formatting" \
  || fail "12. _format_tokens — K/M formatting"

# ============================================================
# Test 13: _append_cost_row — writes per-agent 14-column CSV
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/csv_test"
    mkdir -p "$TASK_LOG_DIR"

    fixture="$TMP_ROOT/csv_test/test.log"
    cat > "$fixture" <<'FIXTURE'
{"type":"assistant","message":{"id":"msg_006","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}
FIXTURE

    start_ts=$(date +%s)
    csv="$TASK_LOG_DIR/.cost-test13.csv"
    _append_cost_row "$csv" "explorer" "claude" "$start_ts" "0" "$fixture" "/dev/null" 0

    [[ -f "$csv" ]] || { echo "CSV not created" >&2; exit 1; }

    # Check header has 14 columns
    header=$(head -1 "$csv")
    col_count=$(echo "$header" | tr ',' '\n' | wc -l | tr -d ' ')
    [[ "$col_count" -eq 14 ]] || { echo "expected 14 columns, got $col_count" >&2; exit 1; }

    # Check data row
    data=$(tail -1 "$csv")
    data_cols=$(echo "$data" | tr ',' '\n' | wc -l | tr -d ' ')
    [[ "$data_cols" -eq 14 ]] || { echo "data row: expected 14 columns, got $data_cols" >&2; exit 1; }

    # Check tokens are non-zero
    reasoning=$(echo "$data" | cut -d',' -f6)
    input_tok=$(echo "$data" | cut -d',' -f7)
    [[ "$reasoning" == "n/a" ]] || { echo "reasoning_effort: expected n/a, got $reasoning" >&2; exit 1; }
    [[ "$input_tok" -eq 100 ]] || { echo "input_tokens: expected 100, got $input_tok" >&2; exit 1; }
) && pass "13. _append_cost_row — writes per-agent 14-column CSV with real tokens" \
  || fail "13. _append_cost_row — writes per-agent 14-column CSV with real tokens"

# ============================================================
# Test 14: _append_cost_row — archives legacy headers before writing
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/legacy_csv_test"
    mkdir -p "$TASK_LOG_DIR"
    csv="$TASK_LOG_DIR/.cost-legacy-test.csv"
    cat > "$csv" <<'CSV'
timestamp,task,agent_role,engine,model,input_tokens,output_tokens,cost_usd,duration_sec,exit_code
legacy,data,row,claude,opus,1,2,0.01,10,0
CSV

    fixture="$TASK_LOG_DIR/claude.log"
    cat > "$fixture" <<'FIXTURE'
{"type":"assistant","message":{"id":"msg_007","usage":{"input_tokens":25,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
FIXTURE

    _append_cost_row "$csv" "explorer" "claude" "$(date +%s)" "0" "$fixture" "/dev/null" 0 >/dev/null 2>&1

    [[ -f "$csv" ]] || { echo "new agent csv missing" >&2; exit 1; }
    [[ "$(head -1 "$csv")" == "$COST_CSV_HEADER" ]] || { echo "new header mismatch" >&2; exit 1; }
    legacy_count=$(find "$TASK_LOG_DIR" -name '.cost-legacy-test.legacy-*.csv' | wc -l | tr -d ' ')
    [[ "$legacy_count" -eq 1 ]] || { echo "expected 1 archived legacy csv, got $legacy_count" >&2; exit 1; }
) && pass "14. _append_cost_row — archives legacy headers" \
  || fail "14. _append_cost_row — archives legacy headers"

# ============================================================
# Test 15: _extract_claude_tokens — real log file validation
# ============================================================
(
    real_log="$REPO_ROOT/logs/pilot/pilot-multi-question-context-degradation-executor.log"
    if [[ -f "$real_log" ]]; then
        result=$(_extract_claude_tokens "$real_log")
        read -r in cw cr out <<< "$result"
        # Real log should have non-zero values
        total=$((in + cw + cr + out))
        [[ "$total" -gt 0 ]] || { echo "real log returned all zeros" >&2; exit 1; }
        # Sanity: output tokens should be positive for an executor
        [[ "$out" -gt 0 ]] || { echo "output_tokens=0 for executor log" >&2; exit 1; }
    else
        echo "Skipping — real log not found" >&2
        exit 0
    fi
) && pass "15. _extract_claude_tokens — real log file has non-zero tokens" \
  || fail "15. _extract_claude_tokens — real log file has non-zero tokens"

# ============================================================
# Test 16: _print_cost_summary — produces output from CSV
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/summary_test"
    SLUG="test-summary"
    mkdir -p "$TASK_LOG_DIR"

    # Write a CSV with known data
    cat > "$TASK_LOG_DIR/cost.csv" <<'CSV'
timestamp,task,agent_role,engine,model,reasoning_effort,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,cost_usd,duration_sec,exit_code,status
2026-03-06T10:00:00,test,explorer,claude,opus,n/a,100,200,300,50,0.0040,60,0,completed
2026-03-06T10:01:00,test,planner-a,claude,opus,n/a,200,0,0,100,0.0035,45,0,completed
2026-03-06T10:01:00,test,planner-b,codex,gpt-5.4,medium,0,0,0,50,0.0007,30,0,completed
CSV

    output=$(_print_cost_summary 2>&1)
    echo "$output" | grep -q "Cost Summary" || { echo "missing header" >&2; exit 1; }
    echo "$output" | grep -q "explorer" || { echo "missing explorer row" >&2; exit 1; }
    echo "$output" | grep -q "Total:" || { echo "missing total" >&2; exit 1; }
    echo "$output" | grep -q "Linear equivalent:" || { echo "missing linear" >&2; exit 1; }
    echo "$output" | grep -q "Competitive premium:" || { echo "missing premium" >&2; exit 1; }
    echo "$output" | grep -q "Codex token and cost values are estimated" || { echo "missing codex note" >&2; exit 1; }
) && pass "16. _print_cost_summary — produces formatted output" \
  || fail "16. _print_cost_summary — produces formatted output"

# ============================================================
# Test 18: run_agent — truncates log before each Claude run
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/run_agent_test"
    mkdir -p "$TASK_LOG_DIR"

    stub_bin="$TMP_ROOT/bin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/claude" <<'FIXTURE'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_stub","type":"message","role":"assistant","content":[],"usage":{"input_tokens":7,"cache_creation_input_tokens":11,"cache_read_input_tokens":13,"output_tokens":17,"service_tier":"standard"}}}'
FIXTURE
    chmod +x "$stub_bin/claude"

    PATH="$stub_bin:$PATH"
    AGENT_SETTINGS='{}'

    log_file="$TMP_ROOT/run_agent_test/explorer.log"
    output_file="$TMP_ROOT/run_agent_test/output.md"
    printf 'stale-first-run\n' > "$log_file"

    run_agent "explorer" "claude" "prompt body" "system prompt" "$output_file" "$log_file" "5s" "5" "Bash"

    printf 'stale-second-run\n' >> "$log_file"
    run_agent "explorer" "claude" "prompt body" "system prompt" "$output_file" "$log_file" "5s" "5" "Bash"

    ! grep -q 'stale-first-run' "$log_file" || { echo "first stale content survived" >&2; exit 1; }
    ! grep -q 'stale-second-run' "$log_file" || { echo "second stale content survived" >&2; exit 1; }
    [[ "$(grep -c '"id":"msg_stub"' "$log_file")" -eq 1 ]] || { echo "expected 1 fresh assistant event" >&2; exit 1; }

    [[ "$(cost_shard_count "$TASK_LOG_DIR")" -eq 2 ]] || { echo "expected 2 per-instance cost shards" >&2; exit 1; }
    data=$(tail -1 "$(single_cost_shard "$TASK_LOG_DIR")")
    reasoning=$(echo "$data" | cut -d',' -f6)
    input_tok=$(echo "$data" | cut -d',' -f7)
    cache_write_tok=$(echo "$data" | cut -d',' -f8)
    cache_read_tok=$(echo "$data" | cut -d',' -f9)
    output_tok=$(echo "$data" | cut -d',' -f10)
    [[ "$reasoning" == "n/a" ]] || { echo "reasoning_effort: expected n/a, got $reasoning" >&2; exit 1; }
    [[ "$input_tok" -eq 7 ]] || { echo "input_tokens: expected 7, got $input_tok" >&2; exit 1; }
    [[ "$cache_write_tok" -eq 11 ]] || { echo "cache_write: expected 11, got $cache_write_tok" >&2; exit 1; }
    [[ "$cache_read_tok" -eq 13 ]] || { echo "cache_read: expected 13, got $cache_read_tok" >&2; exit 1; }
    [[ "$output_tok" -eq 17 ]] || { echo "output_tokens: expected 17, got $output_tok" >&2; exit 1; }
) && pass "18. run_agent — truncates stale log content before each run" \
  || fail "18. run_agent — truncates stale log content before each run"

# ============================================================
# Test 19: run_agent — metadata creation failure hard-fails without side effects
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/meta_failure_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    stub_bin="$TMP_ROOT/bin-meta-failure"
    marker_file="$TASK_LOG_DIR/claude-invoked"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/claude" <<FIXTURE
#!/bin/bash
touch "$marker_file"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_meta_fail","type":"message","role":"assistant","content":[],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1,"service_tier":"standard"}}}'
FIXTURE
    chmod +x "$stub_bin/claude"

    PATH="$stub_bin:$PATH"
    AGENT_SETTINGS='{}'

    _write_active_agent_meta() {
        return 1
    }

    set +e
    run_agent "explorer" "claude" "prompt body" "system prompt" \
        "$TASK_LOG_DIR/output.md" "$TASK_LOG_DIR/explorer.log" "5s" "5" "Bash"
    rc=$?
    set -e

    [[ "$rc" -ne 0 ]] || { echo "expected metadata failure to return non-zero" >&2; exit 1; }
    [[ "$(cost_shard_count "$TASK_LOG_DIR")" -eq 0 ]] || { echo "fallback shard should not exist" >&2; exit 1; }
    ! find "$TASK_LOG_DIR" -name '.active-agent.*.meta' | grep -q . || { echo "orphan metadata file remained" >&2; exit 1; }
    [[ ! -f "$marker_file" ]] || { echo "agent should not launch after metadata failure" >&2; exit 1; }
) && pass "19. run_agent — metadata creation failure hard-fails without side effects" \
  || fail "19. run_agent — metadata creation failure hard-fails without side effects"

# ============================================================
# Test 20: run_agent + interrupted rows — marker skips completed row and writes one interrupted row
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/interrupted_row_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    stub_bin="$TMP_ROOT/bin-interrupted"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/claude" <<'FIXTURE'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_interrupt","type":"message","role":"assistant","content":[],"usage":{"input_tokens":9,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3,"service_tier":"standard"}}}'
FIXTURE
    chmod +x "$stub_bin/claude"

    PATH="$stub_bin:$PATH"
    AGENT_SETTINGS='{}'

    _set_interrupt_marker
    run_agent "explorer" "claude" "prompt body" "system prompt" \
        "$TASK_LOG_DIR/output.md" "$TASK_LOG_DIR/explorer.log" "5s" "5" "Bash"

    [[ "$(cost_shard_count "$TASK_LOG_DIR")" -eq 0 ]] || { echo "completed row should have been skipped" >&2; exit 1; }
    meta_file=$(single_meta_file "$TASK_LOG_DIR")
    [[ -n "$meta_file" ]] || { echo "expected active-agent metadata to remain" >&2; exit 1; }
    grep -q $'\twriting_row$' "$meta_file" || { echo "expected metadata state writing_row" >&2; exit 1; }

    _append_interrupted_cost_rows INT

    [[ "$(cost_shard_count "$TASK_LOG_DIR")" -eq 1 ]] || { echo "interrupted row not written" >&2; exit 1; }
    data=$(tail -1 "$(single_cost_shard "$TASK_LOG_DIR")")
    [[ "$(echo "$data" | cut -d',' -f14)" == "interrupted" ]] || { echo "expected interrupted status, got $data" >&2; exit 1; }
    ! find "$TASK_LOG_DIR" -name '.active-agent.*.meta' | grep -q . || { echo "metadata should be removed after interrupted row append" >&2; exit 1; }
) && pass "20. run_agent + interrupted rows — marker yields one interrupted row" \
  || fail "20. run_agent + interrupted rows — marker yields one interrupted row"

# ============================================================
# Test 21: _clear_interrupt_marker — stale marker does not poison resumed cost tracking
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/clear_marker_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    stub_bin="$TMP_ROOT/bin-clear-marker"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/claude" <<'FIXTURE'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_resume","type":"message","role":"assistant","content":[],"usage":{"input_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2,"service_tier":"standard"}}}'
FIXTURE
    chmod +x "$stub_bin/claude"

    PATH="$stub_bin:$PATH"
    AGENT_SETTINGS='{}'

    _set_interrupt_marker
    _clear_interrupt_marker
    run_agent "explorer" "claude" "prompt body" "system prompt" \
        "$TASK_LOG_DIR/output.md" "$TASK_LOG_DIR/explorer.log" "5s" "5" "Bash"

    data=$(tail -1 "$(single_cost_shard "$TASK_LOG_DIR")")
    [[ "$(echo "$data" | cut -d',' -f14)" == "completed" ]] || { echo "expected completed row after clearing marker, got $data" >&2; exit 1; }
) && pass "21. _clear_interrupt_marker — stale marker does not poison resumed runs" \
  || fail "21. _clear_interrupt_marker — stale marker does not poison resumed runs"

# ============================================================
# Test 22: _append_interrupted_cost_rows — completed shard suppresses duplicate interrupted row
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/interrupted_dedupe_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    meta_file=$(_agent_meta_path "explorer")
    _write_active_agent_meta "explorer" "claude" "opus" "n/a" "$(date +%s)" "5s" "writing_row" "$meta_file"
    instance_id=$(_agent_instance_id_from_meta_path "$meta_file")
    csv=$(_cost_csv_path_for_instance "$instance_id")
    _append_cost_csv_raw_row \
        "$csv" "$(_iso_timestamp)" "test-slug" "explorer" "claude" "opus" \
        "n/a" "1" "0" "0" "1" "0.0001" "1" "0" "completed"

    _append_interrupted_cost_rows INT

    [[ "$(tail -n +2 "$csv" | wc -l | tr -d ' ')" -eq 1 ]] || { echo "duplicate interrupted row appended" >&2; exit 1; }
    ! find "$TASK_LOG_DIR" -name '.active-agent.*.meta' | grep -q . || { echo "metadata should be removed after dedupe skip" >&2; exit 1; }
) && pass "22. _append_interrupted_cost_rows — completed shard suppresses duplicate interrupted row" \
  || fail "22. _append_interrupted_cost_rows — completed shard suppresses duplicate interrupted row"

# ============================================================
# Test 23: run_agent — same-role runs create distinct per-instance shards
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/per_instance_shards_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    stub_bin="$TMP_ROOT/bin-instance"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/claude" <<'FIXTURE'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-6","id":"msg_instance","type":"message","role":"assistant","content":[],"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2,"service_tier":"standard"}}}'
FIXTURE
    cat > "$stub_bin/date" <<'FIXTURE'
#!/bin/bash
if [[ "$1" == "+%s" ]]; then
    printf '1700000000\n'
elif [[ "$1" == "-Iseconds" ]]; then
    printf '2026-03-09T00:00:00+00:00\n'
else
    /bin/date "$@"
fi
FIXTURE
    chmod +x "$stub_bin/claude" "$stub_bin/date"

    PATH="$stub_bin:$PATH"
    AGENT_SETTINGS='{}'

    run_agent "explorer" "claude" "prompt body" "system prompt" \
        "$TASK_LOG_DIR/output-a.md" "$TASK_LOG_DIR/explorer-a.log" "5s" "5" "Bash"
    run_agent "explorer" "claude" "prompt body" "system prompt" \
        "$TASK_LOG_DIR/output-b.md" "$TASK_LOG_DIR/explorer-b.log" "5s" "5" "Bash"

    [[ "$(cost_shard_count "$TASK_LOG_DIR")" -eq 2 ]] || { echo "expected 2 distinct per-instance shards" >&2; exit 1; }
    shard_a=$(find "$TASK_LOG_DIR" -maxdepth 1 -name '.cost-*.csv' ! -name 'cost.csv' | sort | head -1)
    shard_b=$(find "$TASK_LOG_DIR" -maxdepth 1 -name '.cost-*.csv' ! -name 'cost.csv' | sort | tail -1)
    [[ "$shard_a" != "$shard_b" ]] || { echo "same-role runs reused the same shard" >&2; exit 1; }
) && pass "23. run_agent — same-role runs create distinct per-instance shards" \
  || fail "23. run_agent — same-role runs create distinct per-instance shards"

# ============================================================
# Test 23a: run_agent — Codex capacity failure retries on the high profile and logs reasoning
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/codex_capacity_retry_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    codex_call_log="$TASK_LOG_DIR/codex-calls.log"
    sleep_log="$TASK_LOG_DIR/sleep.log"
    codex_calls=0

    sleep() {
        printf '%s\n' "$1" >> "$sleep_log"
    }

    _run_codex_agent_attempt() {
        local role="$1" profile="$2" prompt="$3" artifact_file="$4" attempt_log="$5"
        codex_calls=$((codex_calls + 1))
        printf '%s\n' "$profile" >> "$codex_call_log"
        : > "$attempt_log"
        if [[ "$codex_calls" -eq 1 ]]; then
            echo "event: response.failed" >> "$attempt_log"
            echo "error.type: too_many_requests" >> "$attempt_log"
            return 1
        fi

        printf 'codex output\n' > "$artifact_file"
        return 0
    }

    run_agent "planner-b" "codex" "prompt body" "" \
        "$TASK_LOG_DIR/planner-b.md" "$TASK_LOG_DIR/planner-b.log" "5s" "5" "Bash"

    [[ "$codex_calls" -eq 2 ]] || { echo "expected 2 codex calls, got $codex_calls" >&2; exit 1; }
    [[ "$(sed -n '1p' "$codex_call_log")" == "azure54" ]] || { echo "first codex profile should be azure54" >&2; exit 1; }
    [[ "$(sed -n '2p' "$codex_call_log")" == "azure54" ]] || { echo "second codex profile should stay azure54" >&2; exit 1; }
    [[ "$(cat "$sleep_log")" == "15" ]] || { echo "expected one 15-second backoff, got $(tr '\n' ',' < "$sleep_log")" >&2; exit 1; }
    [[ "$(grep -c 'profile=azure54 reasoning=xhigh' "$TASK_LOG_DIR/planner-b.log")" -eq 2 ]] || {
        echo "planner log should record two high-profile attempts" >&2
        exit 1
    }
    ! grep -q 'reasoning=medium' "$TASK_LOG_DIR/planner-b.log" || { echo "planner log should not downgrade to medium reasoning" >&2; exit 1; }

    data=$(tail -1 "$(single_cost_shard "$TASK_LOG_DIR")")
    [[ "$(echo "$data" | cut -d',' -f6)" == "xhigh" ]] || { echo "expected xhigh reasoning in cost row, got $data" >&2; exit 1; }
) && pass "23a. run_agent — Codex capacity failure retries on the high profile" \
  || fail "23a. run_agent — Codex capacity failure retries on the high profile"

# ============================================================
# Test 23b: run_agent — Codex stream failure retries on the high profile
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/codex_stream_retry_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    codex_call_log="$TASK_LOG_DIR/codex-calls.log"
    sleep_log="$TASK_LOG_DIR/sleep.log"
    codex_calls=0

    sleep() {
        printf '%s\n' "$1" >> "$sleep_log"
    }

    _run_codex_agent_attempt() {
        local role="$1" profile="$2" prompt="$3" artifact_file="$4" attempt_log="$5"
        codex_calls=$((codex_calls + 1))
        printf '%s\n' "$profile" >> "$codex_call_log"
        : > "$attempt_log"
        if [[ "$codex_calls" -eq 1 ]]; then
            echo "stream disconnected before completion: response.failed event received" >> "$attempt_log"
            return 1
        fi

        printf 'codex output\n' > "$artifact_file"
        return 0
    }

    run_agent "planner-b" "codex" "prompt body" "" \
        "$TASK_LOG_DIR/planner-b.md" "$TASK_LOG_DIR/planner-b.log" "5s" "5" "Bash"

    [[ "$codex_calls" -eq 2 ]] || { echo "expected 2 codex calls, got $codex_calls" >&2; exit 1; }
    [[ "$(sed -n '1p' "$codex_call_log")" == "azure54" ]] || { echo "first codex profile should be azure54" >&2; exit 1; }
    [[ "$(sed -n '2p' "$codex_call_log")" == "azure54" ]] || { echo "second codex profile should stay azure54" >&2; exit 1; }
    [[ "$(cat "$sleep_log")" == "15" ]] || { echo "expected one 15-second backoff, got $(tr '\n' ',' < "$sleep_log")" >&2; exit 1; }
    grep -q 'WARN: Codex stream failure for planner-b; retrying with profile azure54 after 15s backoff.' "$TASK_LOG_DIR/planner-b.log" || {
        echo "planner log missing stream fallback warning" >&2
        exit 1
    }
    [[ "$(grep -c 'profile=azure54 reasoning=xhigh' "$TASK_LOG_DIR/planner-b.log")" -eq 2 ]] || {
        echo "planner log should record two high-profile attempts" >&2
        exit 1
    }
    ! grep -q 'reasoning=medium' "$TASK_LOG_DIR/planner-b.log" || { echo "planner log should not downgrade to medium reasoning" >&2; exit 1; }

    data=$(tail -1 "$(single_cost_shard "$TASK_LOG_DIR")")
    [[ "$(echo "$data" | cut -d',' -f6)" == "xhigh" ]] || { echo "expected xhigh reasoning in cost row, got $data" >&2; exit 1; }
) && pass "23b. run_agent — Codex stream failure retries on the high profile" \
  || fail "23b. run_agent — Codex stream failure retries on the high profile"

# ============================================================
# Test 23c: run_agent — Codex summary output is decoupled from the real artifact
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/codex_summary_decouple_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    artifact_file="$TASK_LOG_DIR/planner-b.md"
    summary_file="$TASK_LOG_DIR/planner-b.summary.txt"
    export CODEX_ARTIFACT_PATH="$artifact_file"
    stub_bin="$TMP_ROOT/bin-codex-summary"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/codex54_exec_with_guard" <<'EOF'
#!/bin/bash
set -euo pipefail
output_file=""
if [[ "${1:-}" == "--profile" ]]; then
    shift 2
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            output_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

cat > "$CODEX_ARTIFACT_PATH" <<'INNER'
# Plan B

## Files to Modify
- `lauren-loop-v2.sh` — Artifact decoupling

## Implementation Tasks

```xml
<wave number="1">
  <task type="auto">
    <name>Preserve the on-disk artifact</name>
    <files>lauren-loop-v2.sh</files>
    <action>Keep the Codex summary response separate from the actual plan file.</action>
    <verify>bash test_cost_tracking.sh</verify>
    <done>The plan artifact remains intact on disk.</done>
  </task>
</wave>
```

## Testability Design
- Exercise `run_agent` through the Codex shell path.

## Test Strategy
- Run the Lauren Loop shell regressions.

## Risk Assessment
- Ensure summary-only output cannot overwrite the real artifact.

## Dependencies
- None.
INNER

printf 'ARTIFACT_WRITTEN\n' > "$output_file"
EOF
    chmod +x "$stub_bin/codex54_exec_with_guard"
    PATH="$stub_bin:$PATH"

    run_agent "planner-b" "codex" "Write the plan artifact to $artifact_file." "" \
        "$artifact_file" "$TASK_LOG_DIR/planner-b.log" "5s" "5" "Bash"

    grep -q '^# Plan B$' "$artifact_file" || { echo "artifact file did not keep the plan content" >&2; exit 1; }
    ! grep -q '^ARTIFACT_WRITTEN$' "$artifact_file" || { echo "summary sentinel overwrote the planner artifact" >&2; exit 1; }
    grep -q '^ARTIFACT_WRITTEN$' "$summary_file" || { echo "summary file missing sentinel response" >&2; exit 1; }
    unset CODEX_ARTIFACT_PATH
) && pass "23c. run_agent — Codex summary output is decoupled from the real artifact" \
  || fail "23c. run_agent — Codex summary output is decoupled from the real artifact"

# ============================================================
# Test 23d: run_agent — valid non-zero Codex artifact suppresses outer fallback
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/codex_valid_nonzero_attempt"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    codex_calls=0
    sleep_log="$TASK_LOG_DIR/sleep.log"
    prompt_log="$TASK_LOG_DIR/prompts.log"
    canonical_artifact="$TASK_LOG_DIR/plan-b.md"

    sleep() {
        printf '%s\n' "$1" >> "$sleep_log"
    }

    _run_codex_agent_attempt() {
        local role="$1" profile="$2" prompt="$3" artifact_file="$4" attempt_log="$5"
        codex_calls=$((codex_calls + 1))
        printf '%s\n' "$prompt" >> "$prompt_log"
        : > "$attempt_log"
        echo "stream disconnected before completion: response.failed event received" >> "$attempt_log"
        write_valid_plan_artifact "$artifact_file" "Plan B" "Attempt-local plan"
        return 1
    }

    run_agent "planner-b" "codex" "Write the detailed plan to ${CODEX_ARTIFACT_PATH_PLACEHOLDER}." "" \
        "$canonical_artifact" "$TASK_LOG_DIR/planner-b.log" "5s" "5" "Bash" || true

    [[ "$codex_calls" -eq 1 ]] || { echo "expected one codex call, got $codex_calls" >&2; exit 1; }
    [[ ! -f "$sleep_log" ]] || { echo "fallback backoff should not have run for a complete artifact" >&2; exit 1; }
    grep -q 'plan-b\.attempt-1\.md' "$prompt_log" || { echo "attempt-local artifact path was not injected into the prompt" >&2; exit 1; }
    grep -q '^# Plan B$' "$canonical_artifact" || { echo "canonical artifact was not promoted from the attempt file" >&2; exit 1; }
    [[ -f "$TASK_LOG_DIR/plan-b.attempt-1.md" ]] || { echo "attempt artifact should be preserved for provenance" >&2; exit 1; }
    grep -q 'artifact_state=complete_fallback' "$TASK_LOG_DIR/planner-b.log" || { echo "planner log missing complete_fallback state" >&2; exit 1; }
) && pass "23d. run_agent — valid non-zero Codex artifact suppresses outer fallback" \
  || fail "23d. run_agent — valid non-zero Codex artifact suppresses outer fallback"

# ============================================================
# Test 23e: _merge_cost_csvs — fallback shards are merged into the consolidated cost CSV
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/merge_fallback_costs_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    planner_csv="$TASK_LOG_DIR/.cost-planner-b.csv"
    fallback_csv="$TASK_LOG_DIR/.cost-planner-b-claude-fallback.csv"

    _ensure_cost_csv_header "$TASK_LOG_DIR/cost.csv"
    _ensure_cost_csv_header "$planner_csv"
    _ensure_cost_csv_header "$fallback_csv"

    _append_cost_csv_raw_row \
        "$planner_csv" "$(_iso_timestamp)" "test-slug" "planner-b" "codex" "gpt-5.4" \
        "xhigh" "0" "0" "0" "50" "0.0007" "30" "0" "completed"
    _append_cost_csv_raw_row \
        "$fallback_csv" "$(_iso_timestamp)" "test-slug" "planner-b-claude-fallback" "claude" "opus" \
        "n/a" "100" "0" "0" "50" "0.0035" "12" "0" "completed"

    _merge_cost_csvs

    [[ "$(cost_shard_count "$TASK_LOG_DIR")" -eq 0 ]] || { echo "expected all per-instance shards to be merged and removed" >&2; exit 1; }
    [[ "$(tail -n +2 "$TASK_LOG_DIR/cost.csv" | wc -l | tr -d ' ')" -eq 2 ]] || { echo "expected exactly two merged cost rows" >&2; exit 1; }
    grep -q ',planner-b,' "$TASK_LOG_DIR/cost.csv" || { echo "merged cost.csv is missing planner-b row" >&2; exit 1; }
    grep -q ',planner-b-claude-fallback,' "$TASK_LOG_DIR/cost.csv" || { echo "merged cost.csv is missing fallback row" >&2; exit 1; }
) && pass "23e. _merge_cost_csvs — fallback shards are merged into the consolidated cost CSV" \
  || fail "23e. _merge_cost_csvs — fallback shards are merged into the consolidated cost CSV"

# ============================================================
# Test 24: _terminate_active_jobs — reaps live jobs from the current shell
# ============================================================
(
    TASK_LOG_DIR="$TMP_ROOT/terminate_jobs_test"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    mkdir -p "$TASK_LOG_DIR"

    sleep 30 &
    pid_a=$!
    ( sleep 30 ) &
    pid_b=$!

    jobs_before=$(_list_active_job_pids)
    echo "$jobs_before" | grep -q "^${pid_a}$" || { echo "missing pid_a from jobs -p" >&2; exit 1; }
    echo "$jobs_before" | grep -q "^${pid_b}$" || { echo "missing pid_b from jobs -p" >&2; exit 1; }

    _terminate_active_jobs

    ! kill -0 "$pid_a" 2>/dev/null || { echo "pid_a survived termination" >&2; exit 1; }
    ! kill -0 "$pid_b" 2>/dev/null || { echo "pid_b survived termination" >&2; exit 1; }
) && pass "24. _terminate_active_jobs — reaps live shell jobs" \
  || fail "24. _terminate_active_jobs — reaps live shell jobs"

# ============================================================
# Test 25: _phase2_planner_artifact_state — exit 0 + invalid artifact is corrupt
# ============================================================
(
    fixture="$TMP_ROOT/phase2_corrupt_plan.md"
    : > "$fixture"

    state=$(_phase2_planner_artifact_state "planner-b" 0 "$fixture")
    [[ "$state" == "corrupt" ]] || { echo "expected corrupt, got $state" >&2; exit 1; }
) && pass "25. _phase2_planner_artifact_state — clean exit + invalid artifact is corrupt" \
  || fail "25. _phase2_planner_artifact_state — clean exit + invalid artifact is corrupt"

# ============================================================
# Test 26: _phase2_planner_artifact_state — non-zero exit stays unavailable
# ============================================================
(
    state=$(_phase2_planner_artifact_state "planner-b" 17 "$TMP_ROOT/nonexistent-plan.md")
    [[ "$state" == "unavailable" ]] || { echo "expected unavailable, got $state" >&2; exit 1; }
) && pass "26. _phase2_planner_artifact_state — non-zero exit is unavailable" \
  || fail "26. _phase2_planner_artifact_state — non-zero exit is unavailable"

# ============================================================
# Test 26b: _phase2_planner_artifact_state — non-zero exit + valid artifact is valid (Fix 4)
# ============================================================
(
    valid_plan="$TMP_ROOT/phase2_valid_nonzero.md"
    write_valid_plan_artifact "$valid_plan" "Plan B" "Valid despite exit code"

    state=$(_phase2_planner_artifact_state "planner-b" 17 "$valid_plan")
    [[ "$state" == "valid" ]] || { echo "expected valid, got $state" >&2; exit 1; }
) && pass "26b. _phase2_planner_artifact_state — non-zero exit + valid artifact is valid" \
  || fail "26b. _phase2_planner_artifact_state — non-zero exit + valid artifact is valid"

# ============================================================
# Test 26d: _phase2_planner_artifact_state — clean exit + valid unfenced artifact is valid
# ============================================================
(
    valid_plan="$TMP_ROOT/phase2_valid_unfenced.md"
    write_valid_plan_artifact "$valid_plan" "Plan B" "Valid without fences" "no"

    state=$(_phase2_planner_artifact_state "planner-b" 0 "$valid_plan")
    [[ "$state" == "valid" ]] || { echo "expected valid, got $state" >&2; exit 1; }
) && pass "26d. _phase2_planner_artifact_state — clean exit + valid unfenced artifact is valid" \
  || fail "26d. _phase2_planner_artifact_state — clean exit + valid unfenced artifact is valid"

# ============================================================
# Test 26c: _phase2_planner_artifact_state — exit 0 + summary-only stub is corrupt
# ============================================================
(
    stub_plan="$TMP_ROOT/phase2_summary_only.md"
    printf 'ARTIFACT_WRITTEN\n' > "$stub_plan"

    state=$(_phase2_planner_artifact_state "planner-b" 0 "$stub_plan")
    [[ "$state" == "corrupt" ]] || { echo "expected corrupt, got $state" >&2; exit 1; }
) && pass "26c. _phase2_planner_artifact_state — exit 0 + summary-only stub is corrupt" \
  || fail "26c. _phase2_planner_artifact_state — exit 0 + summary-only stub is corrupt"

# ============================================================
# Test 27: _phase2_checkpoint_plan_state — missing/valid/corrupt are distinct
# ============================================================
(
    missing_state=$(_phase2_checkpoint_plan_state "planner-b" "$TMP_ROOT/missing-checkpoint-plan.md")
    [[ "$missing_state" == "missing" ]] || { echo "expected missing, got $missing_state" >&2; exit 1; }

    valid_plan="$TMP_ROOT/valid-checkpoint-plan.md"
    write_valid_plan_artifact "$valid_plan" "Plan B" "Implement the fix"
    valid_state=$(_phase2_checkpoint_plan_state "planner-b" "$valid_plan")
    [[ "$valid_state" == "valid" ]] || { echo "expected valid, got $valid_state" >&2; exit 1; }

    corrupt_plan="$TMP_ROOT/corrupt-checkpoint-plan.md"
    : > "$corrupt_plan"
    corrupt_state=$(_phase2_checkpoint_plan_state "planner-b" "$corrupt_plan")
    [[ "$corrupt_state" == "corrupt" ]] || { echo "expected corrupt, got $corrupt_state" >&2; exit 1; }
) && pass "27. _phase2_checkpoint_plan_state — distinguishes missing, valid, and corrupt" \
  || fail "27. _phase2_checkpoint_plan_state — distinguishes missing, valid, and corrupt"

# ============================================================
# Test 27b: _clear_force_artifacts — prunes attempt/cycle provenance files
# ============================================================
(
    comp_dir="$TMP_ROOT/force-clean-competitive"
    task_log_dir="$TMP_ROOT/force-clean-logs"
    mkdir -p "$comp_dir" "$task_log_dir"
    touch \
        "$comp_dir/plan-b.attempt-1.md" \
        "$comp_dir/reviewer-b.raw.attempt-2.md" \
        "$comp_dir/reviewer-b.raw.cycle1.md" \
        "$comp_dir/review-b.cycle1.md" \
        "$comp_dir/.review-mapping.cycle1" \
        "$task_log_dir/planner-b.attempt-1.summary.txt"

    _clear_force_artifacts "$comp_dir" "$task_log_dir"

    [[ ! -e "$comp_dir/plan-b.attempt-1.md" ]]
    [[ ! -e "$comp_dir/reviewer-b.raw.attempt-2.md" ]]
    [[ ! -e "$comp_dir/reviewer-b.raw.cycle1.md" ]]
    [[ ! -e "$comp_dir/review-b.cycle1.md" ]]
    [[ ! -e "$comp_dir/.review-mapping.cycle1" ]]
    [[ ! -e "$task_log_dir/planner-b.attempt-1.summary.txt" ]]
) && pass "27b. _clear_force_artifacts — prunes attempt/cycle provenance files" \
  || fail "27b. _clear_force_artifacts — prunes attempt/cycle provenance files"

# ============================================================
# Test 28: _phase7_resume_gate_reason — critic disabled skips critique requirement
# ============================================================
(
    comp_dir="$TMP_ROOT/phase7-no-critic"
    mkdir -p "$comp_dir"
    cat > "$comp_dir/fix-plan.md" <<'EOF'
## Fix Plan
READY: yes
EOF

    unset ENGINE_CRITIC
    output=$(_phase7_resume_gate_reason "$comp_dir")
    rc=$?

    [[ "$rc" -eq 0 ]] || { echo "expected success, got rc=$rc" >&2; exit 1; }
    [[ -z "$output" ]] || { echo "expected no reason output, got: $output" >&2; exit 1; }
) && pass "28. _phase7_resume_gate_reason — no critic skips fix-critique gate" \
  || fail "28. _phase7_resume_gate_reason — no critic skips fix-critique gate"

# ============================================================
# Test 29: _phase7_resume_gate_reason — critic requires EXECUTE verdict
# ============================================================
(
    comp_dir="$TMP_ROOT/phase7-execute"
    mkdir -p "$comp_dir"
    cat > "$comp_dir/fix-plan.md" <<'EOF'
## Fix Plan
READY: yes
EOF
    cat > "$comp_dir/fix-critique.md" <<'EOF'
## Critique

## Verdict

VERDICT: EXECUTE
EOF

    ENGINE_CRITIC="claude"
    output=$(_phase7_resume_gate_reason "$comp_dir")
    rc=$?

    [[ "$rc" -eq 0 ]] || { echo "expected success, got rc=$rc" >&2; exit 1; }
    [[ -z "$output" ]] || { echo "expected no reason output, got: $output" >&2; exit 1; }
) && pass "29. _phase7_resume_gate_reason — EXECUTE verdict permits resume" \
  || fail "29. _phase7_resume_gate_reason — EXECUTE verdict permits resume"

# ============================================================
# Test 30: _phase7_resume_gate_reason — missing critique or non-EXECUTE verdict blocks resume
# ============================================================
(
    missing_dir="$TMP_ROOT/phase7-missing-critique"
    mkdir -p "$missing_dir"
    cat > "$missing_dir/fix-plan.md" <<'EOF'
## Fix Plan
READY: yes
EOF

    ENGINE_CRITIC="claude"
    set +e
    missing_output=$(_phase7_resume_gate_reason "$missing_dir")
    missing_rc=$?
    set -e

    [[ "$missing_rc" -ne 0 ]] || { echo "expected missing critique to fail" >&2; exit 1; }
    echo "$missing_output" | grep -q "missing valid fix-critique.md" || {
        echo "unexpected missing-critique reason: $missing_output" >&2
        exit 1
    }

    blocked_dir="$TMP_ROOT/phase7-blocked-critique"
    mkdir -p "$blocked_dir"
    cat > "$blocked_dir/fix-plan.md" <<'EOF'
## Fix Plan
READY: yes
EOF
    cat > "$blocked_dir/fix-critique.md" <<'EOF'
## Critique

## Verdict

VERDICT: BLOCKED - needs revision
EOF

    set +e
    blocked_output=$(_phase7_resume_gate_reason "$blocked_dir")
    blocked_rc=$?
    set -e

    [[ "$blocked_rc" -ne 0 ]] || { echo "expected blocked verdict to fail" >&2; exit 1; }
    echo "$blocked_output" | grep -q "fix-critique verdict is BLOCKED" || {
        echo "unexpected blocked-verdict reason: $blocked_output" >&2
        exit 1
    }
) && pass "30. _phase7_resume_gate_reason — missing critique or non-EXECUTE verdict blocks resume" \
  || fail "30. _phase7_resume_gate_reason — missing critique or non-EXECUTE verdict blocks resume"

# ============================================================
# Test 31: run_critic_loop — EXECUTE_WITH_CHANGES hard-fails as an invalid verdict
# ============================================================
(
    task_file="$TMP_ROOT/critic-loop-reject-task.md"
    comp_dir="$TMP_ROOT/critic-loop-reject"
    critic_prompt="$TMP_ROOT/critic-loop-reject-critic.md"
    reviser_prompt="$TMP_ROOT/critic-loop-reject-reviser.md"
    mkdir -p "$comp_dir"

    cat > "$task_file" <<'EOF'
## Task: critic-loop-reject
## Status: in progress
## Goal: Verify critic verdict parsing

## Execution Log
EOF
    cat > "$comp_dir/fix-plan.md" <<'EOF'
## Fix Plan
READY: yes
EOF
    printf '# critic\n' > "$critic_prompt"
    printf '# reviser\n' > "$reviser_prompt"

    PROJECT_RULES=""
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    run_agent() {
        local output_file="$5"
        cat > "$output_file" <<'EOF'
## Critique

VERDICT: EXECUTE_WITH_CHANGES
EOF
        return 0
    }

    set +e
    run_critic_loop "$task_file" "$comp_dir" "$critic_prompt" "$reviser_prompt" \
        "$comp_dir/fix-plan.md" "$comp_dir/fix-critique.md" 1 "fix-critic" "needs verification" "claude"
    rc=$?
    set -e

    [[ "$rc" -eq 2 ]] || { echo "expected rc=2, got $rc" >&2; exit 1; }
    ! grep -q 'round 1 approved' "$task_file" || { echo "non-EXECUTE verdict should not approve" >&2; exit 1; }
) && pass "31. run_critic_loop — EXECUTE_WITH_CHANGES hard-fails as invalid" \
  || fail "31. run_critic_loop — EXECUTE_WITH_CHANGES hard-fails as invalid"

# ============================================================
# Test 32: run_critic_loop — exact EXECUTE approves
# ============================================================
(
    task_file="$TMP_ROOT/critic-loop-approve-task.md"
    comp_dir="$TMP_ROOT/critic-loop-approve"
    critic_prompt="$TMP_ROOT/critic-loop-approve-critic.md"
    reviser_prompt="$TMP_ROOT/critic-loop-approve-reviser.md"
    mkdir -p "$comp_dir"

    cat > "$task_file" <<'EOF'
## Task: critic-loop-approve
## Status: in progress
## Goal: Verify critic verdict parsing

## Execution Log
EOF
    cat > "$comp_dir/fix-plan.md" <<'EOF'
## Fix Plan
READY: yes
EOF
    printf '# critic\n' > "$critic_prompt"
    printf '# reviser\n' > "$reviser_prompt"

    PROJECT_RULES=""
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    run_agent() {
        local output_file="$5"
        cat > "$output_file" <<'EOF'
## Critique

VERDICT: EXECUTE
EOF
        return 0
    }

    run_critic_loop "$task_file" "$comp_dir" "$critic_prompt" "$reviser_prompt" \
        "$comp_dir/fix-plan.md" "$comp_dir/fix-critique.md" 1 "fix-critic" "needs verification" "claude"

    grep -q 'round 1 approved' "$task_file" || { echo "exact EXECUTE verdict should approve" >&2; exit 1; }
    grep -q '^## Status: in progress$' "$task_file" || { echo "task status should stay in progress on approval" >&2; exit 1; }
) && pass "32. run_critic_loop — exact EXECUTE approves" \
  || fail "32. run_critic_loop — exact EXECUTE approves"

# ============================================================
# Test 33: lauren_loop_competitive — both planners exit 0 with corrupt output hard-fails in Phase 2
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase2-both-corrupt"
    slug="phase2-both-corrupt"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            explorer)
                cat > "$output_file" <<'EOF'
## Exploration Summary
Ready for planning.
EOF
                return 0
                ;;
            planner-a|planner-b)
                : > "$output_file"
                return 0
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    set +e
    lauren_loop_competitive "$slug" "Phase 2 planner corruption"
    rc=$?
    set -e

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    [[ "$rc" -ne 0 ]] || { echo "expected Phase 2 hard-fail" >&2; exit 1; }
    grep -q '^## Status: blocked$' "$task_file" || { echo "task file not blocked after corrupt planners" >&2; exit 1; }
    grep -q 'Phase 2 planner A produced an invalid plan artifact' "$task_file" || {
        echo "missing planner corruption failure message" >&2
        exit 1
    }
) && pass "33. lauren_loop_competitive — both corrupt planners hard-fail Phase 2" \
  || fail "33. lauren_loop_competitive — both corrupt planners hard-fail Phase 2"

# ============================================================
# Test 34: lauren_loop_competitive — crash + corrupt planner still hard-fails in Phase 2
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase2-crash-corrupt"
    slug="phase2-crash-corrupt"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            explorer)
                cat > "$output_file" <<'EOF'
## Exploration Summary
Ready for planning.
EOF
                return 0
                ;;
            planner-a)
                return 17
                ;;
            planner-b)
                : > "$output_file"
                return 0
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    set +e
    lauren_loop_competitive "$slug" "Phase 2 crash plus corrupt planner"
    rc=$?
    set -e

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    [[ "$rc" -ne 0 ]] || { echo "expected Phase 2 hard-fail" >&2; exit 1; }
    grep -q '^## Status: blocked$' "$task_file" || { echo "task file not blocked after crash+corrupt planner" >&2; exit 1; }
    grep -q 'Phase 2 planner B produced an invalid plan artifact' "$task_file" || {
        echo "missing corrupt-planner failure message" >&2
        exit 1
    }
    ! grep -q 'Single plan (plan-' "$task_file" || { echo "single-plan survival should not trigger for crash+corrupt" >&2; exit 1; }
) && pass "34. lauren_loop_competitive — crash plus corrupt planner does not survive" \
  || fail "34. lauren_loop_competitive — crash plus corrupt planner does not survive"

# ============================================================
# Test 35: lauren_loop_competitive — crash + valid planner survives as single-plan path
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase2-single-survival"
    slug="phase2-single-survival"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs
    comp_dir=$(lauren_loop_comp_dir_for_slug "$slug")
    mkdir -p "$comp_dir"

    cat > "$comp_dir/plan-critique.md" <<'EOF'
## Plan Critique

VERDICT: EXECUTE
EOF
    cat > "$comp_dir/execution-diff.patch" <<'EOF'
diff --git a/tmp.txt b/tmp.txt
+phase-4-checkpoint
EOF

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            explorer)
                cat > "$output_file" <<'EOF'
## Exploration Summary
Ready for planning.
EOF
                return 0
                ;;
            planner-a)
                return 23
                ;;
            planner-a-claude-fallback)
                return 99
                ;;
            planner-b)
                write_valid_plan_artifact "$output_file" "Plan B" "Surviving valid plan"
                return 0
                ;;
            reviewer-a*)
                write_task_review_findings "$_CURRENT_TASK_FILE" "PASS"
                return 0
                ;;
            reviewer-b*)
                write_valid_reviewer_b_artifact "$output_file" "PASS" "No findings."
                return 0
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    lauren_loop_competitive "$slug" "Phase 2 single-plan survival"

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    revised_plan="$comp_dir/revised-plan.md"
    grep -q '^## Status: needs verification$' "$task_file" || { echo "single-plan survival should reach needs verification" >&2; exit 1; }
    grep -q 'Single plan (plan-b.md) seeded' "$task_file" || { echo "single-plan seeding log missing" >&2; exit 1; }
    grep -q 'Both reviewers PASS — early consensus' "$task_file" || { echo "review completion log missing" >&2; exit 1; }
    grep -q 'Surviving valid plan' "$revised_plan" || { echo "revised plan was not seeded from surviving plan" >&2; exit 1; }
) && pass "35. lauren_loop_competitive — crash plus valid planner survives via single-plan path" \
  || fail "35. lauren_loop_competitive — crash plus valid planner survives via single-plan path"

# ============================================================
# Test 35b: lauren_loop_competitive — crash plus valid unfenced planner survives via single-plan path
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase2-single-survival-unfenced"
    slug="phase2-single-survival-unfenced"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs
    comp_dir=$(lauren_loop_comp_dir_for_slug "$slug")
    mkdir -p "$comp_dir"
    cat > "$comp_dir/exploration-summary.md" <<'EOF'
## Exploration Summary
Ready for planning.
EOF
    cat > "$comp_dir/plan-critique.md" <<'EOF'
## Plan Critique

VERDICT: EXECUTE
EOF
    cat > "$comp_dir/execution-diff.patch" <<'EOF'
diff --git a/tmp.txt b/tmp.txt
+phase-4-checkpoint
EOF

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            explorer)
                cat > "$output_file" <<'EOF'
## Exploration Summary
Ready for planning.
EOF
                return 0
                ;;
            planner-a)
                return 23
                ;;
            planner-a-claude-fallback)
                return 99
                ;;
            planner-b)
                write_valid_plan_artifact "$output_file" "Plan B" "Surviving unfenced valid plan" "no"
                return 0
                ;;
            reviewer-a*)
                write_task_review_findings "$_CURRENT_TASK_FILE" "PASS"
                return 0
                ;;
            reviewer-b*)
                write_valid_reviewer_b_artifact "$output_file" "PASS" "No findings."
                return 0
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    lauren_loop_competitive "$slug" "Phase 2 single-plan survival without fences"

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    revised_plan="$comp_dir/revised-plan.md"
    grep -q '^## Status: needs verification$' "$task_file" || { echo "unfenced single-plan survival should reach needs verification" >&2; exit 1; }
    grep -q 'Single plan (plan-b.md) seeded' "$task_file" || { echo "single-plan seeding log missing for unfenced plan" >&2; exit 1; }
    grep -q 'Both reviewers PASS — early consensus' "$task_file" || { echo "review completion log missing for unfenced plan" >&2; exit 1; }
    grep -q 'Surviving unfenced valid plan' "$revised_plan" || { echo "revised plan was not seeded from unfenced surviving plan" >&2; exit 1; }
) && pass "35b. lauren_loop_competitive — crash plus valid unfenced planner survives via single-plan path" \
  || fail "35b. lauren_loop_competitive — crash plus valid unfenced planner survives via single-plan path"

# ============================================================
# Test 36: lauren_loop_competitive — phase-7 resume accepts ENGINE_CRITIC empty string without fix-critique.md
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase7-empty-critic"
    slug="phase7-empty-critic"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs
    seed_phase7_resume_artifacts "$slug"
    comp_dir=$(lauren_loop_comp_dir_for_slug "$slug")
    ENGINE_CRITIC=""

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            fix-executor*)
                cat > "$comp_dir/fix-execution.md" <<'EOF'
## Fix Execution
STATUS: COMPLETE
EOF
                return 0
                ;;
            reviewer-a*)
                write_task_review_findings "$_CURRENT_TASK_FILE" "PASS"
                return 0
                ;;
            reviewer-b*)
                write_valid_reviewer_b_artifact "$output_file" "PASS" "No findings."
                return 0
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    lauren_loop_competitive "$slug" "Phase 7 resume without critic artifact"

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    grep -q 'Cycle checkpoint resume: fix_cycle=0, last_completed=phase-6c, resume_to=phase-7' "$task_file" || {
        echo "resume-to-phase-7 log missing for empty ENGINE_CRITIC" >&2
        exit 1
    }
    grep -q '^## Status: needs verification$' "$task_file" || { echo "pipeline should finish after resumed phase-7 path" >&2; exit 1; }
    [[ -f "$comp_dir/fix-execution.md" ]] || { echo "phase-7 fix execution did not run" >&2; exit 1; }
) && pass "36. lauren_loop_competitive — empty ENGINE_CRITIC resumes Phase 7 without fix-critique.md" \
  || fail "36. lauren_loop_competitive — empty ENGINE_CRITIC resumes Phase 7 without fix-critique.md"

# ============================================================
# Test 37: lauren_loop_competitive — phase-7 resume accepts unset ENGINE_CRITIC without fix-critique.md
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase7-unset-critic"
    slug="phase7-unset-critic"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs
    seed_phase7_resume_artifacts "$slug"
    comp_dir=$(lauren_loop_comp_dir_for_slug "$slug")
    unset ENGINE_CRITIC

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            fix-executor*)
                cat > "$comp_dir/fix-execution.md" <<'EOF'
## Fix Execution
STATUS: COMPLETE
EOF
                return 0
                ;;
            reviewer-a*)
                write_task_review_findings "$_CURRENT_TASK_FILE" "PASS"
                return 0
                ;;
            reviewer-b*)
                write_valid_reviewer_b_artifact "$output_file" "PASS" "No findings."
                return 0
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    lauren_loop_competitive "$slug" "Phase 7 resume with critic unset"

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    grep -q 'Cycle checkpoint resume: fix_cycle=0, last_completed=phase-6c, resume_to=phase-7' "$task_file" || {
        echo "resume-to-phase-7 log missing for unset ENGINE_CRITIC" >&2
        exit 1
    }
    grep -q '^## Status: needs verification$' "$task_file" || { echo "pipeline should finish after resumed phase-7 path" >&2; exit 1; }
    [[ -f "$comp_dir/fix-execution.md" ]] || { echo "phase-7 fix execution did not run" >&2; exit 1; }
) && pass "37. lauren_loop_competitive — unset ENGINE_CRITIC resumes Phase 7 without fix-critique.md" \
  || fail "37. lauren_loop_competitive — unset ENGINE_CRITIC resumes Phase 7 without fix-critique.md"

# ============================================================
# Test 38: lauren_loop_competitive — phase-7 resume rejects EXECUTE_WITH_CHANGES and restarts from Phase 5
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase7-execute-with-changes"
    slug="phase7-execute-with-changes"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs
    seed_phase7_resume_artifacts "$slug" "EXECUTE_WITH_CHANGES"
    comp_dir=$(lauren_loop_comp_dir_for_slug "$slug")

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            reviewer-a*)
                write_task_review_findings "$_CURRENT_TASK_FILE" "PASS"
                return 0
                ;;
            reviewer-b*)
                write_valid_reviewer_b_artifact "$output_file" "PASS" "No findings."
                return 0
                ;;
            fix-executor*)
                echo "fix-executor should not run when resume gate rejects EXECUTE_WITH_CHANGES" >&2
                return 98
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    lauren_loop_competitive "$slug" "Phase 7 resume with EXECUTE_WITH_CHANGES"

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    grep -Eq 'WARN: Resume checkpoint invalid for phase-7 \(fix-critique verdict is (EXECUTE_WITH_CHANGES|missing)\); restarting from Phase 5' "$task_file" || {
        echo "invalid resume warning missing for EXECUTE_WITH_CHANGES gate" >&2
        exit 1
    }
    ! grep -q 'Cycle checkpoint resume: fix_cycle=0, last_completed=phase-6c, resume_to=phase-7' "$task_file" || {
        echo "resume-to-phase-7 should not occur for EXECUTE_WITH_CHANGES" >&2
        exit 1
    }
    grep -q 'Phase 5: Review started (cycle 1)' "$task_file" || { echo "pipeline should restart from Phase 5" >&2; exit 1; }
    grep -q '^## Status: needs verification$' "$task_file" || { echo "pipeline should still finish via review PASS path" >&2; exit 1; }
) && pass "38. lauren_loop_competitive — EXECUTE_WITH_CHANGES fails the phase-7 resume gate" \
  || fail "38. lauren_loop_competitive — EXECUTE_WITH_CHANGES fails the phase-7 resume gate"

# ============================================================
# Test 39: lauren_loop_competitive — phase-7 resume accepts exact EXECUTE
# ============================================================
(
    load_lauren_loop_competitive
    runtime_root="$TMP_ROOT/lauren-loop-phase7-execute"
    slug="phase7-execute"
    setup_lauren_loop_runtime "$runtime_root" "$slug"
    install_lauren_loop_test_stubs
    seed_phase7_resume_artifacts "$slug" "EXECUTE"
    comp_dir=$(lauren_loop_comp_dir_for_slug "$slug")

    run_agent() {
        local role="$1" output_file="$5"
        case "$role" in
            fix-executor*)
                cat > "$comp_dir/fix-execution.md" <<'EOF'
## Fix Execution
STATUS: COMPLETE
EOF
                return 0
                ;;
            reviewer-a*)
                write_task_review_findings "$_CURRENT_TASK_FILE" "PASS"
                return 0
                ;;
            reviewer-b*)
                write_valid_reviewer_b_artifact "$output_file" "PASS" "No findings."
                return 0
                ;;
            *)
                echo "unexpected role: $role" >&2
                return 99
                ;;
        esac
    }

    lauren_loop_competitive "$slug" "Phase 7 resume with exact EXECUTE"

    task_file=$(lauren_loop_task_file_for_slug "$slug")
    grep -q 'Cycle checkpoint resume: fix_cycle=0, last_completed=phase-6c, resume_to=phase-7' "$task_file" || {
        echo "resume-to-phase-7 log missing for exact EXECUTE" >&2
        exit 1
    }
    ! grep -q 'Resume checkpoint invalid for phase-7' "$task_file" || { echo "exact EXECUTE should not invalidate checkpoint" >&2; exit 1; }
    grep -q '^## Status: needs verification$' "$task_file" || { echo "pipeline should finish after resumed phase-7 path" >&2; exit 1; }
    [[ -f "$comp_dir/fix-execution.md" ]] || { echo "phase-7 fix execution did not run" >&2; exit 1; }
) && pass "39. lauren_loop_competitive — exact EXECUTE passes the phase-7 resume gate" \
  || fail "39. lauren_loop_competitive — exact EXECUTE passes the phase-7 resume gate"

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

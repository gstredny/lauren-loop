#!/bin/bash
# test_lauren_loop_integration.sh — Full pipeline integration test for lauren_loop_competitive()
# Gap 10: exercises all 7 phases with a mocked run_agent function.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-integ.XXXXXX")"
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

# ============================================================
# Fixture helpers (adapted from test_lauren_loop_logic.sh)
# ============================================================

write_task_fixture() {
    local path="$1"
    cat <<'EOF' > "$path"
## Task: lauren-loop-integ
## Status: in progress
## Goal: Exercise Lauren Loop integration

## Current Plan
Current plan body

## Critique
Critique body

## Review Findings

## Plan History

## Execution Log
EOF
}

write_prompt_fixtures() {
    local root="$1"
    mkdir -p "$root/prompts"
    local prompt
    for prompt in exploration-summarizer planner-a planner-b plan-evaluator critic reviser executor reviewer reviewer-b review-evaluator fix-plan-author fix-executor project-rules; do
        case "$prompt" in
            planner-b|reviewer-b)
                cp "$REPO_ROOT/prompts/${prompt}.md" "$root/prompts/${prompt}.md"
                ;;
            *)
                printf 'placeholder for %s\n' "$prompt" > "$root/prompts/${prompt}.md"
                ;;
        esac
    done
}

write_plan_evaluation_artifact() {
    local path="$1"
    cat <<'EOF' > "$path"
## Evaluation

## Selected Plan

### Goal
Checkpoint plan
EOF
    printf '{"selected_plan_present":true}\n' > "${path%.*}.contract.json"
}

write_valid_plan_artifact() {
    local path="$1" title="${2:-Plan Artifact}" change_label="${3:-Update}"
    cat > "$path" <<EOF
# ${title}

## Files to Modify
- \`src/main.py\` — ${change_label}

## Implementation Tasks

\`\`\`xml
<wave number="1">
  <task type="auto">
    <name>Exercise the planning artifact contract</name>
    <files>src/main.py</files>
    <action>Describe the production change and the test-first order without writing code.</action>
    <verify>bash tests/test_lauren_loop_integration.sh</verify>
    <done>The plan is complete and ready for evaluation.</done>
  </task>
</wave>
\`\`\`

## Testability Design
- Exercise the shell pipeline through \`lauren_loop_competitive\`.

## Test Strategy
- Run the shell regression suite around the pipeline phases.

## Risk Assessment
- Ensure fallback logic does not discard a still-growing valid artifact.

## Dependencies
- None.
EOF
}

write_plan_critique_artifact() {
    local path="$1" verdict="$2"
    cat > "$path" <<EOF
## Critique

## Verdict

VERDICT: ${verdict}
EOF
    printf '{"verdict":"%s"}\n' "$verdict" > "${path%.*}.contract.json"
}

write_review_artifact() {
    local path="$1" verdict="$2" findings="$3"
    cat > "$path" <<EOF
# Review B

**Task:** task.md
**Focus:** Architecture / Structural Integrity
**Scope:** src/main.py

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

write_reviewer_a_section() {
    local task_file="$1" verdict="$2" findings="$3"
    local replacement="$TMP_ROOT/review-findings.$$.txt"
    cat > "$replacement" <<EOF
### Review (Round 1)

**Scope:** src/main.py

**Findings:**

${findings}

**Done-criteria check:**
Not applicable (plan uses numbered steps).

**What was checked:** test branch
**What was NOT checked:** none

**VERDICT: ${verdict}**
safe
EOF
    rewrite_section "$task_file" "## Review Findings" "$replacement"
    rm -f "$replacement"
}

write_review_synthesis_artifact() {
    local path="$1" verdict="$2" critical="$3" major="$4" minor="$5" nit="$6"
    cat > "$path" <<EOF
# Review Synthesis

**Task:** task.md
**Inputs:** competitive/review-a.md, competitive/review-b.md

## Critical Findings

$( [ "$critical" -gt 0 ] && printf -- '- [from: both] [critical/correctness] file:1 - issue\n  -> fix\n' || printf 'None.\n' )

## Major Findings

$( [ "$major" -gt 0 ] && printf -- '- [from: both] [major/correctness] file:2 - issue\n  -> fix\n' || printf 'None.\n' )

## Minor Findings

$( [ "$minor" -gt 0 ] && printf -- '- [from: both] [minor/test] file:3 - issue\n  -> fix\n' || printf 'None.\n' )

## Nit Findings

$( [ "$nit" -gt 0 ] && printf -- '- [from: both] [nit/docs] file:4 - issue\n  -> fix\n' || printf 'None.\n' )

## Discarded or Disputed Reviewer Inputs

None.

## Done-Criteria Summary

Not applicable.

## Summary

- Reviewer A findings kept: 0
- Reviewer B findings kept: 0
- Overlapping findings merged: 0
- Distinct findings forwarded to fix phase: 0

## Verdict

**VERDICT: ${verdict}**
**Rationale:** test artifact
**Next action:** test artifact
EOF
    printf '{"verdict":"%s","critical_count":%s,"major_count":%s,"minor_count":%s,"nit_count":%s}\n' \
        "$verdict" "$critical" "$major" "$minor" "$nit" > "${path%.*}.contract.json"
}

write_fix_plan_artifact() {
    local path="$1" ready="$2"
    local markdown_ready="yes"
    local json_ready="true"
    if [[ "$ready" != "yes" ]]; then
        markdown_ready="no"
        json_ready="false"
    fi
    cat > "$path" <<EOF
# Fix Plan

**Task:** task.md
**Input:** competitive/review-synthesis.md
**Execution log target:** competitive/fix-execution.md

## Execution Order

No fixes required.

## Implementation Tasks

\`\`\`xml
<wave number="1">
</wave>
\`\`\`

## Dispute Candidates

None.

## Ready Gate

**READY: ${markdown_ready}**
**Blocking assumptions:** None
EOF
    printf '{"ready":%s}\n' "$json_ready" > "${path%.*}.contract.json"
}

# ============================================================
# Source shared utils and extract V2 functions
# ============================================================

SCRIPT_DIR="$REPO_ROOT"
SLUG="integ-init"
source "$REPO_ROOT/lib/lauren-loop-utils.sh"

eval "$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

# Restore temp-cleanup trap (eval'd code sets 'trap cleanup_v2 EXIT')
trap 'rm -rf "$TMP_ROOT"' EXIT

declare -f lauren_loop_competitive >/dev/null 2>&1 || {
    echo "FAIL: extraction did not produce lauren_loop_competitive" >&2
    exit 1
}

# ============================================================
# Global stubs — external functions not needed in test context
# ============================================================

release_lock() { :; }
acquire_lock() { :; }
stop_agent_monitor() { :; }
start_agent_monitor() { :; }
notify_terminal_state() { :; }
_print_cost_summary() { :; }
_print_phase_timing() { :; }
setup_azure_context() { :; }
codex54_exec_with_guard() { return 1; }

# ============================================================
# Integration fixture setup
# ============================================================

setup_integration_fixture() {
    local name="$1"
    local root="$TMP_ROOT/$name"
    local slug="integ-${name}"
    local task_dir="$root/docs/tasks/open/$slug"
    mkdir -p "$task_dir/competitive" "$task_dir/logs" "$root/src" "$root/prompts" "$root/bin"
    write_prompt_fixtures "$root"
    write_task_fixture "$task_dir/task.md"
    printf 'baseline content\n' > "$root/src/main.py"
    git -C "$root" init -q
    git -C "$root" config user.name "Integration Tests"
    git -C "$root" config user.email "integ-tests@example.com"
    git -C "$root" add .
    git -C "$root" commit -q -m "Initial fixture"

    # Fail-fast mock claude binary — catches any leaked real agent calls
    cat > "$root/bin/claude" <<'MOCKEOF'
#!/bin/bash
echo "ERROR: mock claude binary invoked — real agent call leaked" >&2
exit 99
MOCKEOF
    chmod +x "$root/bin/claude"

    printf '%s\n' "$root"
}

set_integration_globals() {
    local root="$1"
    export PATH="$root/bin:$PATH"
    SCRIPT_DIR="$root"
    INTERNAL=true
    DRY_RUN=false
    FORCE_RERUN=false
    MODEL="opus"
    LAUREN_LOOP_STRICT=false
    LAUREN_LOOP_MAX_COST=0
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    EXPLORE_TIMEOUT="5s"
    PLANNER_TIMEOUT="5s"
    EVALUATE_TIMEOUT="5s"
    CRITIC_TIMEOUT="5s"
    EXECUTOR_TIMEOUT="5s"
    REVIEWER_TIMEOUT="5s"
    SYNTHESIZE_TIMEOUT="5s"
    SINGLE_REVIEWER_POLICY="synthesis"
}

# ============================================================
# Shared overrides (stubs for functions the pipeline calls)
# ============================================================

set_integration_stubs() {
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n--- a/src/main.py\n+++ b/src/main.py\n@@ -1 +1 @@\n-baseline\n+modified\n' > "$2"; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _init_run_manifest() { :; }
    _append_manifest_phase() { :; }
    _finalize_run_manifest() { :; }
}

# ============================================================
# Mock run_agent infrastructure
# ============================================================

mock_run_agent() {
    local role="$1" engine="$2" prompt_body="$3" system_prompt="$4"
    local output_file="$5" log_file="$6"
    shift 6
    local timeout="${1:-5s}" max_steps="${2:-100}" disallowed="${3:-}"

    printf '%s\n' "$role" >> "$CALL_LOG"

    # Write minimal stream-json to log for cost tracking
    mkdir -p "$(dirname "$log_file")"
    printf '{"type":"assistant","message":{"id":"msg_%s","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}\n' \
        "$role" > "$log_file"

    # Check for configured failure
    if [[ "${MOCK_FAIL_ROLE:-}" == "$role" ]]; then
        return "${MOCK_FAIL_EXIT:-1}"
    fi

    # Create phase-specific artifacts
    local comp_dir="$_COMP_DIR"
    local task_file="$_TASK_FILE"
        case "$role" in
        explorer)
            printf '# Exploration Summary\n\nExploration of test codebase.\n' \
                > "${comp_dir}/exploration-summary.md"
            ;;
        planner-a)
            write_valid_plan_artifact "${comp_dir}/plan-a.md" "Plan A" "Update"
            ;;
        planner-b)
            write_valid_plan_artifact "${comp_dir}/plan-b.md" "Plan B" "Alternative"
            ;;
        evaluator)
            write_plan_evaluation_artifact "${comp_dir}/plan-evaluation.md"
            ;;
        plan-critic-r*)
            write_plan_critique_artifact "${comp_dir}/plan-critique.md" "EXECUTE"
            ;;
        plan-critic-reviser-r*)
            printf '# Revised Plan\n\n## Files to Modify\n\n| File | Change |\n|------|--------|\n| src/main.py | Revised |\n' \
                > "${comp_dir}/revised-plan.md"
            ;;
        executor|fix-executor*)
            # Make real git changes so capture_diff_artifact has something
            printf 'modified by %s\n' "$role" >> "${_FIXTURE_ROOT}/src/main.py"
            (cd "${_FIXTURE_ROOT}" && git add src/main.py && git commit -q -m "$role changes")
            ;;
        reviewer-a*)
            # Pipeline extracts ## Review Findings from task file to reviewer-a.raw.md
            write_reviewer_a_section "$task_file" "PASS" "No issues found."
            ;;
        reviewer-b*)
            # Reviewer B writes directly to its raw file
            write_review_artifact "${comp_dir}/reviewer-b.raw.md" "PASS" "No issues found."
            ;;
        review-evaluator*)
            write_review_synthesis_artifact "${comp_dir}/review-synthesis.md" "PASS" 0 0 0 0
            ;;
        fix-plan-author*)
            write_fix_plan_artifact "${comp_dir}/fix-plan.md" "yes"
            ;;
        fix-critic*-r*)
            write_plan_critique_artifact "${comp_dir}/fix-critique.md" "EXECUTE"
            ;;
    esac
    return 0
}

# ============================================================
# Test 1: Happy path — full pipeline completes all phases
# ============================================================
(
    root="$(setup_integration_fixture "happy-path")"
    slug="integ-happy-path"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    log_dir="$task_dir/logs"
    task_file="$task_dir/task.md"

    CALL_LOG="$TMP_ROOT/happy-path.calls"
    : > "$CALL_LOG"
    _COMP_DIR="$comp_dir"
    _FIXTURE_ROOT="$root"
    _TASK_FILE="$task_file"
    MOCK_FAIL_ROLE=""

    set_integration_stubs
    run_agent() { mock_run_agent "$@"; }

    (cd "$root" && lauren_loop_competitive "$slug" "Test happy path") >/dev/null 2>&1

    # Assert: task status is needs verification
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]

    # Assert: execution-diff.patch exists (from our capture_diff_artifact stub)
    [[ -s "${comp_dir}/execution-diff.patch" ]]

    # Assert: call log contains expected phases
    # Planners run in parallel so order may vary — check membership
    grep -q '^explorer$' "$CALL_LOG"
    grep -q '^planner-a$' "$CALL_LOG"
    grep -q '^planner-b$' "$CALL_LOG"
    grep -q '^evaluator$' "$CALL_LOG"
    grep -q '^plan-critic-r1$' "$CALL_LOG"
    grep -q '^executor$' "$CALL_LOG"
    grep -q '^reviewer-a$' "$CALL_LOG"
    grep -q '^reviewer-b$' "$CALL_LOG"

    # Phase order: explorer must come before planners, executor before reviewers
    explorer_line=$(grep -n '^explorer$' "$CALL_LOG" | head -1 | cut -d: -f1)
    executor_line=$(grep -n '^executor$' "$CALL_LOG" | head -1 | cut -d: -f1)
    reviewer_a_line=$(grep -n '^reviewer-a$' "$CALL_LOG" | head -1 | cut -d: -f1)
    [[ "$explorer_line" -lt "$executor_line" ]]
    [[ "$executor_line" -lt "$reviewer_a_line" ]]
) && pass "1. Happy path — full pipeline completes with correct phase sequence" \
  || fail "1. Happy path — full pipeline completes with correct phase sequence"

# ============================================================
# Test 2: Explorer failure blocks pipeline
# ============================================================
(
    root="$(setup_integration_fixture "explore-fail")"
    slug="integ-explore-fail"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    task_file="$task_dir/task.md"

    CALL_LOG="$TMP_ROOT/explore-fail.calls"
    : > "$CALL_LOG"
    _COMP_DIR="$comp_dir"
    _FIXTURE_ROOT="$root"
    _TASK_FILE="$task_file"
    MOCK_FAIL_ROLE="explorer"
    MOCK_FAIL_EXIT=1

    set_integration_stubs
    run_agent() { mock_run_agent "$@"; }

    set +e
    (cd "$root" && lauren_loop_competitive "$slug" "Test explorer failure") >/dev/null 2>&1
    exit_code=$?
    set -e

    # Assert: non-zero exit
    [[ "$exit_code" -ne 0 ]]

    # Assert: task status is blocked
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "blocked" ]]

    # Assert: call log contains only explorer
    [[ "$(wc -l < "$CALL_LOG")" -eq 1 ]]
    grep -q '^explorer$' "$CALL_LOG"

    # Assert: no plan artifact was created
    [[ ! -f "${comp_dir}/plan-a.md" ]]
) && pass "2. Explorer failure — pipeline halts and sets blocked status" \
  || fail "2. Explorer failure — pipeline halts and sets blocked status"

# ============================================================
# Test 3: Cleanup trap on SIGTERM
# ============================================================
(
    root="$(setup_integration_fixture "sigterm-cleanup")"
    slug="integ-sigterm-cleanup"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    comp_dir="$task_dir/competitive"
    ready_marker="$TMP_ROOT/sigterm.ready"
    child_script="$TMP_ROOT/sigterm-child.sh"

    cat > "$child_script" <<EOF
#!/bin/bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
TMP_ROOT="$TMP_ROOT"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
SLUG="$slug"
source "\$REPO_ROOT/lib/lauren-loop-utils.sh"
SCRIPT_DIR="$root"
eval "\$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "\$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"\$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"\$/d'
)"
declare -f lauren_loop_competitive >/dev/null 2>&1 || { echo "FAIL: extraction broken" >&2; exit 1; }
# Stubs
release_lock() { :; }
acquire_lock() { :; }
stop_agent_monitor() { :; }
start_agent_monitor() { :; }
notify_terminal_state() { :; }
_print_cost_summary() { :; }
_print_phase_timing() { :; }
setup_azure_context() { :; }
codex54_exec_with_guard() { return 1; }
prepare_agent_request() { AGENT_PROMPT_BODY="\$3"; AGENT_SYSTEM_PROMPT=""; }
capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "\$2"; }
_classify_diff_risk() { printf 'LOW\n'; }
_block_on_untracked_files() { return 0; }
_check_cost_ceiling() { return 0; }
_init_run_manifest() { :; }
_append_manifest_phase() { :; }
_finalize_run_manifest() { :; }
INTERNAL=true
DRY_RUN=false
FORCE_RERUN=false
MODEL="opus"
LAUREN_LOOP_STRICT=false
LAUREN_LOOP_MAX_COST=0
ENGINE_EXPLORE="claude"; ENGINE_PLANNER_A="claude"; ENGINE_PLANNER_B="claude"
ENGINE_EVALUATOR="claude"; ENGINE_CRITIC="claude"; ENGINE_EXECUTOR="claude"
ENGINE_REVIEWER_A="claude"; ENGINE_REVIEWER_B="claude"; ENGINE_FIX="claude"
PROJECT_RULES=""
AGENT_SETTINGS='{}'
EXPLORE_TIMEOUT="5s"; PLANNER_TIMEOUT="5s"; EVALUATE_TIMEOUT="5s"
CRITIC_TIMEOUT="5s"; EXECUTOR_TIMEOUT="5s"; REVIEWER_TIMEOUT="5s"
SYNTHESIZE_TIMEOUT="5s"
SINGLE_REVIEWER_POLICY="synthesis"
COMP_DIR="$comp_dir"
TASK_FILE="$task_file"
run_agent() {
    local role="\$1"; shift 5; local log_file="\$1"; shift
    printf '%s\n' "\$role" >> "$TMP_ROOT/sigterm-child.calls"
    mkdir -p "\$(dirname "\$log_file")"
    : > "\$log_file"
        case "\$role" in
        explorer)
            printf '# Exploration Summary\n' > "\$COMP_DIR/exploration-summary.md"
            ;;
        planner-a)
            write_valid_plan_artifact "\$COMP_DIR/plan-a.md" "Plan A" "Update"
            ;;
        planner-b)
            write_valid_plan_artifact "\$COMP_DIR/plan-b.md" "Plan B" "Alt"
            ;;
        evaluator)
            cat > "\$COMP_DIR/plan-evaluation.md" <<'EVALEOF'
## Evaluation

## Selected Plan

### Goal
Checkpoint plan
EVALEOF
            printf '{"selected_plan_present":true}\n' > "\$COMP_DIR/plan-evaluation.contract.json"
            ;;
        plan-critic-r*)
            cat > "\$COMP_DIR/plan-critique.md" <<'CRITEOF'
## Critique

## Verdict

VERDICT: EXECUTE
CRITEOF
            printf '{"verdict":"EXECUTE"}\n' > "\$COMP_DIR/plan-critique.contract.json"
            ;;
        executor)
            # Signal readiness then block
            printf 'ready\n' > "$ready_marker"
            sleep 30
            ;;
    esac
    return 0
}
cd "$root"
lauren_loop_competitive "$slug" "SIGTERM test"
EOF
    chmod +x "$child_script"

    "$child_script" >/dev/null 2>&1 &
    child_pid=$!

    # Wait for the executor phase to start
    for _ in $(seq 1 500); do
        [[ -f "$ready_marker" ]] && break
        sleep 0.01
    done

    if [[ ! -f "$ready_marker" ]]; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        false  # fail the test
    fi

    kill -TERM "$child_pid" 2>/dev/null || true
    set +e
    wait "$child_pid" 2>/dev/null
    child_exit=$?
    set -e

    # Assert: child exited with 143 (128 + 15 = SIGTERM)
    [[ "$child_exit" -eq 143 ]]

    # Assert: task status is blocked (cleanup_v2 safety net fired)
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "blocked" ]]
) && pass "3. Cleanup trap — SIGTERM sets status to blocked (exit 143)" \
  || fail "3. Cleanup trap — SIGTERM sets status to blocked (exit 143)"

# ============================================================
# Test 4: Cost tracking populated
# ============================================================
(
    root="$(setup_integration_fixture "cost-tracking")"
    slug="integ-cost-tracking"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    log_dir="$task_dir/logs"
    task_file="$task_dir/task.md"

    CALL_LOG="$TMP_ROOT/cost-tracking.calls"
    : > "$CALL_LOG"
    _COMP_DIR="$comp_dir"
    _FIXTURE_ROOT="$root"
    _TASK_FILE="$task_file"
    MOCK_FAIL_ROLE=""

    set_integration_stubs
    # Use a run_agent that writes real cost shards
    run_agent() {
        local role="$1" engine="$2" prompt="$3" system_prompt="$4"
        local output_file="$5" log_file="$6"
        shift 6
        local timeout="${1:-5s}" max_steps="${2:-100}" disallowed="${3:-}"

        printf '%s\n' "$role" >> "$CALL_LOG"
        mkdir -p "$(dirname "$log_file")"
        : > "$log_file"

        # Write a cost shard for this role
        local cost_shard="$log_dir/.cost-${role}.csv"
        _ensure_cost_csv_header "$cost_shard"
        printf '%s,%s,%s,claude,opus,n/a,100,0,0,50,0.0012,2,0,completed\n' \
            "$(_iso_timestamp)" "$slug" "$role" >> "$cost_shard"

        # Create phase-specific artifacts
        local comp_dir="$_COMP_DIR"
        local task_file="$_TASK_FILE"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nExploration of test codebase.\n' \
                    > "${comp_dir}/exploration-summary.md"
                ;;
            planner-a)
                write_valid_plan_artifact "${comp_dir}/plan-a.md" "Plan A" "Update"
                ;;
            planner-b)
                write_valid_plan_artifact "${comp_dir}/plan-b.md" "Plan B" "Alternative"
                ;;
            evaluator)
                write_plan_evaluation_artifact "${comp_dir}/plan-evaluation.md"
                ;;
            plan-critic-r*)
                write_plan_critique_artifact "${comp_dir}/plan-critique.md" "EXECUTE"
                ;;
            executor|fix-executor*)
                printf 'modified by %s\n' "$role" >> "${_FIXTURE_ROOT}/src/main.py"
                (cd "${_FIXTURE_ROOT}" && git add src/main.py && git commit -q -m "$role changes")
                ;;
            reviewer-a*)
                write_reviewer_a_section "$task_file" "PASS" "No issues found."
                ;;
            reviewer-b*)
                write_review_artifact "${comp_dir}/reviewer-b.raw.md" "PASS" "No issues found."
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "${comp_dir}/review-synthesis.md" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }

    (cd "$root" && lauren_loop_competitive "$slug" "Test cost tracking") >/dev/null 2>&1

    # Assert: cost.csv exists with header
    cost_csv="$log_dir/cost.csv"
    [[ -f "$cost_csv" ]]
    header=$(head -1 "$cost_csv")
    [[ "$header" == "$COST_CSV_HEADER" ]]

    # Assert: at least one data row
    row_count=$(tail -n +2 "$cost_csv" | awk 'NF { count++ } END { print count+0 }')
    [[ "$row_count" -gt 0 ]]

    # Assert: cost_usd column (field 11) contains numeric values
    tail -n +2 "$cost_csv" | head -1 | awk -F',' '{ if ($11 + 0 > 0) exit 0; else exit 1 }'
) && pass "4. Cost tracking — cost.csv populated with header and data rows" \
  || fail "4. Cost tracking — cost.csv populated with header and data rows"

# ============================================================
# Test 5: Checkpoint resume — executor failure then re-run skips phases 1-3
# ============================================================
(
    root="$(setup_integration_fixture "checkpoint-resume")"
    slug="integ-checkpoint-resume"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    log_dir="$task_dir/logs"
    task_file="$task_dir/task.md"

    CALL_LOG="$TMP_ROOT/checkpoint-resume-a.calls"
    : > "$CALL_LOG"
    _COMP_DIR="$comp_dir"
    _FIXTURE_ROOT="$root"
    _TASK_FILE="$task_file"

    set_integration_stubs

    # Phase A: fail on executor
    MOCK_FAIL_ROLE="executor"
    MOCK_FAIL_EXIT=1
    run_agent() { mock_run_agent "$@"; }

    set +e
    (cd "$root" && lauren_loop_competitive "$slug" "Checkpoint resume test") >/dev/null 2>&1
    exit_a=$?
    set -e

    # Assert Phase A: non-zero exit, status blocked
    [[ "$exit_a" -ne 0 ]]
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "blocked" ]]

    # Assert Phase A: phases 1-3 artifacts exist
    [[ -s "${comp_dir}/exploration-summary.md" ]]
    [[ -s "${comp_dir}/plan-a.md" ]]
    [[ -s "${comp_dir}/revised-plan.md" ]]
    [[ -s "${comp_dir}/plan-critique.md" ]]
    # No execution diff (executor failed before capture)
    [[ ! -s "${comp_dir}/execution-diff.patch" ]]

    # Phase B: re-run with working executor
    CALL_LOG="$TMP_ROOT/checkpoint-resume-b.calls"
    : > "$CALL_LOG"
    MOCK_FAIL_ROLE=""
    MOCK_FAIL_EXIT=""

    (cd "$root" && lauren_loop_competitive "$slug" "Checkpoint resume test") >/dev/null 2>&1

    # Assert Phase B: skipped phases — explorer/planners/evaluator/critic should NOT appear
    ! grep -q '^explorer$' "$CALL_LOG"
    ! grep -q '^planner-a$' "$CALL_LOG"
    ! grep -q '^planner-b$' "$CALL_LOG"
    ! grep -q '^evaluator$' "$CALL_LOG"
    ! grep -q '^plan-critic-r1$' "$CALL_LOG"

    # Assert Phase B: executor and reviewers DID run
    grep -q '^executor$' "$CALL_LOG"
    grep -q '^reviewer-a$' "$CALL_LOG"
    grep -q '^reviewer-b$' "$CALL_LOG"

    # Assert Phase B: final status is needs verification
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]

    # Assert Phase B: execution-diff.patch now exists
    [[ -s "${comp_dir}/execution-diff.patch" ]]
) && pass "5. Checkpoint resume — executor failure + re-run skips completed phases" \
  || fail "5. Checkpoint resume — executor failure + re-run skips completed phases"

# ============================================================
# Test 6: Planner B watcher fallback — pipeline continues with planner A only
# ============================================================
(
    root="$(setup_integration_fixture "planner-b-fallback")"
    slug="integ-planner-b-fallback"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    task_file="$task_dir/task.md"

    set_integration_stubs
    run_agent() {
        local role="$1"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nExploration of test codebase.\n' > "${comp_dir}/exploration-summary.md"
                ;;
            planner-a)
                write_valid_plan_artifact "${comp_dir}/plan-a.md" "Plan A" "Claude survivor"
                ;;
            planner-b)
                printf 'ARTIFACT_WRITTEN\n' > "${comp_dir}/plan-b.md"
                return 65
                ;;
            executor|fix-executor*)
                printf 'modified by %s\n' "$role" >> "${root}/src/main.py"
                (cd "${root}" && git add src/main.py && git commit -q -m "$role changes")
                ;;
            reviewer-a*)
                write_reviewer_a_section "$task_file" "PASS" "No issues found."
                ;;
            reviewer-b*)
                write_review_artifact "${comp_dir}/reviewer-b.raw.md" "PASS" "No findings."
                ;;
            *)
                ;;
        esac
        return 0
    }

    (cd "$root" && lauren_loop_competitive "$slug" "Planner B fallback test") >/dev/null 2>&1

    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]
    grep -q 'Single plan (plan-a.md) seeded' "$task_file"
    grep -q '^ARTIFACT_WRITTEN$' "${comp_dir}/plan-b.md"
    grep -q '^# Plan A$' "${comp_dir}/revised-plan.md"
) && pass "6. Planner B watcher fallback — pipeline continues with planner A only" \
  || fail "6. Planner B watcher fallback — pipeline continues with planner A only"

# ============================================================
# Test 7: Reviewer B watcher fallback — pipeline continues with reviewer A only
# ============================================================
(
    root="$(setup_integration_fixture "reviewer-b-fallback")"
    slug="integ-reviewer-b-fallback"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    task_file="$task_dir/task.md"

    set_integration_stubs
    run_agent() {
        local role="$1"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nExploration of test codebase.\n' > "${comp_dir}/exploration-summary.md"
                ;;
            planner-a)
                write_valid_plan_artifact "${comp_dir}/plan-a.md" "Plan A" "Update"
                ;;
            planner-b)
                write_valid_plan_artifact "${comp_dir}/plan-b.md" "Plan B" "Alternative"
                ;;
            evaluator)
                write_plan_evaluation_artifact "${comp_dir}/plan-evaluation.md"
                ;;
            plan-critic-r*)
                write_plan_critique_artifact "${comp_dir}/plan-critique.md" "EXECUTE"
                ;;
            executor|fix-executor*)
                printf 'modified by %s\n' "$role" >> "${root}/src/main.py"
                (cd "${root}" && git add src/main.py && git commit -q -m "$role changes")
                ;;
            reviewer-a*)
                write_reviewer_a_section "$task_file" "PASS" "No issues found."
                ;;
            reviewer-b*)
                printf 'ARTIFACT_WRITTEN\n' > "${comp_dir}/reviewer-b.raw.md"
                return 65
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "${comp_dir}/review-synthesis.md" "PASS" 0 0 0 0
                ;;
            *)
                ;;
        esac
        return 0
    }

    (cd "$root" && lauren_loop_competitive "$slug" "Reviewer B fallback test") >/dev/null 2>&1

    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]
    grep -q 'review-b=absent' "${comp_dir}/.review-mapping"
    grep -q '^ARTIFACT_WRITTEN$' "${comp_dir}/reviewer-b.raw.md"
) && pass "7. Reviewer B watcher fallback — pipeline continues with reviewer A only" \
  || fail "7. Reviewer B watcher fallback — pipeline continues with reviewer A only"

# ============================================================
# Test 8: Planner B backstop — slow Codex planner is killed after 2x Claude
# ============================================================
(
    root="$(setup_integration_fixture "planner-b-backstop")"
    slug="integ-planner-b-backstop"
    set_integration_globals "$root"
    ENGINE_PLANNER_B="codex"
    PLANNER_TIMEOUT="10s"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    log_dir="$task_dir/logs"
    task_file="$task_dir/task.md"
    kill_marker="$TMP_ROOT/planner-b-backstop.killed"

    set_integration_stubs
    run_agent() {
        local role="$1"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nExploration of test codebase.\n' > "${comp_dir}/exploration-summary.md"
                ;;
            planner-a)
                write_valid_plan_artifact "${comp_dir}/plan-a.md" "Plan A" "Claude survivor"
                sleep 1
                ;;
            planner-b)
                trap 'printf "killed\n" > "'"$kill_marker"'"; exit 143' TERM
                sleep 10
                ;;
            executor|fix-executor*)
                printf 'modified by %s\n' "$role" >> "${root}/src/main.py"
                (cd "${root}" && git add src/main.py && git commit -q -m "$role changes")
                ;;
            reviewer-a*)
                write_reviewer_a_section "$task_file" "PASS" "No issues found."
                ;;
            reviewer-b*)
                write_review_artifact "${comp_dir}/reviewer-b.raw.md" "PASS" "No findings."
                ;;
            *)
                ;;
        esac
        return 0
    }

    start_ts=$(date +%s)
    (cd "$root" && lauren_loop_competitive "$slug" "Planner B backstop test") >/dev/null 2>&1
    duration=$(( $(date +%s) - start_ts ))

    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]
    [[ "$duration" -lt 6 ]]
    [[ -f "$kill_marker" ]]
    grep -q '\[codex-backstop\]' "${log_dir}/planner-b.log"
) && pass "8. Planner B backstop — slow Codex planner is killed after 2x Claude" \
  || fail "8. Planner B backstop — slow Codex planner is killed after 2x Claude"

# ============================================================
# Test 9: Reviewer B backstop — slow Codex reviewer is killed after 2x Claude
# ============================================================
(
    root="$(setup_integration_fixture "reviewer-b-backstop")"
    slug="integ-reviewer-b-backstop"
    set_integration_globals "$root"
    ENGINE_REVIEWER_B="codex"
    REVIEWER_TIMEOUT="10s"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    log_dir="$task_dir/logs"
    task_file="$task_dir/task.md"
    kill_marker="$TMP_ROOT/reviewer-b-backstop.killed"

    set_integration_stubs
    run_agent() {
        local role="$1"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nExploration of test codebase.\n' > "${comp_dir}/exploration-summary.md"
                ;;
            planner-a)
                write_valid_plan_artifact "${comp_dir}/plan-a.md" "Plan A" "Update"
                ;;
            planner-b)
                write_valid_plan_artifact "${comp_dir}/plan-b.md" "Plan B" "Alternative"
                ;;
            evaluator)
                write_plan_evaluation_artifact "${comp_dir}/plan-evaluation.md"
                ;;
            plan-critic-r*)
                write_plan_critique_artifact "${comp_dir}/plan-critique.md" "EXECUTE"
                ;;
            executor|fix-executor*)
                printf 'modified by %s\n' "$role" >> "${root}/src/main.py"
                (cd "${root}" && git add src/main.py && git commit -q -m "$role changes")
                ;;
            reviewer-a*)
                write_reviewer_a_section "$task_file" "PASS" "No issues found."
                sleep 1
                ;;
            reviewer-b*)
                trap 'printf "killed\n" > "'"$kill_marker"'"; exit 143' TERM
                sleep 10
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "${comp_dir}/review-synthesis.md" "PASS" 0 0 0 0
                ;;
            *)
                ;;
        esac
        return 0
    }

    start_ts=$(date +%s)
    (cd "$root" && lauren_loop_competitive "$slug" "Reviewer B backstop test") >/dev/null 2>&1
    duration=$(( $(date +%s) - start_ts ))

    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]
    [[ "$duration" -lt 7 ]]
    [[ -f "$kill_marker" ]]
    grep -q '\[codex-backstop\]' "${log_dir}/reviewer-b.log"
    grep -q 'review-b=absent' "${comp_dir}/.review-mapping"
) && pass "9. Reviewer B backstop — slow Codex reviewer is killed after 2x Claude" \
  || fail "9. Reviewer B backstop — slow Codex reviewer is killed after 2x Claude"

# ============================================================
# Test 10: Claude planner fails — Codex gets full phase timeout, no backstop arms
# ============================================================
(
    root="$(setup_integration_fixture "no-backstop-on-claude-fail")"
    slug="integ-no-backstop-on-claude-fail"
    set_integration_globals "$root"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="codex"
    PLANNER_TIMEOUT="10s"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    log_dir="$task_dir/logs"
    task_file="$task_dir/task.md"

    set_integration_stubs
    run_agent() {
        local role="$1"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nExploration of test codebase.\n' > "${comp_dir}/exploration-summary.md"
                ;;
            planner-a)
                # Claude fails: exit 1 with invalid artifact
                printf 'incomplete garbage\n' > "${comp_dir}/plan-a.md"
                return 1
                ;;
            planner-b)
                # Codex succeeds (simulates needing a couple seconds)
                : > "${log_dir}/planner-b.log"
                sleep 1
                write_valid_plan_artifact "${comp_dir}/plan-b.md" "Plan B" "Codex plan"
                ;;
            evaluator)
                write_plan_evaluation_artifact "${comp_dir}/plan-evaluation.md"
                ;;
            plan-critic-r*)
                write_plan_critique_artifact "${comp_dir}/plan-critique.md" "EXECUTE"
                ;;
            executor|fix-executor*)
                printf 'modified by %s\n' "$role" >> "${root}/src/main.py"
                (cd "${root}" && git add src/main.py && git commit -q -m "$role changes")
                ;;
            reviewer-a*)
                write_reviewer_a_section "$task_file" "PASS" "No issues found."
                ;;
            reviewer-b*)
                write_review_artifact "${comp_dir}/reviewer-b.raw.md" "PASS" "No findings."
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "${comp_dir}/review-synthesis.md" "PASS" 0 0 0 0
                ;;
            *)
                ;;
        esac
        return 0
    }

    (cd "$root" && lauren_loop_competitive "$slug" "No backstop on Claude fail") >/dev/null 2>&1

    # Assert: no backstop log entry for planner-b (Claude failed, so backstop should not arm)
    [[ -f "${log_dir}/planner-b.log" ]]
    ! grep -q '\[codex-backstop\]' "${log_dir}/planner-b.log" || {
        echo "backstop should not have armed when Claude planner failed" >&2; exit 1; }

    # Assert: pipeline completed (Codex plan survived as single-plan path)
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]
) && pass "10. Claude planner fails — Codex gets full timeout, no backstop arms" \
  || fail "10. Claude planner fails — Codex gets full timeout, no backstop arms"

# ============================================================
# Test 10b: review cycle artifacts are snapshotted with cycle-numbered filenames
# ============================================================
(
    root="$(setup_integration_fixture "review-cycle-snapshot")"
    slug="integ-review-cycle-snapshot"
    set_integration_globals "$root"
    task_dir="$root/docs/tasks/open/$slug"
    comp_dir="$task_dir/competitive"
    task_file="$task_dir/task.md"

    set_integration_stubs
    run_agent() {
        local role="$1"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nExploration of test codebase.\n' > "${comp_dir}/exploration-summary.md"
                ;;
            planner-a)
                write_valid_plan_artifact "${comp_dir}/plan-a.md" "Plan A" "Update"
                ;;
            planner-b)
                write_valid_plan_artifact "${comp_dir}/plan-b.md" "Plan B" "Alternative"
                ;;
            evaluator)
                write_plan_evaluation_artifact "${comp_dir}/plan-evaluation.md"
                ;;
            plan-critic-r*)
                write_plan_critique_artifact "${comp_dir}/plan-critique.md" "EXECUTE"
                ;;
            executor|fix-executor*)
                printf 'modified by %s\n' "$role" >> "${root}/src/main.py"
                (cd "${root}" && git add src/main.py && git commit -q -m "$role changes")
                ;;
            reviewer-a*)
                write_reviewer_a_section "$task_file" "PASS" "No issues found."
                ;;
            reviewer-b*)
                write_review_artifact "${comp_dir}/reviewer-b.raw.md" "PASS" "No findings."
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "${comp_dir}/review-synthesis.md" "PASS" 0 0 0 0
                ;;
            *)
                ;;
        esac
        return 0
    }

    (cd "$root" && lauren_loop_competitive "$slug" "Review artifact snapshot test") >/dev/null 2>&1

    [[ -f "${comp_dir}/reviewer-b.raw.cycle1.md" ]]
    [[ -f "${comp_dir}/review-a.cycle1.md" ]]
    [[ -f "${comp_dir}/review-b.cycle1.md" ]]
    [[ -f "${comp_dir}/.review-mapping.cycle1" ]]
    grep -q '^# Review B$' "${comp_dir}/reviewer-b.raw.cycle1.md"
) && pass "10b. review cycle artifacts are snapshotted with cycle-numbered filenames" \
  || fail "10b. review cycle artifacts are snapshotted with cycle-numbered filenames"

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

#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-logic.XXXXXX")"
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

write_task_fixture() {
    local path="$1"
    cat <<'EOF' > "$path"
## Task: lauren-loop-test
## Status: in progress
## Goal: Exercise Lauren Loop logic

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
        printf 'placeholder for %s\n' "$prompt" > "$root/prompts/${prompt}.md"
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
**Scope:** lib/lauren-loop-utils.sh

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

**Scope:** lib/lauren-loop-utils.sh

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

write_reviewer_a_artifacts() {
    local root="$1" slug="$2" verdict="$3" findings="$4"
    local task_file="$root/docs/tasks/open/$slug/task.md"
    local raw_file="$root/docs/tasks/open/$slug/competitive/reviewer-a.raw.md"
    write_reviewer_a_section "$task_file" "$verdict" "$findings"
    write_review_artifact "$raw_file" "$verdict" "$findings"
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

write_fix_execution_artifact() {
    local path="$1" status="$2"
    cat > "$path" <<EOF
# Fix Execution

## Final Status

**STATUS:** ${status}
**Remaining findings:** None
**Follow-up:** None
EOF
    printf '{"status":"%s"}\n' "$status" > "${path%.*}.contract.json"
}

setup_pipeline_fixture() {
    local name="$1" slug="$2"
    local root="$TMP_ROOT/$name"
    local task_dir="$root/docs/tasks/open/$slug"
    mkdir -p "$task_dir/competitive" "$task_dir/logs"
    write_prompt_fixtures "$root"
    write_task_fixture "$task_dir/task.md"
    git -C "$root" init -q
    git -C "$root" config user.name "Lauren Loop Tests"
    git -C "$root" config user.email "lauren-loop-tests@example.com"
    git -C "$root" add .
    git -C "$root" commit -q -m "Initial fixture"
    printf '%s\n' "$root"
}

set_runtime_defaults() {
    EXPLORE_TIMEOUT="1s"
    PLANNER_TIMEOUT="1s"
    EVALUATE_TIMEOUT="1s"
    CRITIC_TIMEOUT="1s"
    EXECUTOR_TIMEOUT="1s"
    REVIEWER_TIMEOUT="1s"
    SYNTHESIZE_TIMEOUT="1s"
    SINGLE_REVIEWER_POLICY="synthesis"
    LAUREN_LOOP_MAX_COST="0"
}

stub_manifest_hooks() {
    _init_run_manifest() { :; }
    _append_manifest_phase() { :; }
    _finalize_run_manifest() { :; }
}

seed_phase4_checkpoints() {
    local root="$1" slug="$2"
    local comp_dir="$root/docs/tasks/open/$slug/competitive"
    printf 'explore summary\n' > "$comp_dir/exploration-summary.md"
    printf 'plan a\n' > "$comp_dir/plan-a.md"
    printf 'plan b\n' > "$comp_dir/plan-b.md"
    printf 'revised plan\n' > "$comp_dir/revised-plan.md"
    write_plan_critique_artifact "$comp_dir/plan-critique.md" "EXECUTE"
    printf 'diff --git a/x b/x\n' > "$comp_dir/execution-diff.patch"
}

source "$REPO_ROOT/lib/lauren-loop-utils.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

# Direct V1 legacy coverage for the dormant planner/critic path.
eval "$(sed -n '/^task_file_stem() {/,/^}/p' "$REPO_ROOT/lauren-loop.sh")"
eval "$(sed -n '/^run_critic() {/,/^}/p' "$REPO_ROOT/lauren-loop.sh")"

(
    [ "$(task_file_stem "docs/tasks/open/my-task/task.md")" = "my-task" ]
    [ "$(task_file_stem "docs/tasks/open/my-task.md")" = "my-task" ]
    [ "$(task_file_stem "docs/tasks/open/pilot-my-task.md")" = "pilot-my-task" ]
) && pass "0. task_file_stem derives slugs for directory-backed, flat, and pilot task paths" \
  || fail "0. task_file_stem derives slugs for directory-backed, flat, and pilot task paths"

(
    root="$TMP_ROOT/v1-critic"
    task_file="$root/task.md"
    mkdir -p "$root/bin" "$root/logs/pilot" "$root/prompts" "$root/competitive"
    write_task_fixture "$task_file"
    printf 'prompt\n' > "$root/prompts/critic.md"

    cat > "$root/bin/claude" <<'EOF'
#!/bin/bash
set -euo pipefail
mkdir -p competitive
case "${CRITIC_TEST_MODE:-missing}" in
    json)
        cat > competitive/plan-critique.md <<'INNER'
## Critique

### Fresh-Eyes Assessment

**1. Goal Coverage:** PASS - ok

## Verdict

VERDICT: EXECUTE
INNER
        printf '{"verdict":"EXECUTE"}\n' > competitive/plan-critique.contract.json
        ;;
    mdonly)
        cat > competitive/plan-critique.md <<'INNER'
## Critique

### Fresh-Eyes Assessment

**1. Goal Coverage:** BLOCKING - stop

## Verdict

VERDICT: BLOCKED - missing dependency
INNER
        ;;
    missing)
        ;;
esac
EOF
    chmod +x "$root/bin/claude"

    SCRIPT_DIR="$root"
    LOG_DIR="$root/logs/pilot"
    SLUG="v1-critic"
    V1_COST_CSV="$LOG_DIR/pilot-${SLUG}-cost.csv"
    CRITIC_TIMEOUT="1s"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    MODEL="opus"
    CRITIC_PROMPT="$root/prompts/critic.md"
    log_signal() { :; }

    export PATH="$root/bin:$PATH"

    export CRITIC_TEST_MODE="json"
    set +e
    (
        cd "$root"
        run_critic "$task_file" 1
    )
    rc_json=$?
    set -e
    [ "$rc_json" -eq 0 ]

    set +e
    export CRITIC_TEST_MODE="mdonly"
    (
        cd "$root"
        run_critic "$task_file" 2
    )
    rc_md=$?
    set -e
    [ "$rc_md" -eq 1 ]

    write_plan_critique_artifact "$root/competitive/plan-critique.md" "EXECUTE"
    set +e
    export CRITIC_TEST_MODE="missing"
    (
        cd "$root"
        run_critic "$task_file" 3
    ) > "$root/missing.out" 2>&1
    rc_missing=$?
    set -e
    [ "$rc_missing" -eq 2 ]
    grep -q "Critic produced no verdict artifact" "$root/missing.out"
    [ ! -f "$root/competitive/plan-critique.md" ]
    [ ! -f "$root/competitive/plan-critique.contract.json" ]
) && pass "1a. run_critic — sidecar contract, markdown fallback, and missing-artifact hard failure" \
  || fail "1a. run_critic — sidecar contract, markdown fallback, and missing-artifact hard failure"

(
    task_file="$TMP_ROOT/critic-success/task.md"
    comp_dir="$TMP_ROOT/critic-success/competitive"
    mkdir -p "$comp_dir" "${TMP_ROOT}/critic-success/logs"
    write_task_fixture "$task_file"
    printf 'plan\n' > "$comp_dir/revised-plan.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-success/critic.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-success/reviser.md"
    TASK_LOG_DIR="${TMP_ROOT}/critic-success/logs"
    CRITIC_TIMEOUT="1s"
    assemble_prompt_for_engine() { printf 'ok\n'; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        if [[ "$role" == "plan-critic-r1" ]]; then
            write_plan_critique_artifact "$output" "EXECUTE"
        fi
        return 0
    }
    run_critic_loop "$task_file" "$comp_dir" "$TMP_ROOT/critic-success/critic.md" "$TMP_ROOT/critic-success/reviser.md" \
        "$comp_dir/revised-plan.md" "$comp_dir/plan-critique.md" 3 "plan-critic" "needs verification" "claude"
) && pass "1. run_critic_loop — approved round 1 returns 0" \
  || fail "1. run_critic_loop — approved round 1 returns 0"

(
    task_file="$TMP_ROOT/critic-max/task.md"
    comp_dir="$TMP_ROOT/critic-max/competitive"
    mkdir -p "$comp_dir" "${TMP_ROOT}/critic-max/logs"
    write_task_fixture "$task_file"
    printf 'plan\n' > "$comp_dir/revised-plan.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-max/critic.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-max/reviser.md"
    TASK_LOG_DIR="${TMP_ROOT}/critic-max/logs"
    CRITIC_TIMEOUT="1s"
    assemble_prompt_for_engine() { printf 'ok\n'; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        case "$role" in
            plan-critic-r*) write_plan_critique_artifact "$output" "BLOCKED" ;;
            plan-critic-reviser-r*) printf 'revised plan\n' > "$output" ;;
        esac
        return 0
    }
    set +e
    run_critic_loop "$task_file" "$comp_dir" "$TMP_ROOT/critic-max/critic.md" "$TMP_ROOT/critic-max/reviser.md" \
        "$comp_dir/revised-plan.md" "$comp_dir/plan-critique.md" 2 "plan-critic" "needs verification" "claude"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q '^## Status: needs verification$' "$task_file"
) && pass "2. run_critic_loop — max rounds returns 1" \
  || fail "2. run_critic_loop — max rounds returns 1"

(
    task_file="$TMP_ROOT/critic-hard/task.md"
    comp_dir="$TMP_ROOT/critic-hard/competitive"
    mkdir -p "$comp_dir" "${TMP_ROOT}/critic-hard/logs"
    write_task_fixture "$task_file"
    printf 'plan\n' > "$comp_dir/revised-plan.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-hard/critic.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-hard/reviser.md"
    TASK_LOG_DIR="${TMP_ROOT}/critic-hard/logs"
    CRITIC_TIMEOUT="1s"
    assemble_prompt_for_engine() { printf 'ok\n'; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    run_agent() {
        local _role="$1" _engine="$2" _body="$3" _system="$4" _output="$5" log_file="$6"
        : > "$log_file"
        return 7
    }
    set +e
    run_critic_loop "$task_file" "$comp_dir" "$TMP_ROOT/critic-hard/critic.md" "$TMP_ROOT/critic-hard/reviser.md" \
        "$comp_dir/revised-plan.md" "$comp_dir/plan-critique.md" 2 "plan-critic" "needs verification" "claude"
    rc=$?
    set -e
    [[ "$rc" -eq 2 ]]
) && pass "3. run_critic_loop — hard failure returns 2" \
  || fail "3. run_critic_loop — hard failure returns 2"

(
    task_file="$TMP_ROOT/critic-inconsistent/task.md"
    comp_dir="$TMP_ROOT/critic-inconsistent/competitive"
    mkdir -p "$comp_dir" "${TMP_ROOT}/critic-inconsistent/logs"
    write_task_fixture "$task_file"
    printf 'plan\n' > "$comp_dir/revised-plan.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-inconsistent/critic.md"
    printf 'prompt\n' > "$TMP_ROOT/critic-inconsistent/reviser.md"
    TASK_LOG_DIR="${TMP_ROOT}/critic-inconsistent/logs"
    CRITIC_TIMEOUT="1s"
    assemble_prompt_for_engine() { printf 'ok\n'; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        if [[ "$role" == "plan-critic-r1" ]]; then
            cat > "$output" <<'EOF'
## Critique
### Fresh-Eyes Assessment
**1. Goal Coverage:** CONCERN - first issue
**2. Constraint Compliance:** CONCERN - second issue

## Verdict
VERDICT: EXECUTE
EOF
            printf '{"verdict":"EXECUTE"}\n' > "${output%.*}.contract.json"
        fi
        return 0
    }
    set +e
    run_critic_loop "$task_file" "$comp_dir" "$TMP_ROOT/critic-inconsistent/critic.md" "$TMP_ROOT/critic-inconsistent/reviser.md" \
        "$comp_dir/revised-plan.md" "$comp_dir/plan-critique.md" 2 "plan-critic" "needs verification" "claude"
    rc=$?
    set -e
    [[ "$rc" -eq 2 ]]
) && pass "4. run_critic_loop — inconsistent EXECUTE verdict returns 2" \
  || fail "4. run_critic_loop — inconsistent EXECUTE verdict returns 2"

(
    file="$TMP_ROOT/archive/revised-plan.md"
    mkdir -p "$(dirname "$file")"
    printf 'plan\n' > "$file"
    first="$(_archive_round_artifact "$file" 1)"
    [[ "$first" == *"/revised-plan-r1.md" ]]
    printf 'older\n' > "$first"
    second="$(_archive_round_artifact "$file" 1)"
    [[ "$second" == *"/revised-plan-r1-dup2.md" ]]
) && pass "5. _archive_round_artifact — duplicate naming" \
  || fail "5. _archive_round_artifact — duplicate naming"

(
    lock_dir="$TMP_ROOT/lock-contention.d"
    child="$TMP_ROOT/lock-holder.sh"
    cat > "$child" <<EOF
#!/bin/bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
source "\$REPO_ROOT/lib/lauren-loop-utils.sh"
SCRIPT_DIR="\$REPO_ROOT"
eval "\$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "\$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"
MODEL="opus"
LOCK_DIR="$lock_dir"
INTERNAL=false
_LOCK_ACQUIRED=false
acquire_lock
printf 'ready\n' > "$TMP_ROOT/lock.ready"
sleep 3
release_lock
EOF
    chmod +x "$child"
    "$child" &
    child_pid=$!
    for _ in $(seq 1 100); do
        [[ -f "$TMP_ROOT/lock.ready" ]] && break
        sleep 0.05
    done
    LOCK_DIR="$lock_dir"
    INTERNAL=false
    _LOCK_ACQUIRED=false
    set +e
    acquire_lock >/dev/null 2>&1
    rc=$?
    set -e
    wait "$child_pid"
    [[ "$rc" -ne 0 ]]
) && pass "5. acquire_lock — second process fails on contention" \
  || fail "5. acquire_lock — second process fails on contention"

(
    TASK_LOG_DIR="$TMP_ROOT/cost-merge"
    mkdir -p "$TASK_LOG_DIR"
    printf '%s\n' "$COST_CSV_HEADER" > "$TASK_LOG_DIR/cost.csv"
    printf '%s\n' "$COST_CSV_HEADER" > "$TASK_LOG_DIR/.cost-a.csv"
    printf '%s\n' "$COST_CSV_HEADER" > "$TASK_LOG_DIR/.cost-b.csv"
    printf '2026-03-09T00:00:00+0000,test,planner-a,claude,opus,n/a,1,0,0,1,0.0001,1,0,completed\n' >> "$TASK_LOG_DIR/.cost-a.csv"
    printf '2026-03-09T00:00:01+0000,test,planner-b,codex,gpt-5.4,medium,1,0,0,1,0.0001,1,0,completed\n' >> "$TASK_LOG_DIR/.cost-b.csv"
    _merge_cost_csvs
    [[ "$(head -1 "$TASK_LOG_DIR/cost.csv")" == "$COST_CSV_HEADER" ]]
    [[ "$(awk 'END { print NR }' "$TASK_LOG_DIR/cost.csv")" -eq 3 ]]
    awk -F',' 'NR > 1 && NF != 14 { exit 1 }' "$TASK_LOG_DIR/cost.csv"
) && pass "6. _merge_cost_csvs — merged CSV keeps 14-column integrity" \
  || fail "6. _merge_cost_csvs — merged CSV keeps 14-column integrity"

(
    slug="single-review-a"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    REVIEW_A_MODE="present"
    REVIEW_B_MODE="absent"
    REVIEW_SYNTHESIS_VERDICT="PASS"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        printf '%s\n' "$role" >> "$ROLE_LOG"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b*)
                return 1
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "$REVIEW_SYNTHESIS_VERDICT" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "single reviewer survives"
    )
    grep -q 'Phase 5: Single reviewer — continuing to synthesis' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q '"verdict":"PASS"' "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.contract.json"
) && pass "7. single reviewer survival — A only routes to synthesis in non-strict mode" \
  || fail "7. single reviewer survival — A only routes to synthesis in non-strict mode"

(
    slug="single-review-b"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=true
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    REVIEW_A_MODE="absent"
    REVIEW_B_MODE="present"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        printf '%s\n' "$role" >> "$ROLE_LOG"
        case "$role" in
            reviewer-a*)
                return 1
                ;;
            reviewer-b*)
                write_review_artifact "$output" "PASS" "No findings."
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "strict single reviewer halt"
    )
    handoff="$fixture_root/docs/tasks/open/$slug/competitive/human-review-handoff.md"
    [[ -f "$handoff" ]]
    grep -q 'Final review verdict: SINGLE_REVIEWER' "$handoff"
    ! grep -q 'review-evaluator' "$ROLE_LOG"
) && pass "8. strict single reviewer — halts and writes human handoff" \
  || fail "8. strict single reviewer — halts and writes human handoff"

(
    slug="dual-pass-fastpath"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b*)
                write_review_artifact "$output" "PASS" "No findings."
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "dual pass fast path"
    )
    grep -q 'Both reviewers PASS — early consensus' "$fixture_root/docs/tasks/open/$slug/task.md"
    [[ ! -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
) && pass "9. dual PASS with zero findings — fast paths before synthesis" \
  || fail "9. dual PASS with zero findings — fast paths before synthesis"

(
    slug="dual-pass-critical"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_EVALUATOR="claude"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "[critical/correctness] file:1 - critical issue
-> fix"
                ;;
            reviewer-b*)
                write_review_artifact "$output" "PASS" "No findings."
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "dual pass with critical finding"
    )
    grep -q 'Dual-PASS overridden: critical/major findings' "$fixture_root/docs/tasks/open/$slug/task.md"
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
) && pass "10. dual PASS with critical findings — does not fast path" \
  || fail "10. dual PASS with critical findings — does not fast path"

(
    run_case() {
        local name="$1" force_flag="$2"
        local slug="$name"
        local fixture_root
        fixture_root="$(setup_pipeline_fixture "$name" "$slug")"
        seed_phase4_checkpoints "$fixture_root" "$slug"
        local role_log="$TMP_ROOT/${name}.roles"
        : > "$role_log"
        SCRIPT_DIR="$fixture_root"
        MODEL="opus"
        PROJECT_RULES=""
        AGENT_SETTINGS='{}'
        set_runtime_defaults
        stub_manifest_hooks
        FORCE_RERUN="$force_flag"
        LAUREN_LOOP_STRICT=false
        ENGINE_EXPLORE="claude"
        ENGINE_PLANNER_A="claude"
        ENGINE_PLANNER_B="claude"
        ENGINE_EVALUATOR="claude"
        ENGINE_CRITIC="claude"
        ENGINE_EXECUTOR="claude"
        ENGINE_REVIEWER_A="claude"
        ENGINE_REVIEWER_B="claude"
        prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
        start_agent_monitor() { :; }
        stop_agent_monitor() { :; }
        capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
        check_diff_scope() { return 0; }
        _classify_diff_risk() { printf 'LOW\n'; }
        _block_on_untracked_files() { return 0; }
        _check_cost_ceiling() { return 0; }
        _print_cost_summary() { :; }
        _print_phase_timing() { :; }
        run_agent() {
            local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
            : > "$log_file"
            printf '%s\n' "$role" >> "$role_log"
            case "$role" in
                explorer) printf 'exploration\n' > "$output" ;;
                planner-a|planner-b) printf 'plan\n' > "$output" ;;
                evaluator)
                    case "$output" in
                        */plan-evaluation.md) write_plan_evaluation_artifact "$output" ;;
                        */review-synthesis.md) write_review_synthesis_artifact "$output" "PASS" 0 0 0 0 ;;
                        */fix-plan.md) write_fix_plan_artifact "$output" "yes" ;;
                    esac
                    ;;
                plan-critic-r*|fix-critic-r*) write_plan_critique_artifact "$output" "EXECUTE" ;;
                reviewer-a*)
                    write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                    ;;
                reviewer-b*) write_review_artifact "$output" "PASS" "No findings." ;;
            esac
            return 0
        }
        (
            cd "$fixture_root"
            lauren_loop_competitive "$slug" "checkpoint behavior" >/dev/null
        )
        printf '%s\n' "$role_log"
    }

    nonforce_log="$(run_case checkpoint-nonforce false)"
    force_log="$(run_case checkpoint-force true)"
    ! grep -q '^explorer$' "$nonforce_log"
    grep -q '^explorer$' "$force_log"
) && pass "11. checkpoint skip behavior — non-force skips and force reruns" \
  || fail "11. checkpoint skip behavior — non-force skips and force reruns"

(
    slug="cycle-resume"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    write_review_synthesis_artifact "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" "FAIL" 0 1 0 0
    write_fix_plan_artifact "$fixture_root/docs/tasks/open/$slug/competitive/fix-plan.md" "yes"
    _write_cycle_state "$fixture_root/docs/tasks/open/$slug/competitive" 0 "phase-6b" "FAIL"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_CRITIC="claude"
    ENGINE_FIX="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        printf '%s\n' "$role" >> "$ROLE_LOG"
        case "$role" in
            fix-critic-r*) write_plan_critique_artifact "$output" "EXECUTE" ;;
            fix-executor*) write_fix_execution_artifact "$SCRIPT_DIR/docs/tasks/open/$slug/competitive/fix-execution.md" "COMPLETE" ;;
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b*) write_review_artifact "$output" "PASS" "No findings." ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "resume from cycle state"
    )
    grep -q 'Cycle checkpoint resume:' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q '^fix-critic-r1$' "$ROLE_LOG"
) && pass "12. cycle state resume — resumes into later subphase" \
  || fail "12. cycle state resume — resumes into later subphase"

# Use the documented zero-cost sentinel here; an empty value is now
# legitimately repopulated by `.lauren-loop.conf` during V2 startup.
(
    set +e
    output="$(LAUREN_LOOP_MAX_COST=0 bash "$REPO_ROOT/lauren-loop-v2.sh" strict-live "strict live" --strict 2>&1)"
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]]
    echo "$output" | grep -q 'Strict mode requires LAUREN_LOOP_MAX_COST'
) && pass "13. strict mode — live run requires cost ceiling" \
  || fail "13. strict mode — live run requires cost ceiling"

(
    set +e
    output="$(LAUREN_LOOP_MAX_COST=0 bash "$REPO_ROOT/lauren-loop-v2.sh" strict-dry "strict dry run" --strict --dry-run 2>&1)"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    echo "$output" | grep -q 'Strict:  true'
) && pass "14. strict mode — dry run does not require cost ceiling" \
  || fail "14. strict mode — dry run does not require cost ceiling"

(
    slug="strict-dual-pass"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=true
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        printf '%s\n' "$role" >> "$ROLE_LOG"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b*)
                write_review_artifact "$output" "PASS" "No findings."
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "strict dual pass forces synthesis"
    )
    grep -q 'review-evaluator' "$ROLE_LOG"
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
) && pass "15. strict dual-PASS fast-path disable — synthesis forced" \
  || fail "15. strict dual-PASS fast-path disable — synthesis forced"

(
    slug="strict-empty-diff"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=true
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { : > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        printf '%s\n' "$role" >> "$ROLE_LOG"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            reviewer-b*)
                write_review_artifact "$output" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "FAIL" 0 1 0 0
                ;;
            fix-plan-author*)
                write_fix_plan_artifact "$output" "yes"
                ;;
            fix-critic-r*)
                write_plan_critique_artifact "$output" "EXECUTE"
                ;;
            fix-executor*)
                write_fix_execution_artifact "$SCRIPT_DIR/docs/tasks/open/$slug/competitive/fix-execution.md" "COMPLETE"
                ;;
        esac
        return 0
    }
    set +e
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "strict empty diff blocks"
    )
    rc=$?
    set -e
    grep -q '## Status: blocked' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "16. strict empty-fix-diff hard block" \
  || fail "16. strict empty-fix-diff hard block"

(
    slug="strict-ready-maybe"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=true
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            reviewer-b*)
                write_review_artifact "$output" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "FAIL" 0 1 0 0
                ;;
            fix-plan-author*)
                # Write fix-plan with ambiguous ready=maybe
                cat > "$output" <<FIXEOF
# Fix Plan
## Ready Gate
**READY: maybe**
FIXEOF
                printf '{"ready":"maybe"}\n' > "${output%.*}.contract.json"
                ;;
        esac
        return 0
    }
    set +e
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "strict ready maybe blocks"
    )
    rc=$?
    set -e
    grep -q '## Status: blocked' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q 'Strict contract failure for fix-plan ready' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "17. strict fix-plan ready validation — ambiguous 'maybe' blocks" \
  || fail "17. strict fix-plan ready validation — ambiguous 'maybe' blocks"

(
    slug="strict-status-partial"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=true
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    prepare_agent_request() { AGENT_PROMPT_BODY="$3"; AGENT_SYSTEM_PROMPT=""; }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            reviewer-b*)
                write_review_artifact "$output" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "FAIL" 0 1 0 0
                ;;
            fix-plan-author*)
                write_fix_plan_artifact "$output" "yes"
                ;;
            fix-critic-r*)
                write_plan_critique_artifact "$output" "EXECUTE"
                ;;
            fix-executor*)
                write_fix_execution_artifact "$SCRIPT_DIR/docs/tasks/open/$slug/competitive/fix-execution.md" "PARTIAL"
                ;;
        esac
        return 0
    }
    set +e
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "strict status partial blocks"
    )
    rc=$?
    set -e
    grep -q '## Status: blocked' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q 'Strict contract failure for fix-execution status' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "18. strict fix-execution status validation — ambiguous 'PARTIAL' blocks" \
  || fail "18. strict fix-execution status validation — ambiguous 'PARTIAL' blocks"

(
    task_file="$TMP_ROOT/review-no-exec-log/task.md"
    mkdir -p "$TMP_ROOT/review-no-exec-log"
    cat > "$task_file" <<'EOF'
## Task: test-task
## Status: in progress
## Goal: Test ensure_review_sections without Execution Log

## Current Plan
Plan body
EOF
    set +e
    ensure_review_sections "$task_file" 2>/dev/null
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    grep -q '^## Execution Log$' "$task_file"
) && pass "19. ensure_review_sections — creates missing Execution Log instead of hard error" \
  || fail "19. ensure_review_sections — creates missing Execution Log instead of hard error"

(
    task_file="$TMP_ROOT/mirror-no-plan/task.md"
    mkdir -p "$TMP_ROOT/mirror-no-plan"
    cat > "$task_file" <<'EOF'
## Task: test-task
## Status: in progress
## Goal: Test mirror after ensure_sections
EOF
    ensure_sections "$task_file"
    plan_file="$TMP_ROOT/mirror-no-plan/plan.md"
    cat > "$plan_file" <<'EOF'
### Goal
The mirrored plan goal

### Steps
1. Do the thing
EOF
    set +e
    mirror_plan_into_task_file "$task_file" "$plan_file"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    grep -q 'The mirrored plan goal' "$task_file"
) && pass "20. mirror_plan_into_task_file — succeeds on task with no pre-existing Current Plan after ensure_sections" \
  || fail "20. mirror_plan_into_task_file — succeeds on task with no pre-existing Current Plan after ensure_sections"

# Gap 8: Config-driven project values
(
    conf_root="$(mktemp -d "$TMP_ROOT/conf-test.XXXXXX")"
    cat > "$conf_root/.lauren-loop.conf" <<'EOF'
PROJECT_NAME="TestProject"
TEST_CMD="python -m pytest"
LINT_CMD="python -m flake8"
EOF
    source "$conf_root/.lauren-loop.conf"
    PROJECT_NAME="${PROJECT_NAME:-$(basename "${LAUREN_LOOP_PROJECT_DIR:-$SCRIPT_DIR}")}"
    TEST_CMD="${TEST_CMD:-pytest tests/ -x -q}"
    LINT_CMD="${LINT_CMD:-flake8 src/ --count --select=E9,F63,F7,F82 --show-source --statistics}"
    [ "$PROJECT_NAME" = "TestProject" ]
    [ "$TEST_CMD" = "python -m pytest" ]
    [ "$LINT_CMD" = "python -m flake8" ]
) && pass "21. conf custom PROJECT_NAME/TEST_CMD/LINT_CMD override defaults" \
  || fail "21. conf custom PROJECT_NAME/TEST_CMD/LINT_CMD override defaults"

(
    PROJECT_NAME="" TEST_CMD="" LINT_CMD=""
    PROJECT_NAME="${PROJECT_NAME:-$(basename "${LAUREN_LOOP_PROJECT_DIR:-$SCRIPT_DIR}")}"
    TEST_CMD="${TEST_CMD:-pytest tests/ -x -q}"
    LINT_CMD="${LINT_CMD:-flake8 src/ --count --select=E9,F63,F7,F82 --show-source --statistics}"
    [ -n "$PROJECT_NAME" ]
    [ "$TEST_CMD" = "pytest tests/ -x -q" ]
) && pass "22. fallback defaults work when conf doesn't set PROJECT_NAME" \
  || fail "22. fallback defaults work when conf doesn't set PROJECT_NAME"

# Gap 2: V1 fix→review diff handoff
(
    dir="$TMP_ROOT/gap2-fix-exists"
    mkdir -p "$dir"
    SLUG="test-task"
    LOG_DIR="$dir"
    # Create both diffs — fix diff should be preferred
    echo "execution diff content" > "$dir/pilot-${SLUG}-diff.patch"
    echo "fix diff content" > "$dir/pilot-${SLUG}-fix-diff.patch"
    FIX_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-fix-diff.patch"
    EXEC_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-diff.patch"
    if [ -f "$FIX_DIFF_FILE" ]; then
        DIFF_FILE="$FIX_DIFF_FILE"
        REVIEW_CONTEXT="post-fix"
    elif [ -f "$EXEC_DIFF_FILE" ]; then
        DIFF_FILE="$EXEC_DIFF_FILE"
        REVIEW_CONTEXT="execution"
    fi
    [ "$DIFF_FILE" = "$FIX_DIFF_FILE" ]
    [ "$REVIEW_CONTEXT" = "post-fix" ]
) && pass "23. Gap 2: fix diff exists — review prefers it over execution diff" \
  || fail "23. Gap 2: fix diff exists — review prefers it over execution diff"

(
    dir="$TMP_ROOT/gap2-exec-only"
    mkdir -p "$dir"
    SLUG="test-task"
    LOG_DIR="$dir"
    # Only execution diff exists
    echo "execution diff content" > "$dir/pilot-${SLUG}-diff.patch"
    FIX_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-fix-diff.patch"
    EXEC_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-diff.patch"
    if [ -f "$FIX_DIFF_FILE" ]; then
        DIFF_FILE="$FIX_DIFF_FILE"
        REVIEW_CONTEXT="post-fix"
    elif [ -f "$EXEC_DIFF_FILE" ]; then
        DIFF_FILE="$EXEC_DIFF_FILE"
        REVIEW_CONTEXT="execution"
    fi
    [ "$DIFF_FILE" = "$EXEC_DIFF_FILE" ]
    [ "$REVIEW_CONTEXT" = "execution" ]
) && pass "24. Gap 2: only execution diff exists — review uses it (regression)" \
  || fail "24. Gap 2: only execution diff exists — review uses it (regression)"

(
    dir="$TMP_ROOT/gap2-neither"
    mkdir -p "$dir"
    SLUG="test-task"
    LOG_DIR="$dir"
    FIX_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-fix-diff.patch"
    EXEC_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-diff.patch"
    DIFF_FILE=""
    if [ -f "$FIX_DIFF_FILE" ]; then
        DIFF_FILE="$FIX_DIFF_FILE"
    elif [ -f "$EXEC_DIFF_FILE" ]; then
        DIFF_FILE="$EXEC_DIFF_FILE"
    fi
    [ -z "$DIFF_FILE" ]
) && pass "25. Gap 2: neither diff exists — no file selected (error path)" \
  || fail "25. Gap 2: neither diff exists — no file selected (error path)"

# Gap 6: _is_terminal_status
(
    _is_terminal_status "needs verification"
) && pass "26. Gap 6: 'needs verification' is terminal" \
  || fail "26. Gap 6: 'needs verification' is terminal"

(
    ! _is_terminal_status "executing"
) && pass "27. Gap 6: 'executing' is NOT terminal" \
  || fail "27. Gap 6: 'executing' is NOT terminal"

(
    ! _is_terminal_status "in progress"
) && pass "28. Gap 6: 'in progress' is NOT terminal" \
  || fail "28. Gap 6: 'in progress' is NOT terminal"

(
    _is_terminal_status "blocked"
) && pass "29. Gap 6: 'blocked' is terminal" \
  || fail "29. Gap 6: 'blocked' is terminal"

(
    _is_terminal_status "review-failed"
) && pass "30. Gap 6: 'review-failed' is terminal (wildcard)" \
  || fail "30. Gap 6: 'review-failed' is terminal (wildcard)"

(
    _is_terminal_status "execution-blocked"
) && pass "31. Gap 6: 'execution-blocked' is terminal (wildcard)" \
  || fail "31. Gap 6: 'execution-blocked' is terminal (wildcard)"

(
    _is_terminal_status "not started"
) && pass "32. Gap 6: 'not started' is terminal" \
  || fail "32. Gap 6: 'not started' is terminal"

(
    _is_terminal_status "paused"
) && pass "33. Gap 6: 'paused' is terminal" \
  || fail "33. Gap 6: 'paused' is terminal"

# Gap 4: pick cache parser diagnostics
(
    PICK_TEMP="$TMP_ROOT/gap4-primary.txt"
    cat > "$PICK_TEMP" <<'PICKEOF'
Ranking explanation here.

## TASK_LIST
1|task-a.md|Goal A|Low
2|task-b.md|Goal B|High
PICKEOF
    _PICK_PARSER_TIER=""
    TASK_LINES=""
    if grep -q '^## TASK_LIST' "$PICK_TEMP"; then
        TASK_LINES=$(sed -n '/^## TASK_LIST/,$ { /^## TASK_LIST/d; p; }' "$PICK_TEMP" \
            | sed '/^[[:space:]]*$/d' \
            | grep -E '^[0-9]+\|.+\|.+\|.+$' || true)
    fi
    [ -n "$TASK_LINES" ] && _PICK_PARSER_TIER="primary"
    [ "$_PICK_PARSER_TIER" = "primary" ]
) && pass "34. Gap 4: primary parser tier detected" \
  || fail "34. Gap 4: primary parser tier detected"

(
    PICK_TEMP="$TMP_ROOT/gap4-bold-bracket.txt"
    cat > "$PICK_TEMP" <<'PICKEOF'
**1. [task-a.md]** — Goal A
**2. [task-b.md]** — Goal B
PICKEOF
    _PICK_PARSER_TIER=""
    TASK_LINES=""
    if grep -q '^## TASK_LIST' "$PICK_TEMP"; then
        TASK_LINES=$(sed -n '/^## TASK_LIST/,$ { /^## TASK_LIST/d; p; }' "$PICK_TEMP" \
            | sed '/^[[:space:]]*$/d' \
            | grep -E '^[0-9]+\|.+\|.+\|.+$' || true)
    fi
    [ -n "$TASK_LINES" ] && _PICK_PARSER_TIER="primary"
    if [ -z "$TASK_LINES" ]; then
        TASK_LINES=$(grep -oE '\*\*[0-9]+\. \[([^]]+)\]\*\* — (.+)' "$PICK_TEMP" \
            | sed -E 's/\*\*([0-9]+)\. \[([^]]+)\]\*\* — (.*)/\1|\2|\3|Unknown/' || true)
        [ -n "$TASK_LINES" ] && _PICK_PARSER_TIER="bold-bracket"
    fi
    [ "$_PICK_PARSER_TIER" = "bold-bracket" ]
) && pass "35. Gap 4: bold-bracket fallback parser tier detected" \
  || fail "35. Gap 4: bold-bracket fallback parser tier detected"

(
    PICK_TEMP="$TMP_ROOT/gap4-bold-plain.txt"
    cat > "$PICK_TEMP" <<'PICKEOF'
**1. task-a.md** — Goal A
**2. task-b.md** — Goal B
PICKEOF
    _PICK_PARSER_TIER=""
    TASK_LINES=""
    if grep -q '^## TASK_LIST' "$PICK_TEMP"; then
        TASK_LINES=$(sed -n '/^## TASK_LIST/,$ { /^## TASK_LIST/d; p; }' "$PICK_TEMP" \
            | sed '/^[[:space:]]*$/d' \
            | grep -E '^[0-9]+\|.+\|.+\|.+$' || true)
    fi
    [ -n "$TASK_LINES" ] && _PICK_PARSER_TIER="primary"
    if [ -z "$TASK_LINES" ]; then
        TASK_LINES=$(grep -oE '\*\*[0-9]+\. \[([^]]+)\]\*\* — (.+)' "$PICK_TEMP" \
            | sed -E 's/\*\*([0-9]+)\. \[([^]]+)\]\*\* — (.*)/\1|\2|\3|Unknown/' || true)
        [ -n "$TASK_LINES" ] && _PICK_PARSER_TIER="bold-bracket"
    fi
    if [ -z "$TASK_LINES" ]; then
        TASK_LINES=$(grep -oE '\*\*[0-9]+\. [^*]+\*\* — .+' "$PICK_TEMP" \
            | sed -E 's/\*\*([0-9]+)\. ([^*]+)\*\* — (.*)/\1|\2|\3|Unknown/' || true)
        [ -n "$TASK_LINES" ] && _PICK_PARSER_TIER="bold-plain"
    fi
    [ "$_PICK_PARSER_TIER" = "bold-plain" ]
) && pass "36. Gap 4: bold-plain fallback parser tier detected" \
  || fail "36. Gap 4: bold-plain fallback parser tier detected"

# Gap 9: Cross-version lock awareness
(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    echo "$$" > "$lock_dir/pid"
    echo "my-task" > "$lock_dir/slug"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 1 ]
) && pass "37. Gap 9: cross-lock warns when V2 holds same slug (returns 1)" \
  || fail "37. Gap 9: cross-lock warns when V2 holds same slug (returns 1)"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    echo "$$" > "$lock_dir/pid"
    echo "other-task" > "$lock_dir/slug"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "38. Gap 9: cross-lock silent when V2 holds different slug (returns 0)" \
  || fail "38. Gap 9: cross-lock silent when V2 holds different slug (returns 0)"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    dead_pid=$(bash -c 'echo $$')
    echo "$dead_pid" > "$lock_dir/pid"
    echo "my-task" > "$lock_dir/slug"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "39. Gap 9: cross-lock ignores dead PID (returns 0)" \
  || fail "39. Gap 9: cross-lock ignores dead PID (returns 0)"

(
    lock_dir="$TMP_ROOT/v2lock-nonexistent"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "40. Gap 9: cross-lock returns 0 when no lock dir exists" \
  || fail "40. Gap 9: cross-lock returns 0 when no lock dir exists"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    echo "$$" > "$lock_dir/pid"
    # No slug file written
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "41. Gap 9: cross-lock returns 0 when PID alive but no slug file" \
  || fail "41. Gap 9: cross-lock returns 0 when PID alive but no slug file"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

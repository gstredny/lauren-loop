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
    [ -n "${2:-}" ] && echo "  Detail: $2" || true
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
    for prompt in exploration-summarizer planner-a planner-b plan-evaluator critic reviser executor scope-triage reviewer reviewer-b review-evaluator fix-plan-author fix-executor final-verifier final-falsifier final-fixer project-rules; do
        case "$prompt" in
            planner-b|reviewer-b|executor)
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
    local path="$1" title="${2:-Plan Artifact}" change_label="${3:-Update}" fenced="${4:-yes}"
    local open_fence="" close_fence=""
    if [[ "$fenced" != "no" ]]; then
        open_fence='```xml'
        close_fence='```'
    fi
    cat > "$path" <<EOF
# ${title}

## Files to Modify
- \`src/main.py\` — ${change_label}

## Implementation Tasks

${open_fence}
<wave number="1">
  <task type="auto">
    <name>Exercise checkpoint plan validity</name>
    <files>src/main.py</files>
    <action>Describe the test-first change without writing code.</action>
    <verify>bash tests/test_lauren_loop_logic.sh</verify>
    <done>The plan is valid for resume-path checks.</done>
  </task>
</wave>
${close_fence}

## Testability Design
- Exercise the checkpointed pipeline through \`lauren_loop_competitive\`.

## Test Strategy
- Run the Lauren Loop shell tests that use checkpointed plan artifacts.

## Risk Assessment
- Keep checkpoint validation aligned with the live planner contract.

## Dependencies
- None.
EOF
}

write_repo_pytest_plan_artifact() {
    local path="$1" title="${2:-Plan Artifact}" change_label="${3:-Update}"
    cat > "$path" <<EOF
# ${title}

## Files to Modify
- \`src/main.py\` — ${change_label}

## Implementation Tasks

\`\`\`xml
<wave number="1">
  <task type="auto">
    <name>Exercise repo-standard pytest verification</name>
    <files>src/main.py</files>
    <action>Describe the test-first change without writing code.</action>
    <verify>.venv/bin/python -m pytest tests/ -x -q</verify>
    <done>The repo-standard pytest verification command is ready for execution.</done>
  </task>
</wave>
\`\`\`

## Testability Design
- Exercise timeout normalization for repo-standard pytest verification.

## Test Strategy
- Normalize the repo-standard pytest verify command before execution.

## Risk Assessment
- Fail closed if repo-standard timeout wrapping drifts.

## Dependencies
- None.
EOF
}

write_repo_pytest_fix_plan_artifact() {
    local path="$1"
    cat > "$path" <<'EOF'
# Fix Plan

**Task:** task.md
**Input:** competitive/review-synthesis.md
**Execution log target:** competitive/fix-execution.md

## Execution Order

Apply the fix in one pass.

## Implementation Tasks

```xml
<wave number="1">
  <task type="auto">
    <name>Execute the repo-standard fix verification</name>
    <files>src/main.py</files>
    <action>Apply the smallest safe fix.</action>
    <verify>.venv/bin/python -m pytest tests/ -x -q</verify>
    <done>The fix is verified with the repo-standard pytest command.</done>
  </task>
</wave>
```

## Dispute Candidates

None.

## Ready Gate

**READY: yes**
**Blocking assumptions:** None
EOF
    printf '{"ready":true}\n' > "${path%.*}.contract.json"
}

write_v1_shell_skeleton_task() {
    local path="$1" goal="${2:-Exercise Lauren Loop logic}" task_name="${3:-Lauren Loop Test}" timestamp="${4:-2026-03-19 12:00}"
    local escaped_goal="" escaped_task_name="" escaped_timestamp=""

    cp "$REPO_ROOT/templates/pilot-task.md" "$path"
    escaped_goal=$(printf '%s\n' "$goal" | sed 's/[&\\/|]/\\&/g')
    escaped_task_name=$(printf '%s\n' "$task_name" | sed 's/[&\\/|]/\\&/g')
    escaped_timestamp=$(printf '%s\n' "$timestamp" | sed 's/[&\\/|]/\\&/g')
    _sed_i "s|{{TASK_NAME}}|${escaped_task_name}|g" "$path"
    _sed_i "s|{{GOAL}}|${escaped_goal}|g" "$path"
    _sed_i "s|{{TIMESTAMP}}|${escaped_timestamp}|g" "$path"
}

write_v2_shell_skeleton_task() {
    local path="$1" slug="${2:-lauren-loop-test}" goal="${3:-Exercise Lauren Loop logic}"
    _write_v2_task_file "$path" "$slug" "$goal"
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

setup_v1_timeout_retry_fixture() {
    local name="$1" slug="$2" status="$3" blocked_line="$4"
    local root="$TMP_ROOT/$name"
    local home_dir="$root/home"
    mkdir -p "$root/docs/tasks/open" "$root/prompts" "$root/lib" "$root/bin" "$root/logs/pilot" "$home_dir/.claude/scripts"

    cp "$REPO_ROOT/lauren-loop.sh" "$root/lauren-loop.sh"
    cp "$REPO_ROOT/lib/lauren-loop-utils.sh" "$root/lib/lauren-loop-utils.sh"

    printf 'verifier prompt\n' > "$root/prompts/verifier.md"
    printf 'project rules\n' > "$root/prompts/project-rules.md"

    cat > "$root/bin/claude" <<'EOF'
#!/bin/bash
cat <<'INNER'
**PASS:** Goal coverage
**PASS:** Done criteria
INNER
EOF
    chmod +x "$root/bin/claude"

    cat > "$home_dir/.claude/scripts/context-guard.sh" <<'EOF'
#!/bin/bash
setup_azure_context() { return 0; }
EOF

    cat > "$root/docs/tasks/open/${slug}.md" <<EOF
## Task: ${slug}
## Status: ${status}
## Goal: Exercise verification retry

## Done Criteria
- [ ] Verification completes

## Current Plan
Plan body

## Critique
Critique body

## Left Off At:
Waiting on verification.

## Attempts:
- 2026-03-19: Verification timed out. -> Result: blocked

## Execution Log
${blocked_line}
EOF

    printf '%s\n' "$root"
}

set_runtime_defaults() {
    DRY_RUN=false
    EXPLORE_TIMEOUT="1s"
    PLANNER_TIMEOUT="1s"
    EVALUATE_TIMEOUT="1s"
    CRITIC_TIMEOUT="1s"
    EXECUTOR_TIMEOUT="1s"
    REVIEWER_TIMEOUT="1s"
    REVIEWER_TIMEOUT_EXPLICIT="true"
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
    write_valid_plan_artifact "$comp_dir/plan-a.md" "Plan A" "Checkpoint update"
    write_valid_plan_artifact "$comp_dir/plan-b.md" "Plan B" "Checkpoint alternative"
    printf 'revised plan\n' > "$comp_dir/revised-plan.md"
    write_plan_critique_artifact "$comp_dir/plan-critique.md" "EXECUTE"
    printf 'diff --git a/x b/x\n' > "$comp_dir/execution-diff.patch"
}

seed_medium_risk_diff() {
    local root="$1"
    local target="$root/prompts/project-rules.md"
    local i=1
    : > "$target"
    while [[ "$i" -le 520 ]]; do
        printf 'medium risk fixture line %04d\n' "$i" >> "$target"
        i=$((i + 1))
    done
}

seed_high_risk_diff() {
    local root="$1"
    local rel_path="config/security.txt"
    local target="$root/$rel_path"
    mkdir -p "$(dirname "$target")"
    if ! git -C "$root" ls-files --error-unmatch "$rel_path" >/dev/null 2>&1; then
        printf 'baseline critical fixture\n' > "$target"
        git -C "$root" add "$rel_path"
        git -C "$root" commit -q -m "Add high-risk fixture"
    fi
    printf 'critical change\n' >> "$target"
}

source "$REPO_ROOT/lib/lauren-loop-utils.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

REAL_INIT_RUN_MANIFEST_DEF="$(declare -f _init_run_manifest)"
REAL_UPDATE_RUN_MANIFEST_STATE_DEF="$(declare -f _update_run_manifest_state)"
REAL_APPEND_MANIFEST_PHASE_DEF="$(declare -f _append_manifest_phase)"
REAL_FINALIZE_RUN_MANIFEST_DEF="$(declare -f _finalize_run_manifest)"
REAL_FAIL_PHASE_DEF="$(sed -n '/^    _fail_phase() {/,/^    }/p' "$REPO_ROOT/lauren-loop-v2.sh" | sed 's/^    //')"
REAL_REQUIRE_VALID_ARTIFACT_DEF="$(sed -n '/^    _require_valid_artifact() {/,/^    }/p' "$REPO_ROOT/lauren-loop-v2.sh" | sed 's/^    //')"
REAL_PHASE8C_ROUTE_LABEL_DEF="$(sed -n '/^    _phase8c_route_label() {/,/^    }/p' "$REPO_ROOT/lauren-loop-v2.sh" | sed 's/^    //')"
REAL_PHASE8C_ROUTE_REQUIRES_FALSIFY_DEF="$(sed -n '/^    _phase8c_route_requires_falsify() {/,/^    }/p' "$REPO_ROOT/lauren-loop-v2.sh" | sed 's/^    //')"
REAL_PHASE8C_ROUTE_REQUIRED_INPUTS_DEF="$(sed -n '/^    _phase8c_route_required_inputs() {/,/^    }/p' "$REPO_ROOT/lauren-loop-v2.sh" | sed 's/^    //')"
REAL_PHASE8C_ROUTE_FIRST_MISSING_INPUT_DEF="$(sed -n '/^    _phase8c_route_first_missing_input() {/,/^    }/p' "$REPO_ROOT/lauren-loop-v2.sh" | sed 's/^    //')"
REAL_PHASE8C_FINAL_FIX_INPUT_INSTRUCTION_DEF="$(sed -n '/^    _phase8c_final_fix_input_instruction() {/,/^    }/p' "$REPO_ROOT/lauren-loop-v2.sh" | sed 's/^    //')"

restore_real_manifest_hooks() {
    eval "$REAL_INIT_RUN_MANIFEST_DEF"
    eval "$REAL_UPDATE_RUN_MANIFEST_STATE_DEF"
    eval "$REAL_APPEND_MANIFEST_PHASE_DEF"
    eval "$REAL_FINALIZE_RUN_MANIFEST_DEF"
}

load_real_fail_phase_helper() {
    eval "$REAL_FAIL_PHASE_DEF"
}

load_real_require_valid_artifact_helper() {
    eval "$REAL_REQUIRE_VALID_ARTIFACT_DEF"
}

load_real_phase8c_route_helpers() {
    eval "$REAL_PHASE8C_ROUTE_LABEL_DEF"
    eval "$REAL_PHASE8C_ROUTE_REQUIRES_FALSIFY_DEF"
    eval "$REAL_PHASE8C_ROUTE_REQUIRED_INPUTS_DEF"
    eval "$REAL_PHASE8C_ROUTE_FIRST_MISSING_INPUT_DEF"
    eval "$REAL_PHASE8C_FINAL_FIX_INPUT_INSTRUCTION_DEF"
}

# Direct V1 legacy coverage for the dormant planner/critic path.
eval "$(sed -n '/^task_file_stem() {/,/^}/p' "$REPO_ROOT/lauren-loop.sh")"
eval "$(sed -n '/^format_auto_duration() {/,/^}/p' "$REPO_ROOT/lib/lauren-loop-utils.sh")"
eval "$(sed -n '/^print_auto_summary() {/,/^}/p' "$REPO_ROOT/lauren-loop.sh")"
eval "$(sed -n '/^_pick_load_ranked_tasks() {/,/^}/p' "$REPO_ROOT/lauren-loop.sh")"
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
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
source "\$REPO_ROOT/lib/lauren-loop-utils.sh"
SCRIPT_DIR="\$REPO_ROOT"
eval "\$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "\$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"
MODEL="opus"
LOCK_DIR="$lock_dir"
SLUG="test-task"
GOAL="test goal"
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
    SLUG="test-task"
    GOAL="test goal"
    INTERNAL=false
    _LOCK_ACQUIRED=false
    set +e
    acquire_lock >/dev/null 2>&1
    rc=$?
    set -e
    wait "$child_pid"
    [[ "$rc" -ne 0 ]]
) && pass "5. acquire_lock — same slug, second process fails on contention" \
  || fail "5. acquire_lock — same slug, second process fails on contention"

(
    lock_dir="$TMP_ROOT/lock-parallel.d"
    child="$TMP_ROOT/lock-holder-parallel.sh"
    cat > "$child" <<EOF
#!/bin/bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
source "\$REPO_ROOT/lib/lauren-loop-utils.sh"
SCRIPT_DIR="\$REPO_ROOT"
eval "\$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "\$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"
MODEL="opus"
LOCK_DIR="$lock_dir"
SLUG="slug-alpha"
GOAL="alpha goal"
INTERNAL=false
_LOCK_ACQUIRED=false
acquire_lock
printf 'ready\n' > "$TMP_ROOT/parallel.ready"
sleep 3
release_lock
EOF
    chmod +x "$child"
    "$child" &
    child_pid=$!
    for _ in $(seq 1 100); do
        [[ -f "$TMP_ROOT/parallel.ready" ]] && break
        sleep 0.05
    done
    LOCK_DIR="$lock_dir"
    SLUG="slug-beta"
    GOAL="beta goal"
    INTERNAL=false
    _LOCK_ACQUIRED=false
    set +e
    acquire_lock >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    [[ -f "$lock_dir/slug-alpha/pid" ]]
    [[ -f "$lock_dir/slug-beta/pid" ]]
    release_lock 2>/dev/null || true
    wait "$child_pid"
    [[ ! -d "$lock_dir" || -z "$(ls -A "$lock_dir")" ]]
) && pass "5b. acquire_lock — different slugs succeed in parallel" \
  || fail "5b. acquire_lock — different slugs succeed in parallel"

(
    lock_dir="$TMP_ROOT/lock-git-safe.d"
    bin_dir="$TMP_ROOT/git-stub/bin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/git" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$bin_dir/git"
    PATH="$bin_dir:$PATH"
    LOCK_DIR="$lock_dir"
    SLUG="gitless-lock"
    GOAL="gitless goal"
    INTERNAL=false
    _LOCK_ACQUIRED=false
    acquire_lock >/dev/null 2>&1
    [[ -f "$lock_dir/gitless-lock/pid" ]]
    release_lock
    [[ ! -d "$lock_dir/gitless-lock" ]]
) && pass "5c. acquire_lock — succeeds when git warning path is unavailable" \
  || fail "5c. acquire_lock — succeeds when git warning path is unavailable"

(
    lock_dir="$TMP_ROOT/lock-stale-race.d"
    mkdir -p "$lock_dir/stale-race"
    dead_pid=$(bash -c 'echo $$')
    echo "$dead_pid" > "$lock_dir/stale-race/pid"
    child="$TMP_ROOT/stale-lock-racer.sh"
    cat > "$child" <<EOF
#!/bin/bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
source "\$REPO_ROOT/lib/lauren-loop-utils.sh"
SCRIPT_DIR="\$REPO_ROOT"
eval "\$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "\$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"
label="\$1"
MODEL="opus"
LOCK_DIR="$lock_dir"
SLUG="stale-race"
GOAL="stale race \$label"
INTERNAL=false
_LOCK_ACQUIRED=false
start_file="$TMP_ROOT/stale-race.start"
release_file="$TMP_ROOT/stale-race.release"
while [[ ! -f "\$start_file" ]]; do
    sleep 0.05
done
set +e
acquire_lock >/dev/null 2>&1
rc=\$?
set -e
printf '%s\n' "\$rc" > "$TMP_ROOT/stale-race.\$label.rc"
if [[ "\$rc" -eq 0 ]]; then
    printf '%s\n' "\$\$" > "$TMP_ROOT/stale-race.\$label.pid"
    while [[ ! -f "\$release_file" ]]; do
        sleep 0.05
    done
    release_lock
fi
EOF
    chmod +x "$child"
    "$child" a &
    child_a=$!
    "$child" b &
    child_b=$!
    : > "$TMP_ROOT/stale-race.start"
    for _ in $(seq 1 100); do
        [[ -f "$TMP_ROOT/stale-race.a.rc" && -f "$TMP_ROOT/stale-race.b.rc" ]] && break
        sleep 0.05
    done
    [[ -f "$TMP_ROOT/stale-race.a.rc" ]]
    [[ -f "$TMP_ROOT/stale-race.b.rc" ]]
    rc_a=$(cat "$TMP_ROOT/stale-race.a.rc")
    rc_b=$(cat "$TMP_ROOT/stale-race.b.rc")
    success_count=0
    [[ "$rc_a" -eq 0 ]] && success_count=$((success_count + 1))
    [[ "$rc_b" -eq 0 ]] && success_count=$((success_count + 1))
    [[ "$success_count" -eq 1 ]]
    if [[ "$rc_a" -eq 0 ]]; then
        winner_label="a"
    else
        winner_label="b"
    fi
    [[ -f "$lock_dir/stale-race/pid" ]]
    [[ "$(tr -d '[:space:]' < "$lock_dir/stale-race/pid")" == "$(tr -d '[:space:]' < "$TMP_ROOT/stale-race.$winner_label.pid")" ]]
    [[ ! -e "$lock_dir/stale-race/.reclaim" ]]
    : > "$TMP_ROOT/stale-race.release"
    wait "$child_a"
    wait "$child_b"
    [[ ! -d "$lock_dir/stale-race" ]]
) && pass "5d. acquire_lock — concurrent stale recovery yields a single owner" \
  || fail "5d. acquire_lock — concurrent stale recovery yields a single owner"

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
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
    grep -Eq 'Phase 5: WARN .*single reviewer continuing to synthesis' "$fixture_root/docs/tasks/open/$slug/task.md"
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
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
    grep -q 'review-synthesis.md is missing, so unresolved findings could not be extracted.' "$handoff"
    ! grep -q 'No unresolved findings were extracted from review-synthesis.md.' "$handoff"
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
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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

(
    slug="single-plan-auto-strict"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    restore_real_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="codex"
    _V2_CODEX_RUN_FAILURES=2
    PLANNER_B_REQUEST_BODY=""
    PLANNER_B_ENGINE=""
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
        case "$2" in
            */planner-b.md)
                PLANNER_B_REQUEST_BODY="$3"
                ;;
        esac
    }
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
            explorer)
                printf '# Exploration Summary\n\nPlanning context.\n' > "$output"
                ;;
            planner-a)
                printf 'partial planner a\n' > "$output"
                return 1
                ;;
            planner-b)
                PLANNER_B_ENGINE="$_engine"
                write_valid_plan_artifact "$output" "Plan B" "Production cutover plan"
                ;;
            *)
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "production cutover deployment"
    )
    handoff="$fixture_root/docs/tasks/open/$slug/competitive/human-review-handoff.md"
    task_file="$fixture_root/docs/tasks/open/$slug/task.md"
    manifest="$fixture_root/docs/tasks/open/$slug/competitive/run-manifest.json"
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]
    [[ -f "$handoff" ]]
    grep -q 'Final review verdict: SINGLE_PLANNER' "$handoff"
    ! grep -q '^evaluator$' "$ROLE_LOG"
    [[ "$PLANNER_B_ENGINE" == "claude" ]]
    [[ "$PLANNER_B_REQUEST_BODY" == *"${fixture_root}/docs/tasks/open/${slug}/competitive/plan-b.md"* ]]
    [[ "$PLANNER_B_REQUEST_BODY" != *"$CODEX_ARTIFACT_PATH_PLACEHOLDER"* ]]
    [[ -f "$manifest" ]]
    jq -e '
        ([.phases[] | select(
            .phase == "phase-2" and
            .name == "planning-b" and
            .status == "skipped" and
            .error_class == "codex_circuit_breaker" and
            .error_detail == "dispatch=planner-b; skipped_engine=codex; fallback_engine=claude; cumulative_failures=2"
        )] | length) == 1
    ' "$manifest" >/dev/null
    [[ ! -f "$fixture_root/docs/tasks/open/$slug/competitive/revised-plan.md" ]]
    grep -q 'Single planner halt' "$task_file"
) && pass "12b. auto strict halts on a single surviving planner and planner-b breaker uses the effective Claude path" \
  || fail "12b. auto strict halts on a single surviving planner and planner-b breaker uses the effective Claude path"

(
    slug="session2-planner-a-auth-breaker"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    PREFLIGHT_FILE="$TMP_ROOT/${slug}.preflight"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    restore_real_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="codex"
    ENGINE_PLANNER_B="claude"
    _V2_CODEX_RUN_FAILURES=0
    PREFLIGHT_CALLS=0
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _classify_diff_risk() { printf 'LOW\n'; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    codex54_auth_preflight() {
        PREFLIGHT_CALLS=$((PREFLIGHT_CALLS + 1))
        echo "Error: No Codex 5.4 API key is available in _CODEX54_AZURE_API_KEY or AZURE_OPENAI_API_KEY, and Key Vault lookup failed" >&2
        return 1
    }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        : > "$log_file"
        printf '%s|%s\n' "$role" "$_engine" >> "$ROLE_LOG"
        case "$role" in
            explorer)
                printf '# Exploration Summary\n\nPlanning context.\n' > "$output"
                ;;
            planner-a)
                write_valid_plan_artifact "$output" "Plan A" "Production cutover plan"
                ;;
            planner-b)
                printf 'partial planner b\n' > "$output"
                return 1
                ;;
            *)
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "production cutover deployment"
        printf '%s\n' "$PREFLIGHT_CALLS" > "$PREFLIGHT_FILE"
    )
    handoff="$fixture_root/docs/tasks/open/$slug/competitive/human-review-handoff.md"
    task_file="$fixture_root/docs/tasks/open/$slug/task.md"
    manifest="$fixture_root/docs/tasks/open/$slug/competitive/run-manifest.json"
    status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    [[ "$status" == "needs verification" ]]
    [[ -f "$handoff" ]]
    [[ "$(cat "$PREFLIGHT_FILE")" == "1" ]]
    grep -Fq 'planner-a|claude' "$ROLE_LOG"
    ! grep -Fq 'planner-a|codex' "$ROLE_LOG"
    ! grep -q '^evaluator|' "$ROLE_LOG"
    [[ -f "$manifest" ]]
    jq -e '
        ([.phases[] | select(
            .phase == "phase-2" and
            .name == "planning-a" and
            .status == "skipped" and
            .error_class == "codex_auth_preflight" and
            .error_detail == "dispatch=planner-a; skipped_engine=codex; fallback_engine=claude; reason=auth_preflight"
        )] | length) == 1
    ' "$manifest" >/dev/null
) && pass "12c. planner-a auth preflight reroutes a previously unguarded Codex slot to Claude before dispatch" \
  || fail "12c. planner-a auth preflight reroutes a previously unguarded Codex slot to Claude before dispatch"

(
    ! _task_auto_strict_reason "authorizer-cleanup" "authorization helper maintenance" >/dev/null 2>&1
    _task_auto_strict_reason "prod-cutover" "production cutover deployment" | grep -q 'deployment or production-cutover'
) && pass "12d. auto strict matching is conservative and catches prod cutover" \
  || fail "12d. auto strict matching is conservative and catches prod cutover"

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
    output="$(LAUREN_LOOP_MAX_COST=0 bash "$REPO_ROOT/lauren-loop-v2.sh" prod-cutover "production cutover deployment" 2>&1)"
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]]
    echo "$output" | grep -q 'Strict mode requires LAUREN_LOOP_MAX_COST'
) && pass "13b. auto strict live run also requires a cost ceiling" \
  || fail "13b. auto strict live run also requires a cost ceiling"

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
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
    grep -q 'Strict mode requires fix-plan.contract.json ready=true|false' "$fixture_root/docs/tasks/open/$slug/task.md"
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
    grep -q 'Strict mode requires fix-execution.contract.json status=COMPLETE|BLOCKED|FAILED' "$fixture_root/docs/tasks/open/$slug/task.md"
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
    PROJECT_NAME="${PROJECT_NAME:-AskGeorge}"
    TEST_CMD="${TEST_CMD:-.venv/bin/python -m pytest tests/ -x -q}"
    LINT_CMD="${LINT_CMD:-.venv/bin/python -m flake8 src/ --count --select=E9,F63,F7,F82 --show-source --statistics}"
    [ "$PROJECT_NAME" = "TestProject" ]
    [ "$TEST_CMD" = "python -m pytest" ]
    [ "$LINT_CMD" = "python -m flake8" ]
) && pass "21. conf custom PROJECT_NAME/TEST_CMD/LINT_CMD override defaults" \
  || fail "21. conf custom PROJECT_NAME/TEST_CMD/LINT_CMD override defaults"

(
    PROJECT_NAME="" TEST_CMD="" LINT_CMD=""
    PROJECT_NAME="${PROJECT_NAME:-AskGeorge}"
    TEST_CMD="${TEST_CMD:-.venv/bin/python -m pytest tests/ -x -q}"
    LINT_CMD="${LINT_CMD:-.venv/bin/python -m flake8 src/ --count --select=E9,F63,F7,F82 --show-source --statistics}"
    [ "$PROJECT_NAME" = "AskGeorge" ]
    [ "$TEST_CMD" = ".venv/bin/python -m pytest tests/ -x -q" ]
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
    _pick_load_ranked_tasks "$PICK_TEMP" > "$TMP_ROOT/gap4-primary.out"
    [ "$_PICK_PARSER_TIER" = "primary" ]
    [ "$PICK_COUNT" -eq 2 ]
    [ "${PICK_FILES[0]}" = "task-a.md" ]
    [ "${PICK_GOALS[1]}" = "Goal B" ]
    [ "${PICK_COMPLEXITY[1]}" = "High" ]
) && pass "34. Gap 4: primary parser helper detects tier and builds arrays" \
  || fail "34. Gap 4: primary parser helper detects tier and builds arrays"

(
    PICK_TEMP="$TMP_ROOT/gap4-bold-bracket.txt"
    cat > "$PICK_TEMP" <<'PICKEOF'
**1. [task-a.md]** — Goal A
**2. [task-b.md]** — Goal B
PICKEOF
    _pick_load_ranked_tasks "$PICK_TEMP" > "$TMP_ROOT/gap4-bold-bracket.out"
    [ "$_PICK_PARSER_TIER" = "bold-bracket" ]
    [ "$PICK_COUNT" -eq 2 ]
    [ "${PICK_FILES[1]}" = "task-b.md" ]
    [ "${PICK_COMPLEXITY[0]}" = "Unknown" ]
) && pass "35. Gap 4: bold-bracket helper uses fallback and builds arrays" \
  || fail "35. Gap 4: bold-bracket helper uses fallback and builds arrays"

(
    PICK_TEMP="$TMP_ROOT/gap4-bold-plain.txt"
    cat > "$PICK_TEMP" <<'PICKEOF'
**1. task-a.md** — Goal A
**2. task-b.md** — Goal B
PICKEOF
    _pick_load_ranked_tasks "$PICK_TEMP" > "$TMP_ROOT/gap4-bold-plain.out"
    [ "$_PICK_PARSER_TIER" = "bold-plain" ]
    [ "$PICK_COUNT" -eq 2 ]
    [ "${PICK_GOALS[0]}" = "Goal A" ]
    [ "${PICK_COMPLEXITY[1]}" = "Unknown" ]
) && pass "36. Gap 4: bold-plain helper uses fallback and builds arrays" \
  || fail "36. Gap 4: bold-plain helper uses fallback and builds arrays"

# Planner artifact validation regressions
(
    fenced_plan="$TMP_ROOT/planner-valid-fenced.md"
    write_valid_plan_artifact "$fenced_plan" "Plan Artifact" "Fenced valid plan" "yes"
    _validate_agent_output_for_role "planner-a" "$fenced_plan"
) && pass "37. planner validation accepts fenced valid artifacts" \
  || fail "37. planner validation accepts fenced valid artifacts"

(
    unfenced_plan="$TMP_ROOT/planner-valid-unfenced.md"
    write_valid_plan_artifact "$unfenced_plan" "Plan Artifact" "Unfenced valid plan" "no"
    _validate_agent_output_for_role "planner-a" "$unfenced_plan"
) && pass "38. planner validation accepts unfenced valid artifacts" \
  || fail "38. planner validation accepts unfenced valid artifacts"

(
    invalid_plan="$TMP_ROOT/planner-invalid-unbalanced-fence.md"
    write_valid_plan_artifact "$invalid_plan" "Plan Artifact" "Broken fence plan" "yes"
    printf '```xml\n' >> "$invalid_plan"
    ! _validate_agent_output_for_role "planner-a" "$invalid_plan"
) && pass "39. planner validation rejects unbalanced fenced artifacts" \
  || fail "39. planner validation rejects unbalanced fenced artifacts"

(
    misplaced_plan="$TMP_ROOT/planner-invalid-misplaced-tasks.md"
    cat > "$misplaced_plan" <<'EOF'
# Plan Artifact

## Files to Modify
- `src/main.py` — Misplaced task structure

## Implementation Tasks
Task details moved to the wrong section.

## Testability Design
```xml
<wave number="1">
  <task type="auto">
    <name>Misplaced task structure</name>
    <files>src/main.py</files>
    <action>Describe the test-first change without writing code.</action>
    <verify>bash tests/test_lauren_loop_logic.sh</verify>
    <done>The validator must reject XML blocks outside Implementation Tasks.</done>
  </task>
</wave>
```

## Test Strategy
- Run the Lauren Loop shell tests that use checkpointed plan artifacts.

## Risk Assessment
- Keep checkpoint validation aligned with the live planner contract.

## Dependencies
- None.
EOF
    ! _validate_agent_output_for_role "planner-a" "$misplaced_plan"
) && pass "40. planner validation rejects task blocks outside Implementation Tasks" \
  || fail "40. planner validation rejects task blocks outside Implementation Tasks"

(
    pick_temp="$TMP_ROOT/pick-ranked.txt"
    cat > "$pick_temp" <<'EOF'
Ranking explanation here.

## TASK_LIST
1|docs/tasks/open/stabilize-v2-traditional-dev-proxy/task.md|Stabilize the V2 traditional dev proxy|Low
EOF

    _pick_load_ranked_tasks "$pick_temp"
    output=$(LAUREN_LOOP_NONINTERACTIVE=1 _pick_interactive_select_task "$pick_temp" 2>&1)
    echo "$output" | grep -q 'Select a task'
    echo "$output" | grep -q 'Cancelled.'
    ! echo "$output" | grep -q 'local: can only be used in a function'
) && pass "41. pick menu helper reaches the real menu path without local crashes" \
  || fail "41. pick menu helper reaches the real menu path without local crashes"

# Gap 9: Cross-version lock awareness (per-slug V2 layout)
(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    mkdir -p "$lock_dir/my-task"
    echo "$$" > "$lock_dir/my-task/pid"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 1 ]
) && pass "42. Gap 9: cross-lock warns when V2 holds same slug (returns 1)" \
  || fail "42. Gap 9: cross-lock warns when V2 holds same slug (returns 1)"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    mkdir -p "$lock_dir/other-task"
    echo "$$" > "$lock_dir/other-task/pid"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "43. Gap 9: cross-lock silent when V2 holds different slug (returns 0)" \
  || fail "43. Gap 9: cross-lock silent when V2 holds different slug (returns 0)"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    dead_pid=$(bash -c 'echo $$')
    mkdir -p "$lock_dir/my-task"
    echo "$dead_pid" > "$lock_dir/my-task/pid"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "44. Gap 9: cross-lock ignores dead PID (returns 0)" \
  || fail "44. Gap 9: cross-lock ignores dead PID (returns 0)"

(
    lock_dir="$TMP_ROOT/v2lock-nonexistent"
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "45. Gap 9: cross-lock returns 0 when no lock dir exists" \
  || fail "45. Gap 9: cross-lock returns 0 when no lock dir exists"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2lock.XXXXXX")"
    # No per-slug dir at all for my-task
    _V2_LOCK_DIR="$lock_dir" _check_cross_version_lock "v1" "my-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "46. Gap 9: cross-lock returns 0 when no per-slug lock dir exists" \
  || fail "46. Gap 9: cross-lock returns 0 when no per-slug lock dir exists"

# _list_running_v2_instances / _is_slug_running_v2 tests
(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2enum.XXXXXX")"
    mkdir -p "$lock_dir/alive-task"
    echo "$$" > "$lock_dir/alive-task/pid"
    echo "alive goal" > "$lock_dir/alive-task/goal"
    dead_pid=$(bash -c 'echo $$')
    mkdir -p "$lock_dir/dead-task"
    echo "$dead_pid" > "$lock_dir/dead-task/pid"
    echo "dead goal" > "$lock_dir/dead-task/goal"
    output=$(_V2_LOCK_DIR="$lock_dir" _list_running_v2_instances)
    echo "$output" | grep -q "alive-task"
    ! echo "$output" | grep -q "dead-task"
) && pass "47. _list_running_v2_instances lists alive, skips dead" \
  || fail "47. _list_running_v2_instances lists alive, skips dead"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2enum.XXXXXX")"
    mkdir -p "$lock_dir/active-slug"
    echo "$$" > "$lock_dir/active-slug/pid"
    _V2_LOCK_DIR="$lock_dir" _is_slug_running_v2 "active-slug"
) && pass "48. _is_slug_running_v2 returns 0 for active slug" \
  || fail "48. _is_slug_running_v2 returns 0 for active slug"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2enum.XXXXXX")"
    ! _V2_LOCK_DIR="$lock_dir" _is_slug_running_v2 "missing-slug"
) && pass "49. _is_slug_running_v2 returns 1 for missing slug" \
  || fail "49. _is_slug_running_v2 returns 1 for missing slug"

(
    lock_dir="$(mktemp -d "$TMP_ROOT/v2enum.XXXXXX")"
    dead_pid=$(bash -c 'echo $$')
    mkdir -p "$lock_dir/stale-slug"
    echo "$dead_pid" > "$lock_dir/stale-slug/pid"
    ! _V2_LOCK_DIR="$lock_dir" _is_slug_running_v2 "stale-slug"
) && pass "50. _is_slug_running_v2 returns 1 for dead PID" \
  || fail "50. _is_slug_running_v2 returns 1 for dead PID"

(
    output="$(print_auto_summary \
        "V2" \
        "Complex (V2) — user selected" \
        "7260" \
        "17.8278" \
        "0" \
        "~21.8h / ~\$1196 (COCOMO-inspired heuristic; 435 net lines at 20 SLOC/hr × \$55/hr)" 2>&1)"
    echo "$output" | grep -q 'Traditional Dev Proxy:'
    echo "$output" | grep -q '~21.8h / ~\$1196'
    echo "$output" | grep -q 'heuristic'
    ! echo "$output" | grep -q 'Offshore Dev Cost'
    ! echo "$output" | grep -q 'industry-standard COCOMO II'
) && pass "51. auto summary uses traditional dev proxy wording" \
  || fail "51. auto summary uses traditional dev proxy wording"

# ============================================================
# Test 52: reviewer timeout scales by diff risk when no explicit override is set
# ============================================================
(
    REVIEWER_TIMEOUT="15m"
    REVIEWER_TIMEOUT_EXPLICIT="false"
    [[ "$(_resolve_reviewer_timeout "LOW")" == "15m" ]]
    [[ "$(_resolve_reviewer_timeout "MEDIUM")" == "30m" ]]
    [[ "$(_resolve_reviewer_timeout "HIGH")" == "45m" ]]
    [[ "$(_reviewer_timeout_resolution_source)" == "diff-risk-scaling" ]]
) && pass "52. reviewer timeout scales by diff risk when no explicit override is set" \
  || fail "52. reviewer timeout scales by diff risk when no explicit override is set"

# ============================================================
# Test 53: explicit reviewer timeout override takes precedence over scaling
# ============================================================
(
    REVIEWER_TIMEOUT="41m"
    REVIEWER_TIMEOUT_EXPLICIT="true"
    [[ "$(_resolve_reviewer_timeout "HIGH")" == "41m" ]]
    [[ "$(_reviewer_timeout_resolution_source)" == "explicit-override" ]]
) && pass "53. explicit reviewer timeout override takes precedence over scaling" \
  || fail "53. explicit reviewer timeout override takes precedence over scaling"

# ============================================================
# Test 54: manifest state updates preserve phase history and reviewer timeout state
# ============================================================
(
    root="$TMP_ROOT/manifest-state"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-state"
    goal="Exercise manifest state updates"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="codex"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _init_run_manifest
    _update_run_manifest_state "phase-5" "MEDIUM" "30m" "$ENGINE_REVIEWER_A" "claude (fallback)"
    _append_manifest_phase "phase-5" "review-cycle-1" "2026-03-20T00:00:00Z" "2026-03-20T00:01:00Z" "completed" "PASS"
    _finalize_run_manifest "success" 0
    jq -e '
        .current_phase == "phase-5" and
        .diff_risk == "MEDIUM" and
        .effective_timeouts.reviewer == "30m" and
        .active_engines.reviewer_b == "claude (fallback)" and
        .final_status == "success" and
        (.phases | length) == 1 and
        .phases[0].phase == "phase-5" and
        (.phases[0] | has("error_class") | not) and
        (.phases[0] | has("error_detail") | not)
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54. manifest state updates preserve phase history and reviewer timeout state" \
  || fail "54. manifest state updates preserve phase history and reviewer timeout state"

# ============================================================
# Test 54a: reviewer launch and reviewer backstop use the scaled timeout
# ============================================================
(
    slug="reviewer-timeout-medium"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    seed_medium_risk_diff "$fixture_root"
    ROLE_TIMEOUT_LOG="$TMP_ROOT/${slug}.timeouts"
    BACKSTOP_TIMEOUT_LOG="$TMP_ROOT/${slug}.backstop"
    : > "$ROLE_TIMEOUT_LOG"
    : > "$BACKSTOP_TIMEOUT_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    REVIEWER_TIMEOUT="15m"
    REVIEWER_TIMEOUT_EXPLICIT="false"
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EVALUATOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    _enforce_codex_phase_backstop() {
        printf '%s\n' "$4" > "$BACKSTOP_TIMEOUT_LOG"
        return 0
    }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6" timeout="$7"
        : > "$log_file"
        printf '%s\t%s\n' "$role" "$timeout" >> "$ROLE_TIMEOUT_LOG"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b)
                sleep 2
                write_review_artifact "$output" "PASS" "No findings."
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "medium diff risk scales reviewer timeout"
    )
    grep -Eq '^reviewer-a\t30m$' "$ROLE_TIMEOUT_LOG"
    grep -Eq '^reviewer-b\t30m$' "$ROLE_TIMEOUT_LOG"
    [[ "$(cat "$BACKSTOP_TIMEOUT_LOG")" == "30m" ]]
    grep -q 'Phase 4: Reviewer timeout resolved to 30m (source=diff-risk-scaling, diff_risk=MEDIUM)' \
        "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "54a. reviewer launch and reviewer backstop use the scaled timeout" \
  || fail "54a. reviewer launch and reviewer backstop use the scaled timeout"

# ============================================================
# Test 54b: reviewer fallback inherits the scaled reviewer timeout
# ============================================================
(
    slug="reviewer-timeout-fallback"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    seed_medium_risk_diff "$fixture_root"
    ROLE_TIMEOUT_LOG="$TMP_ROOT/${slug}.timeouts"
    : > "$ROLE_TIMEOUT_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    REVIEWER_TIMEOUT="15m"
    REVIEWER_TIMEOUT_EXPLICIT="false"
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EVALUATOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6" timeout="$7"
        : > "$log_file"
        printf '%s\t%s\n' "$role" "$timeout" >> "$ROLE_TIMEOUT_LOG"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b)
                return 1
                ;;
            reviewer-b-claude-fallback)
                write_review_artifact "$output" "PASS" "No findings."
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "reviewer fallback inherits the medium diff timeout"
    )
    grep -Eq '^reviewer-b\t30m$' "$ROLE_TIMEOUT_LOG"
    grep -Eq '^reviewer-b-claude-fallback\t30m$' "$ROLE_TIMEOUT_LOG"
) && pass "54b. reviewer fallback inherits the scaled reviewer timeout" \
  || fail "54b. reviewer fallback inherits the scaled reviewer timeout"

# ============================================================
# Test 54c: cycle-state resume preserves an existing manifest and appends new phase history
# ============================================================
(
    slug="resume-manifest-preserved"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    seed_medium_risk_diff "$fixture_root"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    task_file="$fixture_root/docs/tasks/open/$slug/task.md"
    manifest="$comp_dir/run-manifest.json"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    write_review_synthesis_artifact "$comp_dir/review-synthesis.md" "FAIL" 0 1 0 0
    write_fix_plan_artifact "$comp_dir/fix-plan.md" "yes"
    _write_cycle_state "$comp_dir" 0 "phase-6b" "FAIL"
    cat > "$manifest" <<'EOF'
{
  "run_id": "seeded-run-id",
  "slug": "resume-manifest-preserved",
  "goal": "Preserve resume manifest history",
  "started_at": "2026-03-20T00:00:00Z",
  "model": "opus",
  "engines": {
    "explore": "claude",
    "planner_a": "claude",
    "planner_b": "claude",
    "evaluator": "claude",
    "executor": "claude",
    "reviewer_a": "claude",
    "reviewer_b": "claude",
    "fix": "claude"
  },
  "force_rerun": false,
  "current_phase": "phase-6b",
  "active_engines": {
    "explore": "claude",
    "planner_a": "claude",
    "planner_b": "claude",
    "evaluator": "claude",
    "executor": "claude",
    "reviewer_a": "claude",
    "reviewer_b": "claude",
    "fix": "claude"
  },
  "diff_risk": "LOW",
  "effective_timeouts": {
    "reviewer": "15m"
  },
  "phases": [
    {
      "phase": "phase-seeded",
      "name": "pre-resume-history",
      "started_at": "2026-03-20T00:00:00Z",
      "completed_at": "2026-03-20T00:05:00Z",
      "status": "completed",
      "verdict": "FAIL"
    }
  ]
}
EOF
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    REVIEWER_TIMEOUT="15m"
    REVIEWER_TIMEOUT_EXPLICIT="false"
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_CRITIC="claude"
    ENGINE_FIX="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
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
            fix-executor*) write_fix_execution_artifact "$comp_dir/fix-execution.md" "COMPLETE" ;;
            reviewer-a*) write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings." ;;
            reviewer-b*) write_review_artifact "$output" "PASS" "No findings." ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "resume preserves manifest history"
    )
    grep -q 'Cycle checkpoint resume:' "$task_file"
    grep -q '^fix-critic-r1$' "$ROLE_LOG"
    jq -e '
        .run_id == "seeded-run-id" and
        .diff_risk == "MEDIUM" and
        .effective_timeouts.reviewer == "30m" and
        (.phases | length) > 1 and
        .phases[0].phase == "phase-seeded" and
        .phases[0].name == "pre-resume-history"
    ' "$manifest" >/dev/null
) && pass "54c. cycle-state resume preserves an existing manifest and appends new phase history" \
  || fail "54c. cycle-state resume preserves an existing manifest and appends new phase history"

# ============================================================
# Test 54d: explicit reviewer timeout override reaches launch, backstop, and fallback
# ============================================================
(
    slug="reviewer-timeout-explicit-override"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    seed_medium_risk_diff "$fixture_root"
    ROLE_TIMEOUT_LOG="$TMP_ROOT/${slug}.timeouts"
    BACKSTOP_TIMEOUT_LOG="$TMP_ROOT/${slug}.backstop"
    : > "$ROLE_TIMEOUT_LOG"
    : > "$BACKSTOP_TIMEOUT_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    REVIEWER_TIMEOUT="41m"
    REVIEWER_TIMEOUT_EXPLICIT="true"
    stub_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EVALUATOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
    _block_on_untracked_files() { return 0; }
    _check_cost_ceiling() { return 0; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    _enforce_codex_phase_backstop() {
        printf '%s\n' "$4" > "$BACKSTOP_TIMEOUT_LOG"
        return 1
    }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6" timeout="$7"
        : > "$log_file"
        printf '%s\t%s\n' "$role" "$timeout" >> "$ROLE_TIMEOUT_LOG"
        case "$role" in
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b)
                sleep 2
                return 1
                ;;
            reviewer-b-claude-fallback)
                write_review_artifact "$output" "PASS" "No findings."
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "explicit reviewer timeout override wins over medium diff scaling"
    )
    grep -Eq '^reviewer-a\t41m$' "$ROLE_TIMEOUT_LOG"
    grep -Eq '^reviewer-b\t41m$' "$ROLE_TIMEOUT_LOG"
    grep -Eq '^reviewer-b-claude-fallback\t41m$' "$ROLE_TIMEOUT_LOG"
    [[ "$(cat "$BACKSTOP_TIMEOUT_LOG")" == "41m" ]]
    grep -q 'Phase 4: Reviewer timeout resolved to 41m (source=explicit-override, diff_risk=MEDIUM)' \
        "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "54d. explicit reviewer timeout override reaches launch, backstop, and fallback" \
  || fail "54d. explicit reviewer timeout override reaches launch, backstop, and fallback"

(
    root="$TMP_ROOT/manifest-finalize-idempotent"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-finalize-idempotent"
    goal="Finalize once and keep the first terminal state"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _init_run_manifest
    _append_manifest_phase "phase-4" "executing" "2026-03-20T00:00:00Z" "2026-03-20T00:00:30Z" "completed"
    _append_cost_csv_raw_row \
        "$TASK_LOG_DIR/.cost-first.csv" "$(_iso_timestamp)" "$slug" "executor" "claude" "opus" \
        "medium" "1" "0" "0" "1" "0.0003" "30" "0" "completed"
    _finalize_run_manifest "interrupted" 1
    first_completed_at=$(jq -r '.completed_at' "$comp_dir/run-manifest.json")
    first_run_id=$(jq -r '.run_id' "$comp_dir/run-manifest.json")
    sleep 1
    _append_cost_csv_raw_row \
        "$TASK_LOG_DIR/.cost-second.csv" "$(_iso_timestamp)" "$slug" "reviewer-a" "claude" "opus" \
        "medium" "1" "0" "0" "1" "0.0007" "45" "0" "completed"
    _finalize_run_manifest "cleanup" 7
    jq -e --arg completed_at "$first_completed_at" --arg run_id "$first_run_id" '
        .run_id == $run_id and
        .completed_at == $completed_at and
        .final_status == "interrupted" and
        .fix_cycles == 1 and
        .total_cost_usd == "0.0003"
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54e. _finalize_run_manifest is idempotent after the first terminal write" \
  || fail "54e. _finalize_run_manifest is idempotent after the first terminal write"

(
    slug="force-rerun-manifest-persistence"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    cat > "$comp_dir/run-manifest.json" <<'EOF'
{
  "run_id": "seeded-run-id",
  "slug": "force-rerun-manifest-persistence",
  "goal": "Preserve the old manifest on force rerun",
  "started_at": "2026-03-20T00:00:00Z",
  "completed_at": "2026-03-20T00:05:00Z",
  "model": "opus",
  "engines": {
    "explore": "claude",
    "planner_a": "claude",
    "planner_b": "claude",
    "evaluator": "claude",
    "executor": "claude",
    "reviewer_a": "claude",
    "reviewer_b": "claude",
    "fix": "claude"
  },
  "force_rerun": false,
  "current_phase": "phase-5",
  "active_engines": {
    "explore": "claude",
    "planner_a": "claude",
    "planner_b": "claude",
    "evaluator": "claude",
    "executor": "claude",
    "reviewer_a": "claude",
    "reviewer_b": "claude",
    "fix": "claude"
  },
  "diff_risk": "LOW",
  "effective_timeouts": {
    "reviewer": "15m"
  },
  "phases": [
    {
      "phase": "phase-seeded",
      "name": "prior-run",
      "started_at": "2026-03-20T00:00:00Z",
      "completed_at": "2026-03-20T00:05:00Z",
      "status": "completed",
      "verdict": "PASS",
      "cost": "0.1234"
    }
  ],
  "total_cost_usd": "0.1234",
  "final_status": "success",
  "fix_cycles": 2
}
EOF
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    restore_real_manifest_hooks
    FORCE_RERUN=true
    LAUREN_LOOP_STRICT=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _preflight_dependency_check() { return 1; }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    original_dir="$PWD"
    cd "$fixture_root"
    set +e
    lauren_loop_competitive "$slug" "force rerun preserves the old manifest and creates a new run manifest" >/dev/null 2>&1
    rc=$?
    set -e
    cleanup_v2 || true
    cd "$original_dir"
    [[ "$rc" -eq 1 ]] || { echo "expected force rerun preflight failure rc=1, got $rc" >&2; exit 1; }
    backup_manifest=$(find "$comp_dir/backups" -path '*/run-manifest.json' | head -1)
    [[ -n "$backup_manifest" && -f "$backup_manifest" ]] || { echo "expected backup manifest under $comp_dir/backups" >&2; exit 1; }
    jq -e '
        .run_id == "seeded-run-id" and
        .final_status == "success" and
        .total_cost_usd == "0.1234"
    ' "$backup_manifest" >/dev/null || { echo "backup manifest contents drifted" >&2; exit 1; }
    jq -e '
        .run_id != "seeded-run-id" and
        .force_rerun == true and
        .final_status == "cleanup" and
        .total_cost_usd == "0.0000"
    ' "$comp_dir/run-manifest.json" >/dev/null || { echo "live manifest did not reflect a fresh cleanup-finalized force rerun" >&2; exit 1; }
    grep -q '^## Status: blocked$' "$fixture_root/docs/tasks/open/$slug/task.md" \
        || { echo "force rerun cleanup did not leave task status blocked" >&2; exit 1; }
) && pass "54f. force rerun preserves the old manifest in backup and writes a fresh live manifest" \
  || fail "54f. force rerun preserves the old manifest in backup and writes a fresh live manifest"

# ============================================================
# Test 54g: failed phase entries record failed status, error_class, and valid JSON
# ============================================================
(
    root="$TMP_ROOT/manifest-failed-phase"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-failed-phase"
    goal="Record a failed phase entry"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _init_run_manifest
    _FAIL_PHASE_PHASE_ID="phase-4"
    _FAIL_PHASE_PHASE_NAME="execute"
    _FAIL_PHASE_PHASE_STARTED_AT="2026-03-20T00:00:00Z"
    set +e
    _fail_phase \
        "executing" \
        "Failed to merge execution worktree" \
        "Check merge conflicts, then retry" \
        "merge_failure" \
        $'phase=phase-4; step=_v2_merge_execution_worktree\nretry=manual'
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        .final_status == "blocked" and
        (.phases | length) == 1 and
        .phases[0].phase == "phase-4" and
        .phases[0].name == "execute" and
        .phases[0].status == "failed" and
        .phases[0].error_class == "merge_failure" and
        .phases[0].error_detail == "phase=phase-4; step=_v2_merge_execution_worktree retry=manual" and
        .phases[0].cost == "0.00"
    ' "$comp_dir/run-manifest.json" >/dev/null
    jq -e '.' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54g. failed phase entries record failed status, error_class, and valid JSON" \
  || fail "54g. failed phase entries record failed status, error_class, and valid JSON"

# ============================================================
# Test 54h: failed phase entries record cumulative measured cost in manifest format
# ============================================================
(
    root="$TMP_ROOT/manifest-failed-phase-cost"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-failed-phase-cost"
    goal="Record cumulative failure cost"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _init_run_manifest
    _append_cost_csv_raw_row \
        "$TASK_LOG_DIR/.cost-phase5.csv" "$(_iso_timestamp)" "$slug" "reviewer-a" "claude" "opus" \
        "medium" "1" "0" "0" "1" "0.0003" "30" "1" "failed"
    _FAIL_PHASE_PHASE_ID="phase-5"
    _FAIL_PHASE_PHASE_NAME="review-cycle-1"
    _FAIL_PHASE_PHASE_STARTED_AT="2026-03-20T00:00:00Z"
    set +e
    _fail_phase \
        "reviewing" \
        "Both reviewers failed (A=1, B=2)" \
        "Check reviewer logs, then retry" \
        "unknown" \
        "reviewer_a_exit=1; reviewer_b_exit=2"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        .total_cost_usd == "0.0003" and
        (.phases | length) == 1 and
        .phases[0].cost == "0.0003" and
        .phases[0].error_class == "unknown"
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54h. failed phase entries record cumulative measured cost in manifest format" \
  || fail "54h. failed phase entries record cumulative measured cost in manifest format"

# ============================================================
# Test 54i: _fail_phase defaults error_class and error_detail for legacy callers
# ============================================================
(
    root="$TMP_ROOT/manifest-failed-phase-defaults"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-failed-phase-defaults"
    goal="Default failure metadata for legacy callers"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _init_run_manifest
    _FAIL_PHASE_PHASE_ID="phase-1"
    _FAIL_PHASE_PHASE_NAME="explore"
    _FAIL_PHASE_PHASE_STARTED_AT="2026-03-20T00:00:00Z"
    set +e
    _fail_phase "exploring" "Failed to assemble explorer prompt" "Retry after checking the prompt"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        (.phases | length) == 1 and
        .phases[0].status == "failed" and
        .phases[0].error_class == "unknown" and
        .phases[0].error_detail == ""
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54i. _fail_phase defaults error_class and error_detail for legacy callers" \
  || fail "54i. _fail_phase defaults error_class and error_detail for legacy callers"

# ============================================================
# Test 54j: failed manifest error_detail preserves quotes, backslashes, and tabs
# ============================================================
(
    root="$TMP_ROOT/manifest-failed-phase-special-chars"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-failed-phase-special-chars"
    goal="Preserve error_detail special characters"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    restore_real_manifest_hooks
    _init_run_manifest
    error_detail=$'detail="quoted path" C:\\temp\\artifact\tcolumn'
    _append_manifest_phase \
        "phase-4" \
        "execute" \
        "2026-03-20T00:00:00Z" \
        "2026-03-20T00:00:30Z" \
        "failed" \
        "" \
        "0.00" \
        "invalid_artifact" \
        "$error_detail"
    actual_error_detail=$(jq -r '.phases[0].error_detail' "$comp_dir/run-manifest.json")
    [[ "$actual_error_detail" == "$error_detail" ]]
    jq -e '.' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54j. failed manifest error_detail preserves quotes, backslashes, and tabs" \
  || fail "54j. failed manifest error_detail preserves quotes, backslashes, and tabs"

# ============================================================
# Test 54k: _fail_phase still appends a failed phase when phase context globals are unset
# ============================================================
(
    root="$TMP_ROOT/manifest-failed-phase-missing-context"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-failed-phase-missing-context"
    goal="Fallback failure metadata without phase context"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _init_run_manifest
    unset _FAIL_PHASE_PHASE_ID _FAIL_PHASE_PHASE_NAME _FAIL_PHASE_PHASE_STARTED_AT
    set +e
    _fail_phase "evaluating-reviews" "Phase 6 review evaluation produced no verdict" "Retry after checking the synthesis artifact"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        (.phases | length) == 1 and
        .phases[0].phase == "" and
        .phases[0].name == "" and
        .phases[0].status == "failed" and
        .phases[0].started_at == .phases[0].completed_at
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54k. _fail_phase still appends a failed phase when phase context globals are unset" \
  || fail "54k. _fail_phase still appends a failed phase when phase context globals are unset"

# ============================================================
# Test 54l: malformed cost rows leave failed phase cost at the safe 0.00 fallback
# ============================================================
(
    root="$TMP_ROOT/manifest-failed-phase-malformed-cost"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-failed-phase-malformed-cost"
    goal="Fallback failure cost for malformed cost rows"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _init_run_manifest
    printf '%s\n' "$COST_CSV_HEADER" > "$TASK_LOG_DIR/.cost-phase6.csv"
    printf '%s\n' \
        '2026-03-20T00:00:30Z,manifest-failed-phase-malformed-cost,review-evaluator,claude,opus,medium,1,0,0,1,not-a-number,30,1,failed' \
        >> "$TASK_LOG_DIR/.cost-phase6.csv"
    _FAIL_PHASE_PHASE_ID="phase-6a"
    _FAIL_PHASE_PHASE_NAME="review-eval-cycle-1"
    _FAIL_PHASE_PHASE_STARTED_AT="2026-03-20T00:00:00Z"
    set +e
    _fail_phase \
        "evaluating-reviews" \
        "Phase 6 review evaluation produced an invalid synthesis artifact" \
        "Check review-synthesis.md and retry" \
        "invalid_artifact" \
        "artifact=competitive/review-synthesis.md"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        (.phases | length) == 1 and
        .phases[0].status == "failed" and
        .phases[0].cost == "0.00"
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54l. malformed cost rows leave failed phase cost at the safe 0.00 fallback" \
  || fail "54l. malformed cost rows leave failed phase cost at the safe 0.00 fallback"

# ============================================================
# Test 54u: recoverable merge failures append structured recovery metadata to the manifest
# ============================================================
(
    root="$TMP_ROOT/manifest-recoverable-merge"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-recoverable-merge"
    goal="Record recoverable merge metadata"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _init_run_manifest
    _V2_LAST_MERGE_RECOVERABLE=true
    _V2_PRESERVED_EXEC_TARGET_REF="refs/heads/recovery-target"
    _V2_PRESERVED_EXEC_TARGET_HEAD_SHA="1111111111111111111111111111111111111111"
    _V2_PRESERVED_EXEC_WORKTREE_BRANCH="ll-exec-recovery"
    _V2_PRESERVED_EXEC_WORKTREE_PATH="/tmp/ll-exec-recovery"
    _V2_PRESERVED_EXEC_COMMIT_SHA="2222222222222222222222222222222222222222"
    _V2_PRESERVED_RECOVERY_DIR="/tmp/ll-exec-recovery-artifacts"
    _V2_PRESERVED_COMBINED_PATCH="/tmp/ll-exec-recovery-artifacts/combined.patch"
    _V2_PRESERVED_COMMIT_LOG="/tmp/ll-exec-recovery-artifacts/commits.txt"
    _V2_PRESERVED_FORMAT_PATCH_DIR="/tmp/ll-exec-recovery-artifacts/format-patch"
    _V2_PRESERVED_WORKTREE_PATCH="/tmp/ll-exec-recovery-artifacts/worktree.patch"
    _FAIL_PHASE_PHASE_ID="phase-4"
    _FAIL_PHASE_PHASE_NAME="execute"
    _FAIL_PHASE_PHASE_STARTED_AT="2026-03-20T00:00:00Z"
    set +e
    _fail_phase \
        "executing" \
        "Failed to merge execution worktree" \
        "Resolve manually from the preserved worktree" \
        "merge_failure" \
        "phase=phase-4; step=_v2_merge_execution_worktree; branch=ll-exec-recovery"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        .final_status == "blocked" and
        (.phases | length) == 1 and
        .phases[0].status == "failed" and
        .phases[0].error_class == "merge_failure" and
        .phases[0].recovery.target_ref == "refs/heads/recovery-target" and
        .phases[0].recovery.target_head_sha == "1111111111111111111111111111111111111111" and
        .phases[0].recovery.branch == "ll-exec-recovery" and
        .phases[0].recovery.worktree_path == "/tmp/ll-exec-recovery" and
        .phases[0].recovery.preserved_commit == "2222222222222222222222222222222222222222" and
        .phases[0].recovery.recovery_dir == "/tmp/ll-exec-recovery-artifacts" and
        .phases[0].recovery.combined_patch == "/tmp/ll-exec-recovery-artifacts/combined.patch" and
        .phases[0].recovery.commit_log == "/tmp/ll-exec-recovery-artifacts/commits.txt" and
        .phases[0].recovery.format_patch_dir == "/tmp/ll-exec-recovery-artifacts/format-patch" and
        .phases[0].recovery.worktree_patch == "/tmp/ll-exec-recovery-artifacts/worktree.patch"
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54u. recoverable merge failures append structured recovery metadata to the manifest" \
  || fail "54u. recoverable merge failures append structured recovery metadata to the manifest"

# ============================================================
# Test 54m: _require_valid_artifact missing-artifact failures classify as invalid_artifact
# ============================================================
(
    root="$TMP_ROOT/manifest-invalid-artifact"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-invalid-artifact"
    goal="Missing artifacts classify as invalid_artifact"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    load_real_require_valid_artifact_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _init_run_manifest
    _FAIL_PHASE_PHASE_ID="phase-6a"
    _FAIL_PHASE_PHASE_NAME="review-eval-cycle-1"
    _FAIL_PHASE_PHASE_STARTED_AT="2026-03-20T00:00:00Z"
    set +e
    _require_valid_artifact \
        "${comp_dir}/review-synthesis.md" \
        "evaluating-reviews" \
        "Phase 6 review evaluation produced an invalid synthesis artifact" \
        "Check review-synthesis.md and retry"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        (.phases | length) == 1 and
        .phases[0].status == "failed" and
        .phases[0].error_class == "invalid_artifact" and
        (.phases[0].error_detail | type == "string" and length > 0)
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54m. _require_valid_artifact missing-artifact failures classify as invalid_artifact" \
  || fail "54m. _require_valid_artifact missing-artifact failures classify as invalid_artifact"

# ============================================================
# Test 54n: phase 1 agent timeout bypass records timeout even when Codex logs capacity markers
# ============================================================
(
    slug="manifest-phase1-timeout"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    restore_real_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EXPLORE="codex"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _preflight_dependency_check() { return 0; }
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" _output="$5" log_file="$6"
        : > "$log_file"
        case "$role" in
            explorer)
                printf 'too_many_requests: simulated Codex capacity marker before timeout\n' >> "$log_file"
                return 124
                ;;
        esac
        return 0
    }
    set +e
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "record a timeout-classified phase-1 failure"
    ) >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        .final_status == "blocked" and
        (.phases | length) == 1 and
        .phases[0].phase == "phase-1" and
        .phases[0].name == "explore" and
        .phases[0].status == "failed" and
        .phases[0].error_class == "timeout" and
        (.phases[0].error_detail | contains("role=explorer")) and
        (.phases[0].cost | type == "string" and length > 0)
    ' "$comp_dir/run-manifest.json" >/dev/null
    jq -e '.' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54n. phase 1 agent timeout bypass records timeout ahead of Codex capacity markers" \
  || fail "54n. phase 1 agent timeout bypass records timeout ahead of Codex capacity markers"

# ============================================================
# Test 54o: scope-violation bypasses append failed manifest entries through _block_on_untracked_files
# ============================================================
(
    root="$TMP_ROOT/manifest-scope-violation"
    comp_dir="$root/competitive"
    TASK_LOG_DIR="$root/logs"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"
    slug="manifest-scope-violation"
    goal="Record a scope violation bypass"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _CURRENT_TASK_FILE=""
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    restore_real_manifest_hooks
    load_real_fail_phase_helper
    task_file="$root/task.md"
    : > "$task_file"
    fix_cycle=0
    set_task_status() { :; }
    log_execution() { :; }
    finalize_v2_task_metadata() { :; }
    _print_cost_summary() { :; }
    _v2_resolve_scope_paths() {
        _V2_SCOPE_SOURCE="plan-files-to-modify"
        _V2_SCOPE_PATHS=$'src/main.py\nsrc/util.py'
        return 0
    }
    _collect_blocking_untracked_files() {
        printf 'src/main.py\nsrc/util.py\n'
    }
    _v2_scope_fallback_warning_message() { :; }
    _v2_scope_diagnostic_lines() {
        printf 'scope_paths=%s\n' "$1"
    }
    _init_run_manifest
    _FAIL_PHASE_PHASE_ID="phase-4"
    _FAIL_PHASE_PHASE_NAME="execute"
    _FAIL_PHASE_PHASE_STARTED_AT="2026-03-20T00:00:00Z"
    set +e
    _block_on_untracked_files "$task_file" "Phase 4" "${comp_dir}/revised-plan.md" "abc123"
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        .final_status == "blocked" and
        (.phases | length) == 1 and
        .phases[0].phase == "phase-4" and
        .phases[0].name == "execute" and
        .phases[0].status == "failed" and
        .phases[0].error_class == "scope_violation" and
        (.phases[0].error_detail | contains("scope_source=plan-files-to-modify"))
    ' "$comp_dir/run-manifest.json" >/dev/null
    jq -e '.' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54o. scope-violation bypasses append failed manifest entries via _block_on_untracked_files" \
  || fail "54o. scope-violation bypasses append failed manifest entries via _block_on_untracked_files"

# ============================================================
# Test 54p: non-blocking phase 7 BLOCKED appends a failed phase entry and preserves human_review final status
# ============================================================
(
    slug="manifest-phase7-human-review"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    write_review_synthesis_artifact "$comp_dir/review-synthesis.md" "FAIL" 0 1 0 0
    write_repo_pytest_fix_plan_artifact "$comp_dir/fix-plan.md"
    _write_cycle_state "$comp_dir" 0 "phase-6b" "FAIL"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    restore_real_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_FIX="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    _preflight_dependency_check() { return 0; }
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            fix-critic-r*) write_plan_critique_artifact "$output" "EXECUTE" ;;
            fix-executor*)
                printf 'BLOCKED: %s - .venv/bin/python -m pytest tests/ -x -q\n' "$(_verification_timeout_message)" \
                    > "$SCRIPT_DIR/docs/tasks/open/$slug/competitive/fix-execution.md"
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "append a failed phase entry for the human-review BLOCKED path"
    ) >/dev/null 2>&1
    grep -q '^## Status: needs verification$' "$fixture_root/docs/tasks/open/$slug/task.md"
    jq -e '
        .final_status == "human_review" and
        ([.phases[] | select(.phase == "phase-7" and .status == "failed" and .error_class == "timeout" and (.error_detail | contains("status_signal=BLOCKED")))] | length) == 1
    ' "$comp_dir/run-manifest.json" >/dev/null
    jq -e '.' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54p. non-blocking phase 7 BLOCKED appends a failed phase entry while preserving human_review final status" \
  || fail "54p. non-blocking phase 7 BLOCKED appends a failed phase entry while preserving human_review final status"

# ============================================================
# Test 54q: non-timeout Codex failures prioritize capacity markers ahead of stream markers
# ============================================================
(
    slug="manifest-phase1-codex-capacity-priority"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    restore_real_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    ENGINE_EXPLORE="codex"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    _preflight_dependency_check() { return 0; }
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    _print_cost_summary() { :; }
    _print_phase_timing() { :; }
    run_agent() {
        local role="$1" _engine="$2" _body="$3" _system="$4" _output="$5" log_file="$6"
        : > "$log_file"
        case "$role" in
            explorer)
                printf 'too_many_requests: simulated Codex capacity marker before stream failure\n' >> "$log_file"
                printf 'response.failed: simulated Codex stream marker after capacity marker\n' >> "$log_file"
                return 1
                ;;
        esac
        return 0
    }
    set +e
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "record a codex_capacity-classified phase-1 failure"
    ) >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    jq -e '
        .final_status == "blocked" and
        (.phases | length) == 1 and
        .phases[0].phase == "phase-1" and
        .phases[0].name == "explore" and
        .phases[0].status == "failed" and
        .phases[0].error_class == "codex_capacity" and
        (.phases[0].error_detail | contains("role=explorer")) and
        (.phases[0].cost | type == "string" and length > 0)
    ' "$comp_dir/run-manifest.json" >/dev/null
    jq -e '.' "$comp_dir/run-manifest.json" >/dev/null
) && pass "54q. non-timeout Codex failures classify as codex_capacity ahead of codex_stream markers" \
  || fail "54q. non-timeout Codex failures classify as codex_capacity ahead of codex_stream markers"

(
    task_file="$TMP_ROOT/task-goal-colon-block/task.md"
    mkdir -p "$(dirname "$task_file")"
    cat > "$task_file" <<'EOF'
## Task: colon-block
## Status: in progress

## Goal:
  first line
  second line
## Next Section
EOF
    set +e
    goal_text="$(_task_goal_content "$task_file" | _trim_nonblank_lines)"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    [[ "$goal_text" == $'first line\nsecond line' ]]
) && pass "54r. task goal parser treats blank ## Goal: headers as multiline blocks" \
  || fail "54r. task goal parser treats blank ## Goal: headers as multiline blocks"

(
    task_file="$TMP_ROOT/task-goal-inline-colon/task.md"
    mkdir -p "$(dirname "$task_file")"
    cat > "$task_file" <<'EOF'
## Task: inline-goal
## Status: in progress

## Goal: inline text
## Next
EOF
    set +e
    goal_text="$(_task_goal_content "$task_file" | _trim_nonblank_lines)"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    [[ "$goal_text" == "inline text" ]]
) && pass "54s. task goal parser preserves inline ## Goal: content" \
  || fail "54s. task goal parser preserves inline ## Goal: content"

(
    task_file="$TMP_ROOT/task-goal-empty-colon/task.md"
    mkdir -p "$(dirname "$task_file")"
    cat > "$task_file" <<'EOF'
## Task: empty-colon-goal
## Status: in progress

## Goal:

## Next
EOF
    set +e
    goal_text="$(_task_goal_content "$task_file" | _trim_nonblank_lines)"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    [[ -z "$goal_text" ]]
) && pass "54t. task goal parser returns empty content for blank ## Goal: sections" \
  || fail "54t. task goal parser returns empty content for blank ## Goal: sections"

(
    task_file="$TMP_ROOT/task-gate-missing-goal/task.md"
    mkdir -p "$(dirname "$task_file")"
    cat > "$task_file" <<'EOF'
## Task: missing-goal
## Status: in progress

## Current Plan
Plan body
EOF
    set +e
    _validate_task_file_content "$task_file" > "$TMP_ROOT/task-gate-missing-goal.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q '^## Goal section is missing$' "$TMP_ROOT/task-gate-missing-goal.out"
) && pass "55. task-content gate rejects files without a ## Goal section" \
  || fail "55. task-content gate rejects files without a ## Goal section"

(
    task_file="$TMP_ROOT/task-gate-empty-goal/task.md"
    mkdir -p "$(dirname "$task_file")"
    cat > "$task_file" <<'EOF'
## Task: empty-goal
## Status: in progress

## Goal

## Current Plan
Plan body
EOF
    set +e
    _validate_task_file_content "$task_file" > "$TMP_ROOT/task-gate-empty-goal.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q '^## Goal section is empty$' "$TMP_ROOT/task-gate-empty-goal.out"
) && pass "56. task-content gate rejects an empty ## Goal section" \
  || fail "56. task-content gate rejects an empty ## Goal section"

(
    task_file="$TMP_ROOT/task-gate-placeholder-goal/task.md"
    mkdir -p "$(dirname "$task_file")"
    cat > "$task_file" <<'EOF'
## Task: placeholder-goal
## Status: in progress
## Goal: TODO

## Current Plan
Plan body
EOF
    set +e
    _validate_task_file_content "$task_file" > "$TMP_ROOT/task-gate-placeholder-goal.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q '^## Goal section still contains placeholder text$' "$TMP_ROOT/task-gate-placeholder-goal.out"
) && pass "57. task-content gate rejects placeholder goal text" \
  || fail "57. task-content gate rejects placeholder goal text"

(
    task_file="$TMP_ROOT/task-gate-v1-skeleton/task.md"
    mkdir -p "$(dirname "$task_file")"
    write_v1_shell_skeleton_task "$task_file" "Protect verification from hanging"
    set +e
    _validate_task_file_content "$task_file" > "$TMP_ROOT/task-gate-v1-skeleton.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q 'untouched Lauren Loop skeleton' "$TMP_ROOT/task-gate-v1-skeleton.out"
) && pass "58. task-content gate rejects untouched V1 shell skeletons" \
  || fail "58. task-content gate rejects untouched V1 shell skeletons"

(
    task_file="$TMP_ROOT/task-gate-v2-skeleton/task.md"
    mkdir -p "$(dirname "$task_file")"
    write_v2_shell_skeleton_task "$task_file" "task-gate-v2" "Protect verification from hanging"
    set +e
    _validate_task_file_content "$task_file" > "$TMP_ROOT/task-gate-v2-skeleton.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q 'untouched Lauren Loop skeleton' "$TMP_ROOT/task-gate-v2-skeleton.out"
) && pass "59. task-content gate rejects untouched V2 shell skeletons" \
  || fail "59. task-content gate rejects untouched V2 shell skeletons"

(
    task_file="$TMP_ROOT/task-gate-real-goal/task.md"
    mkdir -p "$(dirname "$task_file")"
    cat > "$task_file" <<'EOF'
## Task: real-goal
## Status: in progress

## Goal
Prevent Lauren Loop from starting execution on untouched task skeletons.

## Current Plan
Plan body

## Critique
Critique body

## Left Off At:
Waiting for implementation.

## Attempts:
- 2026-03-19: Captured reproduction details. -> Result: worked
EOF
    _validate_task_file_content "$task_file"
) && pass "60. task-content gate allows populated goals with real task content" \
  || fail "60. task-content gate allows populated goals with real task content"

(
    ! _should_enforce_task_file_content_gate "true" "false"
    ! _should_enforce_task_file_content_gate "true" "true"
) && pass "61a. task-content gate skips dry-run paths" \
  || fail "61a. task-content gate skips dry-run paths"

(
    _LAUREN_LOOP_V1_AUTO_WRAPPER=1
    ! _should_enforce_task_file_content_gate "false" "false" "0"
) && pass "61b. task-content gate skips routed V1 auto wrapper paths" \
  || fail "61b. task-content gate skips routed V1 auto wrapper paths"

(
    ! _should_enforce_task_file_content_gate "false" "true"
    ! _should_enforce_task_file_content_gate "false" "false" "1"
    _should_enforce_task_file_content_gate "false" "false" "0"
) && pass "61. task-content gate skips resume paths and still runs for fresh execution" \
  || fail "61. task-content gate skips resume paths and still runs for fresh execution"

(
    SCRIPT_DIR="$REPO_ROOT"
    wrapped=$(_timeout_wrapped_verification_command ".venv/bin/python -m pytest tests/ -x -q")
    printf '%s\n' "$wrapped" | grep -Eq '_timeout(\\ | )20m'
    printf '%s\n' "$wrapped" | grep -Fq 'lib/lauren-loop-utils.sh'
    printf '%s\n' "$wrapped" | grep -Fq 'pytest'
) && pass "62. timeout helper builds a shell-level 20m verification wrapper" \
  || fail "62. timeout helper builds a shell-level 20m verification wrapper"

(
    unset SCRIPT_DIR
    wrapped=$(_timeout_wrapped_verification_command ".venv/bin/python -m pytest tests/ -x -q")
    printf '%s\n' "$wrapped" | grep -Fq "$REPO_ROOT/lib/lauren-loop-utils.sh"
    ! printf '%s\n' "$wrapped" | grep -Fq 'source\ /lib/lauren-loop-utils.sh'
    _command_uses_timeout_wrapper "$wrapped"
) && pass "62a. timeout helper falls back to the sourced library path when SCRIPT_DIR is unset" \
  || fail "62a. timeout helper falls back to the sourced library path when SCRIPT_DIR is unset"

(
    SCRIPT_DIR="$REPO_ROOT"
    output=$(printf '%s' 'Baseline: .venv/bin/python -m pytest tests/ -x -q before execution.' | _normalize_executor_prompt_timeout_content "test prompt")
    printf '%s\n' "$output" | grep -Fq 'Baseline: bash -lc'
    printf '%s\n' "$output" | grep -Fq '_timeout'
    printf '%s\n' "$output" | grep -Fq 'lib/lauren-loop-utils.sh'
    printf '%s\n' "$output" | grep -Fq 'pytest'
) && pass "63. executor prompt timeout normalization wraps the repo-standard pytest literal" \
  || fail "63. executor prompt timeout normalization wraps the repo-standard pytest literal"

(
    SCRIPT_DIR="$REPO_ROOT"
    set +e
    printf '%s' 'Baseline: pytest -q before execution.' | _normalize_executor_prompt_timeout_content "drifted prompt" > "$TMP_ROOT/executor-timeout-drift.out" 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q 'expected repo-standard pytest verification command in executor prompt but found none' "$TMP_ROOT/executor-timeout-drift.out"
) && pass "64. executor prompt timeout normalization fails closed on prompt drift" \
  || fail "64. executor prompt timeout normalization fails closed on prompt drift"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-implementation-only/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>.venv/bin/python -m pytest tests/ -x -q</verify>

## Test Strategy

Example only: <verify>.venv/bin/python -m pytest tests/ -x -q</verify>
EOF
    SCRIPT_DIR="$REPO_ROOT"
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "implementation-task-only normalization"
    grep -Fq '<verify>bash -lc ' "$plan_file"
    grep -Fq 'Example only: <verify>.venv/bin/python -m pytest tests/ -x -q</verify>' "$plan_file"
) && pass "65a. verify-tag timeout normalization only mutates Implementation Tasks" \
  || fail "65a. verify-tag timeout normalization only mutates Implementation Tasks"

(
    plan_file="$TMP_ROOT/normalize-verify-tags/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    write_repo_pytest_plan_artifact "$plan_file" "Normalization Plan" "Normalize verify tags"
    SCRIPT_DIR="$REPO_ROOT"
    set +e
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "verify tag normalization"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    grep -Fq '<verify>bash -lc ' "$plan_file"
    grep -Fq '_timeout' "$plan_file"
    grep -Fq 'lib/lauren-loop-utils.sh' "$plan_file"
    ! grep -Fq '<verify>.venv/bin/python -m pytest tests/ -x -q</verify>' "$plan_file"
) && pass "65. verify-tag timeout normalization wraps repo-standard pytest commands" \
  || fail "65. verify-tag timeout normalization wraps repo-standard pytest commands"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-superset/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>.venv/bin/python -m pytest tests/ -x -q tests/test_handler_registry.py -v</verify>
EOF
    SCRIPT_DIR="$REPO_ROOT"
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "superset verify normalization"
    grep -Fq '<verify>bash -lc ' "$plan_file"
    grep -Fq 'tests/test_handler_registry.py' "$plan_file"
) && pass "65b. verify-tag timeout normalization wraps superset repo-standard pytest commands" \
  || fail "65b. verify-tag timeout normalization wraps superset repo-standard pytest commands"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-wrapped/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    SCRIPT_DIR="$REPO_ROOT"
    wrapped=$(_timeout_wrapped_verification_command ".venv/bin/python -m pytest tests/ -x -q")
    cat > "$plan_file" <<EOF
# Plan Artifact

## Implementation Tasks

<verify>${wrapped}</verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "already wrapped normalization"
    [[ "$(grep -o 'lib/lauren-loop-utils.sh' "$plan_file" | wc -l | tr -d ' ')" -eq 1 ]]
    grep -Fq '_timeout\ 20m' "$plan_file"
) && pass "65c. verify-tag timeout normalization does not double-wrap already wrapped commands" \
  || fail "65c. verify-tag timeout normalization does not double-wrap already wrapped commands"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-indented/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

    <verify>.venv/bin/python -m pytest tests/ -x -q</verify>
EOF
    SCRIPT_DIR="$REPO_ROOT"
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "indented verify normalization"
    grep -Eq '^    <verify>bash -lc ' "$plan_file"
) && pass "65d. verify-tag timeout normalization wraps indented single-line verify tags" \
  || fail "65d. verify-tag timeout normalization wraps indented single-line verify tags"

(
    SCRIPT_DIR="$REPO_ROOT"
    wrapped=$(_timeout_wrapped_verification_command ".venv/bin/python -m pytest tests/ -x -q")
    _command_uses_timeout_wrapper "$wrapped"
) && pass "65e. timeout wrapper detection recognizes escaped generated wrapper output" \
  || fail "65e. timeout wrapper detection recognizes escaped generated wrapper output"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-multiline/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>
pytest tests/foo.py
pytest tests/bar.py
</verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "multiline verify plan"
    grep -Fq '<verify>pytest tests/foo.py && pytest tests/bar.py</verify>' "$plan_file"
) && pass "66. verify-tag timeout normalization collapses multi-line verify commands with &&" \
  || fail "66. verify-tag timeout normalization collapses multi-line verify commands with &&"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-section-boundary/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>
cmd
## Test Strategy
Example only:
</verify>
EOF
    before="$(cat "$plan_file")"
    set +e
    output="$(_normalize_verify_tags_with_timeout_in_file "$plan_file" "section boundary verify normalization" 2>&1)"
    rc=$?
    set -e
    after="$(cat "$plan_file")"
    [[ "$rc" -ne 0 ]]
    printf '%s\n' "$output" | grep -Fq 'unterminated multi-line <verify> tag crossed a section boundary'
    [[ "$before" == "$after" ]]
) && pass "66a. verify-tag timeout normalization fails closed when accumulation crosses a section boundary" \
  || fail "66a. verify-tag timeout normalization fails closed when accumulation crosses a section boundary"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-comment-fragment/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>
cmd1
  # comment
cmd2
</verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "comment fragment verify normalization"
    grep -Fq '<verify>cmd1 && cmd2</verify>' "$plan_file"
    ! grep -Fq '# comment' "$plan_file"
) && pass "66b. verify-tag timeout normalization skips comment-only fragments during multiline collapse" \
  || fail "66b. verify-tag timeout normalization skips comment-only fragments during multiline collapse"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-trailing-operator/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>
cmd1 &&
cmd2
</verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "trailing operator verify normalization"
    grep -Fq '<verify>cmd1 && cmd2</verify>' "$plan_file"
    ! grep -Fq '&& &&' "$plan_file"
) && pass "66c. verify-tag timeout normalization preserves a trailing operator split across lines" \
  || fail "66c. verify-tag timeout normalization preserves a trailing operator split across lines"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-leading-operator/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>
cmd1
&& cmd2
</verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "leading operator verify normalization"
    grep -Fq '<verify>cmd1 && cmd2</verify>' "$plan_file"
    ! grep -Fq '&& &&' "$plan_file"
) && pass "66d. verify-tag timeout normalization preserves a leading operator split across lines" \
  || fail "66d. verify-tag timeout normalization preserves a leading operator split across lines"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-nested/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>
cmd1
<verify>
cmd2
</verify>
EOF
    before="$(cat "$plan_file")"
    set +e
    output="$(_normalize_verify_tags_with_timeout_in_file "$plan_file" "nested verify normalization" 2>&1)"
    rc=$?
    set -e
    after="$(cat "$plan_file")"
    [[ "$rc" -ne 0 ]]
    printf '%s\n' "$output" | grep -Fq 'nested <verify> tags are not supported'
    [[ "$before" == "$after" ]]
) && pass "66e. verify-tag timeout normalization still fails closed on nested multiline verify tags" \
  || fail "66e. verify-tag timeout normalization still fails closed on nested multiline verify tags"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-eof-unclosed/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>
cmd1
cmd2
EOF
    before="$(cat "$plan_file")"
    set +e
    output="$(_normalize_verify_tags_with_timeout_in_file "$plan_file" "eof verify normalization" 2>&1)"
    rc=$?
    set -e
    after="$(cat "$plan_file")"
    [[ "$rc" -ne 0 ]]
    printf '%s\n' "$output" | grep -Fq 'unterminated multi-line <verify> tag'
    [[ "$before" == "$after" ]]
) && pass "66f. verify-tag timeout normalization still fails closed on EOF-unclosed multiline verify tags" \
  || fail "66f. verify-tag timeout normalization still fails closed on EOF-unclosed multiline verify tags"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-orphan-closer/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

</verify>
EOF
    before="$(cat "$plan_file")"
    set +e
    output="$(_normalize_verify_tags_with_timeout_in_file "$plan_file" "orphan closer verify normalization" 2>&1)"
    rc=$?
    set -e
    after="$(cat "$plan_file")"
    [[ "$rc" -ne 0 ]]
    printf '%s\n' "$output" | grep -Fq 'closing </verify> tag without a matching opener'
    [[ "$before" == "$after" ]]
) && pass "66g. verify-tag timeout normalization still fails closed on orphan closing tags" \
  || fail "66g. verify-tag timeout normalization still fails closed on orphan closing tags"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-inline-opener/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>cmd1
cmd2
</verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "inline opener verify normalization"
    grep -Fq '<verify>cmd1 && cmd2</verify>' "$plan_file"
) && pass "66h. verify-tag timeout normalization preserves inline opener content with continuation lines" \
  || fail "66h. verify-tag timeout normalization preserves inline opener content with continuation lines"

(
    slug="phase4-timeout-blocked"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
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
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="claude"
    ENGINE_CRITIC="claude"
    ENGINE_EXECUTOR="claude"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            explorer) printf '# Exploration Summary\n\nTimeout regression coverage.\n' > "$output" ;;
            planner-a|planner-b) write_repo_pytest_plan_artifact "$output" "Plan Artifact" "Exercise timeout sentinel handling" ;;
            evaluator) write_plan_evaluation_artifact "$output" ;;
            plan-critic-r*) write_plan_critique_artifact "$output" "EXECUTE" ;;
            executor)
                printf 'BLOCKED: %s - .venv/bin/python -m pytest tests/ -x -q\n' "$(_verification_timeout_message)" \
                    > "$SCRIPT_DIR/docs/tasks/open/$slug/competitive/execution-log.md"
                ;;
        esac
        return 0
    }
    set +e
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "mark phase 4 verification timeout as blocked"
    ) >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q '^## Status: blocked$' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q "Phase 4: $(_verification_timeout_message)" "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q '^executor$' "$ROLE_LOG"
) && pass "67. V2 phase 4 maps verification timeout sentinels to blocked status" \
  || fail "67. V2 phase 4 maps verification timeout sentinels to blocked status"

(
    slug="phase7-timeout-handoff"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    write_review_synthesis_artifact "$comp_dir/review-synthesis.md" "FAIL" 0 1 0 0
    write_repo_pytest_fix_plan_artifact "$comp_dir/fix-plan.md"
    _write_cycle_state "$comp_dir" 0 "phase-6b" "FAIL"
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
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            fix-executor*)
                printf 'BLOCKED: %s - .venv/bin/python -m pytest tests/ -x -q\n' "$(_verification_timeout_message)" \
                    > "$SCRIPT_DIR/docs/tasks/open/$slug/competitive/fix-execution.md"
                ;;
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "No findings."
                ;;
            reviewer-b*) write_review_artifact "$output" "PASS" "No findings." ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "surface phase 7 verification timeout for human review"
    ) >/dev/null 2>&1
    grep -q '^## Status: needs verification$' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q "Phase 7: $(_verification_timeout_message)" "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q 'Phase 7: Fix executor STATUS: BLOCKED' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q '"status":"BLOCKED"' "$comp_dir/fix-execution.contract.json"
    grep -q '\*\*Final review verdict:\*\* BLOCKED' "$comp_dir/human-review-handoff.md"
    grep -q '^fix-executor$' "$ROLE_LOG"
) && pass "68. V2 phase 7 routes verification timeout sentinels through the human-review BLOCKED path" \
  || fail "68. V2 phase 7 routes verification timeout sentinels through the human-review BLOCKED path"

(
    slug="phase7-early-handoff-complete"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    write_review_synthesis_artifact "$comp_dir/review-synthesis.md" "FAIL" 0 1 0 0
    write_fix_plan_artifact "$comp_dir/fix-plan.md" "yes"
    _write_cycle_state "$comp_dir" 0 "phase-6b" "FAIL"
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
    LAUREN_LOOP_PHASE7_HANDOFF_POLL_INTERVAL_SEC="0.2"
    LAUREN_LOOP_PHASE7_HANDOFF_GRACE_SEC="0.2"
    ENGINE_CRITIC="claude"
    ENGINE_FIX="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            fix-executor*)
                write_fix_execution_artifact "$SCRIPT_DIR/docs/tasks/open/$slug/competitive/fix-execution.md" "COMPLETE"
                sleep 5
                ;;
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            reviewer-b*) write_review_artifact "$output" "FAIL" "[major/correctness] file:1 - issue
-> fix" ;;
            review-evaluator*) write_review_synthesis_artifact "$output" "FAIL" 0 1 0 0 ;;
            fix-plan-author*) write_fix_plan_artifact "$output" "yes" ;;
        esac
        return 0
    }
    start_ts=$(date +%s)
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "phase 7 early handoff completes from synced artifacts"
    ) >/dev/null 2>&1
    elapsed=$(( $(date +%s) - start_ts ))
    [[ "$elapsed" -lt 3 ]]
    grep -q '^## Status: needs verification$' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q 'Phase 7: Early handoff detected from synced fix-execution.contract.json (STATUS: COMPLETE)' \
        "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q 'Pipeline complete: Phase 7 fix execution merged successfully' \
        "$fixture_root/docs/tasks/open/$slug/task.md"
    ! grep -q 'Phase 5: Review started (cycle 2)' "$fixture_root/docs/tasks/open/$slug/task.md"
    ! grep -q '^reviewer-a-fix1$' "$ROLE_LOG"
    ! grep -q '^reviewer-b-fix1$' "$ROLE_LOG"
    ! grep -q '^review-evaluator-fix1$' "$ROLE_LOG"
) && pass "68a. phase 7 early handoff terminates a slow fix executor once COMPLETE artifacts are synced" \
  || fail "68a. phase 7 early handoff terminates a slow fix executor once COMPLETE artifacts are synced"

(
    slug="phase7-natural-return-without-artifacts"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    comp_dir="$fixture_root/docs/tasks/open/$slug/competitive"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    write_review_synthesis_artifact "$comp_dir/review-synthesis.md" "FAIL" 0 1 0 0
    write_fix_plan_artifact "$comp_dir/fix-plan.md" "yes"
    _write_cycle_state "$comp_dir" 0 "phase-6b" "FAIL"
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
    LAUREN_LOOP_PHASE7_HANDOFF_POLL_INTERVAL_SEC="0.2"
    LAUREN_LOOP_PHASE7_HANDOFF_GRACE_SEC="0.2"
    ENGINE_CRITIC="claude"
    ENGINE_FIX="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            fix-executor*)
                sleep 3
                ;;
            reviewer-a*)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "FAIL" "[major/correctness] file:1 - issue
-> fix"
                ;;
            reviewer-b*) write_review_artifact "$output" "FAIL" "[major/correctness] file:1 - issue
-> fix" ;;
            review-evaluator*) write_review_synthesis_artifact "$output" "FAIL" 0 1 0 0 ;;
            fix-plan-author*) write_fix_plan_artifact "$output" "yes" ;;
        esac
        return 0
    }
    start_ts=$(date +%s)
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "phase 7 waits for natural return when artifacts never appear"
    ) >/dev/null 2>&1
    elapsed=$(( $(date +%s) - start_ts ))
    [[ "$elapsed" -ge 2 ]]
    grep -q '^## Status: needs verification$' "$fixture_root/docs/tasks/open/$slug/task.md"
    ! grep -q 'Phase 7: Early handoff detected from synced fix-execution.contract.json (STATUS: COMPLETE)' \
        "$fixture_root/docs/tasks/open/$slug/task.md"
    ! grep -q 'Phase 5: Review started (cycle 2)' "$fixture_root/docs/tasks/open/$slug/task.md"
    ! grep -q '^reviewer-a-fix1$' "$ROLE_LOG"
    ! grep -q '^reviewer-b-fix1$' "$ROLE_LOG"
    ! grep -q '^review-evaluator-fix1$' "$ROLE_LOG"
) && pass "68b. phase 7 preserves the natural-return path when COMPLETE artifacts never appear" \
  || fail "68b. phase 7 preserves the natural-return path when COMPLETE artifacts never appear"

(
    timeout_task="$TMP_ROOT/timeout-retry-eligible/task.md"
    generic_task="$TMP_ROOT/timeout-retry-generic/task.md"
    mixed_task="$TMP_ROOT/timeout-retry-mixed/task.md"
    mkdir -p "$(dirname "$timeout_task")" "$(dirname "$generic_task")" "$(dirname "$mixed_task")"
    cat > "$timeout_task" <<'EOF'
## Task: retry-eligible
## Status: execution-blocked
## Execution Log
- [2026-03-19T12:00:00Z] BLOCKED: Verification timed out after 20m - .venv/bin/python -m pytest tests/ -x -q
EOF
    cat > "$generic_task" <<'EOF'
## Task: retry-rejected
## Status: execution-blocked
## Execution Log
- [2026-03-19T12:00:00Z] BLOCKED: Missing dependency
EOF
    cat > "$mixed_task" <<'EOF'
## Task: retry-mixed
## Status: execution-blocked
## Execution Log
- [2026-03-19T12:00:00Z] BLOCKED: Verification timed out after 20m - .venv/bin/python -m pytest tests/ -x -q
- [2026-03-19T12:05:00Z] BLOCKED: Missing dependency
EOF
    _task_is_timeout_verification_retry_eligible "$timeout_task" "execution-blocked"
    _task_is_timeout_verification_retry_eligible "$timeout_task" "fix-blocked"
    ! _task_is_timeout_verification_retry_eligible "$generic_task" "execution-blocked"
    ! _task_is_timeout_verification_retry_eligible "$mixed_task" "execution-blocked"
) && pass "68c. timeout verification retry eligibility stays narrow to timeout-blocked states" \
  || fail "68c. timeout verification retry eligibility stays narrow to timeout-blocked states"

(
    slug="v1-resume-timeout-retry"
    blocked_line="- [2026-03-19T12:00:00Z] BLOCKED: $(_verification_timeout_message) - .venv/bin/python -m pytest tests/ -x -q"
    fixture_root="$(setup_v1_timeout_retry_fixture "$slug" "$slug" "execution-blocked" "$blocked_line")"
    task_file="$fixture_root/docs/tasks/open/${slug}.md"
    set +e
    output="$(
        cd "$fixture_root" && \
        HOME="$fixture_root/home" PATH="$fixture_root/bin:$PATH" \
        bash "$fixture_root/lauren-loop.sh" "$slug" "retry verification after timeout" --resume 2>&1
    )"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    echo "$output" | grep -q 'Resuming from verification timeout'
    grep -q '^## Status: needs verification$' "$task_file"
    grep -q 'Resuming from verification timeout — retrying verification' "$task_file"
    grep -q '^## Verification$' "$task_file"
    ! grep -q 'Lead pipeline started' "$task_file"
) && pass "69. V1 --resume retries verification for timeout-blocked tasks without rerunning lead execution" \
  || fail "69. V1 --resume retries verification for timeout-blocked tasks without rerunning lead execution"

(
    slug="v1-execute-timeout-retry"
    blocked_line="- [2026-03-19T12:00:00Z] BLOCKED: $(_verification_timeout_message) - .venv/bin/python -m pytest tests/ -x -q"
    fixture_root="$(setup_v1_timeout_retry_fixture "$slug" "$slug" "execution-blocked" "$blocked_line")"
    task_file="$fixture_root/docs/tasks/open/${slug}.md"
    set +e
    output="$(
        cd "$fixture_root" && \
        HOME="$fixture_root/home" PATH="$fixture_root/bin:$PATH" \
        bash "$fixture_root/lauren-loop.sh" execute "$slug" 2>&1
    )"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    echo "$output" | grep -q 'Resuming from verification timeout'
    grep -q '^## Status: needs verification$' "$task_file"
    grep -q '^## Verification$' "$task_file"
    ! grep -q 'Executor started' "$task_file"
) && pass "70. V1 execute retries verification for execution-blocked timeout tasks" \
  || fail "70. V1 execute retries verification for execution-blocked timeout tasks"

(
    slug="v1-fix-timeout-retry"
    blocked_line="- [2026-03-19T12:00:00Z] BLOCKED: $(_verification_timeout_message) - .venv/bin/python -m pytest tests/ -x -q"
    fixture_root="$(setup_v1_timeout_retry_fixture "$slug" "$slug" "fix-blocked" "$blocked_line")"
    task_file="$fixture_root/docs/tasks/open/${slug}.md"
    set +e
    output="$(
        cd "$fixture_root" && \
        HOME="$fixture_root/home" PATH="$fixture_root/bin:$PATH" \
        bash "$fixture_root/lauren-loop.sh" fix "$slug" 2>&1
    )"
    rc=$?
    set -e
    [[ "$rc" -eq 0 ]]
    echo "$output" | grep -q 'Resuming from verification timeout'
    grep -q '^## Status: needs verification$' "$task_file"
    grep -q '^## Verification$' "$task_file"
    ! grep -q 'Fix agent started' "$task_file"
) && pass "71. V1 fix retries verification for fix-blocked timeout tasks" \
  || fail "71. V1 fix retries verification for fix-blocked timeout tasks"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-prefix-suffix/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

    <verify>
      cmd1
      cmd2
    </verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "prefix and suffix verify normalization"
    grep -Eq '^    <verify>cmd1 && cmd2</verify>$' "$plan_file"
) && pass "72. verify-tag timeout normalization preserves opening indentation and trims inner command whitespace" \
  || fail "72. verify-tag timeout normalization preserves opening indentation and trims inner command whitespace"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-single-line/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>pytest tests/foo.py</verify>
EOF
    before="$(cat "$plan_file")"
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "single-line verify normalization"
    after="$(cat "$plan_file")"
    [[ "$before" == "$after" ]]
) && pass "73. verify-tag timeout normalization leaves single-line verify tags unchanged when no timeout wrap applies" \
  || fail "73. verify-tag timeout normalization leaves single-line verify tags unchanged when no timeout wrap applies"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-inline-broken-plan/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

  <task type="auto">
    <verify>
.venv/bin/python -m pytest tests/test_agent_planning.py -k "revision" -xvs
.venv/bin/python -m pytest tests/test_agent_planning.py -xvs
    </verify>
  </task>

  <task type="auto">
    <verify>
.venv/bin/python -m pytest tests/test_agent_llm_refactor.py -xvs
.venv/bin/python -m pytest tests/test_agent_budget_tracking.py -xvs
    </verify>
  </task>

  <task type="verify">
    <verify>
.venv/bin/python -m pytest tests/test_agent_planning.py -v
.venv/bin/python -m pytest tests/test_agent_llm_refactor.py -v
.venv/bin/python -m pytest tests/test_agent_budget_tracking.py -v
.venv/bin/python -m pytest tests/ -x -q
    </verify>
  </task>
EOF
    SCRIPT_DIR="$REPO_ROOT"
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "inline broken fix plan normalization"
    ! grep -Eq '^[[:space:]]*<verify>[[:space:]]*$' "$plan_file"
    ! grep -Eq '^[[:space:]]*</verify>[[:space:]]*$' "$plan_file"
    grep -Fq '.venv/bin/python -m pytest tests/test_agent_planning.py -k "revision" -xvs && .venv/bin/python -m pytest tests/test_agent_planning.py -xvs' "$plan_file"
    grep -Fq '.venv/bin/python -m pytest tests/test_agent_llm_refactor.py -xvs && .venv/bin/python -m pytest tests/test_agent_budget_tracking.py -xvs' "$plan_file"
    grep -Fq '<verify>bash -lc ' "$plan_file"
    grep -Fq '_timeout' "$plan_file"
) && pass "74. verify-tag timeout normalization handles an inline fixture matching the broken fix-plan patterns" \
  || fail "74. verify-tag timeout normalization handles an inline fixture matching the broken fix-plan patterns"

(
    plan_file="$TMP_ROOT/normalize-verify-tags-empty/plan.md"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
# Plan Artifact

## Implementation Tasks

<verify>

</verify>
EOF
    _normalize_verify_tags_with_timeout_in_file "$plan_file" "empty verify normalization"
    grep -Fq '<verify></verify>' "$plan_file"
) && pass "75. verify-tag timeout normalization collapses empty multi-line verify tags to an empty body" \
  || fail "75. verify-tag timeout normalization collapses empty multi-line verify tags to an empty body"

(
    slug="session2-dual-review-synthesis"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
                write_review_artifact "$output" "PASS" "[major/correctness] file:1 - issue
-> fix"
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "both reviews present still synthesize when fast path is not eligible"
    )
    grep -q '^review-evaluator$' "$ROLE_LOG"
    ! grep -q 'fallback' "$ROLE_LOG"
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
) && pass "76. both reviews present still proceed to synthesis when the dual-PASS fast path is not eligible" \
  || fail "76. both reviews present still proceed to synthesis when the dual-PASS fast path is not eligible"

(
    slug="session2-single-review-b-fallback-fail"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            reviewer-b)
                return 1
                ;;
            reviewer-b-claude-fallback)
                printf 'invalid fallback artifact\n' > "$output"
                return 1
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "retry missing reviewer-b once, then synthesize with one review"
    )
    grep -q '^reviewer-b$' "$ROLE_LOG"
    grep -q '^reviewer-b-claude-fallback$' "$ROLE_LOG"
    [[ "$(grep -c '^reviewer-b' "$ROLE_LOG")" -eq 2 ]]
    grep -q '^review-evaluator$' "$ROLE_LOG"
    [[ ! -f "$fixture_root/docs/tasks/open/$slug/competitive/reviewer-b.raw.md" ]]
    [[ ! -f "$fixture_root/docs/tasks/open/$slug/competitive/reviewer-b.raw.cycle1.md" ]]
    grep -q 'Phase 5: reviewer-b missing, launching claude fallback' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -Eq 'Phase 5: WARN .*single reviewer continuing to synthesis' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "77. missing reviewer-b retries once with Claude and still synthesizes in non-strict mode if fallback fails" \
  || fail "77. missing reviewer-b retries once with Claude and still synthesizes in non-strict mode if fallback fails"

(
    slug="session2-single-review-b-strict"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "strict mode still halts on unresolved single reviewer after fallback"
    )
    handoff="$fixture_root/docs/tasks/open/$slug/competitive/human-review-handoff.md"
    [[ -f "$handoff" ]]
    grep -q '^reviewer-b-claude-fallback$' "$ROLE_LOG"
    [[ "$(grep -c '^reviewer-b' "$ROLE_LOG")" -eq 2 ]]
    ! grep -q '^review-evaluator$' "$ROLE_LOG"
    grep -q 'Phase 5: Single reviewer halt (explicit_strict=true' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "78. missing reviewer-b still halts for human review in explicit strict mode after the one-shot fallback" \
  || fail "78. missing reviewer-b still halts for human review in explicit strict mode after the one-shot fallback"

(
    slug="session2-both-reviewers-missing"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
        local role="$1" _engine="$2" _body="$3" _system="$4" _output="$5" log_file="$6"
        : > "$log_file"
        printf '%s\n' "$role" >> "$ROLE_LOG"
        return 1
    }
    set +e
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "both reviewers missing still hard-stop before synthesis"
    ) >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" -eq 1 ]]
    grep -q '^## Status: blocked$' "$fixture_root/docs/tasks/open/$slug/task.md"
    ! grep -q '^review-evaluator$' "$ROLE_LOG"
) && pass "79. both reviewers missing still halt before synthesis regardless of strict mode" \
  || fail "79. both reviewers missing still halt before synthesis regardless of strict mode"

(
    slug="session2-single-review-b-fallback-success"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            reviewer-b)
                return 1
                ;;
            reviewer-b-claude-fallback)
                write_review_artifact "$output" "PASS" "[major/correctness] file:1 - issue
-> fix"
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "successful opposite-engine fallback restores both reviewer inputs"
    )
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-a.md" ]]
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-b.md" ]]
    [[ "$(grep -c '^reviewer-b' "$ROLE_LOG")" -eq 2 ]]
    ! grep -q 'absent' "$fixture_root/docs/tasks/open/$slug/competitive/.review-mapping"
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
    grep -q '^review-evaluator$' "$ROLE_LOG"
    grep -q 'Phase 5: reviewer-b fallback succeeded' "$fixture_root/docs/tasks/open/$slug/task.md"
    grep -q 'Review engine mapping: reviewer-a=claude, reviewer-b=claude (fallback)' "$fixture_root/docs/tasks/open/$slug/competitive/blinding-metadata.log"
) && pass "80. successful opposite-engine fallback restores both review artifacts for synthesis" \
  || fail "80. successful opposite-engine fallback restores both review artifacts for synthesis"

(
    slug="session2-single-review-a-fallback-success"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            reviewer-a)
                return 1
                ;;
            reviewer-a-codex-fallback)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "[major/correctness] file:1 - issue
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
        lauren_loop_competitive "$slug" "successful reviewer-a fallback recreates the runtime prompt and restores both reviews"
    )
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-a.md" ]]
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-b.md" ]]
    [[ "$(grep -c '^reviewer-a' "$ROLE_LOG")" -eq 2 ]]
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
    grep -q '^review-evaluator$' "$ROLE_LOG"
    grep -q 'Phase 5: reviewer-a fallback succeeded' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "81. successful reviewer-a fallback recreates the runtime prompt and restores both review inputs for synthesis" \
  || fail "81. successful reviewer-a fallback recreates the runtime prompt and restores both review inputs for synthesis"

(
    slug="session2-codex-retry-skip"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            reviewer-b)
                printf 'WARN: Codex stream failure for reviewer-b; retrying with profile azure54 after 15s backoff.\n' >> "$log_file"
                return 1
                ;;
            reviewer-b-claude-fallback)
                return 1
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "skip opposite-engine fallback when codex already entered its retry path"
    )
    [[ "$(grep -c '^reviewer-b' "$ROLE_LOG")" -eq 1 ]]
    ! grep -q '^reviewer-b-claude-fallback$' "$ROLE_LOG"
    grep -q '^review-evaluator$' "$ROLE_LOG"
    grep -q 'skipping opposite-engine fallback because Codex already entered capacity/stream retry handling' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "82. codex capacity/stream retry handling suppresses the opposite-engine fallback" \
  || fail "82. codex capacity/stream retry handling suppresses the opposite-engine fallback"

(
    slug="session2-single-review-b-high-risk-fallback-fail"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    seed_high_risk_diff "$fixture_root"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
    start_agent_monitor() { :; }
    stop_agent_monitor() { :; }
    capture_diff_artifact() { printf 'diff --git a/x b/x\n' > "$2"; }
    check_diff_scope() { return 0; }
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
            reviewer-b)
                return 1
                ;;
            reviewer-b-claude-fallback)
                printf 'invalid fallback artifact\n' > "$output"
                return 1
                ;;
            review-evaluator*)
                write_review_synthesis_artifact "$output" "PASS" 0 0 0 0
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "high-risk single reviewer still synthesizes when strict mode is not explicitly enabled"
    )
    grep -q '^reviewer-b$' "$ROLE_LOG"
    grep -q '^reviewer-b-claude-fallback$' "$ROLE_LOG"
    grep -q '^review-evaluator$' "$ROLE_LOG"
    [[ -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
    [[ ! -f "$fixture_root/docs/tasks/open/$slug/competitive/human-review-handoff.md" ]]
    [[ ! -f "$fixture_root/docs/tasks/open/$slug/competitive/reviewer-b.raw.md" ]]
    grep -Eq 'Phase 5: WARN .*explicit_strict=false, diff_risk=HIGH' "$fixture_root/docs/tasks/open/$slug/task.md"
    ! grep -q 'Phase 5: Single reviewer halt' "$fixture_root/docs/tasks/open/$slug/task.md"
) && pass "83. HIGH-risk single reviewer still reaches synthesis when fallback fails and explicit strict mode is off" \
  || fail "83. HIGH-risk single reviewer still reaches synthesis when fallback fails and explicit strict mode is off"

(
    slug="session2-single-review-b-fallback-fast-pass"
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
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
    }
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
            reviewer-b)
                return 1
                ;;
            reviewer-b-claude-fallback)
                write_review_artifact "$output" "PASS" "No findings."
                ;;
        esac
        return 0
    }
    (
        cd "$fixture_root"
        lauren_loop_competitive "$slug" "fallback success updates the early-consensus audit mapping before synthesis is skipped"
    )
    [[ "$(grep -c '^reviewer-b' "$ROLE_LOG")" -eq 2 ]]
    ! grep -q '^review-evaluator$' "$ROLE_LOG"
    [[ ! -f "$fixture_root/docs/tasks/open/$slug/competitive/review-synthesis.md" ]]
    grep -q 'Review engine mapping: reviewer-a=claude, reviewer-b=claude (fallback)' "$fixture_root/docs/tasks/open/$slug/competitive/blinding-metadata.log"
) && pass "84. fallback success updates the review engine audit on the early-consensus branch" \
  || fail "84. fallback success updates the review engine audit on the early-consensus branch"

# ============================================================
# Tests 85–85g: _preflight_dependency_check
# ============================================================

(
    task_dir="$TMP_ROOT/dep-check-no-deps"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: in progress
## Goal: Test dep check

## Execution Log
EOF
    SCRIPT_DIR="$task_dir"
    _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "false"
) && pass "85. dependency check passes with no dependencies declared" \
  || fail "85. dependency check passes with no dependencies declared"

(
    task_dir="$TMP_ROOT/dep-check-not-started"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: in progress
## Goal: Test dep check

## Depends On
- dep-a

## Execution Log
EOF
    cat > "$task_dir/docs/tasks/open/dep-a.md" <<'EOF'
## Task: dep-a
## Status: not started
## Goal: Dependency
EOF
    SCRIPT_DIR="$task_dir"
    ! _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "false"
) && pass "85a. dependency check fails when dep status is 'not started'" \
  || fail "85a. dependency check fails when dep status is 'not started'"

(
    task_dir="$TMP_ROOT/dep-check-needs-verification"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: in progress
## Goal: Test dep check

## Depends On
- dep-b

## Execution Log
EOF
    cat > "$task_dir/docs/tasks/open/dep-b.md" <<'EOF'
## Task: dep-b
## Status: needs verification
## Goal: Dependency
EOF
    SCRIPT_DIR="$task_dir"
    ! _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "false"
) && pass "85b. dependency check fails when dep status is 'needs verification'" \
  || fail "85b. dependency check fails when dep status is 'needs verification'"

(
    task_dir="$TMP_ROOT/dep-check-closed"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: in progress
## Goal: Test dep check

## Depends On
- dep-c

## Execution Log
EOF
    cat > "$task_dir/docs/tasks/closed/dep-c.md" <<'EOF'
## Task: dep-c
## Status: closed
## Goal: Dependency
EOF
    SCRIPT_DIR="$task_dir"
    _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "false"
) && pass "85c. dependency check passes when dep status is 'closed'" \
  || fail "85c. dependency check passes when dep status is 'closed'"

(
    task_dir="$TMP_ROOT/dep-check-missing"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: in progress
## Goal: Test dep check

## Depends On
- nonexistent-dep

## Execution Log
EOF
    SCRIPT_DIR="$task_dir"
    _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "false"
) && pass "85d. dependency check passes when dep task file doesn't exist" \
  || fail "85d. dependency check passes when dep task file doesn't exist"

(
    task_dir="$TMP_ROOT/dep-check-force"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: blocked
## Goal: Test dep check

## Depends On
- dep-d

## Execution Log
EOF
    cat > "$task_dir/docs/tasks/open/dep-d.md" <<'EOF'
## Task: dep-d
## Status: in progress
## Goal: Dependency
EOF
    SCRIPT_DIR="$task_dir"
    _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "true" 2>/dev/null
) && pass "85e. dependency check passes with force=true despite blocked dep" \
  || fail "85e. dependency check passes with force=true despite blocked dep"

(
    task_dir="$TMP_ROOT/dep-check-blocked-dep"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: in progress
## Goal: Test dep check

## Depends On
- dep-blocked

## Execution Log
EOF
    cat > "$task_dir/docs/tasks/open/dep-blocked.md" <<'EOF'
## Task: dep-blocked
## Status: blocked
## Goal: Dependency
EOF
    SCRIPT_DIR="$task_dir"
    ! _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "false" 2>/dev/null
) && pass "85f. dependency check fails when dep status is 'blocked'" \
  || fail "85f. dependency check fails when dep status is 'blocked'"

(
    task_dir="$TMP_ROOT/dep-check-inline"
    mkdir -p "$task_dir/docs/tasks/open" "$task_dir/docs/tasks/closed"
    cat > "$task_dir/docs/tasks/open/my-task.md" <<'EOF'
## Task: my-task
## Status: in progress
## Goal: Test dep check
Depends On: dep-inline

## Execution Log
EOF
    cat > "$task_dir/docs/tasks/open/dep-inline.md" <<'EOF'
## Task: dep-inline
## Status: in progress
## Goal: Dependency
EOF
    SCRIPT_DIR="$task_dir"
    ! _preflight_dependency_check "$task_dir/docs/tasks/open/my-task.md" "false" 2>/dev/null
) && pass "85g. dependency check fails for inline Depends On field with in-progress dep" \
  || fail "85g. dependency check fails for inline Depends On field with in-progress dep"

# ============================================================
# Tests 86–86g: _validate_verify_commands_in_file / _validate_single_verify_command
# ============================================================

(
    vf="$TMP_ROOT/verify-valid.md"
    cat > "$vf" <<'EOF'
## Implementation Tasks

<wave number="1">
  <task type="auto">
    <verify>bash tests/test_lauren_loop_logic.sh</verify>
  </task>
</wave>
EOF
    _validate_verify_commands_in_file "$vf" "test-valid"
) && pass "86. valid verify command passes validation" \
  || fail "86. valid verify command passes validation"

(
    vf="$TMP_ROOT/verify-empty.md"
    cat > "$vf" <<'EOF'
## Implementation Tasks

<verify></verify>
EOF
    ! _validate_verify_commands_in_file "$vf" "test-empty" 2>/dev/null
) && pass "86a. empty verify command fails validation" \
  || fail "86a. empty verify command fails validation"

(
    vf="$TMP_ROOT/verify-unbalanced.md"
    cat > "$vf" <<'EOF'
## Implementation Tasks

<verify>pytest -k 'test_foo</verify>
EOF
    ! _validate_verify_commands_in_file "$vf" "test-unbalanced" 2>/dev/null
) && pass "86b. unbalanced quote fails validation" \
  || fail "86b. unbalanced quote fails validation"

(
    vf="$TMP_ROOT/verify-unknown.md"
    cat > "$vf" <<'EOF'
## Implementation Tasks

<verify>rm -rf /</verify>
EOF
    ! _validate_verify_commands_in_file "$vf" "test-unknown" 2>/dev/null
) && pass "86c. unknown command prefix fails validation" \
  || fail "86c. unknown command prefix fails validation"

(
    vf="$TMP_ROOT/verify-compound.md"
    cat > "$vf" <<'EOF'
## Implementation Tasks

<verify>bash -n file.sh && pytest tests/</verify>
EOF
    _validate_verify_commands_in_file "$vf" "test-compound"
) && pass "86d. compound command with valid first segment passes" \
  || fail "86d. compound command with valid first segment passes"

(
    vf="$TMP_ROOT/verify-outside.md"
    cat > "$vf" <<'EOF'
## Some Other Section

<verify>rm -rf /</verify>

## Implementation Tasks

<verify>bash tests/test.sh</verify>
EOF
    _validate_verify_commands_in_file "$vf" "test-outside"
) && pass "86e. tag outside Implementation Tasks is not validated" \
  || fail "86e. tag outside Implementation Tasks is not validated"

(
    vf="$TMP_ROOT/verify-venv.md"
    cat > "$vf" <<'EOF'
## Implementation Tasks

<verify>.venv/bin/python -m pytest tests/</verify>
EOF
    _validate_verify_commands_in_file "$vf" "test-venv"
) && pass "86f. path-qualified .venv/bin/python passes validation" \
  || fail "86f. path-qualified .venv/bin/python passes validation"

(
    ! _validate_verify_commands_in_file "$TMP_ROOT/nonexistent-file.md" "test-missing" 2>/dev/null
) && pass "86g. file not found fails validation" \
  || fail "86g. file not found fails validation"

(
    vf="$TMP_ROOT/verify-grep.md"
    cat > "$vf" <<'EOF'
## Implementation Tasks

<verify>grep -n "pattern" src/file.py</verify>
EOF
    _validate_verify_commands_in_file "$vf" "test-grep"
) && pass "86h. grep verify command passes validation" \
  || fail "86h. grep verify command passes validation"

# ============================================================
# Tests 87–87f: finalize_v2_task_metadata
# ============================================================

_setup_v2_metadata_fixture() {
    local name="$1"
    local task_dir="$TMP_ROOT/$name"
    mkdir -p "$task_dir/competitive" "$task_dir/logs"
    cat > "$task_dir/task.md" <<'EOF'
## Task: v2-meta-test
## Status: in progress
## Goal: Test metadata finalization

## Execution Log
EOF
    printf '%s\n' "$task_dir"
}

(
    fixture_dir="$(_setup_v2_metadata_fixture "v2meta-left-off")"
    touch "$fixture_dir/competitive/execution-diff.patch"
    touch "$fixture_dir/competitive/review-synthesis.md"
    SCRIPT_DIR="$(dirname "$(dirname "$fixture_dir")")"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-4" "success" "2"
    grep -q 'V2 competitive pipeline reached phase-4 (status: success, fix cycles: 2). Artifacts:' "$fixture_dir/task.md"
) && pass "87. finalize_v2_task_metadata populates Left Off At" \
  || fail "87. finalize_v2_task_metadata populates Left Off At"

(
    fixture_dir="$(_setup_v2_metadata_fixture "v2meta-attempts")"
    SCRIPT_DIR="$(dirname "$(dirname "$fixture_dir")")"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-4" "success" "2"
    today=$(date '+%Y-%m-%d')
    grep -q "V2 competitive run → reached phase-4, status: success" "$fixture_dir/task.md" &&
    grep -q "$today" "$fixture_dir/task.md"
) && pass "87a. finalize_v2_task_metadata populates Attempts" \
  || fail "87a. finalize_v2_task_metadata populates Attempts"

(
    fixture_dir="$(_setup_v2_metadata_fixture "v2meta-artifacts")"
    touch "$fixture_dir/competitive/execution-diff.patch"
    touch "$fixture_dir/competitive/review-synthesis.md"
    SCRIPT_DIR="$(dirname "$(dirname "$fixture_dir")")"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-4" "success" "2"
    grep -q 'execution-diff.patch, review-synthesis.md' "$fixture_dir/task.md"
) && pass "87b. finalize_v2_task_metadata lists available artifacts" \
  || fail "87b. finalize_v2_task_metadata lists available artifacts"

(
    fixture_dir="$(_setup_v2_metadata_fixture "v2meta-blocked")"
    SCRIPT_DIR="$(dirname "$(dirname "$fixture_dir")")"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-2" "blocked" "0"
    grep -q 'Next: Debug using execution-log.md and run-manifest.json, then retry.' "$fixture_dir/task.md"
) && pass "87c. finalize_v2_task_metadata blocked status produces correct hint" \
  || fail "87c. finalize_v2_task_metadata blocked status produces correct hint"

(
    fixture_dir="$(_setup_v2_metadata_fixture "v2meta-human-review")"
    SCRIPT_DIR="$(dirname "$(dirname "$fixture_dir")")"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-5" "human_review" "1"
    grep -q 'Next: See human-review-handoff.md or review-synthesis.md before proceeding.' "$fixture_dir/task.md"
) && pass "87d. finalize_v2_task_metadata human review status produces correct hint" \
  || fail "87d. finalize_v2_task_metadata human review status produces correct hint"

(
    fixture_dir="$(_setup_v2_metadata_fixture "v2meta-idempotent")"
    SCRIPT_DIR="$(dirname "$(dirname "$fixture_dir")")"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-4" "success" "2"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-7" "blocked" "3"
    count=$(grep -c 'V2 competitive run' "$fixture_dir/task.md")
    [[ "$count" -eq 2 ]]
) && pass "87e. finalize_v2_task_metadata appends multiple Attempts entries" \
  || fail "87e. finalize_v2_task_metadata appends multiple Attempts entries"

(
    fixture_dir="$(_setup_v2_metadata_fixture "v2meta-missing")"
    rm "$fixture_dir/task.md"
    SCRIPT_DIR="$(dirname "$(dirname "$fixture_dir")")"
    finalize_v2_task_metadata "$fixture_dir/task.md" "phase-1" "blocked" "0"
    rc=$?
    [[ "$rc" -eq 0 ]]
) && pass "87f. finalize_v2_task_metadata no-ops on missing task file" \
  || fail "87f. finalize_v2_task_metadata no-ops on missing task file"

# ============================================================
# 88. Execution worktree helpers
# ============================================================

(
    # Set up a temporary git repo to test worktree operations
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-test.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" commit --allow-empty -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-wt"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    _v2_create_execution_worktree || exit 1
    [[ -n "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -d "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -n "$_V2_EXEC_WORKTREE_BRANCH" ]] || exit 1
    # Worktree should be a valid git directory
    git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 1
    _v2_cleanup_execution_worktree
    rm -rf "$wt_test_dir"
) && pass "88. _v2_create_execution_worktree creates valid worktree and branch" \
  || fail "88. _v2_create_execution_worktree creates valid worktree and branch"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-cleanup.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" commit --allow-empty -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-cleanup"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    _v2_create_execution_worktree || exit 1
    local_wt_path="$_V2_EXEC_WORKTREE_PATH"
    local_wt_branch="$_V2_EXEC_WORKTREE_BRANCH"
    _v2_cleanup_execution_worktree
    # Worktree path should be removed
    [[ ! -d "$local_wt_path" ]] || exit 1
    # Branch should be removed
    ! git -C "$wt_test_dir" branch --list "$local_wt_branch" | grep -q . || exit 1
    # Globals should be cleared
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_BRANCH" ]] || exit 1
    rm -rf "$wt_test_dir"
) && pass "88a. _v2_cleanup_execution_worktree removes worktree, branch, clears globals" \
  || fail "88a. _v2_cleanup_execution_worktree removes worktree, branch, clears globals"

(
    # Cleanup with empty globals should be a no-op (idempotent)
    SCRIPT_DIR="$TMP_ROOT"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""
    _v2_cleanup_execution_worktree || exit 1
) && pass "88b. _v2_cleanup_execution_worktree is idempotent with empty globals" \
  || fail "88b. _v2_cleanup_execution_worktree is idempotent with empty globals"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-merge.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" commit --allow-empty -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-merge"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    _v2_create_execution_worktree || exit 1
    # Make a commit in the worktree
    echo "worktree change" > "$_V2_EXEC_WORKTREE_PATH/test-file.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add test-file.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -m "worktree commit" -q
    wt_commit=$(git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse HEAD)

    _v2_merge_execution_worktree || exit 1
    # Main branch should now contain the worktree's commit
    main_head=$(git -C "$wt_test_dir" rev-parse HEAD)
    [[ "$main_head" == "$wt_commit" ]] || exit 1
    # Worktree should be cleaned up
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    # The file should exist in the main tree
    [[ -f "$wt_test_dir/test-file.txt" ]] || exit 1
    rm -rf "$wt_test_dir"
) && pass "88c. _v2_merge_execution_worktree brings commits back to main branch" \
  || fail "88c. _v2_merge_execution_worktree brings commits back to main branch"

(
    # Merge with no new commits should be a no-op
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-merge-noop.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" commit --allow-empty -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-merge-noop"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    before_sha=$(git -C "$wt_test_dir" rev-parse HEAD)
    _v2_create_execution_worktree || exit 1
    _v2_merge_execution_worktree || exit 1
    after_sha=$(git -C "$wt_test_dir" rev-parse HEAD)
    [[ "$before_sha" == "$after_sha" ]] || exit 1
    rm -rf "$wt_test_dir"
) && pass "88d. _v2_merge_execution_worktree no-op when no commits in worktree" \
  || fail "88d. _v2_merge_execution_worktree no-op when no commits in worktree"

(
    # Stale worktree at the same path gets cleaned up on create
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-stale.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" commit --allow-empty -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-stale"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    # Create a worktree, then simulate a crash by clearing globals without cleanup
    _v2_create_execution_worktree || exit 1
    stale_path="$_V2_EXEC_WORKTREE_PATH"
    stale_branch="$_V2_EXEC_WORKTREE_BRANCH"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""
    # The stale worktree directory still exists
    [[ -d "$stale_path" ]] || exit 1

    # Creating a new worktree for the same slug/PID should succeed
    # (it cleans up the stale path first)
    _v2_create_execution_worktree || exit 1
    [[ -d "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    _v2_cleanup_execution_worktree
    # Also clean up the stale branch
    git -C "$wt_test_dir" branch -D "$stale_branch" 2>/dev/null || true
    rm -rf "$wt_test_dir"
) && pass "88e. _v2_create_execution_worktree cleans stale worktree at same path" \
  || fail "88e. _v2_create_execution_worktree cleans stale worktree at same path"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-stage-sync.XXXXXX")
    mkdir -p "$wt_test_dir/docs/tasks/open/test-stage/competitive"
    printf 'task body\n' > "$wt_test_dir/docs/tasks/open/test-stage/task.md"
    printf 'plan body\n' > "$wt_test_dir/docs/tasks/open/test-stage/competitive/revised-plan.md"
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" add .
    git -C "$wt_test_dir" commit -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-stage"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    _v2_create_execution_worktree || exit 1
    _v2_stage_execution_runtime_task_file "$wt_test_dir/docs/tasks/open/test-stage/task.md" || exit 1
    _v2_stage_execution_worktree_files "$wt_test_dir/docs/tasks/open/test-stage/competitive/revised-plan.md" || exit 1

    [[ -f "$_V2_EXEC_WORKTREE_PATH/.lauren-loop-runtime/test-stage/task.md" ]] || exit 1
    [[ -f "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/test-stage/competitive/revised-plan.md" ]] || exit 1
    grep -Fq 'task body' "$_V2_EXEC_WORKTREE_PATH/.lauren-loop-runtime/test-stage/task.md" || exit 1
    grep -Fq 'plan body' "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/test-stage/competitive/revised-plan.md" || exit 1

    printf 'worktree log\n' > "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/test-stage/competitive/execution-log.md"
    _v2_sync_execution_worktree_file "$wt_test_dir/docs/tasks/open/test-stage/competitive/execution-log.md" || exit 1
    grep -Fq 'worktree log' "$wt_test_dir/docs/tasks/open/test-stage/competitive/execution-log.md" || exit 1

    _v2_cleanup_execution_worktree
    rm -rf "$wt_test_dir"
) && pass "88f. execution worktree staging and sync mirror task artifacts and logs" \
  || fail "88f. execution worktree staging and sync mirror task artifacts and logs"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-status-filter.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" commit --allow-empty -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-status-filter"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    _v2_create_execution_worktree || exit 1
    mkdir -p "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/${SLUG}/competitive" "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/${SLUG}/logs"
    printf 'task copy\n' > "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/${SLUG}/task.md"
    printf 'log copy\n' > "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/${SLUG}/competitive/execution-log.md"
    printf 'cost copy\n' > "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/${SLUG}/logs/cost.csv"
    mkdir -p "$_V2_EXEC_WORKTREE_PATH/.lauren-loop-runtime/${SLUG}"
    printf 'runtime task copy\n' > "$_V2_EXEC_WORKTREE_PATH/.lauren-loop-runtime/${SLUG}/task.md"

    status_lines=$(cd "$_V2_EXEC_WORKTREE_PATH" && _v2_filtered_worktree_status_lines)
    [[ -z "$status_lines" ]] || exit 1

    printf 'real code change\n' > "$_V2_EXEC_WORKTREE_PATH/src-main.py"
    status_lines=$(cd "$_V2_EXEC_WORKTREE_PATH" && _v2_filtered_worktree_status_lines)
    printf '%s\n' "$status_lines" | grep -Fq 'src-main.py' || exit 1

    _v2_cleanup_execution_worktree
    rm -rf "$wt_test_dir"
) && pass "88g. execution worktree diagnostics ignore pipeline-owned task artifacts but keep real code paths" \
  || fail "88g. execution worktree diagnostics ignore pipeline-owned task artifacts but keep real code paths"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-save-diff.XXXXXX")
    git -C "$wt_test_dir" init -q
    echo "original" > "$wt_test_dir/existing.txt"
    git -C "$wt_test_dir" add existing.txt
    git -C "$wt_test_dir" commit -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-save-diff"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    # Set up _CURRENT_TASK_FILE so save_dir is deterministic
    task_dir="$wt_test_dir/docs/tasks/open/test-save-diff"
    mkdir -p "$task_dir/competitive"
    printf '## Task: test-save-diff\n## Status: in progress\n' > "$task_dir/task.md"
    _CURRENT_TASK_FILE="$task_dir/task.md"

    _v2_create_execution_worktree || exit 1

    # Make tracked changes (modify existing file)
    echo "modified" > "$_V2_EXEC_WORKTREE_PATH/existing.txt"
    # Make untracked file
    echo "new file content" > "$_V2_EXEC_WORKTREE_PATH/new-file.txt"

    _v2_save_worktree_diff || exit 1

    # Assert: saved-diffs directory and patch file exist
    saved_dir="$task_dir/competitive/saved-diffs"
    [[ -d "$saved_dir" ]] || exit 1
    patch_count=$(ls "$saved_dir"/*.patch 2>/dev/null | wc -l)
    [[ "$patch_count" -ge 1 ]] || exit 1
    patch_file=$(ls "$saved_dir"/*.patch | head -1)
    # Assert: contains tracked diff content
    grep -q 'modified' "$patch_file" || exit 1
    # Assert: contains untracked file reference
    grep -q 'new-file.txt' "$patch_file" || exit 1

    # Cleanup should remove worktree but patch survives
    _v2_cleanup_execution_worktree
    [[ -f "$patch_file" ]] || exit 1
    rm -rf "$wt_test_dir"
) && pass "88h. _v2_save_worktree_diff saves tracked and untracked changes to patch file" \
  || fail "88h. _v2_save_worktree_diff saves tracked and untracked changes to patch file"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-save-noop.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" commit --allow-empty -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-save-noop"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    task_dir="$wt_test_dir/docs/tasks/open/test-save-noop"
    mkdir -p "$task_dir/competitive"
    printf '## Task: test-save-noop\n## Status: in progress\n' > "$task_dir/task.md"
    _CURRENT_TASK_FILE="$task_dir/task.md"

    _v2_create_execution_worktree || exit 1
    # No changes made

    _v2_save_worktree_diff || exit 1

    # Assert: no patch file created
    saved_dir="$task_dir/competitive/saved-diffs"
    if [[ -d "$saved_dir" ]]; then
        patch_count=$(ls "$saved_dir"/*.patch 2>/dev/null | wc -l)
        [[ "$patch_count" -eq 0 ]] || exit 1
    fi

    _v2_cleanup_execution_worktree
    rm -rf "$wt_test_dir"
) && pass "88i. _v2_save_worktree_diff is no-op when worktree has no changes" \
  || fail "88i. _v2_save_worktree_diff is no-op when worktree has no changes"

(
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""
    _CURRENT_TASK_FILE=""
    SLUG=""
    _v2_save_worktree_diff || exit 1
) && pass "88j. _v2_save_worktree_diff returns 0 with empty globals (no worktree)" \
  || fail "88j. _v2_save_worktree_diff returns 0 with empty globals (no worktree)"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-recoverable-merge.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" config user.name "Lauren Loop Tests"
    git -C "$wt_test_dir" config user.email "lauren-loop-tests@example.com"
    printf 'base\n' > "$wt_test_dir/conflict.txt"
    git -C "$wt_test_dir" add conflict.txt
    git -C "$wt_test_dir" commit -m "initial" -q
    git -C "$wt_test_dir" checkout -q -b target-recovery
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-recoverable-merge"
    task_dir="$wt_test_dir/docs/tasks/open/test-recoverable-merge"
    mkdir -p "$task_dir/competitive"
    printf '## Task: test-recoverable-merge\n## Status: in progress\n' > "$task_dir/task.md"
    _CURRENT_TASK_FILE="$task_dir/task.md"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    _v2_create_execution_worktree || exit 1
    [[ "$_V2_EXEC_TARGET_REF" == "refs/heads/target-recovery" ]] || exit 1

    printf 'worktree change\n' > "$_V2_EXEC_WORKTREE_PATH/conflict.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add conflict.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -m "worktree change" -q
    wt_commit=$(git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse HEAD)

    printf 'target branch change\n' > "$wt_test_dir/conflict.txt"
    git -C "$wt_test_dir" add conflict.txt
    git -C "$wt_test_dir" commit -m "target conflict" -q

    set +e
    _v2_merge_execution_worktree
    rc=$?
    set -e

    [[ "$rc" -eq 1 ]] || exit 1
    [[ "$_V2_LAST_MERGE_RECOVERABLE" == true ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_BRANCH" ]] || exit 1
    [[ "$_V2_PRESERVED_EXEC_TARGET_REF" == "refs/heads/target-recovery" ]] || exit 1
    [[ "$_V2_PRESERVED_EXEC_COMMIT_SHA" == "$wt_commit" ]] || exit 1
    [[ -n "$_V2_PRESERVED_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -d "$_V2_PRESERVED_EXEC_WORKTREE_PATH" ]] || exit 1
    git -C "$wt_test_dir" branch --list "$_V2_PRESERVED_EXEC_WORKTREE_BRANCH" | grep -q . || exit 1
    [[ -n "$_V2_PRESERVED_RECOVERY_DIR" && -d "$_V2_PRESERVED_RECOVERY_DIR" ]] || exit 1
    [[ -f "$_V2_PRESERVED_COMBINED_PATCH" ]] || exit 1
    [[ -f "$_V2_PRESERVED_COMMIT_LOG" ]] || exit 1
    [[ -d "$_V2_PRESERVED_FORMAT_PATCH_DIR" ]] || exit 1
    ls "$_V2_PRESERVED_FORMAT_PATCH_DIR"/*.patch >/dev/null 2>&1 || exit 1
    grep -q 'worktree change' "$_V2_PRESERVED_COMMIT_LOG" || exit 1
    grep -q 'worktree change' "$_V2_PRESERVED_COMBINED_PATCH" || exit 1
    ! git -C "$wt_test_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || exit 1

    _v2_cleanup_execution_worktree || exit 1
    [[ -d "$_V2_PRESERVED_EXEC_WORKTREE_PATH" ]] || exit 1
    git -C "$wt_test_dir" branch --list "$_V2_PRESERVED_EXEC_WORKTREE_BRANCH" | grep -q . || exit 1

    preserved_path="$_V2_PRESERVED_EXEC_WORKTREE_PATH"
    preserved_branch="$_V2_PRESERVED_EXEC_WORKTREE_BRANCH"
    git -C "$wt_test_dir" worktree remove "$preserved_path" --force >/dev/null 2>&1 || exit 1
    git -C "$wt_test_dir" branch -D "$preserved_branch" >/dev/null 2>&1 || exit 1
    rm -rf "$wt_test_dir"
) && pass "88k. _v2_merge_execution_worktree preserves recoverable merge failures with recovery artifacts and branch state" \
  || fail "88k. _v2_merge_execution_worktree preserves recoverable merge failures with recovery artifacts and branch state"

(
    wt_test_dir=$(mktemp -d "${TMP_ROOT}/wt-reset-preserved.XXXXXX")
    git -C "$wt_test_dir" init -q
    git -C "$wt_test_dir" config user.name "Lauren Loop Tests"
    git -C "$wt_test_dir" config user.email "lauren-loop-tests@example.com"
    printf 'base\n' > "$wt_test_dir/success.txt"
    git -C "$wt_test_dir" add success.txt
    git -C "$wt_test_dir" commit -m "initial" -q
    SCRIPT_DIR="$wt_test_dir"
    cd "$wt_test_dir"
    SLUG="test-reset-preserved"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""

    _v2_create_execution_worktree || exit 1
    _V2_LAST_MERGE_RECOVERABLE=true
    _V2_PRESERVED_EXEC_WORKTREE_PATH="/tmp/stale-worktree"
    _V2_PRESERVED_EXEC_WORKTREE_BRANCH="stale-branch"
    _V2_PRESERVED_EXEC_TARGET_REF="refs/heads/stale-target"
    _V2_PRESERVED_EXEC_TARGET_HEAD_SHA="stale-target-sha"
    _V2_PRESERVED_EXEC_COMMIT_SHA="stale-commit"
    _V2_PRESERVED_RECOVERY_DIR="/tmp/stale-recovery"
    _V2_PRESERVED_COMBINED_PATCH="/tmp/stale-recovery/combined.patch"
    _V2_PRESERVED_COMMIT_LOG="/tmp/stale-recovery/commits.txt"
    _V2_PRESERVED_FORMAT_PATCH_DIR="/tmp/stale-recovery/format-patch"
    _V2_PRESERVED_WORKTREE_PATCH="/tmp/stale-recovery/worktree.patch"

    printf 'merged cleanly\n' > "$_V2_EXEC_WORKTREE_PATH/success.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add success.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -m "success change" -q

    _v2_merge_execution_worktree || exit 1
    grep -q 'merged cleanly' "$wt_test_dir/success.txt" || exit 1
    [[ "$_V2_LAST_MERGE_RECOVERABLE" == false ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_BRANCH" ]] || exit 1
    [[ -z "$_V2_EXEC_TARGET_REF" ]] || exit 1
    [[ -z "$_V2_EXEC_TARGET_HEAD_SHA" ]] || exit 1
    [[ -z "$_V2_PRESERVED_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -z "$_V2_PRESERVED_EXEC_WORKTREE_BRANCH" ]] || exit 1
    [[ -z "$_V2_PRESERVED_EXEC_TARGET_REF" ]] || exit 1
    [[ -z "$_V2_PRESERVED_EXEC_TARGET_HEAD_SHA" ]] || exit 1
    [[ -z "$_V2_PRESERVED_EXEC_COMMIT_SHA" ]] || exit 1
    [[ -z "$_V2_PRESERVED_RECOVERY_DIR" ]] || exit 1
    [[ -z "$_V2_PRESERVED_COMBINED_PATCH" ]] || exit 1
    [[ -z "$_V2_PRESERVED_COMMIT_LOG" ]] || exit 1
    [[ -z "$_V2_PRESERVED_FORMAT_PATCH_DIR" ]] || exit 1
    [[ -z "$_V2_PRESERVED_WORKTREE_PATCH" ]] || exit 1
    rm -rf "$wt_test_dir"
) && pass "88l. successful merge-back resets preserved recovery globals and target refs" \
  || fail "88l. successful merge-back resets preserved recovery globals and target refs"

(
    task_file="$TMP_ROOT/v2-safe-task/task.md"
    marker_a="$TMP_ROOT/v2-safe-task/marker-a"
    marker_b="$TMP_ROOT/v2-safe-task/marker-b"
    goal=$(printf 'Line one with CORR10488A\nLine two $(printf hacked > "%s")\nLine three `printf hacked > "%s"` at Sugar Land' "$marker_a" "$marker_b")

    _write_v2_task_file "$task_file" "safe-task" "$goal" || exit 1

    [[ -f "$task_file" ]] || exit 1
    [[ ! -e "$marker_a" ]] || exit 1
    [[ ! -e "$marker_b" ]] || exit 1
    grep -Fq '## Goal: Line one with CORR10488A' "$task_file"
    grep -Fq 'Line two $(printf hacked > "' "$task_file"
    grep -Fq 'Line three `printf hacked > "' "$task_file"
    grep -Fq 'Sugar Land' "$task_file"
) && pass "89a. _write_v2_task_file preserves literal goal text without shell execution" \
  || fail "89a. _write_v2_task_file preserves literal goal text without shell execution"

(
    fixture_root="$TMP_ROOT/v2-resolve-nested-flat"
    nested_task="$fixture_root/docs/tasks/open/security/nested-flat.md"
    mkdir -p "$(dirname "$nested_task")"
    write_task_fixture "$nested_task"
    SCRIPT_DIR="$fixture_root"

    resolved=$(_resolve_v2_task_file "nested-flat") || exit 1
    [[ "$resolved" == "$nested_task" ]]
) && pass "89b. _resolve_v2_task_file finds exact nested flat task matches" \
  || fail "89b. _resolve_v2_task_file finds exact nested flat task matches"

(
    fixture_root="$TMP_ROOT/v2-resolve-nested-dir"
    nested_task="$fixture_root/docs/tasks/open/security/nested-dir/task.md"
    mkdir -p "$(dirname "$nested_task")"
    write_task_fixture "$nested_task"
    SCRIPT_DIR="$fixture_root"

    resolved=$(_resolve_v2_task_file "nested-dir") || exit 1
    [[ "$resolved" == "$nested_task" ]]
) && pass "89c. _resolve_v2_task_file finds exact nested directory task matches" \
  || fail "89c. _resolve_v2_task_file finds exact nested directory task matches"

(
    fixture_root="$TMP_ROOT/v2-resolve-top-level-wins"
    top_level_task="$fixture_root/docs/tasks/open/top-level-wins/task.md"
    nested_task="$fixture_root/docs/tasks/open/security/top-level-wins.md"
    mkdir -p "$(dirname "$top_level_task")" "$(dirname "$nested_task")"
    write_task_fixture "$top_level_task"
    write_task_fixture "$nested_task"
    SCRIPT_DIR="$fixture_root"

    resolved=$(_resolve_v2_task_file "top-level-wins") || exit 1
    [[ "$resolved" == "$top_level_task" ]]
) && pass "89d. _resolve_v2_task_file keeps top-level exact matches ahead of nested matches" \
  || fail "89d. _resolve_v2_task_file keeps top-level exact matches ahead of nested matches"

(
    fixture_root="$TMP_ROOT/v2-resolve-ambiguous-nested"
    nested_a="$fixture_root/docs/tasks/open/security/ambiguous-nested.md"
    nested_b="$fixture_root/docs/tasks/open/lauren-loop/ambiguous-nested.md"
    mkdir -p "$(dirname "$nested_a")" "$(dirname "$nested_b")"
    write_task_fixture "$nested_a"
    write_task_fixture "$nested_b"
    SCRIPT_DIR="$fixture_root"

    set +e
    _resolve_v2_task_file "ambiguous-nested" > "$TMP_ROOT/ambiguous-nested.out" 2> "$TMP_ROOT/ambiguous-nested.err"
    rc=$?
    set -e

    [[ "$rc" -eq 2 ]] || exit 1
    grep -q "ambiguous task slug 'ambiguous-nested' matches multiple nested task files" "$TMP_ROOT/ambiguous-nested.err"
    grep -Fq "$nested_a" "$TMP_ROOT/ambiguous-nested.err"
    grep -Fq "$nested_b" "$TMP_ROOT/ambiguous-nested.err"
) && pass "89e. _resolve_v2_task_file fails closed on multiple nested exact matches" \
  || fail "89e. _resolve_v2_task_file fails closed on multiple nested exact matches"

# ============================================================
# Tests 90a–90e: Codex retry wall cap and Lauren Loop V2 circuit breaker
# ============================================================

(
    i=0
    while [[ "$i" -lt 10 ]]; do
        backoff=$(_jittered_backoff 60)
        [[ "$backoff" =~ ^[0-9]+$ ]] || exit 1
        [[ "$backoff" -ge 60 ]] || exit 1
        [[ "$backoff" -le 75 ]] || exit 1
        i=$((i + 1))
    done
) && pass "90a. _jittered_backoff keeps a 60s base within the deterministic 60-75s range" \
  || fail "90a. _jittered_backoff keeps a 60s base within the deterministic 60-75s range"

(
    root="$TMP_ROOT/run-agent-wall-cap"
    mkdir -p "$root/logs"
    MODEL="opus"
    AGENT_SETTINGS='{}'
    TASK_LOG_DIR="$root/logs"
    _CURRENT_TASK_LOG_DIR="$root/logs"
    _append_cost_row() { :; }
    _interrupt_marker_exists() { return 1; }
    _run_codex_agent_attempt() {
        local _role="$1" _profile="$2" _prompt="$3" _artifact_file="$4" attempt_log="$5" role_log="$6"
        command sleep 1
        printf 'too_many_requests\n' >> "$attempt_log"
        printf 'too_many_requests\n' >> "$role_log"
        return 2
    }
    _jittered_backoff() { printf '2\n'; }
    sleep() { command sleep "${1:-0}"; }

    set +e
    run_agent "wall-cap-role" "codex" "prompt" "system" "$root/output.md" "$root/logs/wall-cap.log" "2s" "100"
    rc=$?
    set -e

    [[ "$rc" -ne 0 ]] || exit 1
    attempt_count=$(grep -c '^\[codex-attempt\]' "$root/logs/wall-cap.log")
    [[ "$attempt_count" -eq 1 ]] || exit 1
    grep -q 'wall-time cap' "$root/logs/wall-cap.log"
    ! grep -q 'exhausted retries' "$root/logs/wall-cap.log"
) && pass "90b. run_agent re-checks the wall-time cap after sleep and stops before launching another Codex retry" \
  || fail "90b. run_agent re-checks the wall-time cap after sleep and stops before launching another Codex retry"

(
    root="$TMP_ROOT/scope-triage-circuit-breaker"
    task_file="$root/task.md"
    comp_dir="$root/competitive"
    log_dir="$root/logs"
    diff_file="$comp_dir/execution-diff.patch"
    plan_file="$comp_dir/revised-plan.md"
    mkdir -p "$comp_dir" "$log_dir" "$root/prompts"
    write_task_fixture "$task_file"
    printf 'plan\n' > "$plan_file"
    printf 'scope triage prompt\n' > "$root/prompts/scope-triage.md"

    slug="scope-triage-circuit-breaker"
    goal="Scope triage breaker skips Codex"
    MODEL="opus"
    FORCE_RERUN=false
    ENGINE_EXPLORE="claude"
    ENGINE_PLANNER_A="claude"
    ENGINE_PLANNER_B="claude"
    ENGINE_EVALUATOR="codex"
    ENGINE_EXECUTOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="claude"
    ENGINE_FIX="claude"
    TASK_LOG_DIR="$log_dir"
    _CURRENT_TASK_LOG_DIR="$log_dir"
    _CURRENT_TASK_FILE=""
    _V2_CODEX_RUN_FAILURES=2
    _V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES="src/example.sh"
    _V2_LAST_CAPTURE_SCOPE_SOURCE="plan-files-to-modify"
    _V2_LAST_CAPTURE_SCOPE_PATHS="src/in-scope.sh"
    scope_triage_prompt="$root/prompts/scope-triage.md"
    restore_real_manifest_hooks
    _init_run_manifest

    log_execution() { :; }
    _v2_scope_triage_state_path() { printf '%s\n' "$comp_dir/scope-triage.state"; }
    _v2_scope_triage_raw_output_path() { printf '%s\n' "$comp_dir/execution-scope-triage.raw.json"; }
    _v2_repo_relative_path() { printf 'task.md\n'; }
    _v2_collect_out_of_scope_untracked_paths_for_triage() { :; }
    _v2_write_scope_triage_state() { :; }
    _v2_build_scope_triage_instruction() { printf 'scope triage\n'; }
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT="scope-system"
    }
    run_agent() {
        local _role="$1" _engine="$2" _body="$3" _system="$4" output="$5" log_file="$6"
        SCOPE_TRIAGE_ENGINE="$_engine"
        printf '{}\n' > "$output"
        : > "$log_file"
        return 0
    }
    _v2_scope_triage_entries_as_tsv() { printf 'src/example.sh\tPLAN_GAP\tNeeded by scope triage\n'; }
    _v2_scope_triage_records_cover_candidates() { return 0; }
    _v2_is_pipeline_owned_phase4_noise() { return 1; }
    _v2_is_untracked_path() { return 1; }
    _v2_quarantine_untracked_noise_path() { return 1; }
    _v2_path_changed_in_commit_range() { return 1; }
    _v2_restore_tracked_noise_path() { return 1; }
    capture_diff_artifact() { printf 'diff --git a/src/example.sh b/src/example.sh\n' > "$2"; }
    _v2_filter_out_paths_from_list() { printf '%s\n' "$1"; }
    _v2_refresh_traditional_dev_proxy_artifacts() { :; }
    _v2_append_scope_triage_log_entry() { :; }

    _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD~1" "$plan_file" "$diff_file" "" 0 || exit 1

    [[ "$SCOPE_TRIAGE_ENGINE" == "claude" ]]
    jq -e '
        ([.phases[] | select(
            .phase == "phase-4" and
            .name == "scope-triage" and
            .status == "skipped" and
            .error_class == "codex_circuit_breaker" and
            (.error_detail | contains("cumulative_failures=2"))
        )] | length) == 1
    ' "$comp_dir/run-manifest.json" >/dev/null
) && pass "90c. scope-triage breaker overrides Codex to Claude and records a skipped manifest phase" \
  || fail "90c. scope-triage breaker overrides Codex to Claude and records a skipped manifest phase"

(
    slug="session2-reviewer-a-breaker-fallback"
    fixture_root="$(setup_pipeline_fixture "$slug" "$slug")"
    seed_phase4_checkpoints "$fixture_root" "$slug"
    ROLE_LOG="$TMP_ROOT/${slug}.roles"
    : > "$ROLE_LOG"
    SCRIPT_DIR="$fixture_root"
    MODEL="opus"
    PROJECT_RULES=""
    AGENT_SETTINGS='{}'
    set_runtime_defaults
    restore_real_manifest_hooks
    FORCE_RERUN=false
    LAUREN_LOOP_STRICT=false
    _V2_CODEX_RUN_FAILURES=2
    ENGINE_EVALUATOR="claude"
    ENGINE_REVIEWER_A="claude"
    ENGINE_REVIEWER_B="codex"
    REVIEWER_B_REQUEST_BODY=""
    prepare_agent_request() {
        AGENT_PROMPT_BODY="$3"
        AGENT_SYSTEM_PROMPT=$(cat "$2")
        case "$2" in
            */reviewer-b.md)
                REVIEWER_B_REQUEST_BODY="$3"
                ;;
        esac
    }
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
        printf '%s|%s\n' "$role" "$_engine" >> "$ROLE_LOG"
        case "$role" in
            reviewer-a)
                return 1
                ;;
            reviewer-a-claude-fallback)
                write_reviewer_a_artifacts "$SCRIPT_DIR" "$slug" "PASS" "[major/correctness] file:1 - issue
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
        lauren_loop_competitive "$slug" "circuit breaker overrides reviewer-a codex fallback to claude"
    )
    manifest="$fixture_root/docs/tasks/open/$slug/competitive/run-manifest.json"
    grep -Fq 'reviewer-a-claude-fallback|claude' "$ROLE_LOG"
    ! grep -Fq 'reviewer-a-codex-fallback|codex' "$ROLE_LOG"
    grep -Fq 'reviewer-b|claude' "$ROLE_LOG"
    ! grep -Fq 'reviewer-b|codex' "$ROLE_LOG"
    [[ "$REVIEWER_B_REQUEST_BODY" == *"${fixture_root}/docs/tasks/open/${slug}/competitive/reviewer-b.raw.md"* ]]
    [[ "$REVIEWER_B_REQUEST_BODY" != *"$CODEX_ARTIFACT_PATH_PLACEHOLDER"* ]]
    [[ -f "$manifest" ]]
    jq -e '
        ([.phases[] | select(
            .phase == "phase-5" and
            .name == "review-cycle-1-b" and
            .status == "skipped" and
            .error_class == "codex_circuit_breaker" and
            .error_detail == "dispatch=reviewer-b; skipped_engine=codex; fallback_engine=claude; cumulative_failures=2"
        )] | length) == 1
    ' "$manifest" >/dev/null
) && pass "90d. reviewer breakers use Claude fallbacks plus the effective reviewer-b artifact path and skipped manifest entry" \
  || fail "90d. reviewer breakers use Claude fallbacks plus the effective reviewer-b artifact path and skipped manifest entry"

(
    _V2_CODEX_RUN_FAILURES=0
    _v2_record_codex_outcome "claude" 1
    [[ "$_V2_CODEX_RUN_FAILURES" -eq 0 ]]
) && pass "90e. _v2_record_codex_outcome ignores non-Codex engines" \
  || fail "90e. _v2_record_codex_outcome ignores non-Codex engines"

(
    comp_dir="$TMP_ROOT/phase8a-route-inputs"
    mkdir -p "$comp_dir"
    printf 'verify\n' > "$comp_dir/final-verify.md"
    printf '{"verdict":"FAIL"}\n' > "$comp_dir/final-verify.contract.json"
    load_real_phase8c_route_helpers
    required_inputs="$(_phase8c_route_required_inputs "$comp_dir" "phase-8a")"
    instruction=$(_phase8c_final_fix_input_instruction \
        "docs/tasks/open/phase8a/competitive/final-verify.md" \
        "docs/tasks/open/phase8a/competitive/final-verify.contract.json" \
        "phase-8a")
    [[ "$(printf '%s\n' "$required_inputs" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 2 ]]
    ! printf '%s\n' "$required_inputs" | grep -q 'final-falsify'
    [[ "$instruction" == *"Read docs/tasks/open/phase8a/competitive/final-verify.md and docs/tasks/open/phase8a/competitive/final-verify.contract.json."* ]]
    [[ "$instruction" == *"Do not require competitive/final-falsify.md or competitive/final-falsify.contract.json on this route."* ]]
    grep -Fq "Read the route-specific Phase 8 inputs named in the runtime instruction." "$REPO_ROOT/prompts/final-fixer.md"
) && pass "90f. phase-8a FAIL routes Phase 8c through verifier-only inputs and a route-aware fixer prompt" \
  || fail "90f. phase-8a FAIL routes Phase 8c through verifier-only inputs and a route-aware fixer prompt"

(
    comp_dir="$TMP_ROOT/phase8b-route-inputs"
    mkdir -p "$comp_dir"
    printf 'verify\n' > "$comp_dir/final-verify.md"
    printf '{"verdict":"PASS"}\n' > "$comp_dir/final-verify.contract.json"
    printf 'falsify\n' > "$comp_dir/final-falsify.md"
    printf '{"verdict":"FAIL"}\n' > "$comp_dir/final-falsify.contract.json"
    load_real_phase8c_route_helpers
    required_inputs="$(_phase8c_route_required_inputs "$comp_dir" "phase-8b")"
    instruction=$(_phase8c_final_fix_input_instruction \
        "docs/tasks/open/phase8b/competitive/final-verify.md" \
        "docs/tasks/open/phase8b/competitive/final-verify.contract.json" \
        "phase-8b" \
        "docs/tasks/open/phase8b/competitive/final-falsify.md" \
        "docs/tasks/open/phase8b/competitive/final-falsify.contract.json")
    [[ "$(printf '%s\n' "$required_inputs" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 4 ]]
    printf '%s\n' "$required_inputs" | grep -q 'final-falsify.md'
    [[ "$instruction" == *"Read docs/tasks/open/phase8b/competitive/final-verify.md, docs/tasks/open/phase8b/competitive/final-verify.contract.json, docs/tasks/open/phase8b/competitive/final-falsify.md, and docs/tasks/open/phase8b/competitive/final-falsify.contract.json."* ]]
) && pass "90g. phase-8b FAIL keeps final-falsify inputs in the Phase 8c fixer contract" \
  || fail "90g. phase-8b FAIL keeps final-falsify inputs in the Phase 8c fixer contract"

(
    comp_dir="$TMP_ROOT/phase8b-missing-inputs"
    mkdir -p "$comp_dir"
    printf 'verify\n' > "$comp_dir/final-verify.md"
    printf '{"verdict":"PASS"}\n' > "$comp_dir/final-verify.contract.json"
    load_real_phase8c_route_helpers
    missing_input=$(_phase8c_route_first_missing_input "$comp_dir" "phase-8b")
    [[ "$missing_input" == "$comp_dir/final-falsify.md" ]]
) && pass "90h. Phase 8c names a missing required final-falsify artifact instead of reporting generic staging failure" \
  || fail "90h. Phase 8c names a missing required final-falsify artifact instead of reporting generic staging failure"

(
    _codex_role_uses_tool_written_artifact "final-verify"
    _codex_role_uses_tool_written_artifact "final-falsify"
    _codex_role_uses_tool_written_artifact "final-fix"
) && pass "90i. final Phase 8 Codex roles use tool-written artifacts" \
  || fail "90i. final Phase 8 Codex roles use tool-written artifacts"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

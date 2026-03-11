#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-auto.XXXXXX")"
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

setup_fixture() {
    local name="$1"
    local root="$TMP_ROOT/$name"
    mkdir -p "$root/bin" "$root/lib" "$root/templates" "$root/prompts" "$root/docs/tasks/open" "$root/home"

    cp "$REPO_ROOT/lauren-loop.sh" "$root/lauren-loop.sh"
    cp "$REPO_ROOT/lib/lauren-loop-utils.sh" "$root/lib/lauren-loop-utils.sh"
    cp "$REPO_ROOT/templates/pilot-task.md" "$root/templates/pilot-task.md"
    cp "$REPO_ROOT/prompts/project-rules.md" "$root/prompts/project-rules.md"
    cp "$REPO_ROOT/prompts/lead.md" "$root/prompts/lead.md"
    cp "$REPO_ROOT/prompts/critic.md" "$root/prompts/critic.md"
    cp "$REPO_ROOT/prompts/classifier.md" "$root/prompts/classifier.md"
    cp "$REPO_ROOT/prompts/reviewer.md" "$root/prompts/reviewer.md"
    cp "$REPO_ROOT/prompts/executor.md" "$root/prompts/executor.md"
    cp "$REPO_ROOT/prompts/chaos-critic.md" "$root/prompts/chaos-critic.md"
    cp "$REPO_ROOT/prompts/verifier.md" "$root/prompts/verifier.md"
    cp "$REPO_ROOT/prompts/retro-hook.md" "$root/prompts/retro-hook.md"

    cat > "$root/bin/claude" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ -n "${CLAUDE_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$CLAUDE_LOG"
fi
if [ -n "${FAKE_CLASSIFY_OUTPUT:-}" ]; then
    printf '%s\n' "$FAKE_CLASSIFY_OUTPUT"
    exit "${FAKE_CLASSIFY_EXIT:-0}"
fi
echo "unexpected claude invocation" >&2
exit 99
EOF
    chmod +x "$root/bin/claude"

    cat > "$root/lauren-loop-v2.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
slug="$1"
goal="$2"
shift 2
if [ -n "${V2_LOG:-}" ]; then
    printf 'slug=%s goal=%s args=%s\n' "$slug" "$goal" "$*" >> "$V2_LOG"
fi
task_dir="$SCRIPT_DIR/docs/tasks/open/${slug}"
mkdir -p "$task_dir/logs"
cat > "$task_dir/logs/cost.csv" <<'CSV'
timestamp,task,agent_role,engine,model,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,cost_usd,duration_sec,exit_code,status
2026-03-10T00:00:00+0000,test,stub,claude,opus,1,0,0,1,1.2345,5,0,completed
CSV
cat > "$task_dir/task.md" <<TASK
## Task: ${slug}
## Status: needs verification
## Goal: ${goal}
TASK
echo "V2 stub ran for ${slug}"
exit "${V2_EXIT_CODE:-0}"
EOF
    chmod +x "$root/lauren-loop-v2.sh"
    chmod +x "$root/lauren-loop.sh"

    printf '%s\n' "$root"
}

run_auto() {
    local fixture="$1"
    shift
    HOME="$fixture/home" PATH="$fixture/bin:$PATH" bash "$fixture/lauren-loop.sh" "$@"
}

run_cmd() {
    local fixture="$1"
    shift
    HOME="$fixture/home" PATH="$fixture/bin:$PATH" bash "$fixture/lauren-loop.sh" "$@"
}

write_task_file() {
    local path="$1" title="$2" status="$3" goal="$4" plan_body="${5:-Step 1: Do something}"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
## Task: ${title}
## Status: ${status}
## Goal: ${goal}

## Current Plan
${plan_body}

## Critique
(Critic writes here)

## Review Findings

## Review Critique

## Fixes Applied

## Review History

## Plan History
(Archived plan+critique rounds)

## Execution Log
(Timestamped round results)
EOF
}

init_fixture_git() {
    local fixture="$1"
    (
        cd "$fixture"
        git init -q
        git config user.name "Lauren Loop Auto Tests"
        git config user.email "lauren-loop-auto@example.com"
        git add .
        git commit -q -m "fixture"
    )
}

(
    fixture=$(setup_fixture "simple-override")
    output="$fixture/output.txt"
    claude_log="$fixture/claude.log"
    CLAUDE_LOG="$claude_log" run_auto "$fixture" auto sample-simple "Sample goal" --simple --dry-run --model sonnet > "$output" 2>&1

    grep -q "Pipeline: V1" "$output"
    grep -q "Reason:   override: --simple" "$output"
    grep -q "Cost:     N/A" "$output"
    [ ! -s "$claude_log" ]
    [ -f "$fixture/docs/tasks/open/pilot-sample-simple.md" ]
) && pass "1. auto --simple routes to V1 and skips classifier" \
  || fail "1. auto --simple routes to V1 and skips classifier"

(
    fixture=$(setup_fixture "thorough-override")
    output="$fixture/output.txt"
    claude_log="$fixture/claude.log"
    v2_log="$fixture/v2.log"
    CLAUDE_LOG="$claude_log" V2_LOG="$v2_log" run_auto "$fixture" auto sample-thorough "Thorough goal" --thorough --dry-run --model sonnet > "$output" 2>&1

    grep -q "Pipeline: V2" "$output"
    grep -q "Reason:   override: --thorough" "$output"
    grep -q "Cost:     1.2345" "$output"
    [ ! -s "$claude_log" ]
    grep -q "slug=sample-thorough" "$v2_log"
) && pass "2. auto --thorough routes to V2 and skips classifier" \
  || fail "2. auto --thorough routes to V2 and skips classifier"

(
    fixture=$(setup_fixture "classified-simple")
    output="$fixture/output.txt"
    claude_log="$fixture/claude.log"
    classifier_output="$(
        cat <<'EOF'
CLASSIFICATION : simple

## Dimension Scores
- File Count: LOW — test

## Rationale
Fits the existing single-agent path.
EOF
    )"

    CLAUDE_LOG="$claude_log" FAKE_CLASSIFY_OUTPUT="$classifier_output" run_auto "$fixture" auto routed-simple "Simple goal" --dry-run --model sonnet > "$output" 2>&1

    grep -q "Pipeline: V1" "$output"
    grep -q "Reason:   Fits the existing single-agent path." "$output"
    grep -q '^## Complexity: simple$' "$fixture/docs/tasks/open/pilot-routed-simple.md"
    grep -q "Goal: Simple goal" "$claude_log"
    [ -s "$claude_log" ]
) && pass "3. auto classifier simple route uses V1 and surfaces rationale" \
  || fail "3. auto classifier simple route uses V1 and surfaces rationale"

(
    fixture=$(setup_fixture "classified-complex")
    output="$fixture/output.txt"
    claude_log="$fixture/claude.log"
    v2_log="$fixture/v2.log"
    classifier_output="$(
        cat <<'EOF'
CLASSIFICATION: complex

## Dimension Scores
- File Count: HIGH — test

## Rationale
Touches enough surface area to require V2.
EOF
    )"

    CLAUDE_LOG="$claude_log" V2_LOG="$v2_log" FAKE_CLASSIFY_OUTPUT="$classifier_output" run_auto "$fixture" auto routed-complex "Complex goal" --dry-run --model sonnet > "$output" 2>&1

    grep -q "Pipeline: V2" "$output"
    grep -q "Reason:   Touches enough surface area to require V2." "$output"
    grep -q "Cost:     1.2345" "$output"
    grep -q '^## Complexity: complex$' "$fixture/docs/tasks/open/routed-complex/task.md"
    [ ! -e "$fixture/docs/tasks/open/pilot-routed-complex.md" ]
    grep -q "Goal: Complex goal" "$claude_log"
    [ -s "$claude_log" ]
    grep -q "slug=routed-complex" "$v2_log"
) && pass "4. auto classifier complex route uses V2 and surfaces rationale" \
  || fail "4. auto classifier complex route uses V2 and surfaces rationale"

(
    fixture=$(setup_fixture "thorough-resume-passthrough")
    output="$fixture/output.txt"
    v2_log="$fixture/v2.log"
    set +e
    V2_LOG="$v2_log" run_auto "$fixture" auto bad-flags "Resume thorough" --thorough --resume --dry-run --model sonnet > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 0 ]
    grep -q "checkpoint-based resumption" "$output"
) && pass "5. auto allows --resume under --thorough with info message" \
  || fail "5. auto allows --resume under --thorough with info message"

(
    fixture=$(setup_fixture "thorough-no-review-rejection")
    output="$fixture/output.txt"
    set +e
    run_auto "$fixture" auto no-review "Bad flags" --thorough --no-review > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    grep -q "does not support --no-review or --no-close" "$output"
) && pass "6. auto rejects --no-review under --thorough" \
  || fail "6. auto rejects --no-review under --thorough"

(
    fixture=$(setup_fixture "thorough-no-close-rejection")
    output="$fixture/output.txt"
    set +e
    run_auto "$fixture" auto no-close "Bad flags" --thorough --no-close > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    grep -q "does not support --no-review or --no-close" "$output"
) && pass "7. auto rejects --no-close under --thorough" \
  || fail "7. auto rejects --no-close under --thorough"

(
    fixture=$(setup_fixture "force-forwarded")
    output="$fixture/output.txt"
    v2_log="$fixture/v2.log"
    V2_LOG="$v2_log" run_auto "$fixture" auto rerun "Force rerun" --thorough --force --dry-run --model sonnet > "$output" 2>&1

    grep -q "Pipeline: V2" "$output"
    grep -q -- '--force' "$v2_log"
) && pass "8. auto forwards --force to V2" \
  || fail "8. auto forwards --force to V2"

(
    fixture=$(setup_fixture "force-rejected-v1")
    output="$fixture/output.txt"
    set +e
    run_auto "$fixture" auto no-force "No force" --simple --force > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    grep -q "V1 routing does not support --force" "$output"
) && pass "9. auto rejects --force on V1 routes" \
  || fail "9. auto rejects --force on V1 routes"

(
    fixture=$(setup_fixture "classifier-garbage")
    output="$fixture/output.txt"
    classifier_output="$(
        cat <<'EOF'
CLASSIFICATION: maybe

## Rationale
Garbage output.
EOF
    )"

    set +e
    FAKE_CLASSIFY_OUTPUT="$classifier_output" run_auto "$fixture" auto garbage "Garbage goal" --dry-run > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    grep -Eq "Auto-routing parse error|Parse error: could not extract valid CLASSIFICATION" "$output"
) && pass "10. auto fails on garbage classifier output" \
  || fail "10. auto fails on garbage classifier output"

(
    fixture=$(setup_fixture "v1-exit-propagation")
    output="$fixture/output.txt"
    claude_log="$fixture/claude.log"
    set +e
    CLAUDE_LOG="$claude_log" run_auto "$fixture" auto missing-resume "Resume only" --simple > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 1 ]
    [ ! -s "$claude_log" ]
    grep -q "Pipeline: V1" "$output"
    grep -q "Exit:     1" "$output"
) && pass "11. auto propagates failed V1 child exit code" \
  || fail "11. auto propagates failed V1 child exit code"

(
    fixture=$(setup_fixture "v2-exit-propagation")
    output="$fixture/output.txt"
    set +e
    V2_EXIT_CODE=23 run_auto "$fixture" auto failed-v2 "V2 failure" --thorough > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 23 ]
    grep -q "Pipeline: V2" "$output"
    grep -q "Exit:     23" "$output"
) && pass "12. auto propagates failed V2 child exit code" \
  || fail "12. auto propagates failed V2 child exit code"

(
    fixture=$(setup_fixture "existing-v2-route")
    output="$fixture/output.txt"
    claude_log="$fixture/claude.log"
    v2_log="$fixture/v2.log"
    mkdir -p "$fixture/docs/tasks/open/existing-v2/logs"
    cat > "$fixture/docs/tasks/open/existing-v2/task.md" <<'TASK'
## Task: existing-v2
## Status: needs verification
## Goal: Existing V2 task
TASK

    CLAUDE_LOG="$claude_log" V2_LOG="$v2_log" run_auto "$fixture" auto existing-v2 "Existing V2 task" --force --dry-run > "$output" 2>&1

    [ ! -s "$claude_log" ]
    grep -q "Reason:   existing V2 task" "$output"
    grep -q "Pipeline: V2" "$output"
    grep -q -- '--force' "$v2_log"
    grep -q '^## Complexity: complex$' "$fixture/docs/tasks/open/existing-v2/task.md"
    [ ! -e "$fixture/docs/tasks/open/pilot-existing-v2.md" ]
) && pass "13. auto resolves existing V2 task directories and skips classifier" \
  || fail "13. auto resolves existing V2 task directories and skips classifier"

(
    fixture=$(setup_fixture "classifier-simple-force")
    output="$fixture/output.txt"
    classifier_output="$(cat <<'EOF'
CLASSIFICATION: simple

## Dimension Scores
- File Count: LOW — trivial

## Rationale
Single-file change.
EOF
    )"

    set +e
    FAKE_CLASSIFY_OUTPUT="$classifier_output" run_auto "$fixture" auto force-simple "Force simple" --force --dry-run --model sonnet > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    grep -q "V1 routing does not support --force" "$output"
) && pass "14. classifier simple + --force rejects with error" \
  || fail "14. classifier simple + --force rejects with error"

(
    fixture=$(setup_fixture "no-close-forwarded")
    output="$fixture/output.txt"

    {
        head -1 "$fixture/lauren-loop.sh"
        echo '[ "${1:-}" != "auto" ] && [ "${1:-}" != "classify" ] && printf "%s\n" "$*" > "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/child-args.log"'
        tail -n +2 "$fixture/lauren-loop.sh"
    } > "$fixture/lauren-loop-patched.sh"
    mv "$fixture/lauren-loop-patched.sh" "$fixture/lauren-loop.sh"
    chmod +x "$fixture/lauren-loop.sh"

    run_auto "$fixture" auto no-close-test "No close goal" --simple --dry-run --model sonnet > "$output" 2>&1

    grep -q "Pipeline: V1" "$output"
    [ -f "$fixture/child-args.log" ]
    grep -q -- '--no-close' "$fixture/child-args.log"
) && pass "16. V1 child receives --no-close from auto caller" \
  || fail "16. V1 child receives --no-close from auto caller"

(
    fixture=$(setup_fixture "override-complexity-writeback")
    output="$fixture/output.txt"

    run_auto "$fixture" auto simple-wb "Simple writeback" --simple --dry-run --model sonnet > "$output" 2>&1
    grep -q '^## Complexity: simple$' "$fixture/docs/tasks/open/pilot-simple-wb.md"

    v2_log="$fixture/v2.log"
    V2_LOG="$v2_log" run_auto "$fixture" auto thorough-wb "Thorough writeback" --thorough --dry-run --model sonnet >> "$output" 2>&1
    grep -q '^## Complexity: complex$' "$fixture/docs/tasks/open/thorough-wb/task.md"
) && pass "17. override flags write complexity to task file" \
  || fail "17. override flags write complexity to task file"

(
    flat_fixture=$(setup_fixture "progress-flat-resolution")
    flat_output="$flat_fixture/flat.txt"
    write_task_file "$flat_fixture/docs/tasks/open/root-task.md" "Root Task" "in progress" "Root goal"
    run_cmd "$flat_fixture" progress root-task > "$flat_output" 2>&1
    grep -q 'Task: root-task' "$flat_output"
    grep -q 'Goal:   Root goal' "$flat_output"

    pilot_fixture=$(setup_fixture "progress-pilot-resolution")
    pilot_output="$pilot_fixture/pilot.txt"
    write_task_file "$pilot_fixture/docs/tasks/open/pilot-legacy-task.md" "Legacy Task" "in progress" "Legacy goal"
    run_cmd "$pilot_fixture" progress legacy-task > "$pilot_output" 2>&1
    grep -q 'Task: legacy-task' "$pilot_output"
    grep -q 'Goal:   Legacy goal' "$pilot_output"

    dir_fixture=$(setup_fixture "progress-dir-resolution")
    dir_output="$dir_fixture/dir.txt"
    write_task_file "$dir_fixture/docs/tasks/open/dir-progress/task.md" "Dir Progress" "in progress" "Directory goal"
    run_cmd "$dir_fixture" progress dir-progress > "$dir_output" 2>&1
    grep -q 'Task: dir-progress' "$dir_output"
    grep -q 'Goal:   Directory goal' "$dir_output"

    ambiguous_fixture=$(setup_fixture "progress-ambiguous-resolution")
    ambiguous_output="$ambiguous_fixture/ambiguous.txt"
    write_task_file "$ambiguous_fixture/docs/tasks/open/ambiguous.md" "Ambiguous Flat" "in progress" "Flat goal"
    write_task_file "$ambiguous_fixture/docs/tasks/open/ambiguous/task.md" "Ambiguous Dir" "in progress" "Directory winner"
    set +e
    run_cmd "$ambiguous_fixture" progress ambiguous > "$ambiguous_output" 2>&1
    ambiguous_rc=$?
    set -e
    [ "$ambiguous_rc" -eq 1 ]
    grep -q "ERROR: ambiguous task slug 'ambiguous'" "$ambiguous_output"
    ! grep -q 'Goal:   Directory winner' "$ambiguous_output"

    missing_fixture=$(setup_fixture "progress-missing-resolution")
    missing_output="$missing_fixture/missing.txt"
    set +e
    run_cmd "$missing_fixture" progress missing-task > "$missing_output" 2>&1
    missing_rc=$?
    set -e
    [ "$missing_rc" -eq 1 ]
    grep -q 'Task file not found:' "$missing_output"
) && pass "18. progress resolves flat, pilot, directory, rejects ambiguous, and rejects missing slug paths" \
  || fail "18. progress resolves flat, pilot, directory, rejects ambiguous, and rejects missing slug paths"

(
    fixture=$(setup_fixture "pause-resume-directory-resolution")
    pause_output="$fixture/pause.txt"
    resume_output="$fixture/resume.txt"
    write_task_file "$fixture/docs/tasks/open/dir-task/task.md" "Dir Task" "in progress" "Directory goal"

    run_cmd "$fixture" pause dir-task > "$pause_output" 2>&1
    grep -q 'Task paused' "$pause_output"
    [ -f "$fixture/.planning/dir-task.json" ]
    grep -q '^## Status: paused$' "$fixture/docs/tasks/open/dir-task/task.md"

    run_cmd "$fixture" resume dir-task > "$resume_output" 2>&1
    grep -q 'Task resumed' "$resume_output"
    grep -q 'Status restored: in progress' "$resume_output"
    grep -q '^## Status: in progress$' "$fixture/docs/tasks/open/dir-task/task.md"
) && pass "19. pause and resume resolve directory-backed task.md files" \
  || fail "19. pause and resume resolve directory-backed task.md files"

(
    fixture=$(setup_fixture "plancheck-directory-resolution")
    output="$fixture/output.txt"
    xml_plan=$'<wave number="1">\n  <task type="auto">\n    <name>Validate XML</name>\n    <files>lauren-loop.sh</files>\n    <action>Check the contract.</action>\n    <verify>bash -n lauren-loop.sh</verify>\n    <done>Contract is valid.</done>\n  </task>\n</wave>'
    write_task_file "$fixture/docs/tasks/open/xml-task/task.md" "XML Task" "plan-approved" "XML goal" "$xml_plan"

    run_cmd "$fixture" plan-check xml-task > "$output" 2>&1

    grep -q 'Format: XML' "$output"
    grep -q 'Plan validation passed' "$output"
) && pass "20. plan-check resolves directory-backed task.md files" \
  || fail "20. plan-check resolves directory-backed task.md files"

(
    fixture=$(setup_fixture "reset-directory-resolution")
    output="$fixture/output.txt"
    write_task_file "$fixture/docs/tasks/open/reset-dir/task.md" "Reset Dir" "blocked" "Reset goal" "Implement the approved plan."

    run_cmd "$fixture" reset reset-dir > "$output" 2>&1

    grep -q "Reset: 'blocked' → 'plan-approved'" "$output"
    grep -q '^## Status: plan-approved$' "$fixture/docs/tasks/open/reset-dir/task.md"
) && pass "21. reset resolves directory-backed task.md files" \
  || fail "21. reset resolves directory-backed task.md files"

(
    fixture=$(setup_fixture "close-directory-resolution")
    output="$fixture/output.txt"
    write_task_file "$fixture/docs/tasks/open/close-dir/task.md" "Close Dir" "blocked" "Close goal"
    mkdir -p "$fixture/docs/tasks/open/close-dir/competitive"
    cat > "$fixture/docs/tasks/open/close-dir/competitive/plan-critique.md" <<'EOF'
## Critique

## Verdict

VERDICT: EXECUTE
EOF
    printf '{"verdict":"EXECUTE"}\n' > "$fixture/docs/tasks/open/close-dir/competitive/plan-critique.contract.json"

    run_cmd "$fixture" close close-dir --force > "$output" 2>&1

    grep -q 'Close complete' "$output"
    grep -q 'relocate competitive/ artifacts' "$output"
    [ -d "$fixture/docs/tasks/closed/close-dir" ]
    [ -f "$fixture/docs/tasks/closed/close-dir/task.md" ]
    [ -f "$fixture/docs/tasks/closed/close-dir/competitive/plan-critique.md" ]
    [ -f "$fixture/docs/tasks/closed/close-dir/competitive/plan-critique.contract.json" ]
    [ ! -e "$fixture/docs/tasks/open/close-dir" ]
    grep -q '^## Status: closed$' "$fixture/docs/tasks/closed/close-dir/task.md"
) && pass "22. close --force preserves directory-backed competitive artifacts and warns before move" \
  || fail "22. close --force preserves directory-backed competitive artifacts and warns before move"

(
    fixture=$(setup_fixture "review-fix-directory-resolution")
    review_output="$fixture/review.txt"
    fix_output="$fixture/fix.txt"
    write_task_file "$fixture/docs/tasks/open/review-dir/task.md" "Review Dir" "executed" "Review goal"
    mkdir -p "$fixture/logs/pilot"
    printf 'diff --git a/x b/x\n' > "$fixture/logs/pilot/review-dir-diff.patch"

    set +e
    run_cmd "$fixture" review review-dir > "$review_output" 2>&1
    review_rc=$?
    run_cmd "$fixture" fix review-dir > "$fix_output" 2>&1
    fix_rc=$?
    set -e

    [ "$review_rc" -eq 1 ]
    grep -q 'V2 task' "$review_output"
    ! grep -q 'Task file not found' "$review_output"
    [ "$fix_rc" -eq 1 ]
    grep -q 'V2 task' "$fix_output"
    ! grep -q 'Task file not found' "$fix_output"
) && pass "23. review and fix on directory-backed V2 tasks exit with V2 redirect" \
  || fail "23. review and fix on directory-backed V2 tasks exit with V2 redirect"

(
    fixture=$(setup_fixture "execute-chaos-verify-directory-resolution")
    execute_output="$fixture/execute.txt"
    chaos_output="$fixture/chaos.txt"
    verify_output="$fixture/verify.txt"
    xml_plan=$'<wave number="1">\n  <task type="auto">\n    <name>Do the work</name>\n    <files>lauren-loop.sh</files>\n    <action>Implement it.</action>\n    <verify>bash -n lauren-loop.sh</verify>\n    <done>Done.</done>\n  </task>\n</wave>'
    write_task_file "$fixture/docs/tasks/open/exec-dir/task.md" "Exec Dir" "blocked" "Exec goal" "$xml_plan"
    write_task_file "$fixture/docs/tasks/open/chaos-dir/task.md" "Chaos Dir" "plan-approved" "Chaos goal" "$xml_plan"
    write_task_file "$fixture/docs/tasks/open/verify-dir/task.md" "Verify Dir" "needs verification" "Verify goal" "$xml_plan"

    set +e
    run_cmd "$fixture" execute exec-dir > "$execute_output" 2>&1
    execute_rc=$?
    run_cmd "$fixture" chaos chaos-dir > "$chaos_output" 2>&1
    chaos_rc=$?
    run_cmd "$fixture" verify verify-dir > "$verify_output" 2>&1
    verify_rc=$?
    set -e

    [ "$execute_rc" -eq 1 ]
    grep -q 'V2 task' "$execute_output"
    ! grep -q 'Task file not found' "$execute_output"
    [ "$chaos_rc" -eq 1 ]
    grep -q 'V2 task' "$chaos_output"
    ! grep -q 'Task file not found' "$chaos_output"
    [ "$verify_rc" -eq 1 ]
    grep -q 'V2 task' "$verify_output"
    ! grep -q 'Task file not found' "$verify_output"
) && pass "24. execute, chaos, and verify on directory-backed V2 tasks exit with V2 redirect" \
  || fail "24. execute, chaos, and verify on directory-backed V2 tasks exit with V2 redirect"

# Gap 3: V2 task + V1 subcommand → helpful error
(
    fixture=$(setup_fixture "v2-review-guard")
    output="$fixture/output.txt"
    write_task_file "$fixture/docs/tasks/open/v2-guarded/task.md" "V2 Guarded" "executed" "V2 goal"
    mkdir -p "$fixture/logs/pilot"
    printf 'diff --git a/x b/x\n' > "$fixture/logs/pilot/v2-guarded-diff.patch"

    set +e
    run_cmd "$fixture" review v2-guarded > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 1 ]
    grep -q "V2 task" "$output"
    grep -q "competitive/" "$output"
) && pass "25. V2 task + review subcommand exits 1 with V2 redirect" \
  || fail "25. V2 task + review subcommand exits 1 with V2 redirect"

(
    fixture=$(setup_fixture "v1-review-passthrough")
    output="$fixture/output.txt"
    write_task_file "$fixture/docs/tasks/open/pilot-v1-task.md" "V1 Task" "executed" "V1 goal"
    mkdir -p "$fixture/logs/pilot"
    printf 'diff --git a/x b/x\n' > "$fixture/logs/pilot/pilot-v1-task-diff.patch"

    set +e
    run_cmd "$fixture" review v1-task > "$output" 2>&1
    rc=$?
    set -e

    # Should NOT see V2 task message — proceeds to later prerequisite check
    ! grep -q "V2 task" "$output"
) && pass "26. V1 task + review subcommand proceeds normally (no V2 guard)" \
  || fail "26. V1 task + review subcommand proceeds normally (no V2 guard)"

# Gap 5: --resume through auto for V2
(
    fixture=$(setup_fixture "resume-v2-passthrough")
    output="$fixture/output.txt"
    v2_log="$fixture/v2.log"
    classifier_output="$(cat <<'EOF'
CLASSIFICATION: complex

## Dimension Scores
- File Count: HIGH — many files

## Rationale
Multi-file change.
EOF
    )"

    set +e
    V2_LOG="$v2_log" FAKE_CLASSIFY_OUTPUT="$classifier_output" run_auto "$fixture" auto resume-v2 "Resume V2 goal" --resume --dry-run --model sonnet > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -eq 0 ]
    grep -q "checkpoint-based resumption" "$output"
    grep -q "Pipeline: V2" "$output"
) && pass "27. V2 routing + --resume succeeds with info message" \
  || fail "27. V2 routing + --resume succeeds with info message"

(
    fixture=$(setup_fixture "no-review-v2-still-rejected")
    output="$fixture/output.txt"
    classifier_output="$(cat <<'EOF'
CLASSIFICATION: complex

## Dimension Scores
- File Count: HIGH — many files

## Rationale
Multi-file change.
EOF
    )"

    set +e
    FAKE_CLASSIFY_OUTPUT="$classifier_output" run_auto "$fixture" auto noreview-v2 "No review V2" --thorough --no-review --dry-run --model sonnet > "$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    grep -q "does not support --no-review" "$output"
) && pass "28. V2 routing + --no-review still rejected" \
  || fail "28. V2 routing + --no-review still rejected"

(
    fixture=$(setup_fixture "resume-no-force-v1")
    output="$fixture/output.txt"
    claude_log="$fixture/claude.log"
    classifier_output="$(cat <<'EOF'
CLASSIFICATION: complex

## Dimension Scores
- File Count: HIGH — many files

## Rationale
Multi-file change.
EOF
    )"

    set +e
    CLAUDE_LOG="$claude_log" FAKE_CLASSIFY_OUTPUT="$classifier_output" run_auto "$fixture" auto resume-classify "Resume classify" --resume --dry-run --model sonnet > "$output" 2>&1
    rc=$?
    set -e

    # --resume alone should NOT force V1 — classifier should run and route V2
    grep -q "Pipeline: V2" "$output"
    ! grep -q "V1-only flags" "$output"
) && pass "29. --resume alone does not force V1 routing — classifier decides" \
  || fail "29. --resume alone does not force V1 routing — classifier decides"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

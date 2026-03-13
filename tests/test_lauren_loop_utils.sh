#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-utils.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0
TOTAL=0

# Minimal globals expected by sourced utils
SCRIPT_DIR="$REPO_ROOT"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
SLUG="test-slug"

pass() {
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "${GREEN}PASS${NC}: $1"
}

fail() {
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "${RED}FAIL${NC}: $1"
    if [ -n "${2:-}" ]; then
        echo "  Detail: $2"
    fi
}

write_task_fixture() {
    local path="$1"
    cat <<'EOF' > "$path"
## Task: Test Task
## Status: in-progress
## Goal: Fix the authentication system

## Current Plan
Step 1: Do something
Step 2: Do another thing

## Critique
VERDICT: FAIL — needs more detail

## Plan History
(Archived plan+critique rounds)

## Execution Log
(Timestamped round results)
EOF
}

write_review_fixture() {
    local path="$1"
    cat <<'EOF' > "$path"
## Task: Test Task
## Status: executed
## Goal: Fix the auth bug

## Review Findings
Found issue in auth.py line 42.
REVIEW VERDICT: FAIL

## Review Critique
The findings are thorough.
VERDICT: PASS

## Fixes Applied

## Review History

## Execution Log
(Timestamped round results)
EOF
}

write_valid_plan_artifact() {
    local path="$1" title="${2:-Plan Artifact}"
    cat > "$path" <<EOF
# ${title}

## Files to Modify
- \`lauren-loop-v2.sh\` — preserve tool-written artifacts and add Codex backstops
- \`lib/lauren-loop-utils.sh\` — add semantic validation and watcher helpers

## Implementation Tasks

\`\`\`xml
<wave number="1">
  <task type="auto">
    <name>Preserve Codex-written artifacts</name>
    <files>lauren-loop-v2.sh, lib/lauren-loop-utils.sh</files>
    <action>Keep Codex summary output separate from the real artifact and reject summary-only planner artifacts.</action>
    <verify>bash -n lauren-loop-v2.sh</verify>
    <done>Planner artifacts on disk retain the full plan content.</done>
  </task>
</wave>
\`\`\`

## Testability Design
- Exercise \`bash lauren-loop-v2.sh\` and the shell helper functions through their public script entry points.

## Test Strategy
- Run the Lauren Loop shell regression suite before and after the change.

## Risk Assessment
- Ensure early stub detection does not kill a still-growing artifact.

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

## Verdict

**VERDICT: ${verdict}**
**Blocking findings:** None
**Rationale:** test artifact
EOF
}

wait_for_lines() {
    local path="$1" expected_lines="$2" iterations="${3:-200}"
    local i actual_lines
    for ((i=0; i<iterations; i++)); do
        if [[ -f "$path" ]]; then
            actual_lines=$(wc -l < "$path" | tr -d ' ')
            if [[ "$actual_lines" -ge "$expected_lines" ]]; then
                return 0
            fi
        fi
        sleep 0.01
    done
    return 1
}

create_fake_notification_tools() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"

    cat > "$bin_dir/afplay" <<'EOF'
#!/bin/bash
printf 'afplay:%s\n' "$*" >> "$NOTIFY_LOG"
EOF

    cat > "$bin_dir/osascript" <<'EOF'
#!/bin/bash
printf 'osascript:%s\n' "$*" >> "$OSASCRIPT_LOG"
EOF

    chmod +x "$bin_dir/afplay" "$bin_dir/osascript"
}

# ============================================================
# Test 1: Sourcing works — all 28 functions defined
# ============================================================
(
    # Source in subshell to avoid polluting this script
    . "$REPO_ROOT/lib/lauren-loop-utils.sh"

    all_ok=true
    for fn in _sed_i _iso_timestamp _timeout same_dir_temp_file \
              notify_terminal_state _atomic_append _validate_agent_output \
              _write_cycle_state _read_cycle_state \
              section_bounds section_body \
              section_has_nonblank_content rewrite_section log_execution \
              prepare_attempt_log attempt_log_contains_max_turns ensure_sections \
              ensure_review_sections validate_task_file inject_context \
              archive_review_cycle archive_round extract_last_critic_verdict \
              extract_last_review_verdict ensure_retro_placeholder \
              list_superseded_tasks move_task_to_closed check_diff_scope; do
        if [ "$(type -t "$fn")" != "function" ]; then
            echo "Missing function: $fn" >&2
            all_ok=false
        fi
    done
    $all_ok
) && pass "1. Sourcing works — all 28 functions defined" \
  || fail "1. Sourcing works — all 28 functions defined"

# Source for remaining tests
. "$REPO_ROOT/lib/lauren-loop-utils.sh"

# ============================================================
# Test 2: _sed_i — in-place replacement
# ============================================================
(
    f="$TMP_ROOT/sed_test.txt"
    echo "hello world" > "$f"
    _sed_i 's/world/universe/' "$f"
    grep -q "hello universe" "$f"
) && pass "2. _sed_i — in-place replacement" \
  || fail "2. _sed_i — in-place replacement"

# ============================================================
# Test 3: _timeout — kills long-running command with canonical exit 124
# ============================================================
(
    set +e
    _timeout 1 sleep 5
    rc=$?
    [ "$rc" -eq 124 ]
) && pass "3. _timeout — long-running command returns 124" \
  || fail "3. _timeout — long-running command returns 124"

# ============================================================
# Test 3a: _timeout — shell function executes successfully
# ============================================================
(
    my_func() {
        echo "hello from function"
        sleep 1
        echo "done"
    }
    output=$(_timeout 5 my_func)
    rc=$?
    [ "$rc" -eq 0 ]
    echo "$output" | grep -q "hello from function"
    echo "$output" | grep -q "done"
) && pass "3a. _timeout — shell function succeeds" \
  || fail "3a. _timeout — shell function succeeds"

# ============================================================
# Test 3b: _timeout — preserves piped stdin for shell functions
# ============================================================
(
    stdin_func() {
        local line=""
        IFS= read -r line
        printf '%s\n' "$line"
    }
    output=$(printf 'payload\n' | _timeout 5 stdin_func)
    rc=$?
    [ "$rc" -eq 0 ]
    [ "$output" = "payload" ]
) && pass "3b. _timeout — preserves piped stdin" \
  || fail "3b. _timeout — preserves piped stdin"

# ============================================================
# Test 3c: jobs -p inside trap — timeout-style child/watchdog jobs are visible
# ============================================================
(
    fixture="$TMP_ROOT/jobs_trap_timeout_style.sh"
    cat > "$fixture" <<'FIXTURE'
#!/bin/bash
set -e
trap 'echo TRAP_START; jobs -p; echo TRAP_END; exit 130' INT
( sleep 1; kill -INT $$ ) &
sleep 30 &
cmd=$!
( sleep 30 ) &
watchdog=$!
printf 'READY:%s:%s\n' "$cmd" "$watchdog"
wait "$cmd"
FIXTURE
    chmod +x "$fixture"

    set +e
    output=$(/bin/bash "$fixture" 2>&1)
    rc=$?
    set -e

    [ "$rc" -eq 130 ] || { echo "expected rc=130, got $rc" >&2; exit 1; }
    echo "$output" | grep -q "TRAP_START" || { echo "missing trap start" >&2; exit 1; }
    echo "$output" | grep -q "TRAP_END" || { echo "missing trap end" >&2; exit 1; }
    pid_lines=$(printf '%s\n' "$output" | awk '/TRAP_START/{flag=1;next}/TRAP_END/{flag=0}flag' | grep -E '^[0-9]+$' | wc -l | tr -d ' ')
    [ "$pid_lines" -ge 2 ] || { echo "expected at least 2 job pids in trap, got $pid_lines" >&2; exit 1; }
) && pass "3c. jobs -p inside trap sees timeout-style jobs" \
  || fail "3c. jobs -p inside trap sees timeout-style jobs"

# ============================================================
# Test 4: section_bounds — returns start/end line numbers
# ============================================================
(
    f="$TMP_ROOT/bounds_test.md"
    write_task_fixture "$f"
    result=$(section_bounds "$f" "## Current Plan")
    start=$(echo "$result" | awk '{print $1}')
    end=$(echo "$result" | awk '{print $2}')
    [ "$start" -gt 0 ] && [ "$end" -gt "$start" ]
) && pass "4. section_bounds — returns start/end line numbers" \
  || fail "4. section_bounds — returns start/end line numbers"

# ============================================================
# Test 5: section_bounds error — duplicate section header
# ============================================================
(
    f="$TMP_ROOT/bounds_dup.md"
    printf '## Foo\nline1\n## Foo\nline2\n' > "$f"
    ! section_bounds "$f" "## Foo" 2>/dev/null
) && pass "5. section_bounds error — duplicate section returns 1" \
  || fail "5. section_bounds error — duplicate section returns 1"

# ============================================================
# Test 6: section_body — extract body content
# ============================================================
(
    f="$TMP_ROOT/body_test.md"
    write_task_fixture "$f"
    body=$(section_body "$f" "## Current Plan")
    echo "$body" | grep -q "Step 1"
) && pass "6. section_body — extract body content" \
  || fail "6. section_body — extract body content"

# ============================================================
# Test 7: section_has_nonblank_content
# ============================================================
(
    f="$TMP_ROOT/nonblank_test.md"
    write_task_fixture "$f"
    section_has_nonblank_content "$f" "## Current Plan"

    f2="$TMP_ROOT/nonblank_empty.md"
    printf '## Foo\n\n## Bar\nContent\n' > "$f2"
    ! section_has_nonblank_content "$f2" "## Foo"
) && pass "7. section_has_nonblank_content — true/false cases" \
  || fail "7. section_has_nonblank_content — true/false cases"

# ============================================================
# Test 8: rewrite_section — replace section body
# ============================================================
(
    f="$TMP_ROOT/rewrite_test.md"
    write_task_fixture "$f"
    rep="$TMP_ROOT/replacement.txt"
    printf 'New plan content\nLine 2\n' > "$rep"
    rewrite_section "$f" "## Current Plan" "$rep"
    grep -q "New plan content" "$f"
    grep -q "Line 2" "$f"
    # Other sections intact
    grep -q "## Critique" "$f"
    grep -q "## Execution Log" "$f"
) && pass "8. rewrite_section — replace section body" \
  || fail "8. rewrite_section — replace section body"

# ============================================================
# Test 9: validate_task_file — valid fixture passes
# ============================================================
(
    f="$TMP_ROOT/valid_task.md"
    write_task_fixture "$f"
    validate_task_file "$f" 2>/dev/null
) && pass "9. validate_task_file — valid fixture passes" \
  || fail "9. validate_task_file — valid fixture passes"

# ============================================================
# Test 10: validate_task_file — missing section fails
# ============================================================
(
    f="$TMP_ROOT/invalid_task.md"
    printf '## Task: Test\n## Status: in-progress\n## Goal: test\n## Current Plan\n## Plan History\n## Execution Log\n' > "$f"
    # Missing ## Critique
    ! validate_task_file "$f" 2>/dev/null
) && pass "10. validate_task_file — missing Critique fails" \
  || fail "10. validate_task_file — missing Critique fails"

# ============================================================
# Test 11: log_execution — append to Execution Log
# ============================================================
(
    f="$TMP_ROOT/log_exec.md"
    write_task_fixture "$f"
    log_execution "$f" "Test entry logged"
    grep -q "Test entry logged" "$f"
    # Verify timestamp format
    grep -qE '\[20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$f"
) && pass "11. log_execution — append with timestamp" \
  || fail "11. log_execution — append with timestamp"

# ============================================================
# Test 12: ensure_sections — adds missing sections
# ============================================================
(
    f="$TMP_ROOT/ensure_sec.md"
    printf '## Task: Test\n## Status: in-progress\n## Goal: test\n' > "$f"
    ensure_sections "$f"
    grep -q "## Current Plan" "$f"
    grep -q "## Critique" "$f"
    grep -q "## Plan History" "$f"
    grep -q "## Execution Log" "$f"
) && pass "12. ensure_sections — adds missing sections" \
  || fail "12. ensure_sections — adds missing sections"

# ============================================================
# Test 13: ensure_review_sections — inserts before Execution Log
# ============================================================
(
    f="$TMP_ROOT/ensure_review.md"
    write_task_fixture "$f"
    ensure_review_sections "$f"
    grep -q "## Review Findings" "$f"
    grep -q "## Review Critique" "$f"
    grep -q "## Review History" "$f"
    # Verify Review sections are BEFORE Execution Log
    rf_line=$(grep -n '## Review Findings' "$f" | head -1 | cut -d: -f1)
    el_line=$(grep -n '## Execution Log' "$f" | head -1 | cut -d: -f1)
    [ "$rf_line" -lt "$el_line" ]
) && pass "13. ensure_review_sections — inserts before Execution Log" \
  || fail "13. ensure_review_sections — inserts before Execution Log"

# ============================================================
# Test 14: archive_review_cycle — archives findings and critique
# ============================================================
(
    f="$TMP_ROOT/archive_review.md"
    write_review_fixture "$f"
    archive_review_cycle "$f"
    # Verify archived to Review History
    grep -q "### Review Cycle 1" "$f"
    grep -q "#### Findings" "$f"
    # Verify sections cleared (Review Findings should be empty after archive)
    findings=$(section_body "$f" "## Review Findings")
    [ -z "$(echo "$findings" | grep -v '^[[:space:]]*$')" ]
) && pass "14. archive_review_cycle — archives and clears" \
  || fail "14. archive_review_cycle — archives and clears"

# ============================================================
# Test 15: extract_last_critic_verdict — returns PASS
# ============================================================
(
    f="$TMP_ROOT/critic_verdict.md"
    write_review_fixture "$f"
    verdict=$(extract_last_critic_verdict "$f")
    [ "$verdict" = "PASS" ]
) && pass "15. extract_last_critic_verdict — returns PASS" \
  || fail "15. extract_last_critic_verdict — returns PASS"

# ============================================================
# Test 16: extract_last_review_verdict — returns FAIL
# ============================================================
(
    f="$TMP_ROOT/review_verdict.md"
    write_review_fixture "$f"
    verdict=$(extract_last_review_verdict "$f")
    [ "$verdict" = "FAIL" ]
) && pass "16. extract_last_review_verdict — returns FAIL" \
  || fail "16. extract_last_review_verdict — returns FAIL"

# ============================================================
# Test 17: move_task_to_closed — moves and updates status
# ============================================================
(
    d="$TMP_ROOT/move_test"
    mkdir -p "$d/docs/tasks/open" "$d/docs/tasks/closed"
    # Override SCRIPT_DIR for this test
    SCRIPT_DIR="$d"
    f="$d/docs/tasks/open/test-task.md"
    write_task_fixture "$f"
    result=$(move_task_to_closed "$f" "closed" "Closed by test")
    [ -f "$d/docs/tasks/closed/test-task.md" ]
    [ ! -f "$f" ]
    grep -q "## Status: closed" "$d/docs/tasks/closed/test-task.md"
    grep -q "Closed by test" "$d/docs/tasks/closed/test-task.md"
) && pass "17. move_task_to_closed — moves and updates status" \
  || fail "17. move_task_to_closed — moves and updates status"

# ============================================================
# Test 18: archive_round — archives plan + critique to history
# ============================================================
(
    f="$TMP_ROOT/archive_round.md"
    write_task_fixture "$f"
    archive_round "$f" 1
    # Verify archived
    grep -q "### Round 1" "$f"
    grep -q "#### Plan" "$f"
    # Verify sections cleared
    grep -q "(Planner writes here)" "$f"
    grep -q "(Critic writes here)" "$f"
) && pass "18. archive_round — archives plan + critique" \
  || fail "18. archive_round — archives plan + critique"

# ============================================================
# Test 19: prepare_attempt_log — appends header line
# ============================================================
(
    lf="$TMP_ROOT/attempt.log"
    start=$(SLUG="test-slug" prepare_attempt_log "$lf" "planner" "1")
    grep -q "phase=planner" "$lf"
    grep -q "slug=test-slug" "$lf"
    [ "$start" -ge 1 ]
) && pass "19. prepare_attempt_log — appends header" \
  || fail "19. prepare_attempt_log — appends header"

# ============================================================
# Test 20: same_dir_temp_file — creates in same directory
# ============================================================
(
    target="$TMP_ROOT/subdir/target.md"
    mkdir -p "$TMP_ROOT/subdir"
    touch "$target"
    tmp=$(same_dir_temp_file "$target")
    [ -f "$tmp" ]
    [ "$(dirname "$tmp")" = "$TMP_ROOT/subdir" ]
    rm -f "$tmp"
) && pass "20. same_dir_temp_file — creates in same directory" \
  || fail "20. same_dir_temp_file — creates in same directory"

# ============================================================
# Test 21: inject_context — injects related context block
# ============================================================
(
    d="$TMP_ROOT/inject_test"
    mkdir -p "$d/docs/tasks/open" "$d/docs/tasks/closed"
    SCRIPT_DIR="$d"
    SLUG="inject-test"

    # Create a closed task with keyword
    cat <<'INNER' > "$d/docs/tasks/closed/pilot-auth-fix.md"
## Task: Auth Fix
## Goal: Fix authentication system
INNER

    # Create target task with Related Context placeholder
    f="$d/docs/tasks/open/pilot-inject-test.md"
    cat <<'INNER' > "$f"
## Task: Test Inject
## Status: in-progress
## Goal: Fix the authentication system errors

## Related Context
(Auto-injected by Lauren Loop)

## Current Plan

## Critique

## Plan History

## Execution Log
INNER

    # TASK_FILE intentionally diverges from $f to prove inject_context uses its param
    TASK_FILE="/dev/null"
    inject_context "$f" 2>/dev/null
    grep -q "Closed task: pilot-auth-fix.md" "$f"
) && pass "21. inject_context — injects related context" \
  || fail "21. inject_context — injects related context"

# ============================================================
# Test 22: attempt_log_contains_max_turns — true/false cases
# ============================================================
(
    lf="$TMP_ROOT/max_turns.log"
    printf 'some output\nReached max turns\nmore output\n' > "$lf"
    attempt_log_contains_max_turns "$lf" 1

    lf2="$TMP_ROOT/no_max_turns.log"
    printf 'some output\nall good\n' > "$lf2"
    ! attempt_log_contains_max_turns "$lf2" 1
) && pass "22. attempt_log_contains_max_turns — true/false" \
  || fail "22. attempt_log_contains_max_turns — true/false"

# ============================================================
# Test 23: list_superseded_tasks — finds superseded task files
# ============================================================
(
    d="$TMP_ROOT/supersede_test"
    mkdir -p "$d/docs/tasks/open" "$d/docs/tasks/closed"
    SCRIPT_DIR="$d"

    # Create a task that supersedes another (bare name format — grep loop resolves it)
    primary="$d/docs/tasks/open/pilot-new-task.md"
    cat <<'INNER' > "$primary"
## Task: New Task
## Status: in-progress
## Goal: Replace old approach
Supersedes: old-task
INNER

    # Create the superseded task with pilot- prefix (bare name resolution adds pilot-)
    superseded="$d/docs/tasks/open/pilot-old-task.md"
    printf '## Task: Old Task\n## Status: in-progress\n## Goal: Old approach\n' > "$superseded"

    result=$(list_superseded_tasks "$primary" "$primary")
    echo "$result" | grep -q "pilot-old-task.md"
) && pass "23. list_superseded_tasks — finds superseded tasks" \
  || fail "23. list_superseded_tasks — finds superseded tasks"

# ============================================================
# Test 24: check_diff_scope — passes when no Files to Modify section
# ============================================================
(
    f="$TMP_ROOT/scope_noheader.md"
    write_task_fixture "$f"
    # No "Files to Modify" section — should pass (return 0)
    check_diff_scope "$f" "HEAD~1" 2>/dev/null
) && pass "24. check_diff_scope — passes without Files to Modify" \
  || fail "24. check_diff_scope — passes without Files to Modify"

# ============================================================
# Test 25: ensure_retro_placeholder — creates placeholder entry
# ============================================================
(
    d="$TMP_ROOT/retro_test"
    mkdir -p "$d/docs/tasks"
    SCRIPT_DIR="$d"
    ensure_retro_placeholder "test-task"
    grep -q "Task: test-task" "$d/docs/tasks/RETRO.md"
    grep -q "_retro pending_" "$d/docs/tasks/RETRO.md"

    # Second call with pending placeholder should return 0
    ensure_retro_placeholder "test-task"
    rc=$?
    [ "$rc" -eq 0 ]
) && pass "25. ensure_retro_placeholder — creates and detects placeholder" \
  || fail "25. ensure_retro_placeholder — creates and detects placeholder"

# ============================================================
# Test 26: check_diff_scope — returns 0 with warning output when header has no paths
# ============================================================
(
    d="$TMP_ROOT/scope_warn"
    mkdir -p "$d"
    cd "$d"
    git init -q
    git config user.email "codex@example.com"
    git config user.name "Codex"

    printf 'baseline\n' > a.py
    printf 'baseline\n' > b.py
    printf 'baseline\n' > c.py
    printf 'baseline\n' > d.py
    git add a.py b.py c.py d.py
    git commit -qm "baseline"

    printf 'changed\n' > a.py
    printf 'changed\n' > b.py
    printf 'changed\n' > c.py
    printf 'changed\n' > d.py

    task_file="$d/task.md"
    cat > "$task_file" <<'EOF'
## Task: Scope Warning
## Status: in progress
## Goal: Reproduce check_diff_scope warning

### Files to Modify
TBD
EOF

    output=$(check_diff_scope "$task_file" "HEAD" 2>&1)
    rc=$?
    [ "$rc" -eq 0 ]
    echo "$output" | grep -q "couldn't parse any file paths"
) && pass "26. check_diff_scope — header-without-paths emits warning on zero exit" \
  || fail "26. check_diff_scope — header-without-paths emits warning on zero exit"

# ============================================================
# Test 27: section_bounds — normalized fallback matches heading-level drift
# ============================================================
(
    f="$TMP_ROOT/norm_fallback.md"
    cat > "$f" <<'EOF'
## Task: Norm Fallback
## Status: in-progress
## Goal: Test normalized section_bounds

### Review Findings

Some findings here.

## Execution Log
EOF

    # Exact "## Review Findings" won't match — heading is "### Review Findings"
    # Normalized fallback should strip hashes and match case-insensitively
    result=$(section_bounds "$f" "## Review Findings" 2>"$TMP_ROOT/norm_stderr.txt")
    rc=$?
    [ "$rc" -eq 0 ]
    # Should have emitted WARN on stderr
    grep -q "WARN.*normalized fallback" "$TMP_ROOT/norm_stderr.txt"
    # Returned bounds should be valid (start < end)
    start=$(echo "$result" | awk '{print $1}')
    end=$(echo "$result" | awk '{print $2}')
    [ "$start" -gt 0 ] && [ "$end" -gt "$start" ]
) && pass "27. section_bounds — normalized fallback matches heading-level drift" \
  || fail "27. section_bounds — normalized fallback matches heading-level drift"

# ============================================================
# Test 28: notify_terminal_state — no-op when LAUREN_LOOP_NOTIFY unset
# ============================================================
(
    bin_dir="$TMP_ROOT/notify-unset-bin"
    create_fake_notification_tools "$bin_dir"
    export NOTIFY_LOG="$TMP_ROOT/notify-unset.log"
    export OSASCRIPT_LOG="$TMP_ROOT/osascript-unset.log"
    PATH="$bin_dir:$PATH"
    unset LAUREN_LOOP_NOTIFY
    _NOTIFIED=0

    notify_terminal_state "pass" "unset case"
    wait 2>/dev/null || true

    [ ! -f "$NOTIFY_LOG" ]
    [ ! -f "$OSASCRIPT_LOG" ]
    [ "$_NOTIFIED" = "0" ]
) && pass "28. notify_terminal_state — no-op when LAUREN_LOOP_NOTIFY is unset" \
  || fail "28. notify_terminal_state — no-op when LAUREN_LOOP_NOTIFY is unset"

# ============================================================
# Test 29: notify_terminal_state — no-op when LAUREN_LOOP_NOTIFY=0
# ============================================================
(
    bin_dir="$TMP_ROOT/notify-zero-bin"
    create_fake_notification_tools "$bin_dir"
    export NOTIFY_LOG="$TMP_ROOT/notify-zero.log"
    export OSASCRIPT_LOG="$TMP_ROOT/osascript-zero.log"
    PATH="$bin_dir:$PATH"
    LAUREN_LOOP_NOTIFY=0
    _NOTIFIED=0

    notify_terminal_state "pass" "zero case"
    wait 2>/dev/null || true

    [ ! -f "$NOTIFY_LOG" ]
    [ ! -f "$OSASCRIPT_LOG" ]
    [ "$_NOTIFIED" = "0" ]
) && pass "29. notify_terminal_state — no-op when LAUREN_LOOP_NOTIFY=0" \
  || fail "29. notify_terminal_state — no-op when LAUREN_LOOP_NOTIFY=0"

# ============================================================
# Test 30: notify_terminal_state — one-shot guard prevents double fire
# ============================================================
(
    bin_dir="$TMP_ROOT/notify-once-bin"
    create_fake_notification_tools "$bin_dir"
    export NOTIFY_LOG="$TMP_ROOT/notify-once.log"
    export OSASCRIPT_LOG="$TMP_ROOT/osascript-once.log"
    PATH="$bin_dir:$PATH"
    LAUREN_LOOP_NOTIFY=1
    _NOTIFIED=0

    notify_terminal_state "pass" "first notification"
    wait_for_lines "$NOTIFY_LOG" 1
    wait_for_lines "$OSASCRIPT_LOG" 1

    notify_terminal_state "blocked" "second notification"
    wait 2>/dev/null || true

    [ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" = "1" ]
    [ "$(wc -l < "$OSASCRIPT_LOG" | tr -d ' ')" = "1" ]
    grep -q 'Glass.aiff' "$NOTIFY_LOG"
    grep -q 'first notification' "$OSASCRIPT_LOG"
    [ "$_NOTIFIED" = "1" ]
) && pass "30. notify_terminal_state — one-shot guard prevents double fire" \
  || fail "30. notify_terminal_state — one-shot guard prevents double fire"

# ============================================================
# Test 31: notify_terminal_state — all four categories accepted
# ============================================================
(
    bin_dir="$TMP_ROOT/notify-categories-bin"
    create_fake_notification_tools "$bin_dir"
    PATH="$bin_dir:$PATH"
    LAUREN_LOOP_NOTIFY=1

    categories=(pass human-review blocked interrupted)
    sounds=(Glass Purr Basso Basso)

    for i in "${!categories[@]}"; do
        export NOTIFY_LOG="$TMP_ROOT/notify-${categories[$i]}.log"
        export OSASCRIPT_LOG="$TMP_ROOT/osascript-${categories[$i]}.log"
        rm -f "$NOTIFY_LOG" "$OSASCRIPT_LOG"
        _NOTIFIED=0

        notify_terminal_state "${categories[$i]}" "category ${categories[$i]}"
        wait_for_lines "$NOTIFY_LOG" 1
        wait_for_lines "$OSASCRIPT_LOG" 1

        grep -q "${sounds[$i]}.aiff" "$NOTIFY_LOG"
        grep -q "category ${categories[$i]}" "$OSASCRIPT_LOG"
        grep -q "osascript:-e on run argv" "$OSASCRIPT_LOG"
    done
) && pass "31. notify_terminal_state — all four categories accepted" \
  || fail "31. notify_terminal_state — all four categories accepted"

# ============================================================
# Test 32: notify_terminal_state — invalid category returns 1 without firing
# ============================================================
(
    bin_dir="$TMP_ROOT/notify-invalid-bin"
    create_fake_notification_tools "$bin_dir"
    export NOTIFY_LOG="$TMP_ROOT/notify-invalid.log"
    export OSASCRIPT_LOG="$TMP_ROOT/osascript-invalid.log"
    PATH="$bin_dir:$PATH"
    LAUREN_LOOP_NOTIFY=1
    _NOTIFIED=0

    set +e
    notify_terminal_state "bad-category" "should fail"
    rc=$?
    set -e

    [ "$rc" -eq 1 ]
    wait 2>/dev/null || true
    [ ! -f "$NOTIFY_LOG" ]
    [ ! -f "$OSASCRIPT_LOG" ]
    [ "$_NOTIFIED" = "0" ]
) && pass "32. notify_terminal_state — invalid category returns 1 without firing" \
  || fail "32. notify_terminal_state — invalid category returns 1 without firing"

# ============================================================
# Test 33: _parse_contract — unknown verdict token is rejected
# ============================================================
(
    fixture="$TMP_ROOT/unknown-verdict.md"
    printf 'VERDICT: MAYBE\n' > "$fixture"
    [[ -z "$(_parse_contract "$fixture" "verdict")" ]]
) && pass "33. _parse_contract — unknown verdict token is rejected" \
  || fail "33. _parse_contract — unknown verdict token is rejected"

# ============================================================
# Test 34: extract_last_review_verdict — returns CONDITIONAL
# ============================================================
(
    f="$TMP_ROOT/review-conditional.md"
    write_review_fixture "$f"
    perl -0pi -e 's/REVIEW VERDICT: FAIL/REVIEW VERDICT: CONDITIONAL/' "$f"
    verdict=$(extract_last_review_verdict "$f")
    [ "$verdict" = "CONDITIONAL" ]
) && pass "34. extract_last_review_verdict — returns CONDITIONAL" \
  || fail "34. extract_last_review_verdict — returns CONDITIONAL"

# ============================================================
# Test 35: _critic_verdict_is_consistent — EXECUTE rejected with 2 concerns
# ============================================================
(
    critique="$TMP_ROOT/critique-concerns.md"
    cat > "$critique" <<'EOF'
## Critique

### Fresh-Eyes Assessment

**1. Goal Coverage:** CONCERN - one
**2. Constraint Compliance:** CONCERN - two
**3. Dependency Coverage:** PASS - ok

## Verdict

VERDICT: EXECUTE
EOF
    ! _critic_verdict_is_consistent "$critique" "EXECUTE"
) && pass "35. _critic_verdict_is_consistent — EXECUTE rejected with 2 concerns" \
  || fail "35. _critic_verdict_is_consistent — EXECUTE rejected with 2 concerns"

# ============================================================
# Test 36: _chaos_count_findings — case-insensitive counts
# ============================================================
(
    artifact="$TMP_ROOT/chaos-findings.md"
    cat > "$artifact" <<'EOF'
**blocking:** one
**CONCERN:** two
**Note:** three
EOF
    [ "$(_chaos_count_findings "$artifact" "BLOCKING")" = "1" ]
    [ "$(_chaos_count_findings "$artifact" "CONCERN")" = "1" ]
    [ "$(_chaos_count_findings "$artifact" "NOTE")" = "1" ]
) && pass "36. _chaos_count_findings — case-insensitive counts" \
  || fail "36. _chaos_count_findings — case-insensitive counts"

# ============================================================
# Test 37: _plancheck_validate_xml — current wave/task contract passes
# ============================================================
(
    xml=$'<wave number="1">\n  <task type="auto">\n    <name>Do work</name>\n    <files>lauren-loop.sh</files>\n    <action>Implement change</action>\n    <verify>bash -n lauren-loop.sh</verify>\n    <done>Change is complete</done>\n  </task>\n</wave>'
    _plancheck_is_xml "$xml"
    _plancheck_is_current_xml "$xml"
    _plancheck_validate_xml "$xml" >/dev/null
) && pass "37. _plancheck_validate_xml — current wave/task contract passes" \
  || fail "37. _plancheck_validate_xml — current wave/task contract passes"

# ============================================================
# Test 38: _plancheck_validate_xml — missing done and invalid type fail
# ============================================================
(
    xml=$'<wave number="1">\n  <task type="manual">\n    <name>Do work</name>\n    <files>lauren-loop.sh</files>\n    <action>Implement change</action>\n    <verify>bash -n lauren-loop.sh</verify>\n  </task>\n</wave>'
    _plancheck_is_xml "$xml"
    _plancheck_is_current_xml "$xml"
    ! _plancheck_validate_xml "$xml" >/dev/null 2>&1
) && pass "38. _plancheck_validate_xml — missing done and invalid type fail" \
  || fail "38. _plancheck_validate_xml — missing done and invalid type fail"

# ============================================================
# Test 39: set_task_status — extended live statuses accepted
# ============================================================
(
    f="$TMP_ROOT/status-allowlist.md"
    write_task_fixture "$f"
    set_task_status "$f" "plan-approved"
    grep -q '^## Status: plan-approved$' "$f"
    set_task_status "$f" "closed"
    grep -q '^## Status: closed$' "$f"
    ! set_task_status "$f" "definitely-invalid" 2>/dev/null
) && pass "39. set_task_status — extended live statuses accepted" \
  || fail "39. set_task_status — extended live statuses accepted"

# ============================================================
# Test 40: move_task_to_closed — directory-backed task moves whole directory
# ============================================================
(
    d="$TMP_ROOT/close-dir"
    SCRIPT_DIR="$d"
    mkdir -p "$d/docs/tasks/open/example-dir" "$d/docs/tasks/closed"
    write_review_fixture "$d/docs/tasks/open/example-dir/task.md"
    _sed_i 's/^## Status: .*/## Status: review-passed/' "$d/docs/tasks/open/example-dir/task.md"
    result=$(move_task_to_closed "$d/docs/tasks/open/example-dir/task.md" "closed" "Task closed")
    [ "$result" = "$d/docs/tasks/closed/example-dir" ]
    [ -f "$d/docs/tasks/closed/example-dir/task.md" ]
    [ ! -e "$d/docs/tasks/open/example-dir" ]
    grep -q '^## Status: closed$' "$d/docs/tasks/closed/example-dir/task.md"
) && pass "40. move_task_to_closed — directory-backed task moves whole directory" \
  || fail "40. move_task_to_closed — directory-backed task moves whole directory"

# ============================================================
# Test 41: start_agent_monitor — surfaces DISPUTED lines
# ============================================================
(
    task="$TMP_ROOT/monitor-task.md"
    log="$TMP_ROOT/monitor.log"
    out="$TMP_ROOT/monitor.out"
    write_task_fixture "$task"
    : > "$log"

    (
        exec > "$out"
        start_agent_monitor "$log" "$task"
        sleep 0.2
        printf 'DISPUTED: needs human review\n' >> "$log"
        for _ in $(seq 1 100); do
            if grep -q 'DISPUTED: needs human review' "$out" 2>/dev/null; then
                break
            fi
            sleep 0.05
        done
        stop_agent_monitor
    )

    grep -q 'DISPUTED: needs human review' "$out"
) && pass "41. start_agent_monitor — surfaces DISPUTED lines" \
  || fail "41. start_agent_monitor — surfaces DISPUTED lines"

# ============================================================
# Test 42: _validate_agent_output_for_role — summary-only reviewer stub is rejected
# ============================================================
(
    artifact="$TMP_ROOT/reviewer-summary-only.md"
    cat > "$artifact" <<'EOF'
**Files modified:** competitive/review-b.md
**Tests:** 0 passed, 0 failed (review only - no tests run)
**What's left:** Ready for review synthesis
**Task file updated:** none
EOF
    _validate_agent_output "$artifact"
    ! _validate_agent_output_for_role "reviewer-b" "$artifact" >/dev/null 2>&1
) && pass "42. _validate_agent_output_for_role — summary-only reviewer stub is rejected" \
  || fail "42. _validate_agent_output_for_role — summary-only reviewer stub is rejected"

# ============================================================
# Test 43: _validate_agent_output_for_role — valid reviewer-b artifact passes
# ============================================================
(
    artifact="$TMP_ROOT/reviewer-valid.md"
    write_valid_reviewer_b_artifact "$artifact" "PASS" "No findings."
    _validate_agent_output_for_role "reviewer-b" "$artifact"
) && pass "43. _validate_agent_output_for_role — valid reviewer-b artifact passes" \
  || fail "43. _validate_agent_output_for_role — valid reviewer-b artifact passes"

# ============================================================
# Test 43b: reviewer-b validation derives dimension count from the prompt contract
# ============================================================
(
    temp_root="$TMP_ROOT/reviewer-dimension-contract"
    mkdir -p "$temp_root/prompts"
    awk '
        /^## Verdict$/ && !inserted {
            print "**9. Rollout Safety:** <checked result>"
            print ""
            inserted=1
        }
        { print }
    ' "$REPO_ROOT/prompts/reviewer-b.md" > "$temp_root/prompts/reviewer-b.md"
    SCRIPT_DIR="$temp_root"

    artifact="$TMP_ROOT/reviewer-missing-9th-dimension.md"
    write_valid_reviewer_b_artifact "$artifact" "PASS" "No findings."
    ! _validate_agent_output_for_role "reviewer-b" "$artifact" >/dev/null 2>&1

    fixed_artifact="$TMP_ROOT/reviewer-with-9th-dimension.md"
    awk '
        /^## Verdict$/ && !inserted {
            print "**9. Rollout Safety:** checked"
            print ""
            inserted=1
        }
        { print }
    ' "$artifact" > "$fixed_artifact"
    _validate_agent_output_for_role "reviewer-b" "$fixed_artifact"
) && pass "43b. reviewer-b validation derives dimension count from the prompt contract" \
  || fail "43b. reviewer-b validation derives dimension count from the prompt contract"

# ============================================================
# Test 44: _validate_agent_output_for_role — valid planner-b artifact passes
# ============================================================
(
    artifact="$TMP_ROOT/planner-valid.md"
    write_valid_plan_artifact "$artifact" "Plan B"
    _validate_agent_output_for_role "planner-b" "$artifact"
) && pass "44. _validate_agent_output_for_role — valid planner-b artifact passes" \
  || fail "44. _validate_agent_output_for_role — valid planner-b artifact passes"

# ============================================================
# Test 44b: planner validation rejects truncated XML task blocks
# ============================================================
(
    artifact="$TMP_ROOT/planner-truncated.md"
    cat > "$artifact" <<'EOF'
# Plan B

## Files to Modify
- `lauren-loop-v2.sh` — preserve planner artifacts

## Implementation Tasks

```xml
<wave number="1">
  <task type="auto">
    <name>Truncated plan</name>
    <files>lauren-loop-v2.sh</files>
    <action>Describe a partial change.</action>
    <verify>bash test_lauren_loop_utils.sh</verify>
    <done>Not complete yet.</done>
```

## Testability Design
- Exercise the planner validator.

## Test Strategy
- Expect the validator to reject the missing closing tags.

## Risk Assessment
- A truncated artifact must not count as complete.

## Dependencies
- None.
EOF
    ! _validate_agent_output_for_role "planner-b" "$artifact" >/dev/null 2>&1
) && pass "44b. planner validation rejects truncated XML task blocks" \
  || fail "44b. planner validation rejects truncated XML task blocks"

# ============================================================
# Test 45: _watch_codex_artifact_for_static_invalid — kills static invalid artifact
# ============================================================
(
    _agent_poll_interval_seconds() { echo 0.05; }
    _agent_terminate_grace_seconds() { echo 0; }

    artifact="$TMP_ROOT/static-invalid-planner.md"
    marker="$TMP_ROOT/static-invalid-planner.marker"
    log_file="$TMP_ROOT/static-invalid-planner.log"
    printf 'ARTIFACT_WRITTEN\n' > "$artifact"

    /bin/bash -c 'sleep 30' &
    cmd_pid=$!

    set +e
    _watch_codex_artifact_for_static_invalid "planner-b" "$artifact" "$cmd_pid" "$marker" "$log_file" &
    watcher_pid=$!
    wait "$watcher_pid"
    watcher_rc=$?
    wait "$cmd_pid" 2>/dev/null
    set -e

    [[ "$watcher_rc" -ne 0 ]]
    [[ -f "$marker" ]]
    ! kill -0 "$cmd_pid" 2>/dev/null
    grep -q 'static_invalid_artifact' "$log_file"
) && pass "45. _watch_codex_artifact_for_static_invalid — kills static invalid artifact" \
  || fail "45. _watch_codex_artifact_for_static_invalid — kills static invalid artifact"

# ============================================================
# Test 46: _watch_codex_artifact_for_static_invalid — growing incomplete artifact survives
# ============================================================
(
    _agent_poll_interval_seconds() { echo 0.1; }
    _agent_terminate_grace_seconds() { echo 0; }

    artifact="$TMP_ROOT/growing-reviewer.md"
    marker="$TMP_ROOT/growing-reviewer.marker"
    log_file="$TMP_ROOT/growing-reviewer.log"

    /bin/bash -c '
        artifact="$1"
        printf "# Review B\n\n## Findings\n\nNo findings.\n" > "$artifact"
        sleep 0.05
        printf "\n## Done-Criteria Check\n\nNot applicable.\n" >> "$artifact"
        sleep 0.05
        printf "\n## Dimension Coverage\n\n**1. Architecture / Structural Integrity:** checked\n**2. Correctness:** checked\n**3. Test Quality:** checked\n**4. Edge Cases:** checked\n**5. Error Handling:** checked\n**6. Security:** checked\n**7. Performance:** checked\n**8. Caller Impact:** checked\n" >> "$artifact"
        sleep 0.05
        printf "\n## Verdict\n\n**VERDICT: PASS**\n**Blocking findings:** None\n**Rationale:** test artifact\n" >> "$artifact"
        sleep 0.1
    ' bash "$artifact" &
    cmd_pid=$!

    set +e
    _watch_codex_artifact_for_static_invalid "reviewer-b" "$artifact" "$cmd_pid" "$marker" "$log_file" &
    watcher_pid=$!
    wait "$watcher_pid"
    watcher_rc=$?
    wait "$cmd_pid"
    cmd_rc=$?
    set -e

    [[ "$watcher_rc" -eq 0 ]]
    [[ "$cmd_rc" -eq 0 ]]
    [[ ! -f "$marker" ]]
    _validate_agent_output_for_role "reviewer-b" "$artifact"
) && pass "46. _watch_codex_artifact_for_static_invalid — growing incomplete artifact survives" \
  || fail "46. _watch_codex_artifact_for_static_invalid — growing incomplete artifact survives"

# ============================================================
# Test 47: _terminate_pid_tree — TERM-ignoring child gets KILLed after grace
# ============================================================
(
    _agent_terminate_grace_seconds() { echo 1; }

    # Spawn a process that traps and ignores TERM
    bash -c 'trap "" TERM; sleep 30' &
    target_pid=$!
    sleep 0.2

    # Verify it's alive
    kill -0 "$target_pid" 2>/dev/null || { echo "target process not alive before terminate" >&2; exit 1; }

    _terminate_pid_tree "$target_pid" 1

    # Brief settle — kill -9 is async; real callers always follow with wait $pid
    sleep 0.2

    # Process should be dead after KILL
    ! kill -0 "$target_pid" 2>/dev/null || { echo "TERM-ignoring process survived _terminate_pid_tree" >&2; exit 1; }
) && pass "47. _terminate_pid_tree — TERM-ignoring child gets KILLed after grace" \
  || fail "47. _terminate_pid_tree — TERM-ignoring child gets KILLed after grace"

# ============================================================
# Test 48: reviewer-b prompt is path-agnostic
# ============================================================
(
    ! rg -n 'competitive/review-b\.md' "$REPO_ROOT/prompts/reviewer-b.md" >/dev/null 2>&1
) && pass "48. reviewer-b prompt is path-agnostic" \
  || fail "48. reviewer-b prompt is path-agnostic"

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

#!/usr/bin/env bash
# test_autofix.sh — Focused tests for Phase 3.5c Nightshift autofix.
#
# Usage: bash scripts/nightshift/tests/test_autofix.sh

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${TEST_DIR}/.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

echo "=== test_autofix.sh ==="
echo ""

source "${NS_DIR}/nightshift.conf"
source "${NS_DIR}/nightshift.sh"
source "${NS_DIR}/lib/lauren-bridge.sh"
source "${TEST_DIR}/autofix_test_lib.sh"

# ── Test 1: disabled gate skips phase ────────────────────────────────────────
(
    setup_autofix_fixture "disabled"
    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    write_autofix_task "${task_path}" "critical" "System fixes alpha."
    VALIDATED_TASKS=("${task_path}")
    NIGHTSHIFT_AUTOFIX_ENABLED="false"

    log_path="${TMP_DIR}/autofix-disabled.log"
    phase_autofix > "${log_path}" 2>&1

    grep -q "Autofix disabled: skipping phase" "${log_path}"
    grep -q "===== Phase 3.5c: Autofix SKIPPED =====" "${log_path}"
) && pass "1. disabled gate skips autofix cleanly" \
  || fail "1. disabled gate skips autofix cleanly" "disabled phase did not log the documented skip"

# ── Test 2: empty validated tasks skips cleanly ──────────────────────────────
(
    setup_autofix_fixture "empty"

    log_path="${TMP_DIR}/autofix-empty.log"
    phase_autofix > "${log_path}" 2>&1

    grep -q "Autofix: 0 validated tasks" "${log_path}"
    grep -q "===== Phase 3.5c: Autofix SKIPPED =====" "${log_path}"
) && pass "2. empty validated task list skips cleanly" \
  || fail "2. empty validated task list skips cleanly" "empty validated tasks did not short-circuit"

# ── Test 3: budget insufficient skips phase ──────────────────────────────────
(
    setup_autofix_fixture "budget"
    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    write_autofix_task "${task_path}" "critical" "System fixes alpha."
    VALIDATED_TASKS=("${task_path}")
    cost_total_value() { echo "95.0000"; }

    log_path="${TMP_DIR}/autofix-budget.log"
    phase_autofix > "${log_path}" 2>&1

    grep -q 'Autofix: insufficient budget remaining (\$5.0000 of \$20 needed)' "${log_path}"
    grep -q "===== Phase 3.5c: Autofix SKIPPED =====" "${log_path}"
) && pass "3. insufficient remaining budget skips autofix" \
  || fail "3. insufficient remaining budget skips autofix" "budget guard did not fire"

# ── Test 4: severity filter only previews critical and major tasks ───────────
(
    setup_autofix_fixture "severity"
    DRY_RUN=1
    critical_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    major_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    minor_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-gamma.md"
    write_autofix_task "${critical_task}" "critical" "System fixes alpha."
    write_autofix_task "${major_task}" "major" "System fixes beta."
    write_autofix_task "${minor_task}" "minor" "System fixes gamma."
    VALIDATED_TASKS=("${critical_task}" "${major_task}" "${minor_task}")

    log_path="${TMP_DIR}/autofix-severity.log"
    phase_autofix > "${log_path}" 2>&1

    grep -q 'DRY RUN: would attempt fix on alpha (severity: critical' "${log_path}"
    grep -q 'DRY RUN: would attempt fix on beta (severity: major' "${log_path}"
    ! grep -q 'DRY RUN: would attempt fix on gamma' "${log_path}"
) && pass "4. severity filter includes only configured severities" \
  || fail "4. severity filter includes only configured severities" "minor task was not filtered out"

# ── Test 5: ordering runs critical before major, preserving manifest order ───
(
    setup_autofix_fixture "ordering"
    DRY_RUN=1
    major_one="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-major-one.md"
    critical_one="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-critical-one.md"
    major_two="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-major-two.md"
    critical_two="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-critical-two.md"
    write_autofix_task "${major_one}" "major" "System fixes major one."
    write_autofix_task "${critical_one}" "critical" "System fixes critical one."
    write_autofix_task "${major_two}" "major" "System fixes major two."
    write_autofix_task "${critical_two}" "critical" "System fixes critical two."
    VALIDATED_TASKS=("${major_one}" "${critical_one}" "${major_two}" "${critical_two}")

    log_path="${TMP_DIR}/autofix-ordering.log"
    phase_autofix > "${log_path}" 2>&1

    critical_one_line="$(grep -n 'critical-one' "${log_path}" | head -n 1 | cut -d: -f1)"
    critical_two_line="$(grep -n 'critical-two' "${log_path}" | head -n 1 | cut -d: -f1)"
    major_one_line="$(grep -n 'major-one' "${log_path}" | head -n 1 | cut -d: -f1)"
    major_two_line="$(grep -n 'major-two' "${log_path}" | head -n 1 | cut -d: -f1)"

    [[ "${critical_one_line}" -lt "${critical_two_line}" ]]
    [[ "${critical_two_line}" -lt "${major_one_line}" ]]
    [[ "${major_one_line}" -lt "${major_two_line}" ]]
) && pass "5. autofix ordering is critical-first and stable within severity" \
  || fail "5. autofix ordering is critical-first and stable within severity" "preview order was wrong"

# ── Test 6: successful fix marks applied and stages merged paths ─────────────
(
    setup_autofix_fixture "success"
    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    write_autofix_task "${task_path}" "critical" "System fixes alpha."
    VALIDATED_TASKS=("${task_path}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/success-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/success-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|0|success|5.5000'

    GIT_ADD_LOG="${TMP_DIR}/success-git-add.log"
    AUTOFIX_GIT_STASH_OUTPUT_1=''
    AUTOFIX_GIT_STASH_OUTPUT_2='after-alpha'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    AUTOFIX_GIT_DIFF_OUTPUT_1='src/fixed-alpha.py\n'
    setup_autofix_git_mock

    log_path="${TMP_DIR}/autofix-success.log"
    phase_autofix > "${log_path}" 2>&1

    grep -q 'Fixed: alpha' "${log_path}"
    grep -q '^## Autofix: applied$' "${task_path}"
    grep -q 'Lauren Loop exit code: 0' "${task_path}"
    grep -q 'Cost: \$5.5000' "${task_path}"
    grep -q '^alpha|System fixes alpha\.|--strict|80\.00$' "${AUTOFIX_STUB_LOG}"
    grep -q 'src/fixed-alpha.py' "${GIT_ADD_LOG}"
    ! grep -q "${task_path}" "${GIT_ADD_LOG}"
) && pass "6. successful fix marks applied and stages merged paths" \
  || fail "6. successful fix marks applied and stages merged paths" "success contract, metadata, or staging was wrong"

# ── Test 7: failed fix appends failure and loop continues ────────────────────
(
    setup_autofix_fixture "failure"
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    write_autofix_task "${alpha_task}" "critical" "System fixes alpha."
    write_autofix_task "${beta_task}" "major" "System fixes beta."
    VALIDATED_TASKS=("${alpha_task}" "${beta_task}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/failure-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/failure-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|9||0.0000' \
        'beta|0|success|7.0000'

    GIT_ADD_LOG="${TMP_DIR}/failure-git-add.log"
    AUTOFIX_GIT_STASH_OUTPUT_1=''
    AUTOFIX_GIT_STASH_OUTPUT_2=''
    AUTOFIX_GIT_STASH_OUTPUT_3=''
    AUTOFIX_GIT_STASH_OUTPUT_4='after-beta'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_3=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_4=''
    AUTOFIX_GIT_DIFF_OUTPUT_1='src/fixed-beta.py\n'
    setup_autofix_git_mock

    log_path="${TMP_DIR}/autofix-failure.log"
    phase_autofix > "${log_path}" 2>&1

    [[ "$(wc -l < "${AUTOFIX_STUB_LOG}")" -eq 2 ]]
    grep -q 'Fix failed: alpha' "${log_path}"
    grep -q 'Fixed: beta' "${log_path}"
    grep -q '^## Autofix: failed$' "${alpha_task}"
    grep -q '^## Autofix: applied$' "${beta_task}"
) && pass "7. failed fix appends metadata and the loop continues" \
  || fail "7. failed fix appends metadata and the loop continues" "loop stopped early or task metadata was wrong"

# ── Test 8: blocked fix stops immediately after partial merge ────────────────
(
    setup_autofix_fixture "blocked"
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    write_autofix_task "${alpha_task}" "critical" "System fixes alpha."
    write_autofix_task "${beta_task}" "major" "System fixes beta."
    VALIDATED_TASKS=("${alpha_task}" "${beta_task}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/blocked-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/blocked-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|0|human_review|4.0000' \
        'beta|0|success|6.0000'

    GIT_ADD_LOG="${TMP_DIR}/blocked-git-add.log"
    AUTOFIX_GIT_STASH_OUTPUT_1=''
    AUTOFIX_GIT_STASH_OUTPUT_2='after-alpha'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    AUTOFIX_GIT_DIFF_OUTPUT_1='src/blocked-alpha.py\n'
    setup_autofix_git_mock

    log_path="${TMP_DIR}/autofix-blocked.log"
    phase_autofix > "${log_path}" 2>&1

    [[ "$(wc -l < "${AUTOFIX_STUB_LOG}")" -eq 1 ]]
    grep -q 'Fix blocked with partial merge: alpha' "${log_path}"
    grep -q 'Stopping autofix: BLOCKED result may affect remaining tasks' "${log_path}"
    grep -q '^## Autofix: blocked$' "${alpha_task}"
    ! grep -q '^## Autofix:' "${beta_task}"
) && pass "8. blocked fix stops the loop immediately" \
  || fail "8. blocked fix stops the loop immediately" "blocked handling did not halt remaining tasks"

# ── Test 9: max-task cap limits attempts to configured count ─────────────────
(
    setup_autofix_fixture "max-tasks"
    DRY_RUN=1
    NIGHTSHIFT_AUTOFIX_MAX_TASKS="3"

    VALIDATED_TASKS=()
    for index in $(seq 1 15); do
        task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-task-${index}.md"
        write_autofix_task "${task_path}" "critical" "System fixes task ${index}."
        VALIDATED_TASKS+=("${task_path}")
    done

    log_path="${TMP_DIR}/autofix-max-tasks.log"
    phase_autofix > "${log_path}" 2>&1

    [[ "$(grep -c 'DRY RUN: would attempt fix on task-' "${log_path}")" -eq 3 ]]
) && pass "9. max-task cap limits autofix attempts" \
  || fail "9. max-task cap limits autofix attempts" "too many tasks were previewed"

# ── Test 10: budget guard stops mid-loop after spend drops below minimum ─────
(
    setup_autofix_fixture "mid-budget"
    NIGHTSHIFT_COST_CAP_USD="50"
    NIGHTSHIFT_AUTOFIX_MIN_BUDGET="20"
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    gamma_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-gamma.md"
    write_autofix_task "${alpha_task}" "critical" "System fixes alpha."
    write_autofix_task "${beta_task}" "critical" "System fixes beta."
    write_autofix_task "${gamma_task}" "major" "System fixes gamma."
    VALIDATED_TASKS=("${alpha_task}" "${beta_task}" "${gamma_task}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/mid-budget-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/mid-budget-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|0|success|5.0000' \
        'beta|0|success|30.0000' \
        'gamma|0|success|1.0000'

    GIT_ADD_LOG="${TMP_DIR}/mid-budget-git-add.log"
    AUTOFIX_GIT_STASH_OUTPUT_1=''
    AUTOFIX_GIT_STASH_OUTPUT_2='after-alpha'
    AUTOFIX_GIT_STASH_OUTPUT_3=''
    AUTOFIX_GIT_STASH_OUTPUT_4='after-beta'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_3=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_4=''
    AUTOFIX_GIT_DIFF_OUTPUT_1='src/fixed-alpha.py\n'
    AUTOFIX_GIT_DIFF_OUTPUT_2='src/fixed-beta.py\n'
    setup_autofix_git_mock

    log_path="${TMP_DIR}/autofix-mid-budget.log"
    phase_autofix > "${log_path}" 2>&1

    [[ "$(wc -l < "${AUTOFIX_STUB_LOG}")" -eq 2 ]]
    grep -q 'Autofix: insufficient budget remaining (\$15.0000 of \$20 needed)' "${log_path}"
    ! grep -q '^## Autofix:' "${gamma_task}"
) && pass "10. budget guard stops remaining autofixes mid-loop" \
  || fail "10. budget guard stops remaining autofixes mid-loop" "budget stop did not preserve the remaining tasks"

# ── Test 11: dry-run never calls Lauren and shows budget math ────────────────
(
    setup_autofix_fixture "dry-run"
    DRY_RUN=1
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    write_autofix_task "${alpha_task}" "critical" "System fixes alpha."
    write_autofix_task "${beta_task}" "major" "System fixes beta."
    VALIDATED_TASKS=("${alpha_task}" "${beta_task}")

    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<'EOF'
#!/usr/bin/env bash
echo "unexpected call" >> "${TMP_DIR}/autofix-dry-run-called.log"
exit 1
EOF
    chmod +x "${REPO_ROOT}/lauren-loop-v2.sh"

    log_path="${TMP_DIR}/autofix-dry-run.log"
    phase_autofix > "${log_path}" 2>&1

    [[ ! -f "${TMP_DIR}/autofix-dry-run-called.log" ]]
    grep -q 'DRY RUN: would attempt fix on alpha (severity: critical' "${log_path}"
    grep -q 'DRY RUN: would attempt fix on beta (severity: major' "${log_path}"
    grep -q 'remaining: \$100.0000' "${log_path}"
    grep -q 'max cost: \$40.00' "${log_path}"
    grep -q 'max cost: \$80.00' "${log_path}"
) && pass "11. dry-run previews order and budget math without invoking Lauren" \
  || fail "11. dry-run previews order and budget math without invoking Lauren" "dry-run called Lauren or missed the budget math"

# ── Test 12: exit-0 missing manifest hard-stops the autofix loop ─────────────
(
    setup_autofix_fixture "missing-manifest"
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    write_autofix_task "${alpha_task}" "critical" "System fixes alpha."
    write_autofix_task "${beta_task}" "major" "System fixes beta."
    VALIDATED_TASKS=("${alpha_task}" "${beta_task}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/missing-manifest-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/missing-manifest-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|0|success|5.0000|missing' \
        'beta|0|success|2.0000'

    AUTOFIX_GIT_STASH_OUTPUT_1=''
    AUTOFIX_GIT_STASH_OUTPUT_2='after-alpha'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    setup_autofix_git_mock

    log_path="${TMP_DIR}/missing-manifest.log"
    phase_autofix > "${log_path}" 2>&1

    [[ "$(wc -l < "${AUTOFIX_STUB_LOG}")" -eq 1 ]]
    grep -q 'Lauren exit 0 but manifest invalid — treating as hard failure' "${log_path}"
    grep -q 'Stopping autofix: manifest contract broken for alpha' "${log_path}"
    grep -q '^## Autofix: failed$' "${alpha_task}"
    grep -q 'Cost: unknown' "${alpha_task}"
    ! grep -q '^## Autofix:' "${beta_task}"
) && pass "12. missing manifest after exit 0 hard-stops autofix" \
  || fail "12. missing manifest after exit 0 hard-stops autofix" "missing manifest did not fail hard"

# ── Test 13: corrupt manifest JSON hard-stops the autofix loop ───────────────
(
    setup_autofix_fixture "corrupt-manifest"
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    write_autofix_task "${alpha_task}" "critical" "System fixes alpha."
    write_autofix_task "${beta_task}" "major" "System fixes beta."
    VALIDATED_TASKS=("${alpha_task}" "${beta_task}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/corrupt-manifest-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/corrupt-manifest-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|0|success|5.0000|corrupt' \
        'beta|0|success|2.0000'

    AUTOFIX_GIT_STASH_OUTPUT_1=''
    AUTOFIX_GIT_STASH_OUTPUT_2='after-alpha'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    setup_autofix_git_mock

    log_path="${TMP_DIR}/corrupt-manifest.log"
    phase_autofix > "${log_path}" 2>&1

    [[ "$(wc -l < "${AUTOFIX_STUB_LOG}")" -eq 1 ]]
    grep -q 'Lauren exit 0 but manifest invalid — treating as hard failure' "${log_path}"
    grep -q '^## Autofix: failed$' "${alpha_task}"
    grep -q 'Cost: unknown' "${alpha_task}"
    ! grep -q '^## Autofix:' "${beta_task}"
) && pass "13. corrupt manifest JSON hard-stops autofix" \
  || fail "13. corrupt manifest JSON hard-stops autofix" "corrupt manifest did not fail hard"

# ── Test 14: pre-dirty tracked files still stage via snapshot diff ───────────
(
    setup_autofix_fixture "pre-dirty"
    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    write_autofix_task "${task_path}" "critical" "System fixes alpha."
    VALIDATED_TASKS=("${task_path}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/pre-dirty-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/pre-dirty-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|0|success|3.2500'

    GIT_ADD_LOG="${TMP_DIR}/pre-dirty-git-add.log"
    AUTOFIX_GIT_STASH_OUTPUT_1='before-dirty'
    AUTOFIX_GIT_STASH_OUTPUT_2='after-dirty'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    AUTOFIX_GIT_DIFF_OUTPUT_1='src/pre-dirty.py\n'
    setup_autofix_git_mock

    log_path="${TMP_DIR}/pre-dirty.log"
    phase_autofix > "${log_path}" 2>&1

    grep -q '^## Autofix: applied$' "${task_path}"
    grep -q 'src/pre-dirty.py' "${GIT_ADD_LOG}"
) && pass "14. pre-dirty tracked files stage from snapshot diffs" \
  || fail "14. pre-dirty tracked files stage from snapshot diffs" "snapshot diff missed a pre-dirty tracked file"

# ── Test 15: git add failure marks failed and hard-stops autofix ─────────────
(
    setup_autofix_fixture "git-add-failure"
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta.md"
    write_autofix_task "${alpha_task}" "critical" "System fixes alpha."
    write_autofix_task "${beta_task}" "major" "System fixes beta."
    VALIDATED_TASKS=("${alpha_task}" "${beta_task}")
    write_autofix_stub
    export AUTOFIX_STUB_LOG="${TMP_DIR}/git-add-failure-stub.log"
    export AUTOFIX_STUB_BEHAVIOR_FILE="${TMP_DIR}/git-add-failure-behavior.txt"
    write_behavior_file "${AUTOFIX_STUB_BEHAVIOR_FILE}" \
        'alpha|0|success|6.0000' \
        'beta|0|success|2.0000'

    GIT_ADD_LOG="${TMP_DIR}/git-add-failure.log"
    AUTOFIX_GIT_STASH_OUTPUT_1=''
    AUTOFIX_GIT_STASH_OUTPUT_2='after-alpha'
    AUTOFIX_GIT_UNTRACKED_OUTPUT_1=''
    AUTOFIX_GIT_UNTRACKED_OUTPUT_2=''
    AUTOFIX_GIT_DIFF_OUTPUT_1='src/fixed-alpha.py\n'
    AUTOFIX_GIT_ADD_EXIT_1=1
    setup_autofix_git_mock

    log_path="${TMP_DIR}/git-add-failure-output.log"
    phase_autofix > "${log_path}" 2>&1

    [[ "$(wc -l < "${AUTOFIX_STUB_LOG}")" -eq 1 ]]
    grep -q 'git add failed for src/fixed-alpha.py — stopping autofix to prevent incomplete PR' "${log_path}"
    grep -q 'Stopping autofix: repo changes could not be staged for alpha' "${log_path}"
    grep -q '^## Autofix: failed$' "${alpha_task}"
    ! grep -q '^## Autofix: applied$' "${alpha_task}"
    ! grep -q '^## Autofix:' "${beta_task}"
) && pass "15. git add failure marks failed and halts autofix" \
  || fail "15. git add failure marks failed and halts autofix" "git add failure did not hard-stop cleanly"

# ── Test 16: LAUREN_LOOP_TASK_FILE_HINT resolver contract works end to end ───
(
    resolver_root="${TMP_DIR}/resolver"
    setup_lauren_resolver_fixture "${resolver_root}"
    prepare_lauren_resolver_harness "${resolver_root}"

    hinted_task="${resolver_root}/docs/tasks/open/nightshift/2026-04-01-alpha.md"
    second_task="${resolver_root}/docs/tasks/open/nightshift/2026-04-02-alpha.md"
    fallback_task="${resolver_root}/docs/tasks/open/nightshift/2026-04-01-beta.md"
    mkdir -p "$(dirname "${hinted_task}")"
    printf 'alpha\n' > "${hinted_task}"
    printf 'beta\n' > "${fallback_task}"

    hinted_result="$(LAUREN_LOOP_TASK_FILE_HINT="${hinted_task}" bash -lc '
        set -e
        source "'"${resolver_root}"'/lauren-resolver-functions.sh"
        _resolve_v2_task_file alpha
    ')"
    [[ "${hinted_result}" == "${hinted_task}" ]]

    fallback_result="$(bash -lc '
        set -e
        source "'"${resolver_root}"'/lauren-resolver-functions.sh"
        _resolve_v2_task_file beta
    ')"
    [[ "${fallback_result}" == "${fallback_task}" ]]

    printf 'alpha-2\n' > "${second_task}"
    set +e
    ambiguous_output="$(bash -lc '
        set -e
        source "'"${resolver_root}"'/lauren-resolver-functions.sh"
        _resolve_v2_task_file alpha
    ' 2>&1)"
    ambiguous_rc=$?
    set -e

    [[ "${ambiguous_rc}" -eq 2 ]]
    printf '%s\n' "${ambiguous_output}" | grep -q "ambiguous nightshift task slug 'alpha'"
) && pass "16. resolver honors hint, fallback, and ambiguity handling" \
  || fail "16. resolver honors hint, fallback, and ambiguity handling" "resolver contract was wrong"

# ── Test 17: ERR trap output stays out of failed goal captures ───────────────
(
    setup_autofix_fixture "err-trap-empty-goal"
    err_log="${TMP_DIR}/err-trap-empty-goal.log"
    trap 'on_err "${LINENO}" "$?"' ERR

    set +e
    {
        goal="$(autofix_extract_goal /dev/null | autofix_compact_text)"
        rc=$?
    } 2> "${err_log}"
    set -e

    trap - ERR
    [[ "${rc}" -ne 0 ]]
    [[ -z "${goal}" ]]
    [[ "${goal}" != *"ERR trap:"* ]]
    grep -q 'ERR trap:' "${err_log}"
) && pass "17. ERR trap logs do not contaminate failed autofix goal captures" \
  || fail "17. ERR trap logs do not contaminate failed autofix goal captures" "failed goal capture still picked up trap output"

# ── Test 18: valid multiline ## Goal: content still survives under ERR trap ──
(
    setup_autofix_fixture "err-trap-valid-goal"
    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha.md"
    err_log="${TMP_DIR}/err-trap-valid-goal.log"
    mkdir -p "$(dirname "${task_path}")"
    cat > "${task_path}" <<'EOF'
## Task: err-trap-valid-goal
## Status: not started
## Created: 2026-04-01
## Execution Mode: single-agent

## Goal:
  first line
  second line

## Scope
### In Scope
- Autofix fixture coverage
EOF
    trap 'on_err "${LINENO}" "$?"' ERR

    set +e
    goal="$(autofix_extract_goal "${task_path}" | autofix_compact_text)" 2> "${err_log}"
    rc=$?
    set -e

    trap - ERR
    [[ "${rc}" -eq 0 ]]
    [[ "${goal}" == "first line second line" ]]
    [[ ! -s "${err_log}" ]]
) && pass "18. multiline ## Goal: content extracts correctly with ERR trap active" \
  || fail "18. multiline ## Goal: content extracts correctly with ERR trap active" "valid goal capture regressed under ERR trap"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed (18 tests) ==="
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1

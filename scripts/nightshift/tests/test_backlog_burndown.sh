#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

write_hash_task() {
    local path="$1" status="${2:-not started}" execution_mode="${3:-single-agent}" depends_on="${4:-}"
    mkdir -p "$(dirname "${path}")"
    cat > "${path}" <<EOF
## Task: $(basename "${path}")
## Status: ${status}
## Created: 2026-03-31
## Execution Mode: ${execution_mode}
${depends_on:+## Depends on: ${depends_on}}
## Goal
Resolve the fixture task.
## Code Review: not started
## Left Off At
Not started.
## Attempts
(none yet)
EOF
}

write_legacy_task() {
    local path="$1" status="${2:-not started}" mode_label="${3:-Single agent}" depends_on="${4:-}"
    mkdir -p "$(dirname "${path}")"
    cat > "${path}" <<EOF
# Legacy Task
**Created:** 2026-03-31
**Status:** ${status}
**Mode:** ${mode_label}
${depends_on:+**Depends on:** ${depends_on}}
## Goal
Resolve the legacy fixture task.
## Code Review: not started
## Left Off At
Not started.
## Attempts
(none yet)
EOF
}

echo "=== test_backlog_burndown.sh ==="
source "${NS_DIR}/nightshift.conf"
source "${NS_DIR}/nightshift.sh"
(
    FAILURE_NOTES=""
    WARNING_NOTES=""

    NIGHTSHIFT_BACKLOG_ENABLED="maybe"
    NIGHTSHIFT_BACKLOG_MAX_TASKS="3"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
    ! validate_nightshift_configuration
    [[ "${FAILURE_NOTES}" == *"NIGHTSHIFT_BACKLOG_ENABLED"* ]]

    FAILURE_NOTES=""
    NIGHTSHIFT_BACKLOG_ENABLED="false"
    NIGHTSHIFT_BACKLOG_MAX_TASKS="0"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
    ! validate_nightshift_configuration
    [[ "${FAILURE_NOTES}" == *"NIGHTSHIFT_BACKLOG_MAX_TASKS"* ]]

    FAILURE_NOTES=""
    NIGHTSHIFT_BACKLOG_ENABLED="false"
    NIGHTSHIFT_BACKLOG_MAX_TASKS="3"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="0"
    ! validate_nightshift_configuration
    [[ "${FAILURE_NOTES}" == *"NIGHTSHIFT_BACKLOG_MIN_BUDGET"* ]]
) && pass "1. validate_nightshift_configuration rejects invalid backlog settings" \
  || fail "1. validate_nightshift_configuration rejects invalid backlog settings" "one or more backlog settings were accepted"

(
    REPO_ROOT="${TMP_DIR}/skip-repo"
    mkdir -p "${REPO_ROOT}/docs/tasks/open"

    RUN_DATE="2026-03-31"
    DRY_RUN=0
    SETUP_FAILED=0
    RUN_COST_CAP=0
    RUN_FAILED=0
    NIGHTSHIFT_COST_CAP_USD="100"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
    NIGHTSHIFT_BACKLOG_ENABLED="false"

    disabled_log="${TMP_DIR}/backlog-disabled.log"
    phase_backlog_burndown > "${disabled_log}" 2>&1
    grep -q "Backlog burndown disabled" "${disabled_log}"

    NIGHTSHIFT_BACKLOG_ENABLED="true"
    SETUP_FAILED=1
    setup_failed_log="${TMP_DIR}/backlog-setup-failed.log"
    phase_backlog_burndown > "${setup_failed_log}" 2>&1
    grep -q "setup did not complete" "${setup_failed_log}"

    SETUP_FAILED=0
    RUN_COST_CAP=1
    cost_cap_log="${TMP_DIR}/backlog-cost-cap.log"
    phase_backlog_burndown > "${cost_cap_log}" 2>&1
    grep -q "already cost-capped" "${cost_cap_log}"

    RUN_COST_CAP=0
    cost_total_value() { echo "95.0000"; }
    low_budget_log="${TMP_DIR}/backlog-low-budget.log"
    phase_backlog_burndown > "${low_budget_log}" 2>&1
    grep -q "below minimum" "${low_budget_log}"
) && pass "2. phase_backlog_burndown skips under all documented guard conditions" \
  || fail "2. phase_backlog_burndown skips under all documented guard conditions" "one of the skip guards did not fire"

(
    REPO_ROOT="${TMP_DIR}/dry-run-repo"
    RUN_DATE="2026-03-31"
    DIGEST_PATH="${TMP_DIR}/dry-run-digest.md"
    printf '# digest\n' > "${DIGEST_PATH}"

    write_hash_task "${REPO_ROOT}/docs/tasks/open/alpha.md" "not started" "single-agent"
    write_hash_task "${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-manager.md" "not started" "single-agent"
    write_hash_task "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-skip/task.md" "not started" "single-agent"

    mkdir -p "${REPO_ROOT}"
    cat > "${REPO_ROOT}/lauren-loop.sh" <<EOF
#!/usr/bin/env bash
echo "unexpected next" >> "${TMP_DIR}/dry-run-invoked.log"
EOF
    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<EOF
#!/usr/bin/env bash
echo "unexpected v2" >> "${TMP_DIR}/dry-run-invoked.log"
EOF

    NIGHTSHIFT_BACKLOG_ENABLED="true"
    NIGHTSHIFT_BACKLOG_MAX_TASKS="2"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
    NIGHTSHIFT_COST_CAP_USD="100"
    DRY_RUN=1
    SETUP_FAILED=0
    RUN_COST_CAP=0
    BACKLOG_RESULTS=()

    dry_run_log="${TMP_DIR}/dry-run-preview.log"
    phase_backlog_burndown > "${dry_run_log}" 2>&1

    [[ ! -f "${TMP_DIR}/dry-run-invoked.log" ]]
    grep -q "DRY RUN: would pick docs/tasks/open/alpha.md (slug: alpha)" "${dry_run_log}"
    [[ "${#BACKLOG_RESULTS[@]}" -eq 1 ]]
    grep -q "## Backlog Burndown" "${DIGEST_PATH}"
) && pass "3. dry-run picks locally and never calls Lauren" \
  || fail "3. dry-run picks locally and never calls Lauren" "preview was wrong or Lauren was invoked"

(
    mock_output=$'Ranking summary\n\n## TASK_LIST\n1|docs/tasks/open/alpha.md|Ship alpha|simple\n2|docs/tasks/open/beta/task.md|Ship beta|complex\n'
    parsed=()
    while IFS= read -r line; do
        parsed+=("${line}")
    done < <(backlog_parse_task_list "${mock_output}")

    [[ "${#parsed[@]}" -eq 2 ]]
    [[ "${parsed[0]}" == "1|docs/tasks/open/alpha.md|Ship alpha|simple" ]]
    [[ "${parsed[1]}" == "2|docs/tasks/open/beta/task.md|Ship beta|complex" ]]
) && pass "4. backlog_parse_task_list reads ## TASK_LIST rows in order" \
  || fail "4. backlog_parse_task_list reads ## TASK_LIST rows in order" "parser output was missing or malformed"

(
    REPO_ROOT="${TMP_DIR}/cap-repo"
    RUN_DATE="2026-03-31"
    NIGHTSHIFT_BACKLOG_ENABLED="true"
    NIGHTSHIFT_BACKLOG_MAX_TASKS="2"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
    NIGHTSHIFT_COST_CAP_USD="100"
    DRY_RUN=0
    SETUP_FAILED=0
    RUN_COST_CAP=0
    RUN_FAILED=0
    DIGEST_PATH="${TMP_DIR}/cap-digest.md"
    printf '# digest\n' > "${DIGEST_PATH}"

    write_hash_task "${REPO_ROOT}/docs/tasks/open/alpha.md"
    write_hash_task "${REPO_ROOT}/docs/tasks/open/beta.md"
    write_hash_task "${REPO_ROOT}/docs/tasks/open/gamma.md"
    write_hash_task "${REPO_ROOT}/docs/tasks/open/delta.md"

    cat > "${REPO_ROOT}/lauren-loop.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
Ranked backlog

## TASK_LIST
1|docs/tasks/open/alpha.md|Ship alpha|simple
2|docs/tasks/open/beta.md|Ship beta|simple
3|docs/tasks/open/gamma.md|Ship gamma|complex
4|docs/tasks/open/delta.md|Ship delta|complex
OUTPUT
EOF

    export BACKLOG_CAP_V2_LOG="${TMP_DIR}/cap-v2.log"
    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "${LAUREN_LOOP_MAX_COST:-}" >> "${BACKLOG_CAP_V2_LOG}"
EOF

    git() {
        if [[ "$1" == "status" && "$2" == "--porcelain" ]]; then
            return 0
        fi
        command git "$@"
    }

    phase_backlog_burndown >/dev/null 2>&1

    [[ "$(wc -l < "${BACKLOG_CAP_V2_LOG}")" -eq 2 ]]
    grep -q '^alpha|Ship alpha|50.00$' "${BACKLOG_CAP_V2_LOG}"
    grep -q '^beta|Ship beta|100.00$' "${BACKLOG_CAP_V2_LOG}"
    ! grep -q '^gamma|' "${BACKLOG_CAP_V2_LOG}"
    [[ "${#BACKLOG_RESULTS[@]}" -eq 2 ]]
) && pass "5. live backlog execution stops at NIGHTSHIFT_BACKLOG_MAX_TASKS" \
  || fail "5. live backlog execution stops at NIGHTSHIFT_BACKLOG_MAX_TASKS" "too many candidates were executed"

(
    REPO_ROOT="${TMP_DIR}/same-run-repo"
    RUN_DATE="2026-03-31"
    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-manager.md"
    write_hash_task "${task_path}"
    ! backlog_task_is_pickable "docs/tasks/open/nightshift/${RUN_DATE}-manager.md"
) && pass "6. backlog_task_is_pickable skips same-run manager tasks" \
  || fail "6. backlog_task_is_pickable skips same-run manager tasks" "same-run manager task was treated as pickable"

(
    REPO_ROOT="${TMP_DIR}/bridge-runtime-repo"
    RUN_DATE="2026-03-31"
    task_path="${REPO_ROOT}/docs/tasks/open/nightshift-bridge-alpha/task.md"
    write_hash_task "${task_path}"
    ! backlog_task_is_pickable "docs/tasks/open/nightshift-bridge-alpha/task.md"
 ) && pass "7. backlog_task_is_pickable skips bridge runtime tasks" \
  || fail "7. backlog_task_is_pickable skips bridge runtime tasks" "bridge runtime task was treated as pickable"

(
    REPO_ROOT="${TMP_DIR}/team-mode-repo"
    RUN_DATE="2026-03-31"
    task_path="${REPO_ROOT}/docs/tasks/open/team-task.md"
    write_legacy_task "${task_path}" "not started" "team"
    ! backlog_task_is_pickable "docs/tasks/open/team-task.md"
) && pass "8. backlog_task_is_pickable recognizes legacy team-mode metadata" \
  || fail "8. backlog_task_is_pickable recognizes legacy team-mode metadata" "team-mode task slipped through"

(
    REPO_ROOT="${TMP_DIR}/closed-dependency-repo"
    RUN_DATE="2026-03-31"

    write_hash_task "${REPO_ROOT}/docs/tasks/closed/some-task.md"
    write_legacy_task "${REPO_ROOT}/docs/tasks/open/closed-path-ok.md" "not started" "Single agent" "docs/tasks/closed/some-task.md"
    ! backlog_task_is_pickable "docs/tasks/open/closed-path-ok.md"
) && pass "9. backlog_task_is_pickable still blocks non-terminal closed-path dependencies" \
  || fail "9. backlog_task_is_pickable still blocks non-terminal closed-path dependencies" "non-terminal closed dependency was treated as satisfied"

(
    REPO_ROOT="${TMP_DIR}/outcome-repo"
    RUN_DATE="2026-03-31"
    status_slugs=(alpha beta gamma delta epsilon zeta eta theta iota kappa lambda)
    NIGHTSHIFT_BACKLOG_ENABLED="true"
    NIGHTSHIFT_BACKLOG_MAX_TASKS="11"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
    NIGHTSHIFT_COST_CAP_USD="100"
    DRY_RUN=0
    SETUP_FAILED=0
    RUN_COST_CAP=0
    RUN_FAILED=0
    WARNING_NOTES=""
    DIGEST_PATH="${TMP_DIR}/outcome-digest.md"
    printf '# digest\n' > "${DIGEST_PATH}"

    for slug in "${status_slugs[@]}"; do
        write_hash_task "${REPO_ROOT}/docs/tasks/open/${slug}.md"
    done

    {
        echo '#!/usr/bin/env bash'
        echo "printf 'Ranking summary\n1|docs/tasks/open/alpha.md|Ship alpha|simple\n'"
    } > "${REPO_ROOT}/lauren-loop.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'exit 99'
    } > "${REPO_ROOT}/lauren-loop-v2.sh"
    no_header_log="${TMP_DIR}/backlog-no-header.log"
    phase_backlog_burndown > "${no_header_log}" 2>&1
    grep -q "no ## TASK_LIST header" "${no_header_log}"

    {
        echo '#!/usr/bin/env bash'
        echo "cat <<'OUTPUT'"
        echo 'Ranking summary'
        echo '## TASK_LIST'
        echo '1|docs/tasks/open/alpha.md|Ship alpha'
        echo 'OUTPUT'
    } > "${REPO_ROOT}/lauren-loop.sh"
    malformed_log="${TMP_DIR}/backlog-malformed.log"
    phase_backlog_burndown > "${malformed_log}" 2>&1
    grep -q "none matched the expected rank|path|goal|complexity format" "${malformed_log}"

    {
        echo '#!/usr/bin/env bash'
        echo "cat <<'OUTPUT'"
        echo 'Ranked backlog'
        echo '## TASK_LIST'
        for rank in "${!status_slugs[@]}"; do
            printf '%s|docs/tasks/open/%s.md|Ship %s|simple\n' \
                "$((rank + 1))" "${status_slugs[${rank}]}" "${status_slugs[${rank}]}"
        done
        echo 'OUTPUT'
    } > "${REPO_ROOT}/lauren-loop.sh"

    export BACKLOG_OUTCOME_V2_LOG="${TMP_DIR}/outcome-v2.log"
    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "${BACKLOG_OUTCOME_V2_LOG}"
manifest_dir="${REPO_ROOT}/docs/tasks/open/\${1}/competitive"
mkdir -p "\${manifest_dir}"
case "\$1" in
    alpha) exit 9 ;;
    beta) printf '{ "final_status": "success" }\n' > "\${manifest_dir}/run-manifest.json" ;;
    gamma) printf '{ "final_status": "human_review" }\n' > "\${manifest_dir}/run-manifest.json" ;;
    delta) printf '{ "final_status": "completed" }\n' > "\${manifest_dir}/run-manifest.json" ;;
    epsilon) printf '{ "final_status": "partial" }\n' > "\${manifest_dir}/run-manifest.json" ;;
    zeta) ;;
    eta) : > "\${manifest_dir}/run-manifest.json" ;;
    theta) printf 'not json at all\n' > "\${manifest_dir}/run-manifest.json" ;;
    iota) printf '{ "final_status": "" }\n' > "\${manifest_dir}/run-manifest.json" ;;
    kappa) printf '{ "phases": [] }\n' > "\${manifest_dir}/run-manifest.json" ;;
    lambda) printf '%s\n' '{' '  "final_status" : "success"' '}' > "\${manifest_dir}/run-manifest.json" ;;
esac
exit 0
EOF

    cost_total_value() { echo "0.0000"; }

    git_status_call_file="${TMP_DIR}/outcome-git-status-call.txt"
    printf '0\n' > "${git_status_call_file}"
    git() {
        if [[ "$1" == "status" && "$2" == "--porcelain" ]]; then
            local git_status_call="" limit=0 i=0
            git_status_call="$(cat "${git_status_call_file}")"
            printf '%s\n' "$((git_status_call + 1))" > "${git_status_call_file}"
            limit=$((git_status_call / 2 + git_status_call % 2))
            for ((i = 0; i < limit && i < ${#status_slugs[@]}; i++)); do
                printf ' M src/%s.py\n' "${status_slugs[${i}]}"
            done
            return 0
        fi
        command git "$@"
    }

    phase_rc=0
    phase_backlog_burndown || phase_rc=$?

    results_dump="$(printf '%s\n' "${BACKLOG_RESULTS[@]-}")"
    stage_dump="$(printf '%s\n' "${BACKLOG_STAGE_PATHS[@]-}")"
    ok=true
    [[ "${phase_rc}" -eq 0 ]] || ok=false
    [[ "${RUN_FAILED}" -eq 0 ]] || ok=false
    [[ -f "${BACKLOG_OUTCOME_V2_LOG}" ]] || ok=false
    if [[ -f "${BACKLOG_OUTCOME_V2_LOG}" ]]; then
        [[ "$(wc -l < "${BACKLOG_OUTCOME_V2_LOG}")" -eq "${#status_slugs[@]}" ]] || ok=false
    fi
    [[ "${#BACKLOG_RESULTS[@]}" -eq "${#status_slugs[@]}" ]] || ok=false
    while IFS='|' read -r slug outcome; do
        grep -Fq $'docs/tasks/open/'"${slug}"$'.md\t'"${slug}"$'\t'"${outcome}"$'\t0.0000' <<< "${results_dump}" || ok=false
    done <<'EOF'
alpha|failed
beta|success
gamma|human_review
delta|blocked
epsilon|failed
zeta|failed
eta|failed
theta|failed
iota|failed
kappa|failed
lambda|success
EOF
    [[ "${#BACKLOG_STAGE_PATHS[@]}" -eq 2 ]] || ok=false
    for slug in beta lambda; do
        grep -Fxq "${REPO_ROOT}/src/${slug}.py" <<< "${stage_dump}" || ok=false
    done
    for slug in alpha gamma delta epsilon zeta eta theta iota kappa; do
        ! grep -Fq "${REPO_ROOT}/src/${slug}.py" <<< "${stage_dump}" || ok=false
    done
    grep -q "## Backlog Burndown" "${DIGEST_PATH}" || ok=false
    [[ "${WARNING_NOTES}" == *"unknown final_status 'partial'"* ]] || ok=false
    [[ "${WARNING_NOTES}" == *"Backlog task zeta exited 0 but manifest ${REPO_ROOT}/docs/tasks/open/zeta/competitive/run-manifest.json was missing or unreadable"* ]] || ok=false
    for slug in eta theta iota kappa; do
        [[ "${WARNING_NOTES}" == *"Backlog task ${slug} exited 0 but manifest ${REPO_ROOT}/docs/tasks/open/${slug}/competitive/run-manifest.json did not contain final_status"* ]] || ok=false
    done
    [[ "${WARNING_NOTES}" != *"Backlog task beta exited 0"* ]] || ok=false
    [[ "${WARNING_NOTES}" != *"Backlog task lambda exited 0"* ]] || ok=false
    [[ "${ok}" == "true" ]]
 ) && pass "10. backlog warnings and non-success outcomes stay non-gating; only success stages files" \
  || fail "10. backlog warnings and non-success outcomes stay non-gating; only success stages files" "warning handling, outcome mapping, stage capture, or digest output was wrong"

(
    REPO_ROOT="${TMP_DIR}/ship-repo"
    RUN_DATE="2026-03-31"
    RUN_BRANCH="nightshift/2026-03-31"
    NIGHTSHIFT_BASE_BRANCH="main"
    NIGHTSHIFT_PR_LABELS=""
    DRY_RUN=0
    RUN_COST_CAP=0
    RUN_CLEAN=0
    RUN_FAILED=0
    BRANCH_READY=1
    GH_AVAILABLE=1
    DIGEST_STAGEABLE=0
    DIGEST_PATH=""
    TASK_FILE_COUNT=0
    TOTAL_FINDINGS_AVAILABLE=0
    PR_URL=""
    mkdir -p "${REPO_ROOT}"

    artifact_one="${REPO_ROOT}/artifact-one.txt"
    artifact_two="${REPO_ROOT}/artifact-two.txt"
    printf 'one\n' > "${artifact_one}"
    printf 'two\n' > "${artifact_two}"
    BACKLOG_STAGE_PATHS=("${artifact_one}" "${artifact_two}")
    BRIDGE_STAGE_PATHS=()

    export BACKLOG_GIT_ADD_LOG="${TMP_DIR}/ship-git-add.log"
    git() {
        if [[ "$1" == "status" && "$2" == "--porcelain" ]]; then
            printf ' M artifact-one.txt\n M artifact-two.txt\n'
            return 0
        fi
        if [[ "$1" == "add" ]]; then
            printf '%s\n' "$*" > "${BACKLOG_GIT_ADD_LOG}"
            return 0
        fi
        if [[ "$1" == "diff" && "$2" == "--cached" && "$3" == "--quiet" ]]; then
            return 1
        fi
        if [[ "$1" == "commit" || "$1" == "push" ]]; then
            return 0
        fi
        command git "$@"
    }

    gh() {
        if [[ "$1" == "pr" && "$2" == "create" ]]; then
            printf 'https://example.test/pr/123\n'
            return 0
        fi
        return 1
    }

    ship_log="${TMP_DIR}/ship-phase.log"
    phase_rc=0
    phase_ship_results || phase_rc=$?

    ok=true
    [[ "${phase_rc}" -eq 0 ]] || ok=false
    [[ -f "${BACKLOG_GIT_ADD_LOG}" ]] || ok=false
    if [[ -f "${BACKLOG_GIT_ADD_LOG}" ]]; then
        grep -q "${artifact_one}" "${BACKLOG_GIT_ADD_LOG}" || ok=false
        grep -q "${artifact_two}" "${BACKLOG_GIT_ADD_LOG}" || ok=false
    fi
    [[ "${ok}" == "true" ]]
 ) && pass "11. phase_ship_results stages backlog artifacts alongside existing outputs" \
  || fail "11. phase_ship_results stages backlog artifacts alongside existing outputs" "backlog stage paths were not forwarded to git add"

echo ""
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi

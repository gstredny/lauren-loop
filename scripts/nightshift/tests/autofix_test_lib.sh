#!/usr/bin/env bash

setup_autofix_fixture() {
    local fixture_name="$1"

    REPO_ROOT="${TMP_DIR}/${fixture_name}/repo"
    RUN_TMP_DIR="${TMP_DIR}/${fixture_name}/run"
    RUN_DATE="2026-04-01"
    RUN_ID="test-autofix-${fixture_name}"
    DRY_RUN=0
    SETUP_FAILED=0
    RUN_COST_CAP=0
    RUN_FAILED=0
    RUN_CLEAN=0
    CURRENT_PHASE="3.5c"
    VALIDATED_TASKS=()
    COST_TRACKING_READY=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    NIGHTSHIFT_AUTOFIX_ENABLED="true"
    NIGHTSHIFT_AUTOFIX_MAX_TASKS="10"
    NIGHTSHIFT_AUTOFIX_MIN_BUDGET="20"
    NIGHTSHIFT_AUTOFIX_SEVERITY="critical,major"
    NIGHTSHIFT_COST_CAP_USD="100"

    mkdir -p "${REPO_ROOT}/docs/tasks/open/nightshift" "${REPO_ROOT}/src" "${RUN_TMP_DIR}"
}

write_autofix_task() {
    local task_path="$1"
    local severity="$2"
    local goal="$3"

    mkdir -p "$(dirname "${task_path}")"
    cat > "${task_path}" <<EOF
## Task: $(basename "${task_path}")
## Status: not started
## Created: ${RUN_DATE}
## Execution Mode: single-agent

## Motivation
Autofix test fixture.

## Goal
${goal}

## Scope
### In Scope
- Autofix fixture coverage

### Out of Scope
- Anything else

## Relevant Files
- \`src/example.py\` — fixture reference

## Context
- Source: Nightshift ${RUN_ID}
- Severity: ${severity}
- Category: regression

## Anti-Patterns
- Do NOT mutate unrelated files

## Done Criteria
- [ ] Autofix fixture behaves deterministically

## Code Review: not started

## Left Off At
Not started.

## Attempts
(none)
EOF
}

write_autofix_stub() {
    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

slug="${1:-}"
goal="${2:-}"
flag="${3:-}"
task_hint="${LAUREN_LOOP_TASK_FILE_HINT:-}"
task_dir="${task_hint%.md}"

if [[ "${task_hint}" == */task.md ]]; then
    task_dir="$(dirname "${task_hint}")"
fi

printf '%s|%s|%s|%s\n' "${slug}" "${goal}" "${flag}" "${LAUREN_LOOP_MAX_COST:-}" >> "${AUTOFIX_STUB_LOG}"

rule="$(grep "^${slug}|" "${AUTOFIX_STUB_BEHAVIOR_FILE}" | head -n 1 || true)"
IFS='|' read -r _ behavior_exit behavior_status behavior_cost behavior_manifest_mode <<< "${rule}"

manifest_dir="${task_dir}/competitive"
case "${behavior_manifest_mode:-normal}" in
    missing)
        ;;
    corrupt)
        mkdir -p "${manifest_dir}"
        printf '{not-json\n' > "${manifest_dir}/run-manifest.json"
        ;;
    missing-status)
        mkdir -p "${manifest_dir}"
        jq -cn \
            --arg total_cost_usd "${behavior_cost}" \
            '{ total_cost_usd: $total_cost_usd }' \
            > "${manifest_dir}/run-manifest.json"
        ;;
    invalid-cost)
        mkdir -p "${manifest_dir}"
        jq -cn \
            --arg final_status "${behavior_status}" \
            '{ final_status: $final_status, total_cost_usd: "oops" }' \
            > "${manifest_dir}/run-manifest.json"
        ;;
    *)
        if [[ -n "${behavior_status:-}" ]]; then
            mkdir -p "${manifest_dir}"
            jq -cn \
                --arg final_status "${behavior_status}" \
                --arg total_cost_usd "${behavior_cost}" \
                '{ final_status: $final_status, total_cost_usd: $total_cost_usd }' \
                > "${manifest_dir}/run-manifest.json"
        fi
        ;;
esac

exit "${behavior_exit:-0}"
EOF
    chmod +x "${REPO_ROOT}/lauren-loop-v2.sh"
}

write_behavior_file() {
    local path="$1"
    shift

    : > "${path}"
    while [[ $# -gt 0 ]]; do
        printf '%s\n' "$1" >> "${path}"
        shift
    done
}

setup_autofix_git_mock() {
    GIT_STASH_CALLS=0
    GIT_LS_FILES_CALLS=0
    GIT_DIFF_CALLS=0
    GIT_ADD_CALLS=0

    git() {
        if [[ "$1" == "stash" && "$2" == "create" ]]; then
            local output_var=""
            GIT_STASH_CALLS=$((GIT_STASH_CALLS + 1))
            output_var="AUTOFIX_GIT_STASH_OUTPUT_${GIT_STASH_CALLS}"
            printf '%b' "${!output_var:-}"
            return 0
        fi
        if [[ "$1" == "ls-files" && "$2" == "--others" && "$3" == "--exclude-standard" ]]; then
            local output_var=""
            GIT_LS_FILES_CALLS=$((GIT_LS_FILES_CALLS + 1))
            output_var="AUTOFIX_GIT_UNTRACKED_OUTPUT_${GIT_LS_FILES_CALLS}"
            printf '%b' "${!output_var:-}"
            return 0
        fi
        if [[ "$1" == "diff" && "$2" == "--name-only" ]]; then
            local output_var=""
            GIT_DIFF_CALLS=$((GIT_DIFF_CALLS + 1))
            output_var="AUTOFIX_GIT_DIFF_OUTPUT_${GIT_DIFF_CALLS}"
            printf '%b' "${!output_var:-}"
            return 0
        fi
        if [[ "$1" == "add" ]]; then
            local exit_var=""
            GIT_ADD_CALLS=$((GIT_ADD_CALLS + 1))
            [[ -n "${GIT_ADD_LOG:-}" ]] && printf '%s\n' "$*" >> "${GIT_ADD_LOG}"
            exit_var="AUTOFIX_GIT_ADD_EXIT_${GIT_ADD_CALLS}"
            return "${!exit_var:-0}"
        fi
        command git "$@"
    }
}

setup_lauren_resolver_fixture() {
    local fixture_root="$1"
    local source_root=""

    source_root="$(cd "${NS_DIR}/../.." && pwd)"
    mkdir -p "${fixture_root}/lib" "${fixture_root}/prompts" "${fixture_root}/docs/tasks/open/nightshift"
    cp "${source_root}/lauren-loop-v2.sh" "${fixture_root}/lauren-loop-v2.sh"
    cp "${source_root}/lib/lauren-loop-utils.sh" "${fixture_root}/lib/lauren-loop-utils.sh"
    : > "${fixture_root}/prompts/project-rules.md"
}

prepare_lauren_resolver_harness() {
    local fixture_root="$1"

    awk '
        /^_consolidate_task_to_dir\(\)/ {
            exit
        }
        {
            print
        }
    ' "${fixture_root}/lauren-loop-v2.sh" > "${fixture_root}/lauren-resolver-functions.sh"
}

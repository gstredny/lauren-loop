#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONF_PATH="${SCRIPT_DIR}/nightshift.conf"
PYTHON_ORCHESTRATOR_DIR="${SCRIPT_DIR}/python"
PYTHON_BIN="${REPO_ROOT}/.venv/bin/python"
BOOTSTRAP_STATUS="fresh"
BOOTSTRAP_WARNING=""
BOOTSTRAP_REPAIR_STATUS="not-needed"
BOOTSTRAP_REPAIR_NOTE=""
BOOTSTRAP_REPAIR_LOG="${SCRIPT_DIR}/logs/bootstrap-repair.log"

bootstrap_log() {
    printf '[%s] [nightshift-bootstrap] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

record_repair_event() {
    mkdir -p "$(dirname "${BOOTSTRAP_REPAIR_LOG}")"
    printf '[%s] status=%s base_branch=%s note=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "${BOOTSTRAP_REPAIR_STATUS}" \
        "${BASE_BRANCH:-unknown}" \
        "${BOOTSTRAP_REPAIR_NOTE:-none}" >> "${BOOTSTRAP_REPAIR_LOG}"
}

resolve_base_branch() {
    local configured_branch=""

    if [[ -n "${NIGHTSHIFT_BASE_BRANCH:-}" ]]; then
        printf '%s' "${NIGHTSHIFT_BASE_BRANCH}"
        return 0
    fi
    if [[ -r "${CONF_PATH}" ]]; then
        configured_branch="$(sed -n 's/^NIGHTSHIFT_BASE_BRANCH="\${NIGHTSHIFT_BASE_BRANCH:-\([^"]*\)}"/\1/p' "${CONF_PATH}" | head -n 1)"
        if [[ -n "${configured_branch}" ]]; then
            printf '%s' "${configured_branch}"
            return 0
        fi
        configured_branch="$(sed -n 's/^NIGHTSHIFT_BASE_BRANCH="\([^"]*\)"/\1/p' "${CONF_PATH}" | head -n 1)"
        if [[ -n "${configured_branch}" ]]; then
            printf '%s' "${configured_branch}"
            return 0
        fi
    fi
    printf 'main'
}

fail_closed() {
    bootstrap_log "ERROR: $1"
    exit 1
}

prune_local_nightshift_branches() {
    local branch=""
    local output=""
    local branches=()

    while IFS= read -r branch; do
        [[ -z "${branch}" ]] && continue
        branches+=("${branch}")
    done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*' 2>/dev/null || true)

    if (( ${#branches[@]} == 0 )); then
        return 0
    fi

    if output="$(git branch -D "${branches[@]}" 2>&1)"; then
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            bootstrap_log "post-detach prune: ${line}"
        done <<< "${output}"
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        bootstrap_log "WARN: post-detach prune: ${line}"
    done <<< "${output}"
    return 0
}

fetch_origin_branch() {
    local attempt=1
    local delay=0

    while [[ "${attempt}" -le 3 ]]; do
        if git fetch origin "${BASE_BRANCH}"; then
            bootstrap_log "Fetched origin/${BASE_BRANCH} on attempt ${attempt}"
            return 0
        fi

        if [[ "${attempt}" -eq 3 ]]; then
            break
        fi

        if [[ "${attempt}" -eq 1 ]]; then
            delay=30
        else
            delay=120
        fi

        bootstrap_log "WARN: git fetch origin ${BASE_BRANCH} failed on attempt ${attempt}; retrying in ${delay}s"
        sleep "${delay}"
        attempt=$((attempt + 1))
    done

    return 1
}

detach_to_origin_branch() {
    if git checkout --detach "origin/${BASE_BRANCH}"; then
        bootstrap_log "Detached HEAD at origin/${BASE_BRANCH}"
        prune_local_nightshift_branches
        return 0
    fi

    return 1
}

write_bootstrap_failure() {
    local reason="$1"
    local logs_dir="${SCRIPT_DIR}/logs"
    local timestamp
    local artifact_path

    timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    artifact_path="${logs_dir}/bootstrap-failure-$(date '+%Y%m%dT%H%M%S')-$$.json"

    bootstrap_log "ERROR: ${reason}"

    if mkdir -p "${logs_dir}" && jq -n \
        --arg timestamp "${timestamp}" \
        --arg reason "${reason}" \
        --arg base_branch "${BASE_BRANCH:-unknown}" \
        --arg repair_status "${BOOTSTRAP_REPAIR_STATUS}" \
        --arg repair_note "${BOOTSTRAP_REPAIR_NOTE:-none}" \
        '{
            timestamp: $timestamp,
            reason: $reason,
            base_branch: $base_branch,
            repair_status: $repair_status,
            repair_note: $repair_note
        }' > "${artifact_path}"; then
        bootstrap_log "Bootstrap failure artifact written to ${artifact_path}"
    else
        bootstrap_log "WARN: Failed to write bootstrap failure artifact to ${artifact_path}"
    fi

    exit 1
}

run_core() {
    export NIGHTSHIFT_BOOTSTRAP_STATUS="${BOOTSTRAP_STATUS}"
    if [[ -n "${BOOTSTRAP_WARNING}" ]]; then
        export NIGHTSHIFT_BOOTSTRAP_WARNING="${BOOTSTRAP_WARNING}"
    else
        unset NIGHTSHIFT_BOOTSTRAP_WARNING 2>/dev/null || true
    fi
    export NIGHTSHIFT_BOOTSTRAP_REPAIR_STATUS="${BOOTSTRAP_REPAIR_STATUS}"
    export NIGHTSHIFT_BOOTSTRAP_REPAIR_LOG="${BOOTSTRAP_REPAIR_LOG}"
    if [[ -n "${BOOTSTRAP_REPAIR_NOTE}" ]]; then
        export NIGHTSHIFT_BOOTSTRAP_REPAIR_NOTE="${BOOTSTRAP_REPAIR_NOTE}"
    else
        unset NIGHTSHIFT_BOOTSTRAP_REPAIR_NOTE 2>/dev/null || true
    fi

    cd "${PYTHON_ORCHESTRATOR_DIR}" || fail_closed "Cannot cd to Python orchestrator: ${PYTHON_ORCHESTRATOR_DIR}"
    exec "${PYTHON_BIN}" -m nightshift "$@"
}

main() {
    local base_branch=""

    base_branch="$(resolve_base_branch)"
    BASE_BRANCH="${base_branch}"

    if [[ ! -d "${PYTHON_ORCHESTRATOR_DIR}" ]]; then
        fail_closed "Python orchestrator dir missing: ${PYTHON_ORCHESTRATOR_DIR}"
    fi
    if [[ ! -x "${PYTHON_BIN}" ]]; then
        fail_closed "Python binary missing or not executable: ${PYTHON_BIN}"
    fi
    if ! command -v git >/dev/null 2>&1; then
        fail_closed "git is not available"
    fi
    if ! cd "${REPO_ROOT}"; then
        fail_closed "Cannot cd to repo root: ${REPO_ROOT}"
    fi
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        fail_closed "Not inside a git working tree: ${REPO_ROOT}"
    fi

    if ! fetch_origin_branch; then
        write_bootstrap_failure "Could not fetch origin/${BASE_BRANCH} after 3 attempts"
    fi

    if detach_to_origin_branch; then
        BOOTSTRAP_STATUS="fresh"
        run_core "$@"
    fi

    bootstrap_log "Force-cleaning worktree before detach"
    if git reset --hard HEAD && git clean -fd; then
        if detach_to_origin_branch; then
            BOOTSTRAP_REPAIR_STATUS="force-clean-succeeded"
            BOOTSTRAP_REPAIR_NOTE="detach-retry-succeeded-after-reset-clean"
            record_repair_event
            BOOTSTRAP_STATUS="fresh"
            run_core "$@"
        fi
        BOOTSTRAP_REPAIR_STATUS="force-clean-fallback"
        BOOTSTRAP_REPAIR_NOTE="detach-retry-failed-after-reset-clean"
        record_repair_event
        write_bootstrap_failure "Could not detach to origin/${BASE_BRANCH} after reset/clean repair"
    fi

    BOOTSTRAP_REPAIR_STATUS="force-clean-failed"
    BOOTSTRAP_REPAIR_NOTE="reset-clean-command-failed"
    record_repair_event
    write_bootstrap_failure "Reset/clean repair failed before detach retry"
}

main "$@"

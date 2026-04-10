#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONF_PATH="${SCRIPT_DIR}/nightshift.conf"
PYTHON_ORCHESTRATOR_DIR="${SCRIPT_DIR}/python"
PYTHON_BIN="${REPO_ROOT}/.venv/bin/python"
BOOTSTRAP_STATUS="fresh"
BOOTSTRAP_WARNING=""

bootstrap_log() {
    printf '[%s] [nightshift-bootstrap] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
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

tracked_files_clean() {
    local status_output=""
    status_output="$(git status --porcelain --untracked-files=no 2>/dev/null || true)"
    [[ -z "${status_output}" ]]
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

set_fallback_warning() {
    BOOTSTRAP_STATUS="stale-fallback"
    BOOTSTRAP_WARNING="$1"
    bootstrap_log "WARN: ${BOOTSTRAP_WARNING}"
}

run_core() {
    export NIGHTSHIFT_BOOTSTRAP_STATUS="${BOOTSTRAP_STATUS}"
    if [[ -n "${BOOTSTRAP_WARNING}" ]]; then
        export NIGHTSHIFT_BOOTSTRAP_WARNING="${BOOTSTRAP_WARNING}"
    else
        unset NIGHTSHIFT_BOOTSTRAP_WARNING 2>/dev/null || true
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
        set_fallback_warning "Nightshift bootstrap could not fetch origin/${BASE_BRANCH} after 3 attempts; running the current checkout as-is"
        run_core "$@"
    fi

    if detach_to_origin_branch; then
        BOOTSTRAP_STATUS="fresh"
        run_core "$@"
    fi

    if tracked_files_clean; then
        bootstrap_log "WARN: git checkout --detach origin/${BASE_BRANCH} failed; attempting reset/clean repair before one retry"
        if git reset --hard HEAD && git clean -fd; then
            if detach_to_origin_branch; then
                BOOTSTRAP_STATUS="fresh"
                run_core "$@"
            fi
            set_fallback_warning "Nightshift bootstrap could not detach to origin/${BASE_BRANCH} after reset/clean repair; running the current checkout as-is"
            run_core "$@"
        fi

        set_fallback_warning "Nightshift bootstrap repair failed before detach retry; running the current checkout as-is"
        run_core "$@"
    fi

    set_fallback_warning "Nightshift bootstrap skipped reset/clean because tracked files were modified after git checkout --detach origin/${BASE_BRANCH} failed; running the current checkout as-is"
    run_core "$@"
}

main "$@"

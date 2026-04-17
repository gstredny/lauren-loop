#!/usr/bin/env bash
# backlog-floor.sh — shared helpers for backlog min-tasks-per-run calculations.

if [[ -n "${_NIGHTSHIFT_BACKLOG_FLOOR_SH:-}" ]]; then
    return 0
fi
_NIGHTSHIFT_BACKLOG_FLOOR_SH=1

backlog_needed_tasks() {
    local attempted="$1"
    local minimum="$2"

    if (( minimum <= 0 || attempted >= minimum )); then
        printf '0\n'
        return 0
    fi

    printf '%s\n' "$(( minimum - attempted ))"
}

backlog_effective_max_tasks() {
    local attempted="$1"
    local minimum="$2"
    local configured_max="$3"
    local needed=0

    needed="$(backlog_needed_tasks "${attempted}" "${minimum}")"
    if (( needed > configured_max )); then
        printf '%s\n' "${needed}"
        return 0
    fi

    printf '%s\n' "${configured_max}"
}

backlog_clean_run_satisfied() {
    local attempted="$1"
    local minimum="$2"
    local needed=0

    needed="$(backlog_needed_tasks "${attempted}" "${minimum}")"
    (( needed == 0 ))
}

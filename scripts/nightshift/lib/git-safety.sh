#!/usr/bin/env bash
# git-safety.sh — Git safety guardrails for Nightshift detective runs.
# Sourced by the orchestrator. Requires nightshift.conf to be sourced first.
# Prevents accidental writes to protected branches and runaway file generation.
# All logging goes to stderr.

# Fail closed if sourced from the wrong shell.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '[%s] [nightshift-git-safety] CRITICAL: Bash is required\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
    return 1 2>/dev/null || exit 1
fi

# Guard against double-sourcing
[[ -n "${_NIGHTSHIFT_GIT_SAFETY_LOADED:-}" ]] && return 0
_NIGHTSHIFT_GIT_SAFETY_LOADED=1

# ── Internal Helpers ──────────────────────────────────────────────────────────

_git_log() {
    printf '[%s] [nightshift-git-safety] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

# ── Public Functions ──────────────────────────────────────────────────────────

# Check if a branch name matches any protected branch.
# Usage: git_validate_branch <branch_name>
# Returns: 0 = safe (not protected), 1 = protected (unsafe).
git_validate_branch() {
    local branch="${1:-}"

    if [[ -z "$branch" ]]; then
        _git_log "CRITICAL: No branch name provided"
        return 1
    fi

    local protected_list="${NIGHTSHIFT_PROTECTED_BRANCHES:-main,development,master}"
    local IFS=','
    local protected
    for protected in $protected_list; do
        if [[ "$branch" == "$protected" ]]; then
            _git_log "CRITICAL: Branch '$branch' is protected — Nightshift must not write to it"
            return 1
        fi
    done

    _git_log "OK: Branch '$branch' is not protected"
    return 0
}

# Validate that a commit message starts with the required prefix.
# Usage: git_validate_commit_message <message>
# Returns: 0 = valid, 1 = invalid.
git_validate_commit_message() {
    local message="${1:-}"

    if [[ -z "$message" ]]; then
        _git_log "CRITICAL: Empty commit message"
        return 1
    fi

    if [[ "$message" != nightshift:\ * ]]; then
        _git_log "CRITICAL: Commit message does not start with 'nightshift: ' — got: '${message}'"
        return 1
    fi

    _git_log "OK: Commit message prefix valid"
    return 0
}

# Validate PR size against configured thresholds.
# Usage: git_validate_pr_size [base_branch]
# Returns: 0 = within limits, 1 = too large or cannot determine.
git_validate_pr_size() {
    local base_branch="${1:-${NIGHTSHIFT_BASE_BRANCH:-main}}"
    local max_files="${NIGHTSHIFT_MAX_PR_FILES:-20}"
    local max_lines="${NIGHTSHIFT_MAX_PR_LINES:-5000}"
    local files_changed=0
    local lines_added=0

    _git_log "Checking PR size against ${base_branch}... (limits: files=${max_files}, lines=${max_lines})"

    local diff_numstat diff_exit
    diff_numstat=$(LC_ALL=C git diff --numstat "${base_branch}...HEAD" 2>&1)
    diff_exit=$?

    if [[ "$diff_exit" -ne 0 ]]; then
        _git_log "CRITICAL: LC_ALL=C git diff --numstat failed (exit=$diff_exit) — cannot determine PR size"
        return 1
    fi

    if [[ -n "$diff_numstat" ]]; then
        local added deleted path extra
        while IFS=$'\t' read -r added deleted path extra; do
            if [[ -z "${added}${deleted}${path}${extra}" ]]; then
                continue
            fi

            if [[ -n "$extra" ]] || [[ -z "$path" ]]; then
                _git_log "CRITICAL: Could not parse git diff --numstat row: ${added}\t${deleted}\t${path}\t${extra}"
                return 1
            fi

            if [[ "$added" == "-" ]] || [[ "$deleted" == "-" ]]; then
                _git_log "CRITICAL: Binary diff entry encountered for '${path}' — aborting on ambiguous PR size"
                return 1
            fi

            if ! [[ "$added" =~ ^[0-9]+$ ]] || ! [[ "$deleted" =~ ^[0-9]+$ ]]; then
                _git_log "CRITICAL: Non-numeric git diff --numstat row for '${path}' — added='${added}' deleted='${deleted}'"
                return 1
            fi

            (( files_changed += 1 ))
            (( lines_added += added ))
        done <<< "$diff_numstat"
    fi

    _git_log "PR size: files_changed=${files_changed}, lines_added=${lines_added}"

    local failed=0

    if (( files_changed > max_files )); then
        _git_log "CRITICAL: Files changed (${files_changed}) exceeds limit (${max_files})"
        failed=1
    fi

    if (( lines_added > max_lines )); then
        _git_log "CRITICAL: Lines added (${lines_added}) exceeds limit (${max_lines})"
        failed=1
    fi

    if [[ "$failed" -eq 1 ]]; then
        return 1
    fi

    _git_log "OK: PR size within limits"
    return 0
}

# Create a dated nightshift branch. Never clobbers existing branches.
# Usage: git_create_branch <date_string>
# Prints the created branch name to stdout.
# Returns: 0 = created, 1 = failed.
git_create_branch() {
    local date_str="${1:-}"

    if [[ -z "$date_str" ]]; then
        _git_log "CRITICAL: No date string provided to git_create_branch"
        return 1
    fi

    local base_name="nightshift/${date_str}"
    local branch_name="$base_name"

    # Delete local branch from a prior run if it exists (we are on detached HEAD)
    if git rev-parse --verify --quiet "refs/heads/${branch_name}" >/dev/null 2>&1; then
        _git_log "Branch '$branch_name' already exists locally — deleting prior branch"
        git branch -D "$branch_name" >/dev/null 2>&1 || true
    fi

    _git_log "Creating branch: ${branch_name}"

    local output
    output=$(git checkout -b "$branch_name" 2>&1)
    local exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        _git_log "CRITICAL: Failed to create branch '${branch_name}' — git exit=$exit_code output: ${output}"
        return 1
    fi

    _git_log "OK: Created and switched to branch '${branch_name}'"
    echo "$branch_name"
    return 0
}

# Validate that we're in a git repo and can reach origin.
# Does NOT check the current branch — the orchestrator calls this during
# Phase 1 setup while still on main, before git_create_branch switches
# to a nightshift branch.
# Returns: 0 = safe to proceed, 1 = not in a git repo or cannot reach origin.
git_safety_preflight() {
    _git_log "Starting git safety preflight..."

    # Check we're inside a git repo
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        _git_log "CRITICAL: Not inside a git working tree"
        return 1
    fi
    _git_log "OK: Inside a git working tree"

    # Check we can reach origin
    local remote_output
    remote_output=$(git ls-remote --exit-code origin HEAD 2>&1)
    local remote_exit=$?

    if [[ "$remote_exit" -ne 0 ]]; then
        _git_log "CRITICAL: Cannot reach git origin (exit=$remote_exit) — output: ${remote_output}"
        return 1
    fi
    _git_log "OK: Origin is reachable"

    _git_log "OK: All git safety checks passed"
    return 0
}

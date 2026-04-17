#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-merge-guards.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
LAUREN_LOOP_V2_MERGE_LOCK_FILE="$TMP_ROOT/lauren-loop-v2-merge.lock"

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
    [[ -n "${2:-}" ]] && echo "  Detail: $2"
}

write_task_fixture() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
## Task: merge-guard-test
## Status: in progress
## Goal: Exercise Lauren Loop merge-guard behavior

## Current Plan
Plan body

## Critique
Critique body

## Review Findings

## Plan History

## Execution Log
EOF
}

write_status_artifact() {
    local path="$1" status="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
# Status Artifact

## Final Status

**STATUS:** ${status}
**Remaining findings:** None
**Follow-up:** None
EOF
    printf '{"status":"%s"}\n' "$status" > "${path%.*}.contract.json"
}

write_fix_execution_artifact() {
    write_status_artifact "$1" "$2"
}

write_final_fix_artifact() {
    write_status_artifact "$1" "$2"
}

write_human_review_handoff_artifact() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'EOF'
# Human Review Handoff

**Final review verdict:** BLOCKED
EOF
}

write_epoch_ms() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

setup_merge_fixture() {
    local name="$1" slug="$2" layout="$3"
    local root="$TMP_ROOT/$name"
    local task_file=""
    local task_dir=""

    case "$layout" in
        dir)
            task_dir="$root/docs/tasks/open/$slug"
            task_file="$task_dir/task.md"
            ;;
        flat-lauren-loop)
            task_dir="$root/docs/tasks/open/lauren-loop/$slug"
            task_file="$root/docs/tasks/open/lauren-loop/${slug}.md"
            ;;
        *)
            echo "unknown fixture layout: $layout" >&2
            return 1
            ;;
    esac

    mkdir -p "$task_dir/competitive" "$task_dir/logs"
    write_task_fixture "$task_file"
    printf 'base\n' > "$root/app.txt"

    git -C "$root" init -q
    git -C "$root" config user.name "Lauren Loop Merge Tests"
    git -C "$root" config user.email "lauren-loop-merge-tests@example.com"
    git -C "$root" add .
    git -C "$root" commit -q -m "Initial fixture"

    printf '%s\t%s\t%s\n' "$root" "$task_file" "$task_dir"
}

configure_merge_fixture() {
    local root="$1" slug="$2" task_file="$3" task_dir="$4"
    SCRIPT_DIR="$root"
    cd "$root"
    SLUG="$slug"
    _CURRENT_TASK_FILE="$task_file"
    TASK_LOG_DIR="$task_dir/logs"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""
    _V2_EXEC_TARGET_REF=""
    _V2_EXEC_TARGET_HEAD_SHA=""
    _V2_LAST_MERGE_RECOVERABLE=false
}

cleanup_preserved_execution_state() {
    local root="$1"
    local preserved_path="${_V2_PRESERVED_EXEC_WORKTREE_PATH:-}"
    local preserved_branch="${_V2_PRESERVED_EXEC_WORKTREE_BRANCH:-}"

    if [[ -n "$preserved_path" && -d "$preserved_path" ]]; then
        git -C "$root" worktree remove "$preserved_path" --force >/dev/null 2>&1 || rm -rf "$preserved_path"
    fi
    if [[ -n "$preserved_branch" ]]; then
        git -C "$root" branch -D "$preserved_branch" >/dev/null 2>&1 || true
    fi
}

source "$REPO_ROOT/lib/lauren-loop-utils.sh"

SCRIPT_DIR="$REPO_ROOT"
LAUREN_LOOP_V2_MERGE_LOCK_TIMEOUT_SEC=5
eval "$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "preflight-allowed-flat" "preflight-allowed-flat" "flat-lauren-loop")
    configure_merge_fixture "$root" "preflight-allowed-flat" "$task_file" "$task_dir"

    printf '\nresume note\n' >> "$task_file"
    printf '{"run_id":"r1"}\n' > "$task_dir/competitive/run-manifest.json"
    printf '{"fix_cycle":0,"last_completed":"phase-6b","timestamp":"2026-04-10T00:00:00Z"}\n' > "$task_dir/competitive/.cycle-state.json"
    printf 'diff --git a/app.txt b/app.txt\n' > "$task_dir/competitive/execution-diff.patch"
    printf '1\t1\tapp.txt\n' > "$task_dir/competitive/execution-diff.numstat.tsv"
    printf 'diff --git a/app.txt b/app.txt\n' > "$task_dir/competitive/fix-diff-cycle1.patch"
    printf '1\t1\tapp.txt\n' > "$task_dir/competitive/fix-diff-cycle1.numstat.tsv"
    printf '1\t1\tapp.txt\n' > "$task_dir/competitive/fix-diff-cycle1.estimate.numstat.tsv"
    printf '{"summary_text":"ok"}\n' > "$task_dir/competitive/traditional-dev-proxy.json"
    printf '%s\n' "$COST_CSV_HEADER" > "$task_dir/logs/cost.csv"
    printf 'executor log\n' > "$task_dir/logs/executor.log"
    printf 'codex summary\n' > "$task_dir/logs/executor.summary.txt"

    _v2_create_execution_worktree || exit 1
    printf 'merged change\n' > "$_V2_EXEC_WORKTREE_PATH/app.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add app.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Worktree code change"

    _v2_merge_execution_worktree || exit 1
    grep -Fq 'merged change' "$root/app.txt" || exit 1
) && pass "1. merge preflight allows expected dirty root files, including nested flat task paths and diff/proxy artifacts" \
  || fail "1. merge preflight allows expected dirty root files, including nested flat task paths and diff/proxy artifacts"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "preflight-unexpected" "preflight-unexpected" "dir")
    configure_merge_fixture "$root" "preflight-unexpected" "$task_file" "$task_dir"

    _v2_create_execution_worktree || exit 1
    printf 'worktree merge candidate\n' > "$_V2_EXEC_WORKTREE_PATH/app.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add app.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Worktree merge candidate"
    wt_commit=$(git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse HEAD)

    printf 'unexpected root copy\n' > "$task_dir/competitive/fix-execution.md"
    output_file="$TMP_ROOT/preflight-unexpected.out"

    set +e
    _v2_merge_execution_worktree >"$output_file" 2>&1
    rc=$?
    set -e
    output="$(cat "$output_file")"

    [[ "$rc" -ne 0 ]] || exit 1
    printf '%s\n' "$output" | grep -Fq 'ERROR: unexpected dirty files in root checkout before merge:'
    printf '%s\n' "$output" | grep -Fq "docs/tasks/open/preflight-unexpected/competitive/fix-execution.md"
    printf '%s\n' "$output" | grep -Fq 'Dirty-root merge preflight blocked merge-back; preserving recoverable execution worktree state'
    printf '%s\n' "$output" | grep -Fq 'Recoverable merge failure'
    grep -Fq 'base' "$root/app.txt" || exit 1
    [[ "$_V2_LAST_MERGE_RECOVERABLE" == true ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_BRANCH" ]] || exit 1
    [[ "$_V2_PRESERVED_EXEC_COMMIT_SHA" == "$wt_commit" ]] || exit 1
    [[ -n "$_V2_PRESERVED_EXEC_WORKTREE_PATH" && -d "$_V2_PRESERVED_EXEC_WORKTREE_PATH" ]] || exit 1
    git -C "$root" branch --list "$_V2_PRESERVED_EXEC_WORKTREE_BRANCH" | grep -q . || exit 1

    cleanup_preserved_execution_state "$root"
) && pass "2. dirty-root preflight preserves recoverable execution state when unexpected root dirtiness blocks merge" \
  || fail "2. dirty-root preflight preserves recoverable execution state when unexpected root dirtiness blocks merge"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "preexisting-pipeline-noise" "preexisting-pipeline-noise" "dir")
    configure_merge_fixture "$root" "preexisting-pipeline-noise" "$task_file" "$task_dir"

    printf '# Exploration Summary\n' > "$task_dir/competitive/exploration-summary.md"
    printf '# Plan A\n' > "$task_dir/competitive/plan-a.md"

    _v2_create_execution_worktree || exit 1
    _v2_capture_preexisting_pipeline_owned_root_dirty "$(_v2_snapshot_dirty_files)"
    printf 'merge with preexisting pipeline artifacts\n' > "$_V2_EXEC_WORKTREE_PATH/app.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add app.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Worktree merge with preexisting pipeline artifacts"

    _v2_merge_execution_worktree || exit 1
    grep -Fq 'merge with preexisting pipeline artifacts' "$root/app.txt" || exit 1
) && pass "3. pre-existing pipeline-owned task artifacts do not block merge-back" \
  || fail "3. pre-existing pipeline-owned task artifacts do not block merge-back"

(
    lock_file="$TMP_ROOT/global-merge.lock"
    first_acquired="$TMP_ROOT/first-acquired.txt"
    second_acquired="$TMP_ROOT/second-acquired.txt"

    (
        fd=""
        _v2_acquire_global_merge_lock fd "$lock_file" 5 || exit 1
        write_epoch_ms > "$first_acquired"
        sleep 2
        _v2_release_merge_lock_fd "$fd"
    ) &
    pid_first=$!

    sleep 0.2

    (
        fd=""
        _v2_acquire_global_merge_lock fd "$lock_file" 5 || exit 1
        write_epoch_ms > "$second_acquired"
        _v2_release_merge_lock_fd "$fd"
    ) &
    pid_second=$!

    wait "$pid_first"
    wait "$pid_second"

    first_ts="$(cat "$first_acquired")"
    second_ts="$(cat "$second_acquired")"
    (( second_ts - first_ts >= 1500 ))
 ) && pass "4. global merge lock serializes concurrent acquirers and lets the second proceed after release" \
  || fail "4. global merge lock serializes concurrent acquirers and lets the second proceed after release"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "post-merge-sync" "post-merge-sync" "dir")
    configure_merge_fixture "$root" "post-merge-sync" "$task_file" "$task_dir"

    _v2_create_execution_worktree || exit 1
    printf 'post-merge code change\n' > "$_V2_EXEC_WORKTREE_PATH/app.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add app.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Code change for post-merge sync"
    write_fix_execution_artifact "$_V2_EXEC_WORKTREE_PATH/docs/tasks/open/post-merge-sync/competitive/fix-execution.md" "COMPLETE"

    _v2_merge_execution_worktree \
        "$task_dir/competitive/fix-execution.md" \
        "$task_dir/competitive/fix-execution.contract.json" || exit 1

    grep -Fq 'post-merge code change' "$root/app.txt" || exit 1
    grep -Fq '**STATUS:** COMPLETE' "$task_dir/competitive/fix-execution.md" || exit 1
    grep -Fq '"status":"COMPLETE"' "$task_dir/competitive/fix-execution.contract.json" || exit 1
) && pass "5. post-merge sync copies fresh competitive artifacts into root after a successful merge" \
  || fail "5. post-merge sync copies fresh competitive artifacts into root after a successful merge"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "phase7-blocked-halt" "phase7-blocked-halt" "dir")
    configure_merge_fixture "$root" "phase7-blocked-halt" "$task_file" "$task_dir"

    comp_dir="$task_dir/competitive"
    _v2_create_execution_worktree || exit 1
    worktree_path="$_V2_EXEC_WORKTREE_PATH"
    worktree_fix_execution="$worktree_path/docs/tasks/open/phase7-blocked-halt/competitive/fix-execution.md"

    printf 'partial halt-only code edit\n' > "$worktree_path/app.txt"
    write_fix_execution_artifact "$worktree_fix_execution" "BLOCKED"
    printf '# Review Synthesis\n' > "$comp_dir/review-synthesis.md"
    write_human_review_handoff_artifact "$comp_dir/human-review-handoff.md"
    write_fix_execution_artifact "$comp_dir/fix-execution.md" "COMPLETE"

    _mark_fix_execution_handoff "$worktree_fix_execution" || exit 1
    _v2_finalize_halt_without_merge \
        "$comp_dir/fix-execution.md" \
        "$comp_dir/fix-execution.contract.json" || exit 1

    grep -Fq 'base' "$root/app.txt" || exit 1
    ! grep -Fq 'partial halt-only code edit' "$root/app.txt" || exit 1
    grep -Fq '**STATUS:** BLOCKED' "$comp_dir/fix-execution.md" || exit 1
    grep -Fq '**Remaining findings:** See ' "$comp_dir/fix-execution.md" || exit 1
    grep -Fq 'review-synthesis.md' "$comp_dir/fix-execution.md" || exit 1
    grep -Fq 'human-review-handoff.md' "$comp_dir/fix-execution.md" || exit 1
    grep -Fq '**Follow-up:** Human review required before any further fix planning or task closeout.' "$comp_dir/fix-execution.md" || exit 1
    grep -Fq '"status":"BLOCKED"' "$comp_dir/fix-execution.contract.json" || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ ! -d "$worktree_path" ]] || exit 1
) && pass "6. phase 7 BLOCKED halt syncs annotated fix-execution artifacts without merging partial code edits" \
  || fail "6. phase 7 BLOCKED halt syncs annotated fix-execution artifacts without merging partial code edits"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "phase8c-blocked-halt" "phase8c-blocked-halt" "dir")
    configure_merge_fixture "$root" "phase8c-blocked-halt" "$task_file" "$task_dir"

    comp_dir="$task_dir/competitive"
    _v2_create_execution_worktree || exit 1
    worktree_path="$_V2_EXEC_WORKTREE_PATH"

    printf 'partial final-fix-only code edit\n' > "$worktree_path/app.txt"
    write_final_fix_artifact "$worktree_path/docs/tasks/open/phase8c-blocked-halt/competitive/final-fix.md" "BLOCKED"
    write_final_fix_artifact "$comp_dir/final-fix.md" "COMPLETE"

    _v2_finalize_halt_without_merge \
        "$comp_dir/final-fix.md" \
        "$comp_dir/final-fix.contract.json" || exit 1

    grep -Fq 'base' "$root/app.txt" || exit 1
    ! grep -Fq 'partial final-fix-only code edit' "$root/app.txt" || exit 1
    grep -Fq '**STATUS:** BLOCKED' "$comp_dir/final-fix.md" || exit 1
    grep -Fq '"status":"BLOCKED"' "$comp_dir/final-fix.contract.json" || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ ! -d "$worktree_path" ]] || exit 1
) && pass "7. phase 8c BLOCKED halt syncs final-fix artifacts without merging partial code edits" \
  || fail "7. phase 8c BLOCKED halt syncs final-fix artifacts without merging partial code edits"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "halt-missing-sync-target" "halt-missing-sync-target" "dir")
    configure_merge_fixture "$root" "halt-missing-sync-target" "$task_file" "$task_dir"

    comp_dir="$task_dir/competitive"
    _v2_create_execution_worktree || exit 1
    worktree_path="$_V2_EXEC_WORKTREE_PATH"

    write_fix_execution_artifact "$worktree_path/docs/tasks/open/halt-missing-sync-target/competitive/fix-execution.md" "BLOCKED"

    _v2_finalize_halt_without_merge \
        "$comp_dir/does-not-exist.md" \
        "$comp_dir/fix-execution.md" \
        "$comp_dir/fix-execution.contract.json" || exit 1

    [[ ! -e "$comp_dir/does-not-exist.md" ]] || exit 1
    grep -Fq '**STATUS:** BLOCKED' "$comp_dir/fix-execution.md" || exit 1
    grep -Fq '"status":"BLOCKED"' "$comp_dir/fix-execution.contract.json" || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
    [[ ! -d "$worktree_path" ]] || exit 1
) && pass "8. halt artifact sync skips missing worktree targets without crashing" \
  || fail "8. halt artifact sync skips missing worktree targets without crashing"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "preflight-missing-task-file" "preflight-missing-task-file" "dir")
    configure_merge_fixture "$root" "preflight-missing-task-file" "$task_file" "$task_dir"

    _v2_create_execution_worktree || exit 1
    printf 'worktree merge candidate\n' > "$_V2_EXEC_WORKTREE_PATH/app.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add app.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Worktree merge candidate"
    _CURRENT_TASK_FILE=""
    output_file="$TMP_ROOT/preflight-missing-task-file.out"

    set +e
    _v2_merge_execution_worktree >"$output_file" 2>&1
    rc=$?
    set -e
    output="$(cat "$output_file")"

    [[ "$rc" -ne 0 ]] || exit 1
    printf '%s\n' "$output" | grep -Fq 'ERROR: cannot run merge preflight without _CURRENT_TASK_FILE set to the active task file.'
    grep -Fq 'base' "$root/app.txt" || exit 1

    _v2_cleanup_execution_worktree || true
) && pass "9. merge preflight fails clearly when _CURRENT_TASK_FILE is unset" \
  || fail "9. merge preflight fails clearly when _CURRENT_TASK_FILE is unset"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "drift-rebase-success" "drift-rebase-success" "dir")
    configure_merge_fixture "$root" "drift-rebase-success" "$task_file" "$task_dir"

    _v2_create_execution_worktree || exit 1
    printf 'worktree drift change\n' > "$_V2_EXEC_WORKTREE_PATH/worktree-only.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add worktree-only.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Worktree drift change"

    printf 'root branch advance\n' > "$root/root-only.txt"
    git -C "$root" add root-only.txt
    git -C "$root" commit -q -m "Root branch advance"
    output_file="$TMP_ROOT/drift-rebase-success.out"

    set +e
    _v2_merge_execution_worktree >"$output_file" 2>&1
    rc=$?
    set -e
    output="$(cat "$output_file")"

    [[ "$rc" -eq 0 ]] || exit 1
    printf '%s\n' "$output" | grep -Fq 'Execution target drift detected for'
    printf '%s\n' "$output" | grep -Fq 'Rebasing execution worktree branch'
    printf '%s\n' "$output" | grep -Fq 'Rebased execution worktree branch'
    grep -Fq 'worktree drift change' "$root/worktree-only.txt" || exit 1
    grep -Fq 'root branch advance' "$root/root-only.txt" || exit 1
    set -- $(git -C "$root" rev-list --parents -n 1 HEAD)
    [[ "$#" -eq 2 ]] || exit 1
    [[ "$_V2_LAST_MERGE_RECOVERABLE" == false ]] || exit 1
    [[ -z "$_V2_EXEC_WORKTREE_PATH" ]] || exit 1
) && pass "10. target drift logs divergence, rebases the execution branch, and fast-forwards merge-back" \
  || fail "10. target drift logs divergence, rebases the execution branch, and fast-forwards merge-back"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "drift-rebase-conflict" "drift-rebase-conflict" "dir")
    configure_merge_fixture "$root" "drift-rebase-conflict" "$task_file" "$task_dir"

    printf 'shared base\n' > "$root/conflict.txt"
    git -C "$root" add conflict.txt
    git -C "$root" commit -q -m "Shared conflict base"

    _v2_create_execution_worktree || exit 1
    printf 'worktree side\n' > "$_V2_EXEC_WORKTREE_PATH/conflict.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add conflict.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Worktree conflict"
    wt_commit=$(git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse HEAD)

    printf 'root side\n' > "$root/conflict.txt"
    git -C "$root" add conflict.txt
    git -C "$root" commit -q -m "Root conflict"
    output_file="$TMP_ROOT/drift-rebase-conflict.out"

    set +e
    _v2_merge_execution_worktree >"$output_file" 2>&1
    rc=$?
    set -e
    output="$(cat "$output_file")"

    [[ "$rc" -ne 0 ]] || exit 1
    printf '%s\n' "$output" | grep -Fq 'Execution target drift detected for'
    printf '%s\n' "$output" | grep -Fq 'Rebasing execution worktree branch'
    printf '%s\n' "$output" | grep -Fq 'Rebase-based merge preparation failed'
    printf '%s\n' "$output" | grep -Fq 'Recoverable merge failure'
    grep -Fq 'root side' "$root/conflict.txt" || exit 1
    [[ "$_V2_LAST_MERGE_RECOVERABLE" == true ]] || exit 1
    [[ "$_V2_PRESERVED_EXEC_COMMIT_SHA" == "$wt_commit" ]] || exit 1
    [[ -n "$_V2_PRESERVED_EXEC_WORKTREE_PATH" && -d "$_V2_PRESERVED_EXEC_WORKTREE_PATH" ]] || exit 1
    git -C "$root" branch --list "$_V2_PRESERVED_EXEC_WORKTREE_BRANCH" | grep -q . || exit 1
    ! git -C "$_V2_PRESERVED_EXEC_WORKTREE_PATH" rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1 || exit 1

    cleanup_preserved_execution_state "$root"
) && pass "11. conflicting target drift aborts rebase and preserves recoverable execution state" \
  || fail "11. conflicting target drift aborts rebase and preserves recoverable execution state"

(
    IFS=$'\t' read -r root task_file task_dir < <(setup_merge_fixture "no-drift-baseline" "no-drift-baseline" "dir")
    configure_merge_fixture "$root" "no-drift-baseline" "$task_file" "$task_dir"

    _v2_create_execution_worktree || exit 1
    printf 'baseline merge change\n' > "$_V2_EXEC_WORKTREE_PATH/no-drift.txt"
    git -C "$_V2_EXEC_WORKTREE_PATH" add no-drift.txt
    git -C "$_V2_EXEC_WORKTREE_PATH" commit -q -m "Baseline merge change"
    output_file="$TMP_ROOT/no-drift-baseline.out"

    set +e
    _v2_merge_execution_worktree >"$output_file" 2>&1
    rc=$?
    set -e
    output="$(cat "$output_file")"

    [[ "$rc" -eq 0 ]] || exit 1
    grep -Fq 'baseline merge change' "$root/no-drift.txt" || exit 1
    ! printf '%s\n' "$output" | grep -Fq 'Execution target drift detected for' || exit 1
    ! printf '%s\n' "$output" | grep -Fq 'Rebasing execution worktree branch' || exit 1
) && pass "12. no-drift merge path keeps the baseline merge behavior without drift logs or rebase" \
  || fail "12. no-drift merge path keeps the baseline merge behavior without drift logs or rebase"

echo ""
echo "============================="
echo "$PASSED/$TOTAL passed"
if [[ "$FAILED" -gt 0 ]]; then
    echo "$FAILED FAILED"
    exit 1
fi
echo "============================="

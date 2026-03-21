#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-v2-scope.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASSED=0
FAILED=0
TOTAL=0
TEST_LOG_FILE=""

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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

write_task_file() {
    local task_file="$1"
    local slug="$2"
    local include_relevant="${3:-yes}"

    cat > "$task_file" <<EOF
## Task: ${slug}
## Status: in progress
## Goal: Exercise V2 scope helpers
EOF

    if [[ "$include_relevant" == "yes" ]]; then
        cat >> "$task_file" <<'EOF'

## Relevant Files:
- `src/in_scope.py` - in-scope code path
- `tests/test_in_scope.py` - in-scope test path
EOF
    fi

    cat >> "$task_file" <<'EOF'

## Current Plan

## Execution Log
EOF
}

write_revised_plan_default() {
    local plan_file="$1"
    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in_scope.py` | Update implementation |
| `tests/test_in_scope.py` | Add verification |
EOF
}

setup_scope_repo() {
    local name="$1"
    local include_relevant="${2:-yes}"
    local slug="${3:-scope-task}"
    local root="$TMP_ROOT/$name"
    local task_dir="$root/docs/tasks/open/$slug"

    mkdir -p "$task_dir/competitive" "$task_dir/logs" "$root/src" "$root/docs" "$root/tests"
    write_task_file "$task_dir/task.md" "$slug" "$include_relevant"
    write_revised_plan_default "$task_dir/competitive/revised-plan.md"

    git -C "$root" init -q
    git -C "$root" config user.email "codex@example.com"
    git -C "$root" config user.name "Codex"
    printf 'baseline\n' > "$root/src/in_scope.py"
    printf 'baseline\n' > "$root/docs/out_of_scope.md"
    printf 'baseline\n' > "$root/tests/test_in_scope.py"
    git -C "$root" add .
    git -C "$root" commit -q -m "baseline"
    printf '%s\n' "$root"
}

reset_test_log() {
    TEST_LOG_FILE="$TMP_ROOT/log.$RANDOM.$RANDOM"
    : > "$TEST_LOG_FILE"
}

git_commit_all() {
    local repo_root="$1"
    local message="$2"
    git -C "$repo_root" add -A
    git -C "$repo_root" commit -q -m "$message"
}

source "$REPO_ROOT/lib/lauren-loop-utils.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
eval "$(
    sed -n '/^## Pricing constants/,/^usage()/{ /^usage()/d; p; }' "$REPO_ROOT/lauren-loop-v2.sh" \
        | sed '/^source "\$HOME\/\.claude\/scripts\/context-guard\.sh"$/d' \
        | sed '/^source "\$SCRIPT_DIR\/lib\/lauren-loop-utils\.sh"$/d'
)"

set_task_status() { :; }
log_execution() {
    if [[ -n "${TEST_LOG_FILE:-}" ]]; then
        printf '%s\n' "$2" >> "$TEST_LOG_FILE"
    fi
}
_print_cost_summary() { :; }

prime_scope_triage_env() {
    local repo_root="$1"
    local task_dir="$2"
    scope_triage_prompt="$REPO_ROOT/prompts/scope-triage.md"
    ENGINE_EVALUATOR="claude"
    EVALUATE_TIMEOUT="1m"
    log_dir="$task_dir/logs"
    mkdir -p "$log_dir"
}

scope_triage_state_record_field() {
    local state_file="$1"
    local section="$2"
    local file_path="$3"
    local field="$4"
    python3 - "$state_file" "$section" "$file_path" "$field" <<'PY'
import json
import sys

state_file, section, file_path, field = sys.argv[1:5]
with open(state_file, encoding="utf-8") as fh:
    data = json.load(fh)

for item in data.get(section, []):
    if isinstance(item, dict) and item.get("file") == file_path:
        value = item.get(field)
        if isinstance(value, str):
            print(value)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

(
    repo_root="$(setup_scope_repo diff-scoped)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    printf 'changed in scope\n' > "$repo_root/src/in_scope.py"
    printf 'changed out of scope\n' > "$repo_root/docs/out_of_scope.md"

    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
    cd "$cwd"

    grep -q 'src/in_scope.py' "$diff_file"
    ! grep -q 'docs/out_of_scope.md' "$diff_file"
    [[ "$_V2_LAST_CAPTURE_SCOPE_SOURCE" == "plan-files-to-modify" ]]
) && pass "1. capture_diff_artifact scopes patch to Files to Modify" \
  || fail "1. capture_diff_artifact scopes patch to Files to Modify"

(
    repo_root="$(setup_scope_repo diff-ignore)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    printf 'changed out of scope only\n' > "$repo_root/docs/out_of_scope.md"

    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
    cd "$cwd"

    [[ ! -s "$diff_file" ]]
    [[ -z "${_V2_LAST_CAPTURED_FILES:-}" ]]
) && pass "2. capture_diff_artifact ignores out-of-scope tracked diffs" \
  || fail "2. capture_diff_artifact ignores out-of-scope tracked diffs"

(
    repo_root="$(setup_scope_repo untracked-in-scope)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"

    printf 'new file\n' > "$repo_root/src/in_scope.py.new"
    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in_scope.py.new` | Add new implementation file |
EOF

    (
        cd "$repo_root"
        output=$(_collect_blocking_untracked_files "$task_file" "$plan_file")
        [[ "$output" == "src/in_scope.py.new" ]]
        ! _block_on_untracked_files "$task_file" "Phase 7" "$plan_file" >/dev/null 2>&1
    )
) && pass "3. untracked files inside scope are blocked" \
  || fail "3. untracked files inside scope are blocked"

(
    repo_root="$(setup_scope_repo untracked-out-of-scope)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"

    mkdir -p "$repo_root/.playwright-cli"
    printf 'noise\n' > "$repo_root/.playwright-cli/noise.yml"
    printf 'unrelated\n' > "$repo_root/docs/unrelated.txt"

    (
        cd "$repo_root"
        output=$(_collect_blocking_untracked_files "$task_file" "$plan_file")
        [[ -z "$output" ]]
        _block_on_untracked_files "$task_file" "Phase 4" "$plan_file"
    )
) && pass "4. untracked files outside scope are ignored" \
  || fail "4. untracked files outside scope are ignored"

(
    repo_root="$(setup_scope_repo directory-slash)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    mkdir -p "$repo_root/src/utils"
    printf 'baseline\n' > "$repo_root/src/utils/helper.sh"
    git_commit_all "$repo_root" "add helper"
    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/utils/` | Update utility directory |
EOF
    printf 'changed helper\n' > "$repo_root/src/utils/helper.sh"

    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
    cd "$cwd"

    grep -q 'src/utils/helper.sh' "$diff_file"
) && pass "5. trailing-slash directory entries include child paths" \
  || fail "5. trailing-slash directory entries include child paths"

(
    repo_root="$(setup_scope_repo directory-bare)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    mkdir -p "$repo_root/src/utils"
    printf 'baseline\n' > "$repo_root/src/utils/helper.sh"
    git_commit_all "$repo_root" "add helper"
    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/utils` | Intentionally bare directory-like entry |
EOF
    printf 'changed helper\n' > "$repo_root/src/utils/helper.sh"

    reset_test_log
    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
    _v2_log_capture_scope_details "$task_file" "Phase 4"
    cd "$cwd"

    [[ ! -s "$diff_file" ]]
    grep -q "scope note: Directory scope requires trailing /; bare entries are exact-match only." "$TEST_LOG_FILE"
) && pass "6. bare directory-like entries stay exact-only and log the convention" \
  || fail "6. bare directory-like entries stay exact-only and log the convention"

(
    repo_root="$(setup_scope_repo out-of-scope-warning)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in.py` | Update in-scope file |
EOF
    printf 'baseline\n' > "$repo_root/src/in.py"
    printf 'baseline\n' > "$repo_root/docs/out.md"
    git_commit_all "$repo_root" "add in file"
    printf 'changed in scope\n' > "$repo_root/src/in.py"
    printf 'changed out of scope\n' > "$repo_root/docs/out.md"

    reset_test_log
    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
    _v2_log_capture_scope_details "$task_file" "Phase 4"
    _v2_log_out_of_scope_capture_warning "$task_file" "Phase 4" >/dev/null
    cd "$cwd"

    [[ "$_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES" == "docs/out.md" ]]
    grep -q "Phase 4: WARNING diff scope check reported out-of-scope changes" "$TEST_LOG_FILE"
    grep -q "out-of-scope diff file: docs/out.md" "$TEST_LOG_FILE"
) && pass "7. out-of-scope tracked changes are warned and listed" \
  || fail "7. out-of-scope tracked changes are warned and listed"

(
    repo_root="$(setup_scope_repo fallback-commit-range no)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/missing-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"
    baseline_sha=$(git -C "$repo_root" rev-parse HEAD)

    printf 'baseline\n' > "$repo_root/src/fallback.py"
    git_commit_all "$repo_root" "add fallback file"

    reset_test_log
    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "$baseline_sha" "$diff_file" "$task_file" "$plan_file"
    _v2_log_capture_scope_details "$task_file" "Phase 4"
    cd "$cwd"

    [[ "$_V2_LAST_CAPTURE_SCOPE_SOURCE" == "fallback-commit-range" ]]
    grep -q 'src/fallback.py' "$diff_file"
    grep -q "Scope unresolved — falling back to committed changes since the pre-phase baseline." "$TEST_LOG_FILE"
) && pass "8. missing declarative scope falls back to commit-range touched files" \
  || fail "8. missing declarative scope falls back to commit-range touched files"

(
    repo_root="$(setup_scope_repo fallback-empty no)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/missing-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    printf 'preexisting dirty tracked\n' > "$repo_root/docs/out_of_scope.md"
    printf 'preexisting dirty untracked\n' > "$repo_root/docs/preexisting-untracked.md"

    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
    blocking=$(_collect_blocking_untracked_files "$task_file" "$plan_file" "HEAD")
    cd "$cwd"

    [[ "$_V2_LAST_CAPTURE_SCOPE_SOURCE" == "fallback-commit-range-empty" ]]
    [[ ! -s "$diff_file" ]]
    [[ -z "${_V2_LAST_CAPTURE_ALL_FILES:-}" ]]
    [[ -z "$blocking" ]]
    [[ -z "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" ]]
) && pass "9. empty commit-range fallback stays constrained and ignores preexisting dirty files" \
  || fail "9. empty commit-range fallback stays constrained and ignores preexisting dirty files"

(
    repo_root="$(setup_scope_repo phase7-fix-plan)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    comp_dir="$repo_root/docs/tasks/open/$slug/competitive"
    diff_file="$comp_dir/fix-diff-cycle1.patch"

    printf 'baseline\n' > "$repo_root/docs/fix_only.py"
    git_commit_all "$repo_root" "add fix-plan file"
    cat > "$comp_dir/revised-plan.md" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in_scope.py` | Original plan scope |
EOF
    cat > "$comp_dir/fix-plan.md" <<'EOF'
# Fix Plan

## Implementation Tasks

```xml
<wave number="1">
  <task type="auto">
    <name>Use fix plan scope</name>
    <files>docs/fix_only.py</files>
    <action>Update the fix-only file.</action>
    <verify>bash tests/test_lauren_loop_v2_scope.sh</verify>
    <done>Updated.</done>
  </task>
</wave>
```
EOF
    printf 'changed by fix plan\n' > "$repo_root/docs/fix_only.py"

    cwd="$PWD"
    cd "$repo_root"
    selected_plan=$(_v2_select_phase7_scope_plan_file "$comp_dir")
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$selected_plan"
    cd "$cwd"

    [[ "$selected_plan" == "$comp_dir/fix-plan.md" ]]
    [[ "$_V2_LAST_CAPTURE_SCOPE_SOURCE" == "plan-xml-files" ]]
    grep -q 'docs/fix_only.py' "$diff_file"
) && pass "10. Phase 7 prefers fix-plan XML files over revised-plan scope" \
  || fail "10. Phase 7 prefers fix-plan XML files over revised-plan scope"

(
    repo_root="$(setup_scope_repo empty-plan-fallback no)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"
    baseline_sha=$(git -C "$repo_root" rev-parse HEAD)

    cat > "$plan_file" <<'EOF'
# Revised Plan

## Notes
This file intentionally has no parseable scope entries.
EOF
    printf 'baseline\n' > "$repo_root/src/from_empty_plan.py"
    git_commit_all "$repo_root" "add file after empty plan"

    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "$baseline_sha" "$diff_file" "$task_file" "$plan_file"
    cd "$cwd"

    [[ "$_V2_LAST_CAPTURE_SCOPE_SOURCE" == "fallback-commit-range" ]]
    grep -q 'src/from_empty_plan.py' "$diff_file"
) && pass "11. empty revised-plan content triggers constrained fallback" \
  || fail "11. empty revised-plan content triggers constrained fallback"

# ---------- Test 12: all scope sources empty — no repo-wide fallback ----------
(
    repo_root="$(setup_scope_repo all-sources-empty no)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    # Overwrite default plan with one that has NO parseable scope entries and NO XML
    cat > "$plan_file" <<'PLAN'
# Revised Plan

## Overview
This plan intentionally contains no Files to Modify section and no XML files tags.
PLAN

    # Add dirty tracked + untracked files (must NOT appear in results)
    printf 'dirty tracked change\n' > "$repo_root/docs/out_of_scope.md"
    printf 'dirty untracked file\n' > "$repo_root/src/untracked_new.py"

    cwd="$PWD"
    cd "$repo_root"
    capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
    blocking=$(_collect_blocking_untracked_files "$task_file" "$plan_file" "HEAD")
    cd "$cwd"

    [[ "$_V2_LAST_CAPTURE_SCOPE_SOURCE" == "fallback-commit-range-empty" ]]
    [[ ! -s "$diff_file" ]]
    [[ -z "${_V2_LAST_CAPTURE_ALL_FILES:-}" ]]
    [[ -z "$blocking" ]]
    [[ -z "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" ]]
) && pass "12. all scope sources empty — no repo-wide fallback, dirty files ignored" \
  || fail "12. all scope sources empty — no repo-wide fallback, dirty files ignored"

# ---------- Test 13: directory-only resolves ----------
(
    root="$TMP_ROOT/resolve-dir-only"
    slug="dir-only-task"
    mkdir -p "$root/docs/tasks/open/$slug"
    printf '## Task: %s\n## Status: in progress\n' "$slug" > "$root/docs/tasks/open/$slug/task.md"

    SCRIPT_DIR="$root"
    result=$(_resolve_v2_task_file "$slug")
    [[ "$result" == "$root/docs/tasks/open/$slug/task.md" ]]
) && pass "13. _resolve_v2_task_file: directory-only resolves to task.md" \
  || fail "13. _resolve_v2_task_file: directory-only resolves to task.md"

# ---------- Test 14: flat + directory ambiguity is rejected ----------
(
    root="$TMP_ROOT/resolve-ambiguous"
    slug="ambig-task"
    mkdir -p "$root/docs/tasks/open/$slug"
    printf '## Task: %s\n## Status: in progress\n' "$slug" > "$root/docs/tasks/open/$slug/task.md"
    printf '## Task: %s (flat)\n## Status: in progress\n' "$slug" > "$root/docs/tasks/open/${slug}.md"

    SCRIPT_DIR="$root"
    set +e
    result=$(_resolve_v2_task_file "$slug" 2>/tmp/v2-resolve-stderr)
    rc=$?
    set -e
    stderr=$(cat /tmp/v2-resolve-stderr)
    rm -f /tmp/v2-resolve-stderr

    [[ "$rc" -eq 2 ]]
    [[ -z "$result" ]]
    [[ "$stderr" == *"ERROR: ambiguous task slug"* ]]
) && pass "14. _resolve_v2_task_file: flat + directory ambiguity returns 2 with error" \
  || fail "14. _resolve_v2_task_file: flat + directory ambiguity returns 2 with error"

# ---------- Test 15: flat-only resolves (backward compat) ----------
(
    root="$TMP_ROOT/resolve-flat-only"
    slug="flat-only-task"
    mkdir -p "$root/docs/tasks/open"
    printf '## Task: %s\n## Status: in progress\n' "$slug" > "$root/docs/tasks/open/${slug}.md"

    SCRIPT_DIR="$root"
    result=$(_resolve_v2_task_file "$slug")
    [[ "$result" == "$root/docs/tasks/open/${slug}.md" ]]
) && pass "15. _resolve_v2_task_file: flat-only resolves for backward compat" \
  || fail "15. _resolve_v2_task_file: flat-only resolves for backward compat"

# ---------- Test 16: executor-created new file NOT blocked (pre-exec snapshot empty) ----------
(
    repo_root="$(setup_scope_repo snapshot-new-file)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"

    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in_scope.py` | Update implementation |
| `src/new_module.py` | Create new module |
EOF

    # Snapshot before executor — no untracked in-scope files exist yet
    (
        cd "$repo_root"
        pre_snapshot=$(_collect_blocking_untracked_files "$task_file" "$plan_file" "HEAD")
        [[ -z "$pre_snapshot" ]]

        # Simulate executor creating a new in-scope file
        printf 'new module\n' > "$repo_root/src/new_module.py"

        # Block check with empty pre-snapshot as 5th arg — should NOT block
        _block_on_untracked_files "$task_file" "Phase 4" "$plan_file" "HEAD" "$pre_snapshot" >/dev/null 2>&1
    )
) && pass "16. executor-created new file NOT blocked (empty pre-exec snapshot)" \
  || fail "16. executor-created new file NOT blocked (empty pre-exec snapshot)"

# ---------- Test 17: pre-existing untracked file STILL blocked with snapshot ----------
(
    repo_root="$(setup_scope_repo snapshot-preexisting)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"

    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in_scope.py` | Update implementation |
| `src/preexisting.py` | Already exists untracked |
EOF

    # Create the untracked in-scope file BEFORE snapshot
    printf 'preexisting content\n' > "$repo_root/src/preexisting.py"

    (
        cd "$repo_root"
        pre_snapshot=$(_collect_blocking_untracked_files "$task_file" "$plan_file" "HEAD")
        [[ -n "$pre_snapshot" ]]

        # Block check with snapshot as 5th arg — should block (pre-existing file)
        ! _block_on_untracked_files "$task_file" "Phase 4" "$plan_file" "HEAD" "$pre_snapshot" >/dev/null 2>&1
    )
) && pass "17. pre-existing untracked file STILL blocked with snapshot" \
  || fail "17. pre-existing untracked file STILL blocked with snapshot"

# ---------- Test 18: mixed — pre-existing blocked, executor-created passes ----------
(
    repo_root="$(setup_scope_repo snapshot-mixed)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"

    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in_scope.py` | Update implementation |
| `src/preexisting.py` | Already exists untracked |
| `src/executor_new.py` | Executor will create this |
EOF

    # Create the pre-existing untracked in-scope file BEFORE snapshot
    printf 'preexisting\n' > "$repo_root/src/preexisting.py"

    (
        cd "$repo_root"
        pre_snapshot=$(_collect_blocking_untracked_files "$task_file" "$plan_file" "HEAD")
        # Only the pre-existing file should be in snapshot
        [[ "$pre_snapshot" == "src/preexisting.py" ]]

        # Simulate executor creating a new in-scope file
        printf 'executor created\n' > "$repo_root/src/executor_new.py"

        # Block check — should still block because of pre-existing file
        ! _block_on_untracked_files "$task_file" "Phase 4" "$plan_file" "HEAD" "$pre_snapshot" >/dev/null 2>&1

        # Verify _filter_to_preexisting only returns the pre-existing file
        current=$(_collect_blocking_untracked_files "$task_file" "$plan_file" "HEAD")
        filtered=$(_filter_to_preexisting "$current" "$pre_snapshot")
        [[ "$filtered" == "src/preexisting.py" ]]
    )
) && pass "18. mixed: pre-existing blocked, executor-created passes through" \
  || fail "18. mixed: pre-existing blocked, executor-created passes through"

# ---------- Test 19: new in-scope file only counts as a code change ----------
(
    repo_root="$(setup_scope_repo new-file-only)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `tests/test_timing_profiler.py` | Add a new test file |
EOF
    printf 'print("new file only")\n' > "$repo_root/tests/test_timing_profiler.py"

    (
        cd "$repo_root"
        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"

        ! (git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && [[ -z "${_V2_LAST_CAPTURE_UNTRACKED_FILES:-}" ]])
        [[ "$_V2_LAST_CAPTURE_UNTRACKED_FILES" == "tests/test_timing_profiler.py" ]]
        grep -q 'tests/test_timing_profiler.py' "$diff_file"
        grep -q 'new file only' "$diff_file"
    )
) && pass "19. new in-scope file only passes gate and captures a diff" \
  || fail "19. new in-scope file only passes gate and captures a diff"

# ---------- Test 20: mixed tracked + new in-scope files both appear in patch ----------
(
    repo_root="$(setup_scope_repo mixed-tracked-and-new)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    cat > "$plan_file" <<'EOF'
# Revised Plan

## Files to Modify

| File | Change |
|------|--------|
| `src/in_scope.py` | Update implementation |
| `tests/test_timing_profiler.py` | Add a new test file |
EOF
    printf 'changed tracked file\n' > "$repo_root/src/in_scope.py"
    printf 'print("new mixed file")\n' > "$repo_root/tests/test_timing_profiler.py"

    (
        cd "$repo_root"
        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"

        grep -q 'src/in_scope.py' "$diff_file"
        grep -q 'tests/test_timing_profiler.py' "$diff_file"
        grep -q 'changed tracked file' "$diff_file"
        grep -q 'new mixed file' "$diff_file"
    )
) && pass "20. mixed tracked changes and new files both appear in the patch" \
  || fail "20. mixed tracked changes and new files both appear in the patch"

# ---------- Test 21: out-of-scope new files stay ignored ----------
(
    repo_root="$(setup_scope_repo out-of-scope-new-file)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    printf 'outside scope only\n' > "$repo_root/docs/new-outside-scope.md"

    (
        cd "$repo_root"
        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"

        git diff --quiet 2>/dev/null
        git diff --cached --quiet 2>/dev/null
        [[ -z "${_V2_LAST_CAPTURE_UNTRACKED_FILES:-}" ]]
        [[ ! -s "$diff_file" ]]
    )
) && pass "21. new file outside scope is ignored by gate and diff capture" \
  || fail "21. new file outside scope is ignored by gate and diff capture"

# ---------- Test 22: pre-existing dirty file not flagged as out-of-scope ----------
(
    repo_root="$(setup_scope_repo preexist-dirty-oos)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    # Pre-existing dirty: modify out-of-scope tracked file before executor
    printf 'preexisting dirty change\n' > "$repo_root/docs/out_of_scope.md"

    (
        cd "$repo_root"
        pre_dirty=$(_v2_snapshot_dirty_files)
        baseline_sha=$(git rev-parse HEAD)

        # Simulate executor: modify in-scope file and commit only that file
        printf 'executor change\n' > "$repo_root/src/in_scope.py"
        git add src/in_scope.py
        git commit -q -m "executor commit"

        capture_diff_artifact "$baseline_sha" "$diff_file" "$task_file" "$plan_file" "$pre_dirty"

        # Pre-existing dirty file must NOT appear as out-of-scope
        [[ -z "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" ]]
        # Executor change IS captured
        echo "${_V2_LAST_CAPTURED_FILES:-}" | grep -q 'src/in_scope.py'
    )
) && pass "22. pre-existing dirty file not flagged as out-of-scope" \
  || fail "22. pre-existing dirty file not flagged as out-of-scope"

# ---------- Test 23: executor-created out-of-scope file IS still flagged ----------
(
    repo_root="$(setup_scope_repo exec-oos-flagged)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    (
        cd "$repo_root"
        pre_dirty=$(_v2_snapshot_dirty_files)
        baseline_sha=$(git rev-parse HEAD)

        # Simulate executor: commit both in-scope and out-of-scope files
        printf 'executor in-scope\n' > "$repo_root/src/in_scope.py"
        printf 'executor out-of-scope\n' > "$repo_root/docs/out_of_scope.md"
        git add -A
        git commit -q -m "executor commit with oos file"

        capture_diff_artifact "$baseline_sha" "$diff_file" "$task_file" "$plan_file" "$pre_dirty"

        # Executor-created out-of-scope file MUST still be flagged
        echo "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" | grep -q 'docs/out_of_scope.md'
    )
) && pass "23. executor-created out-of-scope file IS still flagged" \
  || fail "23. executor-created out-of-scope file IS still flagged"

# ---------- Test 24: executor-modified in-scope file captured even if pre-existing dirty ----------
(
    repo_root="$(setup_scope_repo preexist-dirty-inscope)"
    slug="scope-task"
    SLUG="$slug"
    task_file="$repo_root/docs/tasks/open/$slug/task.md"
    plan_file="$repo_root/docs/tasks/open/$slug/competitive/revised-plan.md"
    diff_file="$repo_root/docs/tasks/open/$slug/competitive/execution-diff.patch"

    # Pre-existing dirty: modify in-scope file before executor
    printf 'preexisting dirty in-scope\n' > "$repo_root/src/in_scope.py"

    (
        cd "$repo_root"
        pre_dirty=$(_v2_snapshot_dirty_files)
        baseline_sha=$(git rev-parse HEAD)

        # Simulate executor: overwrite the same in-scope file and commit
        printf 'executor overwrites in-scope\n' > "$repo_root/src/in_scope.py"
        git add src/in_scope.py
        git commit -q -m "executor commit over dirty file"

        capture_diff_artifact "$baseline_sha" "$diff_file" "$task_file" "$plan_file" "$pre_dirty"

        # File was pre-existing dirty but executor committed changes — must still be captured
        echo "${_V2_LAST_CAPTURED_FILES:-}" | grep -q 'src/in_scope.py'
        # No false out-of-scope warnings
        [[ -z "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" ]]
        # Diff patch includes the executor's change
        grep -q 'src/in_scope.py' "$diff_file"
    )
) && pass "24. executor-modified in-scope file captured correctly even if pre-existing dirty" \
  || fail "24. executor-modified in-scope file captured correctly even if pre-existing dirty"

# ── Test 25: consolidate flat file into directory ──
(
    repo_root="$(setup_scope_repo consolidate-flat)"
    slug="consolidate-task"
    task_dir="$repo_root/docs/tasks/open/$slug"
    flat_file="$repo_root/docs/tasks/open/${slug}.md"

    # Create flat file and track it in git
    mkdir -p "$repo_root/docs/tasks/open"
    printf '## Task: %s\n## Status: in progress\n' "$slug" > "$flat_file"
    git_commit_all "$repo_root" "add flat task file"

    # Create artifact directory (as Lauren Loop would)
    mkdir -p "${task_dir}/competitive" "${task_dir}/logs"

    (
        cd "$repo_root"
        SCRIPT_DIR="$repo_root"
        _consolidate_task_to_dir "$flat_file" "$task_dir"

        # Flat file should be gone, task.md should exist in dir
        [[ ! -f "$flat_file" ]]
        [[ -f "${task_dir}/task.md" ]]
        grep -q "## Task: $slug" "${task_dir}/task.md"
    )
) && pass "25. consolidate flat task file into directory layout" \
  || fail "25. consolidate flat task file into directory layout"

# ── Test 26: consolidate pilot file into directory ──
(
    repo_root="$(setup_scope_repo consolidate-pilot)"
    slug="consolidate-pilot-task"
    task_dir="$repo_root/docs/tasks/open/$slug"
    pilot_file="$repo_root/docs/tasks/open/pilot-${slug}.md"

    # Create pilot file and track it in git
    mkdir -p "$repo_root/docs/tasks/open"
    printf '## Task: %s\n## Status: in progress\n' "$slug" > "$pilot_file"
    git_commit_all "$repo_root" "add pilot task file"

    # Create artifact directory
    mkdir -p "${task_dir}/competitive" "${task_dir}/logs"

    (
        cd "$repo_root"
        SCRIPT_DIR="$repo_root"
        _consolidate_task_to_dir "$pilot_file" "$task_dir"

        # Pilot file should be gone, task.md should exist in dir
        [[ ! -f "$pilot_file" ]]
        [[ -f "${task_dir}/task.md" ]]
        grep -q "## Task: $slug" "${task_dir}/task.md"
    )
) && pass "26. consolidate pilot task file into directory layout" \
  || fail "26. consolidate pilot task file into directory layout"

# ── Test 27: consolidation is no-op when task.md already exists in dir ──
(
    repo_root="$(setup_scope_repo consolidate-noop)"
    slug="consolidate-noop-task"
    task_dir="$repo_root/docs/tasks/open/$slug"
    flat_file="$repo_root/docs/tasks/open/${slug}.md"

    # Create both flat file and dir task.md
    mkdir -p "$repo_root/docs/tasks/open" "${task_dir}/competitive"
    printf '## Task: %s (flat)\n' "$slug" > "$flat_file"
    printf '## Task: %s (dir)\n' "$slug" > "${task_dir}/task.md"
    git_commit_all "$repo_root" "add both flat and dir task files"

    (
        cd "$repo_root"
        SCRIPT_DIR="$repo_root"
        _consolidate_task_to_dir "$flat_file" "$task_dir"

        # Both files should still exist — dir task.md untouched
        [[ -f "$flat_file" ]]
        [[ -f "${task_dir}/task.md" ]]
        grep -q "(dir)" "${task_dir}/task.md"
    )
) && pass "27. consolidation no-op when task.md already in directory" \
  || fail "27. consolidation no-op when task.md already in directory"

# ---------- Test 28: PLAN_GAP files are added to effective scope and kept in diff ----------
(
    repo_root="$(setup_scope_repo scope-triage-plan-gap)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"

    printf 'executor out-of-scope tracked change\n' > "$repo_root/docs/out_of_scope.md"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' '[{"file":"docs/out_of_scope.md","classification":"PLAN_GAP","reasoning":"Required transitive dependency"}]' > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q 'docs/out_of_scope.md' "$diff_file"
        grep -q 'PLAN_GAP: `docs/out_of_scope.md` - Required transitive dependency' "$task_file"
        [[ "$(_v2_read_scope_triage_state_field "$comp_dir/execution-scope-triage.json" "status")" == "completed" ]]
    )
) && pass "28. scope triage keeps PLAN_GAP files in the regenerated diff" \
  || fail "28. scope triage keeps PLAN_GAP files in the regenerated diff"

# ---------- Test 29: NOISE tracked files are reverted ----------
(
    repo_root="$(setup_scope_repo scope-triage-noise-tracked)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"

    printf 'executor out-of-scope tracked change\n' > "$repo_root/docs/out_of_scope.md"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' '[{"file":"docs/out_of_scope.md","classification":"NOISE","reasoning":"Unrelated documentation edit"}]' > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q '^baseline$' "$repo_root/docs/out_of_scope.md"
        [[ ! -s "$diff_file" ]]
        grep -q 'NOISE: `docs/out_of_scope.md` - Unrelated documentation edit \[reverted: restored path to HEAD\]' "$task_file"
    )
) && pass "29. scope triage reverts tracked NOISE files" \
  || fail "29. scope triage reverts tracked NOISE files"

# ---------- Test 30: triage failure fails open to PLAN_GAP ----------
(
    repo_root="$(setup_scope_repo scope-triage-fail-open)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"

    printf 'executor out-of-scope tracked change\n' > "$repo_root/docs/out_of_scope.md"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            return 124
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q 'docs/out_of_scope.md' "$diff_file"
        grep -q 'Failure: Scope triage timed out (1m)' "$task_file"
        grep -q 'PLAN_GAP: `docs/out_of_scope.md` - Scope triage timed out (1m). Kept by default.' "$task_file"
        [[ "$(_v2_read_scope_triage_state_field "$comp_dir/execution-scope-triage.json" "status")" == "failed-open" ]]
    )
) && pass "30. scope triage failures keep files as PLAN_GAP" \
  || fail "30. scope triage failures keep files as PLAN_GAP"

# ---------- Test 31: zero out-of-scope files skip triage agent ----------
(
    repo_root="$(setup_scope_repo scope-triage-skip)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    marker_file="$repo_root/triage-agent-called.txt"

    printf 'changed in scope only\n' > "$repo_root/src/in_scope.py"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf 'called\n' > "$marker_file"
            return 1
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        [[ ! -f "$marker_file" ]]
        [[ "$(_v2_read_scope_triage_state_field "$comp_dir/execution-scope-triage.json" "status")" == "skipped" ]]
    )
) && pass "31. scope triage skips the agent when there are no violations" \
  || fail "31. scope triage skips the agent when there are no violations"

# ---------- Test 32: task file is always forced to NOISE ----------
(
    repo_root="$(setup_scope_repo scope-triage-task-file)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    task_file_rel="docs/tasks/open/$slug/task.md"

    printf '\nexecutor touched task file\n' >> "$task_file"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' "[{\"file\":\"${task_file_rel}\",\"classification\":\"PLAN_GAP\",\"reasoning\":\"Model guessed wrong\"}]" > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q "NOISE: \`${task_file_rel}\` - Pipeline-owned task artifact; excluded from executor scope review." "$task_file"
        [[ -z "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" ]]
    )
) && pass "32. task file violations are forced to NOISE" \
  || fail "32. task file violations are forced to NOISE"

# ---------- Test 33: untracked NOISE files are quarantined ----------
(
    repo_root="$(setup_scope_repo scope-triage-untracked-noise)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    new_file="$repo_root/docs/new-outside-scope.md"
    quarantined_file="$comp_dir/scope-triage-quarantine/docs/new-outside-scope.md"

    printf 'untracked noise\n' > "$new_file"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' '[{"file":"docs/new-outside-scope.md","classification":"NOISE","reasoning":"Debug artifact"}]' > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        [[ ! -e "$new_file" ]]
        [[ -f "$quarantined_file" ]]
        [[ ! -s "$diff_file" ]]
        grep -q 'NOISE: `docs/new-outside-scope.md` - Debug artifact \[quarantined: '"$quarantined_file"'\]' "$task_file"
    )
) && pass "33. scope triage quarantines untracked NOISE files" \
  || fail "33. scope triage quarantines untracked NOISE files"

# ---------- Test 34: scope triage log section is appended ----------
(
    repo_root="$(setup_scope_repo scope-triage-log-section)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"

    printf 'executor out-of-scope tracked change\n' > "$repo_root/docs/out_of_scope.md"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' '[{"file":"docs/out_of_scope.md","classification":"PLAN_GAP","reasoning":"Needed dependency"}]' > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q '^## Scope Triage Log$' "$task_file"
        grep -q '^### Phase 4 Scope Triage - ' "$task_file"
    )
) && pass "34. scope triage log section is created and populated" \
  || fail "34. scope triage log section is created and populated"

# ---------- Test 35: pending checkpoint reruns scope triage on resume ----------
(
    repo_root="$(setup_scope_repo scope-triage-resume-pending)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    state_file="$comp_dir/execution-scope-triage.json"
    marker_file="$repo_root/triage-agent-called.txt"

    printf 'changed in scope\n' > "$repo_root/src/in_scope.py"
    printf 'changed out of scope\n' > "$repo_root/docs/out_of_scope.md"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        before_sha=$(git rev-parse HEAD)
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf 'called\n' > "$marker_file"
            printf '%s\n' '[{"file":"docs/out_of_scope.md","classification":"NOISE","reasoning":"Resume rerun reverted unrelated docs change"}]' > "$5"
            return 0
        }

        capture_diff_artifact "$before_sha" "$diff_file" "$task_file" "$plan_file"
        _phase_start=$(_iso_timestamp)
        _v2_handle_phase4_checkpoint "$task_file" "$diff_file" "$state_file" "$plan_file"
        [[ "$_V2_PHASE4_CHECKPOINT_NEEDS_TRIAGE" == "true" ]]
        grep -q 'Phase 4: WARNING scope triage state missing or unreadable; resuming as pending from checkpoint' "$TEST_LOG_FILE"

        _v2_write_scope_triage_state "$state_file" "pending" "$before_sha" "$plan_file" "$diff_file" "" ""
        _v2_handle_phase4_checkpoint "$task_file" "$diff_file" "$state_file" "$plan_file"
        [[ "$_V2_PHASE4_CHECKPOINT_NEEDS_TRIAGE" == "true" ]]
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "$_V2_PHASE4_CHECKPOINT_BEFORE_SHA" "$plan_file" "$diff_file" "$_V2_PHASE4_CHECKPOINT_PREEXISTING_DIRTY"

        [[ -f "$marker_file" ]]
        grep -q '^changed in scope$' "$repo_root/src/in_scope.py"
        grep -q '^baseline$' "$repo_root/docs/out_of_scope.md"
        grep -q 'src/in_scope.py' "$diff_file"
        ! grep -q 'docs/out_of_scope.md' "$diff_file"
        grep -q 'Phase 4: Executor skipped (checkpoint — scope triage pending)' "$TEST_LOG_FILE"
        [[ "$(_v2_read_scope_triage_state_field "$state_file" "status")" == "completed" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "docs/out_of_scope.md" "classification")" == "NOISE" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "actions" "docs/out_of_scope.md" "action")" == "reverted" ]]
    )
) && pass "35. pending checkpoint reruns scope triage on resume" \
  || fail "35. pending checkpoint reruns scope triage on resume"

# ---------- Test 36: completed checkpoint skips scope triage on resume ----------
(
    repo_root="$(setup_scope_repo scope-triage-resume-completed)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    state_file="$comp_dir/execution-scope-triage.json"
    marker_file="$repo_root/triage-agent-called.txt"

    printf 'changed in scope\n' > "$repo_root/src/in_scope.py"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        before_sha=$(git rev-parse HEAD)
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf 'called\n' > "$marker_file"
            return 0
        }

        capture_diff_artifact "$before_sha" "$diff_file" "$task_file" "$plan_file"
        _v2_write_scope_triage_state "$state_file" "completed" "$before_sha" "$plan_file" "$diff_file" "" ""
        _phase_start=$(_iso_timestamp)
        _v2_handle_phase4_checkpoint "$task_file" "$diff_file" "$state_file" "$plan_file"

        [[ "$_V2_PHASE4_CHECKPOINT_NEEDS_TRIAGE" == "false" ]]
        [[ ! -f "$marker_file" ]]
        grep -q '^changed in scope$' "$repo_root/src/in_scope.py"
        grep -q '^baseline$' "$repo_root/docs/out_of_scope.md"
        grep -q 'src/in_scope.py' "$diff_file"
        ! grep -q 'docs/out_of_scope.md' "$diff_file"
        grep -q 'Phase 4: Skipped (checkpoint)' "$TEST_LOG_FILE"
        [[ "$(_v2_read_scope_triage_state_field "$state_file" "status")" == "completed" ]]
    )
) && pass "36. completed checkpoint skips scope triage on resume" \
  || fail "36. completed checkpoint skips scope triage on resume"

# ---------- Test 37: invalid JSON fails open ----------
(
    repo_root="$(setup_scope_repo scope-triage-invalid-json)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    state_file="$comp_dir/execution-scope-triage.json"

    printf 'executor out-of-scope tracked change\n' > "$repo_root/docs/out_of_scope.md"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' 'not json' > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q '^executor out-of-scope tracked change$' "$repo_root/docs/out_of_scope.md"
        grep -q 'docs/out_of_scope.md' "$diff_file"
        [[ "$(_v2_read_scope_triage_state_field "$state_file" "status")" == "failed-open" ]]
        [[ "$(_v2_read_scope_triage_state_field "$state_file" "failure_reason")" == "Scope triage returned unparseable JSON" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "docs/out_of_scope.md" "classification")" == "PLAN_GAP" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "actions" "docs/out_of_scope.md" "action")" == "kept" ]]
    )
) && pass "37. scope triage invalid JSON fails open" \
  || fail "37. scope triage invalid JSON fails open"

# ---------- Test 38: incomplete coverage fails open ----------
(
    repo_root="$(setup_scope_repo scope-triage-incomplete-coverage)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    state_file="$comp_dir/execution-scope-triage.json"
    second_file="$repo_root/docs/second_out_of_scope.md"

    printf 'baseline\n' > "$second_file"
    git_commit_all "$repo_root" "add second out of scope file"
    printf 'changed first out of scope\n' > "$repo_root/docs/out_of_scope.md"
    printf 'changed second out of scope\n' > "$second_file"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' '[{"file":"docs/out_of_scope.md","classification":"PLAN_GAP","reasoning":"Only one file was classified"}]' > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q '^changed first out of scope$' "$repo_root/docs/out_of_scope.md"
        grep -q '^changed second out of scope$' "$second_file"
        grep -q 'docs/out_of_scope.md' "$diff_file"
        grep -q 'docs/second_out_of_scope.md' "$diff_file"
        [[ "$(_v2_read_scope_triage_state_field "$state_file" "status")" == "failed-open" ]]
        [[ "$(_v2_read_scope_triage_state_field "$state_file" "failure_reason")" == "Scope triage output did not classify the expected file set" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "docs/out_of_scope.md" "classification")" == "PLAN_GAP" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "actions" "docs/out_of_scope.md" "action")" == "kept" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "docs/second_out_of_scope.md" "classification")" == "PLAN_GAP" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "actions" "docs/second_out_of_scope.md" "action")" == "kept" ]]
    )
) && pass "38. scope triage incomplete coverage fails open" \
  || fail "38. scope triage incomplete coverage fails open"

# ---------- Test 39: multi-file mixed classification ----------
(
    repo_root="$(setup_scope_repo scope-triage-mixed-classification)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    state_file="$comp_dir/execution-scope-triage.json"
    tracked_plan_gap="$repo_root/docs/plan_gap.md"
    tracked_noise="$repo_root/docs/out_of_scope.md"
    untracked_noise="$repo_root/docs/new-outside-scope.md"
    quarantined_file="$comp_dir/scope-triage-quarantine/docs/new-outside-scope.md"

    printf 'baseline\n' > "$tracked_plan_gap"
    git_commit_all "$repo_root" "add plan gap file"
    printf 'tracked plan gap\n' > "$tracked_plan_gap"
    printf 'tracked noise\n' > "$tracked_noise"
    printf 'untracked noise\n' > "$untracked_noise"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' '[
{"file":"docs/plan_gap.md","classification":"PLAN_GAP","reasoning":"Needed transitive dependency"},
{"file":"docs/out_of_scope.md","classification":"NOISE","reasoning":"Unrelated docs churn"},
{"file":"docs/new-outside-scope.md","classification":"NOISE","reasoning":"Generated noise"}
]' > "$5"
            return 0
        }

        capture_diff_artifact "HEAD" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "HEAD" "$plan_file" "$diff_file" ""

        grep -q '^tracked plan gap$' "$tracked_plan_gap"
        grep -q '^baseline$' "$tracked_noise"
        [[ ! -e "$untracked_noise" ]]
        [[ -f "$quarantined_file" ]]
        grep -q 'docs/plan_gap.md' "$diff_file"
        ! grep -q 'docs/out_of_scope.md' "$diff_file"
        ! grep -q 'docs/new-outside-scope.md' "$diff_file"
        [[ "$(_v2_read_scope_triage_state_field "$state_file" "status")" == "completed" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "docs/plan_gap.md" "classification")" == "PLAN_GAP" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "actions" "docs/plan_gap.md" "action")" == "kept" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "docs/out_of_scope.md" "classification")" == "NOISE" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "actions" "docs/out_of_scope.md" "action")" == "reverted" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "docs/new-outside-scope.md" "classification")" == "NOISE" ]]
        [[ "$(scope_triage_state_record_field "$state_file" "actions" "docs/new-outside-scope.md" "action")" == "quarantined" ]]
    )
) && pass "39. scope triage handles mixed PLAN_GAP, tracked NOISE, and untracked NOISE" \
  || fail "39. scope triage handles mixed PLAN_GAP, tracked NOISE, and untracked NOISE"

# ---------- Test 40: raw NOISE stays out of estimate scope even when review keeps the file ----------
(
    repo_root="$(setup_scope_repo scope-triage-estimate-noise)"
    slug="scope-task"
    SLUG="$slug"
    task_dir="$repo_root/docs/tasks/open/$slug"
    task_file="$task_dir/task.md"
    plan_file="$task_dir/competitive/revised-plan.md"
    comp_dir="$task_dir/competitive"
    diff_file="$comp_dir/execution-diff.patch"
    state_file="$comp_dir/execution-scope-triage.json"
    tracked_noise="$repo_root/src/out_of_scope.py"
    standard_numstat="$comp_dir/execution-diff.numstat.tsv"
    estimate_numstat="$comp_dir/execution-diff.estimate.numstat.tsv"

    printf 'baseline\n' > "$tracked_noise"
    git_commit_all "$repo_root" "add tracked out-of-scope source"
    before_sha="$(git -C "$repo_root" rev-parse HEAD)"
    printf 'baseline\nin scope change\n' > "$repo_root/src/in_scope.py"
    printf 'baseline\ntracked raw noise\ntracked raw noise 2\n' > "$tracked_noise"
    git_commit_all "$repo_root" "executor changes"
    reset_test_log

    (
        cd "$repo_root"
        prime_scope_triage_env "$repo_root" "$task_dir"
        prepare_agent_request() {
            AGENT_PROMPT_BODY="scope-triage"
            AGENT_SYSTEM_PROMPT=""
        }
        run_agent() {
            printf '%s\n' '[{"file":"src/out_of_scope.py","classification":"NOISE","reasoning":"Unrelated helper churn"}]' > "$5"
            return 0
        }

        capture_diff_artifact "$before_sha" "$diff_file" "$task_file" "$plan_file"
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "$before_sha" "$plan_file" "$diff_file" ""

        grep -q 'src/out_of_scope.py' "$diff_file"
        grep -q 'src/out_of_scope.py' "$standard_numstat"
        [[ "$(scope_triage_state_record_field "$state_file" "classifications" "src/out_of_scope.py" "classification")" == "PLAN_GAP" ]]
        ! grep -q 'src/out_of_scope.py' "$estimate_numstat"
        printf '%s\n' "$(_v2_read_scope_triage_state_lines "$state_file" "estimate_scope_paths")" | grep -qx 'src/in_scope.py'
        ! printf '%s\n' "$(_v2_read_scope_triage_state_lines "$state_file" "estimate_scope_paths")" | grep -qx 'src/out_of_scope.py'
        result=$(build_v2_traditional_dev_proxy_json "$task_file" 0)
        echo "$result" | jq -e '.scope_source == "frozen-v2-estimate-numstat"' >/dev/null
        echo "$result" | jq -e '.insertions == 1 and .deletions == 0 and .net_lines == 1' >/dev/null
    )
) && pass "40. scope triage keeps raw NOISE out of estimate scope even when review keeps the file" \
  || fail "40. scope triage keeps raw NOISE out of estimate scope even when review keeps the file"

echo ""
echo "Passed: $PASSED/$TOTAL"
[ "$FAILED" -eq 0 ]

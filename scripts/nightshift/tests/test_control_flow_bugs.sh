#!/usr/bin/env bash
# test_control_flow_bugs.sh — Tests for cost-cap hard stop and setup-failure abort.
# Validates: cost cap blocks Phase 3 manager call, fallback digest shape,
# SETUP_FAILED blocks Phases 2-3, dry-run bypasses SETUP_FAILED.
#
# Usage: bash scripts/nightshift/tests/test_control_flow_bugs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0 FAIL=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

init_test_git_repo() {
    local repo_dir="$1"

    mkdir -p "$repo_dir"
    (
        cd "$repo_dir"
        git init -q
        git config user.email "nightshift-test@example.com"
        git config user.name "Nightshift Test"
        printf 'tracked\n' > tracked.txt
        git add tracked.txt
        git commit -qm "init"
    )
}

echo "=== test_control_flow_bugs.sh ==="
echo ""

# Source conf first (sets NIGHTSHIFT_* defaults), then libraries, then nightshift.sh.
# The sourcing guard in nightshift.sh prevents main() from executing.
source "$NS_DIR/nightshift.conf"
source "$NS_DIR/lib/cost-tracker.sh"
source "$NS_DIR/lib/agent-runner.sh"
source "$NS_DIR/lib/db-safety.sh"
source "$NS_DIR/lib/git-safety.sh"
source "$NS_DIR/nightshift.sh"

# ── Test 1: Cost cap blocks Phase 3 manager Claude call ──────────────────────
(
    # Set up temp environment
    export REPO_ROOT="$TMP_DIR/t1/repo"
    export RUN_TMP_DIR="$TMP_DIR/t1/run"
    export RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw-findings"
    export AGENT_OUTPUT_DIR="$RUN_TMP_DIR/agent-outputs"
    export NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/t1/findings"
    export NIGHTSHIFT_LOG_DIR="$TMP_DIR/t1/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$TMP_DIR/t1/playbooks"
    export NIGHTSHIFT_COST_STATE_FILE="$RUN_TMP_DIR/cost-state.json"
    export NIGHTSHIFT_COST_CSV="$RUN_TMP_DIR/cost.csv"
    mkdir -p "$REPO_ROOT/docs/nightshift/digests" "$REPO_ROOT/docs/tasks/open/nightshift"
    mkdir -p "$RUN_TMP_DIR" "$RAW_FINDINGS_DIR" "$AGENT_OUTPUT_DIR"
    mkdir -p "$NIGHTSHIFT_FINDINGS_DIR" "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR"

    # State
    RUN_COST_CAP=1
    SETUP_FAILED=0
    BRANCH_READY=1
    MANAGER_ALLOWED=1
    DRY_RUN=0
    RUN_DATE="2026-01-01"
    RUN_ID="test-costcap-1"
    RUN_BRANCH="nightshift/2026-01-01"
    CURRENT_PHASE="3"
    FAILURE_NOTES=""
    WARNING_NOTES=""
    TOTAL_FINDINGS_AVAILABLE=0
    TASK_FILE_COUNT=0
    DIGEST_AVAILABLE=0
    DIGEST_STAGEABLE=0
    DIGEST_PATH=""
    RUN_FAILED=0
    RUN_CLEAN=0
    COST_TRACKING_READY=0

    # Create mock findings
    printf '### Finding: Memory leak in worker pool\nDetails here.\n' > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md"
    printf '### Finding: Stale cache entries\nMore details.\n' > "$NIGHTSHIFT_FINDINGS_DIR/error-detective-findings.md"

    # Mock: track whether agent_run_claude was called
    AGENT_CALLED=0
    agent_run_claude() { AGENT_CALLED=1; return 0; }
    check_total_timeout() { return 0; }
    rebuild_manager_inputs() { return 0; }
    count_total_findings() { echo "2"; }

    phase_manager_merge

    # Assertions
    ok=true
    if [[ "$AGENT_CALLED" -eq 1 ]]; then
        ok=false
    fi
    if [[ ! -f "$DIGEST_PATH" ]]; then
        ok=false
    fi
    if ! grep -q "cost-cap-halted" "$DIGEST_PATH" 2>/dev/null; then
        ok=false
    fi
    if ! grep -q "Raw Detective Findings" "$DIGEST_PATH" 2>/dev/null; then
        ok=false
    fi
    $ok
) && pass "1. Cost cap blocks Phase 3 manager Claude call" \
  || fail "1. Cost cap blocks Phase 3 manager Claude call" "agent was called or digest missing/wrong"

# ── Test 2: Cost cap fallback digest shape ────────────────────────────────────
(
    export REPO_ROOT="$TMP_DIR/t2/repo"
    export RUN_TMP_DIR="$TMP_DIR/t2/run"
    export RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw-findings"
    export AGENT_OUTPUT_DIR="$RUN_TMP_DIR/agent-outputs"
    export NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/t2/findings"
    export NIGHTSHIFT_LOG_DIR="$TMP_DIR/t2/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$TMP_DIR/t2/playbooks"
    export NIGHTSHIFT_COST_STATE_FILE="$RUN_TMP_DIR/cost-state.json"
    export NIGHTSHIFT_COST_CSV="$RUN_TMP_DIR/cost.csv"
    mkdir -p "$REPO_ROOT/docs/nightshift/digests" "$REPO_ROOT/docs/tasks/open/nightshift"
    mkdir -p "$RUN_TMP_DIR" "$RAW_FINDINGS_DIR" "$AGENT_OUTPUT_DIR"
    mkdir -p "$NIGHTSHIFT_FINDINGS_DIR" "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR"

    RUN_COST_CAP=1
    SETUP_FAILED=0
    BRANCH_READY=1
    MANAGER_ALLOWED=1
    DRY_RUN=0
    RUN_DATE="2026-01-02"
    RUN_ID="test-costcap-2"
    RUN_BRANCH="nightshift/2026-01-02"
    CURRENT_PHASE="3"
    FAILURE_NOTES=""
    WARNING_NOTES=""
    TOTAL_FINDINGS_AVAILABLE=0
    TASK_FILE_COUNT=0
    DIGEST_AVAILABLE=0
    DIGEST_STAGEABLE=0
    DIGEST_PATH=""
    RUN_FAILED=0
    RUN_CLEAN=0
    COST_TRACKING_READY=0

    # 3 findings files + 1 partial
    printf '### Finding: Alpha issue\nAlpha details verbatim.\n' > "$NIGHTSHIFT_FINDINGS_DIR/commit-detective-findings.md"
    printf '### Finding: Beta issue\nBeta details verbatim.\n' > "$NIGHTSHIFT_FINDINGS_DIR/conversation-detective-findings.md"
    printf '### Finding: Gamma issue\nGamma details verbatim.\n' > "$NIGHTSHIFT_FINDINGS_DIR/error-detective-findings.md"
    printf '### Finding: Partial stuff\nShould NOT appear.\n' > "$RAW_FINDINGS_DIR/claude-commit-detective-partial.md"

    agent_run_claude() { AGENT_CALLED=1; return 0; }
    AGENT_CALLED=0
    check_total_timeout() { return 0; }
    rebuild_manager_inputs() { return 0; }
    count_total_findings() { echo "3"; }

    phase_manager_merge

    ok=true
    # All 3 findings verbatim
    if ! grep -q "Alpha details verbatim" "$DIGEST_PATH" 2>/dev/null; then ok=false; fi
    if ! grep -q "Beta details verbatim" "$DIGEST_PATH" 2>/dev/null; then ok=false; fi
    if ! grep -q "Gamma details verbatim" "$DIGEST_PATH" 2>/dev/null; then ok=false; fi
    # Partial content excluded
    if grep -q "Should NOT appear" "$DIGEST_PATH" 2>/dev/null; then ok=false; fi
    # Partial noted
    if ! grep -q "Partial outputs omitted" "$DIGEST_PATH" 2>/dev/null; then ok=false; fi
    # Metadata
    if ! grep -q "test-costcap-2" "$DIGEST_PATH" 2>/dev/null; then ok=false; fi
    if ! grep -q "cost cap" "$DIGEST_PATH" 2>/dev/null; then ok=false; fi
    # Sorted order: commit < conversation < error
    commit_line=$(grep -n "commit-detective-findings.md" "$DIGEST_PATH" | head -1 | cut -d: -f1)
    conv_line=$(grep -n "conversation-detective-findings.md" "$DIGEST_PATH" | head -1 | cut -d: -f1)
    error_line=$(grep -n "error-detective-findings.md" "$DIGEST_PATH" | head -1 | cut -d: -f1)
    if [[ "$commit_line" -ge "$conv_line" ]] || [[ "$conv_line" -ge "$error_line" ]]; then ok=false; fi
    $ok
) && pass "2. Cost cap fallback digest shape (3 findings sorted, partial excluded)" \
  || fail "2. Cost cap fallback digest shape" "findings missing, partial leaked, or wrong order"

# ── Test 3: Setup failure aborts before detectives ────────────────────────────
(
    export REPO_ROOT="$TMP_DIR/t3/repo"
    export RUN_TMP_DIR="$TMP_DIR/t3/run"
    export NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/t3/findings"
    export NIGHTSHIFT_LOG_DIR="$TMP_DIR/t3/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$TMP_DIR/t3/playbooks"
    mkdir -p "$REPO_ROOT" "$RUN_TMP_DIR" "$NIGHTSHIFT_FINDINGS_DIR" "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR"

    SETUP_FAILED=1
    DRY_RUN=0
    SETUP_READY=1
    CLAUDE_AVAILABLE=1
    RUN_FAILED=0
    RUN_COST_CAP=0
    CURRENT_PHASE="2"
    FAILURE_NOTES=""
    WARNING_NOTES=""

    AGENT_CALLED=0
    run_detective_call() { AGENT_CALLED=1; return 0; }
    agent_run_claude() { AGENT_CALLED=1; return 0; }
    check_total_timeout() { return 0; }

    phase_detectives

    ok=true
    if [[ "$AGENT_CALLED" -eq 1 ]]; then ok=false; fi
    if [[ "$RUN_FAILED" -ne 1 ]]; then ok=false; fi
    $ok
) && pass "3. SETUP_FAILED=1 blocks Phase 2 detectives (no calls, RUN_FAILED=1)" \
  || fail "3. SETUP_FAILED=1 blocks Phase 2 detectives" "detectives ran or RUN_FAILED not set"

# ── Test 4: Setup failure skips manager ───────────────────────────────────────
(
    export REPO_ROOT="$TMP_DIR/t4/repo"
    export RUN_TMP_DIR="$TMP_DIR/t4/run"
    export RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw-findings"
    export AGENT_OUTPUT_DIR="$RUN_TMP_DIR/agent-outputs"
    export NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/t4/findings"
    export NIGHTSHIFT_LOG_DIR="$TMP_DIR/t4/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$TMP_DIR/t4/playbooks"
    export NIGHTSHIFT_COST_STATE_FILE="$RUN_TMP_DIR/cost-state.json"
    mkdir -p "$REPO_ROOT" "$RUN_TMP_DIR" "$RAW_FINDINGS_DIR" "$AGENT_OUTPUT_DIR"
    mkdir -p "$NIGHTSHIFT_FINDINGS_DIR" "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR"

    SETUP_FAILED=1
    DRY_RUN=0
    RUN_DATE="2026-01-04"
    RUN_ID="test-setupfail-4"
    RUN_BRANCH=""
    CURRENT_PHASE="3"
    FAILURE_NOTES=""
    WARNING_NOTES=""
    TOTAL_FINDINGS_AVAILABLE=0
    TASK_FILE_COUNT=0
    DIGEST_AVAILABLE=0
    DIGEST_STAGEABLE=0
    DIGEST_PATH=""
    RUN_FAILED=0
    RUN_CLEAN=0
    COST_TRACKING_READY=0
    RUN_COST_CAP=0

    AGENT_CALLED=0
    agent_run_claude() { AGENT_CALLED=1; return 0; }

    phase_manager_merge

    ok=true
    if [[ "$AGENT_CALLED" -eq 1 ]]; then ok=false; fi
    if [[ "$DIGEST_STAGEABLE" -ne 0 ]]; then ok=false; fi
    # Fallback digest should exist in RUN_TMP_DIR
    if [[ ! -f "$RUN_TMP_DIR/setup-failed-digest.md" ]]; then ok=false; fi
    $ok
) && pass "4. SETUP_FAILED=1 skips Phase 3 manager (no call, DIGEST_STAGEABLE=0)" \
  || fail "4. SETUP_FAILED=1 skips Phase 3 manager" "agent called or DIGEST_STAGEABLE wrong"

# ── Test 5: Dry-run ignores SETUP_FAILED ──────────────────────────────────────
(
    export REPO_ROOT="$TMP_DIR/t5/repo"
    export RUN_TMP_DIR="$TMP_DIR/t5/run"
    export RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw-findings"
    export AGENT_OUTPUT_DIR="$RUN_TMP_DIR/agent-outputs"
    export NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/t5/findings"
    export NIGHTSHIFT_LOG_DIR="$TMP_DIR/t5/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$TMP_DIR/t5/playbooks"
    export NIGHTSHIFT_COST_STATE_FILE="$RUN_TMP_DIR/cost-state.json"
    mkdir -p "$REPO_ROOT" "$RUN_TMP_DIR" "$RAW_FINDINGS_DIR" "$AGENT_OUTPUT_DIR"
    mkdir -p "$NIGHTSHIFT_FINDINGS_DIR" "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR"

    SETUP_FAILED=1
    DRY_RUN=1
    RUN_DATE="2026-01-05"
    RUN_ID="test-dryrun-5"
    RUN_BRANCH=""
    CURRENT_PHASE="2"
    FAILURE_NOTES=""
    WARNING_NOTES=""
    TOTAL_FINDINGS_AVAILABLE=0
    TASK_FILE_COUNT=0
    DIGEST_AVAILABLE=0
    DIGEST_STAGEABLE=0
    DIGEST_PATH=""
    RUN_FAILED=0
    RUN_CLEAN=0
    COST_TRACKING_READY=0
    RUN_COST_CAP=0

    # Phase 2: dry-run returns early before SETUP_FAILED check
    phase_detectives
    det_failed=$RUN_FAILED

    # Reset for Phase 3
    RUN_FAILED=0
    CURRENT_PHASE="3"

    # Phase 3: dry-run returns early before SETUP_FAILED check
    phase_manager_merge
    mgr_failed=$RUN_FAILED

    ok=true
    if [[ "$det_failed" -ne 0 ]]; then ok=false; fi
    if [[ "$mgr_failed" -ne 0 ]]; then ok=false; fi
    # Phase 3 dry-run should set RUN_CLEAN=1
    if [[ "$RUN_CLEAN" -ne 1 ]]; then ok=false; fi
    $ok
) && pass "5. Dry-run ignores SETUP_FAILED (both phases proceed, RUN_FAILED stays 0)" \
  || fail "5. Dry-run ignores SETUP_FAILED" "RUN_FAILED was set or dry-run flow broken"

# ── Test 6: Detective cost halt stops immediately in playbook-first order ────
(
    export REPO_ROOT="$TMP_DIR/t6/repo"
    export RUN_TMP_DIR="$TMP_DIR/t6/run"
    export NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/t6/findings"
    export NIGHTSHIFT_LOG_DIR="$TMP_DIR/t6/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$TMP_DIR/t6/playbooks"
    mkdir -p "$REPO_ROOT" "$RUN_TMP_DIR" "$NIGHTSHIFT_FINDINGS_DIR" "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR"

    SETUP_FAILED=0
    DRY_RUN=0
    SETUP_READY=1
    CLAUDE_AVAILABLE=1
    RUN_FAILED=0
    RUN_COST_CAP=0
    CURRENT_PHASE="2"
    FAILURE_NOTES=""
    WARNING_NOTES=""

    call_log="$TMP_DIR/t6-phase-detectives.log"
    run_detective_call() {
        local agent_name="$1"
        local playbook_path="$2"
        printf '%s/%s\n' "$agent_name" "$(basename "$playbook_path" .md)" >> "$call_log"
        if [[ "$(wc -l < "$call_log")" -eq 2 ]]; then
            RUN_COST_CAP=1
        fi
        return 0
    }
    check_total_timeout() { return 0; }

    phase_detectives

    calls=()
    if [[ -f "$call_log" ]]; then
        while IFS= read -r call; do
            calls+=("$call")
        done < "$call_log"
    fi
    if [[ "${#calls[@]}" -gt 0 ]]; then
        actual_calls="$(printf '%s\n' "${calls[@]}")"
    else
        actual_calls=""
    fi
    expected_calls=$'claude/commit-detective\ncodex/commit-detective'

    ok=true
    [[ "${RUN_COST_CAP}" -eq 1 ]] || ok=false
    [[ "${#calls[@]}" -eq 2 ]] || ok=false
    [[ "${actual_calls}" == "${expected_calls}" ]] || ok=false
    $ok
) && pass "6. Detective cost halt stops after the current playbook's Codex call" \
  || fail "6. Detective cost halt stops after the current playbook's Codex call" "phase_detectives did not halt in playbook-first order"

# ── Test 7: Manager digest summary/status sections are rewritten deterministically ──
(
    export REPO_ROOT="$TMP_DIR/t7/repo"
    export RUN_TMP_DIR="$TMP_DIR/t7/run"
    export RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw-findings"
    export AGENT_OUTPUT_DIR="$RUN_TMP_DIR/agent-outputs"
    export NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/t7/findings"
    export NIGHTSHIFT_LOG_DIR="$TMP_DIR/t7/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$TMP_DIR/t7/playbooks"
    export NIGHTSHIFT_COST_STATE_FILE="$RUN_TMP_DIR/cost-state.json"
    export DETECTIVE_STATUS_DIR="$RUN_TMP_DIR/detective-status"
    mkdir -p "$REPO_ROOT/docs/nightshift/digests" "$REPO_ROOT/docs/tasks/open/nightshift"
    mkdir -p "$RUN_TMP_DIR" "$RAW_FINDINGS_DIR" "$AGENT_OUTPUT_DIR" "$NIGHTSHIFT_FINDINGS_DIR"
    mkdir -p "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR" "$DETECTIVE_STATUS_DIR"

    RUN_COST_CAP=0
    SETUP_FAILED=0
    BRANCH_READY=1
    MANAGER_ALLOWED=1
    DRY_RUN=0
    RUN_DATE="2026-01-07"
    RUN_ID="test-digest-rewrite-7"
    RUN_BRANCH="nightshift/2026-01-07"
    CURRENT_PHASE="3"
    FAILURE_NOTES=""
    WARNING_NOTES=""
    TOTAL_FINDINGS_AVAILABLE=0
    TASK_FILE_COUNT=0
    DIGEST_AVAILABLE=0
    DIGEST_STAGEABLE=0
    DIGEST_PATH=""
    RUN_FAILED=0
    RUN_CLEAN=0
    COST_TRACKING_READY=0

    reset_detective_statuses
    set_detective_status "commit-detective" "ran"
    set_detective_status "conversation-detective" "ran"
    set_detective_status "error-detective" "ran"

    cat > "$RAW_FINDINGS_DIR/claude-commit-detective-findings.md" <<'EOF'
### Finding: Commit alpha
**Severity:** major
EOF

    cat > "$RAW_FINDINGS_DIR/claude-conversation-detective-findings.md" <<'EOF'
### Finding 12: Conversation beta
**Severity:** minor

### Finding 1: Some Title
**Severity:** observation
EOF

    check_total_timeout() { return 0; }
    agent_run_claude() {
        cat > "$DIGEST_PATH" <<'EOF'
# Nightshift Detective Digest — 2026-01-07

## Run Metadata
- **Run ID:** wrong-run
- **Date:** 2026-01-07
- **Detectives Run:** commit-detective, conversation-detective

## Summary
- **Total findings received:** 999
- **After deduplication:** 998
- **Duplicates merged:** 1
- **Task files created:** 9 (critical: 8, major: 1)
- **Minor/observation findings:** 7 (see digest below)

## Ranked Findings

| # | Severity | Category | Title |
|---|----------|----------|-------|
| 1 | major | regression | Commit alpha |

## Minor & Observation Findings

These findings did not warrant individual task files but are recorded for awareness.

| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
| 1 | Some Title | observation | data-quality | conversation-detective | Title summary |

## Deduplication Log

| Merged Finding | Sources | Action |
|---------------|---------|--------|
| Commit alpha | commit-detective + conversation-detective | Merged |

## Detectives Not Run
- error-detective
- coverage-detective
- product-detective
- rcfa-detective
EOF

        return 0
    }

    phase_manager_merge

    ok=true
    grep -Fq -- '- **Total findings received:** 3' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **After deduplication:** 2' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **Duplicates merged:** 1' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **Task files created:** 0 (critical: 0, major: 1)' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **Minor/observation findings:** 1 (see digest below)' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **Detectives Run:** commit-detective, conversation-detective, error-detective' "$DIGEST_PATH" || ok=false
    grep -q '^## Detectives Skipped$' "$DIGEST_PATH" || ok=false
    grep -q '^- coverage-detective$' "$DIGEST_PATH" || ok=false
    grep -q '^- product-detective$' "$DIGEST_PATH" || ok=false
    grep -q '^- rcfa-detective$' "$DIGEST_PATH" || ok=false
    grep -q '| error-detective | ran | 0 | 0 | 0 | 0 | 0 |' "$DIGEST_PATH" || ok=false
    ! grep -q '^## Detectives Not Run$' "$DIGEST_PATH" || ok=false
    [[ "$ok" == "true" ]]
) && pass "7. phase_manager_merge rewrites manager summary and detective status sections deterministically" \
  || fail "7. phase_manager_merge rewrites manager summary and detective status sections deterministically" "digest summary or detective status sections did not normalize correctly"
# ── Test 8: Setup cleanup removes stale prior-run artifacts before dry-run gate ──
(
    repo_dir="$TMP_DIR/t8/repo"
    run_dir="$TMP_DIR/t8/run"
    setup_log="$TMP_DIR/t8-phase-setup.log"
    second_setup_log="$TMP_DIR/t8-phase-setup-second.log"
    digest_artifact="$repo_dir/docs/nightshift/digests/test-artifact.md"
    task_artifact="$repo_dir/docs/tasks/open/nightshift/2026-01-08-example/competitive/run-manifest.json"

    init_test_git_repo "$repo_dir"
    mkdir -p "$(dirname "$digest_artifact")" "$(dirname "$task_artifact")" "$run_dir"
    printf 'stale digest\n' > "$digest_artifact"
    printf '{}\n' > "$task_artifact"

    export NIGHTSHIFT_REPO_DIR="$repo_dir"
    export REPO_ROOT="$repo_dir"
    export RUN_TMP_DIR="$run_dir"
    export ENV_FILE="$TMP_DIR/t8/missing.env"
    export NIGHTSHIFT_RUN_ID="test-setup-cleanup-8"

    DRY_RUN=1
    SETUP_FAILED=0
    SETUP_READY=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    COST_TRACKING_READY=0

    cost_init() { return 0; }

    phase_setup >"$setup_log" 2>&1
    output="$(cat "$setup_log")"
    status_output="$(cd "$repo_dir" && git status --porcelain --untracked-files=all -- docs/nightshift/digests docs/tasks/open/nightshift)"

    FAILURE_NOTES=""
    WARNING_NOTES=""
    SETUP_READY=0
    phase_setup >"$second_setup_log" 2>&1
    second_output="$(cat "$second_setup_log")"

    ok=true
    [[ ! -e "$digest_artifact" ]] || ok=false
    [[ ! -e "$task_artifact" ]] || ok=false
    [[ -z "$status_output" ]] || ok=false
    grep -Fq "INFO: Night Shift: cleaned prior-run artifacts from worktree" <<< "$output" || ok=false
    ! grep -Fq "INFO: Night Shift: cleaned prior-run artifacts from worktree" <<< "$second_output" || ok=false
    [[ "$SETUP_FAILED" -eq 0 ]] || ok=false
    [[ "$SETUP_READY" -eq 1 ]] || ok=false
    $ok
) && pass "8. phase_setup cleans stale Night Shift artifacts before the dry-run gate" \
  || fail "8. phase_setup cleans stale Night Shift artifacts before the dry-run gate" "artifacts survived cleanup, git status stayed dirty, or cleanup logging was wrong"
# ── Test 9: behavioral toggles are NOT protected (env file must win) ─────────
(
    protected_list="$(printf '%s\n' "${NIGHTSHIFT_PROTECTED_TUNABLES[@]}")"
    ok=true
    grep -Fxq 'NIGHTSHIFT_BRIDGE_ENABLED' <<< "$protected_list" && ok=false
    grep -Fxq 'NIGHTSHIFT_AUTOFIX_ENABLED' <<< "$protected_list" && ok=false
    grep -Fxq 'NIGHTSHIFT_BACKLOG_ENABLED' <<< "$protected_list" && ok=false
    $ok
) && pass "9. bridge, autofix, and backlog toggles are NOT protected tunables" \
  || fail "9. bridge, autofix, and backlog toggles are NOT protected tunables" "behavioral toggles should not be in protected tunables"
# ── Test 10: exported toggles survive config load (env wins) ─────────────────
(
    tmp_home="$TMP_DIR/home-toggle-env-wins"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"
    export NIGHTSHIFT_BRIDGE_ENABLED="true"
    export NIGHTSHIFT_AUTOFIX_ENABLED="true"
    export NIGHTSHIFT_BACKLOG_ENABLED="true"
    : > "$HOME/.nightshift-env"
    load_nightshift_configuration "$NS_DIR/nightshift.conf" "$HOME/.nightshift-env" >/dev/null 2>&1
    ok=true
    [[ "$NIGHTSHIFT_BRIDGE_ENABLED" == "true" ]] || ok=false
    [[ "$NIGHTSHIFT_AUTOFIX_ENABLED" == "true" ]] || ok=false
    [[ "$NIGHTSHIFT_BACKLOG_ENABLED" == "true" ]] || ok=false
    $ok
) && pass "10. exported toggles survive config load (env wins)" \
  || fail "10. exported toggles survive config load (env wins)" "toggle was overridden by conf"
# ── Test 11: unset toggles default to false from conf ────────────────────────
(
    tmp_home="$TMP_DIR/home-toggle-defaults"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"
    unset NIGHTSHIFT_BRIDGE_ENABLED NIGHTSHIFT_AUTOFIX_ENABLED NIGHTSHIFT_BACKLOG_ENABLED 2>/dev/null
    : > "$HOME/.nightshift-env"
    load_nightshift_configuration "$NS_DIR/nightshift.conf" "$HOME/.nightshift-env" >/dev/null 2>&1
    ok=true
    [[ "$NIGHTSHIFT_BRIDGE_ENABLED" == "false" ]] || ok=false
    [[ "$NIGHTSHIFT_AUTOFIX_ENABLED" == "false" ]] || ok=false
    [[ "$NIGHTSHIFT_BACKLOG_ENABLED" == "false" ]] || ok=false
    $ok
) && pass "11. unset toggles default to false from conf" \
  || fail "11. unset toggles default to false from conf" "toggle defaults were not false when unset"
# ── Test 12: Phase 1 prunes leftover nightshift/* branches ───────────────────
(
    repo_dir="$TMP_DIR/t12/repo"
    init_test_git_repo "$repo_dir"
    (
        cd "$repo_dir"
        git branch "nightshift/stale-branch"
    )

    export REPO_ROOT="$repo_dir"
    export NIGHTSHIFT_REPO_DIR="$repo_dir"
    export RUN_TMP_DIR="$TMP_DIR/t12/run"
    export ENV_FILE="$TMP_DIR/t12/missing.env"
    export NIGHTSHIFT_RUN_ID="t12"
    mkdir -p "$TMP_DIR/t12/run"

    DRY_RUN=1
    SETUP_FAILED=0
    SETUP_READY=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    COST_TRACKING_READY=0

    cost_init() { return 0; }

    phase_setup >/dev/null 2>&1

    ! (
        cd "$repo_dir"
        git branch --list 'nightshift/*' | grep -q .
    )
) && pass "12. Phase 1 prunes leftover nightshift/* branches" \
  || fail "12. Phase 1 prunes leftover nightshift/* branches" "stale branch survived"

# ── Test 13: Phase 1 preserves the checked-out nightshift/* branch ────────────
(
    repo_dir="$TMP_DIR/t13/repo"
    init_test_git_repo "$repo_dir"
    (
        cd "$repo_dir"
        git checkout -qb "nightshift/current"
        git branch "nightshift/stale-branch"
    )

    export REPO_ROOT="$repo_dir"
    export NIGHTSHIFT_REPO_DIR="$repo_dir"
    export RUN_TMP_DIR="$TMP_DIR/t13/run"
    export ENV_FILE="$TMP_DIR/t13/missing.env"
    export NIGHTSHIFT_RUN_ID="t13"
    mkdir -p "$TMP_DIR/t13/run"

    DRY_RUN=1
    SETUP_FAILED=0
    SETUP_READY=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    COST_TRACKING_READY=0

    cost_init() { return 0; }

    phase_setup >/dev/null 2>&1

    current_branch="$(cd "$repo_dir" && git branch --show-current)"
    ok=true
    [[ "$current_branch" == "nightshift/current" ]] || ok=false
    ( cd "$repo_dir" && git rev-parse --verify --quiet "refs/heads/nightshift/current" >/dev/null 2>&1 ) || ok=false
    ! ( cd "$repo_dir" && git rev-parse --verify --quiet "refs/heads/nightshift/stale-branch" >/dev/null 2>&1 ) || ok=false
    $ok
) && pass "13. Phase 1 skips pruning the checked-out nightshift/* branch" \
  || fail "13. Phase 1 skips pruning the checked-out nightshift/* branch" "current branch was pruned or stale sibling survived"

printf '\n=== Results: %d passed, %d failed (13 tests) ===\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

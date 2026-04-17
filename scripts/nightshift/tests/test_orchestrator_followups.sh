#!/usr/bin/env bash
# test_orchestrator_followups.sh — Focused tests for Session 2 Nightshift fixes.
#
# Usage: bash scripts/nightshift/tests/test_orchestrator_followups.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TMP_DIR"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

write_manager_digest_fixture() {
    local task_heading="$1"
    local minor_heading="$2"
    local digest_path="$3"
    local run_date="$4"

    cat > "$digest_path" <<EOF
# Nightshift Detective Digest — ${run_date}

## Run Metadata
- **Run ID:** wrong-run
- **Date:** ${run_date}
- **Detectives Run:** commit-detective, conversation-detective

## Summary
- **Total findings received:** 999
- **After deduplication:** 998
- **Duplicates merged:** 1
- **Task files created:** 9 (critical: 8, major: 1)
- **Minor/observation findings:** 7 (see digest below)

${task_heading}

| # | Severity | Category | Title |
|---|----------|----------|-------|
| 1 | major | regression | Commit alpha |

${minor_heading}

These findings did not warrant individual top-finding placement but are recorded for awareness.

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
}

write_manager_digest_without_findings_table_fixture() {
    local digest_path="$1"
    local run_date="$2"

    cat > "$digest_path" <<EOF
# Nightshift Detective Digest — ${run_date}

## Run Metadata
- **Run ID:** wrong-run
- **Date:** ${run_date}
- **Detectives Run:** commit-detective, conversation-detective

## Summary
- **Total findings received:** 999
- **After deduplication:** 998
- **Duplicates merged:** 1
- **Task files created:** 9 (critical: 8, major: 1)
- **Minor/observation findings:** 7 (see digest below)

## Ranked Findings

No ranked findings table was written.

## Minor & Observation Findings

These findings did not warrant individual top-finding placement but are recorded for awareness.

| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
| 1 | Some Title | observation | data-quality | conversation-detective | Title summary |
EOF
}

write_manager_digest_with_top_findings_fixture() {
    local digest_path="$1"
    local run_date="$2"

    cat > "$digest_path" <<EOF
# Nightshift Detective Digest — ${run_date}

## Run Metadata
- **Run ID:** wrong-run
- **Date:** ${run_date}
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
| 1 | critical | regression | Commit alpha |
| 2 | major | security | Security beta |
| 3 | major | data-quality | Data gamma |
| 4 | major | error-handling | Error delta |
| 5 | minor | performance | Perf epsilon |

## Minor & Observation Findings

These findings did not warrant individual top-finding placement but are recorded for awareness.

| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
| 1 | Some Title | observation | data-quality | conversation-detective | Overflow after top-5 triage cap |

## Deduplication Log

| Merged Finding | Sources | Action |
|---------------|---------|--------|
| Commit alpha | commit-detective + conversation-detective | Merged |
EOF
}

write_manager_digest_with_two_top_findings_fixture() {
    local digest_path="$1"
    local run_date="$2"

    cat > "$digest_path" <<EOF
# Nightshift Detective Digest — ${run_date}

## Run Metadata
- **Run ID:** wrong-run
- **Date:** ${run_date}
- **Detectives Run:** commit-detective, conversation-detective

## Summary
- **Total findings received:** 999
- **After deduplication:** 2
- **Duplicates merged:** 0
- **Task files created:** 9 (critical: 8, major: 1)
- **Minor/observation findings:** 0 (see digest below)

## Ranked Findings

| # | Severity | Category | Title |
|---|----------|----------|-------|
| 1 | critical | regression | Commit alpha |
| 2 | major | security | Security beta |

## Minor & Observation Findings

No minor findings.
EOF
}

write_manager_fixture_variant() {
    local variant="$1"
    local digest_path="$2"
    local run_date="$3"

    case "$variant" in
        renamed-task-files)
            write_manager_digest_fixture "## Task Files" "## Minor & Observation Findings" "$digest_path" "$run_date"
            ;;
        trailing-whitespace)
            write_manager_digest_fixture "## Ranked Findings " "## Minor & Observation Findings" "$digest_path" "$run_date"
            ;;
        case-drift)
            write_manager_digest_fixture "## ranked findings" "## Minor & Observation Findings" "$digest_path" "$run_date"
            ;;
        both-missing)
            write_manager_digest_fixture "## Task Files" "## Minor Findings" "$digest_path" "$run_date"
            ;;
        valid)
            write_manager_digest_fixture "## Ranked Findings" "## Minor & Observation Findings" "$digest_path" "$run_date"
            ;;
        valid-five)
            write_manager_digest_with_top_findings_fixture "$digest_path" "$run_date"
            ;;
        no-findings-table)
            write_manager_digest_without_findings_table_fixture "$digest_path" "$run_date"
            ;;
        missing)
            return 0
            ;;
        empty)
            : > "$digest_path"
            ;;
        *)
            return 1
            ;;
    esac
}

write_agent_result_json() {
    local output_path="$1"
    local result_text="$2"

    jq -cn \
        --arg result "${result_text}" \
        '{
            type: "result",
            result: $result,
            usage: {
                input_tokens: 1,
                cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0,
                output_tokens: 1
            }
        }' > "${output_path}"
}

write_triage_only_two_finding_digest_fixture() {
    local digest_path="$1"
    local run_date="$2"

    cat > "${digest_path}" <<EOF
# Nightshift Detective Digest — ${run_date}

## Ranked Findings

| # | Severity | Category | Title |
|---|----------|----------|-------|
| 1 | critical | regression | Commit alpha |
| 2 | major | security | Security beta |

## Minor & Observation Findings

These findings did not warrant individual top-finding placement but are recorded for awareness.

| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
| 1 | Some Title | observation | data-quality | conversation-detective | Overflow after top-5 triage cap |
EOF
}

write_followup_findings_manifest_fixture() {
    local manifest_path="$1"
    shift
    mkdir -p "$(dirname "${manifest_path}")"
    : > "${manifest_path}"

    while [[ $# -gt 0 ]]; do
        printf '%s\n' "$1" >> "${manifest_path}"
        shift
    done
}

task_writer_followup_result_text() {
    local title="$1"
    local severity="$2"
    local category="$3"

    cat <<EOF
--- BEGIN TASK FILE ---
## Task: ${title}
## Status: not started
## Created: 2026-01-16
## Execution Mode: single-agent

## Motivation
Nightshift follow-up integration fixture.

## Goal
Fix ${title}.

## Scope
### In Scope
- Exercise the Nightshift follow-up pipeline

### Out of Scope
- Anything unrelated to this fixture

## Relevant Files
- \`src/example.py\` — integration fixture reference

## Context
- Detective source: commit-detective
- Severity: ${severity}
- Category: ${category}

## Anti-Patterns
- Do NOT skip validation

## Done Criteria
- [ ] Follow-up integration fixture behaves deterministically

## Code Review: not started

## Left Off At
Not started.

## Attempts
(none)
--- END TASK FILE ---

### Task Writer Result: CREATED
EOF
}

validation_followup_valid_result_text() {
    cat <<'EOF'
### Validation Result: VALIDATED
Paths checked: 1 passed, 0 failed
Claims checked: 1 confirmed, 0 contradicted
Structure: complete
Failed checks:
- (none)
EOF
}

setup_manager_merge_fixture() {
    local case_root="$1"
    local run_date="$2"
    local run_key="$3"
    local tmp_home="$TMP_DIR/home-${run_key}"

    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"
    source "$NS_DIR/lib/agent-runner.sh"
    source "$NS_DIR/lib/lauren-bridge.sh"

    export REPO_ROOT="$case_root/repo"
    export RUN_TMP_DIR="$case_root/run"
    export RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw-findings"
    export AGENT_OUTPUT_DIR="$RUN_TMP_DIR/agent-outputs"
    export NIGHTSHIFT_FINDINGS_DIR="$case_root/findings"
    export NIGHTSHIFT_LOG_DIR="$case_root/logs"
    export NIGHTSHIFT_PLAYBOOKS_DIR="$case_root/playbooks"
    export DETECTIVE_STATUS_DIR="$RUN_TMP_DIR/detective-status"
    mkdir -p "$REPO_ROOT/docs/nightshift/digests" "$REPO_ROOT/docs/tasks/open/nightshift"
    mkdir -p "$RUN_TMP_DIR" "$RAW_FINDINGS_DIR" "$AGENT_OUTPUT_DIR"
    mkdir -p "$NIGHTSHIFT_FINDINGS_DIR" "$NIGHTSHIFT_LOG_DIR" "$NIGHTSHIFT_PLAYBOOKS_DIR" "$DETECTIVE_STATUS_DIR"

    RUN_DATE="$run_date"
    RUN_ID="test-${run_key}"
    RUN_BRANCH="nightshift/${run_date}"
    CURRENT_PHASE="3"
    SETUP_FAILED=0
    BRANCH_READY=1
    MANAGER_ALLOWED=1
    NIGHTSHIFT_MANAGER_MODEL="test-manager-model"
    NIGHTSHIFT_BASE_BRANCH="main"
    NIGHTSHIFT_PR_LABELS=""
    DRY_RUN=0
    RUN_COST_CAP=0
    RUN_FAILED=0
    RUN_CLEAN=0
    DIGEST_AVAILABLE=0
    DIGEST_STAGEABLE=0
    DIGEST_PATH=""
    DIGEST_TASK_COUNT_PATCHED=0
    TASK_FILE_COUNT=0
    TOTAL_FINDINGS_AVAILABLE=0
    MANAGER_CONTRACT_FAILED=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    COST_TRACKING_READY=0
    GH_AVAILABLE=0
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0
    BACKLOG_STAGE_PATHS=()
    PR_URL=""

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
}

setup_followup_pipeline_fixture() {
    local case_root="$1"
    local run_date="$2"
    local run_key="$3"

    setup_manager_merge_fixture "$case_root" "$run_date" "$run_key"
    source "$NS_DIR/lib/agent-runner.sh"

    CURRENT_PHASE="3.5a"
    DIGEST_PATH="${RUN_TMP_DIR}/triage-digest.md"
    DIGEST_TASK_COUNT_PATCHED=0
    NIGHTSHIFT_BRIDGE_ENABLED="true"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    NIGHTSHIFT_AUTOFIX_MAX_TASKS="5"
    NIGHTSHIFT_AUTOFIX_MIN_BUDGET="20"
    NIGHTSHIFT_AUTOFIX_SEVERITY="critical,major"
    NIGHTSHIFT_COST_CAP_USD="100"

    printf '# task-writer fixture\n' > "${NIGHTSHIFT_PLAYBOOKS_DIR}/task-writer.md"
    printf '# validation fixture\n' > "${NIGHTSHIFT_PLAYBOOKS_DIR}/validation-agent.md"
}

run_manager_drift_case() {
    local variant="$1"
    local run_date="$2"
    local run_phase4="${3:-0}"
    local case_root="$TMP_DIR/manager-drift-${variant}"

    setup_manager_merge_fixture "$case_root" "$run_date" "manager-drift-${variant}"

    check_total_timeout() { return 0; }
    agent_run_claude() {
        write_manager_fixture_variant "$variant" "$DIGEST_PATH" "$RUN_DATE"
        return 0
    }

    MANAGER_DRIFT_LOG_PATH="$TMP_DIR/manager-drift-${variant}.log"
    MANAGER_DRIFT_PHASE_RC=0
    phase_manager_merge >"$MANAGER_DRIFT_LOG_PATH" 2>&1 || MANAGER_DRIFT_PHASE_RC=$?

    MANAGER_DRIFT_SHIP_LOG_PATH=""
    MANAGER_DRIFT_SHIP_RC=0
    MANAGER_DRIFT_GIT_ADD_LOG=""
    MANAGER_DRIFT_PR_CREATE_LOG=""
    if [[ "$run_phase4" -eq 1 ]]; then
        CURRENT_PHASE="4"
        GH_AVAILABLE=1
        MANAGER_DRIFT_GIT_ADD_LOG="$TMP_DIR/manager-drift-${variant}.git-add"
        MANAGER_DRIFT_PR_CREATE_LOG="$TMP_DIR/manager-drift-${variant}.pr-create"

        git() {
            if [[ "$1" == "status" && "$2" == "--porcelain" ]]; then
                shift 2
                local status_path=""
                for status_path in "$@"; do
                    case "$status_path" in
                        "$REPO_ROOT"/docs/tasks/open/nightshift/*)
                            printf ' M %s\n' "${status_path#$REPO_ROOT/}"
                            ;;
                    esac
                done
                return 0
            fi
            if [[ "$1" == "add" ]]; then
                printf '%s\n' "$@" > "$MANAGER_DRIFT_GIT_ADD_LOG"
                return 0
            fi
            if [[ "$1" == "commit" || "$1" == "push" ]]; then
                return 0
            fi
            if [[ "$1" == "diff" && "$2" == "--cached" && "$3" == "--quiet" ]]; then
                return 1
            fi
            command git "$@"
        }

        gh() {
            if [[ "$1" == "label" && "$2" == "create" ]]; then
                return 0
            fi
            if [[ "$1" == "pr" && "$2" == "create" ]]; then
                printf '%s\n' "$@" > "$MANAGER_DRIFT_PR_CREATE_LOG"
                printf 'https://example.test/pr/drift\n'
                return 0
            fi
            return 1
        }

        git_validate_commit_message() { return 0; }
        git_validate_pr_size() { return 0; }

        MANAGER_DRIFT_SHIP_LOG_PATH="$TMP_DIR/manager-drift-${variant}.ship.log"
        phase_ship_results >"$MANAGER_DRIFT_SHIP_LOG_PATH" 2>&1 || MANAGER_DRIFT_SHIP_RC=$?
    fi
}

assert_manager_drift_failure_state() {
    local expected_marker="$1"
    local expect_empty="${2:-0}"
    local ok=true

    [[ "$MANAGER_DRIFT_PHASE_RC" -eq 0 ]] || ok=false
    [[ "$RUN_FAILED" -eq 1 ]] || ok=false
    [[ "$DIGEST_AVAILABLE" -eq 1 ]] || ok=false
    [[ "$DIGEST_STAGEABLE" -eq 0 ]] || ok=false
    grep -Fq "WARN: manager digest format drift" "$MANAGER_DRIFT_LOG_PATH" || ok=false
    grep -Fq "===== Phase 3: Manager Merge FAILED =====" "$MANAGER_DRIFT_LOG_PATH" || ok=false

    if [[ "$expect_empty" -eq 1 ]]; then
        [[ -f "$DIGEST_PATH" ]] || ok=false
        [[ ! -s "$DIGEST_PATH" ]] || ok=false
    else
        grep -Fxq -- "$expected_marker" "$DIGEST_PATH" || ok=false
        grep -Fq -- '- **Total findings received:** 999' "$DIGEST_PATH" || ok=false
        grep -Fq '## Detectives Not Run' "$DIGEST_PATH" || ok=false
    fi

    ! grep -Fq '## Detectives Skipped' "$DIGEST_PATH" || ok=false
    ! grep -Fq '## Orchestrator Summary' "$DIGEST_PATH" || ok=false
    ! grep -Fq '| error-detective | ran | 0 | 0 | 0 | 0 | 0 |' "$DIGEST_PATH" || ok=false
    [[ "$ok" == "true" ]]
}

assert_manager_no_digest_contract_failure_state() {
    local expected_message="$1"
    local ok=true

    [[ "$MANAGER_DRIFT_PHASE_RC" -eq 0 ]] || ok=false
    [[ "$RUN_FAILED" -eq 1 ]] || ok=false
    [[ "${MANAGER_CONTRACT_FAILED}" -eq 1 ]] || ok=false
    [[ "$DIGEST_AVAILABLE" -eq 0 ]] || ok=false
    [[ "$DIGEST_STAGEABLE" -eq 0 ]] || ok=false
    grep -Fq "$expected_message" "$MANAGER_DRIFT_LOG_PATH" || ok=false
    grep -Fq "===== Phase 3: Manager Merge FAILED =====" "$MANAGER_DRIFT_LOG_PATH" || ok=false
    [[ ! -e "$DIGEST_PATH" ]] || ok=false
    [[ "$ok" == "true" ]]
}

echo "=== test_orchestrator_followups.sh ==="
echo ""

# ── Test 1: Dry-run exits 0 ──────────────────────────────────────────────────
(
    tmp_home="$TMP_DIR/home-dry-run"
    mkdir -p "$tmp_home"

    set +e
    HOME="$tmp_home" bash "$NS_DIR/nightshift.sh" --dry-run >/dev/null 2>&1
    rc=$?
    set -e

    [[ "$rc" -eq 0 ]]
) && pass "1. dry-run exits 0" \
  || fail "1. dry-run exits 0" "nightshift.sh returned non-zero"

# ── Test 2: Environment override ignored and logged ──────────────────────────
(
    tmp_home="$TMP_DIR/home-env-override"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"
    export NIGHTSHIFT_COST_CAP_USD="999999"

    source "$NS_DIR/nightshift.sh"

    log_path="$TMP_DIR/env-override.log"
    load_nightshift_configuration "$NS_DIR/nightshift.conf" "$HOME/.nightshift-env" \
        >"$log_path" 2>&1

    grep -q "Ignored override of NIGHTSHIFT_COST_CAP_USD" "$log_path"
    [[ "$NIGHTSHIFT_COST_CAP_USD" == "200" ]]
) && pass "2. environment override ignored and conf value retained" \
  || fail "2. environment override ignored and conf value retained" "override was not ignored/logged as expected"

# ── Test 3: Bounds violation exits 1 with clear error ────────────────────────
(
    tmp_home="$TMP_DIR/home-bounds"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    bad_conf="$TMP_DIR/nightshift-invalid.conf"
    sed 's/^NIGHTSHIFT_COST_CAP_USD="200"/NIGHTSHIFT_COST_CAP_USD="0"/' \
        "$NS_DIR/nightshift.conf" > "$bad_conf"

    source "$NS_DIR/nightshift.sh"

    log_path="$TMP_DIR/bounds.log"
    set +e
    load_nightshift_configuration "$bad_conf" "$HOME/.nightshift-env" >"$log_path" 2>&1
    rc=$?
    set -e

    [[ "$rc" -eq 1 ]]
    grep -q "NIGHTSHIFT_COST_CAP_USD" "$log_path"
    grep -q "(> 0 and <= 500)" "$log_path"
) && pass "3. invalid protected tunable fails validation with exit 1" \
  || fail "3. invalid protected tunable fails validation with exit 1" "invalid config was accepted or error text was unclear"

# ── Test 4: Codex exit 0 + empty output closes gate ──────────────────────────
(
    tmp_home="$TMP_DIR/home-codex-empty"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    AGENT_OUTPUT_DIR="$TMP_DIR/codex-empty/outputs"
    RAW_FINDINGS_DIR="$TMP_DIR/codex-empty/raw"
    NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/codex-empty/findings"
    mkdir -p "$AGENT_OUTPUT_DIR" "$RAW_FINDINGS_DIR" "$NIGHTSHIFT_FINDINGS_DIR"

    COST_TRACKING_READY=0
    DB_PLAYBOOKS_ENABLED=1
    CODEX_MODE="pending"
    codex_calls=0

    agent_run_codex() {
        codex_calls=$((codex_calls + 1))
        return 0
    }

    log_path="$TMP_DIR/codex-empty.log"
    run_detective_call "codex" "$NS_DIR/playbooks/commit-detective.md" >"$log_path" 2>&1 || true
    run_detective_call "codex" "$NS_DIR/playbooks/conversation-detective.md" >>"$log_path" 2>&1 || true

    [[ "$CODEX_MODE" == "closed" ]]
    [[ "$codex_calls" -eq 1 ]]
    grep -q "Codex commit-detective exited 0 but no output — closing gate" "$log_path"
    grep -q "Skipping codex/conversation-detective: Codex unavailable, proceeding Claude-only" "$log_path"
) && pass "4. empty Codex output closes gate and skips remaining calls" \
  || fail "4. empty Codex output closes gate and skips remaining calls" "gate did not close on empty output"

# ── Test 5: Healthy Codex opens gate, later failure closes it ────────────────
(
    tmp_home="$TMP_DIR/home-codex-transition"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    AGENT_OUTPUT_DIR="$TMP_DIR/codex-transition/outputs"
    RAW_FINDINGS_DIR="$TMP_DIR/codex-transition/raw"
    NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/codex-transition/findings"
    mkdir -p "$AGENT_OUTPUT_DIR" "$RAW_FINDINGS_DIR" "$NIGHTSHIFT_FINDINGS_DIR"

    COST_TRACKING_READY=0
    DB_PLAYBOOKS_ENABLED=1
    CODEX_MODE="pending"
    codex_calls=0

    agent_run_codex() {
        local _playbook_path="$1"
        local _output_path="$2"
        codex_calls=$((codex_calls + 1))

        case "$codex_calls" in
            1)
                printf 'healthy output\n' > "$_output_path"
                return 0
                ;;
            2)
                return 1
                ;;
            *)
                printf 'unexpected third invocation\n' > "$_output_path"
                return 0
                ;;
        esac
    }

    log_path="$TMP_DIR/codex-transition.log"
    run_detective_call "codex" "$NS_DIR/playbooks/commit-detective.md" >"$log_path" 2>&1 || true
    [[ "$CODEX_MODE" == "open" ]]

    run_detective_call "codex" "$NS_DIR/playbooks/conversation-detective.md" >>"$log_path" 2>&1 || true
    run_detective_call "codex" "$NS_DIR/playbooks/product-detective.md" >>"$log_path" 2>&1 || true

    [[ "$CODEX_MODE" == "closed" ]]
    [[ "$codex_calls" -eq 2 ]]
    grep -q "Codex available: first Codex call succeeded" "$log_path"
    grep -q "Codex conversation-detective failed with exit 1 — closing gate" "$log_path"
    grep -q "Skipping codex/product-detective: Codex unavailable, proceeding Claude-only" "$log_path"
) && pass "5. healthy Codex opens gate and later failure closes it permanently" \
  || fail "5. healthy Codex opens gate and later failure closes it permanently" "state machine did not transition as expected"

# ── Test 6: Digest path includes run suffix for reruns ───────────────────────
(
    tmp_home="$TMP_DIR/home-digest-path"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    RUN_DATE="2026-03-27"
    RUN_BRANCH="nightshift/2026-03-27"
    update_run_suffix_from_branch "$RUN_BRANCH"
    first_path="$(repo_digest_path)"

    RUN_BRANCH="nightshift/2026-03-27-2"
    update_run_suffix_from_branch "$RUN_BRANCH"
    second_path="$(repo_digest_path)"

    [[ "$first_path" == "$REPO_ROOT/docs/nightshift/digests/2026-03-27.md" ]]
    [[ "$second_path" == "$REPO_ROOT/docs/nightshift/digests/2026-03-27-2.md" ]]
) && pass "6. rerun digest path gets a numeric suffix" \
  || fail "6. rerun digest path gets a numeric suffix" "digest paths did not disambiguate reruns"

# ── Test 7: rcfa-detective is wired into rebuild_manager_inputs() ───────────
(
    tmp_home="$TMP_DIR/home-rcfa-rebuild"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/rcfa-rebuild/findings"
    RAW_FINDINGS_DIR="$TMP_DIR/rcfa-rebuild/raw"
    mkdir -p "$NIGHTSHIFT_FINDINGS_DIR" "$RAW_FINDINGS_DIR"

    # Seed a raw findings file for rcfa-detective so rebuild has something to merge
    mkdir -p "$RAW_FINDINGS_DIR"
    printf '### Finding: test\n' > "$RAW_FINDINGS_DIR/claude-rcfa-detective-findings.md"

    rebuild_manager_inputs

    [[ -s "$NIGHTSHIFT_FINDINGS_DIR/rcfa-detective-findings.md" ]]
    grep -q "Finding:" "$NIGHTSHIFT_FINDINGS_DIR/rcfa-detective-findings.md"
) && pass "7. rcfa-detective-findings.md rebuilt non-empty with seeded content" \
  || fail "7. rcfa-detective-findings.md rebuilt non-empty with seeded content" "rcfa-detective-findings.md was not rebuilt or is empty"

# ── Test 8: rcfa-detective is in phase_detectives() invocation list ─────────
(
    tmp_home="$TMP_DIR/home-rcfa-phase"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    # Verify the nightshift.sh source contains rcfa-detective in phase_detectives()
    # by checking for the playbook path reference in the function body
    grep -A 200 '^phase_detectives()' "$NS_DIR/nightshift.sh" \
        | grep -q 'rcfa-detective.md'
) && pass "8. rcfa-detective.md referenced in phase_detectives()" \
  || fail "8. rcfa-detective.md referenced in phase_detectives()" "rcfa-detective missing from phase_detectives"

# ── Test 9: rcfa-detective is wired into playbook_requires_db() ────────────
(
    tmp_home="$TMP_DIR/home-rcfa-db"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    playbook_requires_db "rcfa-detective"
) && pass "9. playbook_requires_db() recognizes rcfa-detective" \
  || fail "9. playbook_requires_db() recognizes rcfa-detective" "rcfa-detective not recognized by playbook_requires_db"

# ── Test 10: agent_render_playbook substitutes {{RCFA_WINDOW_DAYS}} ─────────
(
    tmp_home="$TMP_DIR/home-render-rcfa"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"
    load_nightshift_configuration "$NS_DIR/nightshift.conf" "$HOME/.nightshift-env" >/dev/null 2>&1
    source "$NS_DIR/lib/agent-runner.sh"

    NIGHTSHIFT_RCFA_WINDOW_DAYS=42
    NIGHTSHIFT_RENDERED_DIR="$TMP_DIR/rendered-rcfa"
    mkdir -p "$NIGHTSHIFT_RENDERED_DIR"

    # Create a temp playbook with the template variable
    tmp_playbook="$TMP_DIR/test-rcfa-template.md"
    printf 'Window: {{RCFA_WINDOW_DAYS}} days\n' > "$tmp_playbook"

    rendered_path=$(agent_render_playbook "$tmp_playbook" 2>/dev/null)

    [[ -n "$rendered_path" ]] \
        && [[ -f "$rendered_path" ]] \
        && grep -q "42" "$rendered_path" \
        && ! grep -q '{{RCFA_WINDOW_DAYS}}' "$rendered_path"
) && pass "10. agent_render_playbook substitutes {{RCFA_WINDOW_DAYS}}" \
  || fail "10. agent_render_playbook substitutes {{RCFA_WINDOW_DAYS}}" "template variable not substituted"

# ── Test 11: agent_run_codex uses temporary unsandboxed exec invocation ─────
(
    REPO_ROOT="$TMP_DIR/repo-codex-exec"
    stub_dir="$TMP_DIR/bin-codex-exec"
    mkdir -p "$REPO_ROOT" "$stub_dir"

    export CAPTURE_ARGS_PATH="$TMP_DIR/codex-exec.args"
    cat > "$stub_dir/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_ARGS_PATH"
printf 'hello\n'
EOF
    cat > "$stub_dir/timeout" <<'EOF'
#!/usr/bin/env bash
shift
"$@"
EOF
    chmod +x "$stub_dir/codex"
    chmod +x "$stub_dir/timeout"
    PATH="$stub_dir:$PATH"

    source "$NS_DIR/nightshift.conf"
    source "$NS_DIR/lib/cost-tracker.sh"
    source "$NS_DIR/lib/agent-runner.sh"

    NIGHTSHIFT_RENDERED_DIR="$TMP_DIR/rendered-codex-exec"
    NIGHTSHIFT_LOG_DIR="$TMP_DIR/logs-codex-exec"
    NIGHTSHIFT_COST_STATE_FILE="$TMP_DIR/state-codex-exec.json"
    NIGHTSHIFT_COST_CSV="$TMP_DIR/cost-codex-exec.csv"
    mkdir -p "$NIGHTSHIFT_RENDERED_DIR" "$NIGHTSHIFT_LOG_DIR"
    cost_init "test-codex-exec" >/dev/null 2>&1

    playbook="$TMP_DIR/commit-detective.md"
    output="$TMP_DIR/codex-exec.out"
    printf 'Investigate {{DATE}}\n' > "$playbook"

    agent_run_codex "$playbook" "$output" >/dev/null 2>&1 &&
    [[ "$NIGHTSHIFT_CODEX_MODEL" == "azure54" ]] &&
    grep -qx 'exec' "$CAPTURE_ARGS_PATH" &&
    grep -qx -- '-p' "$CAPTURE_ARGS_PATH" &&
    grep -qx 'azure54' "$CAPTURE_ARGS_PATH" &&
    grep -qx -- '-C' "$CAPTURE_ARGS_PATH" &&
    grep -qx "$REPO_ROOT" "$CAPTURE_ARGS_PATH" &&
    grep -qx -- '-c' "$CAPTURE_ARGS_PATH" &&
    grep -Fxq 'model_reasoning_effort="high"' "$CAPTURE_ARGS_PATH" &&
    grep -qx -- '--dangerously-bypass-approvals-and-sandbox' "$CAPTURE_ARGS_PATH" &&
    ! grep -qx -- '--model' "$CAPTURE_ARGS_PATH" &&
    ! grep -qx -- '--quiet' "$CAPTURE_ARGS_PATH" &&
    ! grep -qx -- '--ask-for-approval' "$CAPTURE_ARGS_PATH" &&
    ! grep -qx -- '--sandbox' "$CAPTURE_ARGS_PATH" &&
    grep -qx 'hello' "$output"
) && pass "11. agent_run_codex defaults to azure54, forces high reasoning, and uses temporary unsandboxed flags" \
  || fail "11. agent_run_codex defaults to azure54, forces high reasoning, and uses temporary unsandboxed flags" "Codex runner did not use the expected temporary invocation"

# ── Test 12: phase_detectives is playbook-first and Codex gate stays local ───
(
    tmp_home="$TMP_DIR/home-phase-order"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    RUN_TMP_DIR="$TMP_DIR/phase-order/run"
    AGENT_OUTPUT_DIR="$RUN_TMP_DIR/outputs"
    RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw"
    NIGHTSHIFT_FINDINGS_DIR="$RUN_TMP_DIR/findings"
    NIGHTSHIFT_PLAYBOOKS_DIR="$RUN_TMP_DIR/playbooks"
    NIGHTSHIFT_LOG_DIR="$RUN_TMP_DIR/logs"
    mkdir -p "$AGENT_OUTPUT_DIR" "$RAW_FINDINGS_DIR" "$NIGHTSHIFT_FINDINGS_DIR" \
        "$NIGHTSHIFT_PLAYBOOKS_DIR" "$NIGHTSHIFT_LOG_DIR"

    for playbook_name in "${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}"; do
        printf '# %s\n' "$playbook_name" > "$NIGHTSHIFT_PLAYBOOKS_DIR/${playbook_name}.md"
    done

    DRY_RUN=0
    SETUP_FAILED=0
    SETUP_READY=1
    CLAUDE_AVAILABLE=1
    DB_PLAYBOOKS_ENABLED=1
    COST_TRACKING_READY=0
    RUN_COST_CAP=0
    RUN_FAILED=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    CODEX_MODE="pending"
    CODEX_ATTEMPT_COUNT=0
    codex_calls=0
    trace_path="$TMP_DIR/phase-order.trace"
    : > "$trace_path"

    check_total_timeout() { return 0; }
    agent_run_claude() {
        local _playbook_path="$1"
        local _output_path="$2"
        printf 'claude/%s\n' "$(basename "$_playbook_path" .md)" >> "$trace_path"
        printf 'claude output\n' > "$_output_path"
        return 0
    }
    agent_run_codex() {
        local _playbook_path="$1"
        local _output_path="$2"
        codex_calls=$((codex_calls + 1))
        printf 'codex/%s\n' "$(basename "$_playbook_path" .md)" >> "$trace_path"

        case "$codex_calls" in
            1)
                printf 'codex output\n' > "$_output_path"
                return 0
                ;;
            2)
                return 1
                ;;
            *)
                printf 'unexpected codex invocation\n' > "$_output_path"
                return 0
                ;;
        esac
    }

    log_path="$TMP_DIR/phase-order.log"
    phase_detectives >"$log_path" 2>&1 || true

    trace_lines=()
    if [[ -f "$trace_path" ]]; then
        while IFS= read -r trace_line; do
            trace_lines+=("$trace_line")
        done < "$trace_path"
    fi
    if [[ "${#trace_lines[@]}" -gt 0 ]]; then
        actual_trace="$(printf '%s\n' "${trace_lines[@]}")"
    else
        actual_trace=""
    fi
    expected_trace=$'claude/commit-detective\ncodex/commit-detective\nclaude/conversation-detective\ncodex/conversation-detective\nclaude/coverage-detective\nclaude/error-detective\nclaude/product-detective\nclaude/rcfa-detective\nclaude/security-detective\nclaude/performance-detective'

    ok=true
    [[ "$codex_calls" -eq 2 ]] || ok=false
    [[ "$CODEX_MODE" == "closed" ]] || ok=false
    [[ "${#trace_lines[@]}" -eq 10 ]] || ok=false
    [[ "${actual_trace}" == "${expected_trace}" ]] || ok=false
    grep -q "Codex conversation-detective failed with exit 1 — closing gate" "$log_path" || ok=false
    grep -q "Skipping codex/coverage-detective: Codex unavailable, proceeding Claude-only" "$log_path" || ok=false
    grep -q "Skipping codex/rcfa-detective: Codex unavailable, proceeding Claude-only" "$log_path" || ok=false
    grep -q "Skipping codex/security-detective: Codex unavailable, proceeding Claude-only" "$log_path" || ok=false
    grep -q "Skipping codex/performance-detective: Codex unavailable, proceeding Claude-only" "$log_path" || ok=false
    [[ "$ok" == "true" ]]
) && pass "12. phase_detectives stays playbook-first and skips only later Codex variants" \
  || fail "12. phase_detectives stays playbook-first and skips only later Codex variants" "detective ordering or Codex gate scope regressed"

# ── Test 13: phase_ship_results preflights every configured PR label ─────────
(
    tmp_home="$TMP_DIR/home-label-preflight"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    REPO_ROOT="$TMP_DIR/ship-labels/repo"
    RUN_DATE="2026-04-01"
    RUN_BRANCH="nightshift/2026-04-01"
    NIGHTSHIFT_BASE_BRANCH="main"
    NIGHTSHIFT_PR_LABELS="nightshift, auto-generated, triage-needed"
    DRY_RUN=0
    RUN_COST_CAP=0
    RUN_CLEAN=0
    RUN_FAILED=0
    BRANCH_READY=1
    GH_AVAILABLE=1
    DIGEST_STAGEABLE=1
    TASK_FILE_COUNT=3
    TOTAL_FINDINGS_AVAILABLE=7
    BRIDGE_STAGE_PATHS=()
    BACKLOG_STAGE_PATHS=()
    PR_URL=""

    DIGEST_PATH="$REPO_ROOT/docs/nightshift/digests/${RUN_DATE}.md"
    mkdir -p "$(dirname "$DIGEST_PATH")"
    printf '# Digest\n' > "$DIGEST_PATH"

    git_validate_commit_message() { return 0; }
    git_validate_pr_size() { return 0; }

    label_log="$TMP_DIR/ship-labels.preflight"
    pr_create_log="$TMP_DIR/ship-labels.create"

    git() {
        if [[ "$1" == "status" && "$2" == "--porcelain" ]]; then
            printf ' M docs/nightshift/digests/%s.md\n' "$RUN_DATE"
            return 0
        fi
        if [[ "$1" == "add" || "$1" == "commit" || "$1" == "push" ]]; then
            return 0
        fi
        if [[ "$1" == "diff" && "$2" == "--cached" && "$3" == "--quiet" ]]; then
            return 1
        fi
        command git "$@"
    }

    gh() {
        if [[ "$1" == "label" && "$2" == "create" ]]; then
            printf '%s\n' "$3" >> "$label_log"
            return 0
        fi
        if [[ "$1" == "pr" && "$2" == "create" ]]; then
            printf '%s\n' "$@" > "$pr_create_log"
            printf 'https://example.test/pr/456\n'
            return 0
        fi
        return 1
    }

    ship_log="$TMP_DIR/ship-labels.log"
    phase_rc=0
    phase_ship_results >"$ship_log" 2>&1 || phase_rc=$?

    preflighted_labels=()
    if [[ -f "$label_log" ]]; then
        while IFS= read -r label_name; do
            preflighted_labels+=("$label_name")
        done < "$label_log"
    fi

    pr_args=()
    if [[ -f "$pr_create_log" ]]; then
        while IFS= read -r pr_arg; do
            pr_args+=("$pr_arg")
        done < "$pr_create_log"
    fi
    pr_labels=()
    for ((i = 0; i < ${#pr_args[@]}; i++)); do
        if [[ "${pr_args[i]}" == "--label" && $((i + 1)) -lt ${#pr_args[@]} ]]; then
            pr_labels+=("${pr_args[i + 1]}")
        fi
    done
    if [[ "${#preflighted_labels[@]}" -gt 0 ]]; then
        actual_preflighted="$(printf '%s\n' "${preflighted_labels[@]}")"
    else
        actual_preflighted=""
    fi
    if [[ "${#pr_labels[@]}" -gt 0 ]]; then
        actual_pr_labels="$(printf '%s\n' "${pr_labels[@]}")"
    else
        actual_pr_labels=""
    fi
    expected_labels=$'nightshift\nauto-generated\ntriage-needed'

    ok=true
    [[ "$phase_rc" -eq 0 ]] || ok=false
    [[ "${PR_URL}" == "https://example.test/pr/456" ]] || ok=false
    [[ "${#preflighted_labels[@]}" -eq 3 ]] || ok=false
    [[ "${#pr_labels[@]}" -eq 3 ]] || ok=false
    [[ "${actual_preflighted}" == "${expected_labels}" ]] || ok=false
    [[ "${actual_pr_labels}" == "${expected_labels}" ]] || ok=false
    [[ "$ok" == "true" ]]
) && pass "13. phase_ship_results preflights every configured label and reuses the same list for gh pr create" \
  || fail "13. phase_ship_results preflights every configured label and reuses the same list for gh pr create" "configured labels diverged between preflight and PR creation"

# ── Test 14: finding counter accepts numbered drift variants ─────────────────
(
    tmp_home="$TMP_DIR/home-finding-counter"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    findings_file="$TMP_DIR/finding-counter.md"
    cat > "$findings_file" <<'EOF'
### Finding: Plain title
### Finding 1: Single digit title
### Finding 12: Multi-digit title
### Finding 1: Some Title
### Not A Finding
EOF

    [[ "$(count_findings_in_file "$findings_file")" == "4" ]]
) && pass "14. count_findings_in_file accepts numbered and multi-digit finding headers" \
  || fail "14. count_findings_in_file accepts numbered and multi-digit finding headers" "finding counter missed a supported header variant"

# ── Test 15: rebuild_manager_inputs normalizes headers and stamps statuses ───
(
    tmp_home="$TMP_DIR/home-manager-inputs"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    RUN_DATE="2026-01-07"
    RUN_TMP_DIR="$TMP_DIR/manager-inputs/run"
    RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw"
    NIGHTSHIFT_FINDINGS_DIR="$TMP_DIR/manager-inputs/findings"
    DETECTIVE_STATUS_DIR="$RUN_TMP_DIR/detective-status"
    mkdir -p "$RAW_FINDINGS_DIR" "$NIGHTSHIFT_FINDINGS_DIR" "$DETECTIVE_STATUS_DIR"

    reset_detective_statuses
    set_detective_status "error-detective" "ran"

    cat > "$RAW_FINDINGS_DIR/claude-conversation-detective-findings.md" <<'EOF'
### Finding 12: Multi-digit title
**Severity:** major

### Finding 1: Some Title
**Severity:** observation
EOF

    rebuild_manager_inputs

    conversation_path="$NIGHTSHIFT_FINDINGS_DIR/conversation-detective-findings.md"
    error_path="$NIGHTSHIFT_FINDINGS_DIR/error-detective-findings.md"
    coverage_path="$NIGHTSHIFT_FINDINGS_DIR/coverage-detective-findings.md"

    ok=true
    grep -q '^## Detective: conversation-detective | status=ran | findings=2$' "$conversation_path" || ok=false
    grep -q '^### Finding: Multi-digit title$' "$conversation_path" || ok=false
    grep -q '^### Finding: Some Title$' "$conversation_path" || ok=false
    grep -q '^## Detective: error-detective | status=ran | findings=0$' "$error_path" || ok=false
    grep -q '^## Detective: coverage-detective | status=skipped | findings=0$' "$coverage_path" || ok=false
    [[ "$ok" == "true" ]]
) && pass "15. rebuild_manager_inputs writes canonical status headers and normalized findings" \
  || fail "15. rebuild_manager_inputs writes canonical status headers and normalized findings" "manager input rebuild did not normalize headers or status metadata"

# ── Test 16: manager heading drift fails phase and preserves raw digest ──────
(
    run_manager_drift_case "renamed-task-files" "2026-01-08"
    ok=true
    assert_manager_drift_failure_state "## Task Files" || ok=false
    grep -Fq "WARN: manager digest format drift — expected heading '## Ranked Findings' not found" "$MANAGER_DRIFT_LOG_PATH" || ok=false
    ! grep -Fxq '## Ranked Findings' "$DIGEST_PATH" || ok=false
    [[ "$ok" == "true" ]]
) && pass "16. manager heading drift fails Phase 3 and preserves raw digest output" \
  || fail "16. manager heading drift fails Phase 3 and preserves raw digest output" "format drift was not surfaced or the raw digest was rewritten"

# ── Test 17: drift-failed manager runs skip shipping entirely ────────────────
(
    run_manager_drift_case "renamed-task-files" "2026-01-09" "1"
    ok=true
    assert_manager_drift_failure_state "## Task Files" || ok=false
    [[ "$MANAGER_DRIFT_SHIP_RC" -eq 0 ]] || ok=false
    [[ -z "${PR_URL}" ]] || ok=false
    grep -Fq "Phase 4 skipped because manager contract failed" "$MANAGER_DRIFT_SHIP_LOG_PATH" || ok=false
    grep -Fq "===== Phase 4: Ship Results SKIPPED =====" "$MANAGER_DRIFT_SHIP_LOG_PATH" || ok=false
    [[ ! -e "$MANAGER_DRIFT_GIT_ADD_LOG" ]] || ok=false
    [[ ! -e "$MANAGER_DRIFT_PR_CREATE_LOG" ]] || ok=false
    [[ "$ok" == "true" ]]
) && pass "17. drift-failed manager runs skip Phase 4 shipping and create no PR" \
  || fail "17. drift-failed manager runs skip Phase 4 shipping and create no PR" "Phase 4 still attempted shipping after manager contract failure"

# ── Test 18: drift variants all fail closed and preserve raw output ──────────
(
    ok=true
    while IFS='|' read -r variant run_date expected_marker expect_empty; do
        run_manager_drift_case "$variant" "$run_date"
        assert_manager_drift_failure_state "$expected_marker" "$expect_empty" || ok=false
        case "$variant" in
            both-missing)
                grep -Fxq '## Task Files' "$DIGEST_PATH" || ok=false
                grep -Fxq '## Minor Findings' "$DIGEST_PATH" || ok=false
                ;;
        esac
    done <<'EOF'
trailing-whitespace|2026-01-10|## Ranked Findings |0
case-drift|2026-01-11|## ranked findings|0
both-missing|2026-01-12|## Minor Findings|0
EOF
    [[ "$ok" == "true" ]]
) && pass "18. alternate drift variants fail closed, preserve raw output, and clear DIGEST_STAGEABLE" \
  || fail "18. alternate drift variants fail closed, preserve raw output, and clear DIGEST_STAGEABLE" "one or more drift variants did not fail closed"

# ── Test 19: exit 0 with no digest artifact hard-fails and blocks shipping ──
(
    setup_manager_merge_fixture "$TMP_DIR/manager-no-digest" "2026-01-13" "manager-no-digest"

    check_total_timeout() { return 0; }
    agent_run_claude() {
        printf '{"result":"no digest artifact"}\n' > "${AGENT_OUTPUT_DIR}/manager-merge.json"
        return 0
    }

    log_path="$TMP_DIR/manager-no-digest.log"
    phase_rc=0
    phase_manager_merge >"$log_path" 2>&1 || phase_rc=$?
    MANAGER_DRIFT_PHASE_RC=$phase_rc
    MANAGER_DRIFT_LOG_PATH=$log_path

    ship_log="$TMP_DIR/manager-no-digest.ship.log"
    git_call_log="$TMP_DIR/manager-no-digest.git.log"
    gh_call_log="$TMP_DIR/manager-no-digest.gh.log"
    CURRENT_PHASE="4"
    GH_AVAILABLE=1
    git() {
        printf '%s\n' "$*" >> "$git_call_log"
        return 0
    }
    gh() {
        printf '%s\n' "$*" >> "$gh_call_log"
        return 0
    }
    ship_rc=0
    phase_ship_results >"$ship_log" 2>&1 || ship_rc=$?

    ok=true
    [[ "$phase_rc" -eq 0 ]] || ok=false
    assert_manager_no_digest_contract_failure_state "Manager contract failure: exit 0 but no digest artifact" || ok=false
    [[ -f "${AGENT_OUTPUT_DIR}/manager-merge.json" ]] || ok=false
    [[ "$ship_rc" -eq 0 ]] || ok=false
    [[ -z "${PR_URL}" ]] || ok=false
    grep -Fq "Manager merge output preview: no digest artifact" "$log_path" || ok=false
    grep -Fq "Phase 4 skipped because manager contract failed" "$ship_log" || ok=false
    grep -Fq "===== Phase 4: Ship Results SKIPPED =====" "$ship_log" || ok=false
    [[ ! -e "$git_call_log" ]] || ok=false
    [[ ! -e "$gh_call_log" ]] || ok=false
    [[ "$ok" == "true" ]]
) && pass "19. manager exit 0 without a digest hard-fails and blocks downstream shipping" \
  || fail "19. manager exit 0 without a digest hard-fails and blocks downstream shipping" "missing digest contract failure did not stop downstream phases"

# ── Test 20: findings available with no findings table hard-fails ────────────
(
    setup_manager_merge_fixture "$TMP_DIR/manager-no-findings-table" "2026-01-14" "manager-no-findings-table"

    check_total_timeout() { return 0; }
    count_total_findings() { echo "37"; }
    agent_run_claude() {
        write_manager_fixture_variant "no-findings-table" "$DIGEST_PATH" "$RUN_DATE"
        return 0
    }

    log_path="$TMP_DIR/manager-no-findings-table.log"
    phase_rc=0
    phase_manager_merge >"$log_path" 2>&1 || phase_rc=$?

    ok=true
    [[ "$phase_rc" -eq 0 ]] || ok=false
    [[ "$RUN_FAILED" -eq 1 ]] || ok=false
    [[ "${MANAGER_CONTRACT_FAILED}" -eq 1 ]] || ok=false
    [[ "$DIGEST_AVAILABLE" -eq 1 ]] || ok=false
    [[ "$DIGEST_STAGEABLE" -eq 0 ]] || ok=false
    grep -Fq "Manager contract failure: findings available but digest top-findings table is empty" "$log_path" || ok=false
    grep -Fq "===== Phase 3: Manager Merge FAILED =====" "$log_path" || ok=false
    grep -Fxq '## Ranked Findings' "$DIGEST_PATH" || ok=false
    grep -Fq 'No ranked findings table was written.' "$DIGEST_PATH" || ok=false
    [[ ! -e "${RUN_TMP_DIR}/findings-manifest.txt" ]] || ok=false
    [[ "$ok" == "true" ]]
) && pass "20. findings with no ranked findings table hard-fail the manager contract" \
  || fail "20. findings with no ranked findings table hard-fail the manager contract" "missing top-findings table was not treated as a contract failure"

# ── Test 21: valid ranked findings digest writes findings-manifest.txt ───────
(
    setup_manager_merge_fixture "$TMP_DIR/findings-manifest" "2026-01-15" "findings-manifest"

    check_total_timeout() { return 0; }
    count_total_findings() { echo "7"; }
    agent_run_claude() {
        write_manager_fixture_variant "valid-five" "$DIGEST_PATH" "$RUN_DATE"
        return 0
    }

    log_path="$TMP_DIR/findings-manifest.log"
    phase_rc=0
    phase_manager_merge >"$log_path" 2>&1 || phase_rc=$?

    manifest_path="${RUN_TMP_DIR}/findings-manifest.txt"

    ok=true
    [[ "$phase_rc" -eq 0 ]] || ok=false
    [[ "$RUN_FAILED" -eq 0 ]] || ok=false
    [[ "${MANAGER_CONTRACT_FAILED}" -eq 0 ]] || ok=false
    [[ "$DIGEST_STAGEABLE" -eq 1 ]] || ok=false
    [[ "$TASK_FILE_COUNT" == "0" ]] || ok=false
    grep -Fq "===== Phase 3: Manager Merge OK =====" "$log_path" || ok=false
    grep -Fq -- '- **Total findings received:** 7' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **After deduplication:** 6' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **Duplicates merged:** 1' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **Task files created:** 0 (critical: 1, major: 3)' "$DIGEST_PATH" || ok=false
    grep -Fq -- '- **Minor/observation findings:** 1 (see digest below)' "$DIGEST_PATH" || ok=false
    [[ -f "$manifest_path" ]] || ok=false
    [[ "$(wc -l < "$manifest_path" | tr -d '[:space:]')" == "5" ]] || ok=false
    grep -Fxq $'1\tcritical\tregression\tCommit alpha' "$manifest_path" || ok=false
    grep -Fxq $'5\tminor\tperformance\tPerf epsilon' "$manifest_path" || ok=false
    grep -Fq '## Detectives Skipped' "$DIGEST_PATH" || ok=false
    grep -Fq '## Orchestrator Summary' "$DIGEST_PATH" || ok=false
    [[ "$ok" == "true" ]]
) && pass "21. valid ranked findings digests succeed and write findings-manifest.txt" \
  || fail "21. valid ranked findings digests succeed and write findings-manifest.txt" "findings manifest writing or digest normalization regressed"

# ── Test 22: triage-only output still skips when follow-up phases are not run ──
(
    setup_manager_merge_fixture "$TMP_DIR/triage-only-followups" "2026-01-16" "triage-only-followups"

    check_total_timeout() { return 0; }
    count_total_findings() { echo "7"; }
    agent_run_claude() {
        write_manager_fixture_variant "valid-five" "$DIGEST_PATH" "$RUN_DATE"
        return 0
    }

    manager_log="$TMP_DIR/triage-only-followups.manager.log"
    validation_log="$TMP_DIR/triage-only-followups.validation.log"
    bridge_log="$TMP_DIR/triage-only-followups.bridge.log"
    manager_rc=0
    validation_rc=0
    bridge_rc=0

    phase_manager_merge >"$manager_log" 2>&1 || manager_rc=$?

    NIGHTSHIFT_BRIDGE_ENABLED="true"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"

    phase_validation >"$validation_log" 2>&1 || validation_rc=$?
    phase_bridge >"$bridge_log" 2>&1 || bridge_rc=$?

    ok=true
    [[ "$manager_rc" -eq 0 ]] || ok=false
    [[ "$validation_rc" -eq 0 ]] || ok=false
    [[ "$bridge_rc" -eq 0 ]] || ok=false
    [[ -f "${RUN_TMP_DIR}/findings-manifest.txt" ]] || ok=false
    [[ ! -e "${RUN_TMP_DIR}/manager-task-manifest.txt" ]] || ok=false
    grep -Fq 'Triage metadata found but no task files produced — task-writer phase not yet wired. Skipping validation.' "${validation_log}" || ok=false
    grep -Fq '===== Phase 3.5b: Task Validation SKIPPED =====' "${validation_log}" || ok=false
    grep -Fq 'Bridge skip: findings-manifest contains triage metadata only — no task files to materialize. Task-writer phase required.' "${bridge_log}" || ok=false
    grep -Fq '===== Phase 3.6: Lauren Loop Bridge SKIPPED =====' "${bridge_log}" || ok=false
    [[ "${VALIDATION_TOTAL_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    [[ "${#VALIDATED_TASKS[@]}" -eq 0 ]] || ok=false
    [[ "${BRIDGE_SKIPPED}" -eq 1 ]] || ok=false
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 0 ]] || ok=false
    [[ -z "$(find "${REPO_ROOT}/docs/tasks/open" -maxdepth 1 -type d -name 'nightshift-bridge-*' -print -quit)" ]] || ok=false
    [[ "$ok" == "true" ]]
) && pass "22. triage-only output still skips validation and bridge when no task-writing manifest exists" \
  || fail "22. triage-only output still skips validation and bridge when no task-writing manifest exists" "triage-only downstream skip handling regressed"

# ── Test 23: full triage -> task-writing -> validation -> bridge pipeline works ──
(
    setup_followup_pipeline_fixture "$TMP_DIR/followup-pipeline" "2026-01-17" "followup-pipeline"

    write_triage_only_two_finding_digest_fixture "${DIGEST_PATH}" "${RUN_DATE}"
    write_followup_findings_manifest_fixture \
        "$(findings_manifest_path)" \
        $'1\tcritical\tregression\tCommit alpha' \
        $'2\tmajor\tsecurity\tSecurity beta'

    agent_run_claude() {
        local playbook_path="$1"
        local output_path="$2"
        local playbook_name=""

        playbook_name="$(basename "${playbook_path}")"
        case "${playbook_name}" in
            task-writer.md)
                if [[ "${output_path}" == *rank-1.json ]]; then
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Commit alpha" "critical" "regression")"
                else
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Security beta" "major" "security")"
                fi
                ;;
            validation-agent.md)
                write_agent_result_json "${output_path}" "$(validation_followup_valid_result_text)"
                ;;
            *)
                return 1
                ;;
        esac
        return 0
    }

    task_log="$TMP_DIR/followup-pipeline.task.log"
    validation_log="$TMP_DIR/followup-pipeline.validation.log"
    bridge_log="$TMP_DIR/followup-pipeline.bridge.log"
    task_rc=0
    validation_rc=0
    bridge_rc=0

    phase_task_writing >"$task_log" 2>&1 || task_rc=$?
    phase_validation >"$validation_log" 2>&1 || validation_rc=$?
    phase_bridge >"$bridge_log" 2>&1 || bridge_rc=$?

    manifest_path="$(manager_task_manifest_path)"
    created_count="$(find "${REPO_ROOT}/docs/tasks/open/nightshift" -maxdepth 1 -type f -name "${RUN_DATE}-*.md" | wc -l | tr -d '[:space:]')"

    ok=true
    [[ "$task_rc" -eq 0 ]] || ok=false
    [[ "$validation_rc" -eq 0 ]] || ok=false
    [[ "$bridge_rc" -eq 0 ]] || ok=false
    [[ -f "$(findings_manifest_path)" ]] || ok=false
    [[ "${created_count}" == "2" ]] || ok=false
    [[ -f "${manifest_path}" ]] || ok=false
    [[ "$(wc -l < "${manifest_path}" | tr -d '[:space:]')" == "2" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 2 ]] || ok=false
    [[ "${#VALIDATED_TASKS[@]}" -eq 2 ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "2" ]] || ok=false
    [[ "${BRIDGE_SKIPPED}" -eq 0 ]] || ok=false
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 2 ]] || ok=false
    grep -Fq 'Bridge: digest is triage-only but task manifest exists with 2 task file(s). Reading paths from manifest.' "${bridge_log}" || ok=false
    [[ "$ok" == "true" ]]
) && pass "23. triage-only digest flows through task-writing, validation, and bridge via manager-task-manifest" \
  || fail "23. triage-only digest flows through task-writing, validation, and bridge via manager-task-manifest" "full follow-up pipeline did not bridge manifest-backed tasks"

# ── Test 24: bridge warns on one missing manifest path and processes survivors ──
(
    setup_followup_pipeline_fixture "$TMP_DIR/followup-partial-bridge" "2026-01-18" "followup-partial-bridge"

    write_triage_only_two_finding_digest_fixture "${DIGEST_PATH}" "${RUN_DATE}"
    write_followup_findings_manifest_fixture \
        "$(findings_manifest_path)" \
        $'1\tcritical\tregression\tCommit alpha' \
        $'2\tmajor\tsecurity\tSecurity beta'

    agent_run_claude() {
        local playbook_path="$1"
        local output_path="$2"
        local playbook_name=""

        playbook_name="$(basename "${playbook_path}")"
        case "${playbook_name}" in
            task-writer.md)
                if [[ "${output_path}" == *rank-1.json ]]; then
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Commit alpha" "critical" "regression")"
                else
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Security beta" "major" "security")"
                fi
                ;;
            validation-agent.md)
                write_agent_result_json "${output_path}" "$(validation_followup_valid_result_text)"
                ;;
            *)
                return 1
                ;;
        esac
        return 0
    }

    task_log="$TMP_DIR/followup-partial-bridge.task.log"
    validation_log="$TMP_DIR/followup-partial-bridge.validation.log"
    bridge_log="$TMP_DIR/followup-partial-bridge.bridge.log"

    phase_task_writing >"$task_log" 2>&1
    phase_validation >"$validation_log" 2>&1

    manifest_path="$(manager_task_manifest_path)"
    deleted_path="$(sed -n '1p' "${manifest_path}")"
    rm -f "${deleted_path}"

    phase_bridge >"$bridge_log" 2>&1

    ok=true
    [[ -f "${manifest_path}" ]] || ok=false
    [[ "$(wc -l < "${manifest_path}" | tr -d '[:space:]')" == "2" ]] || ok=false
    [[ "${BRIDGE_SKIPPED}" -eq 0 ]] || ok=false
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 1 ]] || ok=false
    grep -Fq "WARN: Bridge: task file missing: ${deleted_path}" "${bridge_log}" || ok=false
    grep -Fq 'Bridge: digest is triage-only but task manifest exists with 2 task file(s). Reading paths from manifest.' "${bridge_log}" || ok=false
    [[ "$ok" == "true" ]]
) && pass "24. bridge warns on missing manifest entries and still stages the surviving task" \
  || fail "24. bridge warns on missing manifest entries and still stages the surviving task" "partial manifest-path bridge handling regressed"

# ── Test 25: phase_task_writing patches stale digest task counts before validation ─
(
    setup_followup_pipeline_fixture "$TMP_DIR/digest-task-count" "2026-01-20" "digest-task-count"

    check_total_timeout() { return 0; }
    count_total_findings() { echo "2"; }
    agent_run_claude() {
        local playbook_path="$1"
        local output_path="$2"
        local playbook_name=""

        playbook_name="$(basename "${playbook_path}")"
        case "${playbook_name}" in
            manager-merge.md)
                write_manager_digest_with_two_top_findings_fixture "${DIGEST_PATH}" "${RUN_DATE}"
                ;;
            task-writer.md)
                if [[ "${output_path}" == *rank-1.json ]]; then
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Commit alpha" "critical" "regression")"
                else
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Security beta" "major" "security")"
                fi
                ;;
            validation-agent.md)
                write_agent_result_json "${output_path}" "$(validation_followup_valid_result_text)"
                ;;
            *)
                return 1
                ;;
        esac
        return 0
    }

    manager_log="$TMP_DIR/digest-task-count.manager.log"
    task_log="$TMP_DIR/digest-task-count.task.log"
    validation_log="$TMP_DIR/digest-task-count.validation.log"
    manager_rc=0
    task_rc=0
    validation_rc=0

    phase_manager_merge >"$manager_log" 2>&1 || manager_rc=$?
    manager_digest_snapshot="$TMP_DIR/digest-task-count.before.md"
    cp "$DIGEST_PATH" "$manager_digest_snapshot"

    phase_task_writing >"$task_log" 2>&1 || task_rc=$?
    task_writing_digest_snapshot="$TMP_DIR/digest-task-count.after-task-writing.md"
    cp "$DIGEST_PATH" "$task_writing_digest_snapshot"
    phase_validation >"$validation_log" 2>&1 || validation_rc=$?

    ok=true
    [[ "$manager_rc" -eq 0 ]] || ok=false
    [[ "$task_rc" -eq 0 ]] || ok=false
    [[ "$validation_rc" -eq 0 ]] || ok=false
    [[ "${TASK_FILE_COUNT}" == "2" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "2" ]] || ok=false
    [[ "${DIGEST_TASK_COUNT_PATCHED}" == "1" ]] || ok=false
    grep -Fq -- '- **Task files created:** 0 (critical: 1, major: 1)' "$manager_digest_snapshot" || ok=false
    grep -Fxq -- '- **Task files created:** 0' "$manager_digest_snapshot" || ok=false
    grep -Fq -- '- **Task files created:** 2 (critical: 1, major: 1)' "$task_writing_digest_snapshot" || ok=false
    grep -Fxq -- '- **Task files created:** 2' "$task_writing_digest_snapshot" || ok=false
    grep -Fq -- '- **Task files created:** 2 (critical: 1, major: 1)' "$DIGEST_PATH" || ok=false
    grep -Fxq -- '- **Task files created:** 2' "$DIGEST_PATH" || ok=false
    ! grep -Fq -- '- **Task files created:** 0 (critical: 1, major: 1)' "$task_writing_digest_snapshot" || ok=false
    ! grep -Fxq -- '- **Task files created:** 0' "$task_writing_digest_snapshot" || ok=false
    ! grep -Fq -- '- **Task files created:** 0 (critical: 1, major: 1)' "$DIGEST_PATH" || ok=false
    ! grep -Fxq -- '- **Task files created:** 0' "$DIGEST_PATH" || ok=false
    [[ "$ok" == "true" ]]
) && pass "25. phase_task_writing patches manager digest task counts before validation" \
  || fail "25. phase_task_writing patches manager digest task counts before validation" "task-writing digest patching regressed"

# ── Test 26: digest stays patched when validation skips on top-level cost cap ─
(
    setup_followup_pipeline_fixture "$TMP_DIR/digest-task-count-skip" "2026-01-21" "digest-task-count-skip"

    guard_calls=0
    check_total_timeout() { return 0; }
    count_total_findings() { echo "2"; }
    cost_guard_after_call() {
        guard_calls=$((guard_calls + 1))
        if [[ "${guard_calls}" -ge 3 ]]; then
            RUN_COST_CAP=1
            return 1
        fi
        return 0
    }
    agent_run_claude() {
        local playbook_path="$1"
        local output_path="$2"
        local playbook_name=""

        playbook_name="$(basename "${playbook_path}")"
        case "${playbook_name}" in
            manager-merge.md)
                write_manager_digest_with_two_top_findings_fixture "${DIGEST_PATH}" "${RUN_DATE}"
                ;;
            task-writer.md)
                if [[ "${output_path}" == *rank-1.json ]]; then
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Commit alpha" "critical" "regression")"
                else
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Security beta" "major" "security")"
                fi
                ;;
            validation-agent.md)
                write_agent_result_json "${output_path}" "$(validation_followup_valid_result_text)"
                ;;
            *)
                return 1
                ;;
        esac
        return 0
    }

    manager_log="$TMP_DIR/digest-task-count-skip.manager.log"
    task_log="$TMP_DIR/digest-task-count-skip.task.log"
    validation_log="$TMP_DIR/digest-task-count-skip.validation.log"
    manager_rc=0
    task_rc=0
    validation_rc=0

    phase_manager_merge >"$manager_log" 2>&1 || manager_rc=$?
    manager_digest_snapshot="$TMP_DIR/digest-task-count-skip.before.md"
    cp "$DIGEST_PATH" "$manager_digest_snapshot"

    phase_task_writing >"$task_log" 2>&1 || task_rc=$?
    task_writing_digest_snapshot="$TMP_DIR/digest-task-count-skip.after-task-writing.md"
    cp "$DIGEST_PATH" "$task_writing_digest_snapshot"
    phase_validation >"$validation_log" 2>&1 || validation_rc=$?

    ok=true
    [[ "$manager_rc" -eq 0 ]] || ok=false
    [[ "$task_rc" -eq 0 ]] || ok=false
    [[ "$validation_rc" -eq 0 ]] || ok=false
    [[ "${TASK_FILE_COUNT}" == "2" ]] || ok=false
    [[ "${RUN_COST_CAP}" == "1" ]] || ok=false
    [[ "${VALIDATION_TOTAL_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    [[ "${DIGEST_TASK_COUNT_PATCHED}" == "1" ]] || ok=false
    grep -Fq -- '- **Task files created:** 0 (critical: 1, major: 1)' "$manager_digest_snapshot" || ok=false
    grep -Fxq -- '- **Task files created:** 0' "$manager_digest_snapshot" || ok=false
    grep -Fq -- '- **Task files created:** 2 (critical: 1, major: 1)' "$task_writing_digest_snapshot" || ok=false
    grep -Fxq -- '- **Task files created:** 2' "$task_writing_digest_snapshot" || ok=false
    grep -Fq -- '- **Task files created:** 2 (critical: 1, major: 1)' "$DIGEST_PATH" || ok=false
    grep -Fxq -- '- **Task files created:** 2' "$DIGEST_PATH" || ok=false
    grep -Fq '===== Phase 3.5a: Task Writing HALTED =====' "$task_log" || ok=false
    grep -Fq 'Validation skipped because the run is already cost-capped' "$validation_log" || ok=false
    grep -Fq '===== Phase 3.5b: Task Validation SKIPPED =====' "$validation_log" || ok=false
    [[ "$ok" == "true" ]]
) && pass "26. phase_task_writing patches the digest before validation skips on RUN_COST_CAP" \
  || fail "26. phase_task_writing patches the digest before validation skips on RUN_COST_CAP" "cost-cap validation skip left stale digest task counts"

# ── Test 27: clean runs skip backlog only after meeting the task floor ───────
(
    setup_manager_merge_fixture "$TMP_DIR/backlog-clean-run" "2026-01-19" "backlog-clean-run"

    CURRENT_PHASE="3.7"
    NIGHTSHIFT_BACKLOG_ENABLED="true"
    NIGHTSHIFT_MIN_TASKS_PER_RUN="3"
    NIGHTSHIFT_BACKLOG_MIN_BUDGET="20"
    AUTOFIX_ATTEMPTED_COUNT=3
    RUN_CLEAN=1
    RUN_COST_CAP=0
    SETUP_FAILED=0

    bash_calls=0
    bash_log="$TMP_DIR/backlog-clean-run.bash.log"
    bash() {
        bash_calls=$((bash_calls + 1))
        printf '%s\n' "$*" >> "$bash_log"
        return 99
    }

    backlog_log_path="$TMP_DIR/backlog-clean-run.log"
    phase_rc=0
    phase_backlog_burndown >"$backlog_log_path" 2>&1 || phase_rc=$?

    ok=true
    [[ "$phase_rc" -eq 0 ]] || ok=false
    [[ "$bash_calls" -eq 0 ]] || ok=false
    grep -Fq 'Backlog target: attempted autofix=3, min per run=3, needed=0, effective max=3' "$backlog_log_path" || ok=false
    grep -Fq 'INFO: Night Shift: backlog skipped — clean run, no upstream findings' "$backlog_log_path" || ok=false
    grep -Fq '===== Phase 3.7: Backlog Burndown SKIPPED =====' "$backlog_log_path" || ok=false
    [[ "${#BACKLOG_STAGE_PATHS[@]}" -eq 0 ]] || ok=false
    [[ "${#BACKLOG_RESULTS[@]}" -eq 0 ]] || ok=false
    [[ "$ok" == "true" ]]
) && pass "27. RUN_CLEAN skips backlog after autofix meets the minimum task floor" \
  || fail "27. RUN_CLEAN skips backlog after autofix meets the minimum task floor" "clean-run backlog guard regressed"

# ── Test 28: smoke mode dispatches only commit-detective ────────────────────
(
    tmp_home="$TMP_DIR/home-smoke-phase-order"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    RUN_TMP_DIR="$TMP_DIR/smoke-phase-order/run"
    AGENT_OUTPUT_DIR="$RUN_TMP_DIR/outputs"
    RAW_FINDINGS_DIR="$RUN_TMP_DIR/raw"
    NIGHTSHIFT_FINDINGS_DIR="$RUN_TMP_DIR/findings"
    NIGHTSHIFT_PLAYBOOKS_DIR="$RUN_TMP_DIR/playbooks"
    NIGHTSHIFT_LOG_DIR="$RUN_TMP_DIR/logs"
    mkdir -p "$AGENT_OUTPUT_DIR" "$RAW_FINDINGS_DIR" "$NIGHTSHIFT_FINDINGS_DIR" \
        "$NIGHTSHIFT_PLAYBOOKS_DIR" "$NIGHTSHIFT_LOG_DIR"

    for playbook_name in "${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}"; do
        printf '# %s\n' "$playbook_name" > "$NIGHTSHIFT_PLAYBOOKS_DIR/${playbook_name}.md"
    done

    DRY_RUN=0
    SMOKE_MODE=1
    NIGHTSHIFT_SMOKE="true"
    SETUP_FAILED=0
    SETUP_READY=1
    CLAUDE_AVAILABLE=1
    DB_PLAYBOOKS_ENABLED=1
    COST_TRACKING_READY=0
    RUN_COST_CAP=0
    RUN_FAILED=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    CODEX_MODE="pending"
    CODEX_ATTEMPT_COUNT=0
    trace_path="$TMP_DIR/smoke-phase-order.trace"
    : > "$trace_path"

    check_total_timeout() { return 0; }
    agent_run_claude() {
        local _playbook_path="$1"
        local _output_path="$2"
        printf 'claude/%s\n' "$(basename "$_playbook_path" .md)" >> "$trace_path"
        printf 'claude output\n' > "$_output_path"
        return 0
    }
    agent_run_codex() {
        local _playbook_path="$1"
        local _output_path="$2"
        printf 'codex/%s\n' "$(basename "$_playbook_path" .md)" >> "$trace_path"
        printf 'codex output\n' > "$_output_path"
        return 0
    }

    log_path="$TMP_DIR/smoke-phase-order.log"
    phase_detectives >"$log_path" 2>&1 || true

    trace_lines=()
    if [[ -f "$trace_path" ]]; then
        while IFS= read -r trace_line; do
            trace_lines+=("$trace_line")
        done < "$trace_path"
    fi
    if [[ "${#trace_lines[@]}" -gt 0 ]]; then
        actual_trace="$(printf '%s\n' "${trace_lines[@]}")"
    else
        actual_trace=""
    fi
    expected_trace=$'claude/commit-detective\ncodex/commit-detective'

    ok=true
    [[ "${#trace_lines[@]}" -eq 2 ]] || ok=false
    [[ "${actual_trace}" == "${expected_trace}" ]] || ok=false
    [[ "${CODEX_MODE}" == "open" ]] || ok=false
    grep -Fq "===== Phase 2: Detective Runs OK =====" "$log_path" || ok=false
    [[ "$ok" == "true" ]]
) && pass "28. smoke mode Phase 2 dispatches only claude/codex commit-detective" \
  || fail "28. smoke mode Phase 2 dispatches only claude/codex commit-detective" "smoke detective filtering regressed"

# ── Test 29: smoke mode caps task writing at one task ───────────────────────
(
    setup_followup_pipeline_fixture "$TMP_DIR/smoke-task-cap" "2026-01-22" "smoke-task-cap"

    SMOKE_MODE=1
    NIGHTSHIFT_SMOKE="true"
    write_triage_only_two_finding_digest_fixture "${DIGEST_PATH}" "${RUN_DATE}"
    write_followup_findings_manifest_fixture \
        "$(findings_manifest_path)" \
        $'1\tcritical\tregression\tCommit alpha' \
        $'2\tmajor\tsecurity\tSecurity beta'

    task_writer_calls=0
    agent_run_claude() {
        local playbook_path="$1"
        local output_path="$2"
        local playbook_name=""

        playbook_name="$(basename "${playbook_path}")"
        case "${playbook_name}" in
            task-writer.md)
                task_writer_calls=$((task_writer_calls + 1))
                if [[ "${task_writer_calls}" -eq 1 ]]; then
                    write_agent_result_json "${output_path}" "$(task_writer_followup_result_text "Commit alpha" "critical" "regression")"
                    return 0
                fi
                return 1
                ;;
            *)
                return 1
                ;;
        esac
    }

    task_log="$TMP_DIR/smoke-task-cap.task.log"
    task_rc=0

    phase_task_writing >"$task_log" 2>&1 || task_rc=$?

    manifest_path="$(manager_task_manifest_path)"
    created_count="$(find "${REPO_ROOT}/docs/tasks/open/nightshift" -maxdepth 1 -type f -name "${RUN_DATE}-*.md" | wc -l | tr -d '[:space:]')"

    ok=true
    [[ "$task_rc" -eq 0 ]] || ok=false
    [[ "${task_writer_calls}" -eq 1 ]] || ok=false
    [[ "${TASK_FILE_COUNT}" == "1" ]] || ok=false
    [[ "${created_count}" == "1" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 1 ]] || ok=false
    [[ -f "${manifest_path}" ]] || ok=false
    [[ "$(wc -l < "${manifest_path}" | tr -d '[:space:]')" == "1" ]] || ok=false
    grep -Fq 'Smoke mode: capping task writing to 1 task' "$task_log" || ok=false
    grep -Fq '===== Phase 3.5a: Task Writing OK =====' "$task_log" || ok=false
    [[ "$ok" == "true" ]]
) && pass "29. smoke mode caps task writing to one task" \
  || fail "29. smoke mode caps task writing to one task" "smoke task cap regressed"

# ── Test 30: smoke mode skips autofix, bridge, and backlog explicitly ───────
(
    setup_followup_pipeline_fixture "$TMP_DIR/smoke-phase-skips" "2026-01-23" "smoke-phase-skips"

    SMOKE_MODE=1
    NIGHTSHIFT_SMOKE="true"
    NIGHTSHIFT_AUTOFIX_ENABLED="true"
    NIGHTSHIFT_BRIDGE_ENABLED="true"
    NIGHTSHIFT_BACKLOG_ENABLED="true"
    RUN_CLEAN=0
    RUN_COST_CAP=0
    SETUP_FAILED=0
    VALIDATED_TASKS=("${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-dummy.md")

    bridge_called=0
    bridge_run() {
        bridge_called=1
        return 0
    }

    autofix_log="$TMP_DIR/smoke-phase-skips.autofix.log"
    bridge_log="$TMP_DIR/smoke-phase-skips.bridge.log"
    backlog_log_path="$TMP_DIR/smoke-phase-skips.backlog.log"
    autofix_rc=0
    bridge_rc=0
    backlog_rc=0

    phase_autofix >"$autofix_log" 2>&1 || autofix_rc=$?
    phase_bridge >"$bridge_log" 2>&1 || bridge_rc=$?
    phase_backlog_burndown >"$backlog_log_path" 2>&1 || backlog_rc=$?

    ok=true
    [[ "$autofix_rc" -eq 0 ]] || ok=false
    [[ "$bridge_rc" -eq 0 ]] || ok=false
    [[ "$backlog_rc" -eq 0 ]] || ok=false
    [[ "${bridge_called}" -eq 0 ]] || ok=false
    grep -Fq 'Smoke mode: skipping Autofix' "$autofix_log" || ok=false
    grep -Fq 'Smoke mode: skipping Lauren Loop Bridge' "$bridge_log" || ok=false
    grep -Fq 'Smoke mode: skipping Backlog Burndown' "$backlog_log_path" || ok=false
    grep -Fq '===== Phase 3.5c: Autofix SKIPPED =====' "$autofix_log" || ok=false
    grep -Fq '===== Phase 3.6: Lauren Loop Bridge SKIPPED =====' "$bridge_log" || ok=false
    grep -Fq '===== Phase 3.7: Backlog Burndown SKIPPED =====' "$backlog_log_path" || ok=false
    [[ "$ok" == "true" ]]
) && pass "30. smoke mode skips autofix, bridge, and backlog with explicit logs" \
  || fail "30. smoke mode skips autofix, bridge, and backlog with explicit logs" "smoke phase skip guards regressed"

# ── Test 31: smoke mode prefixes the PR title ────────────────────────────────
(
    tmp_home="$TMP_DIR/home-smoke-pr-title"
    mkdir -p "$tmp_home"
    export HOME="$tmp_home"

    source "$NS_DIR/nightshift.sh"

    REPO_ROOT="$TMP_DIR/smoke-pr-title/repo"
    RUN_DATE="2026-04-06"
    RUN_BRANCH="nightshift/smoke-2026-04-06-123456"
    NIGHTSHIFT_BASE_BRANCH="main"
    NIGHTSHIFT_PR_LABELS=""
    DRY_RUN=0
    SMOKE_MODE=1
    NIGHTSHIFT_SMOKE="true"
    RUN_COST_CAP=0
    RUN_CLEAN=0
    RUN_FAILED=0
    BRANCH_READY=1
    GH_AVAILABLE=1
    DIGEST_STAGEABLE=1
    TASK_FILE_COUNT=1
    TOTAL_FINDINGS_AVAILABLE=2
    BRIDGE_STAGE_PATHS=()
    BACKLOG_STAGE_PATHS=()
    PR_URL=""

    DIGEST_PATH="$REPO_ROOT/docs/nightshift/digests/${RUN_DATE}.md"
    mkdir -p "$(dirname "$DIGEST_PATH")"
    printf '# Digest\n' > "$DIGEST_PATH"

    git_validate_commit_message() { return 0; }
    git_validate_pr_size() { return 0; }

    pr_create_log="$TMP_DIR/smoke-pr-title.create"

    git() {
        if [[ "$1" == "status" && "$2" == "--porcelain" ]]; then
            printf ' M docs/nightshift/digests/%s.md\n' "$RUN_DATE"
            return 0
        fi
        if [[ "$1" == "add" || "$1" == "commit" || "$1" == "push" ]]; then
            return 0
        fi
        if [[ "$1" == "diff" && "$2" == "--cached" && "$3" == "--quiet" ]]; then
            return 1
        fi
        command git "$@"
    }

    gh() {
        if [[ "$1" == "label" && "$2" == "create" ]]; then
            return 0
        fi
        if [[ "$1" == "pr" && "$2" == "create" ]]; then
            printf '%s\n' "$@" > "$pr_create_log"
            printf 'https://example.test/pr/smoke\n'
            return 0
        fi
        return 1
    }

    ship_log="$TMP_DIR/smoke-pr-title.log"
    phase_rc=0
    phase_ship_results >"$ship_log" 2>&1 || phase_rc=$?

    pr_args=()
    if [[ -f "$pr_create_log" ]]; then
        while IFS= read -r pr_arg; do
            pr_args+=("$pr_arg")
        done < "$pr_create_log"
    fi
    pr_title=""
    for ((i = 0; i < ${#pr_args[@]}; i++)); do
        if [[ "${pr_args[i]}" == "--title" && $((i + 1)) -lt ${#pr_args[@]} ]]; then
            pr_title="${pr_args[i + 1]}"
            break
        fi
    done

    ok=true
    [[ "$phase_rc" -eq 0 ]] || ok=false
    [[ "${PR_URL}" == "https://example.test/pr/smoke" ]] || ok=false
    [[ "${pr_title}" == "[SMOKE TEST] Nightshift 2026-04-06: 1 tasks / 2 findings" ]] || ok=false
    grep -Fq '===== Phase 4: Ship Results OK =====' "$ship_log" || ok=false
    [[ "$ok" == "true" ]]
) && pass "31. smoke mode prefixes the shipping PR title" \
  || fail "31. smoke mode prefixes the shipping PR title" "smoke PR title prefix regressed"

# ── Test 32: manager prompt accepts smoke input shape and requires completion marker ──
(
    manager_playbook="${NS_DIR}/playbooks/manager-merge.md"

    ok=true
    grep -Fq "Some runs, especially smoke mode, may have exactly one detective file with real findings" "$manager_playbook" || ok=false
    grep -Fq "That is valid input. Do not wait for additional findings files." "$manager_playbook" || ok=false
    grep -Fq "ARTIFACT_WRITTEN" "$manager_playbook" || ok=false
    grep -Fq "Do not respond with a kickoff such as \"I'll start by reading ...\". Complete the digest write" "$manager_playbook" || ok=false
    [[ "$ok" == "true" ]]
) && pass "32. manager merge prompt accepts smoke-shaped input and requires ARTIFACT_WRITTEN" \
  || fail "32. manager merge prompt accepts smoke-shaped input and requires ARTIFACT_WRITTEN" "manager merge prompt contract regressed"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (32 tests) ==="
[[ "$FAIL" -eq 0 ]]

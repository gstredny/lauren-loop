#!/usr/bin/env bash
# test_task_writer.sh — Focused tests for the Nightshift task-writing phase.
#
# Usage: bash scripts/nightshift/tests/test_task_writer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

echo "=== test_task_writer.sh ==="
echo ""

source "${NS_DIR}/nightshift.conf"
source "${NS_DIR}/lib/cost-tracker.sh"
source "${NS_DIR}/lib/agent-runner.sh"
source "${NS_DIR}/nightshift.sh"

write_task_writer_result_json() {
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

task_writer_created_result_text() {
    local title="$1"

    cat <<EOF
--- BEGIN TASK FILE ---
## Task: ${title}
## Status: not started
## Created: 2026-04-01
## Execution Mode: single-agent

## Goal
Fix ${title}.
--- END TASK FILE ---

### Task Writer Result: CREATED
EOF
}

task_writer_rejected_result_text() {
    local reason="$1"
    printf 'Rejected.\n\n### Task Writer Result: REJECTED — %s\n' "${reason}"
}

task_writer_nested_begin_result_text() {
    cat <<'EOF'
--- BEGIN TASK FILE ---
## Task: Broken nested block
--- BEGIN TASK FILE ---
## Task: Nested task
--- END TASK FILE ---

### Task Writer Result: CREATED
EOF
}

write_findings_manifest_fixture() {
    local manifest_path=""
    local finding_row=""

    manifest_path="$(findings_manifest_path)"
    mkdir -p "$(dirname "${manifest_path}")"
    : > "${manifest_path}"

    for finding_row in "$@"; do
        printf '%s\n' "${finding_row}" >> "${manifest_path}"
    done
}

write_digest_fixture() {
    local digest_path="${DIGEST_PATH}"
    local row=""

    mkdir -p "$(dirname "${digest_path}")"
    cat > "${digest_path}" <<EOF
# Nightshift Detective Digest — ${RUN_DATE}

## Ranked Findings

| # | Severity | Category | Title |
|---|----------|----------|-------|
EOF

    for row in "$@"; do
        printf '%s\n' "${row}" >> "${digest_path}"
    done

    cat >> "${digest_path}" <<'EOF'

## Minor & Observation Findings

None.
EOF
}

setup_task_writer_fixture() {
    local fixture_name="$1"

    REPO_ROOT="${TMP_DIR}/${fixture_name}/repo"
    RUN_TMP_DIR="${TMP_DIR}/${fixture_name}/run"
    AGENT_OUTPUT_DIR="${RUN_TMP_DIR}/agent-outputs"
    NIGHTSHIFT_FINDINGS_DIR="${RUN_TMP_DIR}/findings"
    NIGHTSHIFT_LOG_DIR="${RUN_TMP_DIR}/logs"
    NIGHTSHIFT_RENDERED_DIR="${RUN_TMP_DIR}/rendered"
    NIGHTSHIFT_PLAYBOOKS_DIR="${NS_DIR}/playbooks"
    NIGHTSHIFT_COST_STATE_FILE="${RUN_TMP_DIR}/cost-state.json"
    NIGHTSHIFT_COST_CSV="${RUN_TMP_DIR}/cost-history.csv"
    RUN_DATE="2026-04-01"
    RUN_ID="test-task-writer-${fixture_name}"
    DIGEST_PATH="${RUN_TMP_DIR}/digest.md"
    DRY_RUN=0
    SETUP_FAILED=0
    RUN_COST_CAP=0
    RUN_CLEAN=0
    RUN_FAILED=0
    MANAGER_CONTRACT_FAILED=0
    CURRENT_PHASE="3.5a"
    CREATED_TASKS=()
    VALIDATED_TASKS=()
    NIGHTSHIFT_FINDING_TEXT=""
    TASK_FILE_COUNT=0
    COST_TRACKING_READY=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    NIGHTSHIFT_TASK_WRITER_MAX_TASKS="5"
    NIGHTSHIFT_TASK_WRITER_MIN_BUDGET="20"
    NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY="critical,major"

    mkdir -p \
        "${REPO_ROOT}/docs/tasks/open/nightshift" \
        "${RUN_TMP_DIR}" \
        "${AGENT_OUTPUT_DIR}" \
        "${NIGHTSHIFT_FINDINGS_DIR}" \
        "${NIGHTSHIFT_LOG_DIR}" \
        "${NIGHTSHIFT_RENDERED_DIR}"
}

# ── Test 1: CREATED writes task, manifest, and CREATED_TASKS only ────────────
(
    setup_task_writer_fixture "created"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |'

    agent_run_claude() {
        local output_path="$2"
        write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Alpha outage")"
        return 0
    }

    phase_task_writing >/dev/null 2>&1

    expected_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha-outage.md"
    manifest_path="$(manager_task_manifest_path)"
    ok=true
    [[ -f "${expected_path}" ]] || ok=false
    grep -Fq '## Task: Alpha outage' "${expected_path}" || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 1 ]] || ok=false
    [[ "${CREATED_TASKS[0]}" == "${expected_path}" ]] || ok=false
    grep -Fxq "${expected_path}" "${manifest_path}" || ok=false
    [[ "${#VALIDATED_TASKS[@]}" -eq 0 ]] || ok=false
    [[ "${TASK_FILE_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "1. CREATED output writes a task file, records CREATED_TASKS, and leaves VALIDATED_TASKS untouched" \
  || fail "1. CREATED output writes a task file, records CREATED_TASKS, and leaves VALIDATED_TASKS untouched" "created-path bookkeeping regressed"

# ── Test 2: REJECTED logs and later findings still run ───────────────────────
(
    setup_task_writer_fixture "rejected"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage' \
        $'2\tmajor\terror-handling\tBeta failure'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |' \
        '| 2 | major | error-handling | Beta failure |'

    call_count=0
    agent_run_claude() {
        local output_path="$2"
        call_count=$(( call_count + 1 ))
        if [[ "${call_count}" -eq 1 ]]; then
            write_task_writer_result_json "${output_path}" "$(task_writer_rejected_result_text "already tracked")"
        else
            write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Beta failure")"
        fi
        return 0
    }

    log_path="${TMP_DIR}/task-writer-rejected.log"
    phase_task_writing >"${log_path}" 2>&1

    expected_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta-failure.md"
    ok=true
    [[ "${call_count}" == "2" ]] || ok=false
    grep -Fq 'Task writer rejected: Alpha outage — already tracked' "${log_path}" || ok=false
    [[ ! -e "${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha-outage.md" ]] || ok=false
    [[ -f "${expected_path}" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 1 ]] || ok=false
    [[ "${CREATED_TASKS[0]}" == "${expected_path}" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "2. REJECTED output logs the reason and the loop continues to later findings" \
  || fail "2. REJECTED output logs the reason and the loop continues to later findings" "rejected finding handling regressed"

# ── Test 3: malformed output logs failure and later findings still run ───────
(
    setup_task_writer_fixture "malformed"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage' \
        $'2\tmajor\terror-handling\tBeta failure'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |' \
        '| 2 | major | error-handling | Beta failure |'

    call_count=0
    agent_run_claude() {
        local output_path="$2"
        call_count=$(( call_count + 1 ))
        if [[ "${call_count}" -eq 1 ]]; then
            write_task_writer_result_json "${output_path}" "No result markers here."
        else
            write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Beta failure")"
        fi
        return 0
    }

    log_path="${TMP_DIR}/task-writer-malformed.log"
    phase_task_writing >"${log_path}" 2>&1

    expected_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-beta-failure.md"
    ok=true
    [[ "${call_count}" == "2" ]] || ok=false
    grep -Fq 'Task writer malformed output for: Alpha outage' "${log_path}" || ok=false
    [[ -f "${expected_path}" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 1 ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "3. malformed task-writer output is counted as failure and later findings still run" \
  || fail "3. malformed task-writer output is counted as failure and later findings still run" "malformed-output handling regressed"

# ── Test 4: nested BEGIN markers are rejected as malformed ───────────────────
(
    setup_task_writer_fixture "nested"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |'

    agent_run_claude() {
        local output_path="$2"
        write_task_writer_result_json "${output_path}" "$(task_writer_nested_begin_result_text)"
        return 0
    }

    log_path="${TMP_DIR}/task-writer-nested.log"
    phase_task_writing >"${log_path}" 2>&1

    manifest_path="$(manager_task_manifest_path)"
    ok=true
    grep -Fq 'Task writer malformed output for: Alpha outage' "${log_path}" || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 0 ]] || ok=false
    [[ -f "${manifest_path}" ]] || ok=false
    [[ ! -s "${manifest_path}" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "4. nested BEGIN markers inside the task block are treated as malformed" \
  || fail "4. nested BEGIN markers inside the task block are treated as malformed" "nested-begin detection regressed"

# ── Test 5: missing findings manifest writes empty manager manifest and exits OK ──
(
    setup_task_writer_fixture "empty-findings"

    log_path="${TMP_DIR}/task-writer-empty-findings.log"
    phase_task_writing >"${log_path}" 2>&1

    manifest_path="$(manager_task_manifest_path)"
    ok=true
    grep -Fq 'Task writing: 0 findings to process' "${log_path}" || ok=false
    grep -Fq '===== Phase 3.5a: Task Writing OK =====' "${log_path}" || ok=false
    [[ -f "${manifest_path}" ]] || ok=false
    [[ ! -s "${manifest_path}" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 0 ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "5. missing findings-manifest still writes an empty manager-task-manifest and exits OK" \
  || fail "5. missing findings-manifest still writes an empty manager-task-manifest and exits OK" "empty-findings handling regressed"

# ── Test 6: severity filter only processes configured severities ─────────────
(
    setup_task_writer_fixture "severity-filter"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage' \
        $'2\tmajor\terror-handling\tBeta failure' \
        $'3\tminor\tperformance\tGamma slowdown'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |' \
        '| 2 | major | error-handling | Beta failure |' \
        '| 3 | minor | performance | Gamma slowdown |'

    agent_call_log="${TMP_DIR}/task-writer-severity.calls"
    : > "${agent_call_log}"
    agent_run_claude() {
        local output_path="$2"
        printf '%s\n' "${NIGHTSHIFT_FINDING_TEXT}" >> "${agent_call_log}"
        printf -- '---\n' >> "${agent_call_log}"
        write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Processed finding")"
        return 0
    }

    phase_task_writing >/dev/null 2>&1

    ok=true
    [[ "$(grep -c '^Rank:' "${agent_call_log}")" == "2" ]] || ok=false
    grep -Fq 'Alpha outage' "${agent_call_log}" || ok=false
    grep -Fq 'Beta failure' "${agent_call_log}" || ok=false
    ! grep -Fq 'Gamma slowdown' "${agent_call_log}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "6. severity filtering limits task-writing attempts to critical and major findings" \
  || fail "6. severity filtering limits task-writing attempts to critical and major findings" "severity filtering regressed"

# ── Test 7: max tasks cap stops after the first 5 eligible findings ──────────
(
    setup_task_writer_fixture "max-cap"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha 1' \
        $'2\tcritical\tregression\tAlpha 2' \
        $'3\tcritical\tregression\tAlpha 3' \
        $'4\tcritical\tregression\tAlpha 4' \
        $'5\tcritical\tregression\tAlpha 5' \
        $'6\tcritical\tregression\tAlpha 6' \
        $'7\tcritical\tregression\tAlpha 7'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha 1 |' \
        '| 2 | critical | regression | Alpha 2 |' \
        '| 3 | critical | regression | Alpha 3 |' \
        '| 4 | critical | regression | Alpha 4 |' \
        '| 5 | critical | regression | Alpha 5 |' \
        '| 6 | critical | regression | Alpha 6 |' \
        '| 7 | critical | regression | Alpha 7 |'

    call_count=0
    agent_run_claude() {
        local output_path="$2"
        call_count=$(( call_count + 1 ))
        write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Cap ${call_count}")"
        return 0
    }

    phase_task_writing >/dev/null 2>&1

    manifest_path="$(manager_task_manifest_path)"
    ok=true
    [[ "${call_count}" == "5" ]] || ok=false
    [[ "$(wc -l < "${manifest_path}" | tr -d '[:space:]')" == "5" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 5 ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "7. NIGHTSHIFT_TASK_WRITER_MAX_TASKS caps task-writing attempts at the first five eligible findings" \
  || fail "7. NIGHTSHIFT_TASK_WRITER_MAX_TASKS caps task-writing attempts at the first five eligible findings" "max-task cap regressed"

# ── Test 8: budget guard stops after finding #2 and preserves created manifest ──
(
    setup_task_writer_fixture "budget-stop"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha 1' \
        $'2\tcritical\tregression\tAlpha 2' \
        $'3\tcritical\tregression\tAlpha 3' \
        $'4\tcritical\tregression\tAlpha 4'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha 1 |' \
        '| 2 | critical | regression | Alpha 2 |' \
        '| 3 | critical | regression | Alpha 3 |' \
        '| 4 | critical | regression | Alpha 4 |'

    budget_state="${TMP_DIR}/task-writer-budget-state.txt"
    printf '0\n' > "${budget_state}"
    autofix_remaining_budget() {
        local budget_calls=""
        budget_calls="$(cat "${budget_state}")"
        budget_calls=$(( budget_calls + 1 ))
        printf '%s\n' "${budget_calls}" > "${budget_state}"
        if [[ "${budget_calls}" -le 2 ]]; then
            echo "200.0000"
        else
            echo "10.0000"
        fi
    }

    call_count=0
    agent_run_claude() {
        local output_path="$2"
        call_count=$(( call_count + 1 ))
        write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Budget ${call_count}")"
        return 0
    }

    log_path="${TMP_DIR}/task-writer-budget-stop.log"
    phase_task_writing >"${log_path}" 2>&1

    manifest_path="$(manager_task_manifest_path)"
    ok=true
    [[ "${call_count}" == "2" ]] || ok=false
    grep -Fq 'Task writing: insufficient budget remaining ($10.0000 of $20 needed)' "${log_path}" || ok=false
    [[ "$(wc -l < "${manifest_path}" | tr -d '[:space:]')" == "2" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 2 ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "8. the budget guard stops after the second finding and preserves created tasks in the manifest" \
  || fail "8. the budget guard stops after the second finding and preserves created tasks in the manifest" "budget-stop behavior regressed"

# ── Test 9: dry run logs findings, skips agent calls, and writes empty manifest ──
(
    setup_task_writer_fixture "dry-run"
    DRY_RUN=1
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage' \
        $'2\tmajor\terror-handling\tBeta failure'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |' \
        '| 2 | major | error-handling | Beta failure |'

    agent_called=0
    agent_run_claude() {
        agent_called=1
        return 1
    }

    log_path="${TMP_DIR}/task-writer-dry-run.log"
    phase_task_writing >"${log_path}" 2>&1

    manifest_path="$(manager_task_manifest_path)"
    ok=true
    [[ "${agent_called}" == "0" ]] || ok=false
    grep -Fq 'DRY RUN: would write task for: Alpha outage (severity: critical' "${log_path}" || ok=false
    grep -Fq 'DRY RUN: would write task for: Beta failure (severity: major' "${log_path}" || ok=false
    [[ -f "${manifest_path}" ]] || ok=false
    [[ ! -s "${manifest_path}" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 0 ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "9. dry run logs each eligible finding, does not call the agent, and writes an empty manifest" \
  || fail "9. dry run logs each eligible finding, does not call the agent, and writes an empty manifest" "dry-run task-writing behavior regressed"

# ── Test 10: slug collisions allocate -2 suffixes ────────────────────────────
(
    setup_task_writer_fixture "slug-collision"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha Bug' \
        $'2\tcritical\tregression\tAlpha bug!!!'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha Bug |' \
        '| 2 | critical | regression | Alpha bug!!! |'

    agent_run_claude() {
        local output_path="$2"
        write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Collision task")"
        return 0
    }

    phase_task_writing >/dev/null 2>&1

    ok=true
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha-bug.md" ]] || ok=false
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-alpha-bug-2.md" ]] || ok=false
    [[ "${#CREATED_TASKS[@]}" -eq 2 ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "10. slug collisions allocate the -2 suffix for the second matching title" \
  || fail "10. slug collisions allocate the -2 suffix for the second matching title" "slug-collision handling regressed"

# ── Test 11: finding context joins digest rows by rank, not title ────────────
(
    setup_task_writer_fixture "rank-context"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tShared title' \
        $'2\tmajor\terror-handling\tShared title'
    write_digest_fixture \
        '| 1 | critical | regression | Shared title |' \
        '| 2 | major | error-handling | Shared title |'

    context_log="${TMP_DIR}/task-writer-rank-context.log"
    : > "${context_log}"
    agent_run_claude() {
        local output_path="$2"
        printf 'CALL\n%s\n===\n' "${NIGHTSHIFT_FINDING_TEXT}" >> "${context_log}"
        write_task_writer_result_json "${output_path}" "$(task_writer_created_result_text "Shared title task")"
        return 0
    }

    phase_task_writing >/dev/null 2>&1

    second_block="$(awk '
        /^CALL$/ { block_index++; next }
        /^===$/ { next }
        {
            if (block_index == 2) {
                print
            }
        }
    ' "${context_log}")"

    ok=true
    [[ "${second_block}" == *"Rank: 2"* ]] || ok=false
    [[ "${second_block}" == *"Full table row: | 2 | major | error-handling | Shared title |"* ]] || ok=false
    [[ "${second_block}" != *"Full table row: | 1 | critical | regression | Shared title |"* ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "11. NIGHTSHIFT_FINDING_TEXT is built from the digest row matching the finding rank" \
  || fail "11. NIGHTSHIFT_FINDING_TEXT is built from the digest row matching the finding rank" "rank-based context join regressed"

# ── Test 12: matching finding blocks append evidence-rich context ────────────
(
    setup_task_writer_fixture "full-finding-context"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |'

    cat > "${NIGHTSHIFT_FINDINGS_DIR}/commit-detective-findings.md" <<'EOF'
# Normalized commit-detective Findings — 2026-04-01

## Detective: commit-detective | status=ran | findings=1

## Source: commit-detective

### Finding: Alpha outage
**Severity:** critical
**Category:** regression
**Evidence:**
- `src/api/main.py:10` request path fails under retry bursts
- detective source: commit-detective
**Root Cause:**
Retry guard missing.
**Proposed Fix:**
Add the missing retry guard.

### Finding: Unrelated second finding
**Severity:** minor
**Category:** style
**Evidence:**
This content must NOT appear in the enriched output

## Source: security-detective

### Finding: Third finding in different source
**Severity:** major
**Category:** security
**Evidence:**
This content must also NOT appear in the enriched output
EOF

    warn_log="${TMP_DIR}/task-writer-full-context.warn.log"
    context_text="$(task_writer_finding_context "1" "critical" "regression" "Alpha outage" 2>"${warn_log}")"

    ok=true
    [[ "${context_text}" == *"Full table row: | 1 | critical | regression | Alpha outage |"* ]] || ok=false
    [[ "${context_text}" == *"### Finding: Alpha outage"* ]] || ok=false
    [[ "${context_text}" == *"**Evidence:**"* ]] || ok=false
    [[ "${context_text}" == *'`src/api/main.py:10` request path fails under retry bursts'* ]] || ok=false
    [[ "${context_text}" != *"Unrelated second finding"* ]] || ok=false
    [[ "${context_text}" != *"Third finding in different source"* ]] || ok=false
    [[ ! -s "${warn_log}" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "12. task_writer_finding_context appends the matched full finding block, including evidence" \
  || fail "12. task_writer_finding_context appends the matched full finding block, including evidence" "full finding block was not threaded into NIGHTSHIFT_FINDING_TEXT"

# ── Test 13: normalized title fallback matches header-only differences ───────
(
    setup_task_writer_fixture "normalized-context-fallback"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tQueue   Stalls During Retry Burst'
    write_digest_fixture \
        '| 1 | critical | regression | Queue   Stalls During Retry Burst |'

    cat > "${NIGHTSHIFT_FINDINGS_DIR}/commit-detective-findings.md" <<'EOF'
# Normalized commit-detective Findings — 2026-04-01

## Detective: commit-detective | status=ran | findings=1

## Source: claude

### Finding: queue stalls during  retry burst
**Severity:** critical
**Category:** regression
**Evidence:**
- queue stalls during retry burst when retries pile up
**Root Cause:**
Retry guard missing.
**Proposed Fix:**
Add the missing retry guard.
EOF

    warn_log="${TMP_DIR}/task-writer-normalized-context.warn.log"
    context_text="$(task_writer_finding_context "1" "critical" "regression" "Queue   Stalls During Retry Burst" 2>"${warn_log}")"

    ok=true
    [[ "${context_text}" == *"### Finding: queue stalls during  retry burst"* ]] || ok=false
    [[ "${context_text}" == *"queue stalls during retry burst when retries pile up"* ]] || ok=false
    [[ ! -s "${warn_log}" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "13. normalized title fallback can recover a finding block when the digest title differs from the header" \
  || fail "13. normalized title fallback can recover a finding block when the digest title differs from the header" "normalized fallback matching regressed"

# ── Test 14: missing canonical match warns and keeps thin context ────────────
(
    setup_task_writer_fixture "missing-context-match"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tGhost title'
    write_digest_fixture \
        '| 1 | critical | regression | Ghost title |'

    cat > "${NIGHTSHIFT_FINDINGS_DIR}/commit-detective-findings.md" <<'EOF'
# Normalized commit-detective Findings — 2026-04-01

## Detective: commit-detective | status=ran | findings=1

## Source: claude

### Finding: Different title
**Severity:** critical
**Category:** regression
**Evidence:**
- unrelated evidence
EOF

    warn_log="${TMP_DIR}/task-writer-missing-context.warn.log"
    context_text="$(task_writer_finding_context "1" "critical" "regression" "Ghost title" 2>"${warn_log}")"

    ok=true
    grep -Fq "WARN: Task writing could not match finding title 'Ghost title'" "${warn_log}" || ok=false
    [[ "${context_text}" == *"Rank: 1"* ]] || ok=false
    [[ "${context_text}" == *"Severity: critical"* ]] || ok=false
    [[ "${context_text}" == *"Category: regression"* ]] || ok=false
    [[ "${context_text}" == *"Title: Ghost title"* ]] || ok=false
    [[ "${context_text}" != *"### Finding:"* ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "14. missing canonical finding matches warn and keep the thin manifest-derived context" \
  || fail "14. missing canonical finding matches warn and keep the thin manifest-derived context" "missing-match fallback regressed"

# ── Test 15: same-file duplicate titles remain ambiguous ─────────────────────
(
    setup_task_writer_fixture "ambiguous-context-match"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tShared title'
    write_digest_fixture \
        '| 1 | critical | regression | Shared title |'

    cat > "${NIGHTSHIFT_FINDINGS_DIR}/commit-detective-findings.md" <<'EOF'
# Normalized commit-detective Findings — 2026-04-01

## Detective: commit-detective | status=ran | findings=1

## Source: claude

### Finding: Shared title
**Severity:** critical
**Category:** regression
**Evidence:**
- first source
### Finding: Shared title
**Severity:** critical
**Category:** regression
**Evidence:**
- second source
EOF

    warn_log="${TMP_DIR}/task-writer-ambiguous-context.warn.log"
    context_text="$(task_writer_finding_context "1" "critical" "regression" "Shared title" 2>"${warn_log}")"

    ok=true
    grep -Fq "WARN: Task writing found multiple finding blocks matching title 'Shared title'" "${warn_log}" || ok=false
    [[ "${context_text}" == *"Full table row: | 1 | critical | regression | Shared title |"* ]] || ok=false
    [[ "${context_text}" != *"### Finding:"* ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "15. ambiguous canonical finding matches warn and fall back to thin context" \
  || fail "15. ambiguous canonical finding matches warn and fall back to thin context" "ambiguous-match handling regressed"

# ── Test 16: cross-file corroboration merges matching finding blocks ─────────
(
    setup_task_writer_fixture "corroborating-context-match"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tShared title'
    write_digest_fixture \
        '| 1 | critical | regression | Shared title |'

    cat > "${NIGHTSHIFT_FINDINGS_DIR}/commit-detective-findings.md" <<'EOF'
# Normalized commit-detective Findings — 2026-04-01

## Detective: commit-detective | status=ran | findings=1

## Source: claude

### Finding: Shared title
**Severity:** critical
**Category:** regression
**Evidence:**
- commit evidence
EOF

    cat > "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" <<'EOF'
# Normalized security-detective Findings — 2026-04-01

## Detective: security-detective | status=ran | findings=1

## Source: codex

### Finding: Shared title
**Severity:** critical
**Category:** regression
**Evidence:**
- security evidence
EOF

    context_log="${TMP_DIR}/task-writer-corroborating-context.log"
    context_text="$(task_writer_finding_context "1" "critical" "regression" "Shared title" 2>"${context_log}")"
    finding_count="$(printf '%s\n' "${context_text}" | grep -c '^### Finding: Shared title$')"

    ok=true
    grep -Fq "INFO: Task writing merged 2 corroborating finding blocks for title 'Shared title'" "${context_log}" || ok=false
    ! grep -Fq "WARN:" "${context_log}" || ok=false
    [[ "${context_text}" == *"commit evidence"* ]] || ok=false
    [[ "${context_text}" == *"security evidence"* ]] || ok=false
    [[ "${finding_count}" == "2" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "16. corroborating finding blocks from different files are merged into enriched context" \
  || fail "16. corroborating finding blocks from different files are merged into enriched context" "corroborating-match merge regressed"

# ── Test 17: legacy autofix-only vars still drive task-writing fallback ──────
(
    setup_task_writer_fixture "legacy-autofix-fallback"
    DRY_RUN=1
    unset NIGHTSHIFT_TASK_WRITER_MAX_TASKS
    unset NIGHTSHIFT_TASK_WRITER_MIN_BUDGET
    unset NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY
    unset NIGHTSHIFT_AUTOFIX_MAX_TASKS
    unset NIGHTSHIFT_AUTOFIX_MIN_BUDGET
    unset NIGHTSHIFT_AUTOFIX_SEVERITY
    env_file="${TMP_DIR}/task-writer-legacy-autofix.env"
    cat > "${env_file}" <<'EOF'
NIGHTSHIFT_AUTOFIX_MAX_TASKS="1"
NIGHTSHIFT_AUTOFIX_MIN_BUDGET="123"
NIGHTSHIFT_AUTOFIX_SEVERITY="major"
EOF
    load_nightshift_configuration "${NS_DIR}/nightshift.conf" "${env_file}" >/dev/null 2>&1
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha outage' \
        $'2\tmajor\terror-handling\tBeta failure' \
        $'3\tmajor\tperformance\tGamma slowdown'
    write_digest_fixture \
        '| 1 | critical | regression | Alpha outage |' \
        '| 2 | major | error-handling | Beta failure |' \
        '| 3 | major | performance | Gamma slowdown |'

    log_path="${TMP_DIR}/task-writer-legacy-autofix-fallback.log"
    phase_task_writing >"${log_path}" 2>&1

    ok=true
    grep -Fq 'DRY RUN: would write task for: Beta failure (severity: major, remaining: $200.0000, minimum reserve: $123)' "${log_path}" || ok=false
    ! grep -Fq 'Alpha outage' "${log_path}" || ok=false
    ! grep -Fq 'Gamma slowdown' "${log_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "17. task writing falls back to legacy NIGHTSHIFT_AUTOFIX_* vars when task-writer vars are unset" \
  || fail "17. task writing falls back to legacy NIGHTSHIFT_AUTOFIX_* vars when task-writer vars are unset" "legacy fallback regressed"

# ── Test 18: regex metacharacters in titles match literally ──────────────────
(
    setup_task_writer_fixture "regex-metachar-context"
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tCache miss (v2)+.*'
    write_digest_fixture \
        '| 1 | critical | regression | Cache miss (v2)+.* |'

    cat > "${NIGHTSHIFT_FINDINGS_DIR}/commit-detective-findings.md" <<'EOF'
# Normalized commit-detective Findings — 2026-04-01

## Detective: commit-detective | status=ran | findings=1

## Source: codex

### Finding: Cache miss (v2)+.*
**Severity:** critical
**Category:** regression
**Evidence:**
- literal title contains regex metacharacters
EOF

    warn_log="${TMP_DIR}/task-writer-regex-metachar-context.warn.log"
    context_text="$(task_writer_finding_context "1" "critical" "regression" "Cache miss (v2)+.*" 2>"${warn_log}")"

    ok=true
    [[ "${context_text}" == *"Full table row: | 1 | critical | regression | Cache miss (v2)+.* |"* ]] || ok=false
    [[ "${context_text}" == *"### Finding: Cache miss (v2)+.*"* ]] || ok=false
    [[ "${context_text}" == *"literal title contains regex metacharacters"* ]] || ok=false
    [[ ! -s "${warn_log}" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "18. task_writer_finding_context matches regex metacharacters in titles literally without warnings" \
  || fail "18. task_writer_finding_context matches regex metacharacters in titles literally without warnings" "literal metacharacter title matching regressed"

# ── Test 19: empty task-writer vars fall back to legacy resolver values ──────
(
    setup_task_writer_fixture "empty-string-direct-fallback"
    NIGHTSHIFT_TASK_WRITER_MAX_TASKS=""
    NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY=""
    NIGHTSHIFT_TASK_WRITER_MIN_BUDGET=""
    NIGHTSHIFT_AUTOFIX_MAX_TASKS="3"
    NIGHTSHIFT_AUTOFIX_SEVERITY="major"
    NIGHTSHIFT_AUTOFIX_MIN_BUDGET="17"

    resolved_max_tasks="$(task_writer_max_tasks_setting)"
    resolved_min_severity="$(task_writer_min_severity_setting)"
    resolved_min_budget="$(task_writer_min_budget_setting)"

    ok=true
    [[ "${resolved_max_tasks}" == "3" ]] || ok=false
    [[ "${resolved_min_severity}" == "major" ]] || ok=false
    [[ "${resolved_min_budget}" == "17" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "19. empty NIGHTSHIFT_TASK_WRITER_* vars fall back to legacy resolver values instead of returning blank" \
  || fail "19. empty NIGHTSHIFT_TASK_WRITER_* vars fall back to legacy resolver values instead of returning blank" "empty-string resolver fallback regressed"

# ── Test 20: load-time normalization repairs blank task-writer env vars ──────
(
    setup_task_writer_fixture "empty-string-load-fallback"
    unset NIGHTSHIFT_TASK_WRITER_MAX_TASKS
    unset NIGHTSHIFT_TASK_WRITER_MIN_BUDGET
    unset NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY
    unset NIGHTSHIFT_AUTOFIX_MAX_TASKS
    unset NIGHTSHIFT_AUTOFIX_MIN_BUDGET
    unset NIGHTSHIFT_AUTOFIX_SEVERITY
    env_file="${TMP_DIR}/task-writer-empty-string.env"
    cat > "${env_file}" <<'EOF'
NIGHTSHIFT_TASK_WRITER_MAX_TASKS=""
NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY=""
NIGHTSHIFT_TASK_WRITER_MIN_BUDGET=""
NIGHTSHIFT_AUTOFIX_MAX_TASKS="3"
NIGHTSHIFT_AUTOFIX_MIN_BUDGET="17"
NIGHTSHIFT_AUTOFIX_SEVERITY="major"
EOF
    load_nightshift_configuration "${NS_DIR}/nightshift.conf" "${env_file}" >/dev/null 2>&1

    ok=true
    [[ "${NIGHTSHIFT_TASK_WRITER_MAX_TASKS}" == "3" ]] || ok=false
    [[ "${NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY}" == "major" ]] || ok=false
    [[ "${NIGHTSHIFT_TASK_WRITER_MIN_BUDGET}" == "17" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "20. load_nightshift_configuration repairs blank task-writer env vars from legacy autofix values" \
  || fail "20. load_nightshift_configuration repairs blank task-writer env vars from legacy autofix values" "blank env-file normalization regressed"

# ── Test 21: main() orders task writing before validation before autofix ─────
(
    main_calls="$(sed -n '/^main()/,/^}/p' "${NS_DIR}/nightshift.sh" | grep -nE 'phase_(task_writing|validation|autofix)')"
    task_line="$(printf '%s\n' "${main_calls}" | grep 'phase_task_writing' | head -n 1 | cut -d: -f1)"
    validation_line="$(printf '%s\n' "${main_calls}" | grep 'phase_validation' | head -n 1 | cut -d: -f1)"
    autofix_line="$(printf '%s\n' "${main_calls}" | grep 'phase_autofix' | head -n 1 | cut -d: -f1)"

    [[ -n "${task_line}" ]]
    [[ -n "${validation_line}" ]]
    [[ -n "${autofix_line}" ]]
    [[ "${task_line}" -lt "${validation_line}" ]]
    [[ "${validation_line}" -lt "${autofix_line}" ]]
) && pass "21. main() calls phase_task_writing before phase_validation before phase_autofix" \
  || fail "21. main() calls phase_task_writing before phase_validation before phase_autofix" "phase order regressed"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (21 tests) ==="
[[ "${FAIL}" -eq 0 ]]

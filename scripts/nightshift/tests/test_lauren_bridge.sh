#!/usr/bin/env bash
# test_lauren_bridge.sh — Focused tests for the Night Shift Lauren Loop bridge.
#
# Usage: bash scripts/nightshift/tests/test_lauren_bridge.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT_ACTUAL="$(cd "${NS_DIR}/../.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

write_manager_task() {
    local path="$1"
    local title="$2"
    local goal="$3"
    mkdir -p "$(dirname "${path}")"
    cat > "${path}" <<EOF
## Task: ${title}
## Status: not started
## Created: 2026-03-30
## Execution Mode: single-agent

## Motivation
Bridge test fixture.

## Goal
${goal}

## Scope
### In Scope
- Test bridge behavior

### Out of Scope
- Anything else

## Relevant Files
- \`src/example.py\` — fixture reference

## Context
- Source fixture for bridge tests

## Anti-Patterns
- Do NOT modify unrelated files

## Done Criteria
- [ ] Bridge fixture consumed correctly

## Code Review: not started

## Left Off At
Not started.

## Attempts
(none)
EOF
}

write_digest_fixture() {
    local path="$1"
    cat > "${path}" <<'EOF'
# Nightshift Detective Digest — 2026-03-30

## Ranked Findings

| # | File | Severity | Category | Title |
|---|------|----------|----------|-------|
| 1 | `docs/tasks/open/nightshift/2026-03-30-alpha.md` | critical | regression | Alpha failure |
| 2 | `docs/tasks/open/nightshift/2026-03-30-beta.md` | major | error-handling | Beta error path |
| 3 | `docs/tasks/open/nightshift/2026-03-30-gamma.md` | minor | performance | Gamma perf note |
| 4 | `docs/tasks/open/nightshift/2026-03-30-delta.md` | major | security | Delta validation gap |

## Minor & Observation Findings

| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
| 1 | Informational note | observation | data-quality | coverage | Summary only |
EOF
}

write_triage_only_digest_fixture() {
    local path="$1"
    cat > "${path}" <<'EOF'
# Nightshift Detective Digest — 2026-03-30

## Ranked Findings

| # | Severity | Category | Title |
|---|----------|----------|-------|
| 1 | critical | regression | Alpha failure |
| 2 | major | error-handling | Beta error path |

## Minor & Observation Findings

| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
| 1 | Informational note | observation | data-quality | coverage | Summary only |
EOF
}

write_manager_task_manifest_fixture() {
    local manifest_path=""
    local task_path=""

    manifest_path="$(bridge_manager_task_manifest_path)"
    mkdir -p "$(dirname "${manifest_path}")"
    : > "${manifest_path}"

    for task_path in "$@"; do
        printf '%s\n' "${task_path}" >> "${manifest_path}"
    done
}

echo "=== test_lauren_bridge.sh ==="
echo ""

source "${NS_DIR}/nightshift.conf"
source "${NS_DIR}/nightshift.sh"
source "${NS_DIR}/lib/lauren-bridge.sh"

# ── Test 1: digest table parsing ──────────────────────────────────────────────
(
    digest_path="${TMP_DIR}/parse-digest.md"
    write_digest_fixture "${digest_path}"

    parsed=()
    while IFS= read -r line; do
        parsed+=("${line}")
    done < <(bridge_parse_digest "${digest_path}")

    [[ "${#parsed[@]}" -eq 4 ]]
    [[ "${parsed[0]}" == $'docs/tasks/open/nightshift/2026-03-30-alpha.md\tcritical\tregression\tAlpha failure' ]]
    [[ "${parsed[1]}" == $'docs/tasks/open/nightshift/2026-03-30-beta.md\tmajor\terror-handling\tBeta error path' ]]
    [[ "${parsed[3]}" == $'docs/tasks/open/nightshift/2026-03-30-delta.md\tmajor\tsecurity\tDelta validation gap' ]]
) && pass "1. bridge_parse_digest reads Ranked Findings rows in order" \
  || fail "1. bridge_parse_digest reads Ranked Findings rows in order" "parsed rows were missing or malformed"

# ── Test 2: triage-only digests still skip when manifest is missing ──────────
(
    REPO_ROOT="${TMP_DIR}/repo-triage-only"
    RUN_TMP_DIR="${TMP_DIR}/repo-triage-only/run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="3"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0

    digest_path="${TMP_DIR}/triage-only-digest.md"
    run_log="${TMP_DIR}/triage-only-bridge.log"
    write_triage_only_digest_fixture "${digest_path}"

    set +e
    bridge_run "${digest_path}" "false" > "${run_log}"
    rc=$?
    set -e

    [[ "${rc}" -eq 0 ]]
    [[ "${BRIDGE_SKIPPED}" -eq 1 ]]
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 0 ]]
    grep -Fq 'Bridge skip: findings-manifest contains triage metadata only — no task files to materialize. Task-writer phase required.' "${run_log}"
    [[ ! -d "${REPO_ROOT}/docs/tasks/open" ]]
) && pass "2. bridge_run keeps the Session B skip when a triage-only digest has no manifest" \
  || fail "2. bridge_run keeps the Session B skip when a triage-only digest has no manifest" "missing-manifest triage-only behavior regressed"

# ── Test 3: triage-only digests still skip when manifest is empty ────────────
(
    REPO_ROOT="${TMP_DIR}/repo-triage-empty"
    RUN_TMP_DIR="${TMP_DIR}/repo-triage-empty/run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="3"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0

    digest_path="${TMP_DIR}/triage-empty-digest.md"
    run_log="${TMP_DIR}/triage-empty-bridge.log"
    write_triage_only_digest_fixture "${digest_path}"
    write_manager_task_manifest_fixture

    bridge_run "${digest_path}" "false" > "${run_log}"

    [[ "${BRIDGE_SKIPPED}" -eq 1 ]]
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 0 ]]
    grep -Fq 'Bridge skip: findings-manifest contains triage metadata only — no task files to materialize. Task-writer phase required.' "${run_log}"
) && pass "3. bridge_run keeps the Session B skip when the triage-only manifest is empty" \
  || fail "3. bridge_run keeps the Session B skip when the triage-only manifest is empty" "empty-manifest triage-only behavior regressed"

# ── Test 4: triage-only digests use manager-task-manifest fallback ───────────
(
    REPO_ROOT="${TMP_DIR}/repo-triage-manifest"
    RUN_TMP_DIR="${TMP_DIR}/repo-triage-manifest/run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="critical"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="3"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0

    digest_path="${TMP_DIR}/triage-manifest-digest.md"
    run_log="${TMP_DIR}/triage-manifest-bridge.log"
    alpha_task="${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md"
    beta_task="${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-beta.md"

    write_triage_only_digest_fixture "${digest_path}"
    write_manager_task "${alpha_task}" "Alpha failure" "System handles alpha failures without crashing."
    write_manager_task "${beta_task}" "Beta error path" "System keeps beta error handling intact."
    write_manager_task_manifest_fixture "${alpha_task}" "${beta_task}"

    bridge_run "${digest_path}" "false" > "${run_log}"

    ok=true
    [[ "${BRIDGE_SKIPPED}" -eq 0 ]] || ok=false
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 2 ]] || ok=false
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-alpha/task.md" ]] || ok=false
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-beta/task.md" ]] || ok=false
    grep -Fq 'Bridge: digest is triage-only but task manifest exists with 2 task file(s). Reading paths from manifest.' "${run_log}" || ok=false
    ! grep -Fq 'Bridge skip: findings-manifest contains triage metadata only — no task files to materialize. Task-writer phase required.' "${run_log}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "4. bridge_run falls back to manager-task-manifest paths for triage-only digests" \
  || fail "4. bridge_run falls back to manager-task-manifest paths for triage-only digests" "manifest fallback did not materialize runtime bridge tasks"

# ── Test 5: triage-only digests skip when all manifest paths are missing ─────
(
    REPO_ROOT="${TMP_DIR}/repo-triage-missing-paths"
    RUN_TMP_DIR="${TMP_DIR}/repo-triage-missing-paths/run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="3"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0

    digest_path="${TMP_DIR}/triage-missing-paths-digest.md"
    run_log="${TMP_DIR}/triage-missing-paths-bridge.log"
    missing_alpha="${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md"
    missing_beta="${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-beta.md"

    write_triage_only_digest_fixture "${digest_path}"
    write_manager_task_manifest_fixture "${missing_alpha}" "${missing_beta}"

    bridge_run "${digest_path}" "false" > "${run_log}"

    ok=true
    [[ "${BRIDGE_SKIPPED}" -eq 1 ]] || ok=false
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 0 ]] || ok=false
    grep -Fq "WARN: Bridge: task file missing: ${missing_alpha}" "${run_log}" || ok=false
    grep -Fq "WARN: Bridge: task file missing: ${missing_beta}" "${run_log}" || ok=false
    grep -Fq 'Bridge skip: findings-manifest contains triage metadata only — no task files to materialize. Task-writer phase required.' "${run_log}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "5. bridge_run treats all-missing manifest paths the same as an empty triage-only manifest" \
  || fail "5. bridge_run treats all-missing manifest paths the same as an empty triage-only manifest" "all-missing manifest handling regressed"

# ── Test 6: duplicate manifest entries are skipped after path resolution ──────
(
    REPO_ROOT="${TMP_DIR}/repo-triage-duplicate-paths"
    RUN_TMP_DIR="${TMP_DIR}/repo-triage-duplicate-paths/run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="3"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0

    digest_path="${TMP_DIR}/triage-duplicate-paths-digest.md"
    run_log="${TMP_DIR}/triage-duplicate-paths-bridge.log"
    source_task="${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md"
    runtime_task="${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-alpha/task.md"

    write_triage_only_digest_fixture "${digest_path}"
    write_manager_task "${source_task}" "Alpha failure" "System handles alpha failures without crashing."
    write_manager_task_manifest_fixture "${source_task}" "${source_task}"

    bridge_run "${digest_path}" "false" > "${run_log}"

    ok=true
    [[ "${BRIDGE_SKIPPED}" -eq 0 ]] || ok=false
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 1 ]] || ok=false
    [[ -f "${runtime_task}" ]] || ok=false
    grep -Fq "WARN: Bridge: skipping duplicate manifest entry: ${source_task}" "${run_log}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "6. bridge_run deduplicates duplicate manifest entries by resolved path" \
  || fail "6. bridge_run deduplicates duplicate manifest entries by resolved path" "duplicate manifest entry was not skipped"

# ── Test 7: relative manifest paths resolve from REPO_ROOT even without EOL ──
(
    REPO_ROOT="${TMP_DIR}/repo-triage-relative-path"
    RUN_TMP_DIR="${TMP_DIR}/repo-triage-relative-path/run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="3"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0

    digest_path="${TMP_DIR}/triage-relative-path-digest.md"
    relative_task="docs/tasks/open/nightshift/test-relative.md"
    source_task="${REPO_ROOT}/${relative_task}"
    manifest_path="$(bridge_manager_task_manifest_path)"
    runtime_task="${REPO_ROOT}/docs/tasks/open/nightshift-bridge-test-relative/task.md"
    runtime_task_dir="$(dirname "${runtime_task}")"

    write_triage_only_digest_fixture "${digest_path}"
    write_manager_task "${source_task}" "Relative path task" "System preserves relative-path manifest task content."
    mkdir -p "$(dirname "${manifest_path}")"
    printf '%s' "${relative_task}" > "${manifest_path}"

    bridge_run "${digest_path}" "false" > "${TMP_DIR}/triage-relative-path-bridge.log"

    ok=true
    [[ "${BRIDGE_SKIPPED}" -eq 0 ]] || ok=false
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 1 ]] || ok=false
    [[ "${BRIDGE_STAGE_PATHS[0]}" == "${runtime_task_dir}" ]] || ok=false
    [[ -f "${runtime_task}" ]] || ok=false
    grep -Fq 'System preserves relative-path manifest task content.' "${runtime_task}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "7. bridge_run resolves relative manifest paths from REPO_ROOT" \
  || fail "7. bridge_run resolves relative manifest paths from REPO_ROOT" "relative manifest path did not materialize correctly"

# ── Test 8: severity threshold filtering ──────────────────────────────────────
(
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="critical"
    bridge_should_execute "critical"
    ! bridge_should_execute "major"
    ! bridge_should_execute "observation"
) && pass "8. bridge_should_execute honors NIGHTSHIFT_BRIDGE_MIN_SEVERITY" \
  || fail "8. bridge_should_execute honors NIGHTSHIFT_BRIDGE_MIN_SEVERITY" "severity gating was incorrect"

# ── Test 9: runtime task file creation adds Lauren sections without moving source ──
(
    REPO_ROOT="${TMP_DIR}/repo-create"
    RUN_DATE="2026-03-30"
    BRIDGE_STAGE_PATHS=()

    source_task="${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md"
    write_manager_task "${source_task}" "Alpha failure" "System handles alpha failures without crashing."

    runtime_info="$(bridge_create_task_file "${source_task}" "critical" "regression" "Alpha failure")"
    runtime_info="$(printf '%s\n' "${runtime_info}" | tail -n 1)"
    IFS=$'\t' read -r runtime_slug runtime_task_file <<< "${runtime_info}"

    [[ -f "${source_task}" ]]
    [[ "${runtime_slug}" == "nightshift-bridge-2026-03-30-alpha" ]]
    [[ "${runtime_task_file}" == "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-alpha/task.md" ]]
    [[ -f "${runtime_task_file}" ]]
    grep -q '^## Goal$' "${runtime_task_file}"
    grep -q '^## Current Plan$' "${runtime_task_file}"
    grep -q '^## Critique$' "${runtime_task_file}"
    grep -q '^## Plan History$' "${runtime_task_file}"
    grep -q '^## Execution Log$' "${runtime_task_file}"
    grep -q 'System handles alpha failures without crashing\.' "${runtime_task_file}"
) && pass "9. bridge_create_task_file copies manager task content into a V2 runtime task" \
  || fail "9. bridge_create_task_file copies manager task content into a V2 runtime task" "runtime task file was missing or malformed"

# ── Test 10: Lauren invocation uses verified V2 positional CLI + strict mode ──
(
    REPO_ROOT="${TMP_DIR}/repo-invoke"
    RUN_DATE="2026-03-30"
    runtime_slug="nightshift-bridge-2026-03-30-alpha"
    runtime_task_file="${REPO_ROOT}/docs/tasks/open/${runtime_slug}/task.md"
    args_capture="${TMP_DIR}/invoke.args"
    env_capture="${TMP_DIR}/invoke.env"

    write_manager_task "${runtime_task_file}" "Alpha failure" "System keeps processing alpha failures."

    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1|\$2|\${3:-}" > "${args_capture}"
printf 'max=%s\nnoninteractive=%s\n' "\${LAUREN_LOOP_MAX_COST:-}" "\${LAUREN_LOOP_NONINTERACTIVE:-}" > "${env_capture}"
EOF

    bridge_cost_cap_for_remaining_slots() {
        printf '12.34\n'
    }

    bridge_invoke_lauren_loop "${runtime_slug}" "${runtime_task_file}" "2"

    [[ "$(cat "${args_capture}")" == "nightshift-bridge-2026-03-30-alpha|System keeps processing alpha failures.|--strict" ]]
    grep -q '^max=12.34$' "${env_capture}"
    grep -q '^noninteractive=1$' "${env_capture}"
) && pass "10. bridge_invoke_lauren_loop uses positional V2 CLI with --strict and cost env" \
  || fail "10. bridge_invoke_lauren_loop uses positional V2 CLI with --strict and cost env" "Lauren invocation shape or env was wrong"

# ── Test 11: path-backed digests ignore the manifest and keep existing behavior ──
(
    REPO_ROOT="${TMP_DIR}/repo-run"
    RUN_TMP_DIR="${TMP_DIR}/repo-run/run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="3"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()
    INVOKE_COUNT=0

    digest_path="${TMP_DIR}/run-digest.md"
    run_log="${TMP_DIR}/run-digest.log"
    write_digest_fixture "${digest_path}"

    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md" "Alpha failure" "System handles alpha failures."
    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-beta.md" "Beta error path" "System keeps beta error handling intact."
    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-delta.md" "Delta validation gap" "System blocks invalid delta inputs."
    write_manager_task_manifest_fixture "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-missing.md"

    bridge_invoke_lauren_loop() {
        INVOKE_COUNT=$((INVOKE_COUNT + 1))
        return 0
    }

    bridge_run "${digest_path}" "false" > "${run_log}"

    ok=true
    [[ "${INVOKE_COUNT}" -eq 0 ]]
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-alpha/task.md" ]]
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-beta/task.md" ]]
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-delta/task.md" ]]
    [[ ! -e "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-gamma" ]]
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 3 ]] || ok=false
    ! grep -Fq 'Bridge: digest is triage-only but task manifest exists' "${run_log}" || ok=false
    ! grep -Fq 'Bridge: task file missing:' "${run_log}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "11. bridge_run keeps path-backed digest behavior and does not consult the manifest" \
  || fail "11. bridge_run keeps path-backed digest behavior and does not consult the manifest" "path-backed digest behavior changed or manifest was consulted"

# ── Test 12: dry-run preview logs actions without creating runtime task files ──
(
    REPO_ROOT="${TMP_DIR}/repo-dry-run"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="2"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="true"
    BRIDGE_STAGE_PATHS=()

    digest_path="${TMP_DIR}/dry-run-digest.md"
    dry_run_log="${TMP_DIR}/dry-run.log"
    write_digest_fixture "${digest_path}"

    bridge_run "${digest_path}" "true" > "${dry_run_log}"

    grep -q 'DRY RUN: would prepare runtime task' "${dry_run_log}"
    grep -q 'DRY RUN: would invoke Lauren Loop V2' "${dry_run_log}"
    [[ ! -d "${REPO_ROOT}/docs/tasks/open" ]]
) && pass "12. bridge_run dry-run previews work without creating task files" \
  || fail "12. bridge_run dry-run previews work without creating task files" "dry-run created files or missed preview logs"

# ── Test 13: phase_bridge remains non-gating when bridge_run fails ────────────
(
    NIGHTSHIFT_BRIDGE_ENABLED="true"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    DRY_RUN=0
    SETUP_FAILED=0
    BRANCH_READY=1
    RUN_COST_CAP=0
    RUN_FAILED=0
    DIGEST_PATH="${TMP_DIR}/phase-bridge-digest.md"
    printf '# digest\n' > "${DIGEST_PATH}"

    bridge_run() {
        return 1
    }

    phase_bridge >/dev/null
    [[ "${RUN_FAILED}" -eq 0 ]]
) && pass "13. phase_bridge treats bridge failures as warning-only and continues" \
  || fail "13. phase_bridge treats bridge failures as warning-only and continues" "phase_bridge propagated a bridge failure into RUN_FAILED"

# ── Test 14: max-task cap truncates when qualifying rows exceed the cap ───────
(
    REPO_ROOT="${TMP_DIR}/repo-cap"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="2"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="false"
    BRIDGE_STAGE_PATHS=()

    # Digest with 4 qualifying critical/major rows (all pass the severity filter)
    digest_path="${TMP_DIR}/cap-digest.md"
    cat > "${digest_path}" <<'DIGEST'
# Nightshift Detective Digest — 2026-03-30

## Ranked Findings

| # | File | Severity | Category | Title |
|---|------|----------|----------|-------|
| 1 | `docs/tasks/open/nightshift/2026-03-30-alpha.md` | critical | regression | Alpha failure |
| 2 | `docs/tasks/open/nightshift/2026-03-30-beta.md` | major | error-handling | Beta error path |
| 3 | `docs/tasks/open/nightshift/2026-03-30-gamma.md` | major | performance | Gamma perf issue |
| 4 | `docs/tasks/open/nightshift/2026-03-30-delta.md` | major | security | Delta validation gap |
DIGEST

    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md" "Alpha failure" "System handles alpha failures."
    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-beta.md" "Beta error path" "System keeps beta error handling intact."
    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-gamma.md" "Gamma perf issue" "System improves gamma performance."
    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-delta.md" "Delta validation gap" "System blocks invalid delta inputs."

    cap_log="${TMP_DIR}/cap-run.log"
    bridge_run "${digest_path}" "false" > "${cap_log}"

    # Only 2 task dirs created (alpha + beta); gamma and delta skipped by cap
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-alpha/task.md" ]]
    [[ -f "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-beta/task.md" ]]
    [[ ! -e "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-gamma" ]]
    [[ ! -e "${REPO_ROOT}/docs/tasks/open/nightshift-bridge-2026-03-30-delta" ]]
    [[ "${#BRIDGE_STAGE_PATHS[@]}" -eq 2 ]]
    grep -q 'Task cap reached (2)' "${cap_log}"
) && pass "14. bridge_run max-task cap truncates at 2 when 4 rows qualify" \
  || fail "14. bridge_run max-task cap truncates at 2 when 4 rows qualify" "cap did not truncate — wrong number of tasks or missing log message"

# ── Test 15: live bridge execution does not drain digest stdin and logs real exit ──
(
    REPO_ROOT="${TMP_DIR}/repo-live"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="2"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="true"
    BRIDGE_STAGE_PATHS=()
    invoke_log="${TMP_DIR}/live-invoke.log"
    run_log="${TMP_DIR}/live-run.log"

    digest_path="${TMP_DIR}/live-digest.md"
    write_digest_fixture "${digest_path}"

    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md" "Alpha failure" "System handles alpha failures."
    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-beta.md" "Beta error path" "System keeps beta error handling intact."

    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "\$1|\$2|\${3:-}" >> "${invoke_log}"
exit 7
EOF
    chmod +x "${REPO_ROOT}/lauren-loop-v2.sh"

    bridge_run "${digest_path}" "false" > "${run_log}"

    [[ "$(wc -l < "${invoke_log}" | tr -d '[:space:]')" -eq 2 ]]
    grep -q '^nightshift-bridge-2026-03-30-alpha|System handles alpha failures\.|--strict$' "${invoke_log}"
    grep -q '^nightshift-bridge-2026-03-30-beta|System keeps beta error handling intact\.|--strict$' "${invoke_log}"
    grep -q 'WARN: Lauren Loop V2 failed for nightshift-bridge-2026-03-30-alpha with exit 7' "${run_log}"
    grep -q 'WARN: Lauren Loop V2 failed for nightshift-bridge-2026-03-30-beta with exit 7' "${run_log}"
    grep -q 'Bridge summary: qualified=3, selected=2, prepared=2, invoked=0, dry_run=false' "${run_log}"
) && pass "15. bridge_run preserves digest iteration and logs the real Lauren exit code" \
  || fail "15. bridge_run preserves digest iteration and logs the real Lauren exit code" "stdin drain or exit-code reporting regressed"

# ── Test 16: SIGTERM bridge child logs shell exit code 143 ───────────────────
(
    REPO_ROOT="${TMP_DIR}/repo-sigterm"
    RUN_DATE="2026-03-30"
    NIGHTSHIFT_BRIDGE_MIN_SEVERITY="major"
    NIGHTSHIFT_BRIDGE_MAX_TASKS="1"
    NIGHTSHIFT_BRIDGE_AUTO_EXECUTE="true"
    BRIDGE_STAGE_PATHS=()
    invoke_log="${TMP_DIR}/sigterm-invoke.log"
    run_log="${TMP_DIR}/sigterm-run.log"

    digest_path="${TMP_DIR}/sigterm-digest.md"
    write_digest_fixture "${digest_path}"

    write_manager_task "${REPO_ROOT}/docs/tasks/open/nightshift/2026-03-30-alpha.md" "Alpha failure" "System handles alpha failures."

    cat > "${REPO_ROOT}/lauren-loop-v2.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "\$1|\$2|\${3:-}" >> "${invoke_log}"
kill -TERM \$\$
EOF
    chmod +x "${REPO_ROOT}/lauren-loop-v2.sh"

    bridge_run "${digest_path}" "false" > "${run_log}"

    grep -q '^nightshift-bridge-2026-03-30-alpha|System handles alpha failures\.|--strict$' "${invoke_log}"
    grep -q 'WARN: Lauren Loop V2 failed for nightshift-bridge-2026-03-30-alpha with exit 143' "${run_log}"
) && pass "16. bridge_run logs SIGTERM child exits as 143" \
  || fail "16. bridge_run logs SIGTERM child exits as 143" "SIGTERM exit code handling regressed"

echo ""
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi

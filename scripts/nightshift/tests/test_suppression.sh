#!/usr/bin/env bash
# test_suppression.sh — Focused tests for Night Shift suppression behavior.
#
# Usage: bash scripts/nightshift/tests/test_suppression.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${NS_DIR}/../.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

echo "=== test_suppression.sh ==="
echo ""

source "${NS_DIR}/nightshift.conf"
source "${NS_DIR}/nightshift.sh"
source "${NS_DIR}/lib/suppression.sh"

setup_suppression_fixture() {
    local fixture_name="$1"

    RUN_TMP_DIR="${TMP_DIR}/${fixture_name}/run"
    NIGHTSHIFT_FINDINGS_DIR="${TMP_DIR}/${fixture_name}/findings"
    NIGHTSHIFT_SUPPRESSIONS_FILE="${TMP_DIR}/${fixture_name}/suppressions.yaml"
    NIGHTSHIFT_DIGESTS_DIR="${TMP_DIR}/${fixture_name}/digests"
    DETECTIVE_STATUS_DIR="${RUN_TMP_DIR}/detective-status"
    RUN_DATE="2026-04-16"
    RUN_ID="test-suppression-${fixture_name}"
    DIGEST_PATH="${TMP_DIR}/${fixture_name}/digest.md"
    WARNING_NOTES=""
    FAILURE_NOTES=""
    TOTAL_FINDINGS_AVAILABLE=0
    FINDINGS_ELIGIBLE_FOR_RANKING=0
    SUPPRESSED_FINDINGS_COUNT=0
    TASK_FILE_COUNT=0

    mkdir -p "${RUN_TMP_DIR}" "${NIGHTSHIFT_FINDINGS_DIR}" "${NIGHTSHIFT_DIGESTS_DIR}" "${DETECTIVE_STATUS_DIR}"
    : > "${NIGHTSHIFT_SUPPRESSIONS_FILE}"
}

write_findings_file() {
    local file_path="$1"
    shift
    mkdir -p "$(dirname "${file_path}")"
    {
        printf '# Normalized security-detective Findings — 2026-04-16\n\n'
        printf '## Detective: security-detective | status=ran | findings=%s\n\n' "$#"
        printf '## Source: claude\n\n'
        local index=0
        local block=""
        for block in "$@"; do
            printf '%s\n' "${block}"
            index=$(( index + 1 ))
            if (( index < $# )); then
                printf '\n\n'
            fi
        done
    } > "${file_path}"
}

finding_block() {
    local title="$1"
    local category="$2"
    local rule_key="$3"
    local evidence="$4"
    local primary_file="${5:-}"

    printf '### Finding: %s\n' "${title}"
    printf '**Severity:** major\n'
    printf '**Category:** %s\n' "${category}"
    if [[ -n "${rule_key}" ]]; then
        printf '**Rule Key:** %s\n' "${rule_key}"
    fi
    if [[ -n "${primary_file}" ]]; then
        printf '**Primary File:** %s\n' "${primary_file}"
    fi
    printf '**Evidence:**\n'
    printf -- '- %s\n' "${evidence}"
    printf '**Root Cause:** Example root cause.\n'
    printf '**Proposed Fix:** Example proposed fix.\n'
    printf '**Affected Users:** Example users.\n'
}

write_digest_fixture() {
    local path="$1"
    local table_row="$2"
    local detail_heading="$3"
    local source_line="$4"
    cat > "${path}" <<EOF
# Nightshift Detective Digest — 2026-04-16

## Ranked Findings
| # | Severity | Category | Title |
|---|----------|----------|-------|
${table_row}

${detail_heading}

${source_line}

## Minor & Observation Findings
| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
EOF
}

# 1. finding-scope fingerprint ignores line numbers
(
    setup_suppression_fixture "line-numbers"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth path A" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")" \
        "$(finding_block "Chat auth path B" "security" "CWE-306" "src/api/routers/chat.py:800-900 anonymous access")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306
  rationale: EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.
  added_by: george
  added_date: 2026-04-16
  expires_date: 2026-07-15
  scope: finding
EOF

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    [[ "${SUPPRESSED_FINDINGS_COUNT}" == "2" ]]
) && pass "1. finding-scope suppression fingerprint ignores line numbers" \
  || fail "1. finding-scope suppression fingerprint ignores line numbers" "suppressed count did not prove line-number independence"

# 2. valid suppression excludes finding from ranking and renders audit section
(
    setup_suppression_fixture "audit-section"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")" \
        "$(finding_block "Feedback metrics unauthenticated" "security" "CWE-862" "src/api/routers/feedback.py:40-50 auth missing")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306
  rationale: EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.
  added_by: george
  added_date: 2026-04-16
  expires_date: 2026-07-15
  scope: finding
EOF
    write_digest_fixture \
        "${DIGEST_PATH}" \
        '| 1 | major | security | Feedback metrics unauthenticated |' \
        '### 1. Feedback metrics unauthenticated' \
        '**Source Detective:** security-detective'

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    rewrite_manager_digest "${DIGEST_PATH}"
    nightshift_annotate_digest_with_fingerprints "${DIGEST_PATH}" >/dev/null
    write_findings_manifest "${DIGEST_PATH}"

    grep -Fq -- '- **Ranked:** 1 (1 suppressed)' "${DIGEST_PATH}" &&
    grep -Fq '## Suppressed Findings (Audit Only)' "${DIGEST_PATH}" &&
    grep -Fq 'security-detective:security:src/api/routers/chat.py:CWE-306' "${DIGEST_PATH}" &&
    grep -Fq $'1\tmajor\tsecurity\tFeedback metrics unauthenticated' "$(findings_manifest_path)" &&
    ! grep -Fq '### 1. Chat auth missing' "${DIGEST_PATH}"
) && pass "2. valid suppression skips ranking and appears in the audit-only digest section" \
  || fail "2. valid suppression skips ranking and appears in the audit-only digest section" "digest summary or audit rendering regressed"

# 3. expired suppression does not filter and surfaces expired section
(
    setup_suppression_fixture "expired"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306
  rationale: EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.
  added_by: george
  added_date: 2026-01-01
  expires_date: 2026-04-01
  scope: finding
EOF

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    grep -Fq 'expired' <<< "${WARNING_NOTES}" &&
    [[ "${SUPPRESSED_FINDINGS_COUNT}" == "0" ]] &&
    grep -Fq '## Expired Suppressions' "$(nightshift_suppression_section_path "expired-suppressions.md")"
) && pass "3. expired suppression flows through and renders the expired-suppressions section" \
  || fail "3. expired suppression flows through and renders the expired-suppressions section" "expired suppressions were applied or not surfaced"

# 4. expiring soon section renders within 14 days
(
    setup_suppression_fixture "expiring"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306
  rationale: EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.
  added_by: george
  added_date: 2026-04-16
  expires_date: 2026-04-20
  scope: finding
EOF

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    grep -Fq '## Expiring Soon' "$(nightshift_suppression_section_path "expiring-soon.md")" &&
    grep -Fq '2026-04-20' "$(nightshift_suppression_section_path "expiring-soon.md")"
) && pass "4. expiring-soon suppressions surface within the 14-day window" \
  || fail "4. expiring-soon suppressions surface within the 14-day window" "expiring-soon section missing"

# 5. malformed YAML warns without crashing
(
    setup_suppression_fixture "malformed"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")"
    printf 'not: [valid\n' > "${NIGHTSHIFT_SUPPRESSIONS_FILE}"

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    grep -Fq 'parse error' <<< "${WARNING_NOTES}" &&
    [[ "${SUPPRESSED_FINDINGS_COUNT}" == "0" ]] &&
    [[ "${FINDINGS_ELIGIBLE_FOR_RANKING}" == "1" ]]
) && pass "5. malformed YAML produces warnings and does not crash suppression application" \
  || fail "5. malformed YAML produces warnings and does not crash suppression application" "malformed YAML handling regressed"

# 6. missing or too-short rationale is rejected at load time
(
    setup_suppression_fixture "short-rationale"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306
  rationale: too short
  added_by: george
  added_date: 2026-04-16
  expires_date: 2026-07-15
  scope: finding
EOF

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    grep -Fq 'rationale must be at least 20 characters' <<< "${WARNING_NOTES}" &&
    [[ "${SUPPRESSED_FINDINGS_COUNT}" == "0" ]]
) && pass "6. rationale validation rejects entries shorter than 20 characters" \
  || fail "6. rationale validation rejects entries shorter than 20 characters" "short rationale was accepted"

# 7. scope=rule suppresses across multiple files
(
    setup_suppression_fixture "rule-scope"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")" \
        "$(finding_block "Feedback auth missing" "security" "CWE-306" "src/api/routers/feedback.py:40-50 anonymous access")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:*:CWE-306
  rationale: The shared front-door control makes this whole rule class accepted risk until the edge policy changes.
  added_by: george
  added_date: 2026-04-16
  expires_date: 2026-07-15
  scope: rule
EOF

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    [[ "${SUPPRESSED_FINDINGS_COUNT}" == "2" ]] &&
    [[ "${FINDINGS_ELIGIBLE_FOR_RANKING}" == "0" ]]
) && pass "7. scope=rule suppresses multiple files sharing detective, category, and rule key" \
  || fail "7. scope=rule suppresses multiple files sharing detective, category, and rule key" "rule-scope suppression did not span files"

# 8. scope=finding suppresses only exact fingerprint match
(
    setup_suppression_fixture "finding-scope"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")" \
        "$(finding_block "Feedback auth missing" "security" "CWE-306" "src/api/routers/feedback.py:40-50 anonymous access")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306
  rationale: EasyAuth only covers the chat route in this accepted-risk scenario, not the feedback route.
  added_by: george
  added_date: 2026-04-16
  expires_date: 2026-07-15
  scope: finding
EOF

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    [[ "${SUPPRESSED_FINDINGS_COUNT}" == "1" ]] &&
    grep -Fq 'Feedback auth missing' "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md"
) && pass "8. scope=finding suppresses only the exact fingerprint match" \
  || fail "8. scope=finding suppresses only the exact fingerprint match" "finding-scope suppression matched too broadly"

# 9. findings without rule key are not suppressible and surface in digest section
(
    setup_suppression_fixture "missing-rule-key"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "" "src/api/routers/chat.py:10-20 anonymous access")"

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    grep -Fq 'missing Rule Key' <<< "${WARNING_NOTES}" &&
    grep -Fq '## Findings Missing Rule Key' "$(nightshift_suppression_section_path "missing-rule-key.md")" &&
    grep -Fq 'Chat auth missing' "$(nightshift_suppression_section_path "missing-rule-key.md")"
) && pass "9. findings missing Rule Key flow through and appear in the dedicated digest section" \
  || fail "9. findings missing Rule Key flow through and appear in the dedicated digest section" "missing-rule-key handling regressed"

# 10. prior digest parse failure defaults runs-since-added to one and warns
(
    setup_suppression_fixture "prior-digest"
    write_findings_file \
        "${NIGHTSHIFT_FINDINGS_DIR}/security-detective-findings.md" \
        "$(finding_block "Chat auth missing" "security" "CWE-306" "src/api/routers/chat.py:10-20 anonymous access")"
    cat > "${NIGHTSHIFT_SUPPRESSIONS_FILE}" <<'EOF'
- fingerprint: security-detective:security:src/api/routers/chat.py:CWE-306
  rationale: EasyAuth blocks this route at the App Service edge so the app-layer check is defense in depth.
  added_by: george
  added_date: 2026-04-16
  expires_date: 2026-07-15
  scope: finding
EOF
    cat > "${NIGHTSHIFT_DIGESTS_DIR}/2026-04-15.md" <<'EOF'
## Suppressed Findings (Audit Only)
not-a-table
EOF

    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    nightshift_apply_suppressions >/dev/null
    grep -Fq 'defaulted runs-since-added to 1' <<< "${WARNING_NOTES}" &&
    grep -Fq '| 1 |' "$(nightshift_suppression_section_path "suppressed-findings.md")"
) && pass "10. prior digest parse failures warn and default runs-since-added to 1" \
  || fail "10. prior digest parse failures warn and default runs-since-added to 1" "prior digest fallback regressed"

echo ""
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

if (( FAIL > 0 )); then
    exit 1
fi

#!/usr/bin/env bash
# test_secrets_hygiene.sh -- Guardrails for Night Shift secret handling docs/scripts.
#
# Usage:
#   bash scripts/nightshift/tests/test_secrets_hygiene.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${NS_DIR}/../.." && pwd)"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }

file_mode() {
    local path="$1"

    if stat -f '%Lp' "${path}" >/dev/null 2>&1; then
        stat -f '%Lp' "${path}"
        return 0
    fi

    stat -c '%a' "${path}"
}

echo "=== test_secrets_hygiene.sh ==="
echo ""

(
    env_file="${HOME}/.nightshift-env"

    if [[ ! -e "${env_file}" ]]; then
        exit 0
    fi

    [[ "$(file_mode "${env_file}")" == "600" ]]
) && pass "1. ~/.nightshift-env is mode 600 or absent" \
  || fail "1. ~/.nightshift-env is mode 600 or absent" "env file exists with insecure permissions"

(
    ! grep -rn --exclude-dir='tests' --exclude-dir='playbooks' 'postgresql://' "${REPO_ROOT}/scripts/nightshift/" "${REPO_ROOT}/docs/nightshift/" "${REPO_ROOT}/docs/tasks/open/night-shift-orchestrator/" >/dev/null
) && pass "2. no inline password URI-style psql examples remain in Night Shift scripts/docs/tasks" \
  || fail "2. no inline password URI-style psql examples remain in Night Shift scripts/docs/tasks" "found an inline password-bearing psql example"

(
    [[ -x "${NS_DIR}/refresh-secrets.sh" ]] &&
    bash -n "${NS_DIR}/refresh-secrets.sh"
) && pass "3. refresh-secrets.sh is executable and bash -n clean" \
  || fail "3. refresh-secrets.sh is executable and bash -n clean" "script missing, not executable, or has syntax errors"

(
    grep -Fq 'export HISTIGNORE="*API_KEY*:*PASSWORD*:*SECRET*"' "${REPO_ROOT}/docs/nightshift/README.md" &&
    grep -Fq 'export HISTIGNORE="*API_KEY*:*PASSWORD*:*SECRET*"' "${REPO_ROOT}/docs/tasks/open/night-shift-orchestrator/00-prerequisites.md" &&
    grep -Fq 'export HISTIGNORE="*API_KEY*:*PASSWORD*:*SECRET*"' "${NS_DIR}/refresh-secrets.sh"
) && pass "4. HISTIGNORE pattern is documented and emitted by refresh-secrets.sh" \
  || fail "4. HISTIGNORE pattern is documented and emitted by refresh-secrets.sh" "pattern missing from docs or refresh script"

(
    source "${NS_DIR}/nightshift.sh"

    tmp_home="$(mktemp -d)"
    trap 'rm -rf "${tmp_home}"' EXIT
    export HOME="${tmp_home}"

    validate_env_file_preflight "${HOME}/.nightshift-env" >/dev/null 2>&1

    printf 'export NIGHTSHIFT_DB_PASSWORD=test\n' > "${HOME}/.nightshift-env"
    chmod 644 "${HOME}/.nightshift-env"
    ! validate_env_file_preflight "${HOME}/.nightshift-env" >/dev/null 2>&1

    chmod 600 "${HOME}/.nightshift-env"
    validate_env_file_preflight "${HOME}/.nightshift-env" >/dev/null 2>&1
) && pass "5. env file preflight allows missing/600 and rejects insecure permissions" \
  || fail "5. env file preflight allows missing/600 and rejects insecure permissions" "preflight helper did not enforce the expected mode checks"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

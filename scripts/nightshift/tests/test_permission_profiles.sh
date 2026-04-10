#!/usr/bin/env bash
# test_permission_profiles.sh — Tests for Nightshift agent permission profiles.
#
# Usage: bash scripts/nightshift/tests/test_permission_profiles.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NS_DIR/../.." && pwd)"
PERMS_DIR="$NS_DIR/permissions"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

profile_has_allowed() {
    local profile_path="$1"
    local tool_name="$2"
    jq -e --arg tool "$tool_name" '.permissions.allowedTools | index($tool) != null' \
        "$profile_path" >/dev/null
}

profile_has_disallowed() {
    local profile_path="$1"
    local tool_name="$2"
    jq -e --arg tool "$tool_name" '.permissions.disallowedTools | index($tool) != null' \
        "$profile_path" >/dev/null
}

profile_lacks_allowed() {
    local profile_path="$1"
    local tool_name="$2"
    ! profile_has_allowed "$profile_path" "$tool_name"
}

source "$NS_DIR/nightshift.conf"
source "$NS_DIR/lib/cost-tracker.sh"
source "$NS_DIR/lib/agent-runner.sh"

readonly_profile="$PERMS_DIR/detective-readonly.json"
db_profile="$PERMS_DIR/detective-db.json"
manager_profile="$PERMS_DIR/manager-write.json"
forbidden="dangerously-skip"
forbidden="${forbidden}-permissions"

echo "=== test_permission_profiles.sh ==="
echo ""

# ── File existence + JSON shape ──────────────────────────────────────────────
(
    [[ -f "$readonly_profile" ]] &&
    [[ -f "$db_profile" ]] &&
    [[ -f "$manager_profile" ]]
) && pass "1. all three permission profile files exist" \
  || fail "1. all three permission profile files exist" "one or more profile files are missing"

(
    jq . "$readonly_profile" >/dev/null &&
    jq . "$db_profile" >/dev/null &&
    jq . "$manager_profile" >/dev/null
) && pass "2. all profile files are valid JSON" \
  || fail "2. all profile files are valid JSON" "jq could not parse one or more profiles"

(
    jq -e '.permissions.allowedTools | type == "array"' "$readonly_profile" >/dev/null &&
    jq -e '.permissions.disallowedTools | type == "array"' "$readonly_profile" >/dev/null &&
    jq -e '.permissions.allowedTools | type == "array"' "$db_profile" >/dev/null &&
    jq -e '.permissions.disallowedTools | type == "array"' "$db_profile" >/dev/null &&
    jq -e '.permissions.allowedTools | type == "array"' "$manager_profile" >/dev/null &&
    jq -e '.permissions.disallowedTools | type == "array"' "$manager_profile" >/dev/null
) && pass "3. each profile exposes allowedTools and disallowedTools arrays" \
  || fail "3. each profile exposes allowedTools and disallowedTools arrays" "missing or invalid permissions arrays"

# ── Detective profile assertions ─────────────────────────────────────────────
(
    profile_lacks_allowed "$readonly_profile" "Write" &&
    profile_lacks_allowed "$readonly_profile" "Edit" &&
    profile_lacks_allowed "$readonly_profile" "Bash(psql:*)"
) && pass "4. detective-readonly omits Write, Edit, and psql" \
  || fail "4. detective-readonly omits Write, Edit, and psql" "readonly profile is too permissive"

(
    profile_has_allowed "$db_profile" "Bash(psql:*)" &&
    profile_lacks_allowed "$db_profile" "Write" &&
    profile_lacks_allowed "$db_profile" "Edit"
) && pass "5. detective-db adds psql without Write or Edit" \
  || fail "5. detective-db adds psql without Write or Edit" "db profile permissions are incorrect"

(
    profile_has_allowed "$readonly_profile" "Bash(python:*)" &&
    profile_has_allowed "$readonly_profile" "Bash(source:*)" &&
    profile_has_allowed "$readonly_profile" "Bash(basename:*)" &&
    profile_has_allowed "$readonly_profile" "Bash(for:*)" &&
    profile_has_allowed "$readonly_profile" "Bash(while:*)" &&
    profile_has_allowed "$readonly_profile" "Bash(echo:*)"
) && pass "6. detective-readonly includes extra playbook commands discovered during exploration" \
  || fail "6. detective-readonly includes extra playbook commands discovered during exploration" "expected widened allowlist entries are missing"

# ── Manager profile assertions ───────────────────────────────────────────────
(
    profile_has_allowed "$manager_profile" "Read" &&
    profile_has_allowed "$manager_profile" "Write" &&
    profile_has_allowed "$manager_profile" "Edit"
) && pass "7. manager-write includes Read, Write, and Edit" \
  || fail "7. manager-write includes Read, Write, and Edit" "manager-write profile is missing a required tool"

(
    profile_lacks_allowed "$manager_profile" "Bash(rm:*)" &&
    profile_lacks_allowed "$manager_profile" "Bash(curl:*)" &&
    profile_lacks_allowed "$manager_profile" "Bash(wget:*)" &&
    profile_lacks_allowed "$manager_profile" "Bash(git push:*)" &&
    profile_lacks_allowed "$manager_profile" "Bash(docker:*)" &&
    profile_lacks_allowed "$manager_profile" "Bash(sudo:*)" &&
    profile_has_disallowed "$manager_profile" "Bash(rm:*)" &&
    profile_has_disallowed "$manager_profile" "Bash(curl:*)" &&
    profile_has_disallowed "$manager_profile" "Bash(wget:*)" &&
    profile_has_disallowed "$manager_profile" "Bash(git push:*)" &&
    profile_has_disallowed "$manager_profile" "Bash(docker:*)" &&
    profile_has_disallowed "$manager_profile" "Bash(sudo:*)"
) && pass "8. manager-write blocks dangerous commands instead of allowing them" \
  || fail "8. manager-write blocks dangerous commands instead of allowing them" "dangerous commands leaked into manager-write allowedTools"

# ── Temporary bypass safety ──────────────────────────────────────────────────
(
    [[ "$(rg -l "$forbidden" "$NS_DIR" | wc -l | tr -d ' ')" == "1" ]] &&
    rg -l "$forbidden" "$NS_DIR" | grep -qx "$NS_DIR/lib/agent-runner.sh" &&
    ! rg -q "$forbidden" "$PERMS_DIR"
) && pass "9. temporary bypass is isolated to agent-runner.sh, not permission JSON" \
  || fail "9. temporary bypass is isolated to agent-runner.sh, not permission JSON" "bypass leaked outside the runner or did not land where expected"

# ── Runner mapping assertions ────────────────────────────────────────────────
(
    [[ "$(_agent_permission_profile commit-detective)" == "$readonly_profile" ]] &&
    [[ "$(_agent_permission_profile coverage-detective)" == "$readonly_profile" ]] &&
    [[ "$(_agent_permission_profile conversation-detective)" == "$db_profile" ]] &&
    [[ "$(_agent_permission_profile error-detective)" == "$db_profile" ]] &&
    [[ "$(_agent_permission_profile product-detective)" == "$db_profile" ]] &&
    [[ "$(_agent_permission_profile rcfa-detective)" == "$db_profile" ]] &&
    [[ "$(_agent_permission_profile security-detective)" == "$readonly_profile" ]] &&
    [[ "$(_agent_permission_profile performance-detective)" == "$db_profile" ]] &&
    [[ "$(_agent_permission_profile manager-merge)" == "$manager_profile" ]] &&
    [[ "$(_agent_permission_profile unknown-playbook)" == "$readonly_profile" ]]
) && pass "10. _agent_permission_profile maps known playbooks and fails closed" \
  || fail "10. _agent_permission_profile maps known playbooks and fails closed" "runner profile mapping is incorrect"

(
    [[ "$(_agent_codex_sandbox commit-detective)" == "read-only" ]] &&
    [[ "$(_agent_codex_sandbox coverage-detective)" == "read-only" ]] &&
    [[ "$(_agent_codex_sandbox conversation-detective)" == "workspace-write" ]] &&
    [[ "$(_agent_codex_sandbox error-detective)" == "workspace-write" ]] &&
    [[ "$(_agent_codex_sandbox product-detective)" == "workspace-write" ]] &&
    [[ "$(_agent_codex_sandbox rcfa-detective)" == "workspace-write" ]] &&
    [[ "$(_agent_codex_sandbox security-detective)" == "read-only" ]] &&
    [[ "$(_agent_codex_sandbox performance-detective)" == "workspace-write" ]] &&
    [[ "$(_agent_codex_sandbox manager-merge)" == "workspace-write" ]] &&
    [[ "$(_agent_codex_sandbox unknown-playbook)" == "read-only" ]]
) && pass "11. Codex sandbox selection matches detective and manager roles" \
  || fail "11. Codex sandbox selection matches detective and manager roles" "Codex sandbox mapping is incorrect"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (11 tests) ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

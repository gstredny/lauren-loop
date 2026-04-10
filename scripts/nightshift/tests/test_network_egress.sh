#!/usr/bin/env bash
# test_network_egress.sh -- Validate Nightshift VM outbound allowlist reachability.
#
# Usage:
#   bash scripts/nightshift/tests/test_network_egress.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${NS_DIR}/../.." && pwd)"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s -- %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m %s -- %s\n' "$1" "$2"; }

source "${NS_DIR}/nightshift.conf"

if [[ -r "${HOME}/.nightshift-env" ]]; then
    # shellcheck disable=SC1090
    source "${HOME}/.nightshift-env"
fi

url_host() {
    local value="${1:-}"
    value="${value#*://}"
    value="${value%%/*}"
    value="${value%%\?*}"
    value="${value%%:*}"
    printf '%s\n' "$value"
}

is_ip_address() {
    local value="$1"
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi
    if [[ "$value" == *:* ]] && [[ "$value" != *.* ]]; then
        return 0
    fi
    return 1
}

resolve_host() {
    local host="$1"
    local pybin=""

    pybin="$(python_for_tcp)" || pybin=""
    if [[ -n "${pybin}" ]]; then
        "$pybin" - "$host" <<'PY'
import socket
import sys

host = sys.argv[1]

try:
    socket.getaddrinfo(host, None)
except socket.gaierror:
    sys.exit(1)
PY
        return $?
    fi

    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1 && return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$host" >/dev/null 2>&1 && return 0
    fi
    if command -v host >/dev/null 2>&1; then
        host "$host" >/dev/null 2>&1 && return 0
    fi
    return 1
}

python_for_tcp() {
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        command -v python
        return 0
    fi
    if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
        printf '%s\n' "${REPO_ROOT}/.venv/bin/python"
        return 0
    fi
    return 1
}

tcp_reachable() {
    local host="$1"
    local port="$2"
    local pybin=""

    pybin="$(python_for_tcp)" || return 2

    "$pybin" - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

try:
    with socket.create_connection((host, port), timeout=5):
        pass
except OSError:
    sys.exit(1)
PY
}

probe_dns() {
    local label="$1"
    local host="$2"

    if [[ -z "$host" ]]; then
        skip "$label" "host is empty"
        return 0
    fi

    if is_ip_address "$host"; then
        skip "$label" "$host is already an IP literal"
        return 0
    fi

    printf 'CHECK %s expects DNS resolution: %s\n' "$label" "$host"
    if resolve_host "$host"; then
        pass "$label resolves ($host)"
    else
        fail "$label" "DNS lookup failed for $host"
    fi
}

probe_https() {
    local label="$1"
    local host="$2"
    local url="https://${host}"

    if [[ -z "$host" ]]; then
        skip "$label" "host is empty"
        return 0
    fi

    printf 'CHECK %s expects HTTPS reachable: %s\n' "$label" "$url"
    if curl -sSI --connect-timeout 5 --max-time 10 -H 'User-Agent: Nightshift-Egress-Test/1.0' "$url" >/dev/null; then
        pass "$label reachable over 443/tcp ($host)"
    else
        fail "$label" "HTTPS probe failed for $url"
    fi
}

probe_tcp() {
    local label="$1"
    local host="$2"
    local port="$3"
    local rc=0

    if [[ -z "$host" ]]; then
        skip "$label" "host is empty"
        return 0
    fi

    printf 'CHECK %s expects TCP reachable: %s:%s\n' "$label" "$host" "$port"
    tcp_reachable "$host" "$port" || rc=$?

    case "$rc" in
        0)
            pass "$label reachable over ${port}/tcp ($host)"
            ;;
        2)
            skip "$label" "no Python interpreter available for TCP probe"
            ;;
        *)
            fail "$label" "TCP probe failed for ${host}:${port}"
            ;;
    esac
}

ufw_is_active() {
    local status=""

    if ! command -v ufw >/dev/null 2>&1; then
        return 1
    fi

    status="$(ufw status 2>/dev/null || true)"
    if printf '%s\n' "$status" | grep -q '^Status: active'; then
        return 0
    fi

    if [[ -r /etc/ufw/ufw.conf ]] && grep -Eq '^ENABLED=yes' /etc/ufw/ufw.conf; then
        return 0
    fi

    return 1
}

probe_blocked_https() {
    local label="$1"
    local host="$2"
    local url="https://${host}"

    if ! ufw_is_active; then
        skip "$label" "ufw is not active; enforcement checks are skipped until firewall rules are applied"
        return 0
    fi

    printf 'CHECK %s expects HTTPS blocked: %s\n' "$label" "$url"
    if curl -sSI --connect-timeout 5 --max-time 10 -H 'User-Agent: Nightshift-Egress-Test/1.0' "$url" >/dev/null; then
        fail "$label" "unexpectedly reached $url while ufw appears active"
    else
        pass "$label blocked as expected ($host)"
    fi
}

ANTHROPIC_HOST="api.anthropic.com"
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    ANTHROPIC_HOST="$(url_host "${ANTHROPIC_BASE_URL}")"
fi

OPENAI_HOST="api.openai.com"
if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
    OPENAI_HOST="$(url_host "${OPENAI_BASE_URL}")"
elif [[ -n "${OPENAI_API_BASE:-}" ]]; then
    OPENAI_HOST="$(url_host "${OPENAI_API_BASE}")"
fi

DB_HOST="${NIGHTSHIFT_DB_HOST:-champioxpertpostgresql.postgres.database.azure.com}"

KEYVAULT_HOST="newchampionxpertkeyvault.vault.azure.net"
if [[ -n "${AZURE_KEY_VAULT_URL:-}" ]]; then
    KEYVAULT_HOST="$(url_host "${AZURE_KEY_VAULT_URL}")"
fi

BLOB_HOST="newchampioxpertstorage.blob.core.windows.net"
if [[ -n "${AZURE_BLOB_ACCOUNT_URL:-}" ]]; then
    BLOB_HOST="$(url_host "${AZURE_BLOB_ACCOUNT_URL}")"
elif [[ -n "${AZURE_STORAGE_ACCOUNT:-}" ]]; then
    BLOB_HOST="${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net"
fi

GIT_REMOTE_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"

echo "=== test_network_egress.sh ==="
echo ""
echo "Runtime core reachability:"
probe_https "Anthropic API" "${ANTHROPIC_HOST}"
probe_https "OpenAI API" "${OPENAI_HOST}"
probe_https "GitHub HTTPS" "github.com"
probe_https "GitHub API" "api.github.com"
probe_tcp "Nightshift PostgreSQL" "${DB_HOST}" "5432"

echo ""
echo "DNS resolution checks:"
probe_dns "Anthropic API" "${ANTHROPIC_HOST}"
probe_dns "OpenAI API" "${OPENAI_HOST}"
probe_dns "GitHub HTTPS" "github.com"
probe_dns "GitHub API" "api.github.com"
probe_dns "Nightshift PostgreSQL" "${DB_HOST}"
probe_dns "GitHub CLI packages" "cli.github.com"
probe_dns "Ubuntu archive mirror" "archive.ubuntu.com"
probe_dns "Ubuntu security mirror" "security.ubuntu.com"
probe_dns "Azure Key Vault" "${KEYVAULT_HOST}"
probe_dns "Azure Blob Storage" "${BLOB_HOST}"

echo ""
echo "Conditional checks:"
case "${GIT_REMOTE_URL}" in
    git@github.com:*|ssh://git@github.com/*)
        probe_tcp "GitHub SSH" "github.com" "22"
        ;;
    *)
        skip "GitHub SSH" "origin remote is not SSH (${GIT_REMOTE_URL:-unset})"
        ;;
esac

probe_blocked_https "Known-bad egress target" "example.com"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ==="
[[ "${FAIL}" -eq 0 ]] && exit 0 || exit 1

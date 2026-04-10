#!/usr/bin/env bash

set -Eeuo pipefail

KEY_VAULT_NAME="${NIGHTSHIFT_KEY_VAULT_NAME:-newchampionxpertkeyvault}"
ENV_FILE="${NIGHTSHIFT_ENV_FILE:-${HOME}/.nightshift-env}"
TMP_FILE=""

log() {
    printf '[%s] [refresh-secrets] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

cleanup() {
    if [[ -n "${TMP_FILE}" && -f "${TMP_FILE}" ]]; then
        rm -f "${TMP_FILE}"
    fi
}

trap cleanup EXIT

require_command() {
    local tool="$1"
    if ! command -v "${tool}" >/dev/null 2>&1; then
        log "ERROR: required command not found: ${tool}"
        exit 1
    fi
}

fetch_secret() {
    local secret_name="$1"
    az keyvault secret show \
        --vault-name "${KEY_VAULT_NAME}" \
        --name "${secret_name}" \
        --query value \
        -o tsv
}

managed_key_pattern() {
    cat <<'EOF'
ANTHROPIC_API_KEY|AZURE_OPENAI_API_KEY|OPENAI_API_KEY|NIGHTSHIFT_DB_PASSWORD|HISTIGNORE
EOF
}

write_base_file() {
    local anthropic_key="$1"
    local codex_key="$2"
    local db_password="$3"
    local include_openai_alias="$4"

    cat >> "${TMP_FILE}" <<EOF
# Night Shift secrets file.
# Refreshed by scripts/nightshift/refresh-secrets.sh from Azure Key Vault.
# Keep CLAUDE_CODE_USE_FOUNDRY unset on the orchestrator VM.
export HISTIGNORE="*API_KEY*:*PASSWORD*:*SECRET*"
export ANTHROPIC_API_KEY="$(printf '%q' "${anthropic_key}")"
export AZURE_OPENAI_API_KEY="$(printf '%q' "${codex_key}")"
export NIGHTSHIFT_DB_PASSWORD="$(printf '%q' "${db_password}")"
EOF

    if [[ "${include_openai_alias}" == "1" ]]; then
        cat >> "${TMP_FILE}" <<EOF
export OPENAI_API_KEY="$(printf '%q' "${codex_key}")"
EOF
    fi
}

main() {
    local anthropic_key=""
    local codex_key=""
    local db_password=""
    local include_openai_alias="0"
    local managed_pattern=""

    require_command az
    require_command chmod
    require_command grep
    require_command mktemp
    require_command mv

    log "Logging into Azure with managed identity"
    az login --identity >/dev/null

    log "Validating Azure session"
    az account show >/dev/null

    log "Validating Key Vault access for ${KEY_VAULT_NAME}"
    az keyvault secret list --vault-name "${KEY_VAULT_NAME}" --query '[].name' -o tsv >/dev/null

    log "Fetching secret Opus45Key"
    anthropic_key="$(fetch_secret "Opus45Key")"
    log "Fetching secret gpt54"
    codex_key="$(fetch_secret "gpt54")"
    log "Fetching secret postgres-password"
    db_password="$(fetch_secret "postgres-password")"

    TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/nightshift-env.XXXXXX")"
    chmod 600 "${TMP_FILE}"

    managed_pattern="$(managed_key_pattern)"
    if [[ -f "${ENV_FILE}" ]]; then
        if grep -Eq '^[[:space:]]*export[[:space:]]+OPENAI_API_KEY=' "${ENV_FILE}"; then
            include_openai_alias="1"
        fi

        grep -Ev "^[[:space:]]*export[[:space:]]+(${managed_pattern})=" "${ENV_FILE}" > "${TMP_FILE}" || true
        if [[ -s "${TMP_FILE}" ]]; then
            printf '\n' >> "${TMP_FILE}"
        fi
    fi

    write_base_file "${anthropic_key}" "${codex_key}" "${db_password}" "${include_openai_alias}"

    mv "${TMP_FILE}" "${ENV_FILE}"
    TMP_FILE=""
    chmod 600 "${ENV_FILE}"

    log "Refreshed ANTHROPIC_API_KEY from Opus45Key"
    log "Refreshed AZURE_OPENAI_API_KEY from gpt54"
    if [[ "${include_openai_alias}" == "1" ]]; then
        log "Refreshed OPENAI_API_KEY compatibility alias from gpt54"
    fi
    log "Refreshed NIGHTSHIFT_DB_PASSWORD from postgres-password"
    log "Updated ${ENV_FILE} with mode 600"
}

main "$@"

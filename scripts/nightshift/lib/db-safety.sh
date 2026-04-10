#!/usr/bin/env bash
# db-safety.sh — Database safety guardrails for Nightshift detective runs.
# Sourced by the orchestrator. Requires nightshift.conf to be sourced first.
# Validates that the DB connection uses a readonly role before any detective
# touches the database. All logging goes to stderr.

# Fail closed if sourced from the wrong shell.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '[%s] [nightshift-db-safety] CRITICAL: Bash is required\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
    return 1 2>/dev/null || exit 1
fi

# Guard against double-sourcing
[[ -n "${_NIGHTSHIFT_DB_SAFETY_LOADED:-}" ]] && return 0
_NIGHTSHIFT_DB_SAFETY_LOADED=1

# ── Internal Helpers ──────────────────────────────────────────────────────────

_db_log() {
    printf '[%s] [nightshift-db-safety] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

_db_conninfo() {
    printf 'host=%s port=5432 dbname=%s user=%s sslmode=%s connect_timeout=%s' \
        "${NIGHTSHIFT_DB_HOST}" \
        "${NIGHTSHIFT_DB_NAME}" \
        "${NIGHTSHIFT_DB_USER}" \
        "${NIGHTSHIFT_DB_SSLMODE}" \
        "${NIGHTSHIFT_DB_CONNECT_TIMEOUT:-10}"
}

_db_run_psql() {
    local conninfo=""
    conninfo="$(_db_conninfo)"

    PGPASSWORD="${NIGHTSHIFT_DB_PASSWORD}" psql "${conninfo}" "$@"
}

# ── Public Functions ──────────────────────────────────────────────────────────

# Build the base psql command string using env vars.
# Uses a libpq conninfo string instead of a URI so the password stays in env vars
# and the timeout syntax works on the orchestrator VM's psql build.
# Prints the command to stdout — callers capture with $().
db_build_psql_cmd() {
    local password_q conninfo_q conninfo
    printf -v password_q '%q' "${NIGHTSHIFT_DB_PASSWORD}"
    conninfo="$(_db_conninfo)"
    printf -v conninfo_q '%q' "${conninfo}"

    _db_log "Building base psql command"
    printf 'PGPASSWORD=%s psql %s\n' "$password_q" "$conninfo_q"
}

# Validate that all required DB env vars are set and the user is NOT the admin.
# Returns: 0 = safe, 1 = unsafe or misconfigured.
db_validate_connection() {
    local missing=0

    _db_log "Validating database connection environment"

    if [[ -z "${NIGHTSHIFT_DB_USER:-}" ]]; then
        _db_log "CRITICAL: NIGHTSHIFT_DB_USER is not set"
        missing=1
    fi
    if [[ -z "${NIGHTSHIFT_DB_PASSWORD:-}" ]]; then
        _db_log "CRITICAL: NIGHTSHIFT_DB_PASSWORD is not set"
        missing=1
    fi
    if [[ -z "${NIGHTSHIFT_DB_HOST:-}" ]]; then
        _db_log "CRITICAL: NIGHTSHIFT_DB_HOST is not set"
        missing=1
    fi
    if [[ -z "${NIGHTSHIFT_DB_NAME:-}" ]]; then
        _db_log "CRITICAL: NIGHTSHIFT_DB_NAME is not set"
        missing=1
    fi

    if [[ "$missing" -eq 1 ]]; then
        _db_log "CRITICAL: One or more NIGHTSHIFT_DB_* env vars are missing — aborting"
        return 1
    fi

    # Reject the admin user
    if [[ "$NIGHTSHIFT_DB_USER" == "${NIGHTSHIFT_DB_ADMIN_USER:-gstredny}" ]]; then
        _db_log "CRITICAL: NIGHTSHIFT_DB_USER is set to admin user '${NIGHTSHIFT_DB_USER}' — Nightshift must use a readonly role"
        return 1
    fi

    _db_log "OK: Connection validated — user='${NIGHTSHIFT_DB_USER}', host='${NIGHTSHIFT_DB_HOST}', db='${NIGHTSHIFT_DB_NAME}'"
    return 0
}

# Verify the configured role is truly readonly by attempting a write.
# Attempts CREATE TABLE — this MUST fail. If it succeeds, something is
# catastrophically wrong: clean up and return failure.
# Returns: 0 = readonly confirmed, 1 = write succeeded (unsafe).
db_verify_readonly() {
    _db_log "Verifying readonly: attempting CREATE TABLE _nightshift_safety_test..."

    # Attempt a write — this MUST fail
    local create_output create_exit
    create_output=$(_db_run_psql -c "CREATE TABLE _nightshift_safety_test (id int);" 2>&1)
    create_exit=$?

    if [[ "$create_exit" -eq 0 ]]; then
        # Catastrophic: write succeeded — the role is NOT readonly
        _db_log "CRITICAL: CREATE TABLE succeeded — role '${NIGHTSHIFT_DB_USER}' has write access!"

        # Attempt cleanup
        local drop_output drop_exit
        drop_output=$(_db_run_psql -c "DROP TABLE IF EXISTS _nightshift_safety_test;" 2>&1)
        drop_exit=$?

        if [[ "$drop_exit" -ne 0 ]]; then
            _db_log "CRITICAL: Cleanup failed after unsafe CREATE success"
            _db_log "CRITICAL: Phantom table '_nightshift_safety_test' may still exist. DROP output: ${drop_output}"
        else
            _db_log "Cleanup: _nightshift_safety_test table dropped"
        fi

        return 1
    fi

    _db_log "OK: CREATE TABLE failed as expected (exit=$create_exit) — readonly confirmed"
    return 0
}

# Test basic connectivity by running SELECT 1.
# Returns: 0 = connected, 1 = cannot connect.
db_test_connectivity() {
    _db_log "Testing connectivity: SELECT 1..."

    local output exit_code
    output=$(_db_run_psql -c "SELECT 1;" 2>&1)
    exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        _db_log "CRITICAL: Cannot connect to database — psql exit=$exit_code output: ${output}"
        return 1
    fi

    _db_log "OK: Database connectivity confirmed"
    return 0
}

# Single entry point: validate → verify_readonly → test_connectivity.
# Fails fast on first failure. The orchestrator calls only this function.
# Returns: 0 = all checks passed, 1 = any check failed.
db_safety_preflight() {
    _db_log "Starting database safety preflight..."

    if ! db_validate_connection; then
        _db_log "ABORT: Connection validation failed"
        return 1
    fi

    if ! db_verify_readonly; then
        _db_log "ABORT: Readonly verification failed"
        return 1
    fi

    if ! db_test_connectivity; then
        _db_log "ABORT: Connectivity test failed"
        return 1
    fi

    _db_log "OK: All database safety checks passed"
    return 0
}

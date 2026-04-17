#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${HOME}/.nightshift-env"
LOCK_FILE="/tmp/nightshift.lock"

DRY_RUN=0
SMOKE_MODE=0
FORCE_DIRECT=0
NIGHTSHIFT_SMOKE="false"
PHASE_ONLY=""

RUN_DATE="$(date +%Y-%m-%d)"
RUN_CLOCK="$(date +%H%M%S)"
RUN_SUFFIX=""
RUN_ID=""
RUN_TMP_DIR=""
RAW_FINDINGS_DIR=""
AGENT_OUTPUT_DIR=""
DETECTIVE_STATUS_DIR=""
LOG_FILE=""
LOG_PIPE=""
LOGGER_PID=0

CURRENT_PHASE="bootstrap"

LOCK_ACQUIRED=0
LOCK_PID=""
ERR_TRAP_ACTIVE=0
EXIT_TRAP_ACTIVE=0

COST_TRACKING_READY=0
SETUP_READY=0
BRANCH_READY=0
DB_PLAYBOOKS_ENABLED=1
CLAUDE_AVAILABLE=1
MANAGER_ALLOWED=0
PUSH_ALLOWED=0
PR_ALLOWED=0
GH_AVAILABLE=0

RUN_FAILED=0
RUN_COST_CAP=0
SETUP_FAILED=0
RUN_CLEAN=0

RUN_BRANCH=""
ORIGINAL_REF=""

TOTAL_FINDINGS_AVAILABLE=0
FINDINGS_ELIGIBLE_FOR_RANKING=0
SUPPRESSED_FINDINGS_COUNT=0
TASK_FILE_COUNT=0
DIGEST_AVAILABLE=0
DIGEST_STAGEABLE=0
DIGEST_PATH=""
DIGEST_TASK_COUNT_PATCHED=0
MANAGER_CONTRACT_FAILED=0
PR_URL=""
BRIDGE_STAGE_PATHS=()
BRIDGE_SKIPPED=0
BACKLOG_STAGE_PATHS=()
BACKLOG_RESULTS=()
BACKLOG_LAST_OUTCOME=""
AUTOFIX_ATTEMPTED_COUNT=0
CREATED_TASKS=()
NIGHTSHIFT_FINDING_TEXT=""
VALIDATED_TASKS=()
VALIDATION_TOTAL_COUNT=0
VALIDATION_VALID_COUNT=0
VALIDATION_INVALID_COUNT=0

CODEX_MODE="disabled"
CODEX_ATTEMPT_COUNT=0

FAILURE_NOTES=""
WARNING_NOTES=""

# Protected tunables — conf-authoritative values that env files cannot override.
# Note: NIGHTSHIFT_BRIDGE_ENABLED, NIGHTSHIFT_AUTOFIX_ENABLED, and
# NIGHTSHIFT_BACKLOG_ENABLED are intentionally NOT protected — those are
# deployment-specific toggles where ~/.nightshift-env is the override mechanism.
NIGHTSHIFT_PROTECTED_TUNABLES=(
    "NIGHTSHIFT_COST_CAP_USD"
    "NIGHTSHIFT_PER_CALL_CAP_USD"
    "NIGHTSHIFT_RUNAWAY_THRESHOLD_USD"
    "NIGHTSHIFT_RUNAWAY_CONSECUTIVE"
    "NIGHTSHIFT_PROTECTED_BRANCHES"
    "NIGHTSHIFT_MAX_PR_FILES"
    "NIGHTSHIFT_MAX_PR_LINES"
    "NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS"
    "NIGHTSHIFT_MIN_FREE_MB"
)

NIGHTSHIFT_DETECTIVE_PLAYBOOKS=(
    "commit-detective"
    "conversation-detective"
    "coverage-detective"
    "error-detective"
    "product-detective"
    "rcfa-detective"
    "security-detective"
    "performance-detective"
)

NIGHTSHIFT_DETECTIVE_ENGINES=(
    "claude"
    "codex"
)

NIGHTSHIFT_MANAGER_TASK_FILES_HEADING="## Ranked Findings"
NIGHTSHIFT_MANAGER_MINOR_FINDINGS_HEADING="## Minor & Observation Findings"
NIGHTSHIFT_MANAGER_RUN_METADATA_HEADING="## Run Metadata"
NIGHTSHIFT_MANAGER_SUMMARY_HEADING="## Summary"
NIGHTSHIFT_MANAGER_DETECTIVE_COVERAGE_HEADING="## Detective Coverage"
NIGHTSHIFT_MANAGER_DETECTIVES_NOT_RUN_HEADING="## Detectives Not Run"
NIGHTSHIFT_MANAGER_DETECTIVES_SKIPPED_HEADING="## Detectives Skipped"
NIGHTSHIFT_MANAGER_ORCHESTRATOR_SUMMARY_HEADING="## Orchestrator Summary"
NIGHTSHIFT_MANAGER_ORCHESTRATOR_WARNINGS_HEADING="## Orchestrator Warnings"
NIGHTSHIFT_MANAGER_ORCHESTRATOR_FAILURES_HEADING="## Orchestrator Failures"

NIGHTSHIFT_MANAGER_REQUIRED_BODY_HEADINGS=(
    "${NIGHTSHIFT_MANAGER_TASK_FILES_HEADING}"
    "${NIGHTSHIFT_MANAGER_MINOR_FINDINGS_HEADING}"
)

NIGHTSHIFT_MANAGER_SHELL_OWNED_HEADINGS=(
    "${NIGHTSHIFT_MANAGER_RUN_METADATA_HEADING}"
    "${NIGHTSHIFT_MANAGER_SUMMARY_HEADING}"
    "${NIGHTSHIFT_MANAGER_DETECTIVE_COVERAGE_HEADING}"
    "${NIGHTSHIFT_MANAGER_DETECTIVES_NOT_RUN_HEADING}"
    "${NIGHTSHIFT_MANAGER_DETECTIVES_SKIPPED_HEADING}"
    "${NIGHTSHIFT_MANAGER_ORCHESTRATOR_SUMMARY_HEADING}"
    "${NIGHTSHIFT_MANAGER_ORCHESTRATOR_WARNINGS_HEADING}"
    "${NIGHTSHIFT_MANAGER_ORCHESTRATOR_FAILURES_HEADING}"
)

ns_log() {
    printf '[%s] [nightshift] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

ns_err_log() {
    printf '[%s] [nightshift] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

backlog_log() {
    printf '[%s] [nightshift-backlog] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

record_failure_note() {
    local message="$1"
    RUN_FAILED=1
    if [[ -z "$FAILURE_NOTES" ]]; then
        FAILURE_NOTES="$message"
    else
        FAILURE_NOTES="${FAILURE_NOTES}"$'\n'"$message"
    fi
}

append_failure() {
    local message="$1"
    record_failure_note "$message"
    ns_log "ERROR: $message"
}

append_warning() {
    local message="$1"
    if [[ -z "$WARNING_NOTES" ]]; then
        WARNING_NOTES="$message"
    else
        WARNING_NOTES="${WARNING_NOTES}"$'\n'"$message"
    fi
    ns_log "WARN: $message"
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

bootstrap_status_value() {
    trim_whitespace "${NIGHTSHIFT_BOOTSTRAP_STATUS:-}"
}

bootstrap_warning_value() {
    trim_whitespace "${NIGHTSHIFT_BOOTSTRAP_WARNING:-}"
}

enforce_live_bootstrap_entrypoint() {
    local bootstrap_status=""
    bootstrap_status="$(bootstrap_status_value)"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        return 0
    fi
    if [[ "${FORCE_DIRECT}" -eq 1 ]]; then
        return 0
    fi
    if [[ -n "${bootstrap_status}" ]]; then
        return 0
    fi

    ns_err_log "ERROR: Direct live runs must use scripts/nightshift/nightshift-bootstrap.sh or pass --force-direct"
    return 1
}

record_bootstrap_runtime_warnings() {
    local bootstrap_status=""
    local bootstrap_warning=""

    bootstrap_status="$(bootstrap_status_value)"
    bootstrap_warning="$(bootstrap_warning_value)"

    if [[ -n "${bootstrap_warning}" ]]; then
        append_warning "${bootstrap_warning}"
    fi

    if [[ "${DRY_RUN}" -ne 1 && -z "${bootstrap_status}" && "${FORCE_DIRECT}" -eq 1 ]]; then
        append_warning "Nightshift started without nightshift-bootstrap.sh freshness bootstrap because --force-direct was used; using the current checkout as-is"
    fi
}

phase_start() {
    local phase_id="$1"
    local phase_name="$2"
    CURRENT_PHASE="${phase_id}"
    ns_log "===== Phase ${phase_id}: ${phase_name} START ====="
}

phase_end() {
    local phase_id="$1"
    local phase_name="$2"
    local outcome="$3"
    ns_log "===== Phase ${phase_id}: ${phase_name} ${outcome} ====="
}

usage() {
    cat <<'EOF'
Usage: bash scripts/nightshift/nightshift.sh [--smoke] [--dry-run] [--force-direct] [--phase N]

Options:
  --smoke     Run a real minimal end-to-end smoke pass: commit detective only, skip autofix/bridge/backlog.
  --dry-run   Skip agent, git push, and PR creation. Produces an empty digest and exits 0.
  --force-direct  Allow a live direct run without nightshift-bootstrap.sh. Uses the current checkout as-is.
  --phase N   Marker-only flag in Task 03C. Logs phase-only mode and continues normally.
  --help      Show this help message.

Exit codes:
  0  Success (artifacts shipped, clean run, or dry-run)
  1  One or more errors occurred
  2  Cost cap or runaway detection halted the run
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --smoke)
                SMOKE_MODE=1
                NIGHTSHIFT_SMOKE="true"
                export NIGHTSHIFT_SMOKE
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force-direct)
                FORCE_DIRECT=1
                shift
                ;;
            --phase)
                if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]]; then
                    usage >&2
                    exit 1
                fi
                PHASE_ONLY="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 1
                ;;
        esac
    done
}

smoke_mode_enabled() {
    [[ "${SMOKE_MODE:-0}" -eq 1 || "${NIGHTSHIFT_SMOKE:-false}" == "true" ]]
}

cleanup_lock() {
    if [[ "${LOCK_ACQUIRED}" -eq 1 && -f "${LOCK_FILE}" ]]; then
        local lock_pid=""
        lock_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
        if [[ -z "${lock_pid}" || "${lock_pid}" == "${LOCK_PID}" || "${lock_pid}" == "$$" ]]; then
            rm -f "${LOCK_FILE}"
            ns_log "Lockfile cleaned up: ${LOCK_FILE}"
        fi
    fi
    LOCK_ACQUIRED=0
}

cleanup_logger() {
    if [[ -n "${LOG_PIPE}" && -p "${LOG_PIPE}" ]]; then
        rm -f "${LOG_PIPE}"
    fi

    if [[ "${LOGGER_PID}" -gt 0 ]]; then
        LOGGER_PID=0
    fi
}

on_err() {
    local line_no="$1"
    local status="$2"
    if [[ "${ERR_TRAP_ACTIVE}" -eq 1 ]]; then
        return 0
    fi
    ERR_TRAP_ACTIVE=1
    ns_err_log "ERR trap: phase=${CURRENT_PHASE} line=${line_no} status=${status}"
    cleanup_lock
    ERR_TRAP_ACTIVE=0
    return 0
}

on_exit() {
    local status="$1"
    if [[ "${EXIT_TRAP_ACTIVE}" -eq 1 ]]; then
        return 0
    fi
    EXIT_TRAP_ACTIVE=1
    if [[ "${status}" -ne 0 ]]; then
        ns_err_log "Exit trap: phase=${CURRENT_PHASE} status=${status}"
    fi
    cleanup_lock
    cleanup_logger
    git checkout main 2>/dev/null || true
    EXIT_TRAP_ACTIVE=0
    return 0
}

on_signal() {
    local signal_name="$1"
    record_failure_note "Received ${signal_name} during ${CURRENT_PHASE}"
    ns_err_log "ERROR: Received ${signal_name} during ${CURRENT_PHASE}"
    cleanup_lock
    exit 1
}

acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local existing_pid=""
        existing_pid="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
        if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
            append_failure "Another Nightshift run is already active (pid ${existing_pid})"
            exit 1
        fi
        ns_log "Removing stale lockfile: ${LOCK_FILE}"
        rm -f "${LOCK_FILE}"
    fi

    printf '%s\n' "$$" > "${LOCK_FILE}"
    LOCK_ACQUIRED=1
    LOCK_PID="$$"
    ns_log "Lockfile created: ${LOCK_FILE}"
}

source_if_present() {
    local path="$1"
    if [[ -r "${path}" ]]; then
        # shellcheck disable=SC1090
        source "${path}"
        ns_log "Sourced: ${path}"
    else
        ns_log "Optional file not found: ${path}"
    fi
}

source_required() {
    local path="$1"
    if [[ ! -r "${path}" ]]; then
        append_failure "Required file missing or unreadable: ${path}"
        return 1
    fi
    # shellcheck disable=SC1090
    source "${path}"
    ns_log "Sourced: ${path}"
    return 0
}

ensure_task_context_helpers() {
    declare -F task_context_existing_open_tasks_block >/dev/null 2>&1 && return 0
    source_required "${SCRIPT_DIR}/lib/task-context.sh"
}

snapshot_protected_tunables() {
    local prefix="$1"
    local name=""
    for name in "${NIGHTSHIFT_PROTECTED_TUNABLES[@]}"; do
        if [[ -n "${!name+x}" ]]; then
            printf -v "${prefix}_${name}_IS_SET" '%s' "1"
            printf -v "${prefix}_${name}_VALUE" '%s' "${!name}"
        else
            printf -v "${prefix}_${name}_IS_SET" '%s' "0"
            printf -v "${prefix}_${name}_VALUE" '%s' ""
        fi
    done
}

log_ignored_environment_overrides() {
    local prefix="$1"
    local name=""
    local is_set_var=""
    local value_var=""
    local attempted_is_set=""
    local attempted_value=""
    for name in "${NIGHTSHIFT_PROTECTED_TUNABLES[@]}"; do
        is_set_var="${prefix}_${name}_IS_SET"
        value_var="${prefix}_${name}_VALUE"
        attempted_is_set="${!is_set_var:-0}"
        attempted_value="${!value_var-}"

        if [[ "${attempted_is_set}" == "1" && "${attempted_value}" != "${!name-}" ]]; then
            ns_log "Ignored override of ${name} from environment"
        fi
    done
}

restore_protected_tunables() {
    local prefix="$1"
    local source_label="$2"
    local name=""
    local is_set_var=""
    local value_var=""
    local snapshot_is_set=""
    local snapshot_value=""
    local current_is_set=""
    local current_value=""

    for name in "${NIGHTSHIFT_PROTECTED_TUNABLES[@]}"; do
        is_set_var="${prefix}_${name}_IS_SET"
        value_var="${prefix}_${name}_VALUE"
        snapshot_is_set="${!is_set_var:-0}"
        snapshot_value="${!value_var-}"

        current_is_set="0"
        current_value=""
        if [[ -n "${!name+x}" ]]; then
            current_is_set="1"
            current_value="${!name}"
        fi

        if [[ "${current_is_set}" != "${snapshot_is_set}" || "${current_value}" != "${snapshot_value}" ]]; then
            ns_log "Ignored override of ${name} from ${source_label}"
        fi

        if [[ "${snapshot_is_set}" == "1" ]]; then
            printf -v "${name}" '%s' "${snapshot_value}"
        else
            unset "${name}"
        fi
    done
}

validate_decimal_gt_le() {
    local name="$1"
    local value="$2"
    local lower="$3"
    local upper="$4"
    local range_label="$5"

    if ! awk -v value="${value}" -v lower="${lower}" -v upper="${upper}" '
        BEGIN {
            if (value !~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/) {
                exit 1
            }
            if (value <= lower || value > upper) {
                exit 1
            }
        }
    '; then
        append_failure "Invalid ${name}: value='${value}' allowed range ${range_label}"
        return 1
    fi

    return 0
}

validate_integer_gt_le() {
    local name="$1"
    local value="$2"
    local lower="$3"
    local upper="$4"
    local range_label="$5"

    if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value <= lower || value > upper )); then
        append_failure "Invalid ${name}: value='${value}' allowed range ${range_label}"
        return 1
    fi

    return 0
}

validate_integer_ge_le() {
    local name="$1"
    local value="$2"
    local lower="$3"
    local upper="$4"
    local range_label="$5"

    if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value < lower || value > upper )); then
        append_failure "Invalid ${name}: value='${value}' allowed range ${range_label}"
        return 1
    fi

    return 0
}

normalize_boolean_value() {
    local raw_value="${1:-}"
    raw_value="$(printf '%s' "${raw_value}" | tr '[:upper:]' '[:lower:]')"
    case "${raw_value}" in
        true|1|yes)
            printf 'true'
            return 0
            ;;
        false|0|no|"")
            printf 'false'
            return 0
            ;;
    esac
    return 1
}

validate_boolean_setting() {
    local name="$1"
    local value="$2"
    local normalized=""

    if ! normalized="$(normalize_boolean_value "${value}")"; then
        append_failure "Invalid ${name}: value='${value}' expected true/false, 1/0, or yes/no"
        return 1
    fi

    printf -v "${name}" '%s' "${normalized}"
    return 0
}

validate_bridge_severity_setting() {
    local name="$1"
    local value
    value="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"

    case "${value}" in
        critical|major|minor|observation)
            printf -v "${name}" '%s' "${value}"
            return 0
            ;;
    esac

    append_failure "Invalid ${name}: value='${2}' allowed values critical|major|minor|observation"
    return 1
}

validate_severity_csv_setting() {
    local name="$1"
    local raw_value="${2:-}"
    local part=""
    local normalized=""
    local -a parts=()

    IFS=',' read -r -a parts <<< "${raw_value}"
    if (( ${#parts[@]} == 0 )); then
        append_failure "Invalid ${name}: value='${raw_value}' expected a comma-separated severity list"
        return 1
    fi

    for part in "${parts[@]}"; do
        part="$(trim_whitespace "${part}")"
        part="$(printf '%s' "${part}" | tr '[:upper:]' '[:lower:]')"
        case "${part}" in
            critical|major|minor|observation)
                ;;
            *)
                append_failure "Invalid ${name}: value='${raw_value}' allowed values critical|major|minor|observation"
                return 1
                ;;
        esac

        if [[ -n "${normalized}" ]]; then
            normalized="${normalized},"
        fi
        normalized="${normalized}${part}"
    done

    if [[ -z "${normalized}" ]]; then
        append_failure "Invalid ${name}: value='${raw_value}' expected a comma-separated severity list"
        return 1
    fi

    printf -v "${name}" '%s' "${normalized}"
    return 0
}

setting_is_set() {
    local name="$1"
    [[ "${!name+x}" == "x" ]]
}

resolve_setting_with_legacy_fallback() {
    local primary_name="$1"
    local legacy_name="$2"
    local hard_default="$3"
    local primary_value=""
    local legacy_value=""

    if setting_is_set "${primary_name}"; then
        primary_value="${!primary_name}"
        if [[ -n "${primary_value}" ]]; then
            printf '%s' "${primary_value}"
            return 0
        fi
    fi

    if setting_is_set "${legacy_name}"; then
        legacy_value="${!legacy_name}"
        if [[ -n "${legacy_value}" ]]; then
            printf '%s' "${legacy_value}"
            return 0
        fi
    fi

    printf '%s' "${hard_default}"
}

resolve_legacy_or_default_setting() {
    local legacy_name="$1"
    local hard_default="$2"
    local legacy_value=""

    if setting_is_set "${legacy_name}"; then
        legacy_value="${!legacy_name}"
        if [[ -n "${legacy_value}" ]]; then
            printf '%s' "${legacy_value}"
            return 0
        fi
    fi

    printf '%s' "${hard_default}"
}

set_setting_from_legacy_or_default() {
    local target_name="$1"
    local legacy_name="$2"
    local hard_default="$3"
    local value=""

    value="$(resolve_legacy_or_default_setting "${legacy_name}" "${hard_default}")"
    printf -v "${target_name}" '%s' "${value}"
}

setting_defined_in_file() {
    local file_path="$1"
    local setting_name="$2"

    [[ -f "${file_path}" ]] || return 1
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?${setting_name}=" "${file_path}"
}

normalize_loaded_task_writer_configuration() {
    local env_path="$1"
    local max_tasks_preexisting="${2:-0}"
    local min_severity_preexisting="${3:-0}"
    local min_budget_preexisting="${4:-0}"

    if [[ "${max_tasks_preexisting}" -eq 0 ]] \
        && { ! setting_defined_in_file "${env_path}" "NIGHTSHIFT_TASK_WRITER_MAX_TASKS" \
            || [[ -z "${NIGHTSHIFT_TASK_WRITER_MAX_TASKS:-}" ]]; }; then
        set_setting_from_legacy_or_default \
            "NIGHTSHIFT_TASK_WRITER_MAX_TASKS" \
            "NIGHTSHIFT_AUTOFIX_MAX_TASKS" \
            "5"
    fi

    if [[ "${min_severity_preexisting}" -eq 0 ]] \
        && { ! setting_defined_in_file "${env_path}" "NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY" \
            || [[ -z "${NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY:-}" ]]; }; then
        set_setting_from_legacy_or_default \
            "NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY" \
            "NIGHTSHIFT_AUTOFIX_SEVERITY" \
            "critical,major"
    fi

    if [[ "${min_budget_preexisting}" -eq 0 ]] \
        && { ! setting_defined_in_file "${env_path}" "NIGHTSHIFT_TASK_WRITER_MIN_BUDGET" \
            || [[ -z "${NIGHTSHIFT_TASK_WRITER_MIN_BUDGET:-}" ]]; }; then
        set_setting_from_legacy_or_default \
            "NIGHTSHIFT_TASK_WRITER_MIN_BUDGET" \
            "NIGHTSHIFT_AUTOFIX_MIN_BUDGET" \
            "20"
    fi
}

validate_nightshift_configuration() {
    validate_decimal_gt_le \
        "NIGHTSHIFT_COST_CAP_USD" "${NIGHTSHIFT_COST_CAP_USD}" "0" "500" "(> 0 and <= 500)" || return 1
    validate_decimal_gt_le \
        "NIGHTSHIFT_PER_CALL_CAP_USD" "${NIGHTSHIFT_PER_CALL_CAP_USD}" "0" "100" "(> 0 and <= 100)" || return 1
    validate_integer_ge_le \
        "NIGHTSHIFT_RUNAWAY_CONSECUTIVE" "${NIGHTSHIFT_RUNAWAY_CONSECUTIVE}" "2" "10" "(>= 2 and <= 10)" || return 1
    validate_integer_gt_le \
        "NIGHTSHIFT_AGENT_TIMEOUT_SECONDS" "${NIGHTSHIFT_AGENT_TIMEOUT_SECONDS}" "0" "7200" "(> 0 and <= 7200)" || return 1
    validate_integer_gt_le \
        "NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS" "${NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS}" "0" "86400" "(> 0 and <= 86400)" || return 1
    validate_integer_gt_le \
        "NIGHTSHIFT_MIN_FREE_MB" "${NIGHTSHIFT_MIN_FREE_MB}" "0" "102400" "(> 0 and <= 102400)" || return 1
    validate_boolean_setting \
        "NIGHTSHIFT_BRIDGE_ENABLED" "${NIGHTSHIFT_BRIDGE_ENABLED:-false}" || return 1
    validate_boolean_setting \
        "NIGHTSHIFT_BRIDGE_AUTO_EXECUTE" "${NIGHTSHIFT_BRIDGE_AUTO_EXECUTE:-false}" || return 1
    validate_bridge_severity_setting \
        "NIGHTSHIFT_BRIDGE_MIN_SEVERITY" "${NIGHTSHIFT_BRIDGE_MIN_SEVERITY:-major}" || return 1
    validate_integer_gt_le \
        "NIGHTSHIFT_BRIDGE_MAX_TASKS" "${NIGHTSHIFT_BRIDGE_MAX_TASKS:-3}" "0" "15" "(> 0 and <= 15)" || return 1
    validate_decimal_gt_le \
        "NIGHTSHIFT_BRIDGE_MAX_COST_PER_TASK" "${NIGHTSHIFT_BRIDGE_MAX_COST_PER_TASK:-25}" "0" "100" "(> 0 and <= 100)" || return 1
    validate_boolean_setting \
        "NIGHTSHIFT_BACKLOG_ENABLED" "${NIGHTSHIFT_BACKLOG_ENABLED:-true}" || return 1
    validate_integer_gt_le \
        "NIGHTSHIFT_BACKLOG_MAX_TASKS" "${NIGHTSHIFT_BACKLOG_MAX_TASKS:-3}" "0" "15" "(> 0 and <= 15)" || return 1
    validate_decimal_gt_le \
        "NIGHTSHIFT_BACKLOG_MIN_BUDGET" "${NIGHTSHIFT_BACKLOG_MIN_BUDGET:-20}" "0" "500" "(> 0 and <= 500)" || return 1
    validate_integer_ge_le \
        "NIGHTSHIFT_MIN_TASKS_PER_RUN" "${NIGHTSHIFT_MIN_TASKS_PER_RUN:-3}" "0" "15" "(>= 0 and <= 15)" || return 1
    validate_boolean_setting \
        "NIGHTSHIFT_AUTOFIX_ENABLED" "${NIGHTSHIFT_AUTOFIX_ENABLED:-false}" || return 1
    validate_integer_gt_le \
        "NIGHTSHIFT_AUTOFIX_MAX_TASKS" "${NIGHTSHIFT_AUTOFIX_MAX_TASKS:-10}" "0" "15" "(> 0 and <= 15)" || return 1
    validate_decimal_gt_le \
        "NIGHTSHIFT_AUTOFIX_MIN_BUDGET" "${NIGHTSHIFT_AUTOFIX_MIN_BUDGET:-20}" "0" "500" "(> 0 and <= 500)" || return 1
    validate_severity_csv_setting \
        "NIGHTSHIFT_AUTOFIX_SEVERITY" "${NIGHTSHIFT_AUTOFIX_SEVERITY:-critical,major}" || return 1
    validate_integer_gt_le \
        "NIGHTSHIFT_TASK_WRITER_MAX_TASKS" "${NIGHTSHIFT_TASK_WRITER_MAX_TASKS:-5}" "0" "15" "(> 0 and <= 15)" || return 1
    validate_decimal_gt_le \
        "NIGHTSHIFT_TASK_WRITER_MIN_BUDGET" "${NIGHTSHIFT_TASK_WRITER_MIN_BUDGET:-20}" "0" "500" "(> 0 and <= 500)" || return 1
    validate_severity_csv_setting \
        "NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY" "${NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY:-critical,major}" || return 1
}

load_nightshift_configuration() {
    local conf_path="${1:-${SCRIPT_DIR}/nightshift.conf}"
    local env_path="${2:-${ENV_FILE}}"
    local task_writer_max_tasks_preexisting=0
    local task_writer_min_severity_preexisting=0
    local task_writer_min_budget_preexisting=0

    if [[ -n "${NIGHTSHIFT_TASK_WRITER_MAX_TASKS:-}" ]]; then
        task_writer_max_tasks_preexisting=1
    fi
    if [[ -n "${NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY:-}" ]]; then
        task_writer_min_severity_preexisting=1
    fi
    if [[ -n "${NIGHTSHIFT_TASK_WRITER_MIN_BUDGET:-}" ]]; then
        task_writer_min_budget_preexisting=1
    fi

    snapshot_protected_tunables "__NIGHTSHIFT_ENV_ATTEMPT"

    if ! source_required "${conf_path}"; then
        return 1
    fi

    log_ignored_environment_overrides "__NIGHTSHIFT_ENV_ATTEMPT"
    snapshot_protected_tunables "__NIGHTSHIFT_CONF"
    source_if_present "${env_path}"
    # LIMITATION: this only blocks sourced config/env overrides during load; post-load shell assignments are not prevented here.
    restore_protected_tunables "__NIGHTSHIFT_CONF" "~/.nightshift-env"
    normalize_loaded_task_writer_configuration \
        "${env_path}" \
        "${task_writer_max_tasks_preexisting}" \
        "${task_writer_min_severity_preexisting}" \
        "${task_writer_min_budget_preexisting}"
    validate_nightshift_configuration
}

update_run_suffix_from_branch() {
    local branch_name="${1:-${RUN_BRANCH}}"

    RUN_SUFFIX=""
    if [[ "${branch_name}" =~ ^nightshift/[0-9]{4}-[0-9]{2}-[0-9]{2}-([0-9]+)$ ]]; then
        RUN_SUFFIX="${BASH_REMATCH[1]}"
    fi
}

init_runtime_paths() {
    RUN_ID="${RUN_DATE}-${RUN_CLOCK}-$$"
    export NIGHTSHIFT_RUN_ID="${RUN_ID}"

    RUN_TMP_DIR="/tmp/nightshift-${RUN_ID}"
    RAW_FINDINGS_DIR="${RUN_TMP_DIR}/raw-findings"
    AGENT_OUTPUT_DIR="${RUN_TMP_DIR}/agent-outputs"
    DETECTIVE_STATUS_DIR="${RUN_TMP_DIR}/detective-status"

    export NIGHTSHIFT_RENDERED_DIR="${RUN_TMP_DIR}/rendered"
    export NIGHTSHIFT_COST_STATE_FILE="${RUN_TMP_DIR}/cost-state.json"

    mkdir -p "${RUN_TMP_DIR}" "${RAW_FINDINGS_DIR}" "${AGENT_OUTPUT_DIR}" \
        "${DETECTIVE_STATUS_DIR}" "${NIGHTSHIFT_LOG_DIR}"
    mkdir -p "${NIGHTSHIFT_FINDINGS_DIR}"

    local stale_entries=("${NIGHTSHIFT_FINDINGS_DIR}"/*)
    if (( ${#stale_entries[@]} > 0 )); then
        rm -f "${stale_entries[@]}"
    fi

    LOG_FILE="${NIGHTSHIFT_LOG_DIR}/${RUN_DATE}.log"
    LOG_PIPE="${RUN_TMP_DIR}/run.log.pipe"
    touch "${LOG_FILE}"
    mkfifo "${LOG_PIPE}"
    tee -a "${LOG_FILE}" < "${LOG_PIPE}" &
    LOGGER_PID=$!
    exec > "${LOG_PIPE}" 2>&1

    ns_log "Run ID: ${RUN_ID}"
    ns_log "Run temp dir: ${RUN_TMP_DIR}"
    ns_log "Log file: ${LOG_FILE}"

    reset_detective_statuses
}

ensure_repo_output_dirs() {
    mkdir -p "${REPO_ROOT}/docs/tasks/open/nightshift" "${REPO_ROOT}/docs/nightshift/digests"
}

current_ref_name() {
    local ref_name=""
    ref_name="$(git branch --show-current 2>/dev/null || true)"
    if [[ -n "${ref_name}" ]]; then
        printf '%s' "${ref_name}"
        return 0
    fi
    ref_name="$(git rev-parse --short HEAD 2>/dev/null || true)"
    printf '%s' "${ref_name:-detached}"
}

working_tree_is_clean() {
    local status_output=""
    status_output="$(git status --porcelain --untracked-files=all 2>/dev/null || true)"
    [[ -z "${status_output}" ]]
}

list_local_nightshift_branches() {
    git for-each-ref --format='%(refname:short)' 'refs/heads/nightshift/*' 2>/dev/null || true
}

prune_local_nightshift_branches() {
    local context="$1"
    local current_branch=""
    local branch=""
    local output=""
    local branches=()

    current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    while IFS= read -r branch; do
        [[ -z "${branch}" ]] && continue
        if [[ -n "${current_branch}" && "${branch}" == "${current_branch}" ]]; then
            ns_log "INFO: Night Shift: skipped pruning checked-out branch ${branch} during ${context}"
            continue
        fi
        branches+=("${branch}")
    done < <(list_local_nightshift_branches)

    if (( ${#branches[@]} == 0 )); then
        return 0
    fi

    if output="$(git branch -D "${branches[@]}" 2>&1)"; then
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            ns_log "INFO: Night Shift: ${context}: ${line}"
        done <<< "${output}"
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        ns_log "WARN: Night Shift: ${context}: ${line}"
    done <<< "${output}"
    return 0
}

ensure_detective_status_dir() {
    if [[ -z "${DETECTIVE_STATUS_DIR}" ]]; then
        if [[ -n "${RUN_TMP_DIR}" ]]; then
            DETECTIVE_STATUS_DIR="${RUN_TMP_DIR}/detective-status"
        elif [[ -n "${RAW_FINDINGS_DIR}" ]]; then
            DETECTIVE_STATUS_DIR="$(dirname "${RAW_FINDINGS_DIR}")/detective-status"
        else
            DETECTIVE_STATUS_DIR="${TMPDIR:-/tmp}/nightshift-detective-status-${RUN_ID:-$$}"
        fi
    fi
    mkdir -p "${DETECTIVE_STATUS_DIR}"
}

detective_status_path() {
    local playbook_name="$1"
    ensure_detective_status_dir
    printf '%s/%s.status' "${DETECTIVE_STATUS_DIR}" "${playbook_name}"
}

reset_detective_statuses() {
    local playbook_name=""
    ensure_detective_status_dir

    local stale_statuses=("${DETECTIVE_STATUS_DIR}"/*.status)
    if (( ${#stale_statuses[@]} > 0 )); then
        rm -f "${stale_statuses[@]}"
    fi

    for playbook_name in "${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}"; do
        printf 'skipped\n' > "$(detective_status_path "${playbook_name}")"
    done
}

set_detective_status() {
    local playbook_name="$1"
    local status="$2"
    printf '%s\n' "${status}" > "$(detective_status_path "${playbook_name}")"
}

detective_status_value() {
    local playbook_name="$1"
    local path=""
    path="$(detective_status_path "${playbook_name}")"
    if [[ -f "${path}" ]]; then
        tr -d '\n' < "${path}"
    else
        printf 'skipped'
    fi
}

count_findings_in_file() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        echo "0"
        return 0
    fi
    awk '/^### Finding(:| [0-9]+:)/{count++} END{print count+0}' "${path}"
}

count_total_findings() {
    local total=0
    local path=""
    for path in "${NIGHTSHIFT_FINDINGS_DIR}"/*-findings.md; do
        total=$(( total + $(count_findings_in_file "${path}") ))
    done
    echo "${total}"
}

count_findings_by_severity_in_file() {
    local path="$1"
    local severity="$2"
    if [[ ! -f "${path}" ]]; then
        echo "0"
        return 0
    fi
    awk -v severity="${severity}" '
        /^\*\*Severity:\*\*[[:space:]]*/ {
            value=$0
            sub(/^\*\*Severity:\*\*[[:space:]]*/, "", value)
            sub(/[[:space:]].*$/, "", value)
            if (value == severity) {
                count++
            }
        }
        END { print count + 0 }
    ' "${path}"
}

count_task_files() {
    if [[ ! -d "${REPO_ROOT}/docs/tasks/open/nightshift" ]]; then
        echo "0"
        return 0
    fi
    find "${REPO_ROOT}/docs/tasks/open/nightshift" -maxdepth 1 -type f -name "${RUN_DATE}-*.md" | wc -l | tr -d '[:space:]'
}

manager_task_manifest_path() {
    printf '%s/manager-task-manifest.txt\n' "${RUN_TMP_DIR}"
}

findings_manifest_path() {
    printf '%s/findings-manifest.txt\n' "${RUN_TMP_DIR}"
}

manager_top_findings_from_digest() {
    local digest_path="${1:-${DIGEST_PATH:-}}"

    [[ -n "${digest_path}" && -f "${digest_path}" ]] || return 0

    awk -v heading="${NIGHTSHIFT_MANAGER_TASK_FILES_HEADING}" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function lower_trim(value) {
            value = trim(value)
            return tolower(value)
        }

        $0 == heading {
            in_table = 1
            next
        }

        in_table && /^## / {
            exit
        }

        !in_table {
            next
        }

        /^\|---/ {
            next
        }

        /^\|/ {
            field_count = split($0, columns, "|")
            if (!header_seen) {
                for (i = 1; i <= field_count; i++) {
                    column_name = lower_trim(columns[i])
                    if (column_name == "#") {
                        rank_col = i
                    } else if (column_name == "severity") {
                        severity_col = i
                    } else if (column_name == "category") {
                        category_col = i
                    } else if (column_name == "title") {
                        title_col = i
                    }
                }
                if (rank_col > 0 && severity_col > 0 && category_col > 0 && title_col > 0) {
                    header_seen = 1
                }
                next
            }

            rank = trim(columns[rank_col])
            severity = trim(columns[severity_col])
            category = trim(columns[category_col])
            title = trim(columns[title_col])

            if (rank != "" && severity != "" && category != "" && title != "") {
                printf "%s\t%s\t%s\t%s\n", rank, severity, category, title
            }
        }
    ' "${digest_path}"
}

count_top_findings_in_digest() {
    local digest_path="${1:-${DIGEST_PATH:-}}"

    manager_top_findings_from_digest "${digest_path}" | awk 'END { print NR + 0 }'
}

write_findings_manifest() {
    local digest_path="$1"
    local manifest_path=""
    local manifest_tmp=""

    manifest_path="$(findings_manifest_path)"
    manifest_tmp="${manifest_path}.tmp"

    if ! manager_top_findings_from_digest "${digest_path}" > "${manifest_tmp}"; then
        rm -f "${manifest_tmp}"
        return 1
    fi

    if ! mv "${manifest_tmp}" "${manifest_path}"; then
        rm -f "${manifest_tmp}"
        return 1
    fi
}

write_manager_task_manifest() {
    local manifest_path=""
    local manifest_tmp=""
    local task_path=""

    manifest_path="$(manager_task_manifest_path)"
    manifest_tmp="${manifest_path}.tmp"
    mkdir -p "$(dirname "${manifest_path}")"
    : > "${manifest_tmp}"

    for task_path in "${CREATED_TASKS[@]-}"; do
        [[ -n "${task_path}" ]] || continue
        printf '%s\n' "${task_path}" >> "${manifest_tmp}"
    done

    if ! mv "${manifest_tmp}" "${manifest_path}"; then
        rm -f "${manifest_tmp}"
        return 1
    fi
}

manager_digest_table_row_by_rank() {
    local rank="$1"
    local digest_path="${2:-${DIGEST_PATH:-}}"

    [[ -n "${rank}" && -n "${digest_path}" && -f "${digest_path}" ]] || return 0

    awk -v heading="${NIGHTSHIFT_MANAGER_TASK_FILES_HEADING}" -v wanted_rank="${rank}" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function lower_trim(value) {
            value = trim(value)
            return tolower(value)
        }

        $0 == heading {
            in_table = 1
            next
        }

        in_table && /^## / {
            exit
        }

        !in_table {
            next
        }

        /^\|---/ {
            next
        }

        /^\|/ {
            field_count = split($0, columns, "|")
            if (!header_seen) {
                for (i = 1; i <= field_count; i++) {
                    if (lower_trim(columns[i]) == "#") {
                        rank_col = i
                    }
                }
                if (rank_col > 0) {
                    header_seen = 1
                }
                next
            }

            rank_value = trim(columns[rank_col])
            if (rank_value == wanted_rank) {
                print $0
                exit
            }
        }
    ' "${digest_path}"
}

task_writer_finding_blocks() {
    local findings_path=""

    for findings_path in "${NIGHTSHIFT_FINDINGS_DIR}"/*-findings.md; do
        [[ -f "${findings_path}" ]] || continue

        awk -v findings_path="${findings_path}" '
            function flush_block() {
                if (capture && block != "") {
                    printf "%s%c", findings_path, 0
                    printf "%s", block
                    printf "%c", 0
                    block = ""
                }
            }

            /^## Source:/ {
                flush_block()
                capture = 0
                next
            }

            /^### Finding:/ {
                flush_block()
                block = $0 ORS
                capture = 1
                next
            }

            capture {
                block = block $0 ORS
            }

            END {
                flush_block()
            }
        ' "${findings_path}"
    done
}

task_writer_finding_block_title() {
    local finding_block="$1"

    printf '%s\n' "${finding_block}" \
        | sed -n 's/^### Finding:[[:space:]]*//p;q'
}

task_writer_casefold_match_text() {
    local text="$1"

    printf '%s' "${text}" | tr '[:upper:]' '[:lower:]'
}

task_writer_normalize_match_text() {
    local text="$1"

    printf '%s' "${text}" | awk '
        {
            line = tolower($0)
            gsub(/[[:space:]]+/, " ", line)
            sub(/^ /, "", line)
            sub(/ $/, "", line)
            if (line == "") {
                next
            }
            if (result != "") {
                result = result " "
            }
            result = result line
        }
        END {
            print result
        }
    '
}

task_writer_collect_matching_blocks() {
    local title="$1"
    local match_mode="$2"
    local findings_path=""
    local finding_block=""
    local block_title=""
    local casefold_title=""
    local casefold_block_title=""
    local normalized_title=""
    local normalized_block_title=""

    case "${match_mode}" in
        nocase)
            casefold_title="$(task_writer_casefold_match_text "${title}")"
            ;;
        normalized)
            normalized_title="$(task_writer_normalize_match_text "${title}")"
            ;;
    esac

    while IFS= read -r -d '' findings_path && IFS= read -r -d '' finding_block; do
        block_title="$(task_writer_finding_block_title "${finding_block}")"
        case "${match_mode}" in
            header)
                [[ "${block_title}" == "${title}" ]] || continue
                ;;
            nocase)
                casefold_block_title="$(task_writer_casefold_match_text "${block_title}")"
                [[ -n "${block_title}" && "${casefold_block_title}" == "${casefold_title}" ]] || continue
                ;;
            normalized)
                normalized_block_title="$(task_writer_normalize_match_text "${block_title}")"
                [[ -n "${normalized_title}" && "${normalized_block_title}" == "${normalized_title}" ]] || continue
                ;;
        esac

        printf '%s' "${findings_path}"
        printf '\0'
        printf '%s' "${block_title}"
        printf '\0'
        printf '%s' "${finding_block}"
        printf '\0'
    done < <(task_writer_finding_blocks)
}

task_writer_find_matching_block() {
    local title="$1"
    local match_mode=""
    local finding_path=""
    local block_title=""
    local finding_block=""
    local title_key=""
    local first_title_key=""
    local matched_blocks=()
    local matched_paths=()
    local matched_titles=()
    local had_multiple=0
    local same_title=0
    local unique_paths=0
    local i=0
    local j=0

    for match_mode in header nocase normalized; do
        matched_blocks=()
        matched_paths=()
        matched_titles=()
        while IFS= read -r -d '' finding_path \
            && IFS= read -r -d '' block_title \
            && IFS= read -r -d '' finding_block; do
            matched_paths+=("${finding_path}")
            matched_titles+=("${block_title}")
            matched_blocks+=("${finding_block}")
        done < <(task_writer_collect_matching_blocks "${title}" "${match_mode}")

        if (( ${#matched_blocks[@]} == 1 )); then
            printf '%s' "${matched_blocks[0]}"
            return 0
        fi

        if (( ${#matched_blocks[@]} > 1 )); then
            first_title_key=""
            same_title=1
            unique_paths=1

            case "${match_mode}" in
                header)
                    first_title_key="${matched_titles[0]}"
                    ;;
                nocase)
                    first_title_key="$(task_writer_casefold_match_text "${matched_titles[0]}")"
                    ;;
                normalized)
                    first_title_key="$(task_writer_normalize_match_text "${matched_titles[0]}")"
                    ;;
            esac

            for (( i = 1; i < ${#matched_titles[@]}; i++ )); do
                case "${match_mode}" in
                    header)
                        title_key="${matched_titles[$i]}"
                        ;;
                    nocase)
                        title_key="$(task_writer_casefold_match_text "${matched_titles[$i]}")"
                        ;;
                    normalized)
                        title_key="$(task_writer_normalize_match_text "${matched_titles[$i]}")"
                        ;;
                esac

                if [[ "${title_key}" != "${first_title_key}" ]]; then
                    same_title=0
                    break
                fi
            done

            if (( same_title == 1 )); then
                for (( i = 0; i < ${#matched_paths[@]}; i++ )); do
                    for (( j = i + 1; j < ${#matched_paths[@]}; j++ )); do
                        if [[ "${matched_paths[$i]}" == "${matched_paths[$j]}" ]]; then
                            unique_paths=0
                            break 2
                        fi
                    done
                done
            fi

            if (( same_title == 1 && unique_paths == 1 )); then
                ns_err_log "INFO: Task writing merged ${#matched_blocks[@]} corroborating finding blocks for title '${title}'"
                for (( i = 0; i < ${#matched_blocks[@]}; i++ )); do
                    if (( i > 0 )); then
                        printf '\n'
                    fi
                    printf '%s' "${matched_blocks[$i]}"
                done
                return 0
            fi

            had_multiple=1
        fi
    done

    if (( had_multiple == 1 )); then
        return 2
    fi

    return 1
}

task_writer_finding_context() {
    local rank="$1"
    local severity="$2"
    local category="$3"
    local title="$4"
    local existing_open_tasks_context="${5:-}"
    local digest_row=""
    local finding_context=""
    local finding_block=""
    local finding_block_status=0
    local result=""

    digest_row="$(manager_digest_table_row_by_rank "${rank}" "${DIGEST_PATH:-}")"
    if [[ -z "${digest_row}" ]]; then
        ns_err_log "WARN: Task writing could not find rank ${rank} in digest; using manifest metadata only"
        finding_context="$(printf 'Rank: %s\nSeverity: %s\nCategory: %s\nTitle: %s\n' \
            "${rank}" "${severity}" "${category}" "${title}")"
    else
        finding_context="$(printf 'Rank: %s\nSeverity: %s\nCategory: %s\nTitle: %s\nFull table row: %s\n' \
            "${rank}" "${severity}" "${category}" "${title}" "${digest_row}")"
    fi

    finding_block=""
    if finding_block="$(task_writer_find_matching_block "${title}")"; then
        result="$(printf '%s\n%s' "${finding_context}" "${finding_block}")"
    else
        finding_block_status=$?
    fi

    if [[ -z "${result}" ]]; then
        case "${finding_block_status}" in
            1)
                ns_err_log "WARN: Task writing could not match finding title '${title}' in ${NIGHTSHIFT_FINDINGS_DIR}; using manifest metadata only"
                ;;
            2)
                ns_err_log "WARN: Task writing found multiple finding blocks matching title '${title}'; using manifest metadata only"
                ;;
        esac
        result="${finding_context}"
    fi

    if [[ -n "${existing_open_tasks_context}" ]]; then
        result="${result}"$'\n\n'"${existing_open_tasks_context}"
    fi

    printf '%s' "${result}"
}

task_writer_result_line() {
    local task_writer_text="$1"

    printf '%s\n' "${task_writer_text}" \
        | sed -n '/^### Task Writer Result:[[:space:]]*/{p;q;}'
}

task_writer_result_status() {
    local result_line="$1"

    case "${result_line}" in
        '### Task Writer Result:'*)
            case "${result_line#*Task Writer Result: }" in
                CREATED*)
                    printf 'CREATED\n'
                    ;;
                REJECTED*)
                    printf 'REJECTED\n'
                    ;;
            esac
            ;;
    esac
}

task_writer_rejection_reason() {
    local result_line="$1"
    local reason=""

    reason="${result_line#*Task Writer Result: }"
    reason="${reason#REJECTED}"
    reason="$(printf '%s' "${reason}" | sed -E 's/^[[:space:]]*[—-]?[[:space:]]*//')"
    printf '%s\n' "${reason}"
}

task_writer_extract_task_block() {
    local task_writer_text="$1"

    printf '%s\n' "${task_writer_text}" | awk '
        /^--- BEGIN TASK FILE ---[[:space:]]*$/ {
            if (capture) {
                nested_begin = 1
                next
            }
            begin_seen = 1
            capture = 1
            next
        }

        /^--- END TASK FILE ---[[:space:]]*$/ {
            if (capture) {
                end_seen = 1
                capture = 0
                exit
            }
        }

        capture {
            lines[++line_count] = $0
        }

        END {
            if (!begin_seen || !end_seen || nested_begin || line_count == 0) {
                exit 1
            }
            for (i = 1; i <= line_count; i++) {
                print lines[i]
            }
        }
    '
}

task_writer_slug_from_title() {
    local title="$1"

    printf '%s' "${title}" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g' \
        | cut -c1-60 \
        | sed -E 's/^-+//; s/-+$//'
}

task_writer_resolve_target_path() {
    local slug="$1"
    local candidate_path=""
    local suffix=2

    candidate_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-${slug}.md"
    if [[ ! -e "${candidate_path}" ]]; then
        printf '%s\n' "${candidate_path}"
        return 0
    fi

    while [[ "${suffix}" -le 99 ]]; do
        candidate_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-${slug}-${suffix}.md"
        if [[ ! -e "${candidate_path}" ]]; then
            printf '%s\n' "${candidate_path}"
            return 0
        fi
        suffix=$(( suffix + 1 ))
    done

    return 1
}

validation_task_paths() {
    local manifest_path=""
    manifest_path="$(manager_task_manifest_path)"

    if [[ ! -f "${manifest_path}" ]]; then
        return 0
    fi

    awk 'NF { print }' "${manifest_path}"
}

validation_final_result_block() {
    local validation_text="$1"

    printf '%s\n' "${validation_text}" | awk '
        /^### Validation Result:[[:space:]]*/ {
            block = $0 ORS
            capture = 1
            next
        }
        capture {
            block = block $0 ORS
        }
        END {
            if (capture) {
                printf "%s", block
            }
        }
    '
}

validation_result_status() {
    local validation_text="$1"
    local final_block=""

    final_block="$(validation_final_result_block "${validation_text}")"
    [[ -n "${final_block}" ]] || return 0

    printf '%s\n' "${final_block}" \
        | sed -n 's/^### Validation Result:[[:space:]]*//p' \
        | head -n 1 \
        | tr '[:lower:]' '[:upper:]'
}

validation_failed_checks() {
    local validation_text="$1"
    local final_block=""

    final_block="$(validation_final_result_block "${validation_text}")"
    [[ -n "${final_block}" ]] || return 0

    printf '%s\n' "${final_block}" | awk '
        /^Failed checks:[[:space:]]*$/ {
            capture = 1
            next
        }
        capture && /^- \(none\)$/ {
            next
        }
        capture && /^- / {
            print
            next
        }
        capture && /^[[:space:]]*$/ {
            next
        }
        capture {
            exit
        }
    '
}

append_validation_failure_section() {
    local task_path="$1"
    local failure_lines="$2"
    local task_display="${task_path}"

    if [[ "${task_display}" == "${REPO_ROOT}/"* ]]; then
        task_display="${task_display#${REPO_ROOT}/}"
    fi

    if [[ ! -f "${task_path}" ]]; then
        append_warning "Could not append validation failure for ${task_display}: task file is missing"
        return 1
    fi

    if [[ ! -w "${task_path}" ]]; then
        append_warning "Could not append validation failure for ${task_display}: task file is not writable"
        return 1
    fi

    if ! remove_existing_validation_section "${task_path}"; then
        append_warning "Could not append validation failure for ${task_display}: rewrite failed"
        return 1
    fi

    if ! {
        printf '\n## Validation: FAILED\n'
        if [[ -n "${failure_lines}" ]]; then
            printf '%s\n' "${failure_lines}"
        else
            printf -- '- INVALID:validation — validation agent marked the task invalid without failure details\n'
        fi
    } >> "${task_path}"; then
        append_warning "Could not append validation failure for ${task_display}: append failed"
        return 1
    fi
}

# remove_existing_validation_section rewrites the task file in place without any
# existing top-level "## Validation:" section. It matches only real headings
# anchored at column 1 and drops content through the next top-level "## " or EOF.
remove_existing_validation_section() {
    local task_path="$1"
    local task_tmp=""

    task_tmp="$(mktemp "${task_path}.XXXXXX")" || return 1

    if ! awk '
        /^## Validation:/ {
            in_validation=1
            next
        }
        in_validation && /^## / {
            in_validation=0
        }
        !in_validation {
            print
        }
    ' "${task_path}" > "${task_tmp}"; then
        rm -f "${task_tmp}"
        return 1
    fi

    if ! mv "${task_tmp}" "${task_path}"; then
        rm -f "${task_tmp}"
        return 1
    fi
}

# append_validation_success_section writes the VALIDATED stamp to the task file on disk.
append_validation_success_section() {
    local task_path="$1"
    local task_display="${task_path}"

    if [[ "${task_display}" == "${REPO_ROOT}/"* ]]; then
        task_display="${task_display#${REPO_ROOT}/}"
    fi

    if [[ ! -f "${task_path}" ]]; then
        append_warning "Could not append validation success for ${task_display}: task file is missing"
        return 1
    fi

    if [[ ! -w "${task_path}" ]]; then
        append_warning "Could not append validation success for ${task_display}: task file is not writable"
        return 1
    fi

    if ! remove_existing_validation_section "${task_path}"; then
        append_warning "Could not append validation success for ${task_display}: rewrite failed"
        return 1
    fi

    if ! {
        printf '\n## Validation: VALIDATED\n\n'
        printf 'Validated by Night Shift validation agent on %s.\n' "${RUN_DATE}"
    } >> "${task_path}"; then
        append_warning "Could not append validation success for ${task_display}: append failed"
        return 1
    fi
}

append_autofix_section() {
    local task_path="$1"
    local autofix_status="$2"
    local exit_code="$3"
    local fix_cost="$4"
    local task_display="${task_path}"
    if [[ "${task_display}" == "${REPO_ROOT}/"* ]]; then
        task_display="${task_display#${REPO_ROOT}/}"
    fi
    if [[ ! -f "${task_path}" ]]; then
        append_warning "Could not append autofix metadata for ${task_display}: task file is missing"
        return 1
    fi
    if [[ ! -w "${task_path}" ]]; then
        append_warning "Could not append autofix metadata for ${task_display}: task file is not writable"
        return 1
    fi
    if ! {
        printf '\n## Autofix: %s\n' "${autofix_status}"
        printf -- '- Date: %s\n' "${RUN_DATE}"
        printf -- '- Run ID: %s\n' "${RUN_ID}"
        printf -- '- Lauren Loop exit code: %s\n' "${exit_code}"
        if [[ "${fix_cost}" == "unknown" ]]; then
            printf -- '- Cost: unknown\n'
        else
            printf -- '- Cost: $%s\n' "${fix_cost}"
        fi
    } >> "${task_path}"; then
        append_warning "Could not append autofix metadata for ${task_display}: append failed"
        return 1
    fi
}

autofix_compact_text() {
    awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "") {
                lines[++count] = line
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                printf "%s", lines[i]
                if (i < count) {
                    printf " "
                }
            }
        }
    '
}

autofix_extract_goal() {
    local task_file="$1"
    local lauren_utils_path="${REPO_ROOT}/lib/lauren-loop-utils.sh"
    if [[ ! -f "${task_file}" ]]; then
        return 1
    fi
    if ! declare -F _task_goal_content >/dev/null 2>&1; then
        [[ -r "${lauren_utils_path}" ]] || return 1
        # Canonical Goal parsing lives in _task_goal_content().
        # shellcheck disable=SC1090
        source "${lauren_utils_path}"
    fi
    declare -F _task_goal_content >/dev/null 2>&1 || return 1
    _task_goal_content "${task_file}"
}

cost_total_value() {
    if [[ "${COST_TRACKING_READY}" -eq 0 ]]; then
        echo "0.0000"
        return 0
    fi
    cost_get_total 2>/dev/null || echo "0.0000"
}

_backlog_remaining_budget() {
    local total_spend="0.0000"
    total_spend="$(cost_total_value)"
    awk -v cap="${NIGHTSHIFT_COST_CAP_USD:-0}" -v spend="${total_spend:-0}" '
        BEGIN {
            remaining = cap - spend
            if (remaining < 0) {
                remaining = 0
            }
            printf "%.4f\n", remaining
        }
    '
}

autofix_remaining_budget() {
    local autofix_spend="${1:-0.0000}"
    local total_spend="0.0000"
    total_spend="$(cost_total_value)"
    awk -v cap="${NIGHTSHIFT_COST_CAP_USD:-0}" \
        -v spend="${total_spend:-0}" \
        -v autofix="${autofix_spend:-0}" '
        BEGIN {
            remaining = cap - spend - autofix
            if (remaining < 0) {
                remaining = 0
            }
            printf "%.4f\n", remaining
        }
    '
}

autofix_spendable_budget() {
    local remaining_budget="${1:-0.0000}"
    awk -v remaining="${remaining_budget:-0}" -v reserve="${NIGHTSHIFT_AUTOFIX_MIN_BUDGET:-0}" '
        BEGIN {
            spendable = remaining - reserve
            if (spendable < 0) {
                spendable = 0
            }
            printf "%.4f\n", spendable
        }
    '
}

task_writer_max_tasks_setting() {
    resolve_setting_with_legacy_fallback \
        "NIGHTSHIFT_TASK_WRITER_MAX_TASKS" \
        "NIGHTSHIFT_AUTOFIX_MAX_TASKS" \
        "5"
}

task_writer_min_severity_setting() {
    resolve_setting_with_legacy_fallback \
        "NIGHTSHIFT_TASK_WRITER_MIN_SEVERITY" \
        "NIGHTSHIFT_AUTOFIX_SEVERITY" \
        "critical,major"
}

task_writer_min_budget_setting() {
    resolve_setting_with_legacy_fallback \
        "NIGHTSHIFT_TASK_WRITER_MIN_BUDGET" \
        "NIGHTSHIFT_AUTOFIX_MIN_BUDGET" \
        "20"
}

severity_allowed_in_list() {
    local severity=""
    local allowed_severities="${2:-}"

    severity="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ -n "${severity}" ]] || return 1

    case ",${allowed_severities}," in
        *,"${severity}",*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

autofix_allowed_severity() {
    severity_allowed_in_list "${1:-}" "${NIGHTSHIFT_AUTOFIX_SEVERITY:-}"
}

task_writer_allowed_severity() {
    local allowed_severities=""

    allowed_severities="$(task_writer_min_severity_setting)"
    severity_allowed_in_list "${1:-}" "${allowed_severities}"
}

autofix_extract_severity() {
    local task_file="$1"

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function emit_if_valid(value) {
            value = tolower(trim(value))
            sub(/[[:space:]].*$/, "", value)
            if (value ~ /^(critical|major|minor|observation)$/) {
                print value
                exit
            }
        }
        /^## Context[[:space:]]*$/ {
            in_context = 1
            next
        }
        /^## [^#]/ && in_context {
            in_context = 0
        }
        in_context {
            normalized = $0
            gsub(/\r/, "", normalized)
            gsub(/\*\*/, "", normalized)
            normalized = trim(normalized)
            sub(/^[-*][[:space:]]*/, "", normalized)
            if (tolower(normalized) ~ /^severity:[[:space:]]*/) {
                sub(/^[Ss]everity:[[:space:]]*/, "", normalized)
                emit_if_valid(normalized)
            }
        }
        /^## Severity:[[:space:]]*/ {
            normalized = $0
            sub(/^## Severity:[[:space:]]*/, "", normalized)
            emit_if_valid(normalized)
        }
        /^## Severity[[:space:]]*$/ {
            in_severity_section = 1
            next
        }
        /^## [^#]/ && in_severity_section {
            exit
        }
        in_severity_section {
            emit_if_valid($0)
        }
    ' "${task_file}"
}

autofix_task_artifact_dir() {
    local task_file="$1"
    case "${task_file}" in
        */task.md)
            dirname "${task_file}"
            ;;
        *.md)
            printf '%s/%s\n' "$(dirname "${task_file}")" "$(basename "${task_file}" .md)"
            ;;
        *)
            return 1
            ;;
    esac
}

autofix_manifest_path() {
    local task_file="$1"
    local task_dir=""
    task_dir="$(autofix_task_artifact_dir "${task_file}")" || return 1
    printf '%s/competitive/run-manifest.json\n' "${task_dir}"
}

autofix_manifest_final_status() {
    local manifest_path="$1"
    local status=""
    if ! status="$(jq -r '.final_status // empty' "${manifest_path}" 2>/dev/null)" || [[ -z "${status}" ]]; then
        echo ""
        return 0
    fi
    printf '%s\n' "${status}"
}

autofix_manifest_total_cost() {
    local manifest_path="$1"
    local total_cost=""
    if ! total_cost="$(jq -r '.total_cost_usd // empty' "${manifest_path}" 2>/dev/null)" || [[ -z "${total_cost}" ]]; then
        return 1
    fi
    if [[ ! "${total_cost}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        return 1
    fi
    awk -v total="${total_cost}" 'BEGIN { printf "%.4f\n", total + 0 }'
}

autofix_validate_exit_zero_manifest() {
    local task_file="$1"
    local manifest_path=""
    local final_status=""
    local task_display="${task_file}"
    if [[ "${task_display}" == "${REPO_ROOT}/"* ]]; then
        task_display="${task_display#${REPO_ROOT}/}"
    fi
    manifest_path="$(autofix_manifest_path "${task_file}" 2>/dev/null || true)"
    if [[ -z "${manifest_path}" || ! -r "${manifest_path}" ]]; then
        append_warning "Autofix task ${task_display} exited 0 but manifest ${manifest_path:-unknown} was missing or unreadable; treating outcome as failed"
        return 1
    fi
    final_status="$(autofix_manifest_final_status "${manifest_path}")"
    case "${final_status}" in
        success|human_review|completed|blocked)
            ;;
        "")
            append_warning "Autofix task ${task_display} exited 0 but manifest ${manifest_path} did not contain final_status; treating outcome as failed"
            return 1
            ;;
        *)
            append_warning "Autofix task ${task_display} exited 0 but manifest ${manifest_path} reported unknown final_status '${final_status}'; treating outcome as failed"
            return 1
            ;;
    esac

    if ! autofix_manifest_total_cost "${manifest_path}" >/dev/null 2>&1; then
        append_warning "Autofix task ${task_display} exited 0 but manifest ${manifest_path} did not contain valid total_cost_usd; treating outcome as failed"
        return 1
    fi
}

autofix_task_slug_from_path() {
    local task_path="$1"
    local base_name=""
    base_name="$(basename "${task_path}" .md)"
    if [[ "${base_name}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-(.+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf '%s\n' "${base_name}"
}

autofix_outcome_from_v2_run() {
    local task_file="$1"
    local invocation_exit="${2:-0}"
    local manifest_path=""
    local final_status=""
    if [[ "${invocation_exit}" -ne 0 ]]; then
        printf 'failed\n'
        return 0
    fi
    manifest_path="$(autofix_manifest_path "${task_file}" 2>/dev/null || true)"
    final_status="$(autofix_manifest_final_status "${manifest_path}")"
    case "${final_status}" in
        success)
            printf 'success\n'
            ;;
        human_review|completed|blocked)
            printf 'blocked\n'
            ;;
        *)
            printf 'failed\n'
            ;;
    esac
}

autofix_stage_changed_paths() {
    local task_file="$1"
    local before_snapshot="$2"
    local after_snapshot="$3"
    local before_untracked="$4"
    local after_untracked="$5"
    local task_dir=""
    local task_dir_rel=""
    local left_ref="HEAD"
    local right_ref="HEAD"
    local diff_output=""
    local repo_path=""
    local task_display="${task_file}"
    local stage_paths=()
    local stage_index=$'\n'
    local path_summary=""
    if [[ "${task_display}" == "${REPO_ROOT}/"* ]]; then
        task_display="${task_display#${REPO_ROOT}/}"
    fi
    task_dir="$(autofix_task_artifact_dir "${task_file}" 2>/dev/null || true)"
    if [[ "${task_dir}" == "${REPO_ROOT}/"* ]]; then
        task_dir_rel="${task_dir#${REPO_ROOT}/}"
    fi
    [[ -n "${before_snapshot}" ]] && left_ref="${before_snapshot}"
    [[ -n "${after_snapshot}" ]] && right_ref="${after_snapshot}"
    if ! diff_output="$(git diff --name-only "${left_ref}" "${right_ref}" 2>/dev/null)"; then
        append_warning "Autofix staging diff failed for ${task_display}"
        return 1
    fi

    while IFS= read -r repo_path; do
        [[ -n "${repo_path}" ]] || continue
        if [[ -n "${task_dir_rel}" ]]; then
            case "${repo_path}" in
                "${task_dir_rel}/competitive/"*|"${task_dir_rel}/logs/"*)
                    continue
                    ;;
            esac
        fi
        if [[ "${stage_index}" == *$'\n'"${repo_path}"$'\n'* ]]; then
            continue
        fi
        stage_paths+=("${repo_path}")
        stage_index+="${repo_path}"$'\n'
    done <<< "${diff_output}"

    while IFS= read -r repo_path; do
        [[ -n "${repo_path}" ]] || continue
        if printf '%s\n' "${before_untracked}" | grep -F -x -- "${repo_path}" >/dev/null 2>&1; then
            continue
        fi
        if [[ -n "${task_dir_rel}" ]]; then
            case "${repo_path}" in
                "${task_dir_rel}/competitive/"*|"${task_dir_rel}/logs/"*)
                    continue
                    ;;
            esac
        fi
        if [[ "${stage_index}" == *$'\n'"${repo_path}"$'\n'* ]]; then
            continue
        fi
        stage_paths+=("${repo_path}")
        stage_index+="${repo_path}"$'\n'
    done <<< "${after_untracked}"

    if (( ${#stage_paths[@]} == 0 )); then
        return 0
    fi

    if ! git add -- "${stage_paths[@]}"; then
        path_summary="$(printf '%s,' "${stage_paths[@]}")"
        path_summary="${path_summary%,}"
        ns_log "git add failed for ${path_summary} — stopping autofix to prevent incomplete PR"
        append_warning "Autofix staging failed for ${task_display}"
        return 1
    fi
}

backlog_relative_task_path() {
    local task_path="$1"
    task_path="$(trim_whitespace "${task_path}")"

    case "${task_path}" in
        "${REPO_ROOT}/"*)
            printf '%s\n' "${task_path#${REPO_ROOT}/}"
            ;;
        /*)
            printf '%s\n' "${task_path}"
            ;;
        docs/tasks/open/*|docs/tasks/closed/*)
            printf '%s\n' "${task_path}"
            ;;
        *)
            task_path="${task_path#./}"
            printf '%s\n' "docs/tasks/open/${task_path}"
            ;;
    esac
}

backlog_absolute_task_path() {
    local task_path="$1"
    local rel_path=""

    task_path="$(trim_whitespace "${task_path}")"
    case "${task_path}" in
        /*)
            printf '%s\n' "${task_path}"
            return 0
            ;;
    esac

    rel_path="$(backlog_relative_task_path "${task_path}")"
    printf '%s\n' "${REPO_ROOT}/${rel_path}"
}

backlog_task_path_to_slug() {
    local task_path="$1"
    local rel_path=""

    rel_path="$(backlog_relative_task_path "${task_path}")"
    case "${rel_path}" in
        */task.md)
            basename "$(dirname "${rel_path}")"
            ;;
        *.md)
            basename "${rel_path}" .md
            ;;
        *)
            basename "${rel_path}"
            ;;
    esac
}

backlog_stage_path_add() {
    local stage_path="$1"
    local existing_path=""

    for existing_path in "${BACKLOG_STAGE_PATHS[@]-}"; do
        [[ "${existing_path}" == "${stage_path}" ]] && return 0
    done

    BACKLOG_STAGE_PATHS+=("${stage_path}")
}

backlog_result_add() {
    local task_path="$1"
    local slug="$2"
    local outcome="$3"
    local cost_delta="$4"

    BACKLOG_RESULTS+=("${task_path}"$'\t'"${slug}"$'\t'"${outcome}"$'\t'"${cost_delta}")
}

backlog_extract_field_value() {
    local task_file="$1"
    shift

    local labels_joined=""
    local label=""
    for label in "$@"; do
        labels_joined="${labels_joined:+${labels_joined}|}${label}"
    done

    awk -v labels="${labels_joined}" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            label_count = split(labels, raw_labels, /\|/)
            for (i = 1; i <= label_count; i++) {
                key = tolower(trim(raw_labels[i]))
                gsub(/[[:space:]]+/, " ", key)
                wanted[key] = 1
            }
        }
        {
            normalized = $0
            gsub(/\r/, "", normalized)
            gsub(/\*\*/, "", normalized)
            normalized = trim(normalized)
            sub(/^[-*][[:space:]]*/, "", normalized)
            sub(/^##[[:space:]]+/, "", normalized)
            if (index(normalized, ":") == 0) {
                next
            }
            key = substr(normalized, 1, index(normalized, ":") - 1)
            key = tolower(trim(key))
            gsub(/[[:space:]]+/, " ", key)
            if (!(key in wanted)) {
                next
            }
            value = substr(normalized, index(normalized, ":") + 1)
            print trim(value)
            exit
        }
    ' "${task_file}"
}

backlog_extract_section_body() {
    local task_file="$1"
    local section_name="$2"

    awk -v section_name="${section_name}" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            target = tolower(trim(section_name))
            capture = 0
        }
        {
            raw = $0
            normalized = raw
            gsub(/\r/, "", normalized)
            gsub(/\*\*/, "", normalized)
            normalized = trim(normalized)
            normalized_lower = tolower(normalized)

            if (capture && normalized_lower ~ /^##[[:space:]]+/) {
                exit
            }

            if (normalized_lower ~ "^##[[:space:]]+" target "[[:space:]]*:?[[:space:]]*$") {
                capture = 1
                next
            }

            if (capture) {
                print raw
            }
        }
    ' "${task_file}"
}

backlog_normalize_status() {
    local status="$1"
    status="$(printf '%s' "${status}" | tr '[:upper:]' '[:lower:]' | tr '[:space:]' ' ' | tr -s ' ')"
    trim_whitespace "${status}"
}

backlog_status_is_terminal() {
    local status_normalized=""
    status_normalized="$(backlog_normalize_status "$1")"
    [[ -n "${status_normalized}" ]] || return 1

    if [[ "${status_normalized}" == *"needs verification"* ]]; then
        return 1
    fi

    [[ "${status_normalized}" =~ ^(done|complete|completed|verified)([[:space:][:punct:]]|$) ]]
}

backlog_dependency_body() {
    local task_file="$1"
    local dep_body=""

    dep_body="$(backlog_extract_section_body "${task_file}" "depends on" | sed '/^[[:space:]]*$/d' || true)"
    if [[ -n "${dep_body}" ]]; then
        printf '%s\n' "${dep_body}"
        return 0
    fi

    backlog_extract_field_value "${task_file}" "depends on"
}

backlog_dependency_tokens() {
    local dep_body="$1"

    printf '%s\n' "${dep_body}" \
        | sed 's/\*\*//g; s/`//g' \
        | tr ',;' '\n' \
        | awk '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }
            {
                line = $0
                sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
                line = trim(line)
                if (line == "") {
                    next
                }

                lower = tolower(line)
                if (lower ~ /^unblocked([[:space:]]|$)/ || lower == "none") {
                    next
                }

                if (match(line, /(docs\/tasks\/(open|closed)\/[^[:space:]`]+(\.md|\/task\.md))/)) {
                    print substr(line, RSTART, RLENGTH)
                    next
                }

                if (match(line, /^[A-Za-z0-9][A-Za-z0-9._\/-]*/)) {
                    token = substr(line, RSTART, RLENGTH)
                    lower = tolower(token)
                    if (lower != "none" && lower != "unblocked" && lower != "task" && lower != "phase") {
                        print token
                    }
                }
            }
        '
}

backlog_resolve_dependency_match() {
    local root_dir="$1"
    local token="$2"
    local normalized_token=""
    local task_file=""
    local matches=()

    normalized_token="$(printf '%s' "${token}" | tr '[:upper:]' '[:lower:]')"

    case "${token}" in
        "${REPO_ROOT}/"*)
            [[ -f "${token}" ]] && printf '%s\n' "${token}"
            return 0
            ;;
        docs/tasks/open/*|docs/tasks/closed/*)
            task_file="${REPO_ROOT}/${token}"
            [[ -f "${task_file}" ]] && printf '%s\n' "${task_file}"
            return 0
            ;;
    esac

    while IFS= read -r task_file; do
        local rel_path="${task_file#${REPO_ROOT}/}"
        local base_name=""
        local stem=""
        local dir_name=""
        local rel_path_lower=""
        local stem_lower=""
        local dir_name_lower=""

        base_name="$(basename "${task_file}")"
        stem="${base_name%.md}"
        dir_name="$(basename "$(dirname "${task_file}")")"

        rel_path_lower="$(printf '%s' "${rel_path}" | tr '[:upper:]' '[:lower:]')"
        stem_lower="$(printf '%s' "${stem}" | tr '[:upper:]' '[:lower:]')"
        dir_name_lower="$(printf '%s' "${dir_name}" | tr '[:upper:]' '[:lower:]')"

        if [[ "${rel_path_lower}" == "${normalized_token}" || "${stem_lower}" == "${normalized_token}" ]]; then
            matches+=("${task_file}")
            continue
        fi

        if [[ "${base_name}" == "task.md" && "${dir_name_lower}" == "${normalized_token}" ]]; then
            matches+=("${task_file}")
        fi
    done < <(find "${root_dir}" -name '*.md' -not -path '*/competitive/*' | sort)

    if (( ${#matches[@]} == 1 )); then
        printf '%s\n' "${matches[0]}"
    fi
}

backlog_task_is_pickable() {
    local task_path="$1"
    local rel_path=""
    local abs_path=""
    local task_slug=""
    local status=""
    local execution_mode=""
    local dep_body=""
    local dep_token=""
    local resolved_dep_path=""
    local resolved_dep_rel_path=""
    local resolved_dep_status=""

    rel_path="$(backlog_relative_task_path "${task_path}")"
    abs_path="$(backlog_absolute_task_path "${task_path}")"
    task_slug="$(backlog_task_path_to_slug "${rel_path}")"

    if [[ ! -f "${abs_path}" ]]; then
        backlog_log "Skipping ${rel_path}: task file no longer exists"
        return 1
    fi

    status="$(backlog_normalize_status "$(backlog_extract_field_value "${abs_path}" "status")")"
    if [[ "${status}" != "not started" ]]; then
        backlog_log "Skipping ${rel_path}: status is '${status:-unknown}'"
        return 1
    fi

    case "${rel_path}" in
        docs/tasks/open/nightshift/${RUN_DATE}-*.md)
            backlog_log "Skipping ${rel_path}: same-run manager task"
            return 1
            ;;
    esac

    case "${rel_path}" in
        *nightshift-bridge-*)
            backlog_log "Skipping ${rel_path}: bridge runtime task"
            return 1
            ;;
    esac

    execution_mode="$(backlog_extract_field_value "${abs_path}" "execution mode" "mode" | tr '[:upper:]' '[:lower:]')"
    execution_mode="$(trim_whitespace "${execution_mode}")"
    if [[ "${execution_mode}" =~ (^|[^[:alnum:]])agent-team([^[:alnum:]]|$) || "${execution_mode}" =~ (^|[^[:alnum:]])team([^[:alnum:]]|$) ]]; then
        backlog_log "Skipping ${rel_path}: execution mode '${execution_mode}' requires team coordination"
        return 1
    fi

    dep_body="$(backlog_dependency_body "${abs_path}" || true)"
    if [[ -n "${dep_body}" ]]; then
        while IFS= read -r dep_token; do
            [[ -n "${dep_token}" ]] || continue
            resolved_dep_path="$(backlog_resolve_dependency_match "${REPO_ROOT}/docs/tasks/open" "${dep_token}")"
            if [[ -z "${resolved_dep_path}" ]]; then
                case "${dep_token}" in
                    "${REPO_ROOT}/"*|docs/tasks/open/*|docs/tasks/closed/*)
                        backlog_log "Skipping ${rel_path}: explicit dependency path '${dep_token}' is missing or does not exist"
                        return 1
                        ;;
                    *)
                        continue
                        ;;
                esac
            fi

            resolved_dep_path="$(backlog_absolute_task_path "${resolved_dep_path}")"
            resolved_dep_rel_path="$(backlog_relative_task_path "${resolved_dep_path}")"
            if [[ "${resolved_dep_path}" == "${abs_path}" ]]; then
                backlog_log "WARN:" "Task ${task_slug} lists itself as a dependency; treating as malformed and blocking pickability"
                return 1
            fi

            resolved_dep_status="$(backlog_normalize_status "$(backlog_extract_field_value "${resolved_dep_path}" "status")")"
            if ! backlog_status_is_terminal "${resolved_dep_status}"; then
                backlog_log "Skipping ${rel_path}: dependency at ${resolved_dep_rel_path} is still '${resolved_dep_status:-unknown}'"
                return 1
            fi
        done < <(backlog_dependency_tokens "${dep_body}")
    fi

    return 0
}

backlog_parse_task_list() {
    if [[ $# -gt 0 ]]; then
        backlog_task_list_section "$1"
    else
        backlog_task_list_section
    fi | awk '
        /^[0-9]+\|[^|]+\|[^|]+\|[^|]+$/ {
            print
        }
    '
}

backlog_task_list_has_header() {
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$1"
    else
        cat
    fi | grep -q '^## TASK_LIST[[:space:]]*$'
}

backlog_task_list_section() {
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$1"
    else
        cat
    fi | awk '
        /^## TASK_LIST[[:space:]]*$/ {
            capture = 1
            next
        }
        capture && /^##[[:space:]]+/ {
            exit
        }
        capture {
            print
        }
    '
}

backlog_manifest_path() {
    local slug="$1"
    printf '%s/docs/tasks/open/%s/competitive/run-manifest.json\n' "${REPO_ROOT}" "${slug}"
}
backlog_manifest_final_status() {
    local manifest_path="$1" status
    if ! status="$(jq -r '.final_status // empty' "${manifest_path}" 2>/dev/null)" || [[ -z "${status}" ]]; then
        echo ""
        return 0
    fi
    echo "${status}"
}

backlog_outcome_from_v2_run() {
    local slug="$1"
    local invocation_exit="${2:-0}"
    local manifest_path=""
    local final_status=""

    BACKLOG_LAST_OUTCOME="failed"
    if [[ "${invocation_exit}" -ne 0 ]]; then
        return 0
    fi

    manifest_path="$(backlog_manifest_path "${slug}")"
    if [[ ! -r "${manifest_path}" ]]; then
        append_warning "Backlog task ${slug} exited 0 but manifest ${manifest_path} was missing or unreadable; treating outcome as failed"
        backlog_log "WARN: ${slug} exited 0 but ${manifest_path} was missing or unreadable; treating outcome as failed"
        return 0
    fi

    final_status="$(backlog_manifest_final_status "${manifest_path}" || true)"
    case "${final_status}" in
        success)
            BACKLOG_LAST_OUTCOME="success"
            ;;
        human_review)
            BACKLOG_LAST_OUTCOME="human_review"
            ;;
        completed)
            BACKLOG_LAST_OUTCOME="blocked"
            ;;
        "")
            append_warning "Backlog task ${slug} exited 0 but manifest ${manifest_path} did not contain final_status; treating outcome as failed"
            backlog_log "WARN: ${slug} exited 0 but ${manifest_path} did not contain final_status; treating outcome as failed"
            ;;
        *)
            append_warning "Backlog task ${slug} exited 0 but manifest ${manifest_path} reported unknown final_status '${final_status}'; treating outcome as failed"
            backlog_log "WARN: ${slug} exited 0 but ${manifest_path} reported unknown final_status '${final_status}'; treating outcome as failed"
            ;;
    esac
}

backlog_status_line_paths() {
    local status_line="$1"
    local path_spec=""
    local old_path=""
    local new_path=""

    path_spec="${status_line:3}"
    path_spec="$(trim_whitespace "${path_spec}")"
    path_spec="${path_spec#\"}"
    path_spec="${path_spec%\"}"

    if [[ "${path_spec}" == *" -> "* ]]; then
        old_path="${path_spec%% -> *}"
        new_path="${path_spec##* -> }"
        old_path="${old_path#\"}"
        old_path="${old_path%\"}"
        new_path="${new_path#\"}"
        new_path="${new_path%\"}"
        printf '%s\n%s\n' "${old_path}" "${new_path}"
        return 0
    fi

    printf '%s\n' "${path_spec}"
}

backlog_capture_stage_paths() {
    local before_status="$1"
    local after_status="$2"
    local status_line=""
    local repo_path=""
    local abs_path=""

    while IFS= read -r status_line; do
        [[ -n "${status_line}" ]] || continue
        if printf '%s\n' "${before_status}" | grep -F -x -- "${status_line}" >/dev/null 2>&1; then
            continue
        fi

        while IFS= read -r repo_path; do
            [[ -n "${repo_path}" ]] || continue
            case "${repo_path}" in
                /*)
                    abs_path="${repo_path}"
                    ;;
                *)
                    abs_path="${REPO_ROOT}/${repo_path}"
                    ;;
            esac
            backlog_stage_path_add "${abs_path}"
        done < <(backlog_status_line_paths "${status_line}")
    done <<< "${after_status}"
}

append_backlog_digest_section() {
    local path="$1"
    local entry=""
    local task_path=""
    local slug=""
    local outcome=""
    local cost_delta=""

    [[ -f "${path}" ]] || return 0

    {
        printf '\n## Backlog Burndown\n'
        if (( ${#BACKLOG_RESULTS[@]} == 0 )); then
            printf -- '- (none)\n'
        else
            for entry in "${BACKLOG_RESULTS[@]}"; do
                IFS=$'\t' read -r task_path slug outcome cost_delta <<< "${entry}"
                printf -- '- `%s` | slug `%s` | outcome `%s` | cost delta `$%s`\n' \
                    "${task_path}" "${slug}" "${outcome}" "${cost_delta}"
            done
        fi
    } >> "${path}"
}

stage_path_has_changes() {
    local path="$1"
    local status_output=""

    [[ -e "${path}" ]] && return 0

    status_output="$(git status --porcelain -- "${path}" 2>/dev/null || true)"
    [[ -n "${status_output}" ]]
}

render_notes_markdown() {
    local notes="$1"
    if [[ -z "${notes}" ]]; then
        printf -- '- (none)\n'
        return 0
    fi
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        printf -- '- %s\n' "${line}"
    done <<< "${notes}"
}

write_fallback_digest() {
    local path="$1"
    local outcome_label="$2"
    local mode_label="$3"
    local cost_total=""
    cost_total="$(cost_total_value)"

    mkdir -p "$(dirname "${path}")"

    cat > "${path}" <<EOF
# Nightshift Detective Digest — ${RUN_DATE}

${NIGHTSHIFT_MANAGER_RUN_METADATA_HEADING}
- **Run ID:** ${RUN_ID}
- **Mode:** ${mode_label}
- **Outcome:** ${outcome_label}
- **Phase Reached:** ${CURRENT_PHASE}
- **Branch:** ${RUN_BRANCH:-not-created}

${NIGHTSHIFT_MANAGER_SUMMARY_HEADING}
- **Total findings received:** ${TOTAL_FINDINGS_AVAILABLE}
- **Task files created:** ${TASK_FILE_COUNT}
- **Total cost:** \$${cost_total}

## Warnings
$(render_notes_markdown "${WARNING_NOTES}")

## Failures
$(render_notes_markdown "${FAILURE_NOTES}")
EOF

    DIGEST_AVAILABLE=1
    DIGEST_PATH="${path}"
}

write_cost_cap_digest() {
    local path="$1"

    write_fallback_digest "${path}" "cost-cap-halted — no LLM synthesis" "live"

    local partial_count=0
    local partial_files=()
    if [[ -d "${RAW_FINDINGS_DIR}" ]]; then
        partial_files=("${RAW_FINDINGS_DIR}"/*-partial.md)
        partial_count=${#partial_files[@]}
    fi

    local findings_files=()
    local completed_findings_files=()
    findings_files=("${NIGHTSHIFT_FINDINGS_DIR}"/*-findings.md)
    local f=""
    if (( ${#findings_files[@]} > 0 )); then
        for f in "${findings_files[@]}"; do
            if [[ "$(count_findings_in_file "${f}")" -gt 0 ]]; then
                completed_findings_files+=("${f}")
            fi
        done
    fi
    local findings_file_count=${#completed_findings_files[@]}

    {
        printf '\n## Guardrail Details\n'
        printf -- '- **Guard fired:** cost cap ($%s limit)\n' "${NIGHTSHIFT_COST_CAP_USD}"
        printf -- '- **Detectives with completed findings:** %s\n' "${findings_file_count}"
        if (( partial_count > 0 )); then
            printf -- '- **Partial outputs omitted:** %s\n' "${partial_count}"
        fi
    } >> "${path}"

    {
        printf '\n## Raw Detective Findings\n\n'
        if (( findings_file_count == 0 )); then
            printf '_No completed detective findings available._\n'
        else
            for f in "${completed_findings_files[@]}"; do
                printf '### %s\n\n' "$(basename "${f}")"
                cat "${f}"
                printf '\n\n'
            done
        fi
    } >> "${path}"

    if [[ "${BRANCH_READY}" -eq 1 ]]; then
        DIGEST_STAGEABLE=1
    else
        DIGEST_STAGEABLE=0
    fi
}

append_orchestrator_summary() {
    local path="$1"
    local cost_total=""
    cost_total="$(cost_total_value)"

    {
        printf '\n%s\n' "${NIGHTSHIFT_MANAGER_ORCHESTRATOR_SUMMARY_HEADING}"
        printf -- '- **Run ID:** %s\n' "${RUN_ID}"
        printf -- '- **Branch:** %s\n' "${RUN_BRANCH:-not-created}"
        printf -- '- **Phase Reached:** %s\n' "${CURRENT_PHASE}"
        printf -- '- **Total findings received:** %s\n' "${TOTAL_FINDINGS_AVAILABLE}"
        printf -- '- **Task files created:** %s\n' "${TASK_FILE_COUNT}"
        printf -- '- **Total cost:** $%s\n' "${cost_total}"
        printf '\n%s\n' "${NIGHTSHIFT_MANAGER_ORCHESTRATOR_WARNINGS_HEADING}"
        render_notes_markdown "${WARNING_NOTES}"
        printf '\n%s\n' "${NIGHTSHIFT_MANAGER_ORCHESTRATOR_FAILURES_HEADING}"
        render_notes_markdown "${FAILURE_NOTES}"
    } >> "${path}"
}

update_digest_task_count() {
    local digest_path="$1"
    local task_file_count="$2"
    local digest_tmp=""

    [[ -n "${digest_path}" && -f "${digest_path}" ]] || return 0
    [[ -w "${digest_path}" ]] || return 0

    digest_tmp="$(mktemp "${digest_path}.XXXXXX")" || return 1

    if ! sed -E \
        -e "s/^(- \\*\\*Task files created:\\*\\* )[0-9]+( \\(critical: [0-9]+, major: [0-9]+\\))$/\\1${task_file_count}\\2/" \
        -e "s/^(- \\*\\*Task files created:\\*\\* )[0-9]+$/\\1${task_file_count}/" \
        -e "s/^(- \\*\\*Validated tasks:\\*\\* )[0-9]+$/\\1${VALIDATION_VALID_COUNT}/" \
        -e "s/^(- \\*\\*Invalid tasks:\\*\\* )[0-9]+$/\\1${VALIDATION_INVALID_COUNT}/" \
        "${digest_path}" > "${digest_tmp}"; then
        rm -f "${digest_tmp}"
        return 1
    fi

    if ! mv "${digest_tmp}" "${digest_path}"; then
        rm -f "${digest_tmp}"
        return 1
    fi
}

record_clean_digest() {
    local path="${RUN_TMP_DIR}/clean-digest.md"
    write_fallback_digest "${path}" "clean" "live"
}

record_dry_run_digest() {
    local path="${RUN_TMP_DIR}/dry-run-digest.md"
    write_fallback_digest "${path}" "clean" "dry-run"
}

playbook_requires_db() {
    local playbook_name="$1"
    case "${playbook_name}" in
        conversation-detective|error-detective|product-detective|rcfa-detective|performance-detective)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

canonical_findings_path() {
    local playbook_name="$1"
    printf '%s/%s-findings.md' "${NIGHTSHIFT_FINDINGS_DIR}" "${playbook_name}"
}

normalize_findings_stream() {
    local path="$1"
    awk '
        /^### Finding [0-9]+:/ {
            sub(/^### Finding [0-9]+:/, "### Finding:")
            print
            next
        }
        { print }
    ' "${path}"
}

detective_findings_count() {
    local playbook_name="$1"
    count_findings_in_file "$(canonical_findings_path "${playbook_name}")"
}

detective_severity_count() {
    local playbook_name="$1"
    local severity="$2"
    count_findings_by_severity_in_file "$(canonical_findings_path "${playbook_name}")" "${severity}"
}

detective_names_for_status() {
    local wanted_status="$1"
    local playbook_name=""
    local result=""

    for playbook_name in "${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}"; do
        if [[ "$(detective_status_value "${playbook_name}")" == "${wanted_status}" ]]; then
            if [[ -n "${result}" ]]; then
                result="${result}, "
            fi
            result="${result}${playbook_name}"
        fi
    done

    printf '%s' "${result:-(none)}"
}

render_detective_list_markdown() {
    local wanted_status="$1"
    local playbook_name=""
    local matched=0

    for playbook_name in "${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}"; do
        if [[ "$(detective_status_value "${playbook_name}")" == "${wanted_status}" ]]; then
            printf -- '- %s\n' "${playbook_name}"
            matched=1
        fi
    done

    if [[ "${matched}" -eq 0 ]]; then
        printf -- '- (none)\n'
    fi
}

repo_digest_path() {
    printf '%s/docs/nightshift/digests/%s%s.md' "${REPO_ROOT}" "${RUN_DATE}" "${RUN_SUFFIX:+-${RUN_SUFFIX}}"
}

archive_findings_if_present() {
    local agent_name="$1"
    local playbook_name="$2"
    local exit_code="${3:-0}"
    local canonical_path=""
    canonical_path="$(canonical_findings_path "${playbook_name}")"

    if [[ -f "${canonical_path}" ]]; then
        local raw_path=""
        if [[ "${exit_code}" -eq 0 ]]; then
            raw_path="${RAW_FINDINGS_DIR}/${agent_name}-${playbook_name}-findings.md"
        else
            raw_path="${RAW_FINDINGS_DIR}/${agent_name}-${playbook_name}-partial.md"
            append_warning "Preserved partial findings from failed ${agent_name}/${playbook_name} at ${raw_path}; manager merge will ignore this file"
        fi
        mv "${canonical_path}" "${raw_path}"
        ns_log "Archived findings: ${raw_path}"
    else
        ns_log "No findings file produced for ${agent_name}/${playbook_name}"
    fi
}

rebuild_manager_input_file() {
    local playbook_name="$1"
    local canonical_path=""
    local raw_matches=("${RAW_FINDINGS_DIR}"/*-"${playbook_name}"-findings.md)
    local raw_match_count=${#raw_matches[@]}
    local playbook_status=""
    local findings_count=0
    local raw_path=""

    playbook_status="$(detective_status_value "${playbook_name}")"
    if (( raw_match_count > 0 )) && [[ "${playbook_status}" != "ran" ]]; then
        playbook_status="ran"
        set_detective_status "${playbook_name}" "${playbook_status}"
    fi

    if (( raw_match_count > 0 )); then
        for raw_path in "${raw_matches[@]}"; do
            findings_count=$(( findings_count + $(count_findings_in_file "${raw_path}") ))
        done
    fi

    if (( findings_count > 0 )) && [[ "${playbook_status}" != "ran" ]]; then
        playbook_status="ran"
        set_detective_status "${playbook_name}" "${playbook_status}"
    fi

    canonical_path="$(canonical_findings_path "${playbook_name}")"
    rm -f "${canonical_path}"

    {
        printf '# Normalized %s Findings — %s\n\n' "${playbook_name}" "${RUN_DATE}"
        printf '## Detective: %s | status=%s | findings=%s\n\n' \
            "${playbook_name}" "${playbook_status}" "${findings_count}"

        if (( raw_match_count == 0 )); then
            if [[ "${playbook_status}" == "ran" ]]; then
                printf '_No findings reported._\n'
            else
                printf '_Detective skipped._\n'
            fi
        else
            for raw_path in "${raw_matches[@]}"; do
                local source_name=""
                source_name="$(basename "${raw_path}" "-${playbook_name}-findings.md")"
                printf '## Source: %s\n\n' "${source_name}"
                normalize_findings_stream "${raw_path}"
                printf '\n\n'
            done
        fi
    } > "${canonical_path}"
}

rebuild_manager_inputs() {
    local playbook_name=""

    local existing_entries=("${NIGHTSHIFT_FINDINGS_DIR}"/*)
    if (( ${#existing_entries[@]} > 0 )); then
        rm -f "${existing_entries[@]}"
    fi

    for playbook_name in "${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}"; do
        rebuild_manager_input_file "${playbook_name}"
    done
}

count_markdown_table_rows_in_section() {
    local path="$1"
    local heading="$2"
    if [[ ! -f "${path}" ]]; then
        echo "0"
        return 0
    fi

    awk -v heading="${heading}" '
        $0 == heading {
            in_section=1
            next
        }
        in_section && /^## / {
            exit
        }
        in_section && /^\|/ {
            if ($0 ~ /^\|[[:space:]:-]+\|([[:space:]:|-]+)?$/) {
                next
            }
            if (!header_seen) {
                header_seen=1
                next
            }
            count++
        }
        END { print count + 0 }
    ' "${path}"
}

count_task_table_rows_by_severity() {
    local path="$1"
    local severity="$2"
    local heading="$3"
    if [[ ! -f "${path}" ]]; then
        echo "0"
        return 0
    fi

    awk -v severity="${severity}" -v heading="${heading}" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function lower_trim(value) {
            value = trim(value)
            return tolower(value)
        }
        $0 == heading {
            in_section=1
            next
        }
        in_section && /^## / {
            exit
        }
        in_section && /^\|/ {
            if ($0 ~ /^\|[[:space:]:-]+\|([[:space:]:|-]+)?$/) {
                next
            }
            if (!header_seen) {
                field_count = split($0, columns, "|")
                for (i = 1; i <= field_count; i++) {
                    if (lower_trim(columns[i]) == "severity") {
                        severity_col = i
                    }
                }
                if (severity_col > 0) {
                    header_seen=1
                }
                next
            }
            split($0, columns, "|")
            if (severity_col > 0 && trim(columns[severity_col]) == severity) {
                count++
            }
        }
        END { print count + 0 }
    ' "${path}"
}

manager_digest_body_without_shell_sections() {
    local path="$1"
    local shell_headings=""
    local shell_heading_delimiter=$'\034'
    shell_headings="$(printf '%s%s' "${NIGHTSHIFT_MANAGER_SHELL_OWNED_HEADINGS[@]/%/${shell_heading_delimiter}}")"

    awk -v shell_headings="${shell_headings}" -v shell_heading_delimiter="${shell_heading_delimiter}" '
        BEGIN {
            skip=0
            split(shell_headings, shell_heading_lines, shell_heading_delimiter)
            for (i in shell_heading_lines) {
                if (shell_heading_lines[i] != "") {
                    shell_heading_lookup[shell_heading_lines[i]] = 1
                }
            }
        }
        NR == 1 && /^# / {
            next
        }
        /^## / {
            skip = ($0 in shell_heading_lookup)
        }
        !skip {
            print
        }
    ' "${path}"
}

render_detective_coverage_section() {
    local playbook_name=""
    local playbook_status=""
    local playbook_findings=0
    local critical_count=0
    local major_count=0
    local minor_count=0
    local observation_count=0
    local total_findings=0
    local total_critical=0
    local total_major=0
    local total_minor=0
    local total_observation=0
    local ran_count=0
    local skipped_count=0

    printf '%s\n\n' "${NIGHTSHIFT_MANAGER_DETECTIVE_COVERAGE_HEADING}"
    printf '| Detective | Status | Findings Received | Critical | Major | Minor | Observation |\n'
    printf '|----------|--------|------------------:|---------:|------:|------:|------------:|\n'

    for playbook_name in "${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}"; do
        playbook_status="$(detective_status_value "${playbook_name}")"
        playbook_findings="$(detective_findings_count "${playbook_name}")"
        critical_count="$(detective_severity_count "${playbook_name}" "critical")"
        major_count="$(detective_severity_count "${playbook_name}" "major")"
        minor_count="$(detective_severity_count "${playbook_name}" "minor")"
        observation_count="$(detective_severity_count "${playbook_name}" "observation")"

        if [[ "${playbook_status}" == "ran" ]]; then
            ran_count=$(( ran_count + 1 ))
        else
            skipped_count=$(( skipped_count + 1 ))
        fi

        total_findings=$(( total_findings + playbook_findings ))
        total_critical=$(( total_critical + critical_count ))
        total_major=$(( total_major + major_count ))
        total_minor=$(( total_minor + minor_count ))
        total_observation=$(( total_observation + observation_count ))

        printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
            "${playbook_name}" \
            "${playbook_status}" \
            "${playbook_findings}" \
            "${critical_count}" \
            "${major_count}" \
            "${minor_count}" \
            "${observation_count}"
    done

    printf '| **Total** | **%s ran / %s skipped** | **%s** | **%s** | **%s** | **%s** | **%s** |\n' \
        "${ran_count}" \
        "${skipped_count}" \
        "${total_findings}" \
        "${total_critical}" \
        "${total_major}" \
        "${total_minor}" \
        "${total_observation}"
}

rewrite_manager_digest() {
    local path="$1"
    local normalized_path="${path}.normalized"
    local task_rows=0
    local minor_rows=0
    local after_dedup=0
    local duplicates_merged=0
    local critical_tasks=0
    local major_tasks=0
    local eligible_findings=0

    [[ -f "${path}" ]] || return 0

    task_rows="$(count_markdown_table_rows_in_section "${path}" "${NIGHTSHIFT_MANAGER_TASK_FILES_HEADING}")"
    minor_rows="$(count_markdown_table_rows_in_section "${path}" "${NIGHTSHIFT_MANAGER_MINOR_FINDINGS_HEADING}")"
    critical_tasks="$(count_task_table_rows_by_severity "${path}" "critical" "${NIGHTSHIFT_MANAGER_TASK_FILES_HEADING}")"
    major_tasks="$(count_task_table_rows_by_severity "${path}" "major" "${NIGHTSHIFT_MANAGER_TASK_FILES_HEADING}")"
    eligible_findings="${FINDINGS_ELIGIBLE_FOR_RANKING:-${TOTAL_FINDINGS_AVAILABLE}}"

    after_dedup=$(( task_rows + minor_rows ))
    duplicates_merged=$(( eligible_findings - after_dedup ))
    if (( duplicates_merged < 0 )); then
        duplicates_merged=0
    fi

    {
        printf '# Nightshift Detective Digest — %s\n\n' "${RUN_DATE}"
        printf '%s\n' "${NIGHTSHIFT_MANAGER_RUN_METADATA_HEADING}"
        printf -- '- **Run ID:** %s\n' "${RUN_ID}"
        printf -- '- **Date:** %s\n' "${RUN_DATE}"
        printf -- '- **Detectives Run:** %s\n' "$(detective_names_for_status "ran")"

        printf '\n%s\n' "${NIGHTSHIFT_MANAGER_SUMMARY_HEADING}"
        printf -- '- **Total findings received:** %s\n' "${TOTAL_FINDINGS_AVAILABLE}"
        printf -- '- **Eligible after suppression:** %s\n' "${eligible_findings}"
        printf -- '- **After deduplication:** %s\n' "${after_dedup}"
        printf -- '- **Duplicates merged:** %s\n' "${duplicates_merged}"
        printf -- '- **Ranked:** %s (%s suppressed)\n' "${task_rows}" "${SUPPRESSED_FINDINGS_COUNT:-0}"
        printf -- '- **Task files created:** %s (critical: %s, major: %s)\n' \
            "${TASK_FILE_COUNT}" "${critical_tasks}" "${major_tasks}"
        printf -- '- **Minor/observation findings:** %s (see digest below)\n' "${minor_rows}"

        printf '\n'
        manager_digest_body_without_shell_sections "${path}"
        if declare -F nightshift_render_suppression_sections >/dev/null 2>&1; then
            local suppression_sections=""
            suppression_sections="$(nightshift_render_suppression_sections)"
            if [[ -n "${suppression_sections}" ]]; then
                printf '\n\n%s\n' "${suppression_sections}"
            fi
        fi
        printf '\n'
        render_detective_coverage_section
        printf '\n%s\n' "${NIGHTSHIFT_MANAGER_DETECTIVES_SKIPPED_HEADING}"
        render_detective_list_markdown "skipped"
    } > "${normalized_path}"

    mv "${normalized_path}" "${path}"
}

cost_guard_after_call() {
    if [[ "${COST_TRACKING_READY}" -eq 0 ]]; then
        return 0
    fi

    if ! cost_check_cap; then
        RUN_COST_CAP=1
        ns_log "Cost cap reached during ${CURRENT_PHASE}"
        return 1
    fi

    if ! cost_check_runaway; then
        RUN_COST_CAP=1
        ns_log "Runaway cost pattern detected during ${CURRENT_PHASE}"
        return 1
    fi

    return 0
}

patch_digest_task_count_if_needed() {
    local digest_path="${1:-${DIGEST_PATH:-}}"

    if [[ "${DIGEST_TASK_COUNT_PATCHED:-0}" -eq 1 ]]; then
        return 0
    fi

    [[ -n "${digest_path}" && -r "${digest_path}" ]] || return 0

    if ! update_digest_task_count "${digest_path}" "${TASK_FILE_COUNT}"; then
        return 1
    fi

    DIGEST_TASK_COUNT_PATCHED=1
    return 0
}

detective_output_path() {
    local agent_name="$1"
    local playbook_name="$2"
    printf '%s/%s-%s.json' "${AGENT_OUTPUT_DIR}" "${agent_name}" "${playbook_name}"
}

run_detective_call() {
    local agent_name="$1"
    local playbook_path="$2"
    local playbook_name=""
    local output_path=""
    local exit_code=0

    playbook_name="$(basename "${playbook_path}" .md)"
    output_path="$(detective_output_path "${agent_name}" "${playbook_name}")"

    if playbook_requires_db "${playbook_name}" && [[ "${DB_PLAYBOOKS_ENABLED}" -eq 0 ]]; then
        append_warning "Skipping ${agent_name}/${playbook_name}: database safety preflight did not pass"
        return 0
    fi

    set_detective_status "${playbook_name}" "ran"
    rm -f "$(canonical_findings_path "${playbook_name}")"
    rm -f "${output_path}"

    if [[ "${agent_name}" == "claude" ]]; then
        if [[ "${CLAUDE_AVAILABLE}" -eq 0 ]]; then
            append_failure "Skipping Claude ${playbook_name}: claude CLI is unavailable"
            return 1
        fi

        if agent_run_claude "${playbook_path}" "${output_path}"; then
            exit_code=0
        else
            exit_code=$?
            append_failure "Claude ${playbook_name} failed with exit ${exit_code}"
        fi
    else
        local codex_mode_before="${CODEX_MODE}"
        if [[ "${CODEX_MODE}" == "disabled" ]]; then
            ns_log "Skipping codex/${playbook_name}: NIGHTSHIFT_CODEX_MODEL is empty"
            return 0
        fi

        if [[ "${CODEX_MODE}" == "closed" ]]; then
            ns_log "Skipping codex/${playbook_name}: Codex unavailable, proceeding Claude-only"
            return 0
        fi

        CODEX_ATTEMPT_COUNT=$((CODEX_ATTEMPT_COUNT + 1))

        if agent_run_codex "${playbook_path}" "${output_path}"; then
            if [[ -f "${output_path}" && -s "${output_path}" ]]; then
                exit_code=0
                if [[ "${CODEX_MODE}" == "pending" ]]; then
                    CODEX_MODE="open"
                    ns_log "Codex available: first Codex call succeeded"
                fi
            else
                exit_code=1
                CODEX_MODE="closed"
                append_warning "Codex ${playbook_name} exited 0 but no output — closing gate"
            fi
        else
            exit_code=$?
            CODEX_MODE="closed"
            if [[ "${codex_mode_before}" == "pending" ]]; then
                CODEX_MODE="closed"
                append_warning "Codex ${playbook_name} failed with exit ${exit_code} — closing gate before Claude-only fallback"
            else
                append_warning "Codex ${playbook_name} failed with exit ${exit_code} — closing gate"
            fi
        fi
    fi

    archive_findings_if_present "${agent_name}" "${playbook_name}" "${exit_code}"

    if ! cost_guard_after_call; then
        return 1
    fi

    return "${exit_code}"
}

check_total_timeout() {
    if [[ -z "${NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS:-}" ]]; then
        return 0
    fi

    local started_at="${TOTAL_START_EPOCH:-0}"
    if [[ "${started_at}" -le 0 ]]; then
        return 0
    fi

    local now elapsed
    now="$(date +%s)"
    elapsed=$(( now - started_at ))

    if (( elapsed >= NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS )); then
        append_failure "Total runtime exceeded ${NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS}s during ${CURRENT_PHASE}"
        return 1
    fi

    return 0
}

check_disk_space() {
    local df_output=""
    local available_kb=""
    local available_mb=0

    df_output="$(df -Pk "${NIGHTSHIFT_REPO_DIR}" 2>/dev/null || true)"
    available_kb="$(printf '%s\n' "$df_output" | awk 'NR == 2 { print $4 }')"

    if ! [[ "${available_kb}" =~ ^[0-9]+$ ]]; then
        append_warning "Could not determine disk space for ${NIGHTSHIFT_REPO_DIR}; continuing"
        return 0
    fi

    available_mb=$(( available_kb / 1024 ))
    if (( available_mb < NIGHTSHIFT_MIN_FREE_MB )); then
        ns_log "Disk space low: ${available_mb}MB available (threshold ${NIGHTSHIFT_MIN_FREE_MB}MB)"
        return 1
    fi

    ns_log "Disk space OK: ${available_mb}MB available (threshold ${NIGHTSHIFT_MIN_FREE_MB}MB)"
    return 0
}

file_mode() {
    local path="$1"
    local mode=""

    if mode="$(stat -f '%Lp' "${path}" 2>/dev/null)"; then
        printf '%s\n' "${mode}"
        return 0
    fi

    if mode="$(stat -c '%a' "${path}" 2>/dev/null)"; then
        printf '%s\n' "${mode}"
        return 0
    fi

    return 1
}

file_owner_name() {
    local path="$1"
    local owner=""

    if owner="$(stat -f '%Su' "${path}" 2>/dev/null)"; then
        printf '%s\n' "${owner}"
        return 0
    fi

    if owner="$(stat -c '%U' "${path}" 2>/dev/null)"; then
        printf '%s\n' "${owner}"
        return 0
    fi

    return 1
}

validate_env_file_preflight() {
    local path="${1:-${ENV_FILE}}"
    local mode=""
    local owner=""
    local expected_owner=""

    if [[ ! -e "${path}" ]]; then
        append_warning "Secrets file not found: ${path}; continuing with existing environment"
        return 0
    fi

    if [[ ! -f "${path}" ]]; then
        append_warning "Secrets path is not a regular file: ${path}; aborting"
        return 1
    fi

    if ! mode="$(file_mode "${path}")"; then
        append_warning "Could not determine permissions for secrets file: ${path}; aborting"
        return 1
    fi

    if [[ "${mode}" != "600" ]]; then
        append_warning "Secrets file ${path} has insecure permissions ${mode}; expected 600 and aborting"
        return 1
    fi

    expected_owner="$(id -un)"
    if owner="$(file_owner_name "${path}")"; then
        if [[ "${owner}" != "${expected_owner}" ]]; then
            append_warning "Secrets file ${path} is owned by ${owner}; expected ${expected_owner} and aborting"
            return 1
        fi
        ns_log "Secrets file ownership OK: ${path} (${owner})"
    else
        append_warning "Could not determine owner for secrets file: ${path}; aborting"
        return 1
    fi

    ns_log "Secrets file permissions OK: ${path} (${mode})"
    return 0
}

phase_setup() {
    phase_start "1" "Setup"
    local prior_run_cleanup_output=""
    local branch_creation_allowed=0

    if [[ -n "${PHASE_ONLY}" ]]; then
        ns_log "Phase-only mode requested for phase ${PHASE_ONLY} (marker only in Task 03C)"
    fi

    if ! cd "${NIGHTSHIFT_REPO_DIR}"; then
        append_failure "Cannot cd to repo root: ${NIGHTSHIFT_REPO_DIR}"
        phase_end "1" "Setup" "FAILED"
        return 0
    fi

    ORIGINAL_REF="$(current_ref_name)"
    ns_log "Starting from ref: ${ORIGINAL_REF}"
    record_bootstrap_runtime_warnings

    if ! check_disk_space; then
        append_failure "Disk space below ${NIGHTSHIFT_MIN_FREE_MB}MB threshold"
        SETUP_FAILED=1
        phase_end "1" "Setup" "FAILED"
        return 0
    fi

    if cost_init "${NIGHTSHIFT_RUN_ID}"; then
        COST_TRACKING_READY=1
    else
        append_failure "cost_init failed"
    fi

    if [[ -n "${NIGHTSHIFT_CODEX_MODEL:-}" ]]; then
        CODEX_MODE="pending"
    else
        CODEX_MODE="disabled"
    fi

    if ! validate_env_file_preflight "${ENV_FILE}"; then
        append_failure "Secrets file preflight failed for ${ENV_FILE}"
        SETUP_FAILED=1
        phase_end "1" "Setup" "FAILED"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        append_failure "git is not available"
        phase_end "1" "Setup" "FAILED"
        return 0
    fi

    prior_run_cleanup_output="$(git clean -fd docs/nightshift/digests/ docs/tasks/open/nightshift/ 2>/dev/null || true)"
    if [[ -n "${prior_run_cleanup_output}" ]]; then
        ns_log "INFO: Night Shift: cleaned prior-run artifacts from worktree"
    fi
    prune_local_nightshift_branches "phase_setup pre-run cleanup"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        SETUP_READY=1
        phase_end "1" "Setup" "OK"
        return 0
    fi

    if ! command -v claude >/dev/null 2>&1; then
        CLAUDE_AVAILABLE=0
        append_failure "claude CLI is not available"
    fi

    if command -v gh >/dev/null 2>&1; then
        GH_AVAILABLE=1
    else
        append_warning "gh CLI is not available"
    fi

    if ! check_total_timeout; then
        phase_end "1" "Setup" "FAILED"
        return 0
    fi

    if ! working_tree_is_clean; then
        append_warning "Working tree dirty at startup — resetting to match HEAD"
        { git checkout -- . && git clean -fd; } 2>/dev/null || true
        if ! working_tree_is_clean; then append_failure "Working tree dirty after reset; refusing to proceed"; phase_end "1" "Setup" "FAILED"; return 0; fi
    fi

    if declare -F git_safety_preflight >/dev/null 2>&1; then
        if git_safety_preflight; then
            PUSH_ALLOWED=1
            branch_creation_allowed=1
        elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            append_warning "git_safety_preflight failed; continuing with local branch creation from current checkout and best-effort shipping"
            branch_creation_allowed=1
        else
            append_failure "git_safety_preflight failed"
        fi
    else
        append_failure "git_safety_preflight is unavailable"
    fi

    if [[ "${branch_creation_allowed}" -eq 1 ]]; then
        local branch_name=""
        local branch_token="${RUN_DATE}"
        if smoke_mode_enabled; then
            branch_token="smoke-${RUN_DATE}-${RUN_CLOCK}"
        fi

        if branch_name="$(git_create_branch "${branch_token}")"; then
            RUN_BRANCH="${branch_name}"
            update_run_suffix_from_branch "${RUN_BRANCH}"
            BRANCH_READY=1
            MANAGER_ALLOWED=1
            PUSH_ALLOWED=1
            PR_ALLOWED="${GH_AVAILABLE}"
            ns_log "Nightshift branch ready: ${RUN_BRANCH}"
        else
            append_failure "git_create_branch failed for ${branch_token}"
            MANAGER_ALLOWED=0
            PUSH_ALLOWED=0
        fi
    fi

    if [[ -n "${RUN_BRANCH}" ]] && declare -F git_validate_branch >/dev/null 2>&1; then
        if ! git_validate_branch "${RUN_BRANCH}"; then
            append_failure "git_validate_branch rejected ${RUN_BRANCH}"
            MANAGER_ALLOWED=0
            PUSH_ALLOWED=0
            BRANCH_READY=0
        fi
    fi

    if [[ "${BRANCH_READY}" -eq 0 && "${DRY_RUN}" -eq 0 ]]; then
        SETUP_FAILED=1
        ns_log "SETUP_FAILED: no writable branch after git operations; Phases 2-3 will be skipped"
    fi

    if declare -F db_safety_preflight >/dev/null 2>&1; then
        if ! db_safety_preflight; then
            DB_PLAYBOOKS_ENABLED=0
            append_warning "Database safety preflight failed; DB-backed playbooks will be skipped"
        fi
    else
        DB_PLAYBOOKS_ENABLED=0
        append_warning "db_safety_preflight is unavailable; DB-backed playbooks will be skipped"
    fi

    if [[ "${CLAUDE_AVAILABLE}" -eq 0 ]]; then
        MANAGER_ALLOWED=0
        PR_ALLOWED=0
    fi

    SETUP_READY=1
    phase_end "1" "Setup" "OK"
}

phase_detectives() {
    phase_start "2" "Detective Runs"
    local playbooks_dir="${NIGHTSHIFT_PLAYBOOKS_DIR}"
    local agent_name=""
    local playbook_name=""
    local playbook_path=""
    local active_playbooks=("${NIGHTSHIFT_DETECTIVE_PLAYBOOKS[@]}")

    if smoke_mode_enabled; then
        active_playbooks=("commit-detective")
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        for playbook_name in "${active_playbooks[@]}"; do
            for agent_name in "${NIGHTSHIFT_DETECTIVE_ENGINES[@]}"; do
                ns_log "Dry-run detective schedule: ${agent_name}/${playbook_name}"
            done
        done
        ns_log "Dry-run enabled: skipping all detective agent calls"
        phase_end "2" "Detective Runs" "SKIPPED"
        return 0
    fi

    if [[ "${SETUP_FAILED:-0}" -eq 1 ]]; then
        ns_log "ABORT: Setup failed — no writable branch, skipping all detective calls"
        RUN_FAILED=1
        phase_end "2" "Detective Runs" "SKIPPED"
        return 0
    fi

    if [[ "${SETUP_READY}" -eq 0 ]]; then
        append_failure "Phase 2 skipped because setup did not complete"
        phase_end "2" "Detective Runs" "SKIPPED"
        return 0
    fi

    if [[ "${CLAUDE_AVAILABLE}" -eq 0 ]]; then
        append_failure "Phase 2 skipped because Claude is unavailable"
        phase_end "2" "Detective Runs" "SKIPPED"
        return 0
    fi

    if ! check_total_timeout; then
        phase_end "2" "Detective Runs" "FAILED"
        return 0
    fi

    reset_detective_statuses

    # Keep the fixed playbook-first detective order explicit for maintainers and grep-based checks:
    # commit-detective.md, conversation-detective.md, coverage-detective.md,
    # error-detective.md, product-detective.md, rcfa-detective.md;
    # each playbook runs claude first, then codex.
    for playbook_name in "${active_playbooks[@]}"; do
        for agent_name in "${NIGHTSHIFT_DETECTIVE_ENGINES[@]}"; do
            playbook_path="${playbooks_dir}/${playbook_name}.md"
            run_detective_call "${agent_name}" "${playbook_path}" || true
            if [[ "${RUN_COST_CAP}" -eq 1 ]]; then
                phase_end "2" "Detective Runs" "HALTED"
                return 0
            fi
        done
    done

    phase_end "2" "Detective Runs" "OK"
}

phase_manager_merge() {
    phase_start "3" "Manager Merge"

    local stageable_repo_digest=""
    local missing_headings=()
    local missing_heading=""
    local drift_failure_note=""
    local missing_heading_summary=""
    local top_findings_count=0
    local manager_exit=0
    local manager_completed=0
    local manager_result_preview=""
    stageable_repo_digest="$(repo_digest_path)"
    MANAGER_CONTRACT_FAILED=0
    DIGEST_TASK_COUNT_PATCHED=0

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        TOTAL_FINDINGS_AVAILABLE=0
        TASK_FILE_COUNT=0
        record_dry_run_digest
        RUN_CLEAN=1
        phase_end "3" "Manager Merge" "SKIPPED"
        return 0
    fi

    if [[ "${SETUP_FAILED:-0}" -eq 1 ]]; then
        ns_log "ABORT: Setup failed — no writable branch, skipping manager merge"
        write_fallback_digest "${RUN_TMP_DIR}/setup-failed-digest.md" "setup-failed" "live"
        DIGEST_STAGEABLE=0
        phase_end "3" "Manager Merge" "SKIPPED"
        return 0
    fi

    rebuild_manager_inputs
    TOTAL_FINDINGS_AVAILABLE="$(count_total_findings)"
    FINDINGS_ELIGIBLE_FOR_RANKING="${TOTAL_FINDINGS_AVAILABLE}"
    SUPPRESSED_FINDINGS_COUNT=0
    if declare -F nightshift_apply_suppressions >/dev/null 2>&1; then
        nightshift_apply_suppressions || true
    fi
    ns_log "Total detective findings available for manager merge: ${TOTAL_FINDINGS_AVAILABLE}"

    if ! check_total_timeout; then
        if [[ "${BRANCH_READY}" -eq 1 ]]; then
            ensure_repo_output_dirs
            write_fallback_digest "${stageable_repo_digest}" "failed" "live"
            DIGEST_STAGEABLE=1
        else
            DIGEST_STAGEABLE=0
            write_fallback_digest "${RUN_TMP_DIR}/timeout-digest.md" "failed" "live"
        fi
        phase_end "3" "Manager Merge" "FAILED"
        return 0
    fi

    if [[ "${TOTAL_FINDINGS_AVAILABLE}" -eq 0 ]]; then
        TASK_FILE_COUNT=0
        if [[ "${RUN_FAILED}" -eq 0 ]]; then
            DIGEST_STAGEABLE=0
            record_clean_digest
            RUN_CLEAN=1
            phase_end "3" "Manager Merge" "CLEAN"
        else
            if [[ "${BRANCH_READY}" -eq 1 ]]; then
                ensure_repo_output_dirs
                write_fallback_digest "${stageable_repo_digest}" "failed" "live"
                DIGEST_STAGEABLE=1
            else
                DIGEST_STAGEABLE=0
                write_fallback_digest "${RUN_TMP_DIR}/failed-empty-findings-digest.md" "failed" "live"
            fi
            phase_end "3" "Manager Merge" "FAILED"
        fi
        return 0
    fi

    if [[ "${MANAGER_ALLOWED}" -eq 0 || "${BRANCH_READY}" -eq 0 ]]; then
        append_failure "Manager merge skipped because a writable nightshift branch is not available"
        write_fallback_digest "${RUN_TMP_DIR}/manager-skipped-digest.md" "failed" "live"
        DIGEST_STAGEABLE=0
        phase_end "3" "Manager Merge" "FAILED"
        return 0
    fi

    ensure_repo_output_dirs

    local manager_output="${AGENT_OUTPUT_DIR}/manager-merge.json"
    local manager_playbook="${NIGHTSHIFT_PLAYBOOKS_DIR}/manager-merge.md"

    DIGEST_PATH="${stageable_repo_digest}"

    if [[ "${RUN_COST_CAP}" -eq 1 ]]; then
        ns_log "Cost cap reached before manager merge — skipping Claude call, building fallback digest"
        write_cost_cap_digest "${DIGEST_PATH}"
        TASK_FILE_COUNT=0
        phase_end "3" "Manager Merge" "HALTED"
        return 0
    fi

    if [[ "${FINDINGS_ELIGIBLE_FOR_RANKING}" -eq 0 ]]; then
        nightshift_write_empty_manager_digest_body "${DIGEST_PATH}"
        manager_completed=1
        ns_log "Manager merge skipped because only suppressed findings remained"
    else
        if agent_run_claude "${manager_playbook}" "${manager_output}" "${NIGHTSHIFT_MANAGER_MODEL}"; then
            manager_completed=1
            ns_log "Manager merge completed"
        else
            manager_exit=$?
            append_failure "Manager merge failed with exit ${manager_exit}"
        fi
    fi

    manager_result_preview="$(agent_output_preview "${manager_output}" 160 2>/dev/null || true)"

    if ! cost_guard_after_call; then
        phase_end "3" "Manager Merge" "HALTED"
        return 0
    fi

    TASK_FILE_COUNT="$(count_task_files)"

    if [[ ! -s "${DIGEST_PATH}" ]]; then
        DIGEST_AVAILABLE=0
        DIGEST_STAGEABLE=0
        MANAGER_CONTRACT_FAILED=1
        if [[ "${manager_completed}" -eq 1 ]]; then
            append_failure "Manager contract failure: exit 0 but no digest artifact"
        elif [[ "${TOTAL_FINDINGS_AVAILABLE}" -gt 0 ]]; then
            append_failure "Manager contract failure: findings available but no digest artifact"
        fi
        if [[ -n "${manager_result_preview}" ]]; then
            append_failure "Manager merge output preview: ${manager_result_preview}"
        fi
        phase_end "3" "Manager Merge" "FAILED"
        return 0
    fi

    DIGEST_AVAILABLE=1
    DIGEST_STAGEABLE=1
    for missing_heading in "${NIGHTSHIFT_MANAGER_REQUIRED_BODY_HEADINGS[@]}"; do
        if ! grep -Fqx -- "${missing_heading}" "${DIGEST_PATH}"; then
            missing_headings+=("${missing_heading}")
        fi
    done

    if (( ${#missing_headings[@]} > 0 )); then
        drift_failure_note="Manager digest format drift detected; raw manager output preserved"
        missing_heading_summary=""
        for missing_heading in "${missing_headings[@]}"; do
            ns_log "WARN: manager digest format drift — expected heading '${missing_heading}' not found"
            if [[ -n "${missing_heading_summary}" ]]; then
                missing_heading_summary="${missing_heading_summary}, "
            fi
            missing_heading_summary="${missing_heading_summary}${missing_heading}"
        done
        record_failure_note "${drift_failure_note} (missing headings: ${missing_heading_summary})"
        DIGEST_STAGEABLE=0
        MANAGER_CONTRACT_FAILED=1
        phase_end "3" "Manager Merge" "FAILED"
        return 0
    fi

    top_findings_count="$(count_top_findings_in_digest "${DIGEST_PATH}")"
    local minor_findings_count=0
    minor_findings_count="$(count_markdown_table_rows_in_section "${DIGEST_PATH}" "${NIGHTSHIFT_MANAGER_MINOR_FINDINGS_HEADING}")"
    if [[ "${FINDINGS_ELIGIBLE_FOR_RANKING}" -gt 0 && $(( top_findings_count + minor_findings_count )) -eq 0 ]]; then
        append_failure "Manager contract failure: findings available after suppression but digest has empty ranked findings table"
        DIGEST_STAGEABLE=0
        MANAGER_CONTRACT_FAILED=1
        phase_end "3" "Manager Merge" "FAILED"
        return 0
    fi

    rewrite_manager_digest "${DIGEST_PATH}"
    if declare -F nightshift_annotate_digest_with_fingerprints >/dev/null 2>&1; then
        nightshift_annotate_digest_with_fingerprints "${DIGEST_PATH}" || true
    fi

    if ! write_findings_manifest "${DIGEST_PATH}"; then
        append_failure "Findings manifest write failed: $(findings_manifest_path)"
        DIGEST_STAGEABLE=0
        MANAGER_CONTRACT_FAILED=1
        phase_end "3" "Manager Merge" "FAILED"
        return 0
    fi

    append_orchestrator_summary "${DIGEST_PATH}"

    phase_end "3" "Manager Merge" "OK"
}

phase_task_writing() {
    phase_start "3.5a" "Task Writing"

    CREATED_TASKS=()
    NIGHTSHIFT_FINDING_TEXT=""
    TASK_FILE_COUNT=0

    if [[ "${SETUP_FAILED:-0}" -eq 1 ]]; then
        ns_log "Task writing skipped because setup did not complete"
        phase_end "3.5a" "Task Writing" "SKIPPED"
        return 0
    fi

    if [[ "${MANAGER_CONTRACT_FAILED:-0}" -eq 1 ]]; then
        ns_log "Task writing skipped because manager contract failed"
        phase_end "3.5a" "Task Writing" "SKIPPED"
        return 0
    fi

    if [[ "${RUN_COST_CAP:-0}" -eq 1 ]]; then
        ns_log "Task writing skipped because the run is already cost-capped"
        phase_end "3.5a" "Task Writing" "SKIPPED"
        return 0
    fi

    if ! ensure_task_context_helpers; then
        phase_end "3.5a" "Task Writing" "FAILED"
        return 0
    fi

    local findings_manifest_path_value=""
    local task_writer_playbook="${NIGHTSHIFT_PLAYBOOKS_DIR}/task-writer.md"
    findings_manifest_path_value="$(findings_manifest_path)"

    if [[ ! -s "${findings_manifest_path_value}" ]]; then
        ns_log "Task writing: 0 findings to process"
        if ! write_manager_task_manifest; then
            append_failure "Task writing manifest write failed: $(manager_task_manifest_path)"
            phase_end "3.5a" "Task Writing" "FAILED"
            return 0
        fi
        phase_end "3.5a" "Task Writing" "OK"
        return 0
    fi

    if [[ ! -r "${task_writer_playbook}" ]]; then
        append_failure "Task writer playbook missing or unreadable: ${task_writer_playbook}"
        phase_end "3.5a" "Task Writing" "FAILED"
        return 0
    fi

    local eligible_entries=()
    local findings_row=""
    local rank=""
    local severity=""
    local category=""
    local title=""
    local total_findings=0
    local created_count=0
    local rejected_count=0
    local failed_count=0
    local severity_skipped=0
    local cap_skipped=0
    local budget_skipped=0
    local task_limit=0
    local max_tasks=""
    local min_budget=""
    local attempt_count=0
    local remaining_budget="0.0000"
    local phase_result="OK"
    local task_writer_output=""
    local task_writer_text=""
    local result_line=""
    local result_status=""
    local rejection_reason=""
    local task_block=""
    local task_slug=""
    local task_path=""
    local task_writer_exit=0
    local existing_open_tasks_context=""

    max_tasks="$(task_writer_max_tasks_setting)"
    min_budget="$(task_writer_min_budget_setting)"
    existing_open_tasks_context="$(task_context_existing_open_tasks_block)"

    if smoke_mode_enabled && (( max_tasks > 1 )); then
        max_tasks=1
        ns_log "Smoke mode: capping task writing to 1 task"
    fi

    while IFS= read -r findings_row; do
        [[ -n "${findings_row}" ]] || continue
        total_findings=$(( total_findings + 1 ))
        IFS=$'\t' read -r rank severity category title <<< "${findings_row}"
        if [[ -z "${rank}" || -z "${severity}" || -z "${category}" || -z "${title}" ]]; then
            ns_log "WARN: Task writing skipped malformed findings row: ${findings_row}"
            severity_skipped=$(( severity_skipped + 1 ))
            continue
        fi

        severity="$(printf '%s' "${severity}" | tr '[:upper:]' '[:lower:]')"
        if ! task_writer_allowed_severity "${severity}"; then
            severity_skipped=$(( severity_skipped + 1 ))
            continue
        fi

        eligible_entries+=("${rank}"$'\t'"${severity}"$'\t'"${category}"$'\t'"${title}")
    done < "${findings_manifest_path_value}"

    task_limit="${#eligible_entries[@]}"
    if (( task_limit > max_tasks )); then
        cap_skipped=$(( task_limit - max_tasks ))
        task_limit="${max_tasks}"
    fi

    for findings_row in "${eligible_entries[@]-}"; do
        [[ -n "${findings_row}" ]] || continue
        if (( attempt_count >= task_limit )); then
            break
        fi

        remaining_budget="$(autofix_remaining_budget "0.0000")"
        if awk -v remaining="${remaining_budget}" -v minimum="${min_budget}" '
            BEGIN {
                if (remaining < minimum) {
                    exit 0
                }
                exit 1
            }
        '; then
            budget_skipped=$(( budget_skipped + task_limit - attempt_count ))
            ns_log "Task writing: insufficient budget remaining (\$${remaining_budget} of \$${min_budget} needed)"
            break
        fi

        IFS=$'\t' read -r rank severity category title <<< "${findings_row}"
        attempt_count=$(( attempt_count + 1 ))

        export NIGHTSHIFT_FINDING_TEXT
        NIGHTSHIFT_FINDING_TEXT="$(task_writer_finding_context "${rank}" "${severity}" "${category}" "${title}" "${existing_open_tasks_context}")"

        if ! task_context_snapshot_task_writer_prompt "${rank}" "${task_writer_playbook}" >/dev/null; then
            append_failure "Task writer prompt snapshot failed for: ${title}"
            phase_end "3.5a" "Task Writing" "FAILED"
            return 0
        fi

        if [[ "${DRY_RUN}" -eq 1 ]]; then
            ns_log "DRY RUN: would write task for: ${title} (severity: ${severity}, remaining: \$${remaining_budget}, minimum reserve: \$${min_budget})"
            unset NIGHTSHIFT_FINDING_TEXT
            continue
        fi

        task_writer_output="${AGENT_OUTPUT_DIR}/task-writer-rank-${rank}.json"
        task_writer_exit=0

        if agent_run_claude "${task_writer_playbook}" "${task_writer_output}" "${NIGHTSHIFT_MANAGER_MODEL}"; then
            :
        else
            task_writer_exit=$?
        fi

        task_writer_text="$(agent_extract_claude_result_text "${task_writer_output}" 2>/dev/null || true)"
        result_line="$(task_writer_result_line "${task_writer_text}")"
        result_status="$(task_writer_result_status "${result_line}")"

        if [[ "${task_writer_exit}" -ne 0 ]]; then
            result_status=""
        fi

        case "${result_status}" in
            CREATED)
                task_block="$(task_writer_extract_task_block "${task_writer_text}" 2>/dev/null || true)"
                if [[ -z "${task_block}" ]]; then
                    ns_log "Task writer malformed output for: ${title}"
                    failed_count=$(( failed_count + 1 ))
                else
                    task_slug="$(task_writer_slug_from_title "${title}")"
                    if [[ -z "${task_slug}" ]]; then
                        task_slug="finding-${rank}"
                    fi
                    task_path="$(task_writer_resolve_target_path "${task_slug}" 2>/dev/null || true)"
                    if [[ -z "${task_path}" ]]; then
                        ns_log "Task writer malformed output for: ${title}"
                        failed_count=$(( failed_count + 1 ))
                    else
                        mkdir -p "$(dirname "${task_path}")"
                        if printf '%s\n' "${task_block}" > "${task_path}"; then
                            CREATED_TASKS+=("${task_path}")
                            created_count=$(( created_count + 1 ))
                        else
                            ns_log "Task writer malformed output for: ${title}"
                            failed_count=$(( failed_count + 1 ))
                        fi
                    fi
                fi
                ;;
            REJECTED)
                rejection_reason="$(task_writer_rejection_reason "${result_line}")"
                if [[ -z "${rejection_reason}" ]]; then
                    rejection_reason="no reason provided"
                fi
                ns_log "Task writer rejected: ${title} — ${rejection_reason}"
                rejected_count=$(( rejected_count + 1 ))
                ;;
            *)
                ns_log "Task writer malformed output for: ${title}"
                failed_count=$(( failed_count + 1 ))
                ;;
        esac

        unset NIGHTSHIFT_FINDING_TEXT

        if ! cost_guard_after_call; then
            budget_skipped=$(( budget_skipped + task_limit - attempt_count ))
            phase_result="HALTED"
            break
        fi
    done

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        unset NIGHTSHIFT_FINDING_TEXT
    fi

    TASK_FILE_COUNT="${created_count}"
    patch_digest_task_count_if_needed "${DIGEST_PATH}" || true

    # manager-task-manifest.txt is the authoritative task-writer output manifest.
    if ! write_manager_task_manifest; then
        append_failure "Task writing manifest write failed: $(manager_task_manifest_path)"
        phase_end "3.5a" "Task Writing" "FAILED"
        return 0
    fi

    ns_log "Task writing: ${created_count} created, ${rejected_count} rejected, ${failed_count} failed, $(( severity_skipped + cap_skipped + budget_skipped )) skipped (severity/budget) out of ${total_findings} findings"
    phase_end "3.5a" "Task Writing" "${phase_result}"
}

phase_validation() {
    phase_start "3.5b" "Task Validation"

    VALIDATED_TASKS=()
    VALIDATION_TOTAL_COUNT=0
    VALIDATION_VALID_COUNT=0
    VALIDATION_INVALID_COUNT=0

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        ns_log "Dry-run enabled: skipping validation because task-writer files are not produced"
        phase_end "3.5b" "Task Validation" "SKIPPED"
        return 0
    fi

    if [[ "${SETUP_FAILED:-0}" -eq 1 ]]; then
        ns_log "Validation skipped because setup did not complete"
        phase_end "3.5b" "Task Validation" "SKIPPED"
        return 0
    fi

    if [[ "${MANAGER_CONTRACT_FAILED:-0}" -eq 1 ]]; then
        ns_log "Validation skipped because manager contract failed"
        phase_end "3.5b" "Task Validation" "SKIPPED"
        return 0
    fi

    if [[ "${RUN_COST_CAP:-0}" -eq 1 ]]; then
        patch_digest_task_count_if_needed "${DIGEST_PATH}" || true
        ns_log "Validation skipped because the run is already cost-capped"
        phase_end "3.5b" "Task Validation" "SKIPPED"
        return 0
    fi

    local manifest_path=""
    local findings_manifest_path_value=""
    # manager-task-manifest.txt distinguishes "phase ran, nothing created"
    # from "phase did not run".
    manifest_path="$(manager_task_manifest_path)"
    findings_manifest_path_value="$(findings_manifest_path)"
    if [[ ! -f "${manifest_path}" ]]; then
        if [[ -f "${findings_manifest_path_value}" ]]; then
            ns_log "Triage metadata found but no task files produced — task-writer phase not yet wired. Skipping validation."
            phase_end "3.5b" "Task Validation" "SKIPPED"
            return 0
        fi
        ns_log "Validation manifest missing at ${manifest_path}; 0 fresh tasks to validate"
        phase_end "3.5b" "Task Validation" "SKIPPED"
        return 0
    fi

    if [[ ! -s "${manifest_path}" ]]; then
        ns_log "Task writing produced no task files. Skipping validation."
        phase_end "3.5b" "Task Validation" "SKIPPED"
        return 0
    fi

    local validation_playbook="${NIGHTSHIFT_PLAYBOOKS_DIR}/validation-agent.md"
    if [[ ! -r "${validation_playbook}" ]]; then
        append_failure "Validation playbook missing or unreadable: ${validation_playbook}"
        phase_end "3.5b" "Task Validation" "FAILED"
        return 0
    fi

    local task_files=()
    local task_path=""
    while IFS= read -r task_path; do
        [[ -n "${task_path}" ]] || continue
        task_files+=("${task_path}")
    done < <(validation_task_paths)

    VALIDATION_TOTAL_COUNT="${#task_files[@]}"
    if (( VALIDATION_TOTAL_COUNT == 0 )); then
        ns_log "Validation: 0 validated, 0 invalid out of 0 total"
        phase_end "3.5b" "Task Validation" "SKIPPED"
        return 0
    fi

    local task_rel=""
    local validation_output=""
    local validation_text=""
    local validation_status=""
    local failed_checks=""
    local parse_failure_line=""
    local validation_exit=0

    for task_path in "${task_files[@]}"; do
        export NIGHTSHIFT_TASK_FILE_PATH="${task_path}"
        task_rel="${task_path#${REPO_ROOT}/}"
        validation_output="${AGENT_OUTPUT_DIR}/validation-$(basename "${task_path%.md}").json"
        validation_exit=0

        if agent_run_claude "${validation_playbook}" "${validation_output}" "${NIGHTSHIFT_MANAGER_MODEL}"; then
            :
        else
            validation_exit=$?
        fi

        validation_text="$(agent_extract_claude_result_text "${validation_output}" 2>/dev/null || true)"
        validation_status="$(validation_result_status "${validation_text}")"
        failed_checks="$(validation_failed_checks "${validation_text}")"

        if [[ "${validation_exit}" -ne 0 ]]; then
            parse_failure_line="- INVALID:validation — validation agent exited ${validation_exit} for ${task_rel}"
            if [[ -n "${failed_checks}" ]]; then
                failed_checks="${parse_failure_line}"$'\n'"${failed_checks}"
            else
                failed_checks="${parse_failure_line}"
            fi
            validation_status="INVALID"
        fi

        case "${validation_status}" in
            VALIDATED)
                VALIDATED_TASKS+=("${task_path}")
                VALIDATION_VALID_COUNT=$(( VALIDATION_VALID_COUNT + 1 ))
                append_validation_success_section "${task_path}" || true
                ns_log "Validated task: ${task_rel}"
                ;;
            INVALID)
                if [[ -z "${failed_checks}" ]]; then
                    failed_checks="- INVALID:validation — validation agent returned INVALID without failure details"
                fi
                append_validation_failure_section "${task_path}" "${failed_checks}" || true
                VALIDATION_INVALID_COUNT=$(( VALIDATION_INVALID_COUNT + 1 ))
                ns_log "Invalid task: ${task_rel}"
                ;;
            *)
                append_validation_failure_section \
                    "${task_path}" \
                    "- INVALID:validation — validation agent produced no parseable '### Validation Result:' block" \
                    || true
                VALIDATION_INVALID_COUNT=$(( VALIDATION_INVALID_COUNT + 1 ))
                ns_log "Invalid task: ${task_rel} (missing validation result)"
                ;;
        esac

        if ! cost_guard_after_call; then
            unset NIGHTSHIFT_TASK_FILE_PATH
            patch_digest_task_count_if_needed "${DIGEST_PATH}" || true
            ns_log "Validation: ${VALIDATION_VALID_COUNT} validated, ${VALIDATION_INVALID_COUNT} invalid out of ${VALIDATION_TOTAL_COUNT} total"
            phase_end "3.5b" "Task Validation" "HALTED"
            return 0
        fi
    done

    unset NIGHTSHIFT_TASK_FILE_PATH
    patch_digest_task_count_if_needed "${DIGEST_PATH}" || true
    ns_log "Validation: ${VALIDATION_VALID_COUNT} validated, ${VALIDATION_INVALID_COUNT} invalid out of ${VALIDATION_TOTAL_COUNT} total"
    phase_end "3.5b" "Task Validation" "OK"
}

phase_autofix() {
    phase_start "3.5c" "Autofix"
    AUTOFIX_ATTEMPTED_COUNT=0

    if smoke_mode_enabled; then
        ns_log "Smoke mode: skipping Autofix"
        phase_end "3.5c" "Autofix" "SKIPPED"
        return 0
    fi

    if [[ "${MANAGER_CONTRACT_FAILED:-0}" -eq 1 ]]; then
        ns_log "Autofix skipped because manager contract failed"
        phase_end "3.5c" "Autofix" "SKIPPED"
        return 0
    fi

    if [[ "${NIGHTSHIFT_AUTOFIX_ENABLED:-false}" != "true" ]]; then
        ns_log "Autofix disabled: skipping phase"
        phase_end "3.5c" "Autofix" "SKIPPED"
        return 0
    fi

    if (( ${#VALIDATED_TASKS[@]} == 0 )); then
        ns_log "Autofix: 0 validated tasks"
        phase_end "3.5c" "Autofix" "SKIPPED"
        return 0
    fi

    if [[ "${RUN_COST_CAP:-0}" -eq 1 ]]; then
        ns_log "Autofix skipped because the run is already cost-capped"
        phase_end "3.5c" "Autofix" "SKIPPED"
        return 0
    fi

    local total_validated="${#VALIDATED_TASKS[@]}"
    local autofix_spend="0.0000"
    local remaining_budget="0.0000"
    remaining_budget="$(autofix_remaining_budget "${autofix_spend}")"
    if awk -v remaining="${remaining_budget}" -v minimum="${NIGHTSHIFT_AUTOFIX_MIN_BUDGET}" '
        BEGIN {
            if (remaining < minimum) {
                exit 0
            }
            exit 1
        }
    '; then
        ns_log "Autofix: insufficient budget remaining (\$${remaining_budget} of \$${NIGHTSHIFT_AUTOFIX_MIN_BUDGET} needed)"
        phase_end "3.5c" "Autofix" "SKIPPED"
        return 0
    fi

    local critical_entries=()
    local major_entries=()
    local minor_entries=()
    local observation_entries=()
    local eligible_entries=()
    local task_path=""
    local severity=""

    for task_path in "${VALIDATED_TASKS[@]}"; do
        severity="$(autofix_extract_severity "${task_path}" | head -n 1)"
        if ! autofix_allowed_severity "${severity}"; then
            continue
        fi

        case "${severity}" in
            critical)
                critical_entries+=("${task_path}"$'\t'"${severity}")
                ;;
            major)
                major_entries+=("${task_path}"$'\t'"${severity}")
                ;;
            minor)
                minor_entries+=("${task_path}"$'\t'"${severity}")
                ;;
            observation)
                observation_entries+=("${task_path}"$'\t'"${severity}")
                ;;
        esac
    done

    local severity_entry=""
    for severity_entry in "${critical_entries[@]-}"; do
        [[ -n "${severity_entry}" ]] || continue
        eligible_entries+=("${severity_entry}")
    done
    for severity_entry in "${major_entries[@]-}"; do
        [[ -n "${severity_entry}" ]] || continue
        eligible_entries+=("${severity_entry}")
    done
    for severity_entry in "${minor_entries[@]-}"; do
        [[ -n "${severity_entry}" ]] || continue
        eligible_entries+=("${severity_entry}")
    done
    for severity_entry in "${observation_entries[@]-}"; do
        [[ -n "${severity_entry}" ]] || continue
        eligible_entries+=("${severity_entry}")
    done

    local max_tasks="${NIGHTSHIFT_AUTOFIX_MAX_TASKS:-10}"
    local task_limit="${#eligible_entries[@]}"
    if (( task_limit > max_tasks )); then
        task_limit="${max_tasks}"
    fi

    local fixed_count=0
    local failed_count=0
    local blocked_count=0
    local attempt_count=0
    local entry=""
    local entry_task=""
    local entry_severity=""
    local slug=""
    local goal=""
    local before_snapshot=""
    local after_snapshot=""
    local before_untracked=""
    local after_untracked=""
    local invocation_exit=0
    local outcome=""
    local manifest_path=""
    local fix_cost="0.0000"
    local per_task_budget="0.00"
    local spendable_budget="0.0000"
    local remaining_slots=0

    for entry in "${eligible_entries[@]}"; do
        [[ -n "${entry}" ]] || continue
        if (( attempt_count >= task_limit )); then
            break
        fi

        remaining_budget="$(autofix_remaining_budget "${autofix_spend}")"
        if awk -v remaining="${remaining_budget}" -v minimum="${NIGHTSHIFT_AUTOFIX_MIN_BUDGET}" '
            BEGIN {
                if (remaining < minimum) {
                    exit 0
                }
                exit 1
            }
        '; then
            ns_log "Autofix: insufficient budget remaining (\$${remaining_budget} of \$${NIGHTSHIFT_AUTOFIX_MIN_BUDGET} needed)"
            break
        fi

        remaining_slots=$(( task_limit - attempt_count ))
        if (( remaining_slots <= 0 )); then
            break
        fi

        spendable_budget="$(autofix_spendable_budget "${remaining_budget}")"
        if awk -v spendable="${spendable_budget}" '
            BEGIN {
                if (spendable <= 0) {
                    exit 0
                }
                exit 1
            }
        '; then
            ns_log "Autofix: no spendable budget remains after reserving \$${NIGHTSHIFT_AUTOFIX_MIN_BUDGET} for Phase 4 shipping"
            break
        fi

        per_task_budget="$(awk -v spendable="${spendable_budget}" -v slots="${remaining_slots}" '
            BEGIN {
                if (slots <= 0) {
                    exit 1
                }
                printf "%.2f\n", spendable / slots
            }
        ' 2>/dev/null || echo "0.00")"

        IFS=$'\t' read -r entry_task entry_severity <<< "${entry}"
        slug="$(autofix_task_slug_from_path "${entry_task}")"
        if ! goal="$(autofix_extract_goal "${entry_task}" | autofix_compact_text)"; then
            goal=""
        fi

        if [[ "${DRY_RUN}" -eq 1 ]]; then
            ns_log "DRY RUN: would attempt fix on ${slug} (severity: ${entry_severity}, remaining: \$${remaining_budget}, max cost: \$${per_task_budget})"
            attempt_count=$(( attempt_count + 1 ))
            continue
        fi

        if [[ -z "${goal}" ]]; then
            ns_log "Fix failed: ${slug}"
            append_warning "Autofix task ${entry_task#${REPO_ROOT}/} is missing a Goal section; skipping Lauren invocation"
            append_autofix_section "${entry_task}" "failed" "64" "0.0000" || true
            failed_count=$(( failed_count + 1 ))
            attempt_count=$(( attempt_count + 1 ))
            continue
        fi

        before_snapshot="$(git stash create 2>/dev/null || true)"
        before_untracked="$(git ls-files --others --exclude-standard 2>/dev/null | sort)"
        invocation_exit=0
        if LAUREN_LOOP_MAX_COST="${per_task_budget}" \
            LAUREN_LOOP_NONINTERACTIVE=1 \
            LAUREN_LOOP_TASK_FILE_HINT="${entry_task}" \
            bash "${REPO_ROOT}/lauren-loop-v2.sh" "${slug}" "${goal}" --strict; then
            :
        else
            invocation_exit=$?
        fi
        after_snapshot="$(git stash create 2>/dev/null || true)"
        after_untracked="$(git ls-files --others --exclude-standard 2>/dev/null | sort)"

        if [[ "${invocation_exit}" -eq 0 ]] && ! autofix_validate_exit_zero_manifest "${entry_task}"; then
            ns_log "Lauren exit 0 but manifest invalid — treating as hard failure"
            append_autofix_section "${entry_task}" "failed" "${invocation_exit}" "unknown" || true
            failed_count=$(( failed_count + 1 ))
            attempt_count=$(( attempt_count + 1 ))
            ns_log "Stopping autofix: manifest contract broken for ${slug}"
            break
        fi

        outcome="$(autofix_outcome_from_v2_run "${entry_task}" "${invocation_exit}")"
        if [[ "${invocation_exit}" -eq 0 ]]; then
            manifest_path="$(autofix_manifest_path "${entry_task}" 2>/dev/null || true)"
            if ! fix_cost="$(autofix_manifest_total_cost "${manifest_path}")"; then
                ns_log "Lauren exit 0 but manifest invalid — treating as hard failure"
                append_autofix_section "${entry_task}" "failed" "${invocation_exit}" "unknown" || true
                failed_count=$(( failed_count + 1 ))
                attempt_count=$(( attempt_count + 1 ))
                ns_log "Stopping autofix: manifest contract broken for ${slug}"
                break
            fi
            autofix_spend="$(awk -v current="${autofix_spend}" -v delta="${fix_cost}" '
                BEGIN {
                    printf "%.4f\n", current + delta
                }
            ')"
        else
            fix_cost="0.0000"
        fi

        case "${outcome}" in
            success)
                ns_log "Fixed: ${slug}"
                if ! autofix_stage_changed_paths "${entry_task}" "${before_snapshot}" "${after_snapshot}" "${before_untracked}" "${after_untracked}"; then
                    append_autofix_section "${entry_task}" "failed" "${invocation_exit}" "${fix_cost}" || true
                    failed_count=$(( failed_count + 1 ))
                    attempt_count=$(( attempt_count + 1 ))
                    ns_log "Stopping autofix: repo changes could not be staged for ${slug}"
                    break
                fi
                append_autofix_section "${entry_task}" "applied" "${invocation_exit}" "${fix_cost}" || true
                fixed_count=$(( fixed_count + 1 ))
                ;;
            blocked)
                ns_log "Fix blocked with partial merge: ${slug}"
                if ! autofix_stage_changed_paths "${entry_task}" "${before_snapshot}" "${after_snapshot}" "${before_untracked}" "${after_untracked}"; then
                    append_autofix_section "${entry_task}" "failed" "${invocation_exit}" "${fix_cost}" || true
                    failed_count=$(( failed_count + 1 ))
                    attempt_count=$(( attempt_count + 1 ))
                    ns_log "Stopping autofix: repo changes could not be staged for ${slug}"
                    break
                fi
                append_autofix_section "${entry_task}" "blocked" "${invocation_exit}" "${fix_cost}" || true
                blocked_count=$(( blocked_count + 1 ))
                attempt_count=$(( attempt_count + 1 ))
                ns_log "Stopping autofix: BLOCKED result may affect remaining tasks"
                break
                ;;
            *)
                ns_log "Fix failed: ${slug}"
                append_autofix_section "${entry_task}" "failed" "${invocation_exit}" "${fix_cost}" || true
                failed_count=$(( failed_count + 1 ))
                ;;
        esac

        attempt_count=$(( attempt_count + 1 ))

        remaining_budget="$(autofix_remaining_budget "${autofix_spend}")"
        if awk -v remaining="${remaining_budget}" -v minimum="${NIGHTSHIFT_AUTOFIX_MIN_BUDGET}" '
            BEGIN {
                if (remaining < minimum) {
                    exit 0
                }
                exit 1
            }
        '; then
            ns_log "Autofix: insufficient budget remaining (\$${remaining_budget} of \$${NIGHTSHIFT_AUTOFIX_MIN_BUDGET} needed)"
            break
        fi
    done

    local skipped_count=0
    skipped_count=$(( total_validated - fixed_count - failed_count - blocked_count ))
    if (( skipped_count < 0 )); then
        skipped_count=0
    fi
    AUTOFIX_ATTEMPTED_COUNT="${attempt_count}"

    ns_log "Autofix: ${fixed_count} fixed, ${failed_count} failed, ${blocked_count} blocked, ${skipped_count} skipped (budget/severity) out of ${total_validated} validated"
    phase_end "3.5c" "Autofix" "OK"
}

phase_bridge() {
    phase_start "3.6" "Lauren Loop Bridge"
    BRIDGE_STAGE_PATHS=()
    BRIDGE_SKIPPED=0

    if smoke_mode_enabled; then
        ns_log "Smoke mode: skipping Lauren Loop Bridge"
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi

    if [[ "${MANAGER_CONTRACT_FAILED:-0}" -eq 1 ]]; then
        ns_log "Night Shift bridge skipped because manager contract failed"
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi

    if [[ "${NIGHTSHIFT_BRIDGE_ENABLED:-false}" != "true" ]]; then
        ns_log "Night Shift bridge disabled: skipping phase"
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        if ! bridge_run "${DIGEST_PATH}" "true"; then
            bridge_log "WARN: Bridge preview failed; continuing without bridge artifacts"
        elif [[ "${BRIDGE_SKIPPED:-0}" -eq 1 ]]; then
            phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
            return 0
        fi
        phase_end "3.6" "Lauren Loop Bridge" "OK"
        return 0
    fi

    if [[ "${SETUP_FAILED:-0}" -eq 1 ]]; then
        ns_log "Night Shift bridge skipped because setup did not complete"
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi

    if [[ "${BRANCH_READY:-0}" -eq 0 ]]; then
        ns_log "Night Shift bridge skipped because no writable nightshift branch is available"
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi

    if [[ "${RUN_COST_CAP:-0}" -eq 1 ]]; then
        ns_log "Night Shift bridge skipped because the run is already cost-capped"
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi

    if [[ -z "${DIGEST_PATH}" || ! -f "${DIGEST_PATH}" ]]; then
        bridge_log "WARN: Bridge enabled but digest is unavailable; skipping execution"
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi

    if ! bridge_run "${DIGEST_PATH}" "false"; then
        bridge_log "WARN: Bridge execution failed; continuing to shipping"
    elif [[ "${BRIDGE_SKIPPED:-0}" -eq 1 ]]; then
        phase_end "3.6" "Lauren Loop Bridge" "SKIPPED"
        return 0
    fi
    phase_end "3.6" "Lauren Loop Bridge" "OK"
}

phase_backlog_burndown() {
    phase_start "3.7" "Backlog Burndown"
    BACKLOG_STAGE_PATHS=()
    BACKLOG_RESULTS=()
    BACKLOG_LAST_OUTCOME=""

    if smoke_mode_enabled; then
        backlog_log "Smoke mode: skipping Backlog Burndown"
        phase_end "3.7" "Backlog Burndown" "SKIPPED"
        return 0
    fi

    if [[ "${MANAGER_CONTRACT_FAILED:-0}" -eq 1 ]]; then
        backlog_log "Backlog burndown skipped because manager contract failed"
        phase_end "3.7" "Backlog Burndown" "SKIPPED"
        return 0
    fi

    if [[ "${NIGHTSHIFT_BACKLOG_ENABLED:-false}" != "true" ]]; then
        backlog_log "Backlog burndown disabled: skipping phase"
        phase_end "3.7" "Backlog Burndown" "SKIPPED"
        return 0
    fi
    if ! declare -F backlog_needed_tasks >/dev/null 2>&1; then
        if ! source_required "${SCRIPT_DIR}/lib/backlog-floor.sh"; then
            phase_end "3.7" "Backlog Burndown" "FAILED"
            return 1
        fi
    fi

    local attempted_autofix="${AUTOFIX_ATTEMPTED_COUNT:-0}"
    local min_tasks_per_run="${NIGHTSHIFT_MIN_TASKS_PER_RUN:-3}"
    local needed_tasks=0
    local effective_max_tasks=0
    needed_tasks="$(backlog_needed_tasks "${attempted_autofix}" "${min_tasks_per_run}")"
    effective_max_tasks="$(backlog_effective_max_tasks "${attempted_autofix}" "${min_tasks_per_run}" "${NIGHTSHIFT_BACKLOG_MAX_TASKS:-3}")"
    backlog_log "Backlog target: attempted autofix=${attempted_autofix}, min per run=${min_tasks_per_run}, needed=${needed_tasks}, effective max=${effective_max_tasks}"

    if [[ "${RUN_CLEAN:-0}" -eq 1 ]] && backlog_clean_run_satisfied "${attempted_autofix}" "${min_tasks_per_run}"; then
        backlog_log "INFO: Night Shift: backlog skipped — clean run, no upstream findings"
        phase_end "3.7" "Backlog Burndown" "SKIPPED"
        return 0
    fi

    if [[ "${SETUP_FAILED:-0}" -eq 1 ]]; then
        backlog_log "Backlog burndown skipped because setup did not complete"
        phase_end "3.7" "Backlog Burndown" "SKIPPED"
        return 0
    fi

    if [[ "${RUN_COST_CAP:-0}" -eq 1 ]]; then
        backlog_log "Backlog burndown skipped because the run is already cost-capped"
        phase_end "3.7" "Backlog Burndown" "SKIPPED"
        return 0
    fi

    local remaining_budget="0.0000"
    remaining_budget="$(_backlog_remaining_budget)"
    if awk -v remaining="${remaining_budget}" -v minimum="${NIGHTSHIFT_BACKLOG_MIN_BUDGET}" '
        BEGIN {
            if (remaining < minimum) {
                exit 0
            }
            exit 1
        }
    '; then
        backlog_log "Backlog burndown skipped because remaining budget \$${remaining_budget} is below minimum \$${NIGHTSHIFT_BACKLOG_MIN_BUDGET}"
        phase_end "3.7" "Backlog Burndown" "SKIPPED"
        return 0
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        local preview_task=""
        local preview_rel_path=""
        local preview_slug=""
        local selected_preview=0
        local max_preview_tasks="${effective_max_tasks}"

        while IFS= read -r preview_task; do
            [[ -n "${preview_task}" ]] || continue
            preview_rel_path="$(backlog_relative_task_path "${preview_task}")"
            if ! backlog_task_is_pickable "${preview_rel_path}"; then
                continue
            fi

            preview_slug="$(backlog_task_path_to_slug "${preview_rel_path}")"
            backlog_log "DRY RUN: would pick ${preview_rel_path} (slug: ${preview_slug})"
            backlog_result_add "${preview_rel_path}" "${preview_slug}" "skipped" "0.0000"
            selected_preview=$(( selected_preview + 1 ))
            if (( selected_preview >= max_preview_tasks )); then
                break
            fi
        done < <(find "${REPO_ROOT}/docs/tasks/open" -name '*.md' -not -path '*/competitive/*' | sort)

        if [[ -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
            append_backlog_digest_section "${DIGEST_PATH}"
        fi
        phase_end "3.7" "Backlog Burndown" "OK"
        return 0
    fi

    local ranked_output=""
    local ranked_entry=""
    local selected_candidates=()
    local max_tasks="${effective_max_tasks}"
    local task_rank=""
    local task_path=""
    local task_goal=""
    local task_complexity=""
    local task_list_section=""
    local raw_task_list_has_content=0
    local parsed_rows=0
    local selected_count=0

    if ranked_output="$(LAUREN_LOOP_NONINTERACTIVE=1 bash "${REPO_ROOT}/lauren-loop.sh" next 2>/dev/null)"; then
        :
    else
        local ranking_exit=$?
        append_warning "Backlog ranking failed with exit ${ranking_exit}; skipping backlog burndown"
        backlog_log "Lauren Loop next failed with exit ${ranking_exit}; continuing without backlog execution"
        phase_end "3.7" "Backlog Burndown" "OK"
        return 0
    fi

    if ! backlog_task_list_has_header "${ranked_output}"; then
        append_warning "lauren-loop.sh next succeeded but output contained no ## TASK_LIST header; ranking output may have changed format"
        backlog_log "WARN: lauren-loop.sh next succeeded but output contained no ## TASK_LIST header; ranking output may have changed format"
        if [[ -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
            append_backlog_digest_section "${DIGEST_PATH}"
        fi
        phase_end "3.7" "Backlog Burndown" "OK"
        return 0
    fi

    task_list_section="$(backlog_task_list_section "${ranked_output}")"
    if printf '%s\n' "${task_list_section}" | grep -q '[^[:space:]]'; then
        raw_task_list_has_content=1
    fi

    while IFS= read -r ranked_entry; do
        [[ -n "${ranked_entry}" ]] || continue
        parsed_rows=$(( parsed_rows + 1 ))
        IFS='|' read -r task_rank task_path task_goal task_complexity <<< "${ranked_entry}"
        task_path="$(backlog_relative_task_path "${task_path}")"
        task_goal="$(trim_whitespace "${task_goal}")"
        task_complexity="$(trim_whitespace "${task_complexity}")"

        if ! backlog_task_is_pickable "${task_path}"; then
            continue
        fi

        selected_candidates+=("${task_rank}|${task_path}|${task_goal}|${task_complexity}")
        selected_count=$(( selected_count + 1 ))
        if (( selected_count >= max_tasks )); then
            break
        fi
    done < <(backlog_parse_task_list "${ranked_output}")

    if (( parsed_rows == 0 )); then
        if (( raw_task_list_has_content == 1 )); then
            append_warning "TASK_LIST contained rows but none matched the expected rank|path|goal|complexity format; check for format changes"
            backlog_log "WARN: TASK_LIST contained rows but none matched the expected rank|path|goal|complexity format; check for format changes"
        else
            backlog_log "Lauren Loop next returned an empty TASK_LIST; continuing without backlog execution"
        fi
        if [[ -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
            append_backlog_digest_section "${DIGEST_PATH}"
        fi
        phase_end "3.7" "Backlog Burndown" "OK"
        return 0
    fi

    if (( ${#selected_candidates[@]} == 0 )); then
        backlog_log "No ranked backlog tasks passed the pickability filters"
        if [[ -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
            append_backlog_digest_section "${DIGEST_PATH}"
        fi
        phase_end "3.7" "Backlog Burndown" "OK"
        return 0
    fi

    local selected_entry=""
    local selected_slug=""
    local remaining_tasks_to_run=0
    local budget_before="0.0000"
    local budget_after="0.0000"
    local per_task_budget="0.00"
    local cost_before="0.0000"
    local cost_after="0.0000"
    local cost_delta="0.0000"
    local before_status=""
    local after_status=""
    local invocation_exit=0
    local outcome=""

    for selected_entry in "${selected_candidates[@]}"; do
        remaining_tasks_to_run=$(( ${#selected_candidates[@]} - ${#BACKLOG_RESULTS[@]} ))
        if (( remaining_tasks_to_run <= 0 )); then
            break
        fi

        budget_before="$(_backlog_remaining_budget)"
        if awk -v remaining="${budget_before}" -v minimum="${NIGHTSHIFT_BACKLOG_MIN_BUDGET}" '
            BEGIN {
                if (remaining < minimum) {
                    exit 0
                }
                exit 1
            }
        '; then
            backlog_log "Stopping backlog burndown early: remaining budget \$${budget_before} is below minimum \$${NIGHTSHIFT_BACKLOG_MIN_BUDGET}"
            break
        fi

        per_task_budget="$(awk -v remaining="${budget_before}" -v slots="${remaining_tasks_to_run}" '
            BEGIN {
                if (slots <= 0) {
                    exit 1
                }
                printf "%.2f\n", remaining / slots
            }
        ' 2>/dev/null || echo "0.00")"

        IFS='|' read -r task_rank task_path task_goal task_complexity <<< "${selected_entry}"
        selected_slug="$(backlog_task_path_to_slug "${task_path}")"
        backlog_log "Selected ranked task #${task_rank}: ${task_path} (slug: ${selected_slug}, complexity: ${task_complexity}, budget: \$${per_task_budget})"

        before_status="$(git status --porcelain --untracked-files=all || true)"
        cost_before="$(cost_total_value)"

        invocation_exit=0
        if LAUREN_LOOP_MAX_COST="${per_task_budget}" \
            LAUREN_LOOP_NONINTERACTIVE=1 \
            bash "${REPO_ROOT}/lauren-loop-v2.sh" "${selected_slug}" "${task_goal}" --strict; then
            :
        else
            invocation_exit=$?
        fi

        backlog_outcome_from_v2_run "${selected_slug}" "${invocation_exit}"
        outcome="${BACKLOG_LAST_OUTCOME}"
        # outcome success: verified manifest success, capture stage paths.
        # outcome human_review: V2 requested human review, log only.
        # outcome blocked: manifest completed without success, log only.
        # outcome failed: non-zero exit or invalid manifest contract, warn only.
        case "${outcome}" in
            success)
                backlog_log "Lauren Loop V2 completed successfully for ${selected_slug}"
                ;;
            human_review)
                backlog_log "Lauren Loop V2 halted for human review for ${selected_slug}; backlog changes will not be staged"
                ;;
            blocked)
                backlog_log "Lauren Loop V2 finished without success for ${selected_slug}; backlog changes will not be staged"
                ;;
            failed)
                if [[ "${invocation_exit}" -ne 0 ]]; then
                    append_warning "Backlog task ${selected_slug} failed with exit ${invocation_exit}; continuing"
                    backlog_log "WARN: Lauren Loop V2 failed for ${selected_slug} with exit ${invocation_exit}; backlog changes will not be staged"
                else
                    backlog_log "WARN: Lauren Loop V2 could not verify a successful outcome for ${selected_slug}; backlog changes will not be staged"
                fi
                ;;
        esac

        after_status="$(git status --porcelain --untracked-files=all || true)"
        cost_after="$(cost_total_value)"
        cost_delta="$(awk -v before="${cost_before}" -v after="${cost_after}" '
            BEGIN {
                delta = after - before
                if (delta < 0) {
                    delta = 0
                }
                printf "%.4f\n", delta
            }
        ')"

        if [[ "${outcome}" == "success" ]]; then
            backlog_capture_stage_paths "${before_status}" "${after_status}"
        fi
        backlog_result_add "${task_path}" "${selected_slug}" "${outcome}" "${cost_delta}"

        budget_after="$(_backlog_remaining_budget)"
        if awk -v remaining="${budget_after}" -v minimum="${NIGHTSHIFT_BACKLOG_MIN_BUDGET}" '
            BEGIN {
                if (remaining < minimum) {
                    exit 0
                }
                exit 1
            }
        '; then
            backlog_log "Remaining budget \$${budget_after} fell below minimum \$${NIGHTSHIFT_BACKLOG_MIN_BUDGET}; stopping backlog burndown"
            break
        fi
    done

    if [[ -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
        append_backlog_digest_section "${DIGEST_PATH}"
    fi

    phase_end "3.7" "Backlog Burndown" "OK"
    return 0
}

parse_configured_pr_labels() {
    local raw_labels="$1"
    local -a _labels=()
    local label=""
    local IFS=','

    read -r -a _labels <<< "${raw_labels}"
    for label in "${_labels[@]-}"; do
        label="$(trim_whitespace "${label}")"
        [[ -z "${label}" ]] && continue
        printf '%s\n' "${label}"
    done
}

phase_ship_results() {
    phase_start "4" "Ship Results"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        ns_log "Dry-run enabled: skipping commit, push, and PR creation"
        phase_end "4" "Ship Results" "SKIPPED"
        return 0
    fi

    if [[ "${MANAGER_CONTRACT_FAILED:-0}" -eq 1 ]]; then
        ns_log "Phase 4 skipped because manager contract failed"
        phase_end "4" "Ship Results" "SKIPPED"
        return 0
    fi

    if [[ "${RUN_COST_CAP}" -eq 1 ]]; then
        append_failure "Phase 4 proceeding after cost cap halt; shipping whatever artifacts exist"
    fi

    if [[ "${RUN_CLEAN}" -eq 1 ]]; then
        ns_log "Clean run detected: no git commit, push, or PR will be created"
        phase_end "4" "Ship Results" "CLEAN"
        return 0
    fi

    if [[ "${BRANCH_READY}" -eq 0 ]]; then
        append_failure "Phase 4 skipped because no nightshift branch is available"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    local stage_paths=()
    local task_path=""
    local pr_labels=()
    local pr_label=""
    local label_args=()
    local status_output=""
    local bridge_stage_path=""
    local backlog_stage_path=""
    local phase_result="OK"

    if [[ "${DIGEST_STAGEABLE}" -eq 1 && -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
        stage_paths+=("${DIGEST_PATH}")
    fi

    for task_path in "${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-"*.md; do
        [[ -f "${task_path}" ]] || continue
        stage_paths+=("${task_path}")
    done

    for bridge_stage_path in "${BRIDGE_STAGE_PATHS[@]-}"; do
        stage_path_has_changes "${bridge_stage_path}" || continue
        stage_paths+=("${bridge_stage_path}")
    done

    for backlog_stage_path in "${BACKLOG_STAGE_PATHS[@]-}"; do
        stage_path_has_changes "${backlog_stage_path}" || continue
        stage_paths+=("${backlog_stage_path}")
    done

    if (( ${#stage_paths[@]} == 0 )); then
        if [[ "${RUN_FAILED}" -eq 0 ]]; then
            RUN_CLEAN=1
            ns_log "No repo artifacts to ship; marking run clean"
            phase_end "4" "Ship Results" "CLEAN"
            return 0
        fi
        append_failure "No repo artifacts were produced for shipping"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    status_output="$(git status --porcelain -- "${stage_paths[@]}" || true)"
    if [[ -z "${status_output}" ]]; then
        if [[ "${RUN_FAILED}" -eq 0 ]]; then
            RUN_CLEAN=1
            ns_log "No diff detected in shipping paths; marking run clean"
            phase_end "4" "Ship Results" "CLEAN"
            return 0
        fi
        append_failure "Shipping paths contain no diff despite a non-clean run"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    if ! git add -- "${stage_paths[@]}"; then
        append_failure "git add failed for shipping artifacts"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    local commit_message="nightshift: ${RUN_DATE} detective run - ${TASK_FILE_COUNT} tasks / ${TOTAL_FINDINGS_AVAILABLE} findings"
    if declare -F git_validate_commit_message >/dev/null 2>&1; then
        if ! git_validate_commit_message "${commit_message}"; then
            append_failure "git_validate_commit_message rejected the generated commit message"
            phase_end "4" "Ship Results" "FAILED"
            return 0
        fi
    fi

    if git diff --cached --quiet -- "${stage_paths[@]}"; then
        if [[ "${RUN_FAILED}" -eq 0 ]]; then
            RUN_CLEAN=1
            ns_log "No staged diff after git add; marking run clean"
            phase_end "4" "Ship Results" "CLEAN"
            return 0
        fi
        append_failure "No staged diff was present after git add"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    if ! git commit -m "${commit_message}"; then
        append_failure "git commit failed"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    if declare -F git_validate_pr_size >/dev/null 2>&1; then
        if ! git_validate_pr_size "${NIGHTSHIFT_BASE_BRANCH}"; then
            append_failure "git_validate_pr_size rejected the committed artifact set"
            phase_end "4" "Ship Results" "FAILED"
            return 0
        fi
    fi
    git push origin --delete "${RUN_BRANCH}" 2>/dev/null || true
    if ! git push origin "${RUN_BRANCH}"; then
        append_failure "git push origin ${RUN_BRANCH} failed"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    if [[ "${GH_AVAILABLE}" -eq 0 ]]; then
        append_failure "gh CLI is unavailable; skipping PR creation"
        phase_end "4" "Ship Results" "FAILED"
        return 0
    fi

    while IFS= read -r pr_label; do
        [[ -z "${pr_label}" ]] && continue
        pr_labels+=("${pr_label}")
        label_args+=("--label" "${pr_label}")
    done < <(parse_configured_pr_labels "${NIGHTSHIFT_PR_LABELS}")

    local pr_title="Nightshift ${RUN_DATE}: ${TASK_FILE_COUNT} tasks / ${TOTAL_FINDINGS_AVAILABLE} findings"
    if smoke_mode_enabled; then
        pr_title="[SMOKE TEST] ${pr_title}"
    fi
    local pr_create_args=(
        --base "${NIGHTSHIFT_BASE_BRANCH}"
        --head "${RUN_BRANCH}"
        --title "${pr_title}"
    )
    if [[ "${DIGEST_STAGEABLE}" -eq 1 && -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
        pr_create_args+=(--body-file "${DIGEST_PATH}")
    fi
    for pr_label in "${pr_labels[@]-}"; do
        gh label create "${pr_label}" --color "0E8A16" 2>/dev/null || true
    done
    if PR_URL="$(gh pr create "${pr_create_args[@]}" "${label_args[@]-}")"; then
        ns_log "PR created: ${PR_URL}"
    else
        append_failure "gh pr create failed"
        phase_result="FAILED"
    fi

    phase_end "4" "Ship Results" "${phase_result}"
}

phase_cleanup() {
    phase_start "5" "Cleanup"
    local run_duration=0
    local cost_total="0.0000"

    if [[ "${COST_TRACKING_READY}" -eq 1 ]]; then
        if ! cost_get_summary; then
            append_warning "cost_get_summary failed during cleanup"
        fi
    fi

    if [[ -n "${DIGEST_PATH}" && -f "${DIGEST_PATH}" ]]; then
        ns_log "Digest artifact: ${DIGEST_PATH}"
    fi

    if [[ -n "${PR_URL}" ]]; then
        ns_log "PR URL: ${PR_URL}"
    fi

    if [[ "${TOTAL_START_EPOCH:-0}" -gt 0 ]]; then
        run_duration=$(( $(date +%s) - TOTAL_START_EPOCH ))
    fi
    if declare -F cost_get_total >/dev/null 2>&1; then
        cost_total="$(cost_get_total 2>/dev/null || echo "0.0000")"
    fi
    if declare -F cost_weekly_summary >/dev/null 2>&1; then
        cost_weekly_summary || true
    fi
    if declare -F notify_dispatch >/dev/null 2>&1; then
        notify_dispatch \
            "${DIGEST_PATH}" "${PR_URL}" "${cost_total}" \
            "${run_duration}" "${TOTAL_FINDINGS_AVAILABLE}" \
            "${FAILURE_NOTES}" "${WARNING_NOTES}" "${LOG_FILE}" || true
    fi

    cleanup_lock
    phase_end "5" "Cleanup" "OK"
}

compute_exit_code() {
    if [[ "${RUN_COST_CAP}" -eq 1 ]]; then
        echo "2"
        return 0
    fi

    if [[ "${RUN_FAILED}" -eq 1 ]]; then
        echo "1"
        return 0
    fi

    echo "0"
}

main() {
    trap 'on_err "${LINENO}" "$?"' ERR
    trap 'on_exit "$?"' EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    trap 'on_signal HUP' HUP

    parse_args "$@"
    if ! enforce_live_bootstrap_entrypoint; then
        return 1
    fi
    acquire_lock

    if ! load_nightshift_configuration "${SCRIPT_DIR}/nightshift.conf" "${ENV_FILE}"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/cost-tracker.sh"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/agent-runner.sh"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/db-safety.sh"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/git-safety.sh"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/notify.sh"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/backlog-floor.sh"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/lauren-bridge.sh"; then
        phase_cleanup
        return 1
    fi
    if ! source_required "${SCRIPT_DIR}/lib/suppression.sh"; then
        phase_cleanup
        return 1
    fi

    init_runtime_paths

    TOTAL_START_EPOCH="$(date +%s)"

    phase_setup
    phase_detectives
    phase_manager_merge
    phase_task_writing
    phase_validation
    phase_autofix
    phase_bridge
    phase_backlog_burndown
    phase_ship_results
    phase_cleanup

    local final_exit_code
    final_exit_code="$(compute_exit_code)"
    git checkout main 2>/dev/null || true
    return "${final_exit_code}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

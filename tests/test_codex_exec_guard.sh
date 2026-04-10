#!/bin/bash
set -euo pipefail

CONTEXT_GUARD_SH="$HOME/.claude/scripts/context-guard.sh"
if [[ ! -f "$CONTEXT_GUARD_SH" ]]; then
    echo "SKIP: context-guard.sh not found at ~/.claude/scripts/ — run from a configured environment"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/codex-exec-guard.XXXXXX")"
CONTROL_FILE="/tmp/test-codex-control"
CALL_COUNT_FILE="/tmp/test-codex-calls"
ARGS_FILE="/tmp/test-codex-args"
ARGS_LOG_FILE="/tmp/test-codex-args-log"
STDIN_FILE="/tmp/test-codex-stdin"
STDIN_LOG_FILE="/tmp/test-codex-stdin-log"
AZ_ACCOUNT_FILE="/tmp/test-codex-az-account"
AZ_KEYVAULT_FILE="/tmp/test-codex-az-keyvault"
AZ_LOG_FILE="/tmp/test-codex-az-log"
CURL_STATUS_FILE="/tmp/test-codex-curl-status"
CURL_CALL_COUNT_FILE="/tmp/test-codex-curl-calls"
CURL_LOG_FILE="/tmp/test-codex-curl-log"
CURL_URL_FILE="/tmp/test-codex-curl-url"
CURL_API_KEY_FILE="/tmp/test-codex-curl-api-key"
trap 'rm -rf "$TMP_ROOT"; rm -f "$CONTROL_FILE" "$CALL_COUNT_FILE" "$ARGS_FILE" "$ARGS_LOG_FILE" "$STDIN_FILE" "$STDIN_LOG_FILE" "$AZ_ACCOUNT_FILE" "$AZ_KEYVAULT_FILE" "$AZ_LOG_FILE" "$CURL_STATUS_FILE" "$CURL_CALL_COUNT_FILE" "$CURL_LOG_FILE" "$CURL_URL_FILE" "$CURL_API_KEY_FILE"' EXIT

PASSED=0
FAILED=0
TOTAL=0
LAST_STATUS=0
LAST_STDOUT=""
LAST_STDERR=""

pass() {
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
    echo "PASS: $1"
}

fail() {
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    echo "FAIL: $1"
    if [ -n "${2:-}" ]; then
        echo "  Detail: $2"
    fi
}

create_fixture() {
    local fixture
    fixture="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    mkdir -p "$fixture/bin"

    cat <<'EOF' > "$fixture/bin/codex"
#!/bin/bash
set -euo pipefail

CONTROL_FILE="/tmp/test-codex-control"
CALL_COUNT_FILE="/tmp/test-codex-calls"
ARGS_FILE="/tmp/test-codex-args"
ARGS_LOG_FILE="/tmp/test-codex-args-log"
STDIN_FILE="/tmp/test-codex-stdin"
STDIN_LOG_FILE="/tmp/test-codex-stdin-log"

count=0
[[ -f "$CALL_COUNT_FILE" ]] && count=$(cat "$CALL_COUNT_FILE")
count=$((count + 1))
echo "$count" > "$CALL_COUNT_FILE"

printf '%s\n' "$@" > "$ARGS_FILE"
{
    printf 'CALL %s\n' "$count"
    printf '%s\n' "$@"
    printf -- '--\n'
} >> "$ARGS_LOG_FILE"

stdin_content=$(cat)
printf '%s' "$stdin_content" > "$STDIN_FILE"
{
    printf 'CALL %s\n' "$count"
    printf '%s\n' "$stdin_content"
    printf -- '--\n'
} >> "$STDIN_LOG_FILE"

line="$(sed -n "${count}p" "$CONTROL_FILE")"
if [[ -z "$line" ]]; then
    line="$(tail -n 1 "$CONTROL_FILE")"
fi
want_exit=${line%%:*}
rest=${line#*:}
if [[ "$rest" == "$line" ]]; then
    want_stderr=""
    succeed_on=""
else
    succeed_on=${rest##*:}
    if [[ "$rest" == "$succeed_on" ]]; then
        want_stderr=""
        succeed_on=""
    else
        want_stderr=${rest%:*}
    fi
fi

if [[ -n "$succeed_on" && "$count" -ge "$succeed_on" ]]; then
    exit 0
fi

[[ -n "$want_stderr" ]] && echo "$want_stderr" >&2
exit "${want_exit:-1}"
EOF
    chmod +x "$fixture/bin/codex"

    cat <<'EOF' > "$fixture/bin/az"
#!/bin/bash
set -euo pipefail

AZ_ACCOUNT_FILE="/tmp/test-codex-az-account"
AZ_KEYVAULT_FILE="/tmp/test-codex-az-keyvault"
AZ_LOG_FILE="/tmp/test-codex-az-log"

account_mode="ok"
keyvault_mode="ok:fake"
[[ -f "$AZ_ACCOUNT_FILE" ]] && account_mode="$(cat "$AZ_ACCOUNT_FILE")"
[[ -f "$AZ_KEYVAULT_FILE" ]] && keyvault_mode="$(cat "$AZ_KEYVAULT_FILE")"
printf '%s\n' "$*" >> "$AZ_LOG_FILE"

if [[ "${1:-}" == "account" && "${2:-}" == "show" ]]; then
    [[ "$account_mode" == "fail" ]] && exit 1
    exit 0
fi

if [[ "${1:-}" == "keyvault" && "${2:-}" == "secret" && "${3:-}" == "show" ]]; then
    case "$keyvault_mode" in
        fail)
            exit 1
            ;;
        empty)
            exit 0
            ;;
        ok:*)
            printf '%s\n' "${keyvault_mode#ok:}"
            exit 0
            ;;
        *)
            printf '%s\n' "$keyvault_mode"
            exit 0
            ;;
    esac
fi

exit 0
EOF
    chmod +x "$fixture/bin/az"

    cat <<'EOF' > "$fixture/bin/sleep"
#!/bin/bash
exit 0
EOF
    chmod +x "$fixture/bin/sleep"

    cat <<'EOF' > "$fixture/bin/curl"
#!/bin/bash
set -euo pipefail

CURL_STATUS_FILE="/tmp/test-codex-curl-status"
CURL_CALL_COUNT_FILE="/tmp/test-codex-curl-calls"
CURL_LOG_FILE="/tmp/test-codex-curl-log"
CURL_URL_FILE="/tmp/test-codex-curl-url"
CURL_API_KEY_FILE="/tmp/test-codex-curl-api-key"

count=0
[[ -f "$CURL_CALL_COUNT_FILE" ]] && count=$(cat "$CURL_CALL_COUNT_FILE")
count=$((count + 1))
echo "$count" > "$CURL_CALL_COUNT_FILE"

url=""
api_key=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -H)
            shift
            if [[ "${1:-}" == api-key:* ]]; then
                api_key="${1#api-key: }"
            fi
            ;;
        -o|-w|--max-time)
            shift
            ;;
        -s)
            ;;
        *)
            url="$1"
            ;;
    esac
    shift
done

printf '%s' "$url" > "$CURL_URL_FILE"
printf '%s' "$api_key" > "$CURL_API_KEY_FILE"
{
    printf 'CALL %s\n' "$count"
    printf 'URL %s\n' "$url"
    printf 'API_KEY %s\n' "$api_key"
    printf -- '--\n'
} >> "$CURL_LOG_FILE"

status="$(sed -n "${count}p" "$CURL_STATUS_FILE" 2>/dev/null || true)"
if [[ -z "$status" && -f "$CURL_STATUS_FILE" ]]; then
    status="$(tail -n 1 "$CURL_STATUS_FILE")"
fi
status="${status:-200}"
printf '%s' "$status"

if [[ "$status" == "000" ]]; then
    exit 28
fi
exit 0
EOF
    chmod +x "$fixture/bin/curl"

    printf '%s\n' "$fixture"
}

reset_az_controls() {
    printf 'ok\n' > "$AZ_ACCOUNT_FILE"
    printf 'ok:fake\n' > "$AZ_KEYVAULT_FILE"
    : > "$AZ_LOG_FILE"
}

reset_curl_controls() {
    printf '200\n' > "$CURL_STATUS_FILE"
    : > "$CURL_LOG_FILE"
    rm -f "$CURL_CALL_COUNT_FILE" "$CURL_URL_FILE" "$CURL_API_KEY_FILE"
}

set_az_account_mode() {
    printf '%s\n' "$1" > "$AZ_ACCOUNT_FILE"
}

set_az_keyvault_mode() {
    printf '%s\n' "$1" > "$AZ_KEYVAULT_FILE"
}

set_curl_statuses() {
    : > "$CURL_STATUS_FILE"
    for status in "$@"; do
        printf '%s\n' "$status" >> "$CURL_STATUS_FILE"
    done
    : > "$CURL_LOG_FILE"
    rm -f "$CURL_CALL_COUNT_FILE" "$CURL_URL_FILE" "$CURL_API_KEY_FILE"
}

write_control() {
    printf '%s\n' "$1" > "$CONTROL_FILE"
    rm -f "$CALL_COUNT_FILE" "$ARGS_LOG_FILE" "$STDIN_LOG_FILE"
    reset_az_controls
    reset_curl_controls
}

write_control_lines() {
    : > "$CONTROL_FILE"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$CONTROL_FILE"
    done
    rm -f "$CALL_COUNT_FILE" "$ARGS_LOG_FILE" "$STDIN_LOG_FILE"
    reset_az_controls
    reset_curl_controls
}

run_case_with_auth() {
    local fixture="$1"
    local retries="${2:-__default__}"
    local cache_key="${3:-__unset__}"
    local env_key="${4:-__unset__}"
    local home_dir="${5:-$HOME}"
    local stdout_file
    local stderr_file
    stdout_file="$(mktemp "${TMP_ROOT}/stdout.XXXXXX")"
    stderr_file="$(mktemp "${TMP_ROOT}/stderr.XXXXXX")"

    if (
        export PATH="$fixture/bin:$PATH"
        export HOME="$home_dir"
        if [[ "$retries" == "__default__" ]]; then
            unset CODEX_MAX_RETRIES
        else
            export CODEX_MAX_RETRIES="$retries"
        fi
        source "$CONTEXT_GUARD_SH"
        case "$cache_key" in
            __unset__) unset _CODEX54_AZURE_API_KEY ;;
            *) export _CODEX54_AZURE_API_KEY="$cache_key" ;;
        esac
        case "$env_key" in
            __unset__) unset AZURE_OPENAI_API_KEY ;;
            *) export AZURE_OPENAI_API_KEY="$env_key" ;;
        esac
        codex54_exec_with_guard "test prompt"
    ) >"$stdout_file" 2>"$stderr_file"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    LAST_STDOUT="$(cat "$stdout_file")"
    LAST_STDERR="$(cat "$stderr_file")"
    rm -f "$stdout_file" "$stderr_file"
}

run_preflight_with_auth() {
    local fixture="$1"
    local cache_key="${2:-__unset__}"
    local env_key="${3:-__unset__}"
    local home_dir="${4:-$HOME}"
    local stdout_file
    local stderr_file
    stdout_file="$(mktemp "${TMP_ROOT}/stdout.XXXXXX")"
    stderr_file="$(mktemp "${TMP_ROOT}/stderr.XXXXXX")"

    if (
        export PATH="$fixture/bin:$PATH"
        export HOME="$home_dir"
        source "$CONTEXT_GUARD_SH"
        case "$cache_key" in
            __unset__) unset _CODEX54_AZURE_API_KEY ;;
            *) export _CODEX54_AZURE_API_KEY="$cache_key" ;;
        esac
        case "$env_key" in
            __unset__) unset AZURE_OPENAI_API_KEY ;;
            *) export AZURE_OPENAI_API_KEY="$env_key" ;;
        esac
        codex54_auth_preflight
    ) >"$stdout_file" 2>"$stderr_file"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    LAST_STDOUT="$(cat "$stdout_file")"
    LAST_STDERR="$(cat "$stderr_file")"
    rm -f "$stdout_file" "$stderr_file"
}

run_endpoint_lookup() {
    local fixture="$1"
    local home_dir="${2:-$HOME}"
    local endpoint_value="${3:-__unset__}"
    local stdout_file
    local stderr_file
    stdout_file="$(mktemp "${TMP_ROOT}/stdout.XXXXXX")"
    stderr_file="$(mktemp "${TMP_ROOT}/stderr.XXXXXX")"

    if (
        export PATH="$fixture/bin:$PATH"
        export HOME="$home_dir"
        source "$CONTEXT_GUARD_SH"
        case "$endpoint_value" in
            __unset__) unset AZURE_OPENAI_ENDPOINT ;;
            *) export AZURE_OPENAI_ENDPOINT="$endpoint_value" ;;
        esac
        _codex54_get_validation_endpoint
    ) >"$stdout_file" 2>"$stderr_file"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    LAST_STDOUT="$(cat "$stdout_file")"
    LAST_STDERR="$(cat "$stderr_file")"
    rm -f "$stdout_file" "$stderr_file"
}

run_case() {
    local fixture="$1"
    local retries="${2:-__default__}"
    run_case_with_auth "$fixture" "$retries" "fake" "__unset__"
}

assert_status() {
    local expected="$1"
    if [[ "$LAST_STATUS" -ne "$expected" ]]; then
        return 1
    fi
}

assert_call_count() {
    local expected="$1"
    local actual=0
    [[ -f "$CALL_COUNT_FILE" ]] && actual=$(cat "$CALL_COUNT_FILE")
    if [[ "$actual" -ne "$expected" ]]; then
        return 1
    fi
}

assert_curl_call_count() {
    local expected="$1"
    local actual=0
    [[ -f "$CURL_CALL_COUNT_FILE" ]] && actual=$(cat "$CURL_CALL_COUNT_FILE")
    if [[ "$actual" -ne "$expected" ]]; then
        return 1
    fi
}

assert_stderr_contains() {
    local needle="$1"
    printf '%s' "$LAST_STDERR" | grep -Fq "$needle"
}

assert_stderr_not_contains() {
    local needle="$1"
    if printf '%s' "$LAST_STDERR" | grep -Fq "$needle"; then
        return 1
    fi
}

assert_stdout_equals() {
    local expected="$1"
    [[ "$LAST_STDOUT" == "$expected" ]]
}

assert_stderr_count() {
    local needle="$1"
    local expected="$2"
    local actual=0
    actual=$(printf '%s' "$LAST_STDERR" | grep -Foc "$needle" || true)
    [[ "$actual" -eq "$expected" ]]
}

assert_args_contains() {
    local needle="$1"
    grep -Fq -- "$needle" "$ARGS_FILE"
}

assert_stdin_contains() {
    local needle="$1"
    grep -Fq -- "$needle" "$STDIN_FILE"
}

assert_args_log_contains() {
    local needle="$1"
    grep -Fq -- "$needle" "$ARGS_LOG_FILE"
}

assert_az_log_contains() {
    local needle="$1"
    grep -Fq -- "$needle" "$AZ_LOG_FILE"
}

assert_az_log_not_contains() {
    local needle="$1"
    if grep -Fq -- "$needle" "$AZ_LOG_FILE"; then
        return 1
    fi
}

assert_curl_log_contains() {
    local needle="$1"
    grep -Fq -- "$needle" "$CURL_LOG_FILE"
}

assert_curl_log_not_contains() {
    local needle="$1"
    if grep -Fq -- "$needle" "$CURL_LOG_FILE"; then
        return 1
    fi
}

source_lauren_loop_codex_auth_helpers() {
    local helper_block
    YELLOW=""
    NC=""
    helper_block="$(awk '
        /^_v2_reset_codex_auth_preflight_state\(\)/ { capture=1 }
        /^_codex_attempt_artifact_path\(\)/ { capture=0 }
        capture { print }
    ' "$REPO_ROOT/lauren-loop-v2.sh")"
    eval "$helper_block"
}

# Flatten Lauren loop shell statements into `line<TAB>statement` records.
# This is intentionally narrow: it ignores blank lines and full-line comments,
# joins trailing-backslash continuations, and is only used with anchored
# dispatch/resolution patterns below. It is not a general Bash parser.
lauren_loop_code_statements() {
    local source_file="${1:-$REPO_ROOT/lauren-loop-v2.sh}"
    awk '
        function flush() {
            if (stmt != "") {
                print stmt_line "\t" stmt
                stmt=""
                stmt_line=0
            }
        }

        /^[[:space:]]*#/ { next }

        {
            if ($0 ~ /^[[:space:]]*$/) {
                flush()
                next
            }

            if (stmt == "") {
                stmt=$0
                stmt_line=NR
            } else {
                stmt=stmt " " $0
            }

            if ($0 ~ /\\[[:space:]]*$/) {
                sub(/\\[[:space:]]*$/, "", stmt)
                next
            }

            flush()
        }

        END {
            flush()
        }
    ' "$source_file"
}

lauren_loop_dispatch_statements() {
    local source_file="${1:-$REPO_ROOT/lauren-loop-v2.sh}"
    lauren_loop_code_statements "$source_file" \
        | awk -F '\t' '$2 ~ /^[[:space:]]*(run_agent|run_critic_loop)[[:space:]]/ { print $2 }'
}

# Prove the stronger invariant that every dynamic engine dispatch in
# `lauren-loop-v2.sh` uses one `_effective_*_engine` local, and that local is
# populated exactly once from `_V2_EFFECTIVE_ENGINE` immediately after exactly
# one `_resolve_effective_engine` call. Literal `"claude"` / `"codex"`
# dispatches are allowed and intentionally bypass this audit.
verify_lauren_loop_dispatch_resolution_provenance() {
    local source_file="${1:-$REPO_ROOT/lauren-loop-v2.sh}"
    local statements_file="$TMP_ROOT/lauren-loop-code-statements.tsv"
    local report_file="$TMP_ROOT/lauren-loop-dispatch-provenance.txt"

    lauren_loop_code_statements "$source_file" > "$statements_file"
    [[ -s "$statements_file" ]] || return 1

    if ! awk -F '\t' '
        function add_error(msg) {
            errors[++error_count]=msg
        }

        function extract_effective_from_assignment(stmt, value) {
            value=stmt
            sub(/^[[:space:]]*_effective_/, "", value)
            sub(/="\$_V2_EFFECTIVE_ENGINE"[[:space:]]*$/, "", value)
            return value
        }

        function extract_effective_from_run_agent(stmt, value) {
            value=stmt
            sub(/^[[:space:]]*run_agent[[:space:]]+"[^"]+"[[:space:]]+"\$_effective_/, "", value)
            sub(/"[[:space:]].*$/, "", value)
            return value
        }

        function extract_effective_from_run_critic_loop(stmt, value) {
            value=stmt
            sub(/^.*"\$_effective_/, "", value)
            sub(/"[[:space:]]*(\|\||$).*$/, "", value)
            return value
        }

        function note_dynamic_dispatch(effective_var, line, kind) {
            dynamic_dispatch_count[effective_var]++
            if (!(effective_var in first_dispatch_line) || line < first_dispatch_line[effective_var]) {
                first_dispatch_line[effective_var]=line
                first_dispatch_kind[effective_var]=kind
            }
            if (!(effective_var in effective_assign_line)) {
                add_error(sprintf("line %s: %s dispatch uses %s without a prior _V2_EFFECTIVE_ENGINE assignment", line, kind, effective_var))
            } else if (effective_assign_line[effective_var] > line) {
                add_error(sprintf("line %s: %s dispatch uses %s before line %s populates it from _V2_EFFECTIVE_ENGINE", line, kind, effective_var, effective_assign_line[effective_var]))
            }
        }

        BEGIN {
            pending_resolve_line=0
            pending_resolve_stmt=""
        }

        {
            line=$1
            stmt=$2

            if (pending_resolve_line != 0 &&
                stmt !~ /^[[:space:]]*_effective_[A-Za-z0-9_]+_engine="\$_V2_EFFECTIVE_ENGINE"[[:space:]]*$/) {
                add_error(sprintf("line %s: expected _effective_*_engine=\"$_V2_EFFECTIVE_ENGINE\" immediately after _resolve_effective_engine at line %s", line, pending_resolve_line))
                pending_resolve_line=0
                pending_resolve_stmt=""
            }

            if (stmt ~ /^[[:space:]]*_resolve_effective_engine[[:space:]]+"[^"]+"[[:space:]]*$/) {
                if (pending_resolve_line != 0) {
                    add_error(sprintf("line %s: encountered a second _resolve_effective_engine before consuming the call at line %s", line, pending_resolve_line))
                }
                pending_resolve_line=line
                pending_resolve_stmt=stmt
                next
            }

            if (stmt ~ /^[[:space:]]*_effective_[A-Za-z0-9_]+_engine="\$_V2_EFFECTIVE_ENGINE"[[:space:]]*$/) {
                effective_var=extract_effective_from_assignment(stmt)
                effective_assign_count[effective_var]++
                effective_assign_line[effective_var]=line
                if (pending_resolve_line == 0) {
                    add_error(sprintf("line %s: %s is populated from _V2_EFFECTIVE_ENGINE without an immediately preceding _resolve_effective_engine call", line, effective_var))
                } else {
                    effective_resolve_count[effective_var]++
                    effective_resolve_line[effective_var]=pending_resolve_line
                }
                pending_resolve_line=0
                pending_resolve_stmt=""
                next
            }

            if (stmt ~ /^[[:space:]]*run_agent[[:space:]]/) {
                if (stmt ~ /^[[:space:]]*run_agent[[:space:]]+"[^"]+"[[:space:]]+"(claude|codex)"[[:space:]]+/) {
                    next
                }
                if (stmt ~ /^[[:space:]]*run_agent[[:space:]]+"[^"]+"[[:space:]]+"\$_effective_[A-Za-z0-9_]+_engine"[[:space:]]+/) {
                    note_dynamic_dispatch(extract_effective_from_run_agent(stmt), line, "run_agent")
                    next
                }
                add_error(sprintf("line %s: run_agent engine arg must be a quoted literal or quoted $_effective_*_engine local", line))
                next
            }

            if (stmt ~ /^[[:space:]]*run_critic_loop[[:space:]]/) {
                if (stmt ~ /"(claude|codex)"[[:space:]]*(\|\||$)/) {
                    next
                }
                if (stmt ~ /"\$_effective_[A-Za-z0-9_]+_engine"[[:space:]]*(\|\||$)/) {
                    note_dynamic_dispatch(extract_effective_from_run_critic_loop(stmt), line, "run_critic_loop")
                    next
                }
                add_error(sprintf("line %s: run_critic_loop engine arg must be a quoted literal or quoted $_effective_*_engine local", line))
                next
            }
        }

        END {
            if (pending_resolve_line != 0) {
                add_error(sprintf("line %s: _resolve_effective_engine is not immediately followed by an _effective_*_engine assignment", pending_resolve_line))
            }

            for (effective_var in dynamic_dispatch_count) {
                if (dynamic_dispatch_count[effective_var] != 1) {
                    add_error(sprintf("%s reaches %d dynamic dispatches; expected exactly 1", effective_var, dynamic_dispatch_count[effective_var]))
                }
                if (effective_assign_count[effective_var] != 1) {
                    add_error(sprintf("%s is populated from _V2_EFFECTIVE_ENGINE %d times; expected exactly 1", effective_var, effective_assign_count[effective_var]))
                }
                if (effective_resolve_count[effective_var] != 1) {
                    add_error(sprintf("%s is paired with %d _resolve_effective_engine calls; expected exactly 1", effective_var, effective_resolve_count[effective_var]))
                }
            }

            for (effective_var in effective_assign_count) {
                if (dynamic_dispatch_count[effective_var] != 1) {
                    add_error(sprintf("%s is populated from _V2_EFFECTIVE_ENGINE but reaches %d dynamic dispatches; expected exactly 1", effective_var, dynamic_dispatch_count[effective_var]))
                }
            }

            if (error_count > 0) {
                for (i = 1; i <= error_count; i++) {
                    print errors[i]
                }
                exit 1
            }
        }
    ' "$statements_file" > "$report_file"; then
        cat "$report_file" >&2
        return 1
    fi
}

run_test() {
    local name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name" "status=$LAST_STATUS calls=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0) curl_calls=$(cat "$CURL_CALL_COUNT_FILE" 2>/dev/null || echo 0) stderr=$(printf '%s' "$LAST_STDERR" | tr '\n' ' ')"
    fi
}

fixture="$(create_fixture)"

test_success() {
    write_control "0::"
    run_case "$fixture"
    assert_status 0
    assert_call_count 1
    assert_stderr_not_contains "Codex retry"
}

test_stream_retry_success() {
    write_control "1:stream disconnected before completion: response.failed event received:2"
    run_case "$fixture"
    assert_status 0 &&
    assert_call_count 2 &&
    assert_stderr_contains "Codex retry 1/2 after stream failure (sleep 5s)"
}

test_stream_retry_exhausted() {
    write_control "1:stream disconnected before completion: response.failed event received:"
    run_case "$fixture"
    assert_status 1 &&
    assert_call_count 3 &&
    assert_stderr_contains "Codex retry 1/2 after stream failure (sleep 5s)" &&
    assert_stderr_contains "Codex retry 2/2 after stream failure (sleep 15s)" &&
    assert_stderr_contains "Codex failed after 3 attempts (stream failures)"
}

test_content_filter_no_retry() {
    write_control "1:response.failed event received content_filter:"
    run_case "$fixture"
    assert_status 1
    assert_call_count 1
    assert_stderr_not_contains "Codex retry"
    assert_stderr_contains "Codex failed (exit 1) - content filter rejection, skipping retry"
}

test_auth_failure_no_retry() {
    write_control "1:authentication failed:"
    run_case "$fixture"
    assert_status 1
    assert_call_count 1
    assert_stderr_not_contains "Codex retry"
    assert_stderr_contains "Codex failed (exit 1) - not a stream failure, skipping retry"
}

test_exit_42_preserved() {
    write_control "42:unknown error:"
    run_case "$fixture"
    assert_status 42
    assert_call_count 1
    assert_stderr_not_contains "Codex retry"
    assert_stderr_contains "Codex failed (exit 42) - not a stream failure, skipping retry"
}

test_exit_127_preserved() {
    write_control "127:command not found:"
    run_case "$fixture"
    assert_status 127
    assert_call_count 1
    assert_stderr_not_contains "Codex retry"
}

test_zero_retries() {
    write_control "1:stream disconnected before completion: response.failed event received:"
    run_case "$fixture" "0"
    assert_status 1
    assert_call_count 1
    assert_stderr_not_contains "Codex retry"
    assert_stderr_contains "Codex failed after 1 attempts (stream failures)"
}

test_env_key_skips_azure_and_keyvault() {
    write_control "0::"
    set_az_account_mode "fail"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "__unset__" "env-secret"
    assert_status 0 &&
    assert_call_count 1 &&
    assert_az_log_not_contains "account show" &&
    assert_az_log_not_contains "keyvault secret show"
}

test_cache_key_skips_azure_and_keyvault() {
    write_control "0::"
    set_az_account_mode "fail"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "__unset__"
    assert_status 0 &&
    assert_call_count 1 &&
    assert_az_log_not_contains "account show" &&
    assert_az_log_not_contains "keyvault secret show"
}

test_keyvault_failure_without_cache_or_env_is_clear_error() {
    write_control "0::"
    set_az_account_mode "ok"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "__unset__" "__unset__"
    assert_status 1 &&
    assert_call_count 0 &&
    assert_az_log_contains "account show" &&
    assert_az_log_contains "keyvault secret show --vault-name newchampionxpertkeyvault --name gpt54 --query value -o tsv" &&
    assert_stderr_contains "No Codex 5.4 API key is available in _CODEX54_AZURE_API_KEY or AZURE_OPENAI_API_KEY, and Key Vault lookup failed"
}

test_exec_subcommand_uses_guarded_path() {
    write_control "0::"

    if (
        export PATH="$fixture/bin:$PATH"
        source "$CONTEXT_GUARD_SH"
        export _CODEX54_AZURE_API_KEY="fake"
        codex54_with_guard exec "test prompt"
    ) >/dev/null 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0
    assert_call_count 1
    assert_args_contains "--dangerously-bypass-approvals-and-sandbox"
    assert_args_contains "--ephemeral"
    assert_args_contains "INDUSTRIAL CONTEXT:"
    assert_args_contains "test prompt"
}

test_profile_override_switches_codex_profile() {
    write_control "0::"

    if (
        export PATH="$fixture/bin:$PATH"
        source "$CONTEXT_GUARD_SH"
        export _CODEX54_AZURE_API_KEY="fake"
        codex54_exec_with_guard --profile azure54med "test prompt"
    ) >/dev/null 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0
    assert_call_count 1
    assert_args_contains "-p"
    assert_args_contains "azure54med"
}

test_stdin_prompt_gets_industrial_context() {
    write_control "0::"

    if (
        export PATH="$fixture/bin:$PATH"
        source "$CONTEXT_GUARD_SH"
        export _CODEX54_AZURE_API_KEY="fake"
        printf 'stdin chemical prompt\n' | codex54_exec_with_guard -
    ) >/dev/null 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0
    assert_call_count 1
    assert_args_contains "-"
    assert_stdin_contains "INDUSTRIAL CONTEXT:"
    assert_stdin_contains "stdin chemical prompt"
}

test_lauren_loop_preflight_failure_sets_auth_breaker() {
    local result_dir="$TMP_ROOT/lauren-auth-failure"
    rm -rf "$result_dir"
    mkdir -p "$result_dir"

    if (
        source_lauren_loop_codex_auth_helpers
        _v2_reset_codex_auth_preflight_state
        _V2_CODEX_RUN_FAILURES=0
        PREFLIGHT_CALLS=0
        LOG_CAPTURE_FILE="$result_dir/log-capture"
        log_execution() {
            printf '%s\n' "$2" > "$LOG_CAPTURE_FILE"
        }
        codex54_auth_preflight() {
            PREFLIGHT_CALLS=$((PREFLIGHT_CALLS + 1))
            echo "Error: No Codex 5.4 API key is available in _CODEX54_AZURE_API_KEY or AZURE_OPENAI_API_KEY, and Key Vault lookup failed" >&2
            return 1
        }

        _v2_preflight_codex_auth_once || true
        _v2_preflight_codex_auth_once || true

        printf '%s\n' "$PREFLIGHT_CALLS" > "$result_dir/calls"
        printf '%s\n' "${_V2_CODEX_AUTH_CIRCUIT_OPEN}" > "$result_dir/open"
        printf '%s\n' "$(_v2_codex_skip_reason)" > "$result_dir/reason"
        if _v2_should_skip_codex; then
            printf 'true\n' > "$result_dir/skip"
        else
            printf 'false\n' > "$result_dir/skip"
        fi
        if ( _v2_should_skip_codex ); then
            printf 'true\n' > "$result_dir/subskip"
        else
            printf 'false\n' > "$result_dir/subskip"
        fi
        _v2_log_codex_circuit_breaker_trip "/tmp/task.md" "planner-b" > "$result_dir/log-output" 2>&1
    ); then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0 &&
    [[ "$(cat "$result_dir/calls")" == "1" ]] &&
    [[ "$(cat "$result_dir/open")" == "true" ]] &&
    [[ "$(cat "$result_dir/reason")" == "auth_preflight" ]] &&
    [[ "$(cat "$result_dir/skip")" == "true" ]] &&
    [[ "$(cat "$result_dir/subskip")" == "true" ]] &&
    grep -Fq "Codex auth preflight failed — using Claude for planner-b" "$result_dir/log-output" &&
    grep -Fq "Codex auth preflight failed for planner-b" "$result_dir/log-capture"
}

test_lauren_loop_preflight_success_allows_codex_roles() {
    local result_dir="$TMP_ROOT/lauren-auth-success"
    rm -rf "$result_dir"
    mkdir -p "$result_dir"

    if (
        source_lauren_loop_codex_auth_helpers
        _v2_reset_codex_auth_preflight_state
        _V2_CODEX_RUN_FAILURES=0
        PREFLIGHT_CALLS=0
        codex54_auth_preflight() {
            PREFLIGHT_CALLS=$((PREFLIGHT_CALLS + 1))
            return 0
        }

        _v2_preflight_codex_auth_once
        _v2_preflight_codex_auth_once

        printf '%s\n' "$PREFLIGHT_CALLS" > "$result_dir/calls"
        printf '%s\n' "${_V2_CODEX_AUTH_CIRCUIT_OPEN}" > "$result_dir/open"
        printf '%s' "$(_v2_codex_skip_reason 2>/dev/null || true)" > "$result_dir/reason"
        if _v2_should_skip_codex; then
            printf 'true\n' > "$result_dir/skip"
        else
            printf 'false\n' > "$result_dir/skip"
        fi
    ); then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0 &&
    [[ "$(cat "$result_dir/calls")" == "1" ]] &&
    [[ "$(cat "$result_dir/open")" == "false" ]] &&
    [[ ! -s "$result_dir/reason" ]] &&
    [[ "$(cat "$result_dir/skip")" == "false" ]]
}

test_lauren_loop_resolve_effective_engine_reroutes_unguarded_executor() {
    local result_dir="$TMP_ROOT/lauren-executor-reroute"
    rm -rf "$result_dir"
    mkdir -p "$result_dir"

    if (
        source_lauren_loop_codex_auth_helpers
        _v2_reset_codex_auth_preflight_state
        ENGINE_EXECUTOR="codex"
        PREFLIGHT_CALLS=0
        _V2_CODEX_AUTH_CIRCUIT_OPEN=true
        _V2_CODEX_AUTH_CIRCUIT_MESSAGE="pre-opened auth breaker"
        codex54_auth_preflight() {
            PREFLIGHT_CALLS=$((PREFLIGHT_CALLS + 1))
            return 0
        }

        _resolve_effective_engine "$ENGINE_EXECUTOR"

        printf '%s\n' "$PREFLIGHT_CALLS" > "$result_dir/calls"
        printf '%s\n' "$_V2_EFFECTIVE_ENGINE" > "$result_dir/engine"
        printf '%s\n' "$_V2_LAST_ENGINE_RESOLUTION_REASON" > "$result_dir/reason"
        printf '%s\n' "$_V2_LAST_ENGINE_RESOLUTION_REQUESTED" > "$result_dir/requested"
        printf '%s\n' "$_V2_LAST_ENGINE_RESOLUTION_RESULT" > "$result_dir/resolved"
    ); then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0 &&
    [[ "$(cat "$result_dir/calls")" == "0" ]] &&
    [[ "$(cat "$result_dir/engine")" == "claude" ]] &&
    [[ "$(cat "$result_dir/reason")" == "auth_preflight" ]] &&
    [[ "$(cat "$result_dir/requested")" == "codex" ]] &&
    [[ "$(cat "$result_dir/resolved")" == "claude" ]]
}

test_lauren_loop_dispatches_use_single_resolved_engine_locals() {
    verify_lauren_loop_dispatch_resolution_provenance "$REPO_ROOT/lauren-loop-v2.sh"
}

test_lauren_loop_critic_helper_only_forwards_engine_param() {
    local dispatch_file="$TMP_ROOT/lauren-utils-dispatches.txt"
    local violations_file="$TMP_ROOT/lauren-utils-dispatch-violations.txt"

    lauren_loop_dispatch_statements "$REPO_ROOT/lib/lauren-loop-utils.sh" > "$dispatch_file"
    [[ -s "$dispatch_file" ]] || return 1

    if grep -nEv '^[[:space:]]*run_agent[[:space:]]+"[^"]+"[[:space:]]+"\$engine"[[:space:]]+' "$dispatch_file" > "$violations_file"; then
        cat "$violations_file" >&2
        return 1
    fi
}

test_lauren_loop_run_failure_breaker_logs_distinct_reason() {
    local result_dir="$TMP_ROOT/lauren-run-failure"
    rm -rf "$result_dir"
    mkdir -p "$result_dir"

    if (
        source_lauren_loop_codex_auth_helpers
        _v2_reset_codex_auth_preflight_state
        _V2_CODEX_RUN_FAILURES=2
        LOG_CAPTURE_FILE="$result_dir/log-capture"
        log_execution() {
            printf '%s\n' "$2" > "$LOG_CAPTURE_FILE"
        }
        _v2_log_codex_circuit_breaker_trip "/tmp/task.md" "planner-b" > "$result_dir/log-output" 2>&1
    ); then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0 &&
    grep -Fq "cumulative Codex failures in this run" "$result_dir/log-output" &&
    grep -Fq "cumulative Codex failures in this run" "$result_dir/log-capture" &&
    ! grep -Fq "auth preflight" "$result_dir/log-output"
}

test_gpt54r_recovers_with_fork_after_disconnect() {
    write_control_lines \
        "1:stream disconnected before completion: response.failed event received:" \
        "0::"

    if (
        export PATH="$fixture/bin:$PATH"
        source "$CONTEXT_GUARD_SH"
        export _CODEX54_AZURE_API_KEY="fake"
        gpt54r "test prompt"
    ) >/dev/null 2>"${TMP_ROOT}/gpt54r.stderr"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    LAST_STDERR="$(cat "${TMP_ROOT}/gpt54r.stderr")"

    assert_status 0
    assert_call_count 2
    assert_stderr_contains "Codex session disconnected. Attempting recovery (1/3)"
    assert_args_contains "fork"
    assert_args_contains "--last"
    assert_args_contains "-p"
    assert_args_contains "azure54"
    assert_args_contains "Previous session disconnected. Continue from where we left off. Check repo state before repeating any actions."
}

test_gpt54r_skips_non_disconnect_failures() {
    write_control "1:authentication failed:"

    if (
        export PATH="$fixture/bin:$PATH"
        source "$CONTEXT_GUARD_SH"
        export _CODEX54_AZURE_API_KEY="fake"
        gpt54r "test prompt"
    ) >/dev/null 2>"${TMP_ROOT}/gpt54r-auth.stderr"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    LAST_STDERR="$(cat "${TMP_ROOT}/gpt54r-auth.stderr")"

    assert_status 1
    assert_call_count 1
    assert_stderr_not_contains "Attempting recovery"
    if assert_args_log_contains "fork"; then
        return 1
    fi
}

test_stale_cache_falls_through_to_valid_env() {
    write_control "0::"
    set_curl_statuses 401 200
    set_az_account_mode "fail"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "env-secret"
    assert_status 0 &&
    assert_call_count 1 &&
    assert_curl_call_count 2 &&
    assert_az_log_not_contains "account show" &&
    assert_az_log_not_contains "keyvault secret show" &&
    assert_stderr_contains "stale key from cache, trying next" &&
    assert_curl_log_contains "API_KEY cache-secret" &&
    assert_curl_log_contains "API_KEY env-secret"
}

test_stale_cache_and_env_fall_through_to_keyvault() {
    write_control "0::"
    set_curl_statuses 401 401 200
    set_az_account_mode "ok"
    set_az_keyvault_mode "ok:keyvault-secret"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "env-secret"
    assert_status 0 &&
    assert_call_count 1 &&
    assert_curl_call_count 3 &&
    assert_az_log_contains "account show" &&
    assert_az_log_contains "keyvault secret show --vault-name newchampionxpertkeyvault --name gpt54 --query value -o tsv" &&
    assert_stderr_contains "stale key from cache, trying next" &&
    assert_stderr_contains "stale key from env, trying next" &&
    assert_curl_log_contains "API_KEY keyvault-secret"
}

test_all_sources_stale_fail_preflight() {
    write_control "0::"
    set_curl_statuses 401 401 401
    set_az_account_mode "ok"
    set_az_keyvault_mode "ok:keyvault-secret"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "env-secret"
    assert_status 1 &&
    assert_call_count 0 &&
    assert_curl_call_count 3 &&
    assert_az_log_contains "account show" &&
    assert_az_log_contains "keyvault secret show --vault-name newchampionxpertkeyvault --name gpt54 --query value -o tsv" &&
    assert_stderr_contains "No valid Codex 5.4 API key is available from cache, environment, or Key Vault"
}

validation_status_is_accepted_tentatively() {
    local http_status="$1"
    write_control "0::"
    set_curl_statuses "$http_status"
    set_az_account_mode "fail"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "__unset__"
    assert_status 0 &&
    assert_call_count 1 &&
    assert_curl_call_count 1 &&
    assert_az_log_not_contains "account show" &&
    assert_az_log_not_contains "keyvault secret show" &&
    assert_stderr_contains "accepting tentatively"
}

test_validation_429_is_accepted_tentatively() {
    validation_status_is_accepted_tentatively 429
}

test_validation_503_is_accepted_tentatively() {
    validation_status_is_accepted_tentatively 503
}

test_validation_000_is_accepted_tentatively() {
    validation_status_is_accepted_tentatively 000
}

test_validation_endpoint_from_azure_openai_endpoint() {
    local home_dir="$TMP_ROOT/endpoint-from-env"
    mkdir -p "$home_dir"
    run_endpoint_lookup "$fixture" "$home_dir" "https://endpoint-env.openai.azure.com/"
    assert_status 0 &&
    assert_stdout_equals "https://endpoint-env.openai.azure.com/openai"
}

test_validation_endpoint_from_config_toml() {
    local home_dir="$TMP_ROOT/endpoint-from-config"
    mkdir -p "$home_dir/.codex"
    cat <<'EOF' > "$home_dir/.codex/config.toml"
[model_providers.other]
base_url = "https://wrong.example.com/openai"

[model_providers.azure]
name = "AzureOpenAI"
base_url = "https://endpoint-config.openai.azure.com/openai"
EOF

    run_endpoint_lookup "$fixture" "$home_dir" "__unset__"
    assert_status 0 &&
    assert_stdout_equals "https://endpoint-config.openai.azure.com/openai"
}

test_missing_validation_endpoint_falls_back_to_presence_only() {
    local home_dir="$TMP_ROOT/endpoint-missing"
    local endpoint_status=0
    local endpoint_stderr=""
    mkdir -p "$home_dir"

    run_endpoint_lookup "$fixture" "$home_dir" "__unset__"
    endpoint_status="$LAST_STATUS"
    endpoint_stderr="$LAST_STDERR"

    write_control "0::"
    set_az_account_mode "fail"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "__unset__" "$home_dir"
    [[ "$endpoint_status" -eq 1 ]] &&
    printf '%s' "$endpoint_stderr" | grep -Fq "Validation endpoint unavailable" &&
    assert_status 0 &&
    assert_call_count 1 &&
    assert_curl_call_count 0 &&
    assert_az_log_not_contains "account show" &&
    assert_stderr_contains "falling back to presence-only auth checks"
}

test_call_time_auth_retry_success() {
    write_control_lines \
        "1:unexpected status 401:" \
        "0::"
    set_curl_statuses 200 200
    set_az_account_mode "fail"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "env-secret"
    assert_status 0 &&
    assert_call_count 2 &&
    assert_curl_call_count 2 &&
    assert_az_log_not_contains "account show" &&
    assert_az_log_not_contains "keyvault secret show" &&
    assert_stderr_contains "Auth failure detected — clearing cached key and retrying once" &&
    assert_stderr_count "Auth failure detected — clearing cached key and retrying once" 1 &&
    assert_curl_log_contains "API_KEY cache-secret" &&
    assert_curl_log_contains "API_KEY env-secret"
}

test_call_time_auth_retry_exhausted_when_repreflight_fails() {
    write_control "1:unexpected status 401:"
    set_curl_statuses 200
    set_az_account_mode "ok"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "__unset__"
    assert_status 1 &&
    assert_call_count 1 &&
    assert_curl_call_count 1 &&
    assert_az_log_contains "account show" &&
    assert_az_log_contains "keyvault secret show --vault-name newchampionxpertkeyvault --name gpt54 --query value -o tsv" &&
    assert_stderr_contains "Auth failure detected — clearing cached key and retrying once" &&
    assert_stderr_contains "No Codex 5.4 API key is available in _CODEX54_AZURE_API_KEY or AZURE_OPENAI_API_KEY, and Key Vault lookup failed"
}

test_call_time_auth_retry_is_single_shot() {
    write_control_lines \
        "1:unexpected status 401:" \
        "1:Unauthorized:"
    set_curl_statuses 200 200
    set_az_account_mode "fail"
    set_az_keyvault_mode "fail"
    run_case_with_auth "$fixture" "__default__" "cache-secret" "env-secret"
    assert_status 1 &&
    assert_call_count 2 &&
    assert_curl_call_count 2 &&
    assert_az_log_not_contains "account show" &&
    assert_stderr_count "Auth failure detected — clearing cached key and retrying once" 1 &&
    assert_stderr_contains "Codex failed (exit 1) - not a stream failure, skipping retry"
}

run_test "1. success returns 0 with no retry" test_success
run_test "2. stream failure retries once and succeeds" test_stream_retry_success
run_test "3. stream failure exhausts retries" test_stream_retry_exhausted
run_test "4. content filter fails fast without retry" test_content_filter_no_retry
run_test "5. auth failure does not retry" test_auth_failure_no_retry
run_test "6. exit code 42 is preserved" test_exit_42_preserved
run_test "7. exit code 127 is preserved" test_exit_127_preserved
run_test "8. CODEX_MAX_RETRIES=0 disables retry" test_zero_retries
run_test "9. env key bypasses Azure CLI and Key Vault" test_env_key_skips_azure_and_keyvault
run_test "10. cache key bypasses Azure CLI and Key Vault" test_cache_key_skips_azure_and_keyvault
run_test "11. missing cache/env plus Key Vault failure is a clear auth error" test_keyvault_failure_without_cache_or_env_is_clear_error
run_test "12. codex54_with_guard exec uses guarded exec path" test_exec_subcommand_uses_guarded_path
run_test "13. codex54_exec_with_guard honors explicit profile override" test_profile_override_switches_codex_profile
run_test "14. stdin prompts get industrial context framing" test_stdin_prompt_gets_industrial_context
run_test "15. Lauren loop auth preflight failure opens a persistent breaker" test_lauren_loop_preflight_failure_sets_auth_breaker
run_test "16. Lauren loop auth preflight success leaves Codex available" test_lauren_loop_preflight_success_allows_codex_roles
run_test "17. _resolve_effective_engine reroutes a previously unguarded executor slot" test_lauren_loop_resolve_effective_engine_reroutes_unguarded_executor
run_test "18. Lauren loop dynamic dispatches use a single resolved engine local" test_lauren_loop_dispatches_use_single_resolved_engine_locals
run_test "19. run_critic_loop forwards only its caller-resolved engine param" test_lauren_loop_critic_helper_only_forwards_engine_param
run_test "20. Lauren loop run-failure breaker logs a distinct reason" test_lauren_loop_run_failure_breaker_logs_distinct_reason
run_test "21. gpt54r recovers with fork after stream disconnect" test_gpt54r_recovers_with_fork_after_disconnect
run_test "22. gpt54r skips non-disconnect failures" test_gpt54r_skips_non_disconnect_failures
run_test "23. stale cache falls through to a valid env key" test_stale_cache_falls_through_to_valid_env
run_test "24. stale cache and env fall through to a valid Key Vault key" test_stale_cache_and_env_fall_through_to_keyvault
run_test "25. all stale key sources fail preflight before Codex runs" test_all_sources_stale_fail_preflight
run_test "26. validation treats HTTP 429 as tentatively acceptable" test_validation_429_is_accepted_tentatively
run_test "27. validation treats HTTP 503 as tentatively acceptable" test_validation_503_is_accepted_tentatively
run_test "28. validation treats HTTP 000 as tentatively acceptable" test_validation_000_is_accepted_tentatively
run_test "29. validation endpoint normalizes AZURE_OPENAI_ENDPOINT" test_validation_endpoint_from_azure_openai_endpoint
run_test "30. validation endpoint parses the Azure base_url from config.toml" test_validation_endpoint_from_config_toml
run_test "31. missing validation endpoint falls back to presence-only preflight" test_missing_validation_endpoint_falls_back_to_presence_only
run_test "32. call-time auth retry succeeds after cache clear and re-preflight" test_call_time_auth_retry_success
run_test "33. call-time auth retry stops when re-preflight fails" test_call_time_auth_retry_exhausted_when_repreflight_fails
run_test "34. call-time auth retry is single-shot" test_call_time_auth_retry_is_single_shot

echo "${PASSED}/${TOTAL} passed"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

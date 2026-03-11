#!/bin/bash
set -euo pipefail

if [[ ! -f "$HOME/.claude/scripts/context-guard.sh" ]]; then
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
trap 'rm -rf "$TMP_ROOT"; rm -f "$CONTROL_FILE" "$CALL_COUNT_FILE" "$ARGS_FILE" "$ARGS_LOG_FILE" "$STDIN_FILE" "$STDIN_LOG_FILE"' EXIT

PASSED=0
FAILED=0
TOTAL=0
LAST_STATUS=0
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

if [[ "${1:-}" == "account" && "${2:-}" == "show" ]]; then
    exit 0
fi

if [[ "${1:-}" == "keyvault" && "${2:-}" == "secret" && "${3:-}" == "show" ]]; then
    printf 'fake\n'
    exit 0
fi

exit 0
EOF
    chmod +x "$fixture/bin/az"

    cat <<'EOF' > "$fixture/bin/sleep"
#!/bin/bash
exit 0
EOF
    chmod +x "$fixture/bin/sleep"

    printf '%s\n' "$fixture"
}

write_control() {
    printf '%s\n' "$1" > "$CONTROL_FILE"
    rm -f "$CALL_COUNT_FILE" "$ARGS_LOG_FILE" "$STDIN_LOG_FILE"
}

write_control_lines() {
    : > "$CONTROL_FILE"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$CONTROL_FILE"
    done
    rm -f "$CALL_COUNT_FILE" "$ARGS_LOG_FILE" "$STDIN_LOG_FILE"
}

run_case() {
    local fixture="$1"
    local retries="${2:-__default__}"
    local stderr_file
    stderr_file="$(mktemp "${TMP_ROOT}/stderr.XXXXXX")"

    if (
        export PATH="$fixture/bin:$PATH"
        if [[ "$retries" == "__default__" ]]; then
            unset CODEX_MAX_RETRIES
        else
            export CODEX_MAX_RETRIES="$retries"
        fi
        source ~/.claude/scripts/context-guard.sh
        export _CODEX54_AZURE_API_KEY="fake"
        codex54_exec_with_guard "test prompt"
    ) 2>"$stderr_file"; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    LAST_STDERR="$(cat "$stderr_file")"
    rm -f "$stderr_file"
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

run_test() {
    local name="$1"
    shift
    if "$@"; then
        pass "$name"
    else
        fail "$name" "status=$LAST_STATUS calls=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0) stderr=$(printf '%s' "$LAST_STDERR" | tr '\n' ' ')"
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
    assert_status 0
    assert_call_count 2
    assert_stderr_contains "Codex retry 1/2 after stream failure (sleep 2s)"
}

test_stream_retry_exhausted() {
    write_control "1:stream disconnected before completion: response.failed event received:"
    run_case "$fixture"
    assert_status 1
    assert_call_count 3
    assert_stderr_contains "Codex retry 1/2 after stream failure (sleep 2s)"
    assert_stderr_contains "Codex retry 2/2 after stream failure (sleep 5s)"
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

test_exec_subcommand_uses_guarded_path() {
    write_control "0::"

    if (
        export PATH="$fixture/bin:$PATH"
        source ~/.claude/scripts/context-guard.sh
        export _CODEX54_AZURE_API_KEY="fake"
        codex54_with_guard exec "test prompt"
    ) >/dev/null 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    assert_status 0
    assert_call_count 1
    assert_args_contains "--full-auto"
    assert_args_contains "--ephemeral"
    assert_args_contains "INDUSTRIAL CONTEXT:"
    assert_args_contains "test prompt"
}

test_profile_override_switches_codex_profile() {
    write_control "0::"

    if (
        export PATH="$fixture/bin:$PATH"
        source ~/.claude/scripts/context-guard.sh
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
        source ~/.claude/scripts/context-guard.sh
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

test_gpt54r_recovers_with_fork_after_disconnect() {
    write_control_lines \
        "1:stream disconnected before completion: response.failed event received:" \
        "0::"

    if (
        export PATH="$fixture/bin:$PATH"
        source ~/.claude/scripts/context-guard.sh
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
        source ~/.claude/scripts/context-guard.sh
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

run_test "1. success returns 0 with no retry" test_success
run_test "2. stream failure retries once and succeeds" test_stream_retry_success
run_test "3. stream failure exhausts retries" test_stream_retry_exhausted
run_test "4. content filter fails fast without retry" test_content_filter_no_retry
run_test "5. auth failure does not retry" test_auth_failure_no_retry
run_test "6. exit code 42 is preserved" test_exit_42_preserved
run_test "7. exit code 127 is preserved" test_exit_127_preserved
run_test "8. CODEX_MAX_RETRIES=0 disables retry" test_zero_retries
run_test "9. codex54_with_guard exec uses guarded exec path" test_exec_subcommand_uses_guarded_path
run_test "10. codex54_exec_with_guard honors explicit profile override" test_profile_override_switches_codex_profile
run_test "11. stdin prompts get industrial context framing" test_stdin_prompt_gets_industrial_context
run_test "12. gpt54r recovers with fork after stream disconnect" test_gpt54r_recovers_with_fork_after_disconnect
run_test "13. gpt54r skips non-disconnect failures" test_gpt54r_skips_non_disconnect_failures

echo "${PASSED}/${TOTAL} passed"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

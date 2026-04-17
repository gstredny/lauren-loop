#!/usr/bin/env bash
#
# test_bootstrap_wrapper.sh — Focused coverage for nightshift-bootstrap.sh.
#
# Usage: bash scripts/nightshift/tests/test_bootstrap_wrapper.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TMP_DIR"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

setup_wrapper_fixture() {
    local repo_dir="$1"
    local ns_dir="$repo_dir/scripts/nightshift"
    local python_dir="$ns_dir/python"
    local venv_bin="$repo_dir/.venv/bin"

    mkdir -p "$ns_dir" "$python_dir" "$venv_bin"
    cp "$NS_DIR/nightshift-bootstrap.sh" "$ns_dir/nightshift-bootstrap.sh"
    chmod +x "$ns_dir/nightshift-bootstrap.sh"

    cat > "$venv_bin/python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

capture_file="${RUNNER_CAPTURE_FILE:?}"
{
    printf 'cwd=%s\n' "$(pwd)"
    printf 'status=%s\n' "${NIGHTSHIFT_BOOTSTRAP_STATUS:-}"
    printf 'warning=%s\n' "${NIGHTSHIFT_BOOTSTRAP_WARNING:-}"
    printf 'repair_status=%s\n' "${NIGHTSHIFT_BOOTSTRAP_REPAIR_STATUS:-}"
    printf 'repair_note=%s\n' "${NIGHTSHIFT_BOOTSTRAP_REPAIR_NOTE:-}"
    printf 'repair_log=%s\n' "${NIGHTSHIFT_BOOTSTRAP_REPAIR_LOG:-}"
    printf 'argc=%s\n' "$#"
    index=1
    for arg in "$@"; do
        printf 'arg%s=%s\n' "$index" "$arg"
        index=$((index + 1))
    done
} > "$capture_file"
EOF
    chmod +x "$venv_bin/python"
}

setup_git_stub() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${GIT_STUB_STATE_DIR:?}"
log_file="${GIT_STUB_LOG_FILE:?}"

read_counter() {
    local path="$1"
    if [[ -f "$path" ]]; then
        cat "$path"
    else
        printf '0\n'
    fi
}

decrement_counter_if_needed() {
    local path="$1"
    local value
    value="$(read_counter "$path")"
    if (( value > 0 )); then
        printf '%s\n' $((value - 1)) > "$path"
        return 0
    fi
    return 1
}

printf '%s\n' "$*" >> "$log_file"

case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--is-inside-work-tree" ]]; then
            rc="$(read_counter "$state_dir/inside_work_tree_rc")"
            if [[ "$rc" == "0" ]]; then
                printf 'true\n'
                exit 0
            fi
            exit "$rc"
        fi
        ;;
    fetch)
        if decrement_counter_if_needed "$state_dir/fetch_failures_remaining"; then
            printf 'fetch failed\n' >&2
            exit 1
        fi
        exit 0
        ;;
    checkout)
        if [[ "${2:-}" == "--detach" ]]; then
            if decrement_counter_if_needed "$state_dir/detach_failures_remaining"; then
                printf 'detach failed\n' >&2
                exit 1
            fi
            exit 0
        fi
        ;;
    status)
        if [[ "${2:-}" == "--porcelain" && "${3:-}" == "--untracked-files=no" ]]; then
            cat "$state_dir/tracked_status_output" 2>/dev/null || true
            exit 0
        fi
        ;;
    reset)
        if [[ "$(read_counter "$state_dir/reset_should_fail")" == "1" ]]; then
            printf 'reset failed\n' >&2
            exit 1
        fi
        printf 'HEAD is now at bootstrap-test\n'
        exit 0
        ;;
    clean)
        if [[ "$(read_counter "$state_dir/clean_should_fail")" == "1" ]]; then
            printf 'clean failed\n' >&2
            exit 1
        fi
        exit 0
        ;;
    for-each-ref)
        cat "$state_dir/branch_list" 2>/dev/null || true
        exit 0
        ;;
    branch)
        if [[ "${2:-}" == "-D" ]]; then
            shift 2
            for branch_name in "$@"; do
                printf 'Deleted branch %s (was bootstrap-test).\n' "$branch_name"
            done
            exit 0
        fi
        ;;
esac

printf 'unsupported git stub invocation: %s\n' "$*" >&2
exit 1
EOF
    chmod +x "$bin_dir/git"
}

setup_sleep_stub() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$1" >> "${SLEEP_LOG_FILE:?}"
EOF
    chmod +x "$bin_dir/sleep"
}

echo "=== test_bootstrap_wrapper.sh ==="
echo ""

(
    test_dir="$TMP_DIR/w1"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"

    setup_wrapper_fixture "$repo_dir"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"
    printf 'nightshift/stale-a\nnightshift/stale-b\n' > "$state_dir/branch_list"

    PATH="$stub_dir:$PATH" \
    GIT_STUB_STATE_DIR="$state_dir" \
    GIT_STUB_LOG_FILE="$git_log" \
    SLEEP_LOG_FILE="$sleep_log" \
    RUNNER_CAPTURE_FILE="$capture_file" \
    bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh" --smoke --dry-run

    grep -Fxq "cwd=$repo_dir/scripts/nightshift/python" "$capture_file" &&
    grep -Fxq 'status=fresh' "$capture_file" &&
    grep -Fxq 'warning=' "$capture_file" &&
    grep -Fxq 'repair_status=not-needed' "$capture_file" &&
    grep -Fxq 'arg1=-m' "$capture_file" &&
    grep -Fxq 'arg2=nightshift' "$capture_file" &&
    grep -Fxq 'arg3=--smoke' "$capture_file" &&
    grep -Fxq 'arg4=--dry-run' "$capture_file" &&
    grep -Fxq 'fetch origin main' "$git_log" &&
    grep -Fxq 'checkout --detach origin/main' "$git_log" &&
    grep -Fxq 'for-each-ref --format=%(refname:short) refs/heads/nightshift/*' "$git_log" &&
    grep -Fxq 'branch -D nightshift/stale-a nightshift/stale-b' "$git_log" &&
    [[ ! -s "$sleep_log" ]]
) && pass "1. wrapper fetches, detaches, prunes, and execs the core runner" \
  || fail "1. wrapper fetches, detaches, prunes, and execs the core runner" "fresh bootstrap path was wrong"

(
    test_dir="$TMP_DIR/w2"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"
    printf '2\n' > "$state_dir/fetch_failures_remaining"

    setup_wrapper_fixture "$repo_dir"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"

    PATH="$stub_dir:$PATH" \
    GIT_STUB_STATE_DIR="$state_dir" \
    GIT_STUB_LOG_FILE="$git_log" \
    SLEEP_LOG_FILE="$sleep_log" \
    RUNNER_CAPTURE_FILE="$capture_file" \
    bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh"

    grep -Fxq 'status=fresh' "$capture_file" &&
    grep -Fxq 'repair_status=not-needed' "$capture_file" &&
    [[ "$(grep -c '^fetch origin main$' "$git_log")" == "3" ]] &&
    grep -Fxq '30' "$sleep_log" &&
    grep -Fxq '120' "$sleep_log"
) && pass "2. wrapper retries fetch with 30s and 120s backoff before succeeding" \
  || fail "2. wrapper retries fetch with 30s and 120s backoff before succeeding" "fetch retry/backoff behavior was wrong"

(
    test_dir="$TMP_DIR/w3"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"
    printf '1\n' > "$state_dir/detach_failures_remaining"

    setup_wrapper_fixture "$repo_dir"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"

    PATH="$stub_dir:$PATH" \
    GIT_STUB_STATE_DIR="$state_dir" \
    GIT_STUB_LOG_FILE="$git_log" \
    SLEEP_LOG_FILE="$sleep_log" \
    RUNNER_CAPTURE_FILE="$capture_file" \
    bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh"

    repair_log="$(sed -n 's/^repair_log=//p' "$capture_file")"

    grep -Fxq 'status=fresh' "$capture_file" &&
    grep -Fxq 'repair_status=force-clean-succeeded' "$capture_file" &&
    grep -Fxq 'repair_note=detach-retry-succeeded-after-reset-clean' "$capture_file" &&
    [[ "$(grep -c '^checkout --detach origin/main$' "$git_log")" == "2" ]] &&
    grep -Fxq 'reset --hard HEAD' "$git_log" &&
    grep -Fxq 'clean -fd' "$git_log" &&
    [[ -n "$repair_log" ]] &&
    grep -Fq 'force-clean-succeeded' "$repair_log"
) && pass "3. wrapper repairs with reset/clean once before retrying detach" \
  || fail "3. wrapper repairs with reset/clean once before retrying detach" "detach repair path was wrong"

(
    test_dir="$TMP_DIR/w4"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"
    printf '999\n' > "$state_dir/detach_failures_remaining"

    setup_wrapper_fixture "$repo_dir"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"

    set +e
    PATH="$stub_dir:$PATH" \
    GIT_STUB_STATE_DIR="$state_dir" \
    GIT_STUB_LOG_FILE="$git_log" \
    SLEEP_LOG_FILE="$sleep_log" \
    RUNNER_CAPTURE_FILE="$capture_file" \
    bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh" 2>&1
    rc=$?
    set -e

    logs_dir="$repo_dir/scripts/nightshift/logs"
    repair_log="$logs_dir/bootstrap-repair.log"

    [[ "$rc" -ne 0 ]] &&
    [[ ! -e "$capture_file" ]] &&
    ls "$logs_dir"/bootstrap-failure-*.json >/dev/null 2>&1 &&
    artifact="$(ls "$logs_dir"/bootstrap-failure-*.json | head -n 1)" &&
    grep -Fq '"reason"' "$artifact" &&
    grep -Fq 'Could not detach' "$artifact" &&
    grep -Fq 'force-clean-fallback' "$artifact" &&
    grep -Fxq 'reset --hard HEAD' "$git_log" &&
    grep -Fxq 'clean -fd' "$git_log" &&
    [[ -f "$repair_log" ]] &&
    grep -Fq 'force-clean-fallback' "$repair_log"
) && pass "4. wrapper exits non-zero when detach still fails after the reset/clean repair" \
  || fail "4. wrapper exits non-zero when detach still fails after the reset/clean repair" "post-repair fail-hard was wrong"

(
    test_dir="$TMP_DIR/w5"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"

    setup_wrapper_fixture "$repo_dir"
    rm -f "$repo_dir/.venv/bin/python"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"

    set +e
    output="$(
        PATH="$stub_dir:$PATH" \
        GIT_STUB_STATE_DIR="$state_dir" \
        GIT_STUB_LOG_FILE="$git_log" \
        SLEEP_LOG_FILE="$sleep_log" \
        RUNNER_CAPTURE_FILE="$capture_file" \
        bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh" 2>&1
    )"
    rc=$?
    set -e

    [[ "$rc" -ne 0 ]] &&
    grep -Fq 'Python binary missing or not executable' <<< "$output" &&
    [[ ! -e "$capture_file" ]]
) && pass "5. wrapper fails closed when the Python orchestrator entrypoint is missing" \
  || fail "5. wrapper fails closed when the Python orchestrator entrypoint is missing" "missing Python entrypoint was not treated as fatal"

(
    test_dir="$TMP_DIR/w6"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"
    printf '3\n' > "$state_dir/fetch_failures_remaining"

    setup_wrapper_fixture "$repo_dir"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"

    set +e
    PATH="$stub_dir:$PATH" \
    GIT_STUB_STATE_DIR="$state_dir" \
    GIT_STUB_LOG_FILE="$git_log" \
    SLEEP_LOG_FILE="$sleep_log" \
    RUNNER_CAPTURE_FILE="$capture_file" \
    bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh" 2>&1
    rc=$?
    set -e

    logs_dir="$repo_dir/scripts/nightshift/logs"

    [[ "$rc" -ne 0 ]] &&
    [[ ! -e "$capture_file" ]] &&
    ls "$logs_dir"/bootstrap-failure-*.json >/dev/null 2>&1 &&
    artifact="$(ls "$logs_dir"/bootstrap-failure-*.json | head -n 1)" &&
    grep -Fq 'Could not fetch' "$artifact" &&
    [[ "$(grep -c '^fetch origin main$' "$git_log")" == "3" ]] &&
    ! grep -Fxq 'checkout --detach origin/main' "$git_log"
) && pass "6. wrapper exits non-zero when all three fetch attempts fail" \
  || fail "6. wrapper exits non-zero when all three fetch attempts fail" "fetch exhaustion fail-hard was wrong"

(
    test_dir="$TMP_DIR/w7"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"
    printf '999\n' > "$state_dir/detach_failures_remaining"
    printf '1\n' > "$state_dir/reset_should_fail"

    setup_wrapper_fixture "$repo_dir"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"

    set +e
    PATH="$stub_dir:$PATH" \
    GIT_STUB_STATE_DIR="$state_dir" \
    GIT_STUB_LOG_FILE="$git_log" \
    SLEEP_LOG_FILE="$sleep_log" \
    RUNNER_CAPTURE_FILE="$capture_file" \
    bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh" 2>&1
    rc=$?
    set -e

    logs_dir="$repo_dir/scripts/nightshift/logs"
    repair_log="$logs_dir/bootstrap-repair.log"

    [[ "$rc" -ne 0 ]] &&
    [[ ! -e "$capture_file" ]] &&
    ls "$logs_dir"/bootstrap-failure-*.json >/dev/null 2>&1 &&
    artifact="$(ls "$logs_dir"/bootstrap-failure-*.json | head -n 1)" &&
    grep -Fq 'Reset/clean repair failed' "$artifact" &&
    grep -Fq 'force-clean-failed' "$artifact" &&
    grep -Fxq 'reset --hard HEAD' "$git_log" &&
    [[ -f "$repair_log" ]] &&
    grep -Fq 'force-clean-failed' "$repair_log"
) && pass "7. wrapper exits non-zero when repair fails before the detach retry" \
  || fail "7. wrapper exits non-zero when repair fails before the detach retry" "repair-failure fail-hard was wrong"

(
    test_dir="$TMP_DIR/w8"
    repo_dir="$test_dir/repo"
    stub_dir="$test_dir/bin"
    state_dir="$test_dir/state"
    git_log="$test_dir/git.log"
    sleep_log="$test_dir/sleep.log"
    capture_file="$test_dir/runner.out"
    mkdir -p "$state_dir"
    : > "$git_log"
    : > "$sleep_log"
    printf '999\n' > "$state_dir/detach_failures_remaining"

    setup_wrapper_fixture "$repo_dir"
    setup_git_stub "$stub_dir"
    setup_sleep_stub "$stub_dir"

    set +e
    NIGHTSHIFT_BASE_BRANCH='branch"with"quotes' \
    PATH="$stub_dir:$PATH" \
    GIT_STUB_STATE_DIR="$state_dir" \
    GIT_STUB_LOG_FILE="$git_log" \
    SLEEP_LOG_FILE="$sleep_log" \
    RUNNER_CAPTURE_FILE="$capture_file" \
    bash "$repo_dir/scripts/nightshift/nightshift-bootstrap.sh" 2>&1
    rc=$?
    set -e

    logs_dir="$repo_dir/scripts/nightshift/logs"

    [[ "$rc" -ne 0 ]] &&
    [[ ! -e "$capture_file" ]] &&
    artifact="$(ls "$logs_dir"/bootstrap-failure-*.json | head -n 1)" &&
    jq . "$artifact" >/dev/null 2>&1 &&
    grep -Fq '"base_branch": "branch\"with\"quotes"' "$artifact" &&
    grep -Fq 'Could not detach' "$artifact" &&
    grep -Fq 'force-clean-fallback' "$artifact"
) && pass "8. wrapper writes valid JSON artifacts when the base branch contains quotes" \
  || fail "8. wrapper writes valid JSON artifacts when the base branch contains quotes" "failure artifact JSON escaping was wrong"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

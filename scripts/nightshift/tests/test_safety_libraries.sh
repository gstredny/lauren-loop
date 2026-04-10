#!/usr/bin/env bash
# test_safety_libraries.sh — Tests for Nightshift db-safety.sh and git-safety.sh.
#
# Usage: bash scripts/nightshift/tests/test_safety_libraries.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
STUB_DIR="$TMP_DIR/stubs"
PSQL_STUB_LOG="$TMP_DIR/psql.log"
GIT_STUB_LOG="$TMP_DIR/git.log"
ORIG_PATH="$PATH"
export PSQL_STUB_LOG GIT_STUB_LOG

trap 'rm -rf "$TMP_DIR"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

mkdir -p "$STUB_DIR"

source "$NS_DIR/nightshift.conf"
source "$NS_DIR/lib/db-safety.sh"
source "$NS_DIR/lib/git-safety.sh"

write_stubs() {
    cat > "$STUB_DIR/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

sql=""
args=()
while (($#)); do
    case "$1" in
        -c)
            sql="${2:-}"
            shift 2
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done

{
    printf 'PASSWORD=%s\n' "${PGPASSWORD:-}"
    printf 'SQL=%s\n' "$sql"
    printf 'ARGS='
    printf '%s ' "${args[@]}"
    printf '\n'
} >> "${PSQL_STUB_LOG}"

case "$sql" in
    "CREATE TABLE _nightshift_safety_test (id int);")
        if [[ "${PSQL_CREATE_STDERR:-}" != "" ]]; then
            printf '%s\n' "${PSQL_CREATE_STDERR}" >&2
        fi
        exit "${PSQL_CREATE_EXIT:-1}"
        ;;
    "DROP TABLE IF EXISTS _nightshift_safety_test;")
        if [[ "${PSQL_DROP_STDERR:-}" != "" ]]; then
            printf '%s\n' "${PSQL_DROP_STDERR}" >&2
        fi
        exit "${PSQL_DROP_EXIT:-0}"
        ;;
    "SELECT 1;")
        if [[ "${PSQL_SELECT_STDERR:-}" != "" ]]; then
            printf '%s\n' "${PSQL_SELECT_STDERR}" >&2
        fi
        printf '1\n'
        exit "${PSQL_SELECT_EXIT:-0}"
        ;;
    *)
        exit "${PSQL_DEFAULT_EXIT:-0}"
        ;;
esac
EOF

    cat > "$STUB_DIR/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

subcommand="${1:-}"
if [[ $# -gt 0 ]]; then
    shift
fi

{
    printf 'SUBCOMMAND=%s\n' "$subcommand"
    printf 'ARGS='
    printf '%s ' "$@"
    printf '\n'
} >> "${GIT_STUB_LOG}"

case "$subcommand" in
    diff)
        if [[ "${1:-}" != "--numstat" ]]; then
            printf 'unexpected diff args\n' >&2
            exit 98
        fi
        shift
        case "${GIT_STUB_MODE:-clean}" in
            clean)
                exit 0
                ;;
            too_many_files)
                for i in $(seq 1 21); do
                    printf '1\t0\tfile%s.txt\n' "$i"
                done
                exit 0
                ;;
            too_many_lines)
                printf '5001\t0\tbig.txt\n'
                exit 0
                ;;
            binary)
                printf -- '-\t-\tbinary.dat\n'
                exit 0
                ;;
            malformed)
                printf 'bogus-row-without-tabs\n'
                exit 0
                ;;
            fail)
                printf 'diff failed\n' >&2
                exit 7
                ;;
            *)
                printf 'unsupported GIT_STUB_MODE=%s\n' "${GIT_STUB_MODE}" >&2
                exit 99
                ;;
        esac
        ;;
    rev-parse)
        if [[ "${1:-}" == "--is-inside-work-tree" ]]; then
            [[ "${GIT_STUB_IN_REPO:-1}" == "1" ]] || exit 1
            printf 'true\n'
            exit 0
        fi
        printf 'unsupported rev-parse args\n' >&2
        exit 97
        ;;
    ls-remote)
        if [[ "${GIT_STUB_REMOTE_OK:-1}" == "1" ]]; then
            printf 'deadbeef\tHEAD\n'
            exit 0
        fi
        printf 'origin unavailable\n' >&2
        exit 2
        ;;
    *)
        printf 'unsupported git subcommand: %s\n' "$subcommand" >&2
        exit 96
        ;;
esac
EOF

    chmod +x "$STUB_DIR/psql" "$STUB_DIR/git"
}

reset_stub_state() {
    : > "$PSQL_STUB_LOG"
    : > "$GIT_STUB_LOG"
    unset PSQL_CREATE_EXIT PSQL_DROP_EXIT PSQL_SELECT_EXIT PSQL_DEFAULT_EXIT
    unset PSQL_CREATE_STDERR PSQL_DROP_STDERR PSQL_SELECT_STDERR
    unset GIT_STUB_MODE GIT_STUB_IN_REPO GIT_STUB_REMOTE_OK
}

with_stub_path() {
    PATH="$STUB_DIR:$ORIG_PATH" "$@"
}

with_real_path() {
    PATH="$ORIG_PATH" "$@"
}

write_stubs
reset_stub_state

echo "=== test_safety_libraries.sh ==="
echo ""

# Shared DB env
SPECIAL_PASSWORD="$(printf 'P@ss/%s#1' 'w0rd')"
export NIGHTSHIFT_DB_HOST="host.example"
export NIGHTSHIFT_DB_NAME="new_georgedata"
export NIGHTSHIFT_DB_PASSWORD="$SPECIAL_PASSWORD"
export NIGHTSHIFT_DB_CONNECT_TIMEOUT="10"

# ── DB validation + command construction ─────────────────────────────────────
(
    export NIGHTSHIFT_DB_USER="gstredny"
    db_validate_connection >/dev/null 2>&1
) && fail "1. db_validate_connection rejects admin user" "returned 0 for admin user" \
  || pass "1. db_validate_connection rejects admin user"

(
    export NIGHTSHIFT_DB_USER=""
    db_validate_connection >/dev/null 2>&1
) && fail "2. db_validate_connection rejects empty user" "returned 0 for empty user" \
  || pass "2. db_validate_connection rejects empty user"

(
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    db_validate_connection >/dev/null 2>&1
) && pass "3. db_validate_connection accepts readonly user" \
  || fail "3. db_validate_connection accepts readonly user" "returned non-zero for readonly user"

(
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    cmd=$(db_build_psql_cmd 2>/dev/null)
    [[ "$cmd" == *"PGPASSWORD="* ]] &&
    [[ "$cmd" == *"psql "* ]] &&
    [[ "$cmd" == *"host="* ]] &&
    [[ "$cmd" == *"dbname="* ]] &&
    [[ "$cmd" == *"user="* ]] &&
    [[ "$cmd" == *"sslmode="* ]] &&
    [[ "$cmd" == *"connect_timeout=10"* ]] &&
    [[ "$cmd" != *"--connect-timeout"* ]] &&
    [[ "$cmd" != *"postgresql://"* ]]
) && pass "4. db_build_psql_cmd uses conninfo-based psql command with portable timeout" \
  || fail "4. db_build_psql_cmd uses conninfo-based psql command with portable timeout" "unexpected command output"

(
    reset_stub_state
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    cmd=$(db_build_psql_cmd 2>/dev/null)
    PATH="$STUB_DIR:$ORIG_PATH" eval "$cmd" -c "SELECT 1;" >/dev/null 2>&1
    grep -q "^PASSWORD=${SPECIAL_PASSWORD}$" "$PSQL_STUB_LOG" &&
    grep -Fq "ARGS=host=${NIGHTSHIFT_DB_HOST} port=5432 dbname=${NIGHTSHIFT_DB_NAME} user=${NIGHTSHIFT_DB_USER} sslmode=${NIGHTSHIFT_DB_SSLMODE} connect_timeout=${NIGHTSHIFT_DB_CONNECT_TIMEOUT} " "$PSQL_STUB_LOG"
) && pass "5. db_build_psql_cmd preserves special-character passwords and emits conninfo args" \
  || fail "5. db_build_psql_cmd preserves special-character passwords and emits conninfo args" "stub did not receive the expected password/conninfo"

# ── DB safety flows ──────────────────────────────────────────────────────────
(
    reset_stub_state
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    export PSQL_CREATE_EXIT=1
    PATH="$STUB_DIR:$ORIG_PATH" db_verify_readonly >/dev/null 2>&1
) && pass "6. db_verify_readonly succeeds when CREATE fails" \
  || fail "6. db_verify_readonly succeeds when CREATE fails" "returned non-zero on expected readonly failure"

(
    reset_stub_state
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    export PSQL_CREATE_EXIT=0
    export PSQL_DROP_EXIT=0
    stderr=$(PATH="$STUB_DIR:$ORIG_PATH" db_verify_readonly 2>&1 >/dev/null || true)
    [[ "$stderr" == *"CREATE TABLE succeeded"* ]] &&
    [[ "$stderr" == *"Cleanup: _nightshift_safety_test table dropped"* ]] &&
    [[ $(grep -c '^SQL=DROP TABLE IF EXISTS _nightshift_safety_test (id int);$' "$PSQL_STUB_LOG" 2>/dev/null || true) -eq 0 ]] &&
    [[ $(grep -c '^SQL=DROP TABLE IF EXISTS _nightshift_safety_test;$' "$PSQL_STUB_LOG") -eq 1 ]]
) && pass "7. db_verify_readonly fails closed and cleans up when CREATE succeeds" \
  || fail "7. db_verify_readonly fails closed and cleans up when CREATE succeeds" "cleanup path did not execute as expected"

(
    reset_stub_state
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    export PSQL_CREATE_EXIT=0
    export PSQL_DROP_EXIT=1
    export PSQL_DROP_STDERR="drop failed"
    stderr=$(PATH="$STUB_DIR:$ORIG_PATH" db_verify_readonly 2>&1 >/dev/null || true)
    [[ "$stderr" == *"Phantom table '_nightshift_safety_test' may still exist"* ]]
) && pass "8. db_verify_readonly logs second CRITICAL warning when cleanup fails" \
  || fail "8. db_verify_readonly logs second CRITICAL warning when cleanup fails" "missing phantom-table warning"

(
    reset_stub_state
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    export PSQL_SELECT_EXIT=0
    PATH="$STUB_DIR:$ORIG_PATH" db_test_connectivity >/dev/null 2>&1
) && pass "9. db_test_connectivity returns 0 on successful SELECT 1" \
  || fail "9. db_test_connectivity returns 0 on successful SELECT 1" "returned non-zero on successful SELECT 1"

(
    reset_stub_state
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    export PSQL_SELECT_EXIT=1
    PATH="$STUB_DIR:$ORIG_PATH" db_test_connectivity >/dev/null 2>&1
) && fail "10. db_test_connectivity returns 1 on failed SELECT 1" "returned 0 on connectivity failure" \
  || pass "10. db_test_connectivity returns 1 on failed SELECT 1"

(
    reset_stub_state
    export NIGHTSHIFT_DB_USER=""
    PATH="$STUB_DIR:$ORIG_PATH" db_safety_preflight >/dev/null 2>&1
) && fail "11. db_safety_preflight short-circuits after validation failure" "returned 0 with invalid env" \
  || {
        if [[ ! -s "$PSQL_STUB_LOG" ]]; then
            pass "11. db_safety_preflight short-circuits after validation failure"
        else
            fail "11. db_safety_preflight short-circuits after validation failure" "psql was invoked despite invalid env"
        fi
    }

(
    reset_stub_state
    export NIGHTSHIFT_DB_USER="nightshift_readonly"
    export PSQL_CREATE_EXIT=0
    export PSQL_DROP_EXIT=0
    PATH="$STUB_DIR:$ORIG_PATH" db_safety_preflight >/dev/null 2>&1
) && fail "12. db_safety_preflight aborts after readonly failure" "returned 0 after unsafe CREATE success" \
  || {
        if grep -q '^SQL=SELECT 1;$' "$PSQL_STUB_LOG"; then
            fail "12. db_safety_preflight aborts after readonly failure" "SELECT 1 ran after readonly failure"
        else
            pass "12. db_safety_preflight aborts after readonly failure"
        fi
    }

# ── Git validation helpers ───────────────────────────────────────────────────
(
    git_validate_branch "main" >/dev/null 2>&1
) && fail "13. git_validate_branch rejects protected branches" "returned 0 for main" \
  || pass "13. git_validate_branch rejects protected branches"

(
    git_validate_branch "nightshift/2026-03-28" >/dev/null 2>&1
) && pass "14. git_validate_branch accepts nightshift branches" \
  || fail "14. git_validate_branch accepts nightshift branches" "returned non-zero for nightshift branch"

(
    git_validate_commit_message "fixed stuff" >/dev/null 2>&1
) && fail "15. git_validate_commit_message rejects bad prefixes" "returned 0 for invalid prefix" \
  || pass "15. git_validate_commit_message rejects bad prefixes"

(
    git_validate_commit_message "nightshift: 2026-03-28 run" >/dev/null 2>&1
) && pass "16. git_validate_commit_message accepts valid prefixes" \
  || fail "16. git_validate_commit_message accepts valid prefixes" "returned non-zero for valid prefix"

# ── Git safety flows using real temp repos ───────────────────────────────────
(
    repo="$TMP_DIR/pr-clean"
    mkdir -p "$repo"
    with_real_path git -C "$repo" init -q --initial-branch=main
    with_real_path git -C "$repo" config user.email test@example.com
    with_real_path git -C "$repo" config user.name tester
    printf 'base\n' > "$repo/base.txt"
    with_real_path git -C "$repo" add base.txt
    with_real_path git -C "$repo" commit -q -m "base"
    with_real_path git -C "$repo" checkout -q -b feature/test
    cd "$repo"
    git_validate_pr_size "main" >/dev/null 2>&1
) && pass "17. git_validate_pr_size returns 0 on a clean diff" \
  || fail "17. git_validate_pr_size returns 0 on a clean diff" "returned non-zero for clean diff"

(
    reset_stub_state
    export GIT_STUB_MODE="too_many_files"
    PATH="$STUB_DIR:$ORIG_PATH" git_validate_pr_size "main" >/dev/null 2>&1
) && fail "18. git_validate_pr_size rejects too many files" "returned 0 for oversized file count" \
  || pass "18. git_validate_pr_size rejects too many files"

(
    reset_stub_state
    export GIT_STUB_MODE="too_many_lines"
    PATH="$STUB_DIR:$ORIG_PATH" git_validate_pr_size "main" >/dev/null 2>&1
) && fail "19. git_validate_pr_size rejects too many added lines" "returned 0 for oversized line count" \
  || pass "19. git_validate_pr_size rejects too many added lines"

(
    reset_stub_state
    export GIT_STUB_MODE="binary"
    stderr=$(PATH="$STUB_DIR:$ORIG_PATH" git_validate_pr_size "main" 2>&1 >/dev/null || true)
    [[ "$stderr" == *"Binary diff entry encountered"* ]]
) && pass "20. git_validate_pr_size fails closed on binary or ambiguous rows" \
  || fail "20. git_validate_pr_size fails closed on binary or ambiguous rows" "missing binary-entry failure"

(
    repo="$TMP_DIR/branch-create"
    mkdir -p "$repo"
    with_real_path git -C "$repo" init -q --initial-branch=main
    with_real_path git -C "$repo" config user.email test@example.com
    with_real_path git -C "$repo" config user.name tester
    printf 'base\n' > "$repo/base.txt"
    with_real_path git -C "$repo" add base.txt
    with_real_path git -C "$repo" commit -q -m "base"
    cd "$repo"
    b1=$(git_create_branch "2026-03-28")
    with_real_path git checkout -q main
    b2=$(git_create_branch "2026-03-28")
    [[ "$b1" == "nightshift/2026-03-28" ]] && [[ "$b2" == "nightshift/2026-03-28" ]]
) && pass "21. git_create_branch deletes prior local branch and recreates on same date" \
  || fail "21. git_create_branch deletes prior local branch and recreates on same date" "branch cleanup did not produce expected branch name"

(
    reset_stub_state
    export GIT_STUB_IN_REPO=0
    PATH="$STUB_DIR:$ORIG_PATH" git_safety_preflight >/dev/null 2>&1
) && fail "22. git_safety_preflight fails outside a git repo" "returned 0 outside a repo" \
  || pass "22. git_safety_preflight fails outside a git repo"

(
    reset_stub_state
    export GIT_STUB_IN_REPO=1
    export GIT_STUB_REMOTE_OK=0
    PATH="$STUB_DIR:$ORIG_PATH" git_safety_preflight >/dev/null 2>&1
) && fail "23. git_safety_preflight fails when origin is unreachable" "returned 0 with unreachable origin" \
  || pass "23. git_safety_preflight fails when origin is unreachable"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (23 tests) ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

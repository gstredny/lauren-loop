#!/usr/bin/env bash
# test_guardrails_cron_notify.sh — Grouped coverage for guardrails, cron, and notify.
#
# Usage:
#   bash scripts/nightshift/tests/test_guardrails_cron_notify.sh
#   TEST_GROUP=cron bash scripts/nightshift/tests/test_guardrails_cron_notify.sh
#   TEST_GROUP=notify bash scripts/nightshift/tests/test_guardrails_cron_notify.sh
#   TEST_GROUP=runtime bash scripts/nightshift/tests/test_guardrails_cron_notify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "${NS_DIR}/../.." && pwd)"

PASS=0
FAIL=0
TEST_GROUP="${TEST_GROUP:-}"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TMP_DIR"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

should_run_group() {
    [[ -z "$TEST_GROUP" || "$TEST_GROUP" == "$1" ]]
}

setup_crontab_stub() {
    local bin_dir="$1"
    local state_file="$2"
    local capture_file="$3"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/crontab" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_FILE="$state_file"
CAPTURE_FILE="$capture_file"

case "\${1:-}" in
    -l)
        if [[ -f "\$STATE_FILE" && -s "\$STATE_FILE" ]]; then
            cat "\$STATE_FILE"
            exit 0
        fi
        exit 1
        ;;
    -)
        cat > "\$CAPTURE_FILE"
        cp "\$CAPTURE_FILE" "\$STATE_FILE"
        exit 0
        ;;
    *)
        printf 'unsupported crontab invocation\n' >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$bin_dir/crontab"
}

setup_notify_stub_dir() {
    local bin_dir="$1"
    local curl_rc="${2:-0}"
    local sendmail_rc="${3:-0}"

    mkdir -p "$bin_dir"

    cat > "$bin_dir/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"text":"stubbed","run_date":"2026-03-30"}\n'
EOF
    chmod +x "$bin_dir/jq"

    cat > "$bin_dir/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exit ${curl_rc}
EOF
    chmod +x "$bin_dir/curl"

    cat > "$bin_dir/sendmail" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
exit ${sendmail_rc}
EOF
    chmod +x "$bin_dir/sendmail"
}

setup_df_stub() {
    local bin_dir="$1"
    local available_kb="$2"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/df" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk1 20971520 1024 %s 1%% /tmp\n' "${available_kb}"
EOF
    chmod +x "$bin_dir/df"
}

setup_cli_presence_stubs() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    for binary in claude gh; do
        cat > "$bin_dir/$binary" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
        chmod +x "$bin_dir/$binary"
    done
}

init_test_git_repo() {
    local repo_dir="$1"

    mkdir -p "$repo_dir"
    (
        cd "$repo_dir"
        git init -q
        git config user.email "nightshift-test@example.com"
        git config user.name "Nightshift Test"
        git commit --allow-empty -qm "init"
    )
}

echo "=== test_guardrails_cron_notify.sh ==="
if [[ -n "$TEST_GROUP" ]]; then
    echo "=== Group: $TEST_GROUP ==="
fi
echo ""

if should_run_group "cron"; then
    (
        test_dir="$TMP_DIR/c1"
        bin_dir="$test_dir/bin"
        state_file="$test_dir/crontab.state"
        capture_file="$test_dir/crontab.capture"
        cron_contents=""
        mkdir -p "$test_dir"
        setup_crontab_stub "$bin_dir" "$state_file" "$capture_file"

        PATH="$bin_dir:$PATH" bash "$NS_DIR/install-cron.sh" >/dev/null 2>&1
        cron_contents="$(cat "$capture_file")"

        grep -Fq "# BEGIN nightshift-detective" "$capture_file" &&
        grep -Fq "# END nightshift-detective" "$capture_file" &&
        grep -Fq "0 23 * * *" "$capture_file" &&
        [[ "$cron_contents" == *"{ cd ${REPO_ROOT}"* ]] &&
        [[ "$cron_contents" == *"bash scripts/nightshift/nightshift-bootstrap.sh; } >> ${REPO_ROOT}/scripts/nightshift/logs/cron.log 2>&1"* ]]
    ) && pass "C1. install-cron creates the marked block" \
      || fail "C1. install-cron creates the marked block" "expected cron block content was missing"

    (
        test_dir="$TMP_DIR/c2"
        bin_dir="$test_dir/bin"
        state_file="$test_dir/crontab.state"
        capture_file="$test_dir/crontab.capture"
        mkdir -p "$test_dir"
        setup_crontab_stub "$bin_dir" "$state_file" "$capture_file"

        cat > "$state_file" <<'EOF'
# BEGIN nightshift-detective
0 23 * * * bash -l -c '{ cd /tmp/old-repo && git checkout main && git pull --ff-only origin main && bash scripts/nightshift/nightshift.sh; } >> /tmp/old-repo/scripts/nightshift/logs/cron.log 2>&1'
# END nightshift-detective
EOF

        PATH="$bin_dir:$PATH" bash "$NS_DIR/install-cron.sh" >/dev/null 2>&1

        [[ "$(grep -c '^# BEGIN nightshift-detective$' "$capture_file")" == "1" ]] &&
        [[ "$(grep -c '^# END nightshift-detective$' "$capture_file")" == "1" ]] &&
        grep -Fq "0 23 * * *" "$capture_file" &&
        grep -Fq "{ cd ${REPO_ROOT}" "$capture_file" &&
        grep -Fq "bash scripts/nightshift/nightshift-bootstrap.sh" "$capture_file" &&
        ! grep -Fq "/tmp/old-repo" "$capture_file"
    ) && pass "C2. install-cron is idempotent" \
      || fail "C2. install-cron is idempotent" "nightshift cron block was duplicated or not refreshed"

    (
        test_dir="$TMP_DIR/c3"
        bin_dir="$test_dir/bin"
        state_file="$test_dir/crontab.state"
        capture_file="$test_dir/crontab.capture"
        mkdir -p "$test_dir"
        setup_crontab_stub "$bin_dir" "$state_file" "$capture_file"

        printf '0 5 * * * /usr/bin/backup.sh\n' > "$state_file"

        PATH="$bin_dir:$PATH" bash "$NS_DIR/install-cron.sh" >/dev/null 2>&1

        grep -Fxq "0 5 * * * /usr/bin/backup.sh" "$capture_file" &&
        grep -Fq "# BEGIN nightshift-detective" "$capture_file"
    ) && pass "C3. install-cron preserves unrelated entries" \
      || fail "C3. install-cron preserves unrelated entries" "existing crontab content was lost"

    (
        test_dir="$TMP_DIR/c4"
        bin_dir="$test_dir/bin"
        state_file="$test_dir/crontab.state"
        capture_file="$test_dir/crontab.capture"
        mkdir -p "$test_dir"
        setup_crontab_stub "$bin_dir" "$state_file" "$capture_file"

        cat > "$state_file" <<'EOF'
0 5 * * * /usr/bin/backup.sh
# BEGIN nightshift-detective
0 23 * * * bash -l -c '{ cd /tmp/nightshift-repo && git checkout main && git pull --ff-only origin main && bash scripts/nightshift/nightshift.sh; } >> /tmp/nightshift-repo/scripts/nightshift/logs/cron.log 2>&1'
# END nightshift-detective
15 6 * * 1 /usr/bin/report.sh
EOF

        PATH="$bin_dir:$PATH" bash "$NS_DIR/uninstall-cron.sh" >/dev/null 2>&1

        ! grep -Fq "# BEGIN nightshift-detective" "$capture_file" &&
        ! grep -Fq "# END nightshift-detective" "$capture_file" &&
        grep -Fxq "0 5 * * * /usr/bin/backup.sh" "$capture_file" &&
        grep -Fxq "15 6 * * 1 /usr/bin/report.sh" "$capture_file"
    ) && pass "C4. uninstall-cron removes only the marked block" \
      || fail "C4. uninstall-cron removes only the marked block" "uninstall removed unrelated entries or left the block behind"

    (
        test_dir="$TMP_DIR/c5"
        bin_dir="$test_dir/bin"
        state_file="$test_dir/crontab.state"
        capture_file="$test_dir/crontab.capture"
        log_file="$test_dir/uninstall.log"
        mkdir -p "$test_dir"
        setup_crontab_stub "$bin_dir" "$state_file" "$capture_file"

        printf '0 5 * * * /usr/bin/backup.sh\n' > "$state_file"
        before_contents="$(cat "$state_file")"

        PATH="$bin_dir:$PATH" bash "$NS_DIR/uninstall-cron.sh" >"$log_file" 2>&1

        [[ "$(cat "$state_file")" == "$before_contents" ]] &&
        [[ ! -e "$capture_file" ]] &&
        grep -Fq "No nightshift cron entry found" "$log_file"
    ) && pass "C5. uninstall-cron is a no-op when no block exists" \
      || fail "C5. uninstall-cron is a no-op when no block exists" "no-op uninstall changed the crontab or logged the wrong message"

    (
        test_dir="$TMP_DIR/c6"
        bin_dir="$test_dir/bin"
        state_file="$test_dir/crontab.state"
        capture_file="$test_dir/crontab.capture"
        cron_line=""
        vm_repo_root="/home/user/project"
        expected_doc_line=""
        mkdir -p "$test_dir"
        setup_crontab_stub "$bin_dir" "$state_file" "$capture_file"

        PATH="$bin_dir:$PATH" bash "$NS_DIR/install-cron.sh" >/dev/null 2>&1
        cron_line="$(awk '/^# BEGIN nightshift-detective$/ { getline; print; exit }' "$capture_file")"
        expected_doc_line="${cron_line//${REPO_ROOT}/${vm_repo_root}}"

        grep -Fqx "$expected_doc_line" "$REPO_ROOT/docs/nightshift/OPERATIONS-RUNBOOK.md" &&
        grep -Fqx "$expected_doc_line" "$REPO_ROOT/docs/NIGHTSHIFT.md"
    ) && pass "C6. docs match the install-cron entry exactly" \
      || fail "C6. docs match the install-cron entry exactly" "runbook or NIGHTSHIFT.md drifted from install-cron.sh"
fi

if should_run_group "notify"; then
    (
        test_dir="$TMP_DIR/n1"
        digest_file="$test_dir/digest.md"
        mkdir -p "$test_dir"

        cat > "$digest_file" <<'EOF'
# Nightshift Detective Digest — 2026-03-30

## Run Metadata
- **Run ID:** n1
- **Mode:** dry-run
- **Outcome:** clean

## Summary
- **Total findings received:** 0
- **Task files created:** 0
- **Total cost:** $0.0000
EOF

        source "$NS_DIR/lib/notify.sh"
        summary="$(notify_build_summary "$digest_file" "" "0.0000" 120 0 "" "" "")"

        grep -Fq "Findings: 0 findings" <<<"$summary" &&
        grep -Fq "Cost: \$0.0000" <<<"$summary" &&
        grep -Fq "Duration: 2m 0s" <<<"$summary" &&
        grep -Fq "PR: none" <<<"$summary"
    ) && pass "N1. notify_build_summary renders a clean 0-finding digest" \
      || fail "N1. notify_build_summary renders a clean 0-finding digest" "summary output did not match the clean case"

    (
        test_dir="$TMP_DIR/n2"
        digest_file="$test_dir/digest.md"
        mkdir -p "$test_dir"

        cat > "$digest_file" <<'EOF'
# Nightshift Detective Digest — 2026-03-30

### Finding: Critical auth bypass
**Severity:** critical

### Finding: Major cache corruption
**Severity:** major

### Finding: High latency regression
**Severity:** high

### Finding: Minor report mismatch
**Severity:** minor

### Finding: Observation about docs
**Severity:** observation
EOF

        source "$NS_DIR/lib/notify.sh"
        summary="$(notify_build_summary "$digest_file" "https://example.com/pr/123" "12.3456" 185 5 "" "" "")"

        grep -Fq "Findings: 5 findings" <<<"$summary" &&
        grep -Fq "Severity: critical=1 high=2 medium=1 low=1" <<<"$summary" &&
        grep -Fq "Duration: 3m 5s" <<<"$summary" &&
        grep -Fq -- "- Critical auth bypass" <<<"$summary" &&
        grep -Fq -- "- Major cache corruption" <<<"$summary" &&
        grep -Fq -- "- High latency regression" <<<"$summary" &&
        ! grep -Fq -- "- Minor report mismatch" <<<"$summary"
    ) && pass "N2. notify_build_summary renders severity counts and top-3 preview" \
      || fail "N2. notify_build_summary renders severity counts and top-3 preview" "severity counts or preview were wrong"

    (
        test_dir="$TMP_DIR/n3"
        digest_file="$test_dir/digest.md"
        mkdir -p "$test_dir"

        {
            printf '# Nightshift Detective Digest — 2026-03-30\n\n'
            for i in $(seq 1 15); do
                printf '### Finding: Issue %02d\n' "$i"
                printf '**Severity:** observation\n\n'
            done
        } > "$digest_file"

        source "$NS_DIR/lib/notify.sh"
        summary="$(notify_build_summary "$digest_file" "" "3.2100" 45 15 "" "" "")"
        preview_count="$(printf '%s\n' "$summary" | awk 'BEGIN { in_top=0; count=0 } /^Top findings:$/ { in_top=1; next } in_top && /^- / { count++ } END { print count + 0 }')"

        grep -Fq "Findings: 15 findings" <<<"$summary" &&
        [[ "$preview_count" == "3" ]] &&
        ! grep -Fq -- "- Issue 04" <<<"$summary"
    ) && pass "N3. notify_build_summary caps preview at 3 items" \
      || fail "N3. notify_build_summary caps preview at 3 items" "preview was not capped at three findings"

    (
        test_dir="$TMP_DIR/n4"
        digest_file="$test_dir/digest.md"
        log_file="$test_dir/nightshift.log"
        mkdir -p "$test_dir"

        cat > "$digest_file" <<'EOF'
# Nightshift Detective Digest — 2026-03-30
EOF

        for i in $(seq 1 60); do
            printf 'line-%02d\n' "$i" >> "$log_file"
        done

        source "$NS_DIR/lib/notify.sh"
        summary="$(notify_build_summary "$digest_file" "" "0.0000" 60 0 "phase_setup: disk space below 1GB" "" "$log_file")"

        grep -Fq "Failures:" <<<"$summary" &&
        grep -Fq "phase_setup: disk space below 1GB" <<<"$summary" &&
        grep -Fq "Recent log tail:" <<<"$summary" &&
        grep -Fq "line-11" <<<"$summary" &&
        ! grep -Fq "line-10" <<<"$summary"
    ) && pass "N4. notify_build_summary includes failure notes and the last 50 log lines" \
      || fail "N4. notify_build_summary includes failure notes and the last 50 log lines" "failure summary or log tail was wrong"

    (
        unset NIGHTSHIFT_WEBHOOK_URL
        source "$NS_DIR/lib/notify.sh"
        set +e
        output="$(notify_send_webhook "hello world" 2>&1)"
        rc=$?
        set -e

        [[ "$rc" -eq 0 ]] &&
        grep -Fq "No webhook URL configured" <<<"$output"
    ) && pass "N5. notify_send_webhook returns 0 when webhook is unset" \
      || fail "N5. notify_send_webhook returns 0 when webhook is unset" "unset webhook case returned non-zero or logged the wrong message"

    (
        test_dir="$TMP_DIR/n6"
        stub_dir="$test_dir/bin"
        mkdir -p "$test_dir"
        setup_notify_stub_dir "$stub_dir" 1 0

        export NIGHTSHIFT_WEBHOOK_URL="https://example.com/webhook"
        source "$NS_DIR/lib/notify.sh"
        set +e
        output="$(PATH="$stub_dir:$PATH" notify_send_webhook "hello world" 2>&1)"
        rc=$?
        set -e

        [[ "$rc" -eq 0 ]] &&
        grep -Fq "Webhook delivery failed" <<<"$output"
    ) && pass "N6. notify_send_webhook remains non-blocking when curl fails" \
      || fail "N6. notify_send_webhook remains non-blocking when curl fails" "curl failure bubbled up or was not logged"

    (
        test_dir="$TMP_DIR/n7"
        stub_dir="$test_dir/bin"
        digest_file="$test_dir/digest.md"
        mkdir -p "$test_dir"
        setup_notify_stub_dir "$stub_dir" 1 1

        cat > "$digest_file" <<'EOF'
# Nightshift Detective Digest — 2026-03-30

### Finding: Example finding
**Severity:** major
EOF

        export NIGHTSHIFT_WEBHOOK_URL="https://example.com/webhook"
        export NIGHTSHIFT_NOTIFY_EMAIL="nightshift@example.com"
        source "$NS_DIR/lib/notify.sh"
        set +e
        output="$(PATH="$stub_dir:$PATH" notify_dispatch "$digest_file" "" "1.2300" 90 1 "" "" "" 2>&1)"
        rc=$?
        set -e

        [[ "$rc" -eq 0 ]] &&
        grep -Fq "Webhook delivery failed" <<<"$output" &&
        grep -Fq "Email delivery failed" <<<"$output"
    ) && pass "N7. notify_dispatch returns 0 even when both transports fail" \
      || fail "N7. notify_dispatch returns 0 even when both transports fail" "transport failures bubbled up or were not logged"
fi

if should_run_group "runtime"; then
    (
        test_dir="$TMP_DIR/r1"
        stub_dir="$test_dir/bin"
        repo_dir="$test_dir/repo"
        mkdir -p "$repo_dir"
        setup_df_stub "$stub_dir" 512000

        source "$NS_DIR/nightshift.sh"
        export NIGHTSHIFT_REPO_DIR="$repo_dir"
        export NIGHTSHIFT_MIN_FREE_MB="1024"
        export NIGHTSHIFT_RUN_ID="r1"
        DRY_RUN=1
        SETUP_FAILED=0
        cost_called=0

        current_ref_name() { echo "main"; }
        cost_init() { cost_called=1; return 0; }

        PATH="$stub_dir:$PATH" phase_setup >/dev/null 2>&1

        [[ "${SETUP_FAILED}" -eq 1 ]] &&
        [[ "${cost_called}" -eq 0 ]]
    ) && pass "R1. low disk aborts phase_setup before cost_init" \
      || fail "R1. low disk aborts phase_setup before cost_init" "disk check did not stop setup before cost_init"

    (
        test_dir="$TMP_DIR/r2"
        stub_dir="$test_dir/bin"
        repo_dir="$test_dir/repo"
        mkdir -p "$repo_dir"
        setup_df_stub "$stub_dir" 5120000

        source "$NS_DIR/nightshift.sh"
        export NIGHTSHIFT_REPO_DIR="$repo_dir"
        export NIGHTSHIFT_MIN_FREE_MB="1024"
        export NIGHTSHIFT_RUN_ID="r2"
        DRY_RUN=1
        SETUP_FAILED=0
        SETUP_READY=0

        current_ref_name() { echo "main"; }
        cost_init() { return 0; }

        PATH="$stub_dir:$PATH" phase_setup >/dev/null 2>&1

        [[ "${SETUP_FAILED}" -eq 0 ]] &&
        [[ "${SETUP_READY}" -eq 1 ]]
    ) && pass "R2. sufficient disk allows phase_setup to proceed" \
      || fail "R2. sufficient disk allows phase_setup to proceed" "setup still failed despite enough free disk"

    (
        test_dir="$TMP_DIR/r3"
        lock_file="$test_dir/nightshift.lock"
        log_file="$test_dir/lock.log"
        mkdir -p "$test_dir"
        printf '%s\n' "$$" > "$lock_file"

        set +e
        (
            source "$NS_DIR/nightshift.sh"
            LOCK_FILE="$lock_file"
            acquire_lock
        ) >"$log_file" 2>&1
        rc=$?
        set -e

        [[ "$rc" -ne 0 ]] &&
        grep -Fq "already active" "$log_file"
    ) && pass "R3. active lockfile blocks acquire_lock" \
      || fail "R3. active lockfile blocks acquire_lock" "active lockfile was not rejected"

    (
        test_dir="$TMP_DIR/r4"
        lock_file="$test_dir/nightshift.lock"
        log_file="$test_dir/lock.log"
        mkdir -p "$test_dir"
        printf '99999999\n' > "$lock_file"
        ! kill -0 99999999 2>/dev/null

        source "$NS_DIR/nightshift.sh"
        LOCK_FILE="$lock_file"

        {
            acquire_lock
        } >"$log_file" 2>&1

        [[ "$(cat "$lock_file")" == "$$" ]] &&
        grep -Fq "Removing stale lockfile" "$log_file"
        cleanup_lock >/dev/null 2>&1
    ) && pass "R4. stale lockfile is cleaned up and replaced" \
      || fail "R4. stale lockfile is cleaned up and replaced" "stale lockfile was not replaced cleanly"

    (
        test_dir="$TMP_DIR/r5"
        home_dir="$test_dir/home"
        log_file="$test_dir/config.log"
        mkdir -p "$home_dir"

        export HOME="$home_dir"
        export NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS="99999"
        source "$NS_DIR/nightshift.sh"
        load_nightshift_configuration "$NS_DIR/nightshift.conf" "$HOME/.nightshift-env" >"$log_file" 2>&1

        [[ "$NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS" == "7200" ]] &&
        grep -Fq "Ignored override of NIGHTSHIFT_TOTAL_TIMEOUT_SECONDS" "$log_file"
    ) && pass "R5. total timeout is conf-authoritative" \
      || fail "R5. total timeout is conf-authoritative" "environment override was not ignored for total timeout"

    (
        test_dir="$TMP_DIR/r6"
        home_dir="$test_dir/home"
        log_file="$test_dir/config.log"
        mkdir -p "$home_dir"

        export HOME="$home_dir"
        export NIGHTSHIFT_MIN_FREE_MB="1"
        source "$NS_DIR/nightshift.sh"
        load_nightshift_configuration "$NS_DIR/nightshift.conf" "$HOME/.nightshift-env" >"$log_file" 2>&1

        [[ "$NIGHTSHIFT_MIN_FREE_MB" == "1024" ]] &&
        grep -Fq "Ignored override of NIGHTSHIFT_MIN_FREE_MB" "$log_file"
    ) && pass "R6. disk threshold is conf-authoritative" \
      || fail "R6. disk threshold is conf-authoritative" "environment override was not ignored for min free MB"

    (
        test_dir="$TMP_DIR/r7"
        repo_dir="$test_dir/repo"
        mkdir -p "$test_dir"
        init_test_git_repo "$repo_dir"

        source "$NS_DIR/nightshift.sh"
        export NIGHTSHIFT_REPO_DIR="$repo_dir"
        export REPO_ROOT="$repo_dir"
        export NIGHTSHIFT_RUN_ID="r7"
        export NIGHTSHIFT_BOOTSTRAP_STATUS="stale-fallback"
        export NIGHTSHIFT_BOOTSTRAP_WARNING="Nightshift bootstrap could not fetch origin/main after 3 attempts; running the current checkout as-is"
        DRY_RUN=1
        SETUP_FAILED=0
        SETUP_READY=0
        WARNING_NOTES=""

        current_ref_name() { echo "main"; }
        check_disk_space() { return 0; }
        cost_init() { return 0; }
        validate_env_file_preflight() { return 0; }

        phase_setup >/dev/null 2>&1

        grep -Fq "Nightshift bootstrap could not fetch origin/main after 3 attempts" <<< "$WARNING_NOTES" &&
        ! grep -Fq "started without nightshift-bootstrap.sh freshness bootstrap" <<< "$WARNING_NOTES" &&
        [[ "${SETUP_READY}" -eq 1 ]]
    ) && pass "R7. phase_setup ingests wrapper bootstrap warnings without adding the direct-run warning in dry-run mode" \
      || fail "R7. phase_setup ingests wrapper bootstrap warnings without adding the direct-run warning in dry-run mode" "bootstrap warning ingestion was wrong"

    (
        test_dir="$TMP_DIR/r8"
        marker_file="$test_dir/calls.log"
        mkdir -p "$test_dir"

        source "$NS_DIR/nightshift.sh"
        export NIGHTSHIFT_RUN_ID="r8"
        unset NIGHTSHIFT_BOOTSTRAP_STATUS NIGHTSHIFT_BOOTSTRAP_WARNING 2>/dev/null
        DRY_RUN=0
        FORCE_DIRECT=0
        : > "$marker_file"

        acquire_lock() { printf 'acquire_lock\n' >> "$marker_file"; }
        load_nightshift_configuration() { printf 'load_config\n' >> "$marker_file"; return 0; }
        source_required() { printf 'source_required:%s\n' "$1" >> "$marker_file"; return 0; }
        on_exit() { return 0; }
        on_err() { return 0; }
        cleanup_lock() { :; }
        cleanup_logger() { :; }
        git() { return 0; }

        set +e
        output="$(main 2>&1)"
        status=$?
        set -e

        [[ "${status}" -eq 1 ]] &&
        grep -Fq "Direct live runs must use scripts/nightshift/nightshift-bootstrap.sh or pass --force-direct" <<< "$output" &&
        [[ ! -s "$marker_file" ]]
    ) && pass "R8. direct live main() fails closed before sourcing when bootstrap freshness is missing" \
      || fail "R8. direct live main() fails closed before sourcing when bootstrap freshness is missing" "direct live run was not blocked early"

    (
        test_dir="$TMP_DIR/r9"
        marker_file="$test_dir/calls.log"
        mkdir -p "$test_dir"

        source "$NS_DIR/nightshift.sh"
        export NIGHTSHIFT_RUN_ID="r9"
        unset NIGHTSHIFT_BOOTSTRAP_STATUS NIGHTSHIFT_BOOTSTRAP_WARNING 2>/dev/null
        DRY_RUN=0
        FORCE_DIRECT=0
        : > "$marker_file"

        acquire_lock() { printf 'acquire_lock\n' >> "$marker_file"; }
        load_nightshift_configuration() { return 0; }
        source_required() { return 0; }
        init_runtime_paths() { :; }
        phase_setup() { printf 'phase_setup\n' >> "$marker_file"; }
        phase_detectives() { :; }
        phase_manager_merge() { :; }
        phase_task_writing() { :; }
        phase_validation() { :; }
        phase_autofix() { :; }
        phase_bridge() { :; }
        phase_backlog_burndown() { :; }
        phase_ship_results() { :; }
        phase_cleanup() { :; }
        compute_exit_code() { echo "0"; }
        on_exit() { return 0; }
        on_err() { return 0; }
        cleanup_lock() { :; }
        cleanup_logger() { :; }
        git() { return 0; }

        set +e
        output="$(main --dry-run 2>&1)"
        status=$?
        set -e

        [[ "${status}" -eq 0 ]] &&
        grep -Fxq "acquire_lock" "$marker_file" &&
        grep -Fxq "phase_setup" "$marker_file" &&
        ! grep -Fq "Direct live runs must use scripts/nightshift/nightshift-bootstrap.sh or pass --force-direct" <<< "$output"
    ) && pass "R9. direct dry-run main() still runs without bootstrap freshness" \
      || fail "R9. direct dry-run main() still runs without bootstrap freshness" "dry-run was incorrectly blocked by the live bootstrap gate"

    (
        test_dir="$TMP_DIR/r10"
        repo_dir="$test_dir/repo"
        stub_dir="$test_dir/bin"
        mkdir -p "$test_dir"
        init_test_git_repo "$repo_dir"
        setup_cli_presence_stubs "$stub_dir"

        source "$NS_DIR/nightshift.sh"
        export NIGHTSHIFT_REPO_DIR="$repo_dir"
        export REPO_ROOT="$repo_dir"
        export NIGHTSHIFT_RUN_ID="r10"
        unset NIGHTSHIFT_BOOTSTRAP_STATUS NIGHTSHIFT_BOOTSTRAP_WARNING 2>/dev/null
        DRY_RUN=0
        FORCE_DIRECT=1
        SETUP_FAILED=0
        SETUP_READY=0
        WARNING_NOTES=""
        BRANCH_READY=0
        MANAGER_ALLOWED=0
        PUSH_ALLOWED=0

        current_ref_name() { echo "main"; }
        check_disk_space() { return 0; }
        cost_init() { return 0; }
        validate_env_file_preflight() { return 0; }
        check_total_timeout() { return 0; }
        working_tree_is_clean() { return 0; }
        git_safety_preflight() { return 1; }
        git_create_branch() { echo "nightshift/r9"; return 0; }
        git_validate_branch() { return 0; }
        db_safety_preflight() { return 0; }

        PATH="$stub_dir:$PATH" phase_setup >/dev/null 2>&1

        grep -Fq "Nightshift started without nightshift-bootstrap.sh freshness bootstrap because --force-direct was used" <<< "$WARNING_NOTES" &&
        [[ "${BRANCH_READY}" -eq 1 ]] &&
        [[ "${SETUP_FAILED}" -eq 0 ]]
    ) && pass "R10. force-direct live phase_setup warns that freshness bootstrap was bypassed" \
      || fail "R10. force-direct live phase_setup warns that freshness bootstrap was bypassed" "force-direct warning was missing or setup failed"

    (
        test_dir="$TMP_DIR/r11"
        repo_dir="$test_dir/repo"
        stub_dir="$test_dir/bin"
        mkdir -p "$test_dir"
        init_test_git_repo "$repo_dir"
        setup_cli_presence_stubs "$stub_dir"

        source "$NS_DIR/nightshift.sh"
        export NIGHTSHIFT_REPO_DIR="$repo_dir"
        export REPO_ROOT="$repo_dir"
        export NIGHTSHIFT_RUN_ID="r11"
        export NIGHTSHIFT_BOOTSTRAP_STATUS="fresh"
        unset NIGHTSHIFT_BOOTSTRAP_WARNING 2>/dev/null
        DRY_RUN=0
        FORCE_DIRECT=0
        SETUP_FAILED=0
        SETUP_READY=0
        WARNING_NOTES=""
        BRANCH_READY=0
        MANAGER_ALLOWED=0
        PUSH_ALLOWED=0

        current_ref_name() { echo "main"; }
        check_disk_space() { return 0; }
        cost_init() { return 0; }
        validate_env_file_preflight() { return 0; }
        check_total_timeout() { return 0; }
        working_tree_is_clean() { return 0; }
        git_safety_preflight() { return 1; }
        git_create_branch() { echo "nightshift/r11"; return 0; }
        git_validate_branch() { return 0; }
        db_safety_preflight() { return 0; }

        PATH="$stub_dir:$PATH" phase_setup >/dev/null 2>&1

        grep -Fq "continuing with local branch creation from current checkout and best-effort shipping" <<< "$WARNING_NOTES" &&
        [[ "${BRANCH_READY}" -eq 1 ]] &&
        [[ "${SETUP_FAILED}" -eq 0 ]]
    ) && pass "R11. phase_setup keeps going with a local branch when git_safety_preflight fails inside a git repo" \
      || fail "R11. phase_setup keeps going with a local branch when git_safety_preflight fails inside a git repo" "local-branch fallback did not stay usable"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

write_hash_task() {
    local path="$1" status="${2:-not started}" execution_mode="${3:-single-agent}" depends_on="${4:-}"
    mkdir -p "$(dirname "${path}")"
    cat > "${path}" <<EOF
## Task: $(basename "${path}")
## Status: ${status}
## Created: 2026-03-31
## Execution Mode: ${execution_mode}
${depends_on:+## Depends on: ${depends_on}}
## Goal
Resolve the fixture task.
## Code Review: not started
## Left Off At
Not started.
## Attempts
(none yet)
EOF
}

write_legacy_task() {
    local path="$1" status="${2:-not started}" mode_label="${3:-Single agent}" depends_on="${4:-}"
    mkdir -p "$(dirname "${path}")"
    cat > "${path}" <<EOF
# Legacy Task
**Created:** 2026-03-31
**Status:** ${status}
**Mode:** ${mode_label}
${depends_on:+**Depends on:** ${depends_on}}
## Goal
Resolve the legacy fixture task.
## Code Review: not started
## Left Off At
Not started.
## Attempts
(none yet)
EOF
}

setup_repo() {
    REPO_ROOT="${TMP_DIR}/$1"
    RUN_DATE="2026-03-31"
    mkdir -p "${REPO_ROOT}/docs/tasks/open" "${REPO_ROOT}/docs/tasks/closed"
}

assert_pickability() {
    local expected="$1" task_rel="$2" expected_reason="${3:-}"
    local output=""
    local status_code=0

    if output="$(backlog_task_is_pickable "${task_rel}" 2>&1)"; then
        status_code=0
    else
        status_code=$?
    fi

    if [[ "${expected}" == "pickable" ]]; then
        if [[ "${status_code}" -ne 0 ]]; then
            printf 'Expected %s to be pickable, but backlog_task_is_pickable exited %s with output:\n%s\n' \
                "${task_rel}" "${status_code}" "${output}" >&2
            return 1
        fi
    else
        if [[ "${status_code}" -eq 0 ]]; then
            printf 'Expected %s to be blocked, but backlog_task_is_pickable returned success.\n' \
                "${task_rel}" >&2
            return 1
        fi
    fi

    if [[ -n "${expected_reason}" && "${output}" != *"${expected_reason}"* ]]; then
        printf 'Expected output for %s to contain %s, got:\n%s\n' \
            "${task_rel}" "${expected_reason}" "${output}" >&2
        return 1
    fi
}

echo "=== test_backlog_dependency_gate.sh ==="
source "${NS_DIR}/nightshift.conf"
source "${NS_DIR}/nightshift.sh"

(
    setup_repo "missing-task-repo"
    assert_pickability blocked "docs/tasks/open/missing-task.md" "no longer exists"
) && pass "1. backlog_task_is_pickable rejects missing task files" \
  || fail "1. backlog_task_is_pickable rejects missing task files" "missing task was treated as pickable"

(
    setup_repo "in-progress-repo"
    write_hash_task "${REPO_ROOT}/docs/tasks/open/in-progress.md" "in progress"
    assert_pickability blocked "docs/tasks/open/in-progress.md" "in progress"
) && pass "2. backlog_task_is_pickable rejects non-not-started primary tasks" \
  || fail "2. backlog_task_is_pickable rejects non-not-started primary tasks" "in-progress task was treated as pickable"

(
    setup_repo "open-dependency-statuses-repo"

    write_hash_task "${REPO_ROOT}/docs/tasks/open/open-not-started.md" "not started"
    write_legacy_task "${REPO_ROOT}/docs/tasks/open/blocked-by-open-not-started.md" "not started" "Single agent" "docs/tasks/open/open-not-started.md"
    assert_pickability blocked "docs/tasks/open/blocked-by-open-not-started.md" "not started"

    write_hash_task "${REPO_ROOT}/docs/tasks/open/open-in-progress.md" "in progress"
    write_legacy_task "${REPO_ROOT}/docs/tasks/open/blocked-by-open-in-progress.md" "not started" "Single agent" "docs/tasks/open/open-in-progress.md"
    assert_pickability blocked "docs/tasks/open/blocked-by-open-in-progress.md" "in progress"
) && pass "3. resolved open dependencies block when their status is non-terminal" \
  || fail "3. resolved open dependencies block when their status is non-terminal" "open dependency status did not block pickability"

(
    setup_repo "closed-nonterminal-statuses-repo"

    while IFS='|' read -r dep_slug dep_status; do
        write_hash_task "${REPO_ROOT}/docs/tasks/closed/${dep_slug}.md" "${dep_status}"
        write_legacy_task "${REPO_ROOT}/docs/tasks/open/${dep_slug}-consumer.md" "not started" "Single agent" "docs/tasks/closed/${dep_slug}.md"
        assert_pickability blocked "docs/tasks/open/${dep_slug}-consumer.md" "${dep_status}"
    done <<'EOF'
closed-not-started|not started
closed-needs-verification|needs verification
closed-status|closed
verified-needs-followup|verified - needs verification follow-up
EOF
) && pass "4. resolved closed-path dependencies still block when their status is non-terminal" \
  || fail "4. resolved closed-path dependencies still block when their status is non-terminal" "non-terminal closed-path dependency was treated as satisfied"

(
    setup_repo "closed-terminal-statuses-repo"

    while IFS='|' read -r dep_slug dep_status; do
        write_hash_task "${REPO_ROOT}/docs/tasks/closed/${dep_slug}.md" "${dep_status}"
        write_legacy_task "${REPO_ROOT}/docs/tasks/open/${dep_slug}-consumer.md" "not started" "Single agent" "docs/tasks/closed/${dep_slug}.md"
        assert_pickability pickable "docs/tasks/open/${dep_slug}-consumer.md"
    done <<'EOF'
done-status|done
complete-status|complete
completed-status|completed
verified-status|verified - closed by user
EOF
) && pass "5. resolved dependencies unblock only for terminal statuses" \
  || fail "5. resolved dependencies unblock only for terminal statuses" "terminal dependency statuses did not unblock pickability"

(
    setup_repo "closed-suffixed-terminal-status-repo"

    write_hash_task "${REPO_ROOT}/docs/tasks/closed/legacy-done.md" "done (legacy migration)"
    write_legacy_task "${REPO_ROOT}/docs/tasks/open/legacy-done-consumer.md" "not started" "Single agent" "docs/tasks/closed/legacy-done.md"
    assert_pickability pickable "docs/tasks/open/legacy-done-consumer.md"
) && pass "6. suffixed terminal statuses remain terminal for dependency gating" \
  || fail "6. suffixed terminal statuses remain terminal for dependency gating" "terminal prefix match did not survive a status suffix"

(
    setup_repo "stale-explicit-path-repo"

    write_hash_task "${REPO_ROOT}/docs/tasks/closed/dep.md" "done"
    write_legacy_task "${REPO_ROOT}/docs/tasks/open/stale-ref.md" "not started" "Single agent" "docs/tasks/open/dep.md"
    assert_pickability blocked "docs/tasks/open/stale-ref.md" "missing"
) && pass "7. explicit stale dependency paths fail closed even if a closed copy exists" \
  || fail "7. explicit stale dependency paths fail closed even if a closed copy exists" "stale explicit dependency path was treated as satisfied"

(
    setup_repo "self-dependency-repo"

    write_hash_task "${REPO_ROOT}/docs/tasks/open/self-dependent.md" "not started" "single-agent" "docs/tasks/open/self-dependent.md"
    assert_pickability blocked "docs/tasks/open/self-dependent.md" "malformed"
) && pass "8. self-dependencies are treated as malformed blockers" \
  || fail "8. self-dependencies are treated as malformed blockers" "self-dependency was treated as satisfied"

(
    setup_repo "unique-slug-dependency-repo"

    write_hash_task "${REPO_ROOT}/docs/tasks/open/unique-resolved/task.md" "in progress"
    write_legacy_task "${REPO_ROOT}/docs/tasks/open/unique-slug-consumer.md" "not started" "Single agent" "unique-resolved"
    assert_pickability blocked "docs/tasks/open/unique-slug-consumer.md" "in progress"
) && pass "9. unique non-path dependency tokens resolve and block on non-terminal status" \
  || fail "9. unique non-path dependency tokens resolve and block on non-terminal status" "unique non-path dependency did not resolve as expected"

(
    setup_repo "prose-dependency-repo"

    write_legacy_task "${REPO_ROOT}/docs/tasks/open/prose-ok.md" "not started" "Single agent" "task 5 must exist first"
    assert_pickability pickable "docs/tasks/open/prose-ok.md"
) && pass "10. prose dependency text remains non-blocking" \
  || fail "10. prose dependency text remains non-blocking" "prose dependency text blocked pickability"

(
    setup_repo "ambiguous-dependency-repo"

    write_hash_task "${REPO_ROOT}/docs/tasks/open/team-a/shared.md" "not started"
    write_hash_task "${REPO_ROOT}/docs/tasks/open/team-b/shared.md" "not started"
    write_legacy_task "${REPO_ROOT}/docs/tasks/open/ambiguous-ok.md" "not started" "Single agent" "shared"
    assert_pickability pickable "docs/tasks/open/ambiguous-ok.md"
) && pass "11. ambiguous non-path dependency tokens remain non-blocking" \
  || fail "11. ambiguous non-path dependency tokens remain non-blocking" "ambiguous non-path dependency blocked pickability"

echo ""
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi

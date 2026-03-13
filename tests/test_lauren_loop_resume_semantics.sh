#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_ROOT="$(mktemp -d "${TMP_BASE}/lauren-loop-resume.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

LAST_STATUS=0
LAST_OUTPUT=""

create_fixture() {
    local fixture
    fixture="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"

    mkdir -p "$fixture/docs/tasks/open" "$fixture/docs/tasks/closed" "$fixture/templates" "$fixture/prompts" "$fixture/bin" "$fixture/home" "$fixture/lib"
    cp "$REPO_ROOT/lauren-loop.sh" "$fixture/lauren-loop.sh"
    cp "$REPO_ROOT/lib/lauren-loop-utils.sh" "$fixture/lib/lauren-loop-utils.sh"
    cp "$REPO_ROOT/templates/pilot-task.md" "$fixture/templates/pilot-task.md"
    printf 'Lead prompt placeholder.\n' > "$fixture/prompts/lead.md"
    printf 'Critic prompt placeholder.\n' > "$fixture/prompts/critic.md"
    : > "$fixture/prompts/project-rules.md"

    perl -0pi -e 's|LOCK_FILE="/tmp/lauren-loop-pilot\.lock"|LOCK_FILE="__FIXTURE_LOCK__"|g' "$fixture/lauren-loop.sh"
    perl -0pi -e 's|__FIXTURE_LOCK__|'"$fixture"'/lauren-loop.lock|g' "$fixture/lauren-loop.sh"
    perl -0pi -e 's|wait "\\$pid" 2>/dev/null|wait "\\$pid" 2>/dev/null || true|g' "$fixture/lauren-loop.sh"

    cat <<'EOF' > "$fixture/bin/claude"
#!/bin/bash
set -euo pipefail

task_file=$(find . -path './docs/tasks/open/*.md' | head -1)
if [ -n "$task_file" ] && [ -f "$task_file" ]; then
    perl -0pi -e 's/^## Status: .*/## Status: plan-approved/m' "$task_file"
fi
EOF
    chmod +x "$fixture/bin/claude"

    (
        cd "$fixture"
        git init -q
        git config user.name "Codex Test"
        git config user.email "codex-test@example.com"
        git add lauren-loop.sh templates/pilot-task.md prompts docs
        git commit -q -m "fixture"
    )

    printf '%s\n' "$fixture"
}

write_task_file() {
    local path="$1"
    local title="$2"
    local status="$3"
    local goal="$4"

    cat <<EOF > "$path"
## Task: $title
## Status: $status
## Goal: $goal

## Current Plan
(Planner writes here)

## Critique
(Critic writes here)

## Plan History
(Archived plan+critique rounds)

## Execution Log
(Timestamped round results)
EOF
}

run_case() {
    local fixture="$1"
    shift

    local output_file
    output_file="$(mktemp "${TMP_ROOT}/output.XXXXXX")"

    if (
        cd "$fixture"
        HOME="$fixture/home" PATH="$fixture/bin:$PATH" bash ./lauren-loop.sh "$@"
    ) >"$output_file" 2>&1; then
        LAST_STATUS=0
    else
        LAST_STATUS=$?
    fi

    LAST_OUTPUT="$(cat "$output_file")"
    rm -f "$output_file"
}

assert_status() {
    local expected="$1"
    if [ "$LAST_STATUS" -ne "$expected" ]; then
        echo "Expected exit $expected, got $LAST_STATUS"
        echo "$LAST_OUTPUT"
        exit 1
    fi
}

assert_contains() {
    local needle="$1"
    if ! printf '%s' "$LAST_OUTPUT" | grep -Fq "$needle"; then
        echo "Expected output to contain: $needle"
        echo "$LAST_OUTPUT"
        exit 1
    fi
}

assert_not_contains() {
    local needle="$1"
    if printf '%s' "$LAST_OUTPUT" | grep -Fq "$needle"; then
        echo "Did not expect output to contain: $needle"
        echo "$LAST_OUTPUT"
        exit 1
    fi
}

assert_file_missing() {
    local path="$1"
    if [ -e "$path" ]; then
        echo "Expected file to be absent: $path"
        exit 1
    fi
}

assert_file_present() {
    local path="$1"
    if [ ! -e "$path" ]; then
        echo "Expected file to exist: $path"
        exit 1
    fi
}

echo "1. explicit --resume fails when no task file exists"
fixture="$(create_fixture)"
run_case "$fixture" missing "Goal" --resume
assert_status 1
assert_contains "No existing task file found for slug: missing"
assert_file_missing "$fixture/docs/tasks/open/pilot-missing.md"

echo "2. exact <slug>.md beats pilot and fuzzy matches"
fixture="$(create_fixture)"
write_task_file "$fixture/docs/tasks/open/foo.md" "Exact Task" "not-started" "Exact goal"
write_task_file "$fixture/docs/tasks/open/pilot-foo.md" "Pilot Task" "not-started" "Pilot goal"
write_task_file "$fixture/docs/tasks/open/task-foo-related.md" "Fuzzy Task" "not-started" "Fuzzy goal"
run_case "$fixture" foo "Goal" --dry-run
assert_status 0
assert_contains "$fixture/docs/tasks/open/foo.md"

echo "3. exact pilot match beats fuzzy non-pilot match"
fixture="$(create_fixture)"
write_task_file "$fixture/docs/tasks/open/pilot-foo.md" "Pilot Task" "not-started" "Pilot goal"
write_task_file "$fixture/docs/tasks/open/task-foo-related.md" "Fuzzy Task" "not-started" "Fuzzy goal"
run_case "$fixture" foo "Goal" --dry-run
assert_status 0
assert_contains "$fixture/docs/tasks/open/pilot-foo.md"
assert_not_contains "$fixture/docs/tasks/open/task-foo-related.md"

echo "4. auto-detected existing file bypasses explicit resume gate"
fixture="$(create_fixture)"
write_task_file "$fixture/docs/tasks/open/foo.md" "Auto Resume Task" "pilot-planning" "Auto goal"
run_case "$fixture" foo "Goal"
assert_not_contains "Cannot resume from status"
assert_contains "Running lead agent (plan + execute)..."

echo "5. explicit --resume still enforces the status allowlist"
fixture="$(create_fixture)"
write_task_file "$fixture/docs/tasks/open/foo.md" "Explicit Resume Task" "pilot-planning" "Resume goal"
run_case "$fixture" foo "Goal" --resume
assert_status 1
assert_contains "Cannot resume from status 'pilot-planning'"

echo "6. explicit --resume succeeds for allowed statuses"
fixture="$(create_fixture)"
write_task_file "$fixture/docs/tasks/open/foo.md" "Explicit Resume Task" "plan-approved" "Resume goal"
run_case "$fixture" foo "Goal" --resume
assert_contains "Resuming from status: plan-approved"
assert_contains "Running lead agent (plan + execute)..."

echo "All Lauren Loop resume semantics checks passed."

#!/bin/bash
INPUT=$(cat)
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // "unknown task"')
CWD=$(echo "$INPUT" | jq -r '.cwd')

cd "$CWD" 2>/dev/null || exit 0

if [ -d ".venv" ]; then
  source .venv/bin/activate 2>/dev/null
fi

if ! command -v pytest &>/dev/null; then
  exit 0
fi

TEST_FILES=$(find . -name "test_*.py" -o -name "*_test.py" 2>/dev/null | head -5)
if [ -z "$TEST_FILES" ]; then
  exit 0
fi

TEST_OUTPUT=$(pytest --tb=short -q 2>&1)
TEST_EXIT=$?

if [ $TEST_EXIT -ne 0 ]; then
  echo "WORKFLOW RULE: Tests must pass before a task can be completed. Task: '$TASK_SUBJECT'

pytest output:
$TEST_OUTPUT

Fix failing tests before marking this task as completed." >&2
  exit 2
fi
exit 0

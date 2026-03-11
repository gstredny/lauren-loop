#!/bin/bash
# PostToolUse hook: auto-generate retro entry when a task file moves to closed/
# Fires on: (mv|git mv) docs/tasks/open/*.md docs/tasks/closed/
# Pattern: append placeholder synchronously, fork claude -p to replace with real entry

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Gate: only trigger on task file moves to closed/
if ! echo "$COMMAND" | grep -qE '(mv|git mv).*docs/tasks/open/.*docs/tasks/closed/'; then
  exit 0
fi

# Extract task stem (filename without .md) from the destination path
TASK_STEM=$(echo "$COMMAND" | grep -oE 'docs/tasks/closed/[^ ]+' | sed 's|docs/tasks/closed/||; s|\.md$||')
if [ -z "$TASK_STEM" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
CLOSED_FILE="$PROJECT_DIR/docs/tasks/closed/${TASK_STEM}.md"
RETRO_FILE="$PROJECT_DIR/docs/tasks/RETRO.md"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/retro-hook.log"
TODAY=$(date +%Y-%m-%d)

# Verify closed file exists
if [ ! -f "$CLOSED_FILE" ]; then
  exit 0
fi

# Idempotency: check if a real (non-placeholder) retro entry already exists
if grep -q "### .* Task: ${TASK_STEM}$" "$RETRO_FILE" 2>/dev/null; then
  # Entry header exists — check if it's a real entry (not placeholder)
  if ! grep -A4 "### .* Task: ${TASK_STEM}$" "$RETRO_FILE" | grep -q '_retro pending_'; then
    # Real entry exists, skip
    exit 0
  fi
fi

# Idempotency: also skip if a placeholder already exists for this task stem
grep -q "### .* Task: ${TASK_STEM}$" "$RETRO_FILE" 2>/dev/null && exit 0

# Append placeholder entry synchronously
cat >> "$RETRO_FILE" << EOF

---

### ${TODAY} Task: ${TASK_STEM}
- **What worked:** _retro pending — auto-generation in progress_
- **What broke:** _retro pending_
- **Workflow friction:** _retro pending_
- **Pattern:** _retro pending_
EOF

# Ensure log directory exists
mkdir -p "$LOG_DIR"
echo "[$(date -Iseconds)] HOOK: placeholder appended for ${TASK_STEM}" >> "$LOG_FILE"

# Background fork: run claude -p to replace placeholder with real entry
(
  env -u CLAUDECODE claude -p "Generate retro entry for docs/tasks/closed/${TASK_STEM}.md" \
      --system-prompt "$(cat "$PROJECT_DIR/prompts/retro-hook.md")" \
      --model sonnet \
      --max-turns 10 \
      --permission-mode acceptEdits \
      --disallowedTools "Bash,Write,WebFetch,WebSearch" \
      --output-format text \
      >> "$LOG_FILE" 2>&1

  if [ $? -eq 0 ]; then
    echo "[$(date -Iseconds)] SUCCESS: retro generated for ${TASK_STEM}" >> "$LOG_FILE"
    afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
  else
    echo "[$(date -Iseconds)] FAILURE: retro generation failed for ${TASK_STEM}" >> "$LOG_FILE"
    afplay /System/Library/Sounds/Basso.aiff 2>/dev/null &
  fi
) & disown

exit 0

#!/bin/bash
# archive-round.sh — Move Current Plan + Critique to Plan History
# Usage: scripts/archive-round.sh <task-file> <round-number>
#
# Extracted from lauren-loop.sh archive_round() function for use by the
# Lead agent via Bash tool. Keeps section manipulation deterministic.

set -e

# Platform-portable sed in-place (macOS needs '' arg, GNU does not)
_sed_i() {
    if [[ "$(uname)" == "Linux" ]]; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# --- Argument validation ---
if [ $# -ne 2 ]; then
    echo "Usage: $0 <task-file> <round-number>"
    exit 1
fi

TASK_FILE="$1"
ROUND="$2"

if [ ! -f "$TASK_FILE" ]; then
    echo "Error: Task file not found: $TASK_FILE"
    exit 1
fi

if ! [[ "$ROUND" =~ ^[0-9]+$ ]]; then
    echo "Error: Round number must be a positive integer, got: $ROUND"
    exit 1
fi

# --- Extract section line numbers ---
plan_start=$(grep -n '^## Current Plan' "$TASK_FILE" | head -1 | cut -d: -f1)
critique_start=$(grep -n '^## Critique' "$TASK_FILE" | head -1 | cut -d: -f1)
history_start=$(grep -n '^## Plan History' "$TASK_FILE" | head -1 | cut -d: -f1)

if [ -z "$plan_start" ] || [ -z "$critique_start" ] || [ -z "$history_start" ]; then
    echo "Error: Cannot find required sections for archival"
    echo "  ## Current Plan: line ${plan_start:-MISSING}"
    echo "  ## Critique: line ${critique_start:-MISSING}"
    echo "  ## Plan History: line ${history_start:-MISSING}"
    exit 1
fi

# --- Extract plan and critique content ---
plan_content=$(sed -n "$((plan_start + 1)),$((critique_start - 1))p" "$TASK_FILE")
critique_content=$(sed -n "$((critique_start + 1)),$((history_start - 1))p" "$TASK_FILE")

if [ -z "$(echo "$plan_content" | tr -s '[:space:]')" ]; then
    echo "WARNING: ## Current Plan is empty in round $ROUND — archiving empty section" >&2
fi
if [ -z "$(echo "$critique_content" | tr -s '[:space:]')" ]; then
    echo "WARNING: ## Critique is empty in round $ROUND — archiving empty section" >&2
fi

# --- Build archive entry in a temp file ---
archive_file=$(mktemp)
{
    echo ""
    echo "### Round $ROUND"
    echo ""
    echo "#### Plan"
    echo "$plan_content"
    echo ""
    echo "#### Critique"
    echo "$critique_content"
    echo "---"
} > "$archive_file"

# --- Insert archive entry after ## Plan History header ---
_sed_i "/^## Plan History$/r $archive_file" "$TASK_FILE"
rm -f "$archive_file"

# --- Clear Current Plan section ---
tmp_file=$(mktemp)
awk -v ps="$plan_start" -v cs="$critique_start" '
    NR == ps { print; print "(Planner writes here)"; next }
    NR > ps && NR < cs { next }
    { print }
' "$TASK_FILE" > "$tmp_file"

# --- Clear Critique section ---
# Recalculate line numbers after plan section was modified
new_critique_start=$(grep -n '^## Critique' "$tmp_file" | head -1 | cut -d: -f1)
new_history_start=$(grep -n '^## Plan History' "$tmp_file" | head -1 | cut -d: -f1)

tmp_file2=$(mktemp)
awk -v cs="$new_critique_start" -v hs="$new_history_start" '
    NR == cs { print; print "(Critic writes here)"; next }
    NR > cs && NR < hs { next }
    { print }
' "$tmp_file" > "$tmp_file2"

cp "$tmp_file2" "$TASK_FILE"
rm -f "$tmp_file" "$tmp_file2"

# --- Validate task file structure after modification ---
required_sections=("## Task:" "## Status:" "## Goal:" "## Current Plan" "## Critique" "## Plan History" "## Execution Log")
valid=true

for section in "${required_sections[@]}"; do
    if ! grep -q "^${section}" "$TASK_FILE"; then
        echo "Error: Missing section after archival: ${section}"
        valid=false
    fi
done

if [ "$valid" = false ]; then
    echo "Error: Task file structure corrupted after archival"
    exit 1
fi

echo "Archived round $ROUND to Plan History"

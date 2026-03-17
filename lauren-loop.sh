#!/bin/bash
# lauren-loop.sh — Autonomous Planner-Critic Pipeline
# Runs planner and critic agents in a loop using claude -p sessions
# with a task file as the communication bus.
#
# Usage:
#   ./lauren-loop.sh <slug> "<goal>" [--dry-run] [--resume] [--model <model>] [--no-review] [--no-close]
#
# Examples:
#   ./lauren-loop.sh test-task "Test the planner-critic pipeline" --dry-run
#   ./lauren-loop.sh fix-auth "Fix JWT validation in login flow"
#   ./lauren-loop.sh fix-auth "Fix JWT validation" --resume  # resume existing task

set -e

# Colors (matching scripts/verify.sh conventions)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Defaults
MODEL="${LAUREN_LOOP_MODEL:-opus}"
MAX_ROUNDS=3
DRY_RUN=false
RESUME=false
LEGACY=false
LOG_DIR="$SCRIPT_DIR/logs/pilot"
LOCK_FILE="/tmp/lauren-loop-pilot.lock"
INTERNAL=false
NO_REVIEW=false
NO_CLOSE=false

# Agent timeout limits (env-overridable)
LEAD_TIMEOUT="${LEAD_TIMEOUT:-120m}"
EXECUTOR_TIMEOUT="${EXECUTOR_TIMEOUT:-120m}"
CRITIC_TIMEOUT="${CRITIC_TIMEOUT:-15m}"
REVIEWER_TIMEOUT="${REVIEWER_TIMEOUT:-30m}"
FIX_TIMEOUT="${FIX_TIMEOUT:-45m}"

LEAD_PROMPT="$SCRIPT_DIR/prompts/lead.md"

# Load project rules (prepended to all agent system prompts)
PROJECT_RULES=$(cat "$SCRIPT_DIR/prompts/project-rules.md" 2>/dev/null || echo "")

# Suppress hooks and skills in spawned agent sessions.
# disableAllHooks: official Claude Code setting (docs: code.claude.com/docs/en/hooks)
# --disable-slash-commands: prevents skill/command auto-loading
AGENT_SETTINGS='{"disableAllHooks":true}'

# Project-scoped cache for next/pick subcommands
PROJ_HASH=$(printf '%s' "$SCRIPT_DIR" | md5 -q 2>/dev/null || printf '%s' "$SCRIPT_DIR" | md5sum | cut -c1-8)
PROJ_HASH="${PROJ_HASH:0:8}"
NEXT_CACHE="/tmp/lauren-loop-next-${USER}-${PROJ_HASH}.txt"

# Source context guard and set Azure env vars for all claude calls
if [[ -f "$HOME/.claude/scripts/context-guard.sh" ]]; then
  source "$HOME/.claude/scripts/context-guard.sh"
  if ! setup_azure_context; then
    echo -e "${YELLOW}[WARN] Azure context guard failed — claude calls may use personal API. Run 'az account show' to re-authenticate.${NC}" >&2
  else
    echo -e "${GREEN}[INFO] Azure context guard loaded.${NC}"
  fi
else
  echo -e "${YELLOW}[WARN] No context-guard.sh found — skipping Azure routing.${NC}"
fi

# Source shared utility functions
. "$SCRIPT_DIR/lib/lauren-loop-utils.sh"

# Source project config (optional overrides)
[[ -f "$SCRIPT_DIR/.lauren-loop.conf" ]] && source "$SCRIPT_DIR/.lauren-loop.conf"

# Config-driven project values (fallback defaults if conf doesn't set them)
PROJECT_NAME="${PROJECT_NAME:-AskGeorge}"
TEST_CMD="${TEST_CMD:-.venv/bin/python -m pytest tests/ -x -q}"
LINT_CMD="${LINT_CMD:-.venv/bin/python -m flake8 src/ --count --select=E9,F63,F7,F82 --show-source --statistics}"

# ============================================================
# Utility functions (needed by subcommands and main pipeline)
# ============================================================
acquire_lock() {
    if [ "$INTERNAL" = true ]; then
        return 0  # Parent holds the lock
    fi
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            echo -e "${RED}Another lauren-loop.sh is running (PID $lock_pid). Exiting.${NC}"
            exit 1
        else
            echo -e "${YELLOW}Stale lock file found (PID $lock_pid not running). Removing.${NC}"
            rm -f "$LOCK_FILE" "${LOCK_FILE}.slug"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    if [[ -n "${SLUG:-}" ]]; then
        echo "$SLUG" > "${LOCK_FILE}.slug"
        _check_cross_version_lock "v1" "$SLUG" || true
    fi
}

release_lock() {
    rm -f "$LOCK_FILE" "${LOCK_FILE}.slug"
}

cleanup() {
    stop_lead_monitor 2>/dev/null
    rm -f "$LOG_DIR"/*.bak
    release_lock
}

trap cleanup EXIT

# ============================================================
# Lead agent status monitor (background watchers)
# ============================================================
LEAD_MONITOR_PIDS=""

start_lead_monitor() {
    local log_file="$1"
    local task_file="$2"

    # Channel 1: Poll task file status every 5s
    (
        local last_status=""
        while true; do
            local status
            status=$(grep '^## Status:' "$task_file" 2>/dev/null | head -1 | sed 's/^## Status: //' | tr -d '\r')
            if [ -n "$status" ] && [ "$status" != "$last_status" ]; then
                case "$status" in
                    planning-round-*)
                        echo -e "  ${BLUE}▸ Phase 1: Planning (round ${status#planning-round-})...${NC}" ;;
                    plan-approved)
                        echo -e "  ${GREEN}▸ Phase 2: Plan approved${NC}" ;;
                    plan-failed)
                        echo -e "  ${RED}▸ Plan failed after all rounds${NC}" ;;
                    executing)
                        echo -e "  ${BLUE}▸ Phase 3: Executing plan via TDD...${NC}" ;;
                    executed)
                        echo -e "  ${GREEN}▸ Phase 3: Execution complete${NC}" ;;
                    execution-blocked)
                        echo -e "  ${YELLOW}▸ Phase 3: Execution blocked${NC}" ;;
                    execution-failed)
                        echo -e "  ${RED}▸ Phase 3: Execution failed${NC}" ;;
                esac
                last_status="$status"
            fi
            sleep 5
        done
    ) &
    local status_pid=$!

    # Channel 2: Tail log for within-phase milestones
    (
        tail -n 0 -f "$log_file" 2>/dev/null | grep --line-buffered -iE \
            'spawn.*critic|VERDICT:|RED:|GREEN:|REFACTOR:|BLOCKED:|pytest.*passed|tests? passed' \
        | while IFS= read -r line; do
            if echo "$line" | grep -qi 'spawn.*critic'; then
                echo -e "  ${BLUE}▸ Phase 2: Spawning critic...${NC}"
            elif echo "$line" | grep -qi 'VERDICT:.*EXECUTE'; then
                echo -e "  ${GREEN}▸ Phase 2: Critic verdict: EXECUTE${NC}"
            elif echo "$line" | grep -qi 'VERDICT:.*BLOCKED'; then
                echo -e "  ${YELLOW}▸ Phase 2: Critic verdict: BLOCKED${NC}"
            elif echo "$line" | grep -qi 'VERDICT:.*PASS'; then
                echo -e "  ${GREEN}▸ Phase 2: Critic verdict: PASS${NC}"
            elif echo "$line" | grep -qi 'VERDICT:.*FAIL'; then
                echo -e "  ${YELLOW}▸ Phase 2: Critic verdict: FAIL${NC}"
            elif echo "$line" | grep -q 'RED:'; then
                echo -e "  ${RED}▸ TDD RED: writing failing test${NC}"
            elif echo "$line" | grep -q 'GREEN:'; then
                echo -e "  ${GREEN}▸ TDD GREEN: test passing${NC}"
            elif echo "$line" | grep -q 'REFACTOR:'; then
                echo -e "  ${BLUE}▸ TDD REFACTOR${NC}"
            elif echo "$line" | grep -qi 'BLOCKED:'; then
                echo -e "  ${YELLOW}▸ BLOCKED — check log for details${NC}"
            elif echo "$line" | grep -qiE 'pytest.*passed|tests? passed'; then
                echo -e "  ${GREEN}▸ Phase 3: Running tests...${NC}"
            fi
        done
    ) &
    local log_pid=$!

    LEAD_MONITOR_PIDS="$status_pid $log_pid"
}

stop_lead_monitor() {
    if [ -n "$LEAD_MONITOR_PIDS" ]; then
        for pid in $LEAD_MONITOR_PIDS; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi
        done
        LEAD_MONITOR_PIDS=""
    fi
}

log_signal() {
    mkdir -p "$LOG_DIR"
    printf '[%s] signal=%s slug=%s phase=%s pid=%s\n' \
        "$(date -Iseconds)" "$1" "${SLUG:-}" "${PHASE:-}" "$$" >> "$LOG_DIR/signals.log"
}

handle_signal() {
    local signal_name="$1"
    log_signal "$signal_name"
    trap - "$signal_name"
    kill -s "$signal_name" "$$"
}

trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

run_retro_agent() {
    local task_stem="$1"
    local retro_log="$LOG_DIR/retro-hook.log"

    mkdir -p "$LOG_DIR"
    printf '[%s] START: retro generation for %s\n' "$(date -Iseconds)" "$task_stem" >> "$retro_log"

    _timeout 120 env -u CLAUDECODE claude -p "Generate retro entry for docs/tasks/closed/${task_stem}.md" \
        --system-prompt "$(cat "$SCRIPT_DIR/prompts/retro-hook.md")" \
        --model sonnet \
        --max-turns 10 \
        --permission-mode acceptEdits \
        --disallowedTools "Bash,Write,WebFetch,WebSearch" \
        --output-format text \
        >> "$retro_log" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ "$rc" -eq 124 ]; then
        printf '[%s] TIMEOUT: retro generation timed out after 120s for %s\n' "$(date -Iseconds)" "$task_stem" >> "$retro_log"
    fi
    return 1
}

# ============================================================
# scan_eligible_tasks — Pre-filter tasks by status
# Sets: ELIGIBLE_TASKS, EXCLUDED_TASKS
# ============================================================
scan_eligible_tasks() {
    ELIGIBLE_TASKS=""
    EXCLUDED_TASKS=""
    local eligible_count=0
    local excluded_count=0

    while IFS= read -r file; do
        local basename
        basename=$(basename "$file")
        # Skip non-task files
        [[ "$basename" == "INDEX.md" || "$basename" == "FEATURE-ROADMAP.md" ]] && continue

        # Extract status line (first 5 lines, case-insensitive match)
        local status_line
        status_line=$(head -5 "$file" | grep -i '^## Status:' | head -1)
        # Skip files without a Status header (not task files)
        [ -z "$status_line" ] && continue

        # Normalize: strip header prefix, trim whitespace, lowercase
        local task_status
        task_status=$(echo "$status_line" | sed 's/^## [Ss]tatus:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')

        local rel_path="${file#$SCRIPT_DIR/}"

        if [[ "$task_status" == "not started" ]]; then
            ELIGIBLE_TASKS="${ELIGIBLE_TASKS}${ELIGIBLE_TASKS:+$'\n'}${rel_path}"
            eligible_count=$((eligible_count + 1))
        else
            EXCLUDED_TASKS="${EXCLUDED_TASKS}${EXCLUDED_TASKS:+$'\n'}${rel_path} (${task_status})"
            excluded_count=$((excluded_count + 1))
        fi
    done < <(find "$SCRIPT_DIR/docs/tasks/open" -name '*.md' -not -path '*/competitive/*' | sort)

    printf '[%s] Task scan: %d eligible, %d excluded\n' "$(date -Iseconds)" "$eligible_count" "$excluded_count" >&2
}

# ============================================================
# gather_ranking_context — Build enriched user prompt for next/pick
# Sets: NEXT_TASK_USER_PROMPT
# ============================================================
gather_ranking_context() {
    local base_instruction="Analyze the open tasks and recommend what to work on next."

    # Git state: uncommitted changes and recent diff stats
    local git_state=""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local porcelain diff_stat
        porcelain=$(git status --porcelain 2>/dev/null | head -20)
        diff_stat=$(git diff --stat HEAD 2>/dev/null | tail -5)
        if [ -n "$porcelain" ] || [ -n "$diff_stat" ]; then
            git_state="## Git State (uncommitted changes)
\`\`\`
${porcelain}
\`\`\`"
            if [ -n "$diff_stat" ]; then
                git_state="${git_state}

Diff stats:
\`\`\`
${diff_stat}
\`\`\`"
            fi
        fi
    fi

    # Closed-task summaries: 10 most recently modified
    local closed_summaries=""
    local closed_dir="$SCRIPT_DIR/docs/tasks/closed"
    if [ -d "$closed_dir" ]; then
        local closed_files
        closed_files=$(ls -t "$closed_dir"/*.md 2>/dev/null | head -10)
        if [ -n "$closed_files" ]; then
            local summaries=""
            while IFS= read -r cf; do
                local task_name goal attempts_preview
                task_name=$(grep -m1 '^## Task:' "$cf" 2>/dev/null | sed 's/^## Task: //')
                goal=$(grep -m1 '^## Goal:' "$cf" 2>/dev/null | sed 's/^## Goal: //')
                attempts_preview=$(sed -n '/^## Attempts:/,/^## /{ /^## Attempts:/d; /^## /d; p; }' "$cf" 2>/dev/null | head -3)
                if [ -n "$task_name" ]; then
                    summaries="${summaries}
- **${task_name}** — ${goal}
  Attempts: ${attempts_preview:-none recorded}"
                fi
            done <<< "$closed_files"
            if [ -n "$summaries" ]; then
                closed_summaries="## Recently Closed Tasks
${summaries}"
            fi
        fi
    fi

    # Scan eligible vs excluded tasks
    scan_eligible_tasks
    local eligible_count
    eligible_count=$(echo "$ELIGIBLE_TASKS" | grep -c . 2>/dev/null || echo 0)

    local eligible_section=""
    if [ -n "$ELIGIBLE_TASKS" ]; then
        eligible_section="## Eligible Tasks (Status: not started) — ONLY rank these ${eligible_count} tasks
${ELIGIBLE_TASKS}"
    else
        eligible_section="## Eligible Tasks (Status: not started)
No eligible tasks found. All open tasks are in progress, blocked, or awaiting verification."
    fi

    local excluded_section=""
    if [ -n "$EXCLUDED_TASKS" ]; then
        excluded_section="## Excluded Tasks — DO NOT rank these
These tasks are already in progress, blocked, or awaiting verification. Use them only for dependency context.
${EXCLUDED_TASKS}"
    fi

    # Assemble enriched user prompt
    NEXT_TASK_USER_PROMPT="$base_instruction"

    NEXT_TASK_USER_PROMPT="${NEXT_TASK_USER_PROMPT}

${eligible_section}"

    if [ -n "$excluded_section" ]; then
        NEXT_TASK_USER_PROMPT="${NEXT_TASK_USER_PROMPT}

${excluded_section}"
    fi

    if [ -n "$git_state" ]; then
        NEXT_TASK_USER_PROMPT="${NEXT_TASK_USER_PROMPT}

${git_state}"
    fi
    if [ -n "$closed_summaries" ]; then
        NEXT_TASK_USER_PROMPT="${NEXT_TASK_USER_PROMPT}

${closed_summaries}"
    fi
}

# ============================================================
# Argument parsing
# ============================================================
usage() {
    echo "Usage: $0 <subcommand|slug> [args...]"
    echo ""
    echo "Subcommands:"
    echo "  list                  List open tasks and pick one to run (instant, no LLM)"
    echo "  list --status <s>     Filter by status (e.g. 'not started')"
    echo "  next                  Recommend which open task to work on next"
    echo "  pick                  Interactively pick a task (ranked list with numbered selection)"
    echo "  auto <slug> <goal>    Classify once and route to V1 or V2"
    echo "  reset <slug>          Reset stuck task to last stable status"
    echo "  execute <slug>        Execute a plan-approved task via TDD executor"
    echo "  review <slug>         Review an executed or verification-ready task's diff via reviewer + critic loop"
    echo "  fix <slug>            Apply fixes for review findings, then re-review"
    echo "  chaos <slug>          Run chaos-critic against approved plan"
    echo "  verify <slug>         Goal-backward verification of task outcomes"
    echo "  classify <slug>       Classify task complexity as simple or complex"
    echo "  close <slug>          Move a review-passed task to closed/ and write retro"
    echo "  plan-check <slug>     Validate XML plan structure"
    echo "  progress <slug>       Show task progress summary"
    echo "  pause <slug>          Snapshot task state for later resume"
    echo "  resume <slug>         Restore paused task and continue"
    echo ""
    echo "Planner-Critic Pipeline:"
    echo "  $0 <slug> \"<goal>\" [--dry-run] [--resume] [--model <model>] [--no-review] [--no-close]"
    echo ""
    echo "Options:"
    echo "  --dry-run    Create task file only, skip agent runs"
    echo "  --resume     Resume an existing task file instead of creating new"
    echo "  --legacy     Use legacy planner-critic loop + separate executor"
    echo "  --model      Model to use for agents (default: opus)"
    echo "  --simple     Force V1 routing (auto subcommand only)"
    echo "  --thorough   Force V2 routing (auto subcommand only)"
    echo "  --force      Force rerun of V2 phases (auto subcommand only)"
    echo "  --no-review  Skip auto-review after execution (manual review later)"
    echo "  --no-close   Skip auto-close after review-passed"
    echo ""
    echo "Environment:"
    echo "  LAUREN_LOOP_MODEL   Default model (overridden by --model)"
    exit 1
}

# ============================================================
# resolve_task_file — Find existing task or return default pilot path
# Sets TASK_FILE and optionally SOURCE_TASK_FILE (for linking)
# Returns: 0 found, 1 not found, 2 ambiguous flat+directory slug
# ============================================================
resolve_task_file() {
    local slug="$1"
    local task_dir="$SCRIPT_DIR/docs/tasks/open"
    local dir_task="$task_dir/${slug}/task.md"
    local flat_task="$task_dir/${slug}.md"
    TASK_FILE=""
    SOURCE_TASK_FILE=""

    if [ -f "$dir_task" ] && [ -f "$flat_task" ]; then
        echo "ERROR: ambiguous task slug '$slug' matches both $flat_task and $dir_task" >&2
        return 2
    fi

    if [ -f "$dir_task" ]; then
        TASK_FILE="$dir_task"
        return 0
    fi

    # Exact match: <slug>.md
    if [ -f "$flat_task" ]; then
        TASK_FILE="$flat_task"
        return 0
    fi

    # Exact match: pilot-<slug>.md
    if [ -f "$task_dir/pilot-${slug}.md" ]; then
        TASK_FILE="$task_dir/pilot-${slug}.md"
        return 0
    fi

    # Uppercase variant: SLUG with uppercase (e.g., FEATURE-STREAMING-SSE.md)
    local upper_slug
    upper_slug=$(echo "$slug" | tr 'a-z' 'A-Z')
    if [ -f "$task_dir/${upper_slug}.md" ]; then
        TASK_FILE="$task_dir/${upper_slug}.md"
        return 0
    fi
    if [ -f "$task_dir/pilot-${upper_slug}.md" ]; then
        TASK_FILE="$task_dir/pilot-${upper_slug}.md"
        return 0
    fi

    # Fuzzy match: *<slug>*.md (first non-pilot match)
    local fuzzy_match
    fuzzy_match=$(find "$task_dir" -maxdepth 1 -name "*${slug}*.md" -not -name "pilot-*" 2>/dev/null | head -1)
    if [ -n "$fuzzy_match" ]; then
        TASK_FILE="$fuzzy_match"
        return 0
    fi

    # No existing match — check if a related task exists for source linking
    local related_match
    related_match=$(find "$task_dir" -maxdepth 1 -name "*.md" -not -name "pilot-*" 2>/dev/null | while read -r f; do
        local base
        base=$(task_file_stem "$f")
        if echo "$slug" | grep -q "$base" || echo "$base" | grep -q "$slug"; then
            echo "$f"
            break
        fi
    done)
    if [ -n "$related_match" ]; then
        SOURCE_TASK_FILE="$related_match"
    fi

    # Default: pilot-<slug>.md (new file)
    TASK_FILE="$task_dir/pilot-${slug}.md"
    return 1
}

is_v2_task_file() {
    case "$1" in
        "$SCRIPT_DIR"/docs/tasks/open/*/task.md) return 0 ;;
        *) return 1 ;;
    esac
}

require_existing_task_file() {
    local slug="$1"
    local resolve_rc=0
    resolve_task_file "$slug" || resolve_rc=$?
    case "$resolve_rc" in
        0) return 0 ;;
        1)
            echo -e "${RED}Task file not found: $TASK_FILE${NC}"
            return 1
            ;;
        2) return 2 ;;
        *) return "$resolve_rc" ;;
    esac
}

task_file_stem() {
    local task_path="$1"
    local task_name

    task_name=$(basename "$task_path")
    if [ "$task_name" = "task.md" ]; then
        basename "$(dirname "$task_path")"
    else
        basename "$task_path" .md
    fi
}

# ============================================================
# _list_collect_tasks — Scan open tasks and populate arrays
# Optional $1: status filter (case-insensitive, e.g. "not started")
# Sets: LIST_SLUGS, LIST_GOALS, LIST_STATUSES, LIST_FILES, LIST_COUNT
# ============================================================
_list_collect_tasks() {
    local status_filter=""
    if [ -n "${1:-}" ]; then
        status_filter=$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')
    fi

    LIST_SLUGS=()
    LIST_GOALS=()
    LIST_STATUSES=()
    LIST_FILES=()
    LIST_COUNT=0

    while IFS= read -r file; do
        local bn
        bn=$(basename "$file")
        [[ "$bn" == "INDEX.md" || "$bn" == "FEATURE-ROADMAP.md" ]] && continue

        # Extract status (first 5 lines)
        local status_line
        status_line=$(head -5 "$file" | grep -i '^## Status:' | head -1)
        [ -z "$status_line" ] && continue

        local task_status
        task_status=$(echo "$status_line" | sed 's/^## [Ss]tatus:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')

        # Apply status filter if provided
        if [ -n "$status_filter" ] && [ "$task_status" != "$status_filter" ]; then
            continue
        fi

        # Extract goal (first 10 lines)
        local goal_text
        goal_text=$(head -10 "$file" | grep -i '^## Goal:' | head -1 | sed 's/^## [Gg]oal:[[:space:]]*//')
        [ -z "$goal_text" ] && goal_text="(no goal)"

        local slug
        slug=$(task_file_stem "$file")

        LIST_SLUGS+=("$slug")
        LIST_GOALS+=("$goal_text")
        LIST_STATUSES+=("$task_status")
        LIST_FILES+=("$file")
    done < <(find "$SCRIPT_DIR/docs/tasks/open" -name '*.md' -not -path '*/competitive/*' | sort)

    LIST_COUNT=${#LIST_SLUGS[@]}
}

# ============================================================
# _list_display_and_select — Show numbered task table + interactive launch
# ============================================================
_list_display_and_select() {
    local running_v2_slugs=""
    running_v2_slugs=$(_list_running_v2_instances 2>/dev/null | cut -f1 || true)

    if [ "$LIST_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}No tasks found.${NC}"
        return 0
    fi

    # Count by status for summary
    local count_not_started=0 count_in_progress=0 count_needs_verification=0 count_blocked=0 count_other=0
    local i

    for (( i=0; i<LIST_COUNT; i++ )); do
        case "${LIST_STATUSES[$i]}" in
            "not started")          count_not_started=$((count_not_started + 1)) ;;
            "in progress")          count_in_progress=$((count_in_progress + 1)) ;;
            "needs verification")   count_needs_verification=$((count_needs_verification + 1)) ;;
            blocked)                count_blocked=$((count_blocked + 1)) ;;
            *)                      count_other=$((count_other + 1)) ;;
        esac
    done

    # Print header
    echo ""
    printf "  %4s  %-45s  %-20s  %s\n" "#" "SLUG" "STATUS" "GOAL"
    printf "  %4s  %-45s  %-20s  %s\n" "----" "---------------------------------------------" "--------------------" "---------------------------"

    # Print rows
    for (( i=0; i<LIST_COUNT; i++ )); do
        local color="$NC" running_tag="" display_goal display_status
        case "${LIST_STATUSES[$i]}" in
            "not started")          color="$GREEN" ;;
            "in progress")          color="$YELLOW" ;;
            "needs verification")   color="$BLUE" ;;
            blocked)                color="$RED" ;;
        esac

        running_tag=""
        if echo "$running_v2_slugs" | grep -qx "${LIST_SLUGS[$i]}" 2>/dev/null; then
            running_tag=" ${YELLOW}[RUNNING]${NC}"
        fi

        # Truncate goal to 55 chars
        display_goal="${LIST_GOALS[$i]}"
        if [ ${#display_goal} -gt 55 ]; then
            display_goal="${display_goal:0:52}..."
        fi

        display_status="${LIST_STATUSES[$i]}"

        printf "  %4s) %-45s  %b%-20s%b%b  %s\n" "$((i+1))" "${LIST_SLUGS[$i]}" "$color" "$display_status" "$NC" "$running_tag" "$display_goal"
    done

    # Summary
    echo ""
    local summary="  Total: ${LIST_COUNT} tasks"
    local parts=()
    [ "$count_not_started" -gt 0 ]        && parts+=("${count_not_started} not started")
    [ "$count_in_progress" -gt 0 ]        && parts+=("${count_in_progress} in progress")
    [ "$count_needs_verification" -gt 0 ] && parts+=("${count_needs_verification} needs verification")
    [ "$count_blocked" -gt 0 ]            && parts+=("${count_blocked} blocked")
    [ "$count_other" -gt 0 ]              && parts+=("${count_other} other")
    if [ ${#parts[@]} -gt 0 ]; then
        local IFS=", "
        summary="${summary} (${parts[*]})"
    fi
    echo -e "$summary"
    echo ""

    # Interactive selection
    local pick_input="" selected_idx="" selected_slug="" selected_goal=""
    local confirm_running="" pick_confirm="" pick_route=""
    local -a list_auto_cmd=()

    while true; do
        printf "  Enter number (0 to cancel): "
        if ! read -r pick_input </dev/tty; then
            echo ""
            echo "  Cancelled."
            return 0
        fi

        if [ -z "$pick_input" ]; then
            continue
        fi
        if [ "$pick_input" = "0" ] || [ "$pick_input" = "q" ] || [ "$pick_input" = "Q" ]; then
            echo "  Cancelled."
            return 0
        fi

        if ! [[ "$pick_input" =~ ^[0-9]+$ ]]; then
            echo -e "  ${RED}Invalid input. Enter a number from the list above, or 0 to cancel.${NC}"
            continue
        fi

        if [ "$pick_input" -lt 1 ] || [ "$pick_input" -gt "$LIST_COUNT" ]; then
            echo -e "  ${RED}Number $pick_input is not in the list. Try again or enter 0 to cancel.${NC}"
            continue
        fi

        selected_idx=$((pick_input - 1))
        selected_slug="${LIST_SLUGS[$selected_idx]}"
        selected_goal="${LIST_GOALS[$selected_idx]}"

        # Warn if running
        if _is_slug_running_v2 "$selected_slug" 2>/dev/null; then
            echo ""
            echo -e "  ${YELLOW}Warning: '${selected_slug}' is already running under V2.${NC}"
            printf "  Continue anyway? (y/n): "
            if ! read -r confirm_running </dev/tty; then
                echo ""
                echo "  Cancelled."
                return 0
            fi
            if [[ "$confirm_running" != "y" && "$confirm_running" != "Y" ]]; then
                continue
            fi
        fi

        echo ""
        echo -e "  ${GREEN}Selected: ${selected_slug}${NC}"
        echo "    ${selected_goal}"
        echo ""

        list_auto_cmd=( "$0" auto "$selected_slug" "$selected_goal" )
        if [ -n "${MODEL:-}" ]; then
            list_auto_cmd+=( --model "$MODEL" )
        fi
        if [ "$DRY_RUN" = true ]; then
            list_auto_cmd+=( --dry-run )
        fi

        while true; do
            printf "  Launch pipeline? (y/n) "
            if ! read -r pick_confirm </dev/tty; then
                echo ""
                echo "  Cancelled."
                return 0
            fi

            case "$pick_confirm" in
                y|Y)
                    while true; do
                        printf "  Route: (1) Auto-classify  (2) Simple (V1)  (3) Complex (V2) "
                        if ! read -r pick_route </dev/tty; then
                            echo ""
                            echo "  Cancelled."
                            return 0
                        fi

                        case "$pick_route" in
                            1)
                                ( "${list_auto_cmd[@]}" )
                                return $?
                                ;;
                            2)
                                ( "${list_auto_cmd[@]}" --simple )
                                return $?
                                ;;
                            3)
                                ( "${list_auto_cmd[@]}" --thorough )
                                return $?
                                ;;
                            0|n|N)
                                break
                                ;;
                            "")
                                echo -e "  ${RED}Enter 1, 2, or 3${NC}"
                                ;;
                            *)
                                echo -e "  ${RED}Enter 1, 2, or 3${NC}"
                                ;;
                        esac
                    done
                    ;;
                n|N)
                    echo ""
                    echo -e "  ${BLUE}To launch manually:${NC}"
                    echo "    ./lauren-loop.sh auto \"${selected_slug}\" \"${selected_goal}\""
                    return 0
                    ;;
                "")
                    echo -e "  ${RED}Enter y or n${NC}"
                    ;;
                *)
                    echo -e "  ${RED}Enter y or n${NC}"
                    ;;
            esac
        done
    done
}

_pick_load_ranked_tasks() {
    local pick_output_file="$1"
    local task_lines=""
    local line complexity remainder num file goal

    _PICK_PARSER_TIER=""
    PICK_NUMS=()
    PICK_FILES=()
    PICK_GOALS=()
    PICK_COMPLEXITY=()
    PICK_COUNT=0

    # Primary parser: extract pipe-delimited lines after ## TASK_LIST header
    if grep -q '^## TASK_LIST' "$pick_output_file"; then
        task_lines=$(sed -n '/^## TASK_LIST/,$ { /^## TASK_LIST/d; p; }' "$pick_output_file" \
            | sed '/^[[:space:]]*$/d' \
            | grep -E '^[0-9]+\|.+\|.+\|.+$' || true)
    fi
    [ -n "$task_lines" ] && _PICK_PARSER_TIER="primary"

    # Fallback parser: scrape **N. [filename]** or **N. filename** entries from human-readable output
    if [ -z "$task_lines" ]; then
        task_lines=$(grep -oE '\*\*[0-9]+\. \[([^]]+)\]\*\* — (.+)' "$pick_output_file" \
            | sed -E 's/\*\*([0-9]+)\. \[([^]]+)\]\*\* — (.*)/\1|\2|\3|Unknown/' || true)
        [ -n "$task_lines" ] && _PICK_PARSER_TIER="bold-bracket"
    fi
    if [ -z "$task_lines" ]; then
        task_lines=$(grep -oE '\*\*[0-9]+\. [^*]+\*\* — .+' "$pick_output_file" \
            | sed -E 's/\*\*([0-9]+)\. ([^*]+)\*\* — (.*)/\1|\2|\3|Unknown/' || true)
        [ -n "$task_lines" ] && _PICK_PARSER_TIER="bold-plain"
    fi

    if [ -z "$task_lines" ]; then
        echo -e "${YELLOW}Could not parse task list from ranking output.${NC}"
        echo "Full output is above — copy a task slug manually."
        return 1
    fi

    while IFS= read -r line; do
        complexity="${line##*|}"
        remainder="${line%|*}"
        num="${remainder%%|*}"
        remainder="${remainder#*|}"
        file="${remainder%%|*}"
        goal="${remainder#*|}"
        num=$(echo "$num" | tr -d '[:space:]')
        file=$(echo "$file" | tr -d '[:space:]')
        complexity=$(echo "$complexity" | tr -d '[:space:]')
        PICK_NUMS+=("$num")
        PICK_FILES+=("$file")
        PICK_GOALS+=("$goal")
        PICK_COMPLEXITY+=("$complexity")
    done <<< "$task_lines"

    PICK_COUNT=${#PICK_FILES[@]}
    if [ "$PICK_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}No tasks parsed from ranking output.${NC}"
        return 1
    fi

    echo -e "${DIM:-}(Parsed via ${_PICK_PARSER_TIER} parser)${NC:-}"

    for (( i=0; i<PICK_COUNT; i++ )); do
        if [[ -z "${PICK_FILES[$i]}" || -z "${PICK_GOALS[$i]}" ]]; then
            echo -e "${YELLOW}Warning: parser extracted empty file or goal at position $((i+1)) — rerun pick to refresh cache${NC}"
        fi
    done

    return 0
}

_pick_interactive_select_task() {
    local pick_temp_file="$1"
    local running_v2_slugs=""
    local local_complexity="" color="$NC" pick_stem="" running_tag=""
    local pick_input="" selected_idx="" selected_file="" selected_goal="" selected_slug=""
    local confirm_running="" pick_confirm="" pick_route=""
    local i
    local -a pick_auto_cmd=()

    running_v2_slugs=$(_list_running_v2_instances 2>/dev/null | cut -f1 || true)

    echo -e "${BLUE}Select a task:${NC}"
    echo ""
    for i in $(seq 0 $(( PICK_COUNT - 1 ))); do
        local_complexity="${PICK_COMPLEXITY[$i]}"
        case "$local_complexity" in
            Low)    color="$GREEN" ;;
            Medium) color="$YELLOW" ;;
            High)   color="$RED" ;;
            *)      color="$NC" ;;
        esac
        pick_stem=$(task_file_stem "${PICK_FILES[$i]}")
        running_tag=""
        if echo "$running_v2_slugs" | grep -qx "$pick_stem" 2>/dev/null; then
            running_tag=" ${YELLOW}[RUNNING]${NC}"
        fi
        printf "  %2s) %-40s %b[%s]%b%b\n" "${PICK_NUMS[$i]}" "${PICK_FILES[$i]}" "$color" "$local_complexity" "$NC" "$running_tag"
        printf "      %s\n" "${PICK_GOALS[$i]}"
    done
    echo ""
    echo "   0) Cancel"
    echo ""

    while true; do
        printf "Enter number: "
        if ! read -r pick_input </dev/tty; then
            echo ""
            echo "Cancelled."
            return 0
        fi

        if [ -z "$pick_input" ]; then
            continue
        fi
        if [ "$pick_input" = "0" ] || [ "$pick_input" = "q" ] || [ "$pick_input" = "Q" ]; then
            echo "Cancelled."
            return 0
        fi

        if ! [[ "$pick_input" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid input. Enter a number from the list above, or 0 to cancel.${NC}"
            continue
        fi

        selected_idx=""
        for i in $(seq 0 $(( PICK_COUNT - 1 ))); do
            if [ "${PICK_NUMS[$i]}" = "$pick_input" ]; then
                selected_idx=$i
                break
            fi
        done

        if [ -z "$selected_idx" ]; then
            echo -e "${RED}Number $pick_input is not in the list. Try again or enter 0 to cancel.${NC}"
            continue
        fi

        selected_file="${PICK_FILES[$selected_idx]}"
        selected_goal="${PICK_GOALS[$selected_idx]}"
        selected_slug=$(task_file_stem "$selected_file")

        if _is_slug_running_v2 "$selected_slug" 2>/dev/null; then
            echo ""
            echo -e "${YELLOW}Warning: '${selected_slug}' is already running under V2.${NC}"
            printf "Continue anyway? (y/n): "
            if ! read -r confirm_running </dev/tty; then
                echo ""
                echo "Cancelled."
                return 0
            fi
            if [[ "$confirm_running" != "y" && "$confirm_running" != "Y" ]]; then
                continue
            fi
        fi

        echo ""
        echo -e "${GREEN}Selected: ${selected_slug}${NC} — ${selected_goal}"
        echo ""

        pick_auto_cmd=( "$0" auto "$selected_slug" "$selected_goal" )
        if [ -n "${MODEL:-}" ]; then
            pick_auto_cmd+=( --model "$MODEL" )
        fi
        if [ "$DRY_RUN" = true ]; then
            pick_auto_cmd+=( --dry-run )
        fi

        while true; do
            printf "Launch pipeline? (y/n) "
            if ! read -r pick_confirm </dev/tty; then
                echo ""
                echo "Cancelled."
                return 0
            fi

            case "$pick_confirm" in
                y|Y)
                    while true; do
                        printf "Route: (1) Auto-classify  (2) Simple (V1)  (3) Complex (V2) "
                        if ! read -r pick_route </dev/tty; then
                            echo ""
                            echo "Cancelled."
                            return 0
                        fi

                        case "$pick_route" in
                            1)
                                rm -f "$pick_temp_file"
                                exec "${pick_auto_cmd[@]}"
                                ;;
                            2)
                                rm -f "$pick_temp_file"
                                exec "${pick_auto_cmd[@]}" --simple
                                ;;
                            3)
                                rm -f "$pick_temp_file"
                                exec "${pick_auto_cmd[@]}" --thorough
                                ;;
                            0|n|N)
                                break
                                ;;
                            "")
                                echo -e "${RED}Enter 1, 2, or 3${NC}"
                                ;;
                            *)
                                echo -e "${RED}Enter 1, 2, or 3${NC}"
                                ;;
                        esac
                    done
                    ;;
                n|N)
                    echo ""
                    echo -e "${BLUE}To launch manually:${NC}"
                    echo "  ./lauren-loop.sh auto \"${selected_slug}\" \"${selected_goal}\""
                    return 0
                    ;;
                "")
                    echo -e "${RED}Enter y or n${NC}"
                    ;;
                *)
                    echo -e "${RED}Enter y or n${NC}"
                    ;;
            esac
        done
    done
}

parse_classification_from_file() {
    local output_file="$1"
    local classification
    classification=$(grep -m1 '^CLASSIFICATION[[:space:]]*:' "$output_file" | sed 's/^CLASSIFICATION[[:space:]]*:[[:space:]]*//' | awk '{print $1}' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$classification" in
        simple|complex)
            printf '%s\n' "$classification"
            return 0
            ;;
    esac
    return 1
}

write_task_complexity() {
    local task_file="$1"
    local classification="$2"

    if [ ! -f "$task_file" ]; then
        return 1
    fi

    if grep -q '^## Complexity:' "$task_file"; then
        _sed_i "s/^## Complexity: .*/## Complexity: $classification/" "$task_file"
    else
        _sed_i "/^## Status:/a\\
## Complexity: $classification" "$task_file"
    fi
}

extract_classifier_rationale() {
    local output_file="$1"
    awk '
        /^## Rationale$/ { capture=1; next }
        /^## / { if (capture) exit }
        capture { print }
    ' "$output_file" | sed '/^[[:space:]]*$/d' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

format_auto_duration() {
    local duration="$1"
    local hours minutes

    if [ "$duration" -lt 60 ]; then
        echo "<1m"
        return 0
    fi

    hours=$((duration / 3600))
    minutes=$(((duration % 3600) / 60))

    if [ "$hours" -gt 0 ]; then
        printf '%sh %sm\n' "$hours" "$minutes"
    else
        printf '%sm\n' "$minutes"
    fi
}

print_auto_summary() {
    local route="$1" reason="$2" duration="$3" cost="$4" exit_code="$5"
    local traditional_proxy="${6:-N/A}"
    local display_duration

    display_duration=$(format_auto_duration "$duration")

    echo ""
    echo -e "${BLUE}=============================================="
    echo "     Auto Route Summary"
    echo -e "==============================================${NC}"
    echo ""
    echo "  Pipeline: ${route}"
    echo "  Reason:   ${reason}"
    echo "  Duration: ${display_duration}"
    echo "  Cost:     ${cost}"
    echo "  Traditional Dev Proxy: ${traditional_proxy}"
    echo "  Exit:     ${exit_code}"
}

# ============================================================
# No-args default: show list
# ============================================================
if [ $# -eq 0 ]; then
    set -- list
fi

# ============================================================
# Subcommand: list — List open tasks and pick one to run
# ============================================================
if [ "${1:-}" = "list" ]; then
    shift

    LIST_STATUS_FILTER=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                echo "Usage: $0 list [--status <status>]"
                echo ""
                echo "List all open tasks and interactively pick one to launch."
                echo "Instant — no LLM calls required."
                echo ""
                echo "Options:"
                echo "  --status <status>   Filter by status (e.g. 'not started', 'in progress', 'blocked')"
                echo "  -h, --help          Show this help"
                exit 0
                ;;
            --status)
                if [ $# -lt 2 ]; then
                    echo -e "${RED}--status requires a value (e.g. --status 'not started')${NC}"
                    exit 1
                fi
                LIST_STATUS_FILTER="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option for 'list': $1${NC}"
                echo "Usage: $0 list [--status <status>]"
                exit 1
                ;;
        esac
    done

    _list_collect_tasks "$LIST_STATUS_FILTER"
    _list_display_and_select
    exit $?
fi

# ============================================================
# Subcommand: auto — Classify and route to V1 or V2
# ============================================================
if [ "${1:-}" = "auto" ]; then
    shift

    if [ $# -lt 2 ]; then
        echo -e "${RED}Usage: $0 auto <slug> \"<goal>\" [--simple|--thorough] [--dry-run] [--resume] [--model <model>] [--force] [--no-review] [--no-close]${NC}"
        exit 1
    fi

    SLUG="$1"
    GOAL="$2"
    shift 2

    AUTO_ROUTE=""
    AUTO_REASON=""
    AUTO_DURATION=0
    AUTO_COST="N/A"
    AUTO_SUMMARY_ROUTE=""
    AUTO_START_TS=$(date +%s)
    AUTO_FORCE=false
    AUTO_EXISTING_TASK=false
    AUTO_EXISTING_V2=false
    AUTO_CLASSIFICATION=""
    CLASSIFY_CAPTURE=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --simple)
                if [ "$AUTO_ROUTE" = "v2" ]; then
                    echo -e "${RED}Cannot combine --simple and --thorough${NC}"
                    exit 1
                fi
                AUTO_ROUTE="v1"
                AUTO_REASON="Simple (V1) — user selected"
                AUTO_CLASSIFICATION="simple"
                shift
                ;;
            --thorough)
                if [ "$AUTO_ROUTE" = "v1" ]; then
                    echo -e "${RED}Cannot combine --simple and --thorough${NC}"
                    exit 1
                fi
                AUTO_ROUTE="v2"
                AUTO_REASON="Complex (V2) — user selected"
                AUTO_CLASSIFICATION="complex"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --resume)
                RESUME=true
                shift
                ;;
            --model)
                MODEL="$2"
                shift 2
                ;;
            --force)
                AUTO_FORCE=true
                shift
                ;;
            --no-review)
                NO_REVIEW=true
                shift
                ;;
            --no-close)
                NO_CLOSE=true
                shift
                ;;
            *)
                echo -e "${RED}Unknown option for 'auto': $1${NC}"
                usage
                ;;
        esac
    done

    AUTO_RESOLVE_RC=0
    resolve_task_file "$SLUG" || AUTO_RESOLVE_RC=$?
    case "$AUTO_RESOLVE_RC" in
        0)
            AUTO_EXISTING_TASK=true
            if is_v2_task_file "$TASK_FILE"; then
                AUTO_EXISTING_V2=true
            fi
            ;;
        1) ;;
        2) exit 1 ;;
        *) exit "$AUTO_RESOLVE_RC" ;;
    esac

    if [ "$AUTO_EXISTING_V2" = true ]; then
        if [ "$AUTO_ROUTE" = "v1" ]; then
            echo -e "${RED}Slug '$SLUG' already has a V2 task directory; auto cannot route it to V1${NC}"
            exit 1
        fi
        if [ "$NO_REVIEW" = true ] || [ "$NO_CLOSE" = true ]; then
            echo -e "${RED}V2 routing does not support --no-review or --no-close via 'auto'${NC}"
            exit 1
        fi
        if [ "$RESUME" = true ]; then
            echo -e "${BLUE}V2 uses checkpoint-based resumption — --resume flag acknowledged${NC}"
        fi
        AUTO_ROUTE="v2"
        AUTO_REASON="Complex (V2) — existing V2 task"
        AUTO_CLASSIFICATION="complex"
    fi

    if [ "$AUTO_ROUTE" = "v2" ] && { [ "$NO_REVIEW" = true ] || [ "$NO_CLOSE" = true ]; }; then
        echo -e "${RED}V2 routing does not support --no-review or --no-close via 'auto'${NC}"
        exit 1
    fi
    if [ "$AUTO_ROUTE" = "v2" ] && [ "$RESUME" = true ]; then
        echo -e "${BLUE}V2 uses checkpoint-based resumption — --resume flag acknowledged${NC}"
    fi

    if [ -z "$AUTO_ROUTE" ] && { [ "$NO_REVIEW" = true ] || [ "$NO_CLOSE" = true ]; }; then
        AUTO_ROUTE="v1"
        AUTO_REASON="Simple (V1) — V1-only flags (--no-review/--no-close)"
    fi

    if [ -z "$AUTO_ROUTE" ]; then
        CLASSIFY_CAPTURE=$(mktemp)
        set +e
        if [ "$AUTO_EXISTING_TASK" = true ]; then
            "$0" classify "$SLUG" --model "$MODEL" | tee "$CLASSIFY_CAPTURE"
        else
            "$0" classify "$SLUG" --goal "$GOAL" --model "$MODEL" | tee "$CLASSIFY_CAPTURE"
        fi
        CLASSIFY_EXIT=${PIPESTATUS[0]}
        set -e
        if [ "$CLASSIFY_EXIT" -ne 0 ]; then
            rm -f "$CLASSIFY_CAPTURE"
            exit "$CLASSIFY_EXIT"
        fi

        if ! AUTO_CLASSIFICATION=$(parse_classification_from_file "$CLASSIFY_CAPTURE"); then
            echo -e "${RED}Auto-routing parse error: classifier did not emit simple|complex${NC}"
            rm -f "$CLASSIFY_CAPTURE"
            exit 1
        fi
        case "$AUTO_CLASSIFICATION" in
            simple) AUTO_ROUTE="v1" ;;
            complex) AUTO_ROUTE="v2" ;;
        esac

        AUTO_REASON=$(extract_classifier_rationale "$CLASSIFY_CAPTURE")
        if [ -z "$AUTO_REASON" ]; then
            if [ "$AUTO_CLASSIFICATION" = "simple" ]; then
                AUTO_REASON="Simple (V1) — classifier scored 0-1 HIGH dimensions"
            else
                AUTO_REASON="Complex (V2) — classifier scored 2+ HIGH dimensions"
            fi
        fi
        rm -f "$CLASSIFY_CAPTURE"
    fi

    if [ "$AUTO_ROUTE" = "v1" ] && [ "$AUTO_FORCE" = true ]; then
        echo -e "${RED}V1 routing does not support --force via 'auto'${NC}"
        exit 1
    fi

    AUTO_PRE_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

    set +e
    if [ "$AUTO_ROUTE" = "v1" ]; then
        AUTO_SUMMARY_ROUTE="V1"
        AUTO_CMD=( "$0" "$SLUG" "$GOAL" )
        if [ "$DRY_RUN" = true ]; then
            AUTO_CMD+=( --dry-run )
        fi
        if [ "$RESUME" = true ]; then
            AUTO_CMD+=( --resume )
        fi
        AUTO_CMD+=( --model "$MODEL" )
        # Routed V1 auto stops after execution handoff for human verification.
        AUTO_CMD+=( --no-review --no-close )
        "${AUTO_CMD[@]}"
        AUTO_CHILD_EXIT=$?
        AUTO_COST=$(read_v1_total_cost "$SLUG")
    else
        AUTO_SUMMARY_ROUTE="V2"
        AUTO_CMD=( "$SCRIPT_DIR/lauren-loop-v2.sh" "$SLUG" "$GOAL" )
        if [ "$DRY_RUN" = true ]; then
            AUTO_CMD+=( --dry-run )
        fi
        AUTO_CMD+=( --model "$MODEL" )
        if [ "$AUTO_FORCE" = true ]; then
            AUTO_CMD+=( --force )
        fi
        "${AUTO_CMD[@]}"
        AUTO_CHILD_EXIT=$?
        AUTO_COST=$(read_v2_total_cost "$SLUG")
    fi
    set -e

    if [ -n "$AUTO_CLASSIFICATION" ]; then
        AUTO_RESOLVE_RC=0
        resolve_task_file "$SLUG" || AUTO_RESOLVE_RC=$?
        case "$AUTO_RESOLVE_RC" in
            0) write_task_complexity "$TASK_FILE" "$AUTO_CLASSIFICATION" || true ;;
            1) ;;
            2) exit 1 ;;
            *) exit "$AUTO_RESOLVE_RC" ;;
        esac
    fi

    AUTO_PROXY_TASK_FILE=""
    AUTO_PROXY_RESOLVE_RC=0
    resolve_task_file "$SLUG" || AUTO_PROXY_RESOLVE_RC=$?
    case "$AUTO_PROXY_RESOLVE_RC" in
        0) AUTO_PROXY_TASK_FILE="$TASK_FILE" ;;
        1) ;;
        2) exit 1 ;;
        *) exit "$AUTO_PROXY_RESOLVE_RC" ;;
    esac

    AUTO_DURATION=$(( $(date +%s) - AUTO_START_TS ))
    if [ "$AUTO_DURATION" -lt 0 ]; then
        AUTO_DURATION=0
    fi
    AUTO_TRADITIONAL_PROXY=$(compute_cocomo_estimate "$AUTO_PRE_SHA" "$AUTO_PROXY_TASK_FILE" "$AUTO_SUMMARY_ROUTE")
    print_auto_summary "$AUTO_SUMMARY_ROUTE" "$AUTO_REASON" "$AUTO_DURATION" "$AUTO_COST" "$AUTO_CHILD_EXIT" "$AUTO_TRADITIONAL_PROXY"
    exit "$AUTO_CHILD_EXIT"
fi

# ============================================================
# Subcommand: next — Task prioritization
# ============================================================
if [ "${1:-}" = "next" ]; then
    shift

    # Parse flags for next subcommand
    while [ $# -gt 0 ]; do
        case "$1" in
            --model)
                MODEL="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option for 'next': $1${NC}"
                usage
                ;;
        esac
    done

    NEXT_TASK_PROMPT="$SCRIPT_DIR/prompts/next-task.md"

    if [ ! -f "$NEXT_TASK_PROMPT" ]; then
        echo -e "${RED}Next-task prompt not found: $NEXT_TASK_PROMPT${NC}"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    # Build enriched user prompt with git state and closed-task context
    gather_ranking_context

    echo -e "${BLUE}Analyzing open tasks (model: $MODEL)...${NC}"
    echo ""

    NEXT_TASK_CONTENT=$(cat "$NEXT_TASK_PROMPT")
    NEXT_TASK_CONTENT="${PROJECT_RULES}

${NEXT_TASK_CONTENT}"

    install -m 600 /dev/null "$NEXT_CACHE"
    SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$NEXT_TASK_USER_PROMPT" \
        --system-prompt "$NEXT_TASK_CONTENT" \
        --model "$MODEL" \
        --max-turns 15 \
        --dangerously-skip-permissions \
        --disallowedTools "Bash,WebFetch,WebSearch" \
        --output-format text | tee "$NEXT_CACHE"

    NEXT_EXIT=${PIPESTATUS[0]}
    if [[ "$NEXT_EXIT" -eq 124 ]]; then
        echo -e "${RED}Next-task agent timed out after $CRITIC_TIMEOUT${NC}"
        rm -f "$NEXT_CACHE"
        exit 124
    fi
    if [[ "$NEXT_EXIT" -ne 0 ]]; then
        rm -f "$NEXT_CACHE"
    fi
    exit $NEXT_EXIT
fi

# ============================================================
# Subcommand: pick — Interactive task selection from ranked list
# ============================================================
if [ "${1:-}" = "pick" ]; then
    shift

    FRESH=false

    # Parse flags for pick subcommand
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            --fresh) FRESH=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            *) echo -e "${RED}Unknown option for 'pick': $1${NC}"; usage ;;
        esac
    done

    NEXT_TASK_PROMPT="$SCRIPT_DIR/prompts/next-task.md"

    if [ ! -f "$NEXT_TASK_PROMPT" ]; then
        echo -e "${RED}Next-task prompt not found: $NEXT_TASK_PROMPT${NC}"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    PICK_TEMP=$(mktemp)
    trap 'rm -f "$PICK_TEMP"' EXIT

    # Check cache: use if fresh enough (10 min TTL) and --fresh not set
    CACHE_HIT=false
    if [ "$FRESH" = false ] && [ -f "$NEXT_CACHE" ]; then
        CACHE_MTIME=$(stat -f %m "$NEXT_CACHE" 2>/dev/null || stat -c %Y "$NEXT_CACHE" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        CACHE_AGE=$(( NOW - CACHE_MTIME ))
        if [ "$CACHE_AGE" -lt 600 ]; then
            CACHE_HIT=true
            CACHE_AGE_MIN=$(( CACHE_AGE / 60 ))
            echo -e "${BLUE}Using cached ranking (${CACHE_AGE_MIN}m ago). Use --fresh to re-rank.${NC}"
            cp "$NEXT_CACHE" "$PICK_TEMP"

            # Validate cached task paths still exist in open/
            CACHE_STALE=false
            CACHED_TASK_LINES=$(sed -n '/^## TASK_LIST/,$ { /^## TASK_LIST/d; p; }' "$PICK_TEMP" \
                | sed '/^[[:space:]]*$/d' \
                | grep -E '^[0-9]+\|.+\|.+\|.+$' || true)
            if [ -n "$CACHED_TASK_LINES" ]; then
                while IFS= read -r ctl; do
                    ctl_remainder="${ctl%|*}"       # drop complexity
                    ctl_remainder="${ctl_remainder#*|}"  # drop num
                    ctl_file="${ctl_remainder%%|*}"      # extract task path
                    ctl_file=$(echo "$ctl_file" | tr -d '[:space:]')
                    case "$ctl_file" in
                        docs/tasks/open/*)
                            ctl_path="$SCRIPT_DIR/$ctl_file"
                            ;;
                        *)
                            ctl_path="$SCRIPT_DIR/docs/tasks/open/$ctl_file"
                            ;;
                    esac
                    if [ ! -f "$ctl_path" ]; then
                        CACHE_STALE=true
                        break
                    fi
                done <<< "$CACHED_TASK_LINES"
            fi
            if [ "$CACHE_STALE" = true ]; then
                echo -e "${YELLOW}Cache invalidated — ranked tasks have been closed. Re-ranking...${NC}"
                CACHE_HIT=false
                rm -f "$NEXT_CACHE"
            fi
        fi
    fi

    if [ "$CACHE_HIT" = false ]; then
        # Build enriched user prompt and run LLM
        gather_ranking_context

        echo -e "${BLUE}Ranking open tasks (model: $MODEL)...${NC}"
        echo ""

        NEXT_TASK_CONTENT=$(cat "$NEXT_TASK_PROMPT")
        NEXT_TASK_CONTENT="${PROJECT_RULES}

${NEXT_TASK_CONTENT}"

        mkdir -p "$LOG_DIR"
        SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$NEXT_TASK_USER_PROMPT" \
            --system-prompt "$NEXT_TASK_CONTENT" \
            --model "$MODEL" \
            --max-turns 15 \
            --dangerously-skip-permissions \
            --disallowedTools "Bash,WebFetch,WebSearch" \
            --output-format text > "$PICK_TEMP" 2>"$LOG_DIR/pick-stderr.log"

        PICK_LLM_EXIT=$?
        if [[ "$PICK_LLM_EXIT" -eq 124 ]]; then
            echo -e "${RED}Ranking agent timed out after $CRITIC_TIMEOUT${NC}"
            rm -f "$PICK_TEMP"
            exit 124
        fi
        if [[ "$PICK_LLM_EXIT" -ne 0 ]]; then
            echo -e "${RED}Ranking agent failed (exit $PICK_LLM_EXIT)${NC}"
            cat "$PICK_TEMP"
            rm -f "$PICK_TEMP"
            exit "$PICK_LLM_EXIT"
        fi

        # Write to cache for future pick/next reuse
        install -m 600 /dev/null "$NEXT_CACHE"
        cp "$PICK_TEMP" "$NEXT_CACHE"
    fi

    # Display human-readable portion (everything before ## TASK_LIST)
    sed '/^## TASK_LIST/,$d' "$PICK_TEMP"
    echo ""

    if ! _pick_load_ranked_tasks "$PICK_TEMP"; then
        rm -f "$PICK_TEMP"
        exit 1
    fi

    _pick_interactive_select_task "$PICK_TEMP"

    rm -f "$PICK_TEMP"
    exit 0
fi

# ============================================================
# Subcommand: reset — Reset task status to last stable state
# ============================================================
if [ "${1:-}" = "reset" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 reset <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi

    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')

    # Determine last stable state
    if grep -q '^## Current Plan' "$TASK_FILE" && \
       grep -A 5 '^## Current Plan' "$TASK_FILE" | grep -qv '^## \|^$\|^(Planner writes here)'; then
        NEW_STATUS="plan-approved"
    else
        NEW_STATUS="not-started"
    fi

    if [ "$CURRENT_STATUS" = "$NEW_STATUS" ]; then
        echo -e "${GREEN}Status already '$NEW_STATUS' — nothing to reset${NC}"
        exit 0
    fi

    _sed_i "s/^## Status: .*/## Status: $NEW_STATUS/" "$TASK_FILE"
    log_execution "$TASK_FILE" "Reset status from '$CURRENT_STATUS' to '$NEW_STATUS'"

    echo -e "${GREEN}Reset: '$CURRENT_STATUS' → '$NEW_STATUS'${NC}"
    echo "  Task file: $TASK_FILE"
    exit 0
fi

# ============================================================
# Subcommand: execute — Run approved plan via TDD executor
# ============================================================
if [ "${1:-}" = "execute" ]; then
    shift

    # Require slug
    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 execute <slug> [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    # Parse optional flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            *) echo -e "${RED}Unknown option for 'execute': $1${NC}"; usage; ;;
        esac
    done

    V1_COST_CSV="$LOG_DIR/pilot-${SLUG}-cost.csv"
    EXECUTOR_PROMPT="$SCRIPT_DIR/prompts/executor.md"

    # Verify prerequisites
    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi
    if is_v2_task_file "$TASK_FILE"; then
        echo -e "${YELLOW}Task '${SLUG}' is a V2 task. V2 diffs and reviews live in:${NC}"
        echo "  docs/tasks/open/${SLUG}/competitive/"
        echo -e "Use: ${BLUE}./lauren-loop-v2.sh ${SLUG}${NC}"
        exit 1
    fi
    if [ ! -f "$EXECUTOR_PROMPT" ]; then
        echo -e "${RED}Executor prompt not found: $EXECUTOR_PROMPT${NC}"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    # Verify status
    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    if [ "$CURRENT_STATUS" = "needs verification" ]; then
        echo -e "${GREEN}Task already executed and awaiting verification. Run: ./lauren-loop.sh review ${SLUG} or ./lauren-loop.sh verify ${SLUG}${NC}"
        log_execution "$TASK_FILE" "Execute skipped — task already awaiting verification"
        exit 0
    fi
    if [ "$CURRENT_STATUS" = "executed" ]; then
        echo -e "${GREEN}Task already executed by Lead agent. Run: ./lauren-loop.sh review ${SLUG}${NC}"
        log_execution "$TASK_FILE" "Execute skipped — task already executed by Lead agent"
        exit 0
    fi
    if [ "$CURRENT_STATUS" != "plan-approved" ] && [ "$CURRENT_STATUS" != "executing" ]; then
        echo -e "${RED}Task status is '$CURRENT_STATUS', expected 'plan-approved' or 'executing'${NC}"
        echo "Only plan-approved or executing (stuck) tasks can be executed."
        exit 1
    fi

    acquire_lock

    # Tag current git SHA for diff later
    PRE_EXEC_SHA=$(git rev-parse HEAD)
    echo -e "${BLUE}Pre-execution SHA: $PRE_EXEC_SHA${NC}"

    # Update status to executing (skip if already in that state)
    if [ "$CURRENT_STATUS" != "executing" ]; then
        _sed_i 's/^## Status: .*/## Status: executing/' "$TASK_FILE"
    fi
    log_execution "$TASK_FILE" "Executor started (model: $MODEL, pre-SHA: $PRE_EXEC_SHA)"

    # Prepare log
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/pilot-${SLUG}-executor.log"

    # Build task instruction
    TASK_INSTRUCTION="Read the task file at ${TASK_FILE}. Execute the implementation plan in ## Current Plan using TDD vertical slices. Log every RED-GREEN cycle to ## Execution Log."

    # Inject placeholders into prompt
    PROMPT_CONTENT=$(cat "$EXECUTOR_PROMPT")
    PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$PROJECT_NAME|$PROJECT_NAME|g")
    PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$TEST_CMD|$TEST_CMD|g")
    PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$LINT_CMD|$LINT_CMD|g")
    PROMPT_CONTENT="${PROJECT_RULES}

${PROMPT_CONTENT}"

    echo -e "${BLUE}Running executor (max-turns 200)...${NC}"

    # Run executor agent
    # Key differences from planner/critic:
    #   - max-turns 200 (TDD cycles need room)
    #   - Bash is ALLOWED (executor runs tests)
    #   - Only WebFetch,WebSearch are disallowed
    PHASE="execute"
    START_LINE=$(prepare_attempt_log "$LOG_FILE" "execute" "na")
    EXIT_CODE=0
    _COST_START=$(date +%s)
    SKIP_SUMMARY_HOOK=1 _timeout "$EXECUTOR_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$TASK_INSTRUCTION" \
        --system-prompt "$PROMPT_CONTENT" \
        --model "$MODEL" \
        --max-turns 200 \
        --dangerously-skip-permissions \
        --disallowedTools "WebFetch,WebSearch" \
        --verbose --output-format stream-json \
        >> "$LOG_FILE" 2>&1 || EXIT_CODE=$?
    _append_cost_row "$V1_COST_CSV" "executor" "claude" "$_COST_START" "$EXIT_CODE" "$LOG_FILE"

    if [[ "$EXIT_CODE" -eq 124 ]]; then
        echo -e "${RED}Executor timed out after $EXECUTOR_TIMEOUT${NC}"
        log_execution "$TASK_FILE" "Executor timed out after $EXECUTOR_TIMEOUT"
        _sed_i 's/^## Status: .*/## Status: timed-out/' "$TASK_FILE"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Executor exited with code $EXIT_CODE${NC}"
        if [ "$EXIT_CODE" -eq 130 ] || [ "$EXIT_CODE" -eq 143 ]; then
            log_execution "$TASK_FILE" "Executor ended by signal (exit code: $EXIT_CODE)"
        else
            log_execution "$TASK_FILE" "Executor failed (exit code: $EXIT_CODE)"
        fi
        _sed_i 's/^## Status: .*/## Status: execution-failed/' "$TASK_FILE"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    # Check for max-turns exhaustion (agent ran out of turns without completing)
    if attempt_log_contains_max_turns "$LOG_FILE" "$START_LINE"; then
        echo -e "${RED}Executor exhausted max turns without completing${NC}"
        log_execution "$TASK_FILE" "Executor failed: reached max turns"
        _sed_i 's/^## Status: .*/## Status: execution-failed/' "$TASK_FILE"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    # Check for BLOCKED in execution log (scoped to log entries, not plan text)
    if grep -q '^\- \[.*\] BLOCKED:' "$TASK_FILE"; then
        echo -e "${YELLOW}Executor reported BLOCKED${NC}"
        BLOCKED_REASON=$(grep '^\- \[.*\] BLOCKED:' "$TASK_FILE" | tail -1)
        log_execution "$TASK_FILE" "Executor BLOCKED: $BLOCKED_REASON"
        _sed_i 's/^## Status: .*/## Status: execution-blocked/' "$TASK_FILE"
        echo "  Reason: $BLOCKED_REASON"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    # Successful execution hands off to human verification unless scope review is needed.
    FINAL_STATUS="needs verification"
    _sed_i 's/^## Status: .*/## Status: needs verification/' "$TASK_FILE"
    log_execution "$TASK_FILE" "Executor completed successfully"

    # Scope check: verify changed files match plan
    if ! check_diff_scope "$TASK_FILE" "$PRE_EXEC_SHA"; then
        echo -e "${YELLOW}Setting status to needs-human-review due to scope violation${NC}"
        _sed_i 's/^## Status: .*/## Status: needs-human-review/' "$TASK_FILE"
        log_execution "$TASK_FILE" "Scope check failed: changed files don't match plan"
        FINAL_STATUS="needs-human-review"
    fi

    # Capture git diff from pre-execution SHA
    DIFF_FILE="$LOG_DIR/pilot-${SLUG}-diff.patch"
    git diff "$PRE_EXEC_SHA"..HEAD > "$DIFF_FILE" 2>/dev/null || true

    if [ -s "$DIFF_FILE" ]; then
        DIFF_LINES=$(wc -l < "$DIFF_FILE" | tr -d ' ')
        echo -e "${GREEN}Diff captured: $DIFF_FILE ($DIFF_LINES lines)${NC}"
    else
        echo -e "${YELLOW}No diff — executor may not have committed changes${NC}"
        # Also capture uncommitted changes
        git diff > "$DIFF_FILE" 2>/dev/null || true
        git diff --cached >> "$DIFF_FILE" 2>/dev/null || true
    fi

    if [ "$FINAL_STATUS" = "needs verification" ]; then
        EXEC_TEST_SIGNAL=$(latest_execution_test_signal "$TASK_FILE")
        REL_LOG_FILE="${LOG_FILE#"$SCRIPT_DIR"/}"
        REL_DIFF_FILE="${DIFF_FILE#"$SCRIPT_DIR"/}"
        LEFT_OFF_SUMMARY="Automated V1 execution completed. Latest execution evidence: ${EXEC_TEST_SIGNAL:-Executor completed successfully}. Artifacts: ${REL_DIFF_FILE}, ${REL_LOG_FILE}. Task is ready for human verification."
        ATTEMPT_ENTRY="- $(date '+%Y-%m-%d'): Executed approved V1 plan via executor. Latest execution evidence: ${EXEC_TEST_SIGNAL:-Executor completed successfully}. Artifacts: ${REL_DIFF_FILE}, ${REL_LOG_FILE}. -> Result: worked"
        finalize_v1_verification_handoff "$TASK_FILE" "$LEFT_OFF_SUMMARY" "$ATTEMPT_ENTRY"
        log_execution "$TASK_FILE" "Executor handoff complete: awaiting human verification"
    fi

    echo ""
    echo -e "${GREEN}Execution complete${NC}"
    echo "  Task file: $TASK_FILE"
    echo "  Status: $FINAL_STATUS"
    echo "  Log: $LOG_FILE"
    echo "  Diff: $DIFF_FILE"
    echo ""
    if [ "$FINAL_STATUS" = "needs verification" ]; then
        echo "Next: Review or verify the task, then close it after human verification."
    else
        echo "Next: Review the diff and execution log, then run the critic or merge."
    fi

    exit 0
fi

# ============================================================
# Subcommand: classify — Classify task complexity as simple or complex
# ============================================================
if [ "${1:-}" = "classify" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 classify <slug> [--goal \"<goal>\"] [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    CLASSIFY_GOAL=""
    shift

    # Parse optional flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --goal) CLASSIFY_GOAL="$2"; shift 2 ;;
            --model) MODEL="$2"; shift 2 ;;
            *) echo -e "${RED}Unknown option for 'classify': $1${NC}"; usage ;;
        esac
    done

    CLASSIFIER_PROMPT="$SCRIPT_DIR/prompts/classifier.md"

    if [ ! -f "$CLASSIFIER_PROMPT" ]; then
        echo -e "${RED}Classifier prompt not found: $CLASSIFIER_PROMPT${NC}"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    CLASSIFY_HAS_TASK=true
    CLASSIFY_RESOLVE_RC=0
    resolve_task_file "$SLUG" || CLASSIFY_RESOLVE_RC=$?
    case "$CLASSIFY_RESOLVE_RC" in
        0) ;;
        1) CLASSIFY_HAS_TASK=false ;;
        2) exit 1 ;;
        *) exit "$CLASSIFY_RESOLVE_RC" ;;
    esac
    if [ "$CLASSIFY_HAS_TASK" != true ] && [ -z "$CLASSIFY_GOAL" ]; then
        echo -e "${RED}Task file not found for slug: $SLUG (provide --goal to classify a new task)${NC}"
        exit 1
    fi

    echo -e "${BLUE}Classifying task complexity (model: $MODEL)...${NC}"
    if [ "$CLASSIFY_HAS_TASK" = true ]; then
        echo "  Task file: $TASK_FILE"
    else
        echo "  Goal-only mode: $CLASSIFY_GOAL"
    fi

    # Build instruction for the LLM
    if [ "$CLASSIFY_HAS_TASK" = true ]; then
        CLASSIFY_INSTRUCTION="Read the task file at: $TASK_FILE"
    else
        CLASSIFY_INSTRUCTION="No existing task file exists for slug '$SLUG'.

Classify this task from the goal only.

Goal: $CLASSIFY_GOAL"
    fi

    # Check for V2 exploration summary
    EXPLORATION_SUMMARY="$SCRIPT_DIR/docs/tasks/open/${SLUG}/competitive/exploration-summary.md"
    if [ -f "$EXPLORATION_SUMMARY" ]; then
        CLASSIFY_INSTRUCTION="$CLASSIFY_INSTRUCTION

Also read the exploration summary at: $EXPLORATION_SUMMARY"
        echo "  Exploration summary: $EXPLORATION_SUMMARY"
    fi

    CLASSIFY_INSTRUCTION="$CLASSIFY_INSTRUCTION

Then classify this task as simple or complex per the scoring dimensions in your system prompt."

    # Load prompt content with project rules prepended
    CLASSIFIER_CONTENT=$(cat "$CLASSIFIER_PROMPT")
    CLASSIFIER_CONTENT="${PROJECT_RULES}

${CLASSIFIER_CONTENT}"

    echo ""

    # Run LLM call (follows next subcommand pattern)
    CLASSIFY_OUTPUT_FILE=$(mktemp)
    SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$CLASSIFY_INSTRUCTION" \
        --system-prompt "$CLASSIFIER_CONTENT" \
        --model "$MODEL" \
        --max-turns 15 \
        --dangerously-skip-permissions \
        --disallowedTools "Bash,WebFetch,WebSearch,Edit,Write,NotebookEdit" \
        --output-format text > "$CLASSIFY_OUTPUT_FILE" 2>&1

    CLASSIFY_EXIT=$?
    if [[ "$CLASSIFY_EXIT" -eq 124 ]]; then
        echo -e "${RED}Classifier agent timed out after $CRITIC_TIMEOUT${NC}"
        rm -f "$CLASSIFY_OUTPUT_FILE"
        exit 124
    fi
    if [[ "$CLASSIFY_EXIT" -ne 0 ]]; then
        echo -e "${RED}Classifier agent failed (exit $CLASSIFY_EXIT)${NC}"
        cat "$CLASSIFY_OUTPUT_FILE"
        rm -f "$CLASSIFY_OUTPUT_FILE"
        exit "$CLASSIFY_EXIT"
    fi

    # Display full output
    cat "$CLASSIFY_OUTPUT_FILE"
    echo ""

    # Parse CLASSIFICATION line
    if ! CLASSIFICATION=$(parse_classification_from_file "$CLASSIFY_OUTPUT_FILE"); then
        echo -e "${RED}Parse error: could not extract valid CLASSIFICATION (simple|complex) from output${NC}"
        echo "  Full output saved at: $CLASSIFY_OUTPUT_FILE"
        exit 1
    fi

    if [ "$CLASSIFY_HAS_TASK" = true ]; then
        write_task_complexity "$TASK_FILE" "$CLASSIFICATION"
        log_execution "$TASK_FILE" "Classified as: $CLASSIFICATION"
    fi
    rm -f "$CLASSIFY_OUTPUT_FILE"

    echo -e "${GREEN}Classification: $CLASSIFICATION${NC}"
    if [ "$CLASSIFY_HAS_TASK" = true ]; then
        echo "  Written to: $TASK_FILE"
    else
        echo "  No task file updated"
    fi
    exit 0
fi

# ============================================================
# Subcommand: review — Review executed diff via reviewer + critic loop
# ============================================================
if [ "${1:-}" = "review" ]; then
    shift

    # Require slug
    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 review <slug> [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    # Parse optional flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            --internal) INTERNAL=true; shift ;;
            *) echo -e "${RED}Unknown option for 'review': $1${NC}"; usage ;;
        esac
    done

    V1_COST_CSV="$LOG_DIR/pilot-${SLUG}-cost.csv"
    REVIEWER_PROMPT="$SCRIPT_DIR/prompts/reviewer.md"
    REVIEW_CRITIC_PROMPT="$SCRIPT_DIR/prompts/review-critic.md"

    # Define diff paths (existence checked after V2 guard below)
    FIX_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-fix-diff.patch"
    EXEC_DIFF_FILE="$LOG_DIR/pilot-${SLUG}-diff.patch"

    # Verify prerequisites
    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi
    if is_v2_task_file "$TASK_FILE"; then
        echo -e "${YELLOW}Task '${SLUG}' is a V2 task. V2 diffs and reviews live in:${NC}"
        echo "  docs/tasks/open/${SLUG}/competitive/"
        echo -e "Use: ${BLUE}./lauren-loop-v2.sh ${SLUG}${NC}"
        exit 1
    fi
    if [ ! -f "$REVIEWER_PROMPT" ]; then
        echo -e "${RED}Reviewer prompt not found: $REVIEWER_PROMPT${NC}"
        exit 1
    fi
    if [ ! -f "$REVIEW_CRITIC_PROMPT" ]; then
        echo -e "${RED}Review critic prompt not found: $REVIEW_CRITIC_PROMPT${NC}"
        exit 1
    fi
    # Prefer fix diff over execution diff
    if [ -f "$FIX_DIFF_FILE" ]; then
        DIFF_FILE="$FIX_DIFF_FILE"
        REVIEW_CONTEXT="post-fix"
    elif [ -f "$EXEC_DIFF_FILE" ]; then
        DIFF_FILE="$EXEC_DIFF_FILE"
        REVIEW_CONTEXT="execution"
    else
        echo -e "${RED}No diff file found${NC}"
        echo "Expected fix diff at: $FIX_DIFF_FILE"
        echo "  or execution diff at: $EXEC_DIFF_FILE"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    # Status gate: only executed, verification-ready, fixed, or reviewing tasks can be reviewed
    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    if [ "$CURRENT_STATUS" != "executed" ] && [ "$CURRENT_STATUS" != "needs verification" ] && [ "$CURRENT_STATUS" != "fixed" ] && [ "$CURRENT_STATUS" != "reviewing" ]; then
        echo -e "${RED}Task status is '$CURRENT_STATUS', expected 'executed', 'needs verification', 'fixed', or 'reviewing'${NC}"
        echo "Only executed, needs verification, fixed, or reviewing (stuck) tasks can be reviewed."
        exit 1
    fi

    acquire_lock

    ensure_review_sections "$TASK_FILE"
    if section_has_nonblank_content "$TASK_FILE" "## Review Findings" || \
       section_has_nonblank_content "$TASK_FILE" "## Review Critique"; then
        archive_review_cycle "$TASK_FILE"
        log_execution "$TASK_FILE" "Archived previous review cycle to Review History"
    fi

    # Set status to reviewing (skip if already in that state)
    if [ "$CURRENT_STATUS" != "reviewing" ]; then
        _sed_i 's/^## Status: .*/## Status: reviewing/' "$TASK_FILE"
    fi
    log_execution "$TASK_FILE" "Review started (model: $MODEL)"

    mkdir -p "$LOG_DIR"

    # Reviewer-Critic loop (max 2 rounds)
    MAX_REVIEW_ROUNDS=2
    ROUND=1
    REVIEW_VERDICT=""

    while [ "$ROUND" -le "$MAX_REVIEW_ROUNDS" ]; do
        echo -e "${BLUE}━━━ Review Round $ROUND of $MAX_REVIEW_ROUNDS ━━━${NC}"

        # --- Session 1: Reviewer ---
        BACKUP="$LOG_DIR/$(basename "$TASK_FILE").bak"
        cp "$TASK_FILE" "$BACKUP"

        REVIEWER_LOG="$LOG_DIR/pilot-${SLUG}-reviewer-r${ROUND}.log"
        if [ "$REVIEW_CONTEXT" = "post-fix" ] && [ -f "$EXEC_DIFF_FILE" ]; then
            REVIEWER_INSTRUCTION="Read the task file at ${TASK_FILE}. Read the original execution diff at ${EXEC_DIFF_FILE} and the fix diff at ${DIFF_FILE}. Review all changed files and write findings to ## Review Findings. This is review round ${ROUND}. Focus on the fix diff — the execution diff provides baseline context."
        else
            REVIEWER_INSTRUCTION="Read the task file at ${TASK_FILE}. Read the diff at ${DIFF_FILE}. Review all changed files and write findings to ## Review Findings. This is review round ${ROUND}."
        fi

        # Inject $PROJECT_NAME into reviewer prompt
        PROMPT_CONTENT=$(cat "$REVIEWER_PROMPT")
        PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$PROJECT_NAME|$PROJECT_NAME|g")
        PROMPT_CONTENT="${PROJECT_RULES}

${PROMPT_CONTENT}"

        PHASE="reviewer"
        REVIEWER_START_LINE=$(prepare_attempt_log "$REVIEWER_LOG" "reviewer" "$ROUND")
        EXIT_CODE=0
        _COST_START=$(date +%s)
        SKIP_SUMMARY_HOOK=1 _timeout "$REVIEWER_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$REVIEWER_INSTRUCTION" \
            --system-prompt "$PROMPT_CONTENT" \
            --model "$MODEL" \
            --max-turns 200 \
            --dangerously-skip-permissions \
            --disallowedTools "WebFetch,WebSearch" \
            --verbose --output-format stream-json \
            >> "$REVIEWER_LOG" 2>&1 || EXIT_CODE=$?
        _append_cost_row "$V1_COST_CSV" "reviewer-r${ROUND}" "claude" "$_COST_START" "$EXIT_CODE" "$REVIEWER_LOG"

        if [[ "$EXIT_CODE" -eq 124 ]]; then
            cp "$BACKUP" "$TASK_FILE"
            log_execution "$TASK_FILE" "Reviewer timed out after $REVIEWER_TIMEOUT"
            _sed_i 's/^## Status: .*/## Status: timed-out/' "$TASK_FILE"
            echo -e "${RED}Reviewer timed out after $REVIEWER_TIMEOUT${NC}"
            echo "  Log: $REVIEWER_LOG"
            exit 1
        fi

        if [ $EXIT_CODE -ne 0 ]; then
            cp "$BACKUP" "$TASK_FILE"
            if [ "$EXIT_CODE" -eq 130 ] || [ "$EXIT_CODE" -eq 143 ]; then
                log_execution "$TASK_FILE" "Reviewer ended by signal (exit code: $EXIT_CODE)"
            else
                log_execution "$TASK_FILE" "Reviewer failed (exit code: $EXIT_CODE)"
            fi
            _sed_i 's/^## Status: .*/## Status: review-failed/' "$TASK_FILE"
            echo -e "${RED}Reviewer exited with code $EXIT_CODE${NC}"
            echo "  Log: $REVIEWER_LOG"
            exit 1
        fi

        # Check for max-turns exhaustion
        if attempt_log_contains_max_turns "$REVIEWER_LOG" "$REVIEWER_START_LINE"; then
            echo -e "${RED}Reviewer exhausted max turns without completing${NC}"
            cp "$BACKUP" "$TASK_FILE"
            log_execution "$TASK_FILE" "Reviewer failed: reached max turns"
            _sed_i 's/^## Status: .*/## Status: review-failed/' "$TASK_FILE"
            echo "  Log: $REVIEWER_LOG"
            exit 1
        fi

        rm -f "$BACKUP"
        log_execution "$TASK_FILE" "Review round $ROUND: Reviewer completed"

        # --- Session 2: Review Critic ---
        BACKUP="$LOG_DIR/$(basename "$TASK_FILE").bak"
        cp "$TASK_FILE" "$BACKUP"

        CRITIC_LOG="$LOG_DIR/pilot-${SLUG}-review-critic-r${ROUND}.log"
        CRITIC_INSTRUCTION="Read the task file at ${TASK_FILE}. Evaluate the review in ## Review Findings and write your critique to ## Review Critique. This is round ${ROUND}."

        CRITIC_CONTENT=$(cat "$REVIEW_CRITIC_PROMPT")
        CRITIC_CONTENT=$(echo "$CRITIC_CONTENT" | sed "s|\$PROJECT_NAME|$PROJECT_NAME|g")
        CRITIC_CONTENT="${PROJECT_RULES}

${CRITIC_CONTENT}"

        PHASE="review-critic"
        CRITIC_START_LINE=$(prepare_attempt_log "$CRITIC_LOG" "review-critic" "$ROUND")
        EXIT_CODE=0
        _COST_START=$(date +%s)
        SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$CRITIC_INSTRUCTION" \
            --system-prompt "$CRITIC_CONTENT" \
            --model "$MODEL" \
            --max-turns 200 \
            --dangerously-skip-permissions \
            --disallowedTools "Bash,WebFetch,WebSearch" \
            --verbose --output-format stream-json \
            >> "$CRITIC_LOG" 2>&1 || EXIT_CODE=$?
        _append_cost_row "$V1_COST_CSV" "review-critic-r${ROUND}" "claude" "$_COST_START" "$EXIT_CODE" "$CRITIC_LOG"

        if [[ "$EXIT_CODE" -eq 124 ]]; then
            cp "$BACKUP" "$TASK_FILE"
            log_execution "$TASK_FILE" "Review critic timed out after $CRITIC_TIMEOUT"
            _sed_i 's/^## Status: .*/## Status: timed-out/' "$TASK_FILE"
            echo -e "${RED}Review critic timed out after $CRITIC_TIMEOUT${NC}"
            echo "  Log: $CRITIC_LOG"
            exit 1
        fi

        if [ $EXIT_CODE -ne 0 ]; then
            cp "$BACKUP" "$TASK_FILE"
            if [ "$EXIT_CODE" -eq 130 ] || [ "$EXIT_CODE" -eq 143 ]; then
                log_execution "$TASK_FILE" "Review critic ended by signal (exit code: $EXIT_CODE)"
            else
                log_execution "$TASK_FILE" "Review critic failed (exit code: $EXIT_CODE)"
            fi
            _sed_i 's/^## Status: .*/## Status: review-failed/' "$TASK_FILE"
            echo -e "${RED}Review critic exited with code $EXIT_CODE${NC}"
            echo "  Log: $CRITIC_LOG"
            exit 1
        fi

        # Check for max-turns exhaustion
        if attempt_log_contains_max_turns "$CRITIC_LOG" "$CRITIC_START_LINE"; then
            echo -e "${RED}Review critic exhausted max turns without completing${NC}"
            cp "$BACKUP" "$TASK_FILE"
            log_execution "$TASK_FILE" "Review critic failed: reached max turns"
            _sed_i 's/^## Status: .*/## Status: review-failed/' "$TASK_FILE"
            echo "  Log: $CRITIC_LOG"
            exit 1
        fi

        rm -f "$BACKUP"

        # Extract critic verdict
        CRITIC_VERDICT=$(extract_last_critic_verdict "$TASK_FILE")

        if [ -z "$CRITIC_VERDICT" ]; then
            log_execution "$TASK_FILE" "Review round $ROUND: Could not extract critic verdict"
            REVIEW_VERDICT="error"
            break
        fi

        CRITIC_VERDICT_UPPER=$(echo "$CRITIC_VERDICT" | tr '[:lower:]' '[:upper:]')
        log_execution "$TASK_FILE" "Review round $ROUND: Critic $CRITIC_VERDICT_UPPER"

        if [ "$CRITIC_VERDICT_UPPER" = "PASS" ]; then
            # Critic passed — now check the REVIEW verdict from ## Review Findings
            REVIEW_VERDICT_RAW=$(extract_last_review_verdict "$TASK_FILE")
            REVIEW_VERDICT=$(echo "$REVIEW_VERDICT_RAW" | tr '[:lower:]' '[:upper:]')
            break
        else
            # Critic failed — loop (reviewer must re-review)
            REVIEW_VERDICT="critic-fail"
            ROUND=$((ROUND + 1))
        fi
    done

    # Final status based on REVIEW_VERDICT
    case "$REVIEW_VERDICT" in
        PASS)
            _sed_i 's/^## Status: .*/## Status: review-passed/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Review complete: PASS"
            echo -e "${GREEN}Review PASSED${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: review-passed"
            echo ""
            echo "Next: ./lauren-loop.sh close ${SLUG}"
            ;;
        CONDITIONAL)
            _sed_i 's/^## Status: .*/## Status: review-findings-pending/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Review complete: CONDITIONAL (follow-up findings pending fix)"
            echo -e "${YELLOW}Review is conditional — follow-up findings pending fix${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: review-findings-pending"
            echo ""
            echo "Next: ./lauren-loop.sh fix ${SLUG}"
            ;;
        FAIL)
            _sed_i 's/^## Status: .*/## Status: review-findings-pending/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Review complete: FAIL (findings pending fix)"
            echo -e "${YELLOW}Review found issues — findings pending fix${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: review-findings-pending"
            echo ""
            echo "Next: ./lauren-loop.sh fix ${SLUG}"
            ;;
        *)
            # critic-fail after max rounds or error
            _sed_i 's/^## Status: .*/## Status: review-findings-pending/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Review complete: reviewer could not satisfy critic in $MAX_REVIEW_ROUNDS rounds"
            echo -e "${YELLOW}Reviewer could not satisfy critic — treating as findings pending${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: review-findings-pending"
            echo ""
            echo "Next: ./lauren-loop.sh fix ${SLUG}"
            ;;
    esac

    echo ""
    echo "Logs: $LOG_DIR/pilot-${SLUG}-reviewer-*.log, $LOG_DIR/pilot-${SLUG}-review-critic-*.log"
    exit 0
fi

# ============================================================
# Subcommand: close — Move review-passed task(s) to closed/
# ============================================================
if [ "${1:-}" = "close" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 close <slug> [--force]${NC}"
        exit 1
    fi

    FORCE_CLOSE=false
    SLUG="$1"
    shift

    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE_CLOSE=true; shift ;;
            *) echo -e "${RED}Unknown option for 'close': $1${NC}"; usage ;;
        esac
    done

    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi

    if [ "${_LAUREN_LOOP_INTERNAL:-}" = "1" ]; then
        INTERNAL=true
    fi

    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    if [ "$FORCE_CLOSE" != true ] && [ "$CURRENT_STATUS" != "review-passed" ]; then
        echo -e "${RED}Task status is '$CURRENT_STATUS', expected 'review-passed'${NC}"
        echo "Use --force to close a stuck task."
        exit 1
    fi

    acquire_lock
    ensure_review_sections "$TASK_FILE"

    if [ "$FORCE_CLOSE" = true ] && [ "$CURRENT_STATUS" != "review-passed" ]; then
        log_execution "$TASK_FILE" "Force close requested from status: $CURRENT_STATUS"
    fi

    PRIMARY_STEM=$(task_file_stem "$TASK_FILE")
    SUPERSEDED_TASKS=$(list_superseded_tasks "$TASK_FILE" "$TASK_FILE")
    MOVED_TASKS=()
    RETRO_WARNINGS=()
    mkdir -p "$LOG_DIR"

    PRIMARY_CLOSED_PATH=$(move_task_to_closed "$TASK_FILE" "closed" "Task closed") || {
        echo -e "${RED}Failed to move primary task to closed${NC}" >&2
        exit 1
    }
    MOVED_TASKS+=("$PRIMARY_CLOSED_PATH")

    # Invalidate pick cache — closed task would make it stale
    rm -f "$NEXT_CACHE"

    while IFS= read -r superseded_task; do
        [ -z "$superseded_task" ] && continue
        SUPERSEDED_CLOSED_PATH=$(move_task_to_closed "$superseded_task" "closed" "Closed as superseded by $PRIMARY_STEM") || {
            echo -e "${YELLOW}WARNING: Failed to move superseded task to closed: $(basename "$superseded_task")${NC}" >&2
            continue
        }
        MOVED_TASKS+=("$SUPERSEDED_CLOSED_PATH")
    done <<< "$SUPERSEDED_TASKS"

    for moved_task in "${MOVED_TASKS[@]}"; do
        task_stem=$(task_file_stem "$moved_task")
        retro_state=0
        ensure_retro_placeholder "$task_stem" || retro_state=$?
        if [ "$retro_state" -eq 10 ]; then
            continue
        fi
        if [ "$retro_state" -ne 0 ]; then
            RETRO_WARNINGS+=("$task_stem")
            printf '[%s] FAILURE: retro placeholder failed for %s\n' "$(date -Iseconds)" "$task_stem" >> "$LOG_DIR/retro-hook.log"
            continue
        fi
        if run_retro_agent "$task_stem"; then
            printf '[%s] SUCCESS: retro generated for %s\n' "$(date -Iseconds)" "$task_stem" >> "$LOG_DIR/retro-hook.log"
        else
            RETRO_WARNINGS+=("$task_stem")
            printf '[%s] FAILURE: retro generation failed for %s\n' "$(date -Iseconds)" "$task_stem" >> "$LOG_DIR/retro-hook.log"
        fi
    done

    echo -e "${GREEN}Close complete${NC}"
    echo "  Primary task: $PRIMARY_CLOSED_PATH"
    if [ -n "$SUPERSEDED_TASKS" ]; then
        echo "  Superseded tasks:"
        while IFS= read -r superseded_task; do
            [ -n "$superseded_task" ] && echo "    - $(basename "$superseded_task")"
        done <<< "$SUPERSEDED_TASKS"
    fi
    if [ "${#RETRO_WARNINGS[@]}" -gt 0 ]; then
        echo -e "${YELLOW}Retro generation warning for:${NC} ${RETRO_WARNINGS[*]}"
        echo "  Log: $LOG_DIR/retro-hook.log"
    fi
    exit 0
fi

# ============================================================
# Subcommand: fix — Apply fixes for review findings
# ============================================================
if [ "${1:-}" = "fix" ]; then
    shift

    # Require slug
    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 fix <slug> [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    # Parse optional flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            --internal) INTERNAL=true; shift ;;
            *) echo -e "${RED}Unknown option for 'fix': $1${NC}"; usage ;;
        esac
    done

    V1_COST_CSV="$LOG_DIR/pilot-${SLUG}-cost.csv"
    FIX_PROMPT="$SCRIPT_DIR/prompts/fix-agent.md"

    # Verify prerequisites
    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi
    if is_v2_task_file "$TASK_FILE"; then
        echo -e "${YELLOW}Task '${SLUG}' is a V2 task. V2 diffs and reviews live in:${NC}"
        echo "  docs/tasks/open/${SLUG}/competitive/"
        echo -e "Use: ${BLUE}./lauren-loop-v2.sh ${SLUG}${NC}"
        exit 1
    fi
    if [ ! -f "$FIX_PROMPT" ]; then
        echo -e "${RED}Fix agent prompt not found: $FIX_PROMPT${NC}"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    # Status gate: only "review-findings-pending" or "fixing" (stuck) tasks can be fixed
    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    if [ "$CURRENT_STATUS" != "review-findings-pending" ] && [ "$CURRENT_STATUS" != "fixing" ]; then
        echo -e "${RED}Task status is '$CURRENT_STATUS', expected 'review-findings-pending' or 'fixing'${NC}"
        echo "Only review-findings-pending or fixing (stuck) tasks can be fixed."
        exit 1
    fi

    acquire_lock
    ensure_review_sections "$TASK_FILE"

    # Tag current git SHA for diff re-capture
    PRE_FIX_SHA=$(git rev-parse HEAD)

    # Set status to fixing (skip if already in that state)
    if [ "$CURRENT_STATUS" != "fixing" ]; then
        _sed_i 's/^## Status: .*/## Status: fixing/' "$TASK_FILE"
    fi
    log_execution "$TASK_FILE" "Fix agent started (model: $MODEL, pre-SHA: $PRE_FIX_SHA)"

    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/pilot-${SLUG}-fix.log"

    # Build task instruction
    TASK_INSTRUCTION="Read the task file at ${TASK_FILE}. Apply fixes for all findings in ## Review Findings using TDD. Log fixes to ## Fixes Applied."

    # Inject placeholders
    PROMPT_CONTENT=$(cat "$FIX_PROMPT")
    PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$PROJECT_NAME|$PROJECT_NAME|g")
    PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$TEST_CMD|$TEST_CMD|g")
    PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s|\$LINT_CMD|$LINT_CMD|g")
    PROMPT_CONTENT="${PROJECT_RULES}

${PROMPT_CONTENT}"

    echo -e "${BLUE}Running fix agent (max-turns 200)...${NC}"

    # Run fix agent (single session, no loop)
    PHASE="fix"
    START_LINE=$(prepare_attempt_log "$LOG_FILE" "fix" "na")
    EXIT_CODE=0
    _COST_START=$(date +%s)
    SKIP_SUMMARY_HOOK=1 _timeout "$FIX_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$TASK_INSTRUCTION" \
        --system-prompt "$PROMPT_CONTENT" \
        --model "$MODEL" \
        --max-turns 200 \
        --dangerously-skip-permissions \
        --disallowedTools "WebFetch,WebSearch" \
        --verbose --output-format stream-json \
        >> "$LOG_FILE" 2>&1 || EXIT_CODE=$?
    _append_cost_row "$V1_COST_CSV" "fix" "claude" "$_COST_START" "$EXIT_CODE" "$LOG_FILE"

    if [[ "$EXIT_CODE" -eq 124 ]]; then
        echo -e "${RED}Fix agent timed out after $FIX_TIMEOUT${NC}"
        log_execution "$TASK_FILE" "Fix agent timed out after $FIX_TIMEOUT"
        _sed_i 's/^## Status: .*/## Status: timed-out/' "$TASK_FILE"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    if [ $EXIT_CODE -ne 0 ]; then
        echo -e "${RED}Fix agent exited with code $EXIT_CODE${NC}"
        if [ "$EXIT_CODE" -eq 130 ] || [ "$EXIT_CODE" -eq 143 ]; then
            log_execution "$TASK_FILE" "Fix agent ended by signal (exit code: $EXIT_CODE)"
        else
            log_execution "$TASK_FILE" "Fix agent failed (exit code: $EXIT_CODE)"
        fi
        _sed_i 's/^## Status: .*/## Status: fix-failed/' "$TASK_FILE"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    # Check for max-turns exhaustion
    if attempt_log_contains_max_turns "$LOG_FILE" "$START_LINE"; then
        echo -e "${RED}Fix agent exhausted max turns without completing${NC}"
        log_execution "$TASK_FILE" "Fix agent failed: reached max turns"
        _sed_i 's/^## Status: .*/## Status: fix-failed/' "$TASK_FILE"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    # Check for BLOCKED (scoped to log entries, not plan text)
    if grep -q '^\- \[.*\] BLOCKED:' "$TASK_FILE"; then
        echo -e "${YELLOW}Fix agent reported BLOCKED${NC}"
        BLOCKED_REASON=$(grep '^\- \[.*\] BLOCKED:' "$TASK_FILE" | tail -1)
        log_execution "$TASK_FILE" "Fix agent BLOCKED: $BLOCKED_REASON"
        _sed_i 's/^## Status: .*/## Status: fix-blocked/' "$TASK_FILE"
        echo "  Reason: $BLOCKED_REASON"
        echo "  Log: $LOG_FILE"
        exit 1
    fi

    # Re-capture diff — write to fix-specific filename so review can distinguish
    DIFF_FILE="$LOG_DIR/pilot-${SLUG}-fix-diff.patch"
    git diff "$PRE_FIX_SHA"..HEAD > "$DIFF_FILE" 2>/dev/null || true

    if [ -s "$DIFF_FILE" ]; then
        DIFF_LINES=$(wc -l < "$DIFF_FILE" | tr -d ' ')
        echo -e "${GREEN}Diff updated: $DIFF_FILE ($DIFF_LINES lines)${NC}"
    else
        git diff > "$DIFF_FILE" 2>/dev/null || true
        git diff --cached >> "$DIFF_FILE" 2>/dev/null || true
    fi

    # Update status to fixed
    _sed_i 's/^## Status: .*/## Status: fixed/' "$TASK_FILE"
    log_execution "$TASK_FILE" "Fix agent completed successfully"

    echo ""
    echo -e "${GREEN}Fix complete${NC}"
    echo "  Task file: $TASK_FILE"
    echo "  Status: fixed"
    echo "  Log: $LOG_FILE"
    echo "  Diff: $DIFF_FILE"
    echo ""
    echo "Next: ./lauren-loop.sh review ${SLUG}"

    exit 0
fi

# ============================================================
# Subcommand: chaos — Run chaos-critic against approved plan
# ============================================================
if [ "${1:-}" = "chaos" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 chaos <slug> [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    # Parse optional flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            *) echo -e "${RED}Unknown option for 'chaos': $1${NC}"; usage ;;
        esac
    done

    CHAOS_PROMPT="$SCRIPT_DIR/prompts/chaos-critic.md"

    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi
    if is_v2_task_file "$TASK_FILE"; then
        echo -e "${YELLOW}Task '${SLUG}' is a V2 task. V2 diffs and reviews live in:${NC}"
        echo "  docs/tasks/open/${SLUG}/competitive/"
        echo -e "Use: ${BLUE}./lauren-loop-v2.sh ${SLUG}${NC}"
        exit 1
    fi
    if [ ! -f "$CHAOS_PROMPT" ]; then
        echo -e "${RED}Chaos-critic prompt not found: $CHAOS_PROMPT${NC}"
        exit 1
    fi

    # Status gate: only plan-approved tasks
    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    if [ "$CURRENT_STATUS" != "plan-approved" ] && [ "$CURRENT_STATUS" != "planned" ]; then
        echo -e "${RED}Task status is '$CURRENT_STATUS', expected 'plan-approved' or 'planned'${NC}"
        exit 1
    fi

    # Extract plan from task file
    PLAN_CONTENT=$(_chaos_extract_plan "$TASK_FILE")
    if [ -z "$PLAN_CONTENT" ]; then
        echo -e "${RED}No plan found in task file${NC}"
        exit 1
    fi

    echo -e "${BLUE}Running chaos-critic (model: $MODEL)...${NC}"

    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/pilot-${SLUG}-chaos.log"
    CHAOS_ARTIFACT="$LOG_DIR/pilot-${SLUG}-chaos-findings.md"

    TASK_INSTRUCTION="Review the following plan and challenge its assumptions, test design, and strategy. Emit findings as BLOCKING, CONCERN, or NOTE.

Plan:
${PLAN_CONTENT}

Task file: ${TASK_FILE}"

    PROMPT_CONTENT=$(cat "$CHAOS_PROMPT")
    PROMPT_CONTENT="${PROJECT_RULES}

${PROMPT_CONTENT}"

    EXIT_CODE=0
    SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$TASK_INSTRUCTION" \
        --system-prompt "$PROMPT_CONTENT" \
        --model "$MODEL" \
        --max-turns 10 \
        --dangerously-skip-permissions \
        --disallowedTools "Bash,WebFetch,WebSearch" \
        --output-format text \
        2>"$LOG_FILE" | tee "$CHAOS_ARTIFACT" || EXIT_CODE=$?

    if [[ "$EXIT_CODE" -eq 124 ]]; then
        echo -e "${RED}Chaos-critic timed out after $CRITIC_TIMEOUT${NC}"
        exit 1
    fi

    # Parse findings
    BLOCKING_COUNT=$(_chaos_count_findings "$CHAOS_ARTIFACT" "BLOCKING")
    CONCERN_COUNT=$(_chaos_count_findings "$CHAOS_ARTIFACT" "CONCERN")
    NOTE_COUNT=$(_chaos_count_findings "$CHAOS_ARTIFACT" "NOTE")

    echo ""
    echo -e "${BLUE}Chaos-critic findings:${NC}"
    echo "  BLOCKING: $BLOCKING_COUNT"
    echo "  CONCERN:  $CONCERN_COUNT"
    echo "  NOTE:     $NOTE_COUNT"
    echo "  Artifact: $CHAOS_ARTIFACT"

    if [ "$BLOCKING_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${RED}BLOCKING findings detected — execution halted${NC}"
        echo "Review findings in: $CHAOS_ARTIFACT"
        echo "Resolve BLOCKING issues, then re-run: $0 chaos $SLUG"
        log_execution "$TASK_FILE" "Chaos-critic: $BLOCKING_COUNT BLOCKING, $CONCERN_COUNT CONCERN, $NOTE_COUNT NOTE — halted"
        exit 1
    fi

    log_execution "$TASK_FILE" "Chaos-critic: $BLOCKING_COUNT BLOCKING, $CONCERN_COUNT CONCERN, $NOTE_COUNT NOTE — passed"
    echo ""
    echo -e "${GREEN}Chaos-critic passed (no blocking findings)${NC}"
    exit 0
fi

# ============================================================
# Subcommand: verify — Goal-backward verification of task outcomes
# ============================================================
if [ "${1:-}" = "verify" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 verify <slug> [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    # Parse optional flags
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            *) echo -e "${RED}Unknown option for 'verify': $1${NC}"; usage ;;
        esac
    done

    VERIFY_PROMPT="$SCRIPT_DIR/prompts/verifier.md"

    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi
    if is_v2_task_file "$TASK_FILE"; then
        echo -e "${YELLOW}Task '${SLUG}' is a V2 task. V2 diffs and reviews live in:${NC}"
        echo "  docs/tasks/open/${SLUG}/competitive/"
        echo -e "Use: ${BLUE}./lauren-loop-v2.sh ${SLUG}${NC}"
        exit 1
    fi
    if [ ! -f "$VERIFY_PROMPT" ]; then
        echo -e "${RED}Verifier prompt not found: $VERIFY_PROMPT${NC}"
        exit 1
    fi

    # Status gate: only executed/fixed/review-passed tasks
    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    case "$CURRENT_STATUS" in
        executed|fixed|review-passed|needs\ verification) ;;
        *) echo -e "${RED}Task status is '$CURRENT_STATUS', expected 'executed', 'fixed', 'review-passed', or 'needs verification'${NC}"; exit 1 ;;
    esac

    # Extract goal and done criteria
    GOAL_TEXT=$(_verify_extract_goal "$TASK_FILE")
    DONE_CRITERIA=$(_verify_extract_done_criteria "$TASK_FILE")

    if [ -z "$GOAL_TEXT" ]; then
        echo -e "${RED}No goal found in task file${NC}"
        exit 1
    fi

    echo -e "${BLUE}Running goal verifier (model: $MODEL)...${NC}"

    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/pilot-${SLUG}-verify.log"

    TASK_INSTRUCTION="Verify the task outcomes against the goal and done criteria.

Goal: ${GOAL_TEXT}

Done Criteria:
${DONE_CRITERIA}

Task file: ${TASK_FILE}

Examine the codebase to determine if each criterion is met. For each criterion, emit PASS or FAIL with evidence."

    PROMPT_CONTENT=$(cat "$VERIFY_PROMPT")
    PROMPT_CONTENT="${PROJECT_RULES}

${PROMPT_CONTENT}"

    VERIFY_OUTPUT=$(mktemp)
    EXIT_CODE=0
    SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$TASK_INSTRUCTION" \
        --system-prompt "$PROMPT_CONTENT" \
        --model "$MODEL" \
        --max-turns 15 \
        --dangerously-skip-permissions \
        --disallowedTools "WebFetch,WebSearch" \
        --output-format text \
        2>"$LOG_FILE" | tee "$VERIFY_OUTPUT" || EXIT_CODE=$?

    if [[ "$EXIT_CODE" -eq 124 ]]; then
        echo -e "${RED}Verifier timed out after $CRITIC_TIMEOUT${NC}"
        rm -f "$VERIFY_OUTPUT"
        exit 1
    fi

    # Parse results
    PASS_COUNT=$(_verify_count_results "$VERIFY_OUTPUT" "PASS")
    FAIL_COUNT=$(_verify_count_results "$VERIFY_OUTPUT" "FAIL")
    TOTAL=$((PASS_COUNT + FAIL_COUNT))

    # Append verification results to task file
    _verify_append_results "$TASK_FILE" "$VERIFY_OUTPUT" "$PASS_COUNT" "$FAIL_COUNT"

    echo ""
    echo -e "${BLUE}Verification results:${NC}"
    echo "  PASS: $PASS_COUNT / $TOTAL"
    echo "  FAIL: $FAIL_COUNT / $TOTAL"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${RED}Verification failed — $FAIL_COUNT criteria not met${NC}"
        log_execution "$TASK_FILE" "Verification: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
        rm -f "$VERIFY_OUTPUT"
        exit 1
    fi

    log_execution "$TASK_FILE" "Verification: $PASS_COUNT PASS, $FAIL_COUNT FAIL — all criteria met"
    echo ""
    echo -e "${GREEN}All criteria verified${NC}"
    rm -f "$VERIFY_OUTPUT"
    exit 0
fi

# ============================================================
# Subcommand: plan-check — Validate XML plan structure
# ============================================================
if [ "${1:-}" = "plan-check" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 plan-check <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi

    # Extract plan section
    PLAN_CONTENT=$(_plancheck_extract_plan "$TASK_FILE")
    if [ -z "$PLAN_CONTENT" ]; then
        echo -e "${RED}No plan found in task file${NC}"
        exit 1
    fi

    echo -e "${BLUE}Validating plan structure...${NC}"

    # Detect format
    if _plancheck_is_current_xml "$PLAN_CONTENT"; then
        echo "  Format: XML"
        _plancheck_validate_xml "$PLAN_CONTENT"
        RESULT=$?
    elif _plancheck_is_xml "$PLAN_CONTENT"; then
        echo -e "  ${YELLOW}Format: Legacy (numbered steps) — consider migrating to XML${NC}"
        RESULT=0
    else
        echo -e "  ${YELLOW}Format: Legacy (numbered steps) — consider migrating to XML${NC}"
        RESULT=0
    fi

    if [ "$RESULT" -eq 0 ]; then
        echo -e "${GREEN}Plan validation passed${NC}"
    else
        echo -e "${RED}Plan validation failed${NC}"
    fi
    exit $RESULT
fi

# ============================================================
# Subcommand: progress — Show task progress summary
# ============================================================
if [ "${1:-}" = "progress" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 progress <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    STATE_FILE="$SCRIPT_DIR/.planning/${SLUG}.json"

    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi

    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    GOAL_TEXT=$(grep '^## Goal:' "$TASK_FILE" | head -1 | sed 's/^## Goal: //')

    echo -e "${BLUE}Task: ${SLUG}${NC}"
    echo "  Status: $CURRENT_STATUS"
    echo "  Goal:   $GOAL_TEXT"

    if [ -f "$STATE_FILE" ]; then
        echo ""
        echo -e "${BLUE}Saved state:${NC}"
        _state_show_snapshot "$STATE_FILE"
    fi

    # Show execution log tail
    _state_show_recent_log "$TASK_FILE"

    exit 0
fi

# ============================================================
# Subcommand: pause — Snapshot task state for later resume
# ============================================================
if [ "${1:-}" = "pause" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 pause <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi

    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')

    # Create .planning directory
    mkdir -p "$SCRIPT_DIR/.planning"

    # Capture state snapshot
    _state_write_snapshot "$SLUG" "$TASK_FILE" "$CURRENT_STATUS"

    # Update status
    _sed_i 's/^## Status: .*/## Status: paused/' "$TASK_FILE"
    log_execution "$TASK_FILE" "Paused (was: $CURRENT_STATUS)"

    echo -e "${GREEN}Task paused${NC}"
    echo "  State saved: .planning/${SLUG}.json"
    echo "  Resume with: $0 resume $SLUG"
    exit 0
fi

# ============================================================
# Subcommand: resume — Restore paused task and continue
# ============================================================
if [ "${1:-}" = "resume" ]; then
    shift

    if [ $# -lt 1 ]; then
        echo -e "${RED}Usage: $0 resume <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    STATE_FILE="$SCRIPT_DIR/.planning/${SLUG}.json"

    if ! require_existing_task_file "$SLUG"; then
        exit 1
    fi

    if [ ! -f "$STATE_FILE" ]; then
        echo -e "${RED}No saved state found for '$SLUG'${NC}"
        echo "  Expected: .planning/${SLUG}.json"
        echo "  Run '$0 pause $SLUG' first to save state."
        exit 1
    fi

    # Validate required artifacts
    _state_validate_artifacts "$SLUG" "$TASK_FILE"
    VALIDATE_RESULT=$?
    if [ "$VALIDATE_RESULT" -ne 0 ]; then
        echo -e "${RED}Resume blocked — required artifacts missing${NC}"
        exit 1
    fi

    # Restore previous status
    PREVIOUS_STATUS=$(_state_read_field "$STATE_FILE" "previous_status")
    if [ -n "$PREVIOUS_STATUS" ]; then
        _sed_i "s/^## Status: .*/## Status: $PREVIOUS_STATUS/" "$TASK_FILE"
    fi

    log_execution "$TASK_FILE" "Resumed from paused state"

    echo -e "${GREEN}Task resumed${NC}"
    echo "  Status restored: $PREVIOUS_STATUS"
    _state_show_snapshot "$STATE_FILE"
    echo ""
    echo "  State file preserved at: .planning/${SLUG}.json"
    exit 0
fi

# ============================================================
# Planner-Critic Pipeline — requires slug + goal
# ============================================================
if [ $# -lt 2 ]; then
    usage
fi

SLUG="$1"
GOAL="$2"
shift 2

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --resume)
            RESUME=true
            shift
            ;;
        --legacy)
            LEGACY=true
            shift
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --no-review)
            NO_REVIEW=true
            shift
            ;;
        --no-close)
            NO_CLOSE=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

TASK_FILE=""  # set by create_task_file() via resolve_task_file()
TEMPLATE="$SCRIPT_DIR/templates/pilot-task.md"
PLANNER_PROMPT="$SCRIPT_DIR/prompts/planner.md"
CRITIC_PROMPT="$SCRIPT_DIR/prompts/critic.md"

# create_task_file — Resolve existing or copy template
# ============================================================
create_task_file() {
    local slug="$1"
    local goal="$2"

    local resolved=0
    resolve_task_file "$slug" || resolved=$?

    # resolved=0 means an existing file was found — reuse it without
    # changing whether resume was explicitly requested by the user.
    if [ $resolved -eq 0 ]; then
        if is_v2_task_file "$TASK_FILE"; then
            echo -e "${RED}Slug '$slug' resolves to a V2 task directory: $TASK_FILE${NC}"
            echo "Use ./lauren-loop.sh auto $slug \"$goal\" or ./lauren-loop-v2.sh directly."
            exit 1
        fi
        # Guard: warn if task is in a terminal state
        local status
        status=$(grep -m1 '^## Status:' "$TASK_FILE" | sed 's/^## Status:[[:space:]]*//' || true)
        if [[ "$status" == *CLOSED* ]] || [[ "$status" == *ABANDONED* ]]; then
            echo -e "${YELLOW}WARNING: Task file exists but status is: $status${NC}"
            echo -e "${YELLOW}  Delete the file to start fresh, or continuing in 3s...${NC}"
            sleep 3
        fi
        echo -e "${BLUE}Resuming existing task: $TASK_FILE${NC}"
        ensure_sections "$TASK_FILE"
        return 0
    fi
    if [ $resolved -eq 2 ]; then
        exit 1
    fi

    if [ "$RESUME" = true ]; then
        echo -e "${RED}No existing task file found for slug: $slug${NC}"
        exit 1
    fi

    if [ ! -f "$TEMPLATE" ]; then
        echo -e "${RED}Template not found: $TEMPLATE${NC}"
        exit 1
    fi

    # Format task name from slug
    local task_name
    task_name=$(echo "$slug" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M')

    # Escape sed-special chars in user-provided values (&, \, and | delimiter are special in sed)
    local escaped_goal escaped_task_name
    escaped_goal=$(printf '%s\n' "$goal" | sed 's/[&\\/|]/\\&/g')
    escaped_task_name=$(printf '%s\n' "$task_name" | sed 's/[&\\/|]/\\&/g')

    cp "$TEMPLATE" "$TASK_FILE"
    _sed_i "s|{{TASK_NAME}}|${escaped_task_name}|g" "$TASK_FILE"
    _sed_i "s|{{GOAL}}|${escaped_goal}|g" "$TASK_FILE"
    _sed_i "s|{{TIMESTAMP}}|${timestamp}|g" "$TASK_FILE"

    # Link to source task if a related (but non-matching) task was found
    if [ -n "$SOURCE_TASK_FILE" ]; then
        local relative_source
        relative_source=$(echo "$SOURCE_TASK_FILE" | sed "s|$SCRIPT_DIR/||")
        _sed_i "1s|^|## Source Task: ${relative_source}\n\n|" "$TASK_FILE"
    fi

    echo -e "${GREEN}Created task file: $TASK_FILE${NC}"
}

# ============================================================
# run_planner — Execute planner agent
# ============================================================
run_planner() {
    local task_file="$1"
    local round="$2"
    local backup_file="$LOG_DIR/$(basename "$task_file").bak"

    echo -e "${BLUE}Running planner (round $round)...${NC}"

    # Backup (to log dir)
    mkdir -p "$LOG_DIR"
    cp "$task_file" "$backup_file"

    # Build task instruction
    local task_instruction="Read the task file at ${task_file} and write an implementation plan into the ## Current Plan section."
    if [ "$round" -gt 1 ]; then
        task_instruction="Read the task file at ${task_file}. Check ## Plan History for previous rejected plans and the critic's feedback. Write a REVISED plan into ## Current Plan that addresses all feedback."
    fi

    # Create log directory
    mkdir -p "$LOG_DIR"
    local log_file="$LOG_DIR/pilot-${SLUG}-planner-r${round}.log"

    # Run planner agent (unset CLAUDECODE to allow nested sessions)
    local planner_content
    planner_content=$(cat "$PLANNER_PROMPT")
    planner_content="${PROJECT_RULES}

${planner_content}"

    PHASE="planner"
    local start_line
    start_line=$(prepare_attempt_log "$log_file" "planner" "$round")
    local exit_code=0
    local _COST_START; _COST_START=$(date +%s)
    SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$task_instruction" \
        --system-prompt "$planner_content" \
        --model "$MODEL" \
        --max-turns 200 \
        --dangerously-skip-permissions \
        --disallowedTools "Bash,WebFetch,WebSearch" \
        --verbose --output-format stream-json \
        >> "$log_file" 2>&1 || exit_code=$?
    _append_cost_row "$V1_COST_CSV" "planner-r${round}" "claude" "$_COST_START" "$exit_code" "$log_file"

    if [[ "$exit_code" -eq 124 ]]; then
        echo -e "${RED}Planner timed out after $CRITIC_TIMEOUT${NC}"
        echo -e "${YELLOW}Restoring backup...${NC}"
        cp "$backup_file" "$task_file"
        rm -f "$backup_file"
        return 1
    fi

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Planner exited with code $exit_code${NC}"
        if [ "$exit_code" -eq 130 ] || [ "$exit_code" -eq 143 ]; then
            log_signal "planner-exit-$exit_code"
        fi
        echo -e "${YELLOW}Restoring backup...${NC}"
        cp "$backup_file" "$task_file"
        return 1
    fi

    # Check for max-turns exhaustion (exit 0 but incomplete plan)
    if attempt_log_contains_max_turns "$log_file" "$start_line"; then
        echo -e "${YELLOW}Planner exhausted max turns (round $round)${NC}"
        echo -e "${YELLOW}Restoring backup...${NC}"
        cp "$backup_file" "$task_file"
        rm -f "$backup_file"
        return 1
    fi

    # Validate structure
    if ! validate_task_file "$task_file"; then
        echo -e "${RED}Task file corrupted after planner run${NC}"
        echo -e "${YELLOW}Restoring backup...${NC}"
        cp "$backup_file" "$task_file"
        return 1
    fi

    # Check that planner actually wrote something
    local plan_start
    plan_start=$(grep -n '^## Current Plan' "$task_file" | head -1 | cut -d: -f1)
    local critique_start
    critique_start=$(grep -n '^## Critique' "$task_file" | head -1 | cut -d: -f1)
    local plan_lines=$((critique_start - plan_start - 1))

    if [ "$plan_lines" -le 1 ]; then
        echo -e "${RED}Planner did not write a plan${NC}"
        cp "$backup_file" "$task_file"
        return 1
    fi

    rm -f "$backup_file"
    echo -e "${GREEN}Planner completed (round $round) — $plan_lines lines written${NC}"
    echo "  Log: $log_file"
    return 0
}

# ============================================================
# run_critic — Execute critic agent, extract verdict
# ============================================================
run_critic() {
    local task_file="$1"
    local round="$2"
    local backup_file="$LOG_DIR/$(basename "$task_file").bak"
    local artifact_dir="$SCRIPT_DIR/competitive"
    local critique_file="$artifact_dir/plan-critique.md"
    local contract_file="$artifact_dir/plan-critique.contract.json"

    echo -e "${BLUE}Running critic (round $round)...${NC}"

    # Backup (to log dir)
    mkdir -p "$LOG_DIR"
    cp "$task_file" "$backup_file"
    mkdir -p "$artifact_dir"
    rm -f "$critique_file" "$contract_file"

    local task_instruction="Read the task file at ${task_file}. Evaluate the plan in ## Current Plan and write your critique to the ## Critique section. This is round ${round}."

    mkdir -p "$LOG_DIR"
    local log_file="$LOG_DIR/pilot-${SLUG}-critic-r${round}.log"

    # Run critic agent (unset CLAUDECODE to allow nested sessions)
    local critic_content
    critic_content=$(cat "$CRITIC_PROMPT")
    critic_content="${PROJECT_RULES}

${critic_content}"

    PHASE="critic"
    local start_line
    start_line=$(prepare_attempt_log "$log_file" "critic" "$round")
    local exit_code=0
    local _COST_START; _COST_START=$(date +%s)
    SKIP_SUMMARY_HOOK=1 _timeout "$CRITIC_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$task_instruction" \
        --system-prompt "$critic_content" \
        --model "$MODEL" \
        --max-turns 200 \
        --dangerously-skip-permissions \
        --disallowedTools "Bash,WebFetch,WebSearch" \
        --verbose --output-format stream-json \
        >> "$log_file" 2>&1 || exit_code=$?
    _append_cost_row "$V1_COST_CSV" "critic-r${round}" "claude" "$_COST_START" "$exit_code" "$log_file"

    if [[ "$exit_code" -eq 124 ]]; then
        echo -e "${RED}Critic timed out after $CRITIC_TIMEOUT${NC}"
        echo "  Log: $log_file"
        cp "$backup_file" "$task_file"
        rm -f "$backup_file"
        return 3
    fi

    # Check for max-turns exhaustion BEFORE checking exit code
    if attempt_log_contains_max_turns "$log_file" "$start_line"; then
        echo -e "${YELLOW}Critic exhausted max turns (round $round)${NC}"
        echo "  Log: $log_file"
        # Restore backup — critic may have partially written
        cp "$backup_file" "$task_file"
        rm -f "$backup_file"
        return 3
    fi

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Critic exited with code $exit_code${NC}"
        if [ "$exit_code" -eq 130 ] || [ "$exit_code" -eq 143 ]; then
            log_signal "critic-exit-$exit_code"
        fi
        cp "$backup_file" "$task_file"
        return 2
    fi

    # Validate structure
    if ! validate_task_file "$task_file"; then
        echo -e "${RED}Task file corrupted after critic run${NC}"
        cp "$backup_file" "$task_file"
        return 2
    fi

    rm -f "$backup_file"

    # Read the repo-root sidecar artifacts written by prompts/critic.md.
    local verdict=""
    if [ -f "$contract_file" ]; then
        verdict=$(_parse_contract "$critique_file" "verdict")
        if [ -z "$verdict" ]; then
            echo -e "${RED}Critic produced unreadable verdict sidecar: $contract_file${NC}"
            echo "  Log: $log_file"
            return 2
        fi
    elif [ -f "$critique_file" ]; then
        verdict=$(_parse_contract "$critique_file" "verdict")
        if [ -z "$verdict" ]; then
            echo -e "${RED}Could not extract verdict from critique artifact${NC}"
            echo "  Log: $log_file"
            return 2
        fi
    else
        echo -e "${RED}Critic produced no verdict artifact.${NC}"
        echo "  Expected: $contract_file or $critique_file"
        echo "  Log: $log_file"
        log_execution "$task_file" "Critic produced no verdict artifact"
        return 2
    fi

    if [ -f "$critique_file" ] && ! _critic_verdict_is_consistent "$critique_file" "$verdict"; then
        echo -e "${YELLOW}Critic returned inconsistent verdict: $verdict${NC}"
        echo "  Log: $log_file"
        return 2
    fi

    echo "  Log: $log_file"

    if [ "$verdict" = "EXECUTE" ]; then
        echo -e "${GREEN}Critic verdict: EXECUTE${NC}"
        return 0
    else
        echo -e "${YELLOW}Critic verdict: BLOCKED${NC}"
        return 1
    fi
}

# ============================================================
# run_lead — Execute lead agent (plan + critic loop + execute)
# ============================================================
run_lead() {
    local task_file="$1"
    local slug="$2"
    local backup_file="$LOG_DIR/$(basename "$task_file").bak"

    echo -e "${BLUE}Running lead agent (plan + execute)...${NC}"
    mkdir -p "$LOG_DIR"
    cp "$task_file" "$backup_file"

    # Tag current git SHA for diff later
    local pre_exec_sha
    pre_exec_sha=$(git rev-parse HEAD)

    mkdir -p "$LOG_DIR"
    local log_file="$LOG_DIR/pilot-${slug}-lead.log"

    # Build task instruction
    local task_instruction="Read the task file at ${task_file}. \
Follow the three-phase workflow in your system prompt: \
(1) explore and plan, (2) spawn critic and handle feedback, \
(3) execute via TDD. The critic prompt is at ${SCRIPT_DIR}/prompts/critic.md."

    # Inject variables into prompt
    local prompt_content
    prompt_content=$(cat "$LEAD_PROMPT")
    prompt_content=$(echo "$prompt_content" | sed "s|\$PROJECT_NAME|$PROJECT_NAME|g")
    prompt_content=$(echo "$prompt_content" | sed "s|\$TEST_CMD|$TEST_CMD|g")
    prompt_content=$(echo "$prompt_content" | sed "s|\$LINT_CMD|$LINT_CMD|g")
    prompt_content=$(echo "$prompt_content" | sed "s|\$CRITIC_PROMPT_PATH|${SCRIPT_DIR}/prompts/critic.md|g")
    prompt_content=$(echo "$prompt_content" | sed "s|\$MAX_ROUNDS|${MAX_ROUNDS}|g")
    prompt_content="${PROJECT_RULES}

${prompt_content}"

    touch "$log_file"
    local start_line
    start_line=$(prepare_attempt_log "$log_file" "lead" "na")
    start_lead_monitor "$log_file" "$task_file"

    PHASE="lead"
    local exit_code=0
    local _cost_start
    _cost_start=$(date +%s)
    SKIP_SUMMARY_HOOK=1 _timeout "$LEAD_TIMEOUT" env -u CLAUDECODE claude --settings "$AGENT_SETTINGS" --disable-slash-commands -p "$task_instruction" \
        --system-prompt "$prompt_content" \
        --model "$MODEL" \
        --max-turns 300 \
        --dangerously-skip-permissions \
        --disallowedTools "WebFetch,WebSearch" \
        --verbose --output-format stream-json \
        >> "$log_file" 2>&1 || exit_code=$?
    _append_cost_row "$V1_COST_CSV" "lead" "claude" "$_cost_start" "$exit_code" "$log_file"

    if [[ "$exit_code" -eq 124 ]]; then
        stop_lead_monitor
        echo -e "${RED}Lead timed out after $LEAD_TIMEOUT${NC}"
        log_execution "$task_file" "Lead timed out after $LEAD_TIMEOUT"
        _sed_i 's/^## Status: .*/## Status: timed-out/' "$task_file"
        rm -f "$backup_file"
        return 124
    fi

    stop_lead_monitor

    # Standard checks: exit code, max-turns exhaustion
    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}Lead exited with code $exit_code${NC}"
        if [ "$exit_code" -eq 130 ] || [ "$exit_code" -eq 143 ]; then
            log_execution "$task_file" "Lead ended by signal (exit code: $exit_code)"
        else
            log_execution "$task_file" "Lead failed (exit code: $exit_code)"
        fi
    fi
    if attempt_log_contains_max_turns "$log_file" "$start_line"; then
        echo -e "${RED}Lead exhausted max turns${NC}"
        log_execution "$task_file" "Lead failed: reached max turns"
    fi

    # --- POST-EXIT STATUS VALIDATION ---
    # The Lead SHOULD have set status to a terminal state.
    # If it didn't (LLM forgot, formatted wrong), catch it here.
    local final_status
    final_status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //' | tr -d '\r')
    local valid_terminal_states="executed plan-approved plan-failed execution-blocked execution-failed timed-out"

    if ! echo "$valid_terminal_states" | grep -qw "$final_status"; then
        echo -e "${YELLOW}Lead left unexpected status: '$final_status'${NC}"
        echo -e "${YELLOW}Setting status to needs-human-review${NC}"
        _sed_i 's/^## Status: .*/## Status: needs-human-review/' "$task_file"
        log_execution "$task_file" "Lead left unexpected status '$final_status', set needs-human-review"
    fi

    # Validate task file structure wasn't mangled
    if ! validate_task_file "$task_file"; then
        echo -e "${RED}Task file structure corrupted after Lead run${NC}"
        echo -e "${YELLOW}Restoring backup...${NC}"
        cp "$backup_file" "$task_file"
        _sed_i 's/^## Status: .*/## Status: needs-human-review/' "$task_file"
        log_execution "$task_file" "Task file corrupted, restored backup, set needs-human-review"
        rm -f "$backup_file"
        return 1
    fi

    # Scope check: verify changed files match plan (only if Lead executed code)
    local final_status_for_scope
    final_status_for_scope=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //' | tr -d '\r')
    if [ "$final_status_for_scope" = "executed" ]; then
        if ! check_diff_scope "$task_file" "$pre_exec_sha"; then
            echo -e "${YELLOW}Setting status to needs-human-review due to scope violation${NC}"
            _sed_i 's/^## Status: .*/## Status: needs-human-review/' "$task_file"
            log_execution "$task_file" "Scope check failed: changed files don't match plan"
        fi
    fi

    # Capture diff
    local diff_file="$LOG_DIR/pilot-${slug}-diff.patch"
    git diff "$pre_exec_sha"..HEAD > "$diff_file" 2>/dev/null || true
    if [ ! -s "$diff_file" ]; then
        git diff > "$diff_file" 2>/dev/null || true
        git diff --cached >> "$diff_file" 2>/dev/null || true
    fi

    rm -f "$backup_file"
    echo "  Log: $log_file"
    return $exit_code
}

# ============================================================
# Main (Lead pipeline)
# ============================================================
main_lead() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo "     Lead Agent Pipeline"
    echo -e "==============================================${NC}"
    echo ""
    echo "  Slug:    $SLUG"
    echo "  Goal:    $GOAL"
    echo "  Model:   $MODEL"
    echo "  Dry run: $DRY_RUN"
    echo "  Resume:  $RESUME"
    echo ""

    acquire_lock

    # Verify prerequisites
    if [ ! -f "$LEAD_PROMPT" ]; then
        echo -e "${RED}Lead prompt not found: $LEAD_PROMPT${NC}"
        exit 1
    fi
    if [ ! -f "$CRITIC_PROMPT" ]; then
        echo -e "${RED}Critic prompt not found: $CRITIC_PROMPT${NC}"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    # Step 1: Create or resume task file
    create_task_file "$SLUG" "$GOAL"

    # Step 2: Inject related context
    inject_context "$TASK_FILE"

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo -e "${GREEN}Dry run complete. Task file created at:${NC}"
        echo "  $TASK_FILE"
        echo ""
        echo "Validate:"
        if validate_task_file "$TASK_FILE"; then
            echo -e "  ${GREEN}All required sections present${NC}"
        else
            echo -e "  ${RED}Validation failed${NC}"
            exit 1
        fi
        exit 0
    fi

    # Status gate for --resume: only allow resuming from known states
    if [ "$RESUME" = true ]; then
        CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
        case "$CURRENT_STATUS" in
            not-started|lead-running|planning-round-*|plan-approved|executing)
                echo -e "${BLUE}Resuming from status: $CURRENT_STATUS${NC}"
                ;;
            *)
                echo -e "${RED}Cannot resume from status '$CURRENT_STATUS'${NC}"
                echo "Expected: not-started, lead-running, planning-round-*, plan-approved, or executing"
                exit 1
                ;;
        esac
    fi

    V1_COST_CSV="$LOG_DIR/pilot-${SLUG}-cost.csv"
    log_execution "$TASK_FILE" "Lead pipeline started (model: $MODEL, max rounds: $MAX_ROUNDS)"

    # Set lead-running, but preserve transient states on resume
    local current_status
    current_status=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    case "$current_status" in
        lead-running|planning-round-*|executing)
            echo -e "${BLUE}Keeping transient status: $current_status${NC}" ;;
        *)
            _sed_i 's/^## Status: .*/## Status: lead-running/' "$TASK_FILE" ;;
    esac

    run_lead "$TASK_FILE" "$SLUG"
    local lead_exit=$?

    # Read validated status (run_lead already set needs-human-review if invalid)
    local final_status
    final_status=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')

    echo ""
    echo -e "${BLUE}=============================================="
    echo "     Pipeline Complete"
    echo -e "==============================================${NC}"
    echo ""

    case "$final_status" in
        executed)
            if [ "$NO_REVIEW" = true ]; then
                local lead_log_file lead_diff_file rel_lead_log_file rel_lead_diff_file lead_exec_signal left_off_summary attempt_entry
                lead_log_file="$LOG_DIR/pilot-${SLUG}-lead.log"
                lead_diff_file="$LOG_DIR/pilot-${SLUG}-diff.patch"
                rel_lead_log_file="${lead_log_file#"$SCRIPT_DIR"/}"
                rel_lead_diff_file="${lead_diff_file#"$SCRIPT_DIR"/}"
                lead_exec_signal=$(latest_execution_test_signal "$TASK_FILE")
                left_off_summary="Automated V1 lead execution completed. Latest execution evidence: ${lead_exec_signal:-Lead completed successfully}. Artifacts: ${rel_lead_diff_file}, ${rel_lead_log_file}. Task is ready for human verification."
                attempt_entry="- $(date '+%Y-%m-%d'): Routed V1 auto execution completed via lead pipeline. Latest execution evidence: ${lead_exec_signal:-Lead completed successfully}. Artifacts: ${rel_lead_diff_file}, ${rel_lead_log_file}. -> Result: worked"
                finalize_v1_verification_handoff "$TASK_FILE" "$left_off_summary" "$attempt_entry"
                log_execution "$TASK_FILE" "Lead completed: plan approved, executed, and handed off for human verification"
                echo -e "${GREEN}Plan approved and executed${NC}"
                echo "  Task file: $TASK_FILE"
                echo "  Status: needs verification"
                echo ""
                echo "  --no-review: routed V1 auto stops after execution handoff"
                echo "  Next: ./lauren-loop.sh review $SLUG or ./lauren-loop.sh verify $SLUG"
            else
                log_execution "$TASK_FILE" "Lead completed: plan approved and executed"
                echo -e "${GREEN}Plan approved and executed${NC}"
                echo "  Task file: $TASK_FILE"
                echo "  Status: executed"

                # Auto-chain: review → fix → re-review (max 2 fix cycles)
                local fix_cycle=0
                local max_fix_cycles=2

                while [ $fix_cycle -le $max_fix_cycles ]; do
                    echo ""
                    echo -e "${BLUE}━━━ Auto-Review (cycle $((fix_cycle + 1))) ━━━${NC}"
                    log_execution "$TASK_FILE" "Auto-chaining review (fix cycle $fix_cycle)"

                    "$0" review "$SLUG" --model "$MODEL" --internal || {
                        log_execution "$TASK_FILE" "Auto-review failed (exit $?)"
                        echo -e "${RED}Auto-review failed. Manual intervention needed.${NC}"
                        break
                    }

                    local post_review_status
                    post_review_status=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')

                    if [ "$post_review_status" = "review-passed" ]; then
                        echo ""
                        echo -e "${GREEN}━━━ Pipeline Complete: review-passed ━━━${NC}"
                        log_execution "$TASK_FILE" "Full pipeline complete: review-passed"

                        if [ "$NO_CLOSE" = true ]; then
                            echo "  --no-close: skipping auto-close"
                            echo "  Next: ./lauren-loop.sh close $SLUG"
                        else
                            echo ""
                            echo -e "${BLUE}━━━ Auto-Close ━━━${NC}"
                            log_execution "$TASK_FILE" "Auto-chaining close"
                            _LAUREN_LOOP_INTERNAL=1 "$0" close "$SLUG" || {
                                log_execution "$TASK_FILE" "Auto-close failed (exit $?)"
                                echo -e "${RED}Auto-close failed. Run manually: ./lauren-loop.sh close $SLUG${NC}"
                            }
                        fi
                        break
                    elif [ "$post_review_status" = "review-findings-pending" ]; then
                        if [ $fix_cycle -ge $max_fix_cycles ]; then
                            echo -e "${YELLOW}Max fix cycles ($max_fix_cycles) reached. Stopping.${NC}"
                            _sed_i 's/^## Status: .*/## Status: needs-human-review/' "$TASK_FILE"
                            log_execution "$TASK_FILE" "Max fix cycles reached — needs human review"
                            break
                        fi

                        echo -e "${YELLOW}Review found issues — auto-fixing...${NC}"
                        log_execution "$TASK_FILE" "Auto-chaining fix (cycle $((fix_cycle + 1)))"

                        "$0" fix "$SLUG" --model "$MODEL" --internal || {
                            log_execution "$TASK_FILE" "Auto-fix failed (exit $?)"
                            echo -e "${RED}Auto-fix failed. Manual intervention needed.${NC}"
                            break
                        }

                        fix_cycle=$((fix_cycle + 1))
                    else
                        echo -e "${YELLOW}Unexpected post-review status: $post_review_status${NC}"
                        log_execution "$TASK_FILE" "Auto-chain stopped: unexpected status $post_review_status"
                        break
                    fi
                done
            fi
            ;;
        plan-approved)
            # Lead bailed before execution (turn budget or chose to defer)
            log_execution "$TASK_FILE" "Lead approved plan but did not execute — run executor separately"
            echo -e "${YELLOW}Plan approved but not executed${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: plan-approved"
            echo ""
            echo "Plan approved. Run: ./lauren-loop.sh execute $SLUG"
            ;;
        execution-blocked)
            log_execution "$TASK_FILE" "Lead blocked during execution"
            echo -e "${YELLOW}Execution blocked${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: execution-blocked"
            ;;
        plan-failed)
            log_execution "$TASK_FILE" "Lead could not get plan approved after $MAX_ROUNDS rounds"
            echo -e "${RED}Plan failed after $MAX_ROUNDS round(s)${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: plan-failed"
            ;;
        execution-failed)
            log_execution "$TASK_FILE" "Lead execution failed"
            echo -e "${RED}Execution failed${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: execution-failed"
            ;;
        timed-out)
            log_execution "$TASK_FILE" "Lead timed out"
            echo -e "${RED}Lead agent timed out${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: timed-out"
            echo ""
            echo "Increase LEAD_TIMEOUT (currently $LEAD_TIMEOUT) or resume: ./lauren-loop.sh $SLUG \"$GOAL\" --resume"
            ;;
        needs-human-review)
            log_execution "$TASK_FILE" "Lead left task in unexpected state — human review required"
            echo -e "${YELLOW}Needs human review${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: needs-human-review"
            ;;
    esac

    echo ""
    echo "Logs: $LOG_DIR/pilot-${SLUG}-*.log"
}

# ============================================================
# Main (Legacy planner-critic pipeline)
# ============================================================
main_legacy() {
    echo ""
    echo -e "${BLUE}=============================================="
    echo "     Planner-Critic Pipeline (Legacy)"
    echo -e "==============================================${NC}"
    echo ""
    echo "  Slug:    $SLUG"
    echo "  Goal:    $GOAL"
    echo "  Model:   $MODEL"
    echo "  Mode:    legacy"
    echo "  Dry run: $DRY_RUN"
    echo "  Resume:  $RESUME"
    echo ""

    acquire_lock

    # Verify prerequisites
    if [ ! -f "$PLANNER_PROMPT" ]; then
        echo -e "${RED}Planner prompt not found: $PLANNER_PROMPT${NC}"
        exit 1
    fi
    if [ ! -f "$CRITIC_PROMPT" ]; then
        echo -e "${RED}Critic prompt not found: $CRITIC_PROMPT${NC}"
        exit 1
    fi
    if ! command -v claude &>/dev/null; then
        echo -e "${RED}claude CLI not found. Install Claude Code first.${NC}"
        exit 1
    fi

    # Step 1: Create or resume task file
    create_task_file "$SLUG" "$GOAL"

    # Step 2: Inject related context
    inject_context "$TASK_FILE"

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo -e "${GREEN}Dry run complete. Task file created at:${NC}"
        echo "  $TASK_FILE"
        echo ""
        echo "Validate:"
        if validate_task_file "$TASK_FILE"; then
            echo -e "  ${GREEN}All required sections present${NC}"
        else
            echo -e "  ${RED}Validation failed${NC}"
            exit 1
        fi
        exit 0
    fi

    V1_COST_CSV="$LOG_DIR/pilot-${SLUG}-cost.csv"
    log_execution "$TASK_FILE" "Pipeline started (model: $MODEL, max rounds: $MAX_ROUNDS)"

    # Step 3: Planner-Critic loop
    local round=1
    local final_verdict=""
    local skip_planner=false
    local consecutive_critic_exhaustions=0

    while [ "$round" -le "$MAX_ROUNDS" ]; do
        echo ""
        echo -e "${BLUE}━━━ Round $round of $MAX_ROUNDS ━━━${NC}"
        echo ""

        # Run planner (skip if retrying after critic exhaustion)
        if [ "$skip_planner" = true ]; then
            echo -e "${BLUE}Retrying critic on existing plan (round $round)...${NC}"
            skip_planner=false
        else
            if ! run_planner "$TASK_FILE" "$round"; then
                log_execution "$TASK_FILE" "Round $round: Planner failed"
                echo -e "${RED}Planner failed in round $round${NC}"
                final_verdict="error"
                break
            fi
            log_execution "$TASK_FILE" "Round $round: Planner completed"
            consecutive_critic_exhaustions=0
        fi

        # Run critic
        local critic_result=0
        run_critic "$TASK_FILE" "$round" || critic_result=$?

        if [ $critic_result -eq 0 ]; then
            # PASS
            log_execution "$TASK_FILE" "Round $round: Critic PASS"
            final_verdict="pass"
            break
        elif [ $critic_result -eq 1 ]; then
            # FAIL — archive and continue
            log_execution "$TASK_FILE" "Round $round: Critic FAIL"
            if [ "$round" -lt "$MAX_ROUNDS" ]; then
                archive_round "$TASK_FILE" "$round"
            fi
            final_verdict="fail"
        elif [ $critic_result -eq 3 ]; then
            # Critic exhausted turns — plan wasn't rejected, critic couldn't finish
            consecutive_critic_exhaustions=$((consecutive_critic_exhaustions + 1))
            if [ "$consecutive_critic_exhaustions" -ge 2 ]; then
                echo -e "${RED}Critic exhausted max turns twice in a row — aborting${NC}"
                log_execution "$TASK_FILE" "Round $round: Critic exhausted twice, pipeline aborted"
                final_verdict="error"
                break
            fi
            # Keep the SAME plan — retry critic next round
            skip_planner=true
            log_execution "$TASK_FILE" "Round $round: Critic exhausted max turns, will retry"
        else
            # Error
            log_execution "$TASK_FILE" "Round $round: Critic error"
            final_verdict="error"
            break
        fi

        round=$((round + 1))
    done

    # Step 4: Final status
    echo ""
    echo -e "${BLUE}=============================================="
    echo "     Pipeline Complete"
    echo -e "==============================================${NC}"
    echo ""

    case "$final_verdict" in
        pass)
            _sed_i 's/^## Status: .*/## Status: plan-approved/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Pipeline complete: APPROVED after $((round)) round(s)"
            echo -e "${GREEN}Plan APPROVED after $round round(s)${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: plan-approved"
            echo ""
            echo "Next: Review the plan and implement, or hand to Claude Code for execution."
            ;;
        fail)
            _sed_i 's/^## Status: .*/## Status: needs-human-review/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Pipeline complete: NEEDS HUMAN REVIEW after $MAX_ROUNDS round(s)"
            echo -e "${YELLOW}Plan FAILED after $MAX_ROUNDS round(s)${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: needs-human-review"
            echo ""
            echo "The planner could not satisfy the critic in $MAX_ROUNDS rounds."
            echo "Review the Plan History and latest critique to decide next steps."
            ;;
        exhausted)
            _sed_i 's/^## Status: .*/## Status: needs-human-review/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Pipeline complete: NEEDS HUMAN REVIEW — critic could not complete in final round"
            echo -e "${YELLOW}Critic could not complete review after $MAX_ROUNDS round(s)${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Status: needs-human-review"
            echo ""
            echo "The critic ran out of turns — the plan was NOT rejected."
            echo "Review the plan and latest partial critique to decide next steps."
            ;;
        error)
            _sed_i 's/^## Status: .*/## Status: pipeline-error/' "$TASK_FILE"
            log_execution "$TASK_FILE" "Pipeline complete: ERROR in round $round"
            echo -e "${RED}Pipeline ERROR in round $round${NC}"
            echo "  Task file: $TASK_FILE"
            echo "  Check logs: $LOG_DIR/"
            ;;
    esac

    echo ""
    echo "Logs: $LOG_DIR/pilot-${SLUG}-*.log"
}

if [ "$LEGACY" = true ]; then
    main_legacy
else
    main_lead
fi

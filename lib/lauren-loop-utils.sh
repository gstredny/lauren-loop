#!/bin/bash
# lib/lauren-loop-utils.sh — Shared utility functions for lauren-loop.sh and lauren-loop-v2.sh
# Sourced (not executed). Expects caller to set: SCRIPT_DIR, color vars (RED, GREEN, YELLOW, BLUE, NC).
# Uses only a minimal helper-state global (_NOTIFIED), plus functions. No traps, no exit calls.

_NOTIFIED="${_NOTIFIED:-0}"

# ============================================================
# Platform shims
# ============================================================

# Platform-portable sed in-place (macOS needs '' arg, GNU does not)
_sed_i() {
    if [[ "$(uname)" == "Linux" ]]; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# Cross-platform ISO 8601 timestamp (macOS stock `date` lacks -Iseconds)
_iso_timestamp() {
    if date -Iseconds &>/dev/null; then
        date -Iseconds
    elif command -v gdate &>/dev/null; then
        gdate -Iseconds
    else
        date -u +"%Y-%m-%dT%H:%M:%S%z"
    fi
}

# Cross-platform timeout wrapper that works for shell functions and piped stdin.
_timeout() {
    local duration="$1"
    shift
    local seconds timeout_flag cmd_pid watchdog_pid exit_code=0
    case "$duration" in
        *m) seconds=$(( ${duration%m} * 60 )) ;;
        *h) seconds=$(( ${duration%h} * 3600 )) ;;
        *s) seconds=${duration%s} ;;
        *)  seconds=$duration ;;
    esac

    timeout_flag=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-timeout.XXXXXX") || return 1
    rm -f "$timeout_flag"

    # Save stdin before backgrounding so shell functions still receive piped input.
    exec 3<&0
    "$@" <&3 3<&- &
    cmd_pid=$!
    exec 3<&-

    (
        sleep "$seconds"
        if kill "$cmd_pid" 2>/dev/null; then
            : > "$timeout_flag"
            sleep 5
            if kill -0 "$cmd_pid" 2>/dev/null; then
                kill -9 "$cmd_pid" 2>/dev/null || true
            fi
        fi
    ) &
    watchdog_pid=$!

    wait "$cmd_pid" 2>/dev/null
    exit_code=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [[ -f "$timeout_flag" ]]; then
        rm -f "$timeout_flag"
        return 124
    fi

    rm -f "$timeout_flag"
    return "$exit_code"
}

notify_terminal_state() {
    local category="$1"
    local message="${2:-Lauren Loop update}"
    local sound_name=""
    local title=""
    local sound_file=""

    [[ "${LAUREN_LOOP_NOTIFY:-0}" == "1" ]] || return 0
    [[ "${_NOTIFIED:-0}" == "0" ]] || return 0

    case "$category" in
        pass)
            sound_name="Glass"
            title="Lauren Loop Passed"
            ;;
        human-review)
            sound_name="Purr"
            title="Human Review Required"
            ;;
        blocked)
            sound_name="Basso"
            title="Lauren Loop Blocked"
            ;;
        interrupted)
            sound_name="Basso"
            title="Lauren Loop Interrupted"
            ;;
        *)
            echo "WARN: Unknown terminal notification category: $category" >&2
            return 1
            ;;
    esac

    _NOTIFIED=1

    command -v afplay >/dev/null 2>&1 || return 0
    command -v osascript >/dev/null 2>&1 || return 0
    sound_file="/System/Library/Sounds/${sound_name}.aiff"
    afplay "$sound_file" 2>/dev/null &
    osascript \
        -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
        -e 'end run' \
        "$message" "$title" 2>/dev/null &
}

# ============================================================
# Cross-version lock awareness (advisory)
# ============================================================

_check_cross_version_lock() {
    local my_version="$1"  # "v1" or "v2"
    local my_slug="$2"
    local other_lock other_slug_file other_pid other_slug

    if [[ "$my_version" == "v1" ]]; then
        local v2_dir="${_V2_LOCK_DIR:-/tmp/lauren-loop-v2.lock.d}"
        other_lock="$v2_dir/pid"
        other_slug_file="$v2_dir/slug"
    else
        local v1_file="${_V1_LOCK_FILE:-/tmp/lauren-loop-pilot.lock}"
        other_lock="$v1_file"
        other_slug_file="${v1_file}.slug"
    fi

    [[ -f "$other_lock" ]] || return 0
    other_pid=$(cat "$other_lock" 2>/dev/null)
    kill -0 "$other_pid" 2>/dev/null || return 0

    other_slug=""
    [[ -f "$other_slug_file" ]] && other_slug=$(cat "$other_slug_file" 2>/dev/null)
    [[ -z "$other_slug" ]] && return 0

    if [[ "$other_slug" == "$my_slug" ]]; then
        echo -e "${YELLOW:-}Warning: ${my_version} and the other pipeline are both operating on '${my_slug}' (PID ${other_pid})${NC:-}" >&2
        echo -e "${YELLOW:-}Concurrent modifications to the same task file may cause corruption.${NC:-}" >&2
        return 1
    fi
    return 0
}

# ============================================================
# Section helpers
# ============================================================

same_dir_temp_file() {
    local target_file="$1"
    local target_dir
    target_dir=$(dirname "$target_file")
    mktemp "$target_dir/.lauren-loop.tmp.XXXXXX"
}

# Atomic append: write content to temp file, cat >> target, rm temp.
# Prevents 0-byte appends from shell crashes during printf.
_atomic_append() {
    local target="$1"
    local content="$2"
    local tmp
    tmp=$(same_dir_temp_file "$target") || return 1
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" >> "$target" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# Atomic overwrite: write content to temp file, mv over target.
_atomic_write() {
    local target="$1"
    local content="$2"
    local tmp
    tmp=$(same_dir_temp_file "$target") || return 1
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$target"
}

# Validate agent output: checks file exists, non-empty, valid UTF-8.
# Returns 1 + stderr warning on failure.
_validate_agent_output() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "WARN: Agent output missing: $file" >&2
        return 1
    fi
    if [[ ! -s "$file" ]]; then
        echo "WARN: Agent output empty: $file" >&2
        return 1
    fi
    if command -v file >/dev/null 2>&1; then
        local encoding
        encoding=$(file --mime-encoding -b "$file" 2>/dev/null || true)
        if [[ -n "$encoding" && "$encoding" != "utf-8" && "$encoding" != "us-ascii" && "$encoding" != "ascii" ]]; then
            echo "WARN: Agent output not valid UTF-8 ($encoding): $file" >&2
            return 1
        fi
    fi
    return 0
}

# Write cycle state checkpoint for review/fix loop resumability.
# Usage: _write_cycle_state <comp_dir> <fix_cycle> <last_completed> [<review_verdict>]
_write_cycle_state() {
    local comp_dir="$1" fix_cycle="$2" last_completed="$3" review_verdict="${4:-}"
    command -v jq >/dev/null 2>&1 || return 0
    local state_file="${comp_dir}/.cycle-state.json"
    local tmp
    tmp=$(same_dir_temp_file "$state_file") || return 1
    jq -n \
        --argjson fix_cycle "$fix_cycle" \
        --arg last_completed "$last_completed" \
        --arg review_verdict "$review_verdict" \
        --arg timestamp "$(_iso_timestamp)" \
        '{
            fix_cycle: $fix_cycle,
            last_completed: $last_completed,
            review_verdict: (if $review_verdict == "" then null else $review_verdict end),
            timestamp: $timestamp
        }' > "$tmp" && mv "$tmp" "$state_file" || { rm -f "$tmp"; return 1; }
}

# Read cycle state checkpoint. Sets globals:
#   CYCLE_STATE_FIX_CYCLE, CYCLE_STATE_LAST_COMPLETED, CYCLE_STATE_REVIEW_VERDICT
# Returns 1 if no state file.
_read_cycle_state() {
    local comp_dir="$1"
    local state_file="${comp_dir}/.cycle-state.json"
    [[ -f "$state_file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    CYCLE_STATE_FIX_CYCLE=$(jq -r '.fix_cycle // 0' "$state_file" 2>/dev/null) || return 1
    [[ "$CYCLE_STATE_FIX_CYCLE" =~ ^[0-9]+$ ]] || return 1
    CYCLE_STATE_LAST_COMPLETED=$(jq -r '.last_completed // empty' "$state_file" 2>/dev/null) || return 1
    CYCLE_STATE_REVIEW_VERDICT=$(jq -r '.review_verdict // empty' "$state_file" 2>/dev/null) || true
    [[ -n "$CYCLE_STATE_LAST_COMPLETED" ]] || return 1
    return 0
}

section_bounds() {
    local task_file="$1"
    local header="$2"

    local matches
    matches=$(grep -n -F -x "$header" "$task_file" | cut -d: -f1)
    local count
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')

    # FRAGILE: Case-insensitive fallback for heading variations. Full fix: Phase C, Item 20.
    if [ "$count" -eq 0 ]; then
        matches=$(grep -in -F -x "$header" "$task_file" | cut -d: -f1)
        count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
        if [ "$count" -eq 1 ]; then
            echo "WARN: section_bounds: case-insensitive match for '$header'" >&2
        fi
    fi

    if [ "$count" -eq 0 ]; then
        local normalized_header normalized_matches
        normalized_header=$(printf '%s\n' "$header" | sed -E 's/^[[:space:]#]+//; s/[[:space:]]+$//')
        normalized_matches=$(awk -v target="$normalized_header" '
            {
                line = $0
                sub(/^[[:space:]#]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                if (tolower(line) == tolower(target)) {
                    print NR
                }
            }
        ' "$task_file")
        matches="$normalized_matches"
        count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
        if [ "$count" -eq 1 ]; then
            echo "WARN: section_bounds: matched heading via normalized fallback for '$header'" >&2
        fi
    fi

    if [ "$count" -ne 1 ]; then
        echo "Expected exactly one section: $header" >&2
        return 1
    fi

    local start
    start=$(printf '%s\n' "$matches")
    local end
    end=$(awk -v start="$start" 'NR > start && /^## / { print NR; exit }' "$task_file")
    if [ -z "$end" ]; then
        end=$(( $(wc -l < "$task_file") + 1 ))
    fi

    printf '%s %s\n' "$start" "$end"
}

# GAP (m4): Returns 0 with no output for both empty and missing sections.
# Callers that need to distinguish should check section_bounds directly.
section_body() {
    local task_file="$1"
    local header="$2"
    local start end

    read -r start end < <(section_bounds "$task_file" "$header") || return 1
    if [ $((end - start)) -le 1 ]; then
        return 0
    fi
    sed -n "$((start + 1)),$((end - 1))p" "$task_file"
}

section_has_nonblank_content() {
    local task_file="$1"
    local header="$2"
    section_body "$task_file" "$header" | grep -q '[^[:space:]]'
}

rewrite_section() {
    local task_file="$1"
    local header="$2"
    local replacement_file="$3"
    local start end tmp_file

    read -r start end < <(section_bounds "$task_file" "$header") || return 1
    tmp_file=$(same_dir_temp_file "$task_file")

    awk -v start="$start" -v end="$end" -v replacement="$replacement_file" '
        NR == start {
            print
            while ((getline line < replacement) > 0) {
                print line
            }
            close(replacement)
            next
        }
        NR > start && NR < end { next }
        { print }
    ' "$task_file" > "$tmp_file"

    mv "$tmp_file" "$task_file"
}

# ============================================================
# Task file ops
# ============================================================

log_execution() {
    local task_file="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local entry="- [$timestamp] $message"

    # Prefer an explicit Execution Log section, but fall back to Attempts for
    # canonical task files that do not carry V1/V2 sidecar sections.
    local log_start
    log_start=$(grep -n '^## Execution Log' "$task_file" | head -1 | cut -d: -f1)
    if [ -z "$log_start" ]; then
        log_start=$(grep -n '^## Attempts:' "$task_file" | head -1 | cut -d: -f1)
    fi
    if [ -n "$log_start" ]; then
        local tmp_file
        tmp_file=$(mktemp)
        echo "$entry" > "$tmp_file"
        _sed_i "$((log_start))r $tmp_file" "$task_file"
        rm -f "$tmp_file"
    fi
}

set_task_status() {
    local task_file="$1"
    local status="$2"

    if ! _task_status_is_allowed "$status"; then
        echo "Invalid workflow status: $status" >&2
        return 1
    fi

    _sed_i "s/^## Status: .*/## Status: $status/" "$task_file"
}

_task_status_is_allowed() {
    case "$1" in
        "not started"|"not-started"|"in progress"|"blocked"|"needs verification"|"closed"| \
        "planned"|"lead-running"|planning-round-*|"plan-approved"|"plan-failed"| \
        "executing"|"executed"|"execution-blocked"|"execution-failed"| \
        "reviewing"|"review-passed"|"review-findings-pending"|"review-failed"| \
        "fixing"|"fixed"|"fix-blocked"|"fix-failed"|"paused"|"timed-out"| \
        "needs-human-review"|"pipeline-error")
            return 0
            ;;
    esac
    return 1
}

latest_execution_log_entry() {
    local task_file="$1"
    if grep -q '^## Execution Log' "$task_file"; then
        section_body "$task_file" "## Execution Log" 2>/dev/null | sed -n '/^- \[/ { p; q; }'
    else
        section_body "$task_file" "## Attempts:" 2>/dev/null | sed -n '/^- \[/ { p; q; }'
    fi
}

prepare_attempt_log() {
    local log_file="$1"
    local phase_name="$2"
    local round_label="${3:-na}"

    mkdir -p "$(dirname "$log_file")"
    touch "$log_file"

    local start_line
    start_line=$(( $(wc -l < "$log_file") + 1 ))
    printf '=== [%s] phase=%s slug=%s round=%s pid=%s ===\n' \
        "$(_iso_timestamp)" "$phase_name" "${SLUG:-}" "$round_label" "$$" >> "$log_file"
    echo "$start_line"
}

attempt_log_contains_max_turns() {
    local log_file="$1"
    local start_line="$2"
    tail -n +"$start_line" "$log_file" | grep -q 'Reached max turns'
}

# ============================================================
# Per-agent monitoring / critic loop
# ============================================================

start_agent_monitor() {
    local log_file="$1"
    local task_file="$2"

    stop_agent_monitor

    (
        local last_status=""
        local last_exec_entry=""
        while true; do
            local status
            status=$(grep '^## Status:' "$task_file" 2>/dev/null | head -1 | sed 's/^## Status: //' | tr -d '\r')
            if [ -n "$status" ] && [ "$status" != "$last_status" ]; then
                case "$status" in
                    in\ progress)
                        echo -e "  ${BLUE}▸ Status: in progress${NC}" ;;
                    needs\ verification)
                        echo -e "  ${GREEN}▸ Status: needs verification${NC}" ;;
                    blocked)
                        echo -e "  ${RED}▸ Status: blocked${NC}" ;;
                esac
                last_status="$status"
            fi

            local exec_entry
            exec_entry=$(latest_execution_log_entry "$task_file" | tr -d '\r')
            if [ -n "$exec_entry" ] && [ "$exec_entry" != "$last_exec_entry" ]; then
                case "$exec_entry" in
                    *"FAILED"*|*"failed"*)
                        echo -e "  ${RED}▸ $exec_entry${NC}" ;;
                    *"human review required"*|*"halted"*|*"BLOCKED"*)
                        echo -e "  ${YELLOW}▸ $exec_entry${NC}" ;;
                    *"PASS"*|*"approved"*|*"completed"*|*"captured"*|*"mirrored"*|*"seeded"*)
                        echo -e "  ${GREEN}▸ $exec_entry${NC}" ;;
                    *)
                        echo -e "  ${BLUE}▸ $exec_entry${NC}" ;;
                esac
                last_exec_entry="$exec_entry"
            fi
            sleep 5
        done
    ) &
    local status_pid=$!

    (
        tail -n 0 -F "$log_file" 2>/dev/null | grep --line-buffered -iE \
            'VERDICT:.*EXECUTE|VERDICT:.*BLOCKED|RED:|GREEN:|REFACTOR:|VERIFY:|BLOCKED:|DISPUTED:|pytest.*passed|tests? passed|spawn.*critic' \
        | while IFS= read -r line; do
            if echo "$line" | grep -qi 'VERDICT:.*EXECUTE'; then
                echo -e "  ${GREEN}▸ $line${NC}"
            elif echo "$line" | grep -qi 'VERDICT:.*BLOCKED'; then
                echo -e "  ${YELLOW}▸ $line${NC}"
            elif echo "$line" | grep -q 'RED:'; then
                echo -e "  ${RED}▸ $line${NC}"
            elif echo "$line" | grep -q 'GREEN:'; then
                echo -e "  ${GREEN}▸ $line${NC}"
            elif echo "$line" | grep -q 'REFACTOR:'; then
                echo -e "  ${BLUE}▸ $line${NC}"
            elif echo "$line" | grep -q 'VERIFY:'; then
                echo -e "  ${GREEN}▸ $line${NC}"
            elif echo "$line" | grep -qi 'BLOCKED:'; then
                echo -e "  ${YELLOW}▸ $line${NC}"
            elif echo "$line" | grep -qi 'DISPUTED:'; then
                echo -e "  ${YELLOW}▸ $line${NC}"
            elif echo "$line" | grep -qiE 'pytest.*passed|tests? passed'; then
                echo -e "  ${GREEN}▸ $line${NC}"
            elif echo "$line" | grep -qi 'spawn.*critic'; then
                echo -e "  ${BLUE}▸ $line${NC}"
            fi
        done
    ) &
    local log_pid=$!

    AGENT_MONITOR_PIDS="$status_pid $log_pid"
}

stop_agent_monitor() {
    if [ -z "${AGENT_MONITOR_PIDS:-}" ]; then
        return 0
    fi

    local pid
    for pid in $AGENT_MONITOR_PIDS; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    AGENT_MONITOR_PIDS=""
}

_make_artifact_prompt_copy() {
    local prompt_file="$1"
    local plan_file="$2"
    local critique_file="$3"
    local prompt_copy
    prompt_copy=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-prompt.XXXXXX")

    sed \
        -e "s|competitive/plan-evaluation.md|$plan_file|g" \
        -e "s|competitive/revised-plan.md|$plan_file|g" \
        -e "s|competitive/plan-critique.md|$critique_file|g" \
        "$prompt_file" > "$prompt_copy"

    printf '%s\n' "$prompt_copy"
}

_archive_round_artifact() {
    local src="$1"
    local round="$2"
    local base
    base=$(basename "$src")

    local stem="${base%.*}"
    local ext=""
    if [[ "$base" == *.* ]]; then
        ext=".${base##*.}"
    fi

    local candidate
    candidate="$(dirname "$src")/${stem}-r${round}${ext}"
    if [ ! -e "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    local dup=2
    while true; do
        candidate="$(dirname "$src")/${stem}-r${round}-dup${dup}${ext}"
        if [ ! -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        dup=$((dup + 1))
    done
}

run_critic_loop() {
    local task_file="$1"
    local comp_dir="$2"
    local critic_prompt="$3"
    local reviser_prompt="$4"
    local plan_file="$5"
    local critique_file="$6"
    local max_rounds="$7"
    local role_prefix="$8"
    local halt_status="$9"
    local engine="${10}"

    local round=1
    while [ "$round" -le "$max_rounds" ]; do
        set_task_status "$task_file" "in progress" || return 2
        log_execution "$task_file" "Critic loop ${role_prefix}: round ${round} started"

        local critic_prompt_copy reviser_prompt_copy
        critic_prompt_copy=$(_make_artifact_prompt_copy "$critic_prompt" "$plan_file" "$critique_file") || return 2
        reviser_prompt_copy=$(_make_artifact_prompt_copy "$reviser_prompt" "$plan_file" "$critique_file") || {
            rm -f "$critic_prompt_copy"
            return 2
        }

        local critic_instruction="Read the task file at ${task_file}. Review the current plan at ${plan_file} and write your critique to ${critique_file}. This is critic round ${round}."
        local critic_prompt_body="" critic_sysprompt=""
        if [[ "$engine" == "claude" ]]; then
            critic_sysprompt=$(assemble_prompt_for_engine "$engine" "$critic_prompt_copy") || {
                rm -f "$critic_prompt_copy" "$reviser_prompt_copy"
                return 2
            }
            critic_prompt_body="$critic_instruction"
        else
            critic_prompt_body=$(assemble_prompt_for_engine "$engine" "$critic_prompt_copy" "$critic_instruction") || {
                rm -f "$critic_prompt_copy" "$reviser_prompt_copy"
                return 2
            }
        fi

        local critic_log="${TASK_LOG_DIR:-${comp_dir}}/${role_prefix}-r${round}.log"
        local critic_output="$critique_file"
        rm -f "${critique_file%.*}.contract.json"
        start_agent_monitor "$critic_log" "$task_file"
        local exit_critic=0
        run_agent "${role_prefix}-r${round}" "$engine" "$critic_prompt_body" "$critic_sysprompt" \
            "$critic_output" "$critic_log" "${CRITIC_TIMEOUT:-15m}" "100" || exit_critic=$?
        stop_agent_monitor

        rm -f "$critic_prompt_copy"

        if [ "$exit_critic" -ne 0 ] || [ ! -f "$critique_file" ]; then
            rm -f "$reviser_prompt_copy"
            log_execution "$task_file" "Critic loop ${role_prefix}: critic round ${round} hard-failed (exit ${exit_critic})"
            return 2
        fi

        local verdict=""
        verdict=$(_parse_contract "$critique_file" "verdict")
        if [ -z "$verdict" ]; then
            rm -f "$reviser_prompt_copy"
            log_execution "$task_file" "Critic loop ${role_prefix}: round ${round} missing verdict"
            return 2
        fi
        if ! _critic_verdict_is_consistent "$critique_file" "$verdict"; then
            rm -f "$reviser_prompt_copy"
            log_execution "$task_file" "Critic loop ${role_prefix}: round ${round} returned inconsistent verdict (${verdict})"
            return 2
        fi

        if [[ "$verdict" == "EXECUTE" ]]; then
            rm -f "$reviser_prompt_copy"
            log_execution "$task_file" "Critic loop ${role_prefix}: round ${round} approved"
            return 0
        fi

        if [[ "$verdict" != "BLOCKED" ]]; then
            rm -f "$reviser_prompt_copy"
            log_execution "$task_file" "Critic loop ${role_prefix}: round ${round} returned unexpected verdict (${verdict})"
            return 2
        fi

        if [ "$round" -ge "$max_rounds" ]; then
            rm -f "$reviser_prompt_copy"
            set_task_status "$task_file" "$halt_status" || return 2
            log_execution "$task_file" "Critic loop ${role_prefix}: max rounds reached (${max_rounds})"
            return 1
        fi

        local archived_plan archived_critique
        archived_plan=$(_archive_round_artifact "$plan_file" "$round") || {
            rm -f "$reviser_prompt_copy"
            return 2
        }
        archived_critique=$(_archive_round_artifact "$critique_file" "$round") || {
            rm -f "$reviser_prompt_copy"
            return 2
        }
        cp "$plan_file" "$archived_plan" || {
            rm -f "$reviser_prompt_copy"
            log_execution "$task_file" "Critic loop ${role_prefix}: failed to archive ${plan_file}"
            return 2
        }
        cp "$critique_file" "$archived_critique" || {
            rm -f "$reviser_prompt_copy"
            log_execution "$task_file" "Critic loop ${role_prefix}: failed to archive ${critique_file}"
            return 2
        }

        local reviser_instruction="Read the task file at ${task_file}. Use the critique at ${critique_file} to revise the current plan at ${plan_file}. Write the updated plan back to ${plan_file}. This is critic round ${round}."
        local reviser_prompt_body="" reviser_sysprompt=""
        if [[ "$engine" == "claude" ]]; then
            reviser_sysprompt=$(assemble_prompt_for_engine "$engine" "$reviser_prompt_copy") || {
                rm -f "$reviser_prompt_copy"
                return 2
            }
            reviser_prompt_body="$reviser_instruction"
        else
            reviser_prompt_body=$(assemble_prompt_for_engine "$engine" "$reviser_prompt_copy" "$reviser_instruction") || {
                rm -f "$reviser_prompt_copy"
                return 2
            }
        fi

        local reviser_log="${TASK_LOG_DIR:-${comp_dir}}/${role_prefix}-reviser-r${round}.log"
        start_agent_monitor "$reviser_log" "$task_file"
        local exit_reviser=0
        run_agent "${role_prefix}-reviser-r${round}" "$engine" "$reviser_prompt_body" "$reviser_sysprompt" \
            "$plan_file" "$reviser_log" "${CRITIC_TIMEOUT:-15m}" "100" || exit_reviser=$?
        stop_agent_monitor

        rm -f "$reviser_prompt_copy"

        if [ "$exit_reviser" -ne 0 ] || [ ! -f "$plan_file" ]; then
            log_execution "$task_file" "Critic loop ${role_prefix}: reviser round ${round} hard-failed (exit ${exit_reviser})"
            return 2
        fi

        log_execution "$task_file" "Critic loop ${role_prefix}: round ${round} revised and continuing"
        round=$((round + 1))
    done

    set_task_status "$task_file" "$halt_status" || return 2
    return 1
}

ensure_sections() {
    local task_file="$1"
    local sections=("## Current Plan" "## Critique" "## Plan History" "## Execution Log")
    for section in "${sections[@]}"; do
        if ! grep -q "^${section}" "$task_file"; then
            printf '\n%s\n' "$section" >> "$task_file"
        fi
    done
}

ensure_review_sections() {
    local task_file="$1"
    local managed_sections=(
        "## Review Findings"
        "## Review Critique"
        "## Fixes Applied"
        "## Review History"
    )
    local missing_sections=()
    local section count

    for section in "${managed_sections[@]}" "## Execution Log"; do
        count=$(grep -n -F -x "$section" "$task_file" | wc -l | tr -d ' ')
        if [ "$count" -gt 1 ]; then
            echo "Expected exactly one section: $section" >&2
            return 1
        fi
        if [ "$count" -eq 0 ] && [ "$section" = "## Execution Log" ]; then
            printf '\n## Execution Log\n' >> "$task_file"
        fi
        if [ "$count" -eq 0 ] && [ "$section" != "## Execution Log" ]; then
            missing_sections+=("$section")
        fi
    done

    if [ "${#missing_sections[@]}" -eq 0 ]; then
        return 0
    fi

    local exec_start tmp_file missing_review_findings missing_review_critique missing_fixes_applied missing_review_history
    exec_start=$(grep -n -F -x '## Execution Log' "$task_file" | cut -d: -f1)
    missing_review_findings=0
    missing_review_critique=0
    missing_fixes_applied=0
    missing_review_history=0
    for section in "${missing_sections[@]}"; do
        case "$section" in
            "## Review Findings") missing_review_findings=1 ;;
            "## Review Critique") missing_review_critique=1 ;;
            "## Fixes Applied") missing_fixes_applied=1 ;;
            "## Review History") missing_review_history=1 ;;
        esac
    done
    tmp_file=$(same_dir_temp_file "$task_file")

    awk -v exec_start="$exec_start" \
        -v missing_review_findings="$missing_review_findings" \
        -v missing_review_critique="$missing_review_critique" \
        -v missing_fixes_applied="$missing_fixes_applied" \
        -v missing_review_history="$missing_review_history" '
        NR == exec_start {
            if (missing_review_findings == 1) {
                print "## Review Findings"
                print ""
            }
            if (missing_review_critique == 1) {
                print "## Review Critique"
                print ""
            }
            if (missing_fixes_applied == 1) {
                print "## Fixes Applied"
                print ""
            }
            if (missing_review_history == 1) {
                print "## Review History"
                print ""
            }
        }
        { print }
    ' "$task_file" > "$tmp_file"

    mv "$tmp_file" "$task_file"
}

validate_task_file() {
    local task_file="$1"
    local required_sections=("## Task:" "## Status:" "## Goal:" "## Current Plan" "## Critique" "## Plan History" "## Execution Log")
    local valid=true

    for section in "${required_sections[@]}"; do
        if ! grep -q "^${section}" "$task_file"; then
            echo -e "${RED}Missing section: ${section}${NC}"
            valid=false
        fi
    done

    if [ "$valid" = true ]; then
        return 0
    else
        return 1
    fi
}

inject_context() {
    local task_file="$1"

    # Guard: skip if context was already injected (not just the placeholder)
    if grep -q '## Related Context' "$task_file" && \
       ! grep -A1 '## Related Context' "$task_file" | grep -q '(Auto-injected'; then
        echo -e "${BLUE}Related context already present, skipping injection${NC}"
        return 0
    fi

    local goal_line
    goal_line=$(grep '^## Goal:' "$task_file" | head -1 | sed 's/^## Goal: //')

    # Extract keywords (words > 3 chars, skip common words)
    local keywords
    keywords=$(echo "$goal_line" | tr ' ' '\n' | grep -E '^.{4,}$' | grep -viE '^(this|that|with|from|into|have|been|will|should|could|would|the|and|for|are|but|not|you|all|can|her|was|one|our|out)$' | head -5)

    if [ -z "$keywords" ]; then
        return 0
    fi

    local context=""
    local budget=2000
    local current_len=0

    # Search closed tasks for related work
    for kw in $keywords; do
        if [ "$current_len" -ge "$budget" ]; then
            break
        fi
        local matches
        matches=$(grep -ril "$kw" "$SCRIPT_DIR/docs/tasks/closed/" 2>/dev/null | head -3)
        for match in $matches; do
            local basename
            basename=$(basename "$match")
            local entry="- Closed task: $basename (keyword: $kw)"
            local entry_len=${#entry}
            if [ $((current_len + entry_len)) -lt "$budget" ]; then
                context="${context}\n${entry}"
                current_len=$((current_len + entry_len))
            fi
        done
    done

    # Search RETRO.md for pattern matches
    local retro_file="$SCRIPT_DIR/docs/tasks/RETRO.md"
    if [ -f "$retro_file" ]; then
        for kw in $keywords; do
            if [ "$current_len" -ge "$budget" ]; then
                break
            fi
            local patterns
            patterns=$(grep -i "Pattern:.*$kw" "$retro_file" 2>/dev/null | head -2)
            while IFS= read -r pattern; do
                if [ -n "$pattern" ]; then
                    local entry="- Retro: $pattern"
                    local entry_len=${#entry}
                    if [ $((current_len + entry_len)) -lt "$budget" ]; then
                        context="${context}\n${entry}"
                        current_len=$((current_len + entry_len))
                    fi
                fi
            done <<< "$patterns"
        done
    fi

    # Search open tasks for related work
    for kw in $keywords; do
        if [ "$current_len" -ge "$budget" ]; then
            break
        fi
        local matches
        matches=$(grep -ril "$kw" "$SCRIPT_DIR/docs/tasks/open/" 2>/dev/null | grep -v "pilot-${SLUG}" | head -3)
        for match in $matches; do
            local basename
            basename=$(basename "$match")
            local entry="- Open task: $basename (keyword: $kw)"
            local entry_len=${#entry}
            if [ $((current_len + entry_len)) -lt "$budget" ]; then
                context="${context}\n${entry}"
                current_len=$((current_len + entry_len))
            fi
        done
    done

    if [ -n "$context" ]; then
        # Replace the placeholder content in Related Context
        _sed_i "/^## Related Context$/,/^## /{
            /^## Related Context$/!{
                /^## /!{
                    /^(Auto-injected/d
                }
            }
        }" "$task_file"
        # Insert context after the header
        local context_file
        context_file=$(mktemp)
        echo -e "$context" > "$context_file"
        _sed_i "/^## Related Context$/r $context_file" "$task_file"
        rm -f "$context_file"
        echo -e "${BLUE}Injected related context (${current_len} chars)${NC}"
    else
        echo -e "${YELLOW}No related context found${NC}"
    fi
}

# ============================================================
# Archive/history
# ============================================================

archive_review_cycle() {
    local task_file="$1"
    local findings_body critique_body history_body cycle_num tmp_file
    local findings_file critique_file history_file blank_file

    findings_body=$(section_body "$task_file" "## Review Findings") || return 1
    critique_body=$(section_body "$task_file" "## Review Critique") || return 1

    if ! printf '%s\n%s\n' "$findings_body" "$critique_body" | grep -q '[^[:space:]]'; then
        return 0
    fi

    history_body=$(section_body "$task_file" "## Review History") || return 1
    cycle_num=$(( $(printf '%s\n' "$history_body" | grep -c '^### Review Cycle ' || true) + 1 ))

    findings_file=$(mktemp)
    critique_file=$(mktemp)
    history_file=$(mktemp)
    blank_file=$(mktemp)

    {
        if [ -n "$history_body" ]; then
            printf '%s' "$history_body"
            case "$history_body" in
                *$'\n') ;;
                *) printf '\n' ;;
            esac
            if [ "${history_body##*$'\n'}" != "" ]; then
                printf '\n'
            fi
        fi
        printf '### Review Cycle %s\n\n' "$cycle_num"
        printf '#### Findings\n'
        if [ -n "$findings_body" ]; then
            printf '%s\n' "$findings_body"
        else
            printf '\n'
        fi
        printf '\n#### Critique\n'
        if [ -n "$critique_body" ]; then
            printf '%s\n' "$critique_body"
        else
            printf '\n'
        fi
        printf '%s\n' '---'
    } > "$history_file"

    tmp_file=$(same_dir_temp_file "$task_file")
    awk -v findings_header='## Review Findings' \
        -v critique_header='## Review Critique' \
        -v history_header='## Review History' \
        -v findings_file="$blank_file" \
        -v critique_file="$blank_file" \
        -v history_file="$history_file" '
        function print_file(path,   line) {
            while ((getline line < path) > 0) {
                print line
            }
            close(path)
        }
        /^## / {
            if (current == findings_header) {
                print_file(findings_file)
            } else if (current == critique_header) {
                print_file(critique_file)
            } else if (current == history_header) {
                print_file(history_file)
            }
            current = $0
            print
            next
        }
        {
            if (current == findings_header || current == critique_header || current == history_header) {
                next
            }
            print
        }
        END {
            if (current == findings_header) {
                print_file(findings_file)
            } else if (current == critique_header) {
                print_file(critique_file)
            } else if (current == history_header) {
                print_file(history_file)
            }
        }
    ' "$task_file" > "$tmp_file"

    mv "$tmp_file" "$task_file"
    rm -f "$findings_file" "$critique_file" "$history_file" "$blank_file"
}

archive_round() {
    local task_file="$1"
    local round="$2"

    # Extract Current Plan content (between ## Current Plan and ## Critique)
    local plan_start
    plan_start=$(grep -n '^## Current Plan' "$task_file" | head -1 | cut -d: -f1)
    local critique_start
    critique_start=$(grep -n '^## Critique' "$task_file" | head -1 | cut -d: -f1)
    local history_start
    history_start=$(grep -n '^## Plan History' "$task_file" | head -1 | cut -d: -f1)

    if [ -z "$plan_start" ] || [ -z "$critique_start" ] || [ -z "$history_start" ]; then
        echo -e "${RED}Cannot find required sections for archival${NC}"
        return 1
    fi

    # Extract plan content (lines between headers, excluding header lines)
    local plan_content
    plan_content=$(sed -n "$((plan_start + 1)),$((critique_start - 1))p" "$task_file")
    local critique_content
    critique_content=$(sed -n "$((critique_start + 1)),$((history_start - 1))p" "$task_file")

    # Build archive entry in a temp file
    local archive_file
    archive_file=$(mktemp)
    {
        echo ""
        echo "### Round $round"
        echo ""
        echo "#### Plan"
        echo "$plan_content"
        echo ""
        echo "#### Critique"
        echo "$critique_content"
        echo "---"
    } > "$archive_file"

    # Insert archive entry after ## Plan History header
    _sed_i "/^## Plan History$/r $archive_file" "$task_file"
    rm -f "$archive_file"

    # Clear Current Plan section (replace content between header and next header)
    local tmp_file
    tmp_file=$(mktemp)
    awk -v ps="$plan_start" -v cs="$critique_start" '
        NR == ps { print; print "(Planner writes here)"; next }
        NR > ps && NR < cs { next }
        { print }
    ' "$task_file" > "$tmp_file"

    # Clear Critique section
    # Recalculate line numbers after plan section was modified
    local new_critique_start
    new_critique_start=$(grep -n '^## Critique' "$tmp_file" | head -1 | cut -d: -f1)
    local new_history_start
    new_history_start=$(grep -n '^## Plan History' "$tmp_file" | head -1 | cut -d: -f1)

    local tmp_file2
    tmp_file2=$(mktemp)
    awk -v cs="$new_critique_start" -v hs="$new_history_start" '
        NR == cs { print; print "(Critic writes here)"; next }
        NR > cs && NR < hs { next }
        { print }
    ' "$tmp_file" > "$tmp_file2"

    cp "$tmp_file2" "$task_file"
    rm -f "$tmp_file" "$tmp_file2"

    echo -e "${BLUE}Archived round $round to Plan History${NC}"
}

extract_last_critic_verdict() {
    local task_file="$1"
    section_body "$task_file" "## Review Critique" | grep -i 'VERDICT:' | tail -1 | grep -oiE '(PASS|FAIL)' | tail -1
}

extract_last_review_verdict() {
    local task_file="$1"
    local raw

    raw=$(section_body "$task_file" "## Review Findings" | grep -i 'REVIEW VERDICT:' | tail -1 | grep -oiE '(PASS|CONDITIONAL|FAIL)' | tail -1)
    if [ -z "$raw" ]; then
        raw=$(section_body "$task_file" "## Review Findings" | grep -i '\*\*VERDICT:' | tail -1 | grep -oiE '(PASS|CONDITIONAL|FAIL)' | tail -1)
    fi
    printf '%s\n' "$raw"
}

# Extract a named signal from an agent artifact file.
# Handles plain (SIGNAL: value) and bold-Markdown (**SIGNAL:** value) formats.
# Returns the value from the LAST occurrence. Empty string if not found.
extract_agent_signal() {
    local artifact="$1"
    local signal_name="$2"
    [[ -f "$artifact" ]] || return 0
    grep -iE "^[[:space:]]*\\**${signal_name}:\\**[[:space:]]*" "$artifact" 2>/dev/null \
        | tail -1 \
        | sed 's/\*//g' \
        | sed -E 's/^[[:space:]]*[^:]*:[[:space:]]*//' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

_strict_contract_mode() {
    [[ "${LAUREN_LOOP_STRICT:-false}" == "true" ]]
}

_contract_token_is_allowed() {
    local field="$1"
    local token="$2"

    case "$field" in
        verdict)
            case "$token" in
                PASS|CONDITIONAL|FAIL|EXECUTE|BLOCKED) return 0 ;;
            esac
            ;;
        ready)
            case "$token" in
                yes|no) return 0 ;;
            esac
            ;;
        status)
            case "$token" in
                COMPLETE|BLOCKED) return 0 ;;
            esac
            ;;
    esac
    return 1
}

_normalize_contract_token() {
    local field="$1"
    local raw="$2"
    local normalized=""

    normalized=$(printf '%s' "$raw" \
        | tr -d '\r' \
        | sed 's/\*//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -n "$normalized" ]] || return 0

    case "$field" in
        verdict)
            normalized=$(printf '%s' "$normalized" | sed -E 's/^([^[:space:]]+).*$/\1/')
            normalized=$(printf '%s' "$normalized" | tr '[:lower:]' '[:upper:]')
            if _contract_token_is_allowed "$field" "$normalized"; then
                printf '%s\n' "$normalized"
            fi
            ;;
        ready)
            normalized=$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')
            normalized=$(printf '%s' "$normalized" | sed -E 's/^([a-z]+).*$/\1/')
            case "$normalized" in
                true|yes)
                    normalized="yes"
                    ;;
                false|no)
                    normalized="no"
                    ;;
            esac
            if _contract_token_is_allowed "$field" "$normalized"; then
                printf '%s\n' "$normalized"
            fi
            ;;
        status)
            normalized=$(printf '%s' "$normalized" | tr '[:lower:]' '[:upper:]')
            case "$normalized" in
                BLOCKED|BLOCKED\ *)
                    normalized="BLOCKED"
                    ;;
                COMPLETE|COMPLETE\ *|EXECUTION\ COMPLETE|EXECUTION\ COMPLETE\ *)
                    normalized="COMPLETE"
                    ;;
            esac
            if _contract_token_is_allowed "$field" "$normalized"; then
                printf '%s\n' "$normalized"
            fi
            ;;
        *)
            printf '%s\n' "$normalized"
            ;;
    esac
}

_critic_assessment_count() {
    local critique_file="$1"
    local level="$2"
    awk -v level="$level" '
        BEGIN { IGNORECASE = 1; count = 0 }
        {
            line = $0
            gsub(/\*/, "", line)
            if (line ~ /^[[:space:]]*[0-9]+\.[^:]*:[[:space:]]*/) {
                sub(/^[[:space:]]*[0-9]+\.[^:]*:[[:space:]]*/, "", line)
                upper = toupper(line)
                if (upper ~ ("^" level "([[:space:]-]|$)")) count++
            }
        }
        END { print count + 0 }
    ' "$critique_file"
}

_critic_verdict_is_consistent() {
    local critique_file="$1"
    local verdict="$2"
    local blocking_count concern_count

    [ -f "$critique_file" ] || return 1
    blocking_count=$(_critic_assessment_count "$critique_file" "BLOCKING")
    concern_count=$(_critic_assessment_count "$critique_file" "CONCERN")

    case "$verdict" in
        EXECUTE)
            if [ "$blocking_count" -gt 0 ] || [ "$concern_count" -ge 2 ]; then
                return 1
            fi
            ;;
        BLOCKED)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# Parse a contract field from a JSON sidecar (preferred) or fall back to regex.
# Usage: _parse_contract <artifact_path> <field_name>
_parse_contract() {
    local artifact="$1"
    local field="$2"
    local sidecar="${artifact%.*}.contract.json"
    local raw="" normalized=""

    if [[ -f "$sidecar" ]] && command -v jq >/dev/null 2>&1; then
        raw=$(jq --arg field "$field" 'if has($field) then .[$field] else empty end' -r "$sidecar" 2>/dev/null || true)
        normalized=$(_normalize_contract_token "$field" "$raw")
        if [[ -n "$normalized" ]]; then
            printf '%s\n' "$normalized"
            return 0
        fi
    fi

    if _strict_contract_mode; then
        return 0
    fi

    if [[ "$field" == "verdict" ]]; then
        local sig
        sig=$(extract_agent_signal "$artifact" "VERDICT")
        if [[ -z "$sig" ]]; then
            [[ -f "$artifact" ]] || return 0
            sig=$(grep -i 'VERDICT:' "$artifact" | tail -1 \
                | sed 's/\*//g' \
                | sed -E 's/.*VERDICT:[[:space:]]*(.*)/\1/I')
        fi
        normalized=$(_normalize_contract_token "$field" "$sig")
        [[ -n "$normalized" ]] && printf '%s\n' "$normalized"
    else
        raw=$(extract_agent_signal "$artifact" "$field")
        normalized=$(_normalize_contract_token "$field" "$raw")
        [[ -n "$normalized" ]] && printf '%s\n' "$normalized"
    fi
}

# ============================================================
# Task lifecycle
# ============================================================

ensure_retro_placeholder() {
    local task_stem="$1"
    local retro_file="$SCRIPT_DIR/docs/tasks/RETRO.md"
    local today
    today=$(date +%Y-%m-%d)

    touch "$retro_file"

    if grep -q "### .* Task: ${task_stem}$" "$retro_file" 2>/dev/null; then
        if ! grep -A4 "### .* Task: ${task_stem}$" "$retro_file" | grep -q '_retro pending_'; then
            return 10
        fi
        return 0
    fi

    cat >> "$retro_file" <<EOF

---

### ${today} Task: ${task_stem}
- **What worked:** _retro pending — auto-generation in progress_
- **What broke:** _retro pending_
- **Workflow friction:** _retro pending_
- **Pattern:** _retro pending_
EOF
}

list_superseded_tasks() {
    local task_file="$1"
    local primary_task="$2"
    local open_dir="$SCRIPT_DIR/docs/tasks/open"
    local raw_paths raw_names resolved=()
    local line token candidate

    raw_paths=$(awk '
        BEGIN { IGNORECASE = 1 }
        /supersedes/ {
            line = $0
            while (match(line, /`[^`]+\.md`/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$task_file")

    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        case "$candidate" in
            docs/tasks/open/*.md) resolved+=("$SCRIPT_DIR/$candidate") ;;
            *.md) resolved+=("$open_dir/$(basename "$candidate")") ;;
        esac
    done <<< "$raw_paths"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        line=$(printf '%s' "$line" | sed -E 's/^.*[Ss]upersedes[^:]*:[[:space:]]*//')
        line=$(printf '%s' "$line" | sed -E 's/[[:space:]]*\(.*$//')
        IFS=',' read -r -a tokens <<< "$line"
        for token in "${tokens[@]}"; do
            token=$(printf '%s' "$token" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            token=$(printf '%s' "$token" | sed -E 's/^[`]+|[`]+$//g')
            token=$(printf '%s' "$token" | sed -E 's/[[:space:]]+\(.*$//')
            [ -z "$token" ] && continue
            [[ "$token" == *" "* ]] && continue
            if [ -f "$open_dir/${token}.md" ] && [ -f "$open_dir/pilot-${token}.md" ]; then
                echo "WARNING: ambiguous bare name '$token' matches both ${token}.md and pilot-${token}.md — skipping" >&2
            elif [ -f "$open_dir/${token}.md" ]; then
                resolved+=("$open_dir/${token}.md")
            elif [ -f "$open_dir/pilot-${token}.md" ]; then
                resolved+=("$open_dir/pilot-${token}.md")
            fi
        done
    done < <(grep -i 'supersedes' "$task_file" || true)

    [ "${#resolved[@]}" -eq 0 ] && return 0
    printf '%s\n' "${resolved[@]}" | sed '/^$/d' | awk -v primary="$primary_task" '!seen[$0]++ && $0 != primary'
}

move_task_to_closed() {
    local src="$1"
    local status_value="$2"
    local log_message="$3"
    local closed_dir="$SCRIPT_DIR/docs/tasks/closed"
    local dst

    mkdir -p "$closed_dir"

    if [ ! -f "$src" ]; then
        echo "Task file not found: $src" >&2
        return 1
    fi

    if [[ "$src" == */task.md ]]; then
        local src_dir dst_task backup_dir backup_task
        src_dir=$(dirname "$src")
        dst="$closed_dir/$(basename "$src_dir")"
        dst_task="$dst/task.md"
        backup_dir="${src_dir}.pre-close.bak"
        backup_task="${dst}/task.md.pre-close.bak"

        if [ -e "$dst" ]; then
            echo "Closed task already exists: $dst" >&2
            return 1
        fi

        if [ -d "$src_dir/competitive" ]; then
            local v2_lock_dir="/tmp/lauren-loop-v2.lock.d"
            local v2_lock_pid=""
            if [ -f "$v2_lock_dir/pid" ]; then
                v2_lock_pid=$(tr -d '[:space:]' < "$v2_lock_dir/pid" 2>/dev/null || true)
            fi
            if [[ -n "$v2_lock_pid" ]] && kill -0 "$v2_lock_pid" 2>/dev/null; then
                echo "WARN: closing $src_dir will relocate competitive/ artifacts while lauren-loop-v2.sh PID $v2_lock_pid is active. Verify it is not using this task before continuing." >&2
            else
                echo "WARN: closing $src_dir will relocate competitive/ artifacts to docs/tasks/closed. Verify no V2 session is active before continuing." >&2
            fi
        fi

        mv "$src_dir" "$dst" || return 1
        cp -R "$dst" "$backup_dir" || { mv "$dst" "$src_dir" 2>/dev/null || true; return 1; }
        cp "$dst_task" "$backup_task" || {
            rm -rf "$dst" 2>/dev/null
            mv "$backup_dir" "$src_dir" 2>/dev/null || true
            return 1
        }

        if ! set_task_status "$dst_task" "$status_value"; then
            rm -rf "$dst" 2>/dev/null
            mv "$backup_dir" "$src_dir" 2>/dev/null || true
            echo "Failed to update status after move: $dst_task" >&2
            return 1
        fi

        if ! log_execution "$dst_task" "$log_message"; then
            rm -rf "$dst" 2>/dev/null
            mv "$backup_dir" "$src_dir" 2>/dev/null || true
            echo "Failed to append execution log after close: $dst_task" >&2
            return 1
        fi

        rm -rf "$backup_dir"
        rm -f "$backup_task"
        printf '%s\n' "$dst"
        return 0
    fi

    dst="$closed_dir/$(basename "$src")"

    if [ -e "$dst" ]; then
        echo "Closed task already exists: $dst" >&2
        return 1
    fi

    mv "$src" "$dst" || return 1

    local backup="${dst}.pre-close.bak"
    cp "$dst" "$backup" || { mv "$dst" "$src" 2>/dev/null || true; return 1; }

    if ! set_task_status "$dst" "$status_value"; then
        mv "$backup" "$src" 2>/dev/null || true
        rm -f "$dst" 2>/dev/null
        echo "Failed to update status after move: $dst" >&2
        return 1
    fi

    if ! log_execution "$dst" "$log_message"; then
        mv "$backup" "$src" 2>/dev/null || true
        rm -f "$dst" 2>/dev/null
        echo "Failed to append execution log after close: $dst" >&2
        return 1
    fi

    rm -f "$backup"
    printf '%s\n' "$dst"
}

# ============================================================
# Diff scope
# ============================================================

check_diff_scope() {
    local task_file="$1"
    local before_sha="$2"

    # Skip if no "Files to Modify" section
    if ! grep -q '### Files to Modify\|#### Files to Modify' "$task_file"; then
        return 0
    fi

    # Get changed files
    local changed_files
    changed_files=$(git diff "$before_sha"..HEAD --name-only 2>/dev/null)
    if [ -z "$changed_files" ]; then
        changed_files=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
    fi
    [ -z "$changed_files" ] && return 0

    local changed_count
    changed_count=$(echo "$changed_files" | sort -u | wc -l | tr -d ' ')
    [ "$changed_count" -le 3 ] && return 0

    # Extract expected files from plan (handles two formats):
    #   1. Bold backtick:  **`path/to/file.py`**
    #   2. Table backtick: | `path/to/file.py` |
    local expected_files
    expected_files=$(awk '
        /^###+ Files to Modify/ { found=1; next }
        found && /^###+ / { exit }
        found {
            line = $0
            # Format 1: **`path`**
            while (match(line, /\*\*`[^`]+`\*\*/)) {
                inner = substr(line, RSTART+3, RLENGTH-6)
                print inner
                line = substr(line, RSTART+RLENGTH)
            }
            # Format 2: | `path` | (table cells with backtick paths)
            line = $0
            while (match(line, /`[^`]+`/)) {
                inner = substr(line, RSTART+1, RLENGTH-2)
                # Only print if it looks like a file path (contains / or .)
                if (inner ~ /[\/.]/) print inner
                line = substr(line, RSTART+RLENGTH)
            }
        }
    ' "$task_file" | sort -u)

    if [ -z "$expected_files" ]; then
        echo -e "${YELLOW}[WARN] Found 'Files to Modify' header but couldn't parse any file paths — skipping scope check${NC}"
        return 0
    fi

    # Count matches
    local matched=0 unique_changed
    unique_changed=$(echo "$changed_files" | sort -u)
    while IFS= read -r f; do
        echo "$expected_files" | grep -qF "$f" && matched=$((matched + 1))
    done <<< "$unique_changed"

    local match_pct=$(( (matched * 100) / changed_count ))
    if [ "$match_pct" -lt 50 ]; then
        echo -e "${YELLOW}[WARN] Scope check: $match_pct% of changed files ($matched/$changed_count) in plan${NC}"
        while IFS= read -r f; do
            echo "$expected_files" | grep -qF "$f" || echo "    - $f"
        done <<< "$unique_changed"
        return 1
    fi
    return 0
}

# === CHAOS-CRITIC HELPERS ===

# Extract plan content from task file (between ## Current Plan and next ## header)
_chaos_extract_plan() {
    local task_file="$1"
    sed -n '/^## Current Plan/,/^## [^#]/p' "$task_file" | sed '1d;$d'
}

# Count findings of a given severity in the chaos artifact
_chaos_count_findings() {
    local artifact="$1" severity="$2"
    grep -ci "\\*\\*${severity}:\\*\\*" "$artifact" 2>/dev/null || echo "0"
}

# === END CHAOS-CRITIC ===

# === GOAL-VERIFIER HELPERS ===

# Extract goal text from task file
_verify_extract_goal() {
    local task_file="$1"
    grep '^## Goal:' "$task_file" | head -1 | sed 's/^## Goal: //'
}

# Extract done criteria from task file (lines between ## Done Criteria and next ## header)
_verify_extract_done_criteria() {
    local task_file="$1"
    sed -n '/^## Done Criteria/,/^## [^#]/p' "$task_file" | sed '1d;$d'
}

# Count PASS or FAIL results in verifier output
_verify_count_results() {
    local output_file="$1" result_type="$2"
    grep -c "\\*\\*${result_type}:\\*\\*" "$output_file" 2>/dev/null || echo "0"
}

# Append verification results to task file under ## Verification section
_verify_append_results() {
    local task_file="$1" output_file="$2" pass_count="$3" fail_count="$4"
    local timestamp
    timestamp=$(_iso_timestamp)

    # Remove existing Verification section if present (always last section)
    if grep -q '^## Verification' "$task_file"; then
        local tmp="${task_file}.tmp"
        sed '/^## Verification/,$d' "$task_file" > "$tmp" && mv "$tmp" "$task_file"
    fi

    {
        echo ""
        echo "## Verification"
        echo "Verified: ${timestamp} | PASS: ${pass_count} | FAIL: ${fail_count}"
        echo ""
        cat "$output_file"
    } >> "$task_file"
}

# === END GOAL-VERIFIER ===

# === PLAN-CHECK HELPERS ===

# Extract plan content from task file (between ## Current Plan and next ## header)
_plancheck_extract_plan() {
    local task_file="$1"
    sed -n '/^## Current Plan/,/^## [^#]/p' "$task_file" | sed '1d;$d'
}

# Check if plan content contains XML structure
_plancheck_is_xml() {
    local content="$1"
    echo "$content" | grep -q '<plan\b\|<steps\b\|<step\b\|<wave\b\|<task\b\|<done\b'
}

_plancheck_is_current_xml() {
    local content="$1"
    echo "$content" | grep -q '<wave\b\|<task\b'
}

# Validate XML plan structure — checks for required elements
_plancheck_validate_xml() {
    local content="$1"
    local errors=0
    local task_count wave_open wave_close

    wave_open=$(echo "$content" | grep -c '<wave\b' 2>/dev/null || echo "0")
    wave_close=$(echo "$content" | grep -c '</wave>' 2>/dev/null || echo "0")
    task_count=$(echo "$content" | grep -c '<task\b' 2>/dev/null || echo "0")

    if [ "$wave_open" -eq 0 ]; then
        echo -e "  ${RED}MISSING: <wave> element${NC}"
        errors=$((errors + 1))
    fi
    if [ "$wave_open" != "$wave_close" ]; then
        echo -e "  ${RED}MISMATCH: <wave> open=$wave_open close=$wave_close${NC}"
        errors=$((errors + 1))
    fi
    if [ "$task_count" -eq 0 ]; then
        echo -e "  ${RED}MISSING: <task> elements${NC}"
        errors=$((errors + 1))
    fi

    for tag in task name files action verify done; do
        local open_count close_count
        open_count=$(echo "$content" | grep -c "<${tag}\b" 2>/dev/null || echo "0")
        close_count=$(echo "$content" | grep -c "</${tag}>" 2>/dev/null || echo "0")
        if [ "$open_count" != "$close_count" ]; then
            echo -e "  ${RED}MISMATCH: <${tag}> open=$open_count close=$close_count${NC}"
            errors=$((errors + 1))
        fi
        if [ "$tag" != "task" ] && [ "$task_count" -gt 0 ] && { [ "$open_count" -ne "$task_count" ] || [ "$close_count" -ne "$task_count" ]; }; then
            echo -e "  ${RED}MISSING: each <task> must contain exactly one <${tag}> block${NC}"
            errors=$((errors + 1))
        fi
    done

    while IFS= read -r task_line; do
        [ -z "$task_line" ] && continue
        if ! printf '%s\n' "$task_line" | grep -q 'type="\(auto\|verify\)"'; then
            echo -e "  ${RED}INVALID: unsupported <task type> in '${task_line}'${NC}"
            errors=$((errors + 1))
        fi
    done < <(echo "$content" | grep '<task\b' || true)

    if [ "$errors" -eq 0 ]; then
        echo -e "  ${GREEN}All required XML elements present${NC}"
    fi
    return $errors
}

# === END PLAN-CHECK ===

# === PLANNING-STATE HELPERS ===

# Write a state snapshot to .planning/<slug>.json
_state_write_snapshot() {
    local slug="$1" task_file="$2" status="$3"
    local state_dir="$SCRIPT_DIR/.planning"
    local state_file="${state_dir}/${slug}.json"
    local timestamp git_sha uncommitted_summary

    timestamp=$(_iso_timestamp)
    git_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    uncommitted_summary=$(git diff --stat 2>/dev/null | tail -1 || echo "none")

    cat > "${state_file}.tmp" <<SNAPSHOT_EOF
{
    "slug": "${slug}",
    "previous_status": "${status}",
    "timestamp": "${timestamp}",
    "git_sha": "${git_sha}",
    "uncommitted_changes": "${uncommitted_summary}",
    "task_file": "${task_file}"
}
SNAPSHOT_EOF
    mv "${state_file}.tmp" "$state_file"
}

# Show snapshot contents in human-readable form
_state_show_snapshot() {
    local state_file="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for k, v in d.items():
    print(f'  {k}: {v}')
" "$state_file" 2>/dev/null || cat "$state_file"
    else
        cat "$state_file"
    fi
}

# Read a specific field from the state JSON
_state_read_field() {
    local state_file="$1" field="$2"
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f).get(sys.argv[2], ''))
" "$state_file" "$field" 2>/dev/null
    else
        grep "\"${field}\"" "$state_file" | sed 's/.*: *"\([^"]*\)".*/\1/'
    fi
}

# Show recent execution log entries from task file
_state_show_recent_log() {
    local task_file="$1"
    local log_section
    log_section=$(sed -n '/^## Execution Log/,/^## [^#]/p' "$task_file" | sed '1d;$d' | tail -5)
    if [ -n "$log_section" ]; then
        echo ""
        echo -e "${BLUE}Recent log entries:${NC}"
        echo "$log_section"
    fi
}

# Validate that required artifacts exist for resume
_state_validate_artifacts() {
    local slug="$1" task_file="$2"
    local errors=0

    # Check task file has a plan
    if ! grep -q '^## Current Plan' "$task_file"; then
        echo -e "  ${YELLOW}WARN: No plan section in task file${NC}"
        ((errors++))
    fi

    # Check state file JSON validity
    local state_file="$SCRIPT_DIR/.planning/${slug}.json"
    if [ -f "$state_file" ] && command -v python3 &>/dev/null && ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$state_file" 2>/dev/null; then
        echo -e "  ${RED}INVALID: State file is not valid JSON${NC}"
        ((errors++))
    fi

    # For V1, check log directory exists if task was in-progress
    local log_dir="$SCRIPT_DIR/logs/pilot"
    if [ -d "$log_dir" ]; then
        local log_count
        log_count=$(ls "$log_dir"/pilot-"${slug}"-*.log 2>/dev/null | wc -l | tr -d ' ')
        echo "  Log files: $log_count"
    fi

    return $errors
}

# === END PLANNING-STATE ===

# ============================================================
# Cost Tracking — shared between V1 and V2
# ============================================================

# Pricing rates (per 1M tokens)
OPUS_INPUT_RATE=5.00
OPUS_CACHE_WRITE_RATE=6.25
OPUS_CACHE_READ_RATE=0.50
OPUS_OUTPUT_RATE=25.00
CODEX_INPUT_RATE=2.50
CODEX_OUTPUT_RATE=15.00
COST_CSV_HEADER="timestamp,task,agent_role,engine,model,reasoning_effort,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,cost_usd,duration_sec,exit_code,status"
LEGACY_COST_CSV_HEADER="timestamp,task,agent_role,engine,model,input_tokens,cache_write_tokens,cache_read_tokens,output_tokens,cost_usd,duration_sec,exit_code,status"

_model_name_for_engine() {
    [[ "$1" == "claude" ]] && echo "$MODEL" || echo "$LAUREN_LOOP_CODEX_MODEL"
}

_is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

_is_decimal_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

# _extract_claude_tokens <log_file>
# Returns: input_tokens cache_write_tokens cache_read_tokens output_tokens (space-separated)
_extract_claude_tokens() {
    local log_file="$1"
    if [[ ! -f "$log_file" || ! -s "$log_file" ]]; then
        echo "0 0 0 0"; return 0
    fi
    # Claude stream-json emits multiple assistant events per message (thinking/text/tool_use).
    # Keep only the final usage row for each message.id before summing.
    jq -Rr 'try (
        fromjson
        | select(.type == "assistant" and (.message.id // "") != "" and .message.usage != null)
        | [
            .message.id,
            (.message.usage.input_tokens // 0),
            (.message.usage.cache_creation_input_tokens // 0),
            (.message.usage.cache_read_input_tokens // 0),
            (.message.usage.output_tokens // 0)
          ] | @tsv
      ) // empty' "$log_file" 2>/dev/null \
        | awk -F'\t' '
            {
                input[$1] = $2
                cache_write[$1] = $3
                cache_read[$1] = $4
                output[$1] = $5
            }
            END {
                for (id in input) {
                    i += input[id]
                    cw += cache_write[id]
                    cr += cache_read[id]
                    o += output[id]
                }
                printf "%d %d %d %d\n", i+0, cw+0, cr+0, o+0
            }'
}

# _extract_codex_tokens <prompt_chars> <output_file>
# Returns: estimated_input_tokens 0 0 estimated_output_tokens (space-separated)
_extract_codex_tokens() {
    local prompt_chars="${1:-0}" output_file="${2:-}"
    local input_tokens=$(( prompt_chars / 4 ))
    if [[ ! -f "$output_file" || ! -s "$output_file" ]]; then
        echo "$input_tokens 0 0 0"; return 0
    fi
    local output_chars
    output_chars=$(wc -c < "$output_file")
    echo "$input_tokens 0 0 $(( output_chars / 4 ))"
}

# _calculate_cost <engine> <input_tokens> <cache_write_tokens> <cache_read_tokens> <output_tokens>
# Returns: cost in USD (e.g., 0.1425)
_calculate_cost() {
    local engine="$1" input="$2" cache_write="$3" cache_read="$4" output="$5"
    local cost
    if [[ "$engine" == "claude" ]]; then
        cost=$(echo "scale=4; ($input * $OPUS_INPUT_RATE + $cache_write * $OPUS_CACHE_WRITE_RATE + $cache_read * $OPUS_CACHE_READ_RATE + $output * $OPUS_OUTPUT_RATE) / 1000000" | bc)
    else
        cost=$(echo "scale=4; ($input * $CODEX_INPUT_RATE + $output * $CODEX_OUTPUT_RATE) / 1000000" | bc)
    fi
    # Normalize leading zero: bc outputs ".1234" → "0.1234"
    [[ "$cost" == .* ]] && cost="0$cost"
    [[ -z "$cost" ]] && cost="0.0000"
    echo "$cost"
}

# _format_tokens <n> — human-readable token count (12500 → 12.5K, 1500000 → 1.5M)
_format_tokens() {
    local n="${1:-0}"
    if [[ "$n" -ge 1000000 ]]; then
        printf '%.1fM' "$(echo "scale=1; $n / 1000000" | bc)"
    elif [[ "$n" -ge 1000 ]]; then
        printf '%.1fK' "$(echo "scale=1; $n / 1000" | bc)"
    else
        echo "$n"
    fi
}

_cost_csv_has_data_row() {
    local cost_csv="$1"
    [[ -f "$cost_csv" ]] || return 1
    awk -F',' 'NR > 1 && NF { found=1; exit } END { exit !found }' "$cost_csv"
}

_emit_normalized_cost_rows() {
    local cost_csv="$1"
    tail -n +2 "$cost_csv" 2>/dev/null | awk -F',' -v file="$cost_csv" '
        NF {
            if (NF == 12) {
                print $1 "," $2 "," $3 "," $4 "," $5 ",unknown," $6 "," $7 "," $8 "," $9 "," $10 "," $11 "," $12 ",completed"
            } else if (NF == 13) {
                print $1 "," $2 "," $3 "," $4 "," $5 ",unknown," $6 "," $7 "," $8 "," $9 "," $10 "," $11 "," $12 "," $13
            } else if (NF == 14) {
                print $0
            } else {
                printf "WARN: Skipping malformed cost row in %s: %s\n", file, $0 > "/dev/stderr"
            }
        }'
}

# _archive_legacy_cost_csv <cost_csv>
# Moves legacy-formatted CSVs out of the way before writing the current schema.
_archive_legacy_cost_csv() {
    local cost_csv="$1"
    local archived_csv="${cost_csv%.csv}.legacy-$(date +%Y%m%d%H%M%S).csv"
    mv "$cost_csv" "$archived_csv"
    echo "$archived_csv"
}

# _ensure_cost_csv_header <cost_csv>
# Ensures the current 14-column CSV header exists while preserving known legacy rows.
_ensure_cost_csv_header() {
    local cost_csv="$1"
    if [[ ! -f "$cost_csv" ]]; then
        echo "$COST_CSV_HEADER" > "$cost_csv"
        return 0
    fi

    local header
    header=$(head -n 1 "$cost_csv" 2>/dev/null)
    if [[ "$header" == "$COST_CSV_HEADER" ]]; then
        return 0
    fi

    if [[ "$header" == "$LEGACY_COST_CSV_HEADER" ]]; then
        local tmp_csv
        tmp_csv=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-cost-schema.XXXXXX") || return 1
        printf '%s\n' "$COST_CSV_HEADER" > "$tmp_csv"
        _emit_normalized_cost_rows "$cost_csv" >> "$tmp_csv"
        mv "$tmp_csv" "$cost_csv"
        return 0
    fi

    if [[ "$header" != "$COST_CSV_HEADER" ]]; then
        local archived_csv
        archived_csv=$(_archive_legacy_cost_csv "$cost_csv")
        echo "WARN: Archived unknown cost CSV schema to $archived_csv" >&2
        echo "$COST_CSV_HEADER" > "$cost_csv"
    fi
}

_append_cost_csv_raw_row() {
    local cost_csv="$1" timestamp="$2" task="$3" role="$4" engine="$5" model_name="$6"
    local reasoning_effort="$7" input_tok="$8" cache_write_tok="$9" cache_read_tok="${10}" output_tok="${11}"
    local cost="${12}" duration="${13}" exit_code="${14}" status="${15}"
    _ensure_cost_csv_header "$cost_csv"
    local _row
    _row=$(printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
        "$timestamp" "$task" "$role" "$engine" "$model_name" \
        "$reasoning_effort" "$input_tok" "$cache_write_tok" "$cache_read_tok" "$output_tok" \
        "$cost" "$duration" "$exit_code" "$status")
    _atomic_append "$cost_csv" "$_row"
}

# _append_cost_row <cost_csv> <role> <engine> <start_ts> <exit_code> [<log_file>] [<output_file>] [<prompt_chars>] [<reasoning_effort>]
_append_cost_row() {
    local cost_csv="$1" role="$2" engine="$3" start_ts="$4" exit_code="$5"
    local log_file="${6:-}" output_file="${7:-}" prompt_chars="${8:-0}" reasoning_effort="${9:-n/a}"
    local end_ts=$(date +%s); local duration=$((end_ts - start_ts))
    local model_name
    model_name=$(_model_name_for_engine "$engine")

    # Extract tokens based on engine
    local tokens
    if [[ "$engine" == "claude" ]]; then
        tokens=$(_extract_claude_tokens "$log_file")
    else
        tokens=$(_extract_codex_tokens "$prompt_chars" "$output_file")
    fi
    local input_tok cache_write_tok cache_read_tok output_tok
    read -r input_tok cache_write_tok cache_read_tok output_tok <<< "$tokens"

    local cost
    cost=$(_calculate_cost "$engine" "$input_tok" "$cache_write_tok" "$cache_read_tok" "$output_tok")

    _append_cost_csv_raw_row \
        "$cost_csv" "$(_iso_timestamp)" "${SLUG:-}" "$role" "$engine" "$model_name" \
        "$reasoning_effort" "$input_tok" "$cache_write_tok" "$cache_read_tok" "$output_tok" \
        "$cost" "$duration" "$exit_code" "completed"
}

# _print_cost_summary [<cost_csv>]
# If called with no argument (V2 behavior): merges per-agent CSVs then reads from TASK_LOG_DIR.
# If called with explicit CSV path (V1 behavior): reads that CSV directly.
_print_cost_summary() {
    local cost_csv="${1:-}"
    if [[ -z "$cost_csv" ]]; then
        # V2 behavior: merge then read from TASK_LOG_DIR
        cost_csv="${TASK_LOG_DIR:-/tmp}/cost.csv"
        _merge_cost_csvs || true
    fi
    [[ -f "$cost_csv" ]] || return 0

    local total_cost=0 linear_cost=0 saw_codex=false
    local linear_roles="explorer planner-a plan-critic plan-critic-reviser executor reviewer-a review-evaluator fix-plan-author fix-critic fix-critic-reviser fix-executor"

    echo ""
    echo -e "${BLUE}=== Cost Summary: ${SLUG:-unknown} ===${NC}"

    # Skip header, read CSV rows
    local line_num=0
    while IFS=',' read -r ts task role engine model reasoning in_tok cw_tok cr_tok out_tok cost dur ec status; do
        line_num=$((line_num + 1))
        [[ "$line_num" -eq 1 ]] && continue  # skip header

        if ! _is_nonnegative_integer "$in_tok" || ! _is_nonnegative_integer "$cw_tok" || \
           ! _is_nonnegative_integer "$cr_tok" || ! _is_nonnegative_integer "$out_tok" || \
           ! _is_nonnegative_integer "$dur" || ! _is_decimal_number "$cost"; then
            echo -e "${YELLOW}WARN: Skipping malformed cost row ${line_num} in ${cost_csv}.${NC}" >&2
            continue
        fi

        local total_in=$((in_tok + cw_tok + cr_tok))
        local role_label="${role} (${engine}/${model})"
        if [[ -n "$reasoning" && "$reasoning" != "n/a" && "$reasoning" != "unknown" ]]; then
            role_label="${role} (${engine}/${model}, ${reasoning})"
        fi
        printf '  %-28s $%-8s (%s in / %s out, %ss)\n' \
            "$role_label" "$cost" \
            "$(_format_tokens "$total_in")" "$(_format_tokens "$out_tok")" "$dur"

        total_cost=$(echo "$total_cost + $cost" | bc)
        [[ "$engine" == "codex" ]] && saw_codex=true

        # Strip -rN, -fixN suffixes to get base role for linear matching
        local base_role
        base_role=$(echo "$role" | sed -E 's/-fix[0-9]+//g; s/-r[0-9]+//g')
        for lr in $linear_roles; do
            if [[ "$base_role" == "$lr" ]]; then
                linear_cost=$(echo "$linear_cost + $cost" | bc)
                break
            fi
        done
    done < "$cost_csv"

    # Normalize
    [[ "$total_cost" == .* ]] && total_cost="0$total_cost"
    [[ "$linear_cost" == .* ]] && linear_cost="0$linear_cost"

    local premium
    premium=$(echo "scale=4; $total_cost - $linear_cost" | bc)
    [[ "$premium" == .* ]] && premium="0$premium"

    local pct="0"
    if [[ "$(echo "$linear_cost > 0" | bc)" -eq 1 ]]; then
        pct=$(echo "scale=0; $premium * 100 / $linear_cost" | bc)
    fi

    echo "  ─────────────────────────────────────────"
    printf '  %-28s $%s\n' "Total:" "$total_cost"
    printf '  %-28s ~$%s\n' "Linear equivalent:" "$linear_cost"
    printf '  %-28s +$%s (+%s%%)\n' "Competitive premium:" "$premium" "$pct"
    if [[ "$saw_codex" == true ]]; then
        echo "  Note: Codex token and cost values are estimated from character counts."
    fi
    echo ""
}

# ────────────────────────────────────────────────────────────
# read_v1_total_cost / read_v2_total_cost
# ────────────────────────────────────────────────────────────

read_v1_total_cost() {
    local slug="$1"
    local cost_csv="$LOG_DIR/pilot-${slug}-cost.csv"
    if [[ ! -f "$cost_csv" ]]; then
        echo "N/A"
        return 0
    fi
    _ensure_cost_csv_header "$cost_csv"
    awk -F',' 'NR > 1 && $11 != "" { sum += $11; found = 1 } END { if (found) printf "%.4f", sum + 0; else print "N/A" }' "$cost_csv" 2>/dev/null || echo "N/A"
}

read_v2_total_cost() {
    local slug="$1"
    local cost_csv="$SCRIPT_DIR/docs/tasks/open/${slug}/logs/cost.csv"
    if [ ! -f "$cost_csv" ]; then
        echo "N/A"
        return 0
    fi
    _ensure_cost_csv_header "$cost_csv"
    awk -F',' 'NR > 1 && $11 != "" { sum += $11; found = 1 } END { if (found) printf "%.4f", sum + 0; else print "N/A" }' "$cost_csv" 2>/dev/null || echo "N/A"
}

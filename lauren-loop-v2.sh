#!/bin/bash
# lauren-loop-v2.sh — Competitive Lauren Loop Scaffold
# Runs dual-engine (Claude + Codex) agents in parallel for planning and review,
# with a Lead agent selecting/synthesizing the best outputs.
#
# Usage:
#   ./lauren-loop-v2.sh <slug> "<goal>" [--dry-run] [--model <model>]
#
# Examples:
#   ./lauren-loop-v2.sh test-task "Test the competitive pipeline" --dry-run
#   ./lauren-loop-v2.sh fix-auth "Fix JWT validation in login flow"
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Defaults
DRY_RUN=false
INTERNAL=false
FORCE_RERUN=false
AGENT_SETTINGS='{"disableAllHooks":true}'
## Pricing constants + CSV headers — now in lib/lauren-loop-utils.sh
source "$HOME/.claude/scripts/context-guard.sh"
source "$SCRIPT_DIR/lib/lauren-loop-utils.sh"

# Source project config (optional overrides)
[[ -f "$SCRIPT_DIR/.lauren-loop.conf" ]] && source "$SCRIPT_DIR/.lauren-loop.conf"

# Config-driven project values (fallback defaults if conf doesn't set them)
PROJECT_NAME="${PROJECT_NAME:-AskGeorge}"
TEST_CMD="${TEST_CMD:-.venv/bin/python -m pytest tests/ -x -q}"
LINT_CMD="${LINT_CMD:-.venv/bin/python -m flake8 src/ --count --select=E9,F63,F7,F82 --show-source --statistics}"

# Config-backed defaults
MODEL="${LAUREN_LOOP_MODEL:-opus}"
_raw_strict="${LAUREN_LOOP_STRICT:-false}"
case "$(echo "$_raw_strict" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes) LAUREN_LOOP_STRICT="true" ;;
    false|0|no|"") LAUREN_LOOP_STRICT="false" ;;
    *)
        echo -e "${RED}Invalid LAUREN_LOOP_STRICT value: '${_raw_strict}' (expected true/1/yes or false/0/no)${NC}" >&2
        exit 1
        ;;
esac
unset _raw_strict
LAUREN_LOOP_MAX_COST="${LAUREN_LOOP_MAX_COST:-0}"
LAUREN_LOOP_EFFECTIVE_STRICT="${LAUREN_LOOP_EFFECTIVE_STRICT:-$LAUREN_LOOP_STRICT}"
LAUREN_LOOP_AUTO_STRICT="${LAUREN_LOOP_AUTO_STRICT:-false}"
LAUREN_LOOP_AUTO_STRICT_REASON="${LAUREN_LOOP_AUTO_STRICT_REASON:-}"
LAUREN_LOOP_CODEX_MODEL="${LAUREN_LOOP_CODEX_MODEL:-gpt-5.4}"
LAUREN_LOOP_CODEX_PROFILE_HIGH="${LAUREN_LOOP_CODEX_PROFILE_HIGH:-azure54}"
LAUREN_LOOP_CODEX_PROFILE_MEDIUM="${LAUREN_LOOP_CODEX_PROFILE_MEDIUM:-azure54med}"
CODEX_ARTIFACT_PATH_PLACEHOLDER="__LAUREN_LOOP_ARTIFACT_PATH__"
PROJECT_RULES=$(cat "$SCRIPT_DIR/prompts/project-rules.md" 2>/dev/null || echo "")
[[ -z "$PROJECT_RULES" ]] && echo -e "${YELLOW}WARN: prompts/project-rules.md missing — agents will run without project constraints${NC}"
ENGINE_EXPLORE="${ENGINE_EXPLORE:-claude}"        # Phase 1
ENGINE_PLANNER_A="${ENGINE_PLANNER_A:-claude}"    # Phase 2a
ENGINE_PLANNER_B="${ENGINE_PLANNER_B:-codex}"     # Phase 2b
ENGINE_EVALUATOR="${ENGINE_EVALUATOR:-claude}"    # Phase 3
ENGINE_CRITIC="${ENGINE_CRITIC:-claude}"          # Phase 4
ENGINE_EXECUTOR="${ENGINE_EXECUTOR:-claude}"      # TODO: switch to codex when stream disconnection fix is merged
ENGINE_REVIEWER_A="${ENGINE_REVIEWER_A:-claude}"  # Phase 6a
ENGINE_REVIEWER_B="${ENGINE_REVIEWER_B:-codex}"   # Phase 6b
ENGINE_FIX="${ENGINE_FIX:-claude}"                # TODO: switch to codex when stream disconnection fix is merged
SINGLE_REVIEWER_POLICY="${SINGLE_REVIEWER_POLICY:-synthesis}"
# Timeouts (env-overridable)
EXPLORE_TIMEOUT="${EXPLORE_TIMEOUT:-15m}"
PLANNER_TIMEOUT="${PLANNER_TIMEOUT:-10m}"
EVALUATE_TIMEOUT="${EVALUATE_TIMEOUT:-10m}"
CRITIC_TIMEOUT="${CRITIC_TIMEOUT:-15m}"
EXECUTOR_TIMEOUT="${EXECUTOR_TIMEOUT:-120m}"
REVIEWER_TIMEOUT="${REVIEWER_TIMEOUT:-15m}"
SYNTHESIZE_TIMEOUT="${SYNTHESIZE_TIMEOUT:-10m}"

# Lock
LOCK_DIR="/tmp/lauren-loop-v2.lock.d"
_LOCK_ACQUIRED=false
_CURRENT_TASK_FILE=""
_CURRENT_TASK_LOG_DIR=""
_CLEANUP_V2_RUNNING=false
_CLEANUP_V2_DONE=false
_COST_CEILING_WARNED=false
_COST_CEILING_INTERRUPT_WARNED=false

_v2_task_artifact_dir() {
    printf '%s/docs/tasks/open/%s\n' "$SCRIPT_DIR" "$1"
}

_resolve_v2_task_file() {
    local slug="$1"
    local open_root="$SCRIPT_DIR/docs/tasks/open"
    local task_dir="$(_v2_task_artifact_dir "$slug")"
    local flat_task="${open_root}/${slug}.md"
    local dir_task="${task_dir}/task.md"
    local candidate=""

    if [[ -f "$dir_task" && -f "$flat_task" ]]; then
        echo "ERROR: ambiguous task slug '$slug' matches both $flat_task and $dir_task" >&2
        return 2
    fi

    if [[ -f "$dir_task" ]]; then
        candidate="$dir_task"
    elif [[ -f "$flat_task" ]]; then
        candidate="$flat_task"
    elif [[ -f "${open_root}/pilot-${slug}.md" ]]; then
        candidate="${open_root}/pilot-${slug}.md"
    elif [[ -d "$task_dir" ]]; then
        candidate=$(find "$task_dir" -maxdepth 1 -name "*.md" ! -path "*/competitive/*" ! -path "*/logs/*" | sort | head -1)
    fi

    [[ -n "$candidate" && -f "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}

_require_v2_task_file() {
    local slug="$1"
    local resolved=""
    local resolve_rc=0

    resolved="$(_resolve_v2_task_file "$slug")" || resolve_rc=$?
    case "$resolve_rc" in
        0)
            printf '%s\n' "$resolved"
            return 0
            ;;
        1)
            echo -e "${RED}Task file not found for slug: $slug${NC}" >&2
            return 1
            ;;
        2)
            return 2
            ;;
        *)
            return "$resolve_rc"
            ;;
    esac
}

_consolidate_task_to_dir() {
    local flat_file="$1"
    local task_dir="$2"
    local dir_task="${task_dir}/task.md"

    [[ -f "$flat_file" ]] || return 0
    [[ ! -f "$dir_task" ]] || return 0

    mkdir -p "$task_dir"
    if git ls-files --error-unmatch "$flat_file" &>/dev/null 2>&1; then
        git mv "$flat_file" "$dir_task"
    else
        mv "$flat_file" "$dir_task"
    fi
    echo -e "${GREEN}Consolidated: $(basename "$flat_file") → ${task_dir}/task.md${NC}"
}

_init_run_manifest() {
    local manifest="${comp_dir}/run-manifest.json"
    command -v jq >/dev/null 2>&1 || return 0
    local tmp
    tmp=$(same_dir_temp_file "$manifest") || return 1
    jq -n \
        --arg run_id "$(date +%Y%m%d-%H%M%S)-$$" \
        --arg slug "$slug" \
        --arg goal "$goal" \
        --arg started_at "$(_iso_timestamp)" \
        --arg model "$MODEL" \
        --arg engine_explore "$ENGINE_EXPLORE" \
        --arg engine_planner_a "$ENGINE_PLANNER_A" \
        --arg engine_planner_b "$ENGINE_PLANNER_B" \
        --arg engine_evaluator "$ENGINE_EVALUATOR" \
        --arg engine_executor "$ENGINE_EXECUTOR" \
        --arg engine_reviewer_a "$ENGINE_REVIEWER_A" \
        --arg engine_reviewer_b "$ENGINE_REVIEWER_B" \
        --arg engine_fix "$ENGINE_FIX" \
        --argjson force_rerun "$([ "$FORCE_RERUN" = true ] && echo true || echo false)" \
        '{
            run_id: $run_id,
            slug: $slug,
            goal: $goal,
            started_at: $started_at,
            model: $model,
            engines: {
                explore: $engine_explore,
                planner_a: $engine_planner_a,
                planner_b: $engine_planner_b,
                evaluator: $engine_evaluator,
                executor: $engine_executor,
                reviewer_a: $engine_reviewer_a,
                reviewer_b: $engine_reviewer_b,
                fix: $engine_fix
            },
            force_rerun: $force_rerun,
            phases: []
        }' > "$tmp" && mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

_append_manifest_phase() {
    local phase="$1" name="$2" started_at="$3" completed_at="$4" status="$5"
    local verdict="${6:-}" cost="${7:-}"
    local manifest="${comp_dir}/run-manifest.json"
    command -v jq >/dev/null 2>&1 || return 0
    [[ -f "$manifest" ]] || return 0
    local tmp
    tmp=$(same_dir_temp_file "$manifest") || return 1
    jq --arg phase "$phase" \
       --arg name "$name" \
       --arg started_at "$started_at" \
       --arg completed_at "$completed_at" \
       --arg status "$status" \
       --arg verdict "$verdict" \
       --arg cost "$cost" \
       '.phases += [{
           phase: $phase,
           name: $name,
           started_at: $started_at,
           completed_at: $completed_at,
           status: $status,
           verdict: (if $verdict == "" then null else $verdict end),
           cost: (if $cost == "" then null else $cost end)
       }]' "$manifest" > "$tmp" && mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

_finalize_run_manifest() {
    local final_status="$1" fix_cycles="$2"
    local manifest="${comp_dir}/run-manifest.json"
    command -v jq >/dev/null 2>&1 || return 0
    [[ -f "$manifest" ]] || return 0
    _merge_cost_csvs || true
    local total_cost="0.0000"
    local cost_csv="${TASK_LOG_DIR}/cost.csv"
    if [[ -f "$cost_csv" ]]; then
        total_cost=$(awk -F',' 'NR > 1 && $11 != "" { sum += $11 } END { printf "%.4f", sum + 0 }' "$cost_csv" 2>/dev/null || echo "0.0000")
    fi
    local tmp
    tmp=$(same_dir_temp_file "$manifest") || return 1
    jq --arg completed_at "$(_iso_timestamp)" \
       --arg total_cost_usd "$total_cost" \
       --arg final_status "$final_status" \
       --argjson fix_cycles "$fix_cycles" \
       '. + {
           completed_at: $completed_at,
           total_cost_usd: $total_cost_usd,
           final_status: $final_status,
           fix_cycles: $fix_cycles
       }' "$manifest" > "$tmp" && mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

## _model_name_for_engine — now in lib/lauren-loop-utils.sh

_reasoning_effort_for_engine() {
    local engine="$1" profile="${2:-}"
    if [[ "$engine" != "codex" ]]; then
        echo "n/a"
        return 0
    fi

    case "$profile" in
        "$LAUREN_LOOP_CODEX_PROFILE_MEDIUM") echo "medium" ;;
        "$LAUREN_LOOP_CODEX_PROFILE_HIGH"|"" ) echo "xhigh" ;;
        *) echo "unknown" ;;
    esac
}

_task_auto_strict_reason() {
    local slug="$1" goal="$2"
    local haystack="${slug} ${goal}"

    if printf '%s\n' "$haystack" | grep -Eqi '(^|[^[:alnum:]_])((prod(uction)?[ -]?(cutover|deploy(ment)?|rollout))|(deploy(ment)?)|(cutover))([^[:alnum:]_]|$)'; then
        printf 'deployment or production-cutover keyword in slug/goal\n'
        return 0
    fi

    if printf '%s\n' "$haystack" | grep -Eqi '(^|[^[:alnum:]_])((security)|(secret|secrets)|(credential|credentials)|(key[ -]?vault)|(rbac))([^[:alnum:]_]|$)'; then
        printf 'security-sensitive keyword in slug/goal\n'
        return 0
    fi

    return 1
}

_apply_effective_strict_mode() {
    local slug="$1" goal="$2"
    local auto_reason=""

    LAUREN_LOOP_EFFECTIVE_STRICT="$LAUREN_LOOP_STRICT"
    LAUREN_LOOP_AUTO_STRICT="false"
    LAUREN_LOOP_AUTO_STRICT_REASON=""

    if [[ "$LAUREN_LOOP_STRICT" == "true" ]]; then
        return 0
    fi

    if auto_reason=$(_task_auto_strict_reason "$slug" "$goal"); then
        LAUREN_LOOP_EFFECTIVE_STRICT="true"
        LAUREN_LOOP_AUTO_STRICT="true"
        LAUREN_LOOP_AUTO_STRICT_REASON="$auto_reason"
    fi
}

_codex_attempt_indicates_capacity_failure() {
    local attempt_log="$1"
    [[ -f "$attempt_log" ]] || return 1
    grep -Eqi 'too_many_requests|no_capacity|rate.limit' "$attempt_log"
}

_codex_attempt_indicates_stream_failure() {
    local attempt_log="$1"
    [[ -f "$attempt_log" ]] || return 1
    grep -Eqi 'content_filter' "$attempt_log" && return 1
    _codex_attempt_indicates_capacity_failure "$attempt_log" && return 1
    grep -Eqi 'response\.failed|stream disconnected' "$attempt_log"
}

_codex_attempt_fallback_reason() {
    local attempt_log="$1" exit_code="${2:-1}"
    [[ -f "$attempt_log" ]] || return 1

    if [[ "$exit_code" -eq 2 ]] || _codex_attempt_indicates_capacity_failure "$attempt_log"; then
        printf 'capacity\n'
        return 0
    fi

    if _codex_attempt_indicates_stream_failure "$attempt_log"; then
        printf 'stream\n'
        return 0
    fi

    return 1
}

_codex_attempt_artifact_path() {
    local canonical_file="$1"
    local attempt_number="$2"
    local extension=""
    local stem="$canonical_file"

    if [[ "$canonical_file" == *.* ]]; then
        extension=".${canonical_file##*.}"
        stem="${canonical_file%${extension}}"
    fi

    printf '%s.attempt-%s%s\n' "$stem" "$attempt_number" "$extension"
}

_codex_summary_path_for_log() {
    local role_log="$1"
    printf '%s.summary.txt\n' "${role_log%.log}"
}

_codex_attempt_summary_path() {
    local role_log="$1"
    local attempt_number="$2"
    printf '%s.attempt-%s.summary.txt\n' "${role_log%.log}" "$attempt_number"
}

_codex_prompt_with_artifact_path() {
    local prompt="$1"
    local artifact_path="$2"

    if [[ "$prompt" == *"$CODEX_ARTIFACT_PATH_PLACEHOLDER"* ]]; then
        printf '%s' "${prompt//$CODEX_ARTIFACT_PATH_PLACEHOLDER/$artifact_path}"
    else
        printf '%s' "$prompt"
    fi
}

_codex_attempt_artifact_state() {
    local role="$1"
    local exit_code="$2"
    local artifact_file="$3"

    if _validate_agent_output_for_role "$role" "$artifact_file" >/dev/null 2>&1; then
        if [[ "$exit_code" -eq 0 ]]; then
            printf 'valid\n'
        else
            printf 'complete_fallback\n'
        fi
    else
        printf 'partial_or_invalid\n'
    fi
}

_latest_codex_attempt_artifact() {
    local canonical_file="$1"
    local extension=""
    local stem="$canonical_file"
    local artifact_dir="" artifact_base="" candidate="" attempt_number=""
    local highest_attempt=-1
    local latest_artifact=""

    if [[ "$canonical_file" == *.* ]]; then
        extension=".${canonical_file##*.}"
        stem="${canonical_file%${extension}}"
    fi

    artifact_dir=$(dirname "$canonical_file")
    artifact_base=$(basename "$stem")

    for candidate in "$artifact_dir"/"${artifact_base}.attempt-"*"$extension"; do
        [[ -f "$candidate" ]] || continue
        attempt_number=$(basename "$candidate")
        attempt_number="${attempt_number#${artifact_base}.attempt-}"
        attempt_number="${attempt_number%${extension}}"
        [[ "$attempt_number" =~ ^[0-9]+$ ]] || continue
        if (( attempt_number > highest_attempt )); then
            highest_attempt=$attempt_number
            latest_artifact="$candidate"
        fi
    done

    [[ -n "$latest_artifact" ]] && printf '%s\n' "$latest_artifact"
}

_resolve_live_codex_artifact_candidate() {
    local role="$1"
    local canonical_file="$2"
    local latest_attempt=""

    [[ -n "$canonical_file" ]] || return 1
    if ! _codex_role_uses_tool_written_artifact "$role"; then
        printf '%s\n' "$canonical_file"
        return 0
    fi

    latest_attempt=$(_latest_codex_attempt_artifact "$canonical_file")
    if [[ -n "$latest_attempt" ]]; then
        printf '%s\n' "$latest_attempt"
    else
        printf '%s\n' "$canonical_file"
    fi
}

_run_codex_agent_attempt() {
    local role="$1" profile="$2" prompt="$3" artifact_file="$4" attempt_log="$5" role_log="$6" timeout="$7" summary_file="${8:-}"
    local timeout_flag watcher_flag watcher_pid="" watchdog_pid="" cmd_pid="" exit_code=0
    local codex_output_file="$artifact_file" timeout_seconds=""

    : > "$attempt_log"

    timeout_flag=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-codex-timeout.XXXXXX") || return 1
    watcher_flag=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-codex-watch.XXXXXX") || {
        rm -f "$timeout_flag"
        return 1
    }
    rm -f "$timeout_flag" "$watcher_flag"

    if _codex_role_uses_tool_written_artifact "$role"; then
        [[ "$artifact_file" != "/dev/null" ]] && rm -f "$artifact_file"
        if [[ -z "$summary_file" ]]; then
            summary_file=$(_codex_summary_path_for_log "$role_log")
        fi
        rm -f "$summary_file"
        codex_output_file="$summary_file"
    else
        [[ "$artifact_file" != "/dev/null" ]] && rm -f "$artifact_file"
    fi

    if [[ ${#prompt} -gt 10240 ]]; then
        (
            set -o pipefail
            printf '%s' "$prompt" | codex54_exec_with_guard --profile "$profile" - -o "$codex_output_file" 2>&1 | tee -a "$attempt_log" >> "$role_log"
        ) &
    else
        (
            set -o pipefail
            codex54_exec_with_guard --profile "$profile" "$prompt" \
                -o "$codex_output_file" 2>&1 | tee -a "$attempt_log" >> "$role_log"
        ) &
    fi
    cmd_pid=$!

    if _codex_role_uses_tool_written_artifact "$role"; then
        _watch_codex_artifact_for_static_invalid "$role" "$artifact_file" "$cmd_pid" "$watcher_flag" "$role_log" &
        watcher_pid=$!
    fi

    timeout_seconds=$(_duration_to_seconds "$timeout")
    (
        sleep "$timeout_seconds"
        if kill -0 "$cmd_pid" 2>/dev/null; then
            : > "$timeout_flag"
            _terminate_pid_tree "$cmd_pid"
        fi
    ) &
    watchdog_pid=$!

    wait "$cmd_pid" 2>/dev/null || exit_code=$?

    if [[ -n "$watcher_pid" ]]; then
        kill "$watcher_pid" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
    fi
    if [[ -n "$watchdog_pid" ]]; then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi

    if [[ -f "$timeout_flag" ]]; then
        exit_code=124
    fi
    if [[ -f "$watcher_flag" ]]; then
        exit_code=65
    fi

    rm -f "$timeout_flag" "$watcher_flag"
    return "$exit_code"
}

_enforce_codex_phase_backstop() {
    local pid="$1" role="$2" codex_start_ts="$3" timeout="$4" claude_duration="$5" log_file="$6" artifact_file="${7:-}"
    local timeout_seconds phase_deadline claude_deadline cutoff_epoch poll_interval now live_artifact=""

    (( claude_duration < 1 )) && claude_duration=1
    timeout_seconds=$(_duration_to_seconds "$timeout")
    phase_deadline=$((codex_start_ts + timeout_seconds))
    claude_deadline=$((codex_start_ts + (claude_duration * 2)))
    cutoff_epoch=$phase_deadline
    if (( claude_deadline < cutoff_epoch )); then
        cutoff_epoch=$claude_deadline
    fi
    poll_interval=$(_agent_poll_interval_seconds)

    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        if (( now >= cutoff_epoch )); then
            printf '[codex-backstop] role=%s claude_duration_sec=%s cutoff_epoch=%s\n' \
                "$role" "$claude_duration" "$cutoff_epoch" >> "$log_file"
            _terminate_pid_tree "$pid"
            # TOCTOU guard: process may have completed naturally before TERM arrived
            live_artifact=$(_resolve_live_codex_artifact_candidate "$role" "$artifact_file")
            if [[ -n "$live_artifact" ]] && _validate_agent_output_for_role "$role" "$live_artifact" >/dev/null 2>&1; then
                printf '[codex-backstop] role=%s artifact valid after termination — treating as natural completion\n' \
                    "$role" >> "$log_file"
                if [[ "$live_artifact" != "$artifact_file" ]]; then
                    _atomic_promote_file "$live_artifact" "$artifact_file" || true
                    printf '[codex-attempt-promote] role=%s attempt=%s -> canonical=%s (backstop)\n' \
                        "$role" "$live_artifact" "$artifact_file" >> "$log_file"
                fi
                return 0
            fi
            return 1
        fi
        sleep "$poll_interval"
    done

    return 0
}

_read_pid_file() {
    local pid_file="$1"
    tr -d '[:space:]' < "$pid_file" 2>/dev/null
}

_read_lock_pid() {
    local slug="${1:-$SLUG}"
    _read_pid_file "$LOCK_DIR/$slug/pid"
}

_lock_dir_mtime_epoch() {
    local dir="$1"
    local mtime=""
    mtime=$(stat -f '%m' "$dir" 2>/dev/null) || mtime=$(stat -c '%Y' "$dir" 2>/dev/null) || return 1
    printf '%s\n' "$mtime"
}

_lock_dir_recent_age_seconds() {
    local dir="$1"
    local now=""
    local lock_mtime=0
    now=$(date +%s)
    lock_mtime=$(_lock_dir_mtime_epoch "$dir" 2>/dev/null || echo 0)
    [[ "$lock_mtime" =~ ^[0-9]+$ ]] || return 1
    (( lock_mtime > 0 )) || return 1
    local lock_age=$((now - lock_mtime))
    if (( lock_age < 30 )); then
        printf '%s\n' "$lock_age"
        return 0
    fi
    return 1
}

_warn_dirty_working_tree_files() {
    local dirty_files=""
    command -v git >/dev/null 2>&1 || return 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    dirty_files=$(
        {
            git diff --name-only 2>/dev/null || true
            git diff --cached --name-only 2>/dev/null || true
        } | sort -u
    )
    [[ -n "$dirty_files" ]] || return 0

    echo -e "${YELLOW}Files currently modified in working tree:${NC}"
    echo "$dirty_files" | while read -r f; do echo "  $f"; done
    echo -e "${YELLOW}Parallel instances touching these files may cause git conflicts.${NC}"
}

_finalize_lock_acquisition() {
    local slug_dir="$1"
    if [[ -n "${GOAL:-}" ]]; then
        _atomic_write "$slug_dir/goal" "$GOAL" || return 1
    else
        rm -f "$slug_dir/goal" 2>/dev/null || true
    fi

    _LOCK_ACQUIRED=true
    [[ -n "${SLUG:-}" ]] && { _check_cross_version_lock "v2" "$SLUG" || true; }

    # Show other running V2 instances (if any)
    local others=""
    others=$(_list_running_v2_instances | grep -v "^${SLUG}	" || true)
    if [[ -n "$others" ]]; then
        echo -e "${YELLOW}Other V2 instances currently running:${NC}"
        while IFS=$'\t' read -r other_slug other_pid other_goal; do
            echo -e "  ${BLUE}${other_slug}${NC} (PID ${other_pid}) - ${other_goal:-<no goal>}"
        done <<< "$others"
    fi

    _warn_dirty_working_tree_files
}

_claim_stale_lock_recovery() {
    local slug_dir="$1"
    local reclaim_dir="$slug_dir/.reclaim"
    local reclaim_pid=""
    local reclaim_age=""
    local claim_attempt

    for claim_attempt in 1 2; do
        if mkdir "$reclaim_dir" 2>/dev/null; then
            if ! _atomic_write "$reclaim_dir/pid" "$$"; then
                rm -rf "$reclaim_dir"
                echo -e "${RED}Failed to initialize stale lock recovery marker at ${reclaim_dir}.${NC}"
                return 1
            fi
            return 0
        fi

        if [[ ! -d "$reclaim_dir" ]]; then
            echo -e "${RED}Failed to claim stale lock recovery at ${reclaim_dir}.${NC}"
            return 1
        fi

        reclaim_pid=$(_read_pid_file "$reclaim_dir/pid")
        if [[ -n "$reclaim_pid" ]] && _process_alive "$reclaim_pid"; then
            echo -e "${YELLOW}Stale lock recovery already in progress for '${SLUG}' (PID $reclaim_pid). Exiting.${NC}"
            return 2
        fi

        reclaim_age=$(_lock_dir_recent_age_seconds "$reclaim_dir" 2>/dev/null || true)
        if [[ "$reclaim_age" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW}Stale lock recovery is still initializing (${reclaim_age}s old). Exiting.${NC}"
            return 2
        fi

        rm -rf "$reclaim_dir" || {
            echo -e "${RED}Failed to remove stale lock recovery marker at ${reclaim_dir}.${NC}"
            return 1
        }
    done

    echo -e "${YELLOW}Another process claimed stale lock recovery for '${SLUG}'. Exiting.${NC}"
    return 2
}

acquire_lock() {
    if [ "$INTERNAL" = true ]; then
        return 0  # Parent holds the lock
    fi

    if [[ "$SLUG" == */* ]]; then
        printf 'ERROR: SLUG contains / - this is not supported\n' >&2
        exit 1
    fi

    local slug_dir="$LOCK_DIR/$SLUG"
    local reclaim_dir="$slug_dir/.reclaim"

    # Create parent dir (non-exclusive; safe for concurrent instances)
    mkdir -p "$LOCK_DIR" 2>/dev/null || true

    local attempt
    for attempt in 1 2; do
        # Atomic per-slug lock via mkdir
        if mkdir "$slug_dir" 2>/dev/null; then
            if ! _atomic_write "$slug_dir/pid" "$$"; then
                rm -rf "$slug_dir"
                echo -e "${RED}Failed to initialize lauren-loop-v2 lock at ${slug_dir}.${NC}"
                return 1
            fi
            if ! _finalize_lock_acquisition "$slug_dir"; then
                rm -rf "$slug_dir"
                echo -e "${RED}Failed to finalize lauren-loop-v2 lock at ${slug_dir}.${NC}"
                return 1
            fi

            return 0
        fi

        if [[ ! -d "$slug_dir" ]]; then
            echo -e "${RED}Failed to acquire lauren-loop-v2 lock at ${slug_dir}.${NC}"
            exit 1
        fi

        # Slug dir exists — check if owner is alive
        local lock_pid=""
        lock_pid=$(_read_lock_pid "$SLUG")
        if [[ -n "$lock_pid" ]] && _process_alive "$lock_pid"; then
            echo -e "${RED}Already running '${SLUG}' (PID $lock_pid). Exiting.${NC}"
            return 1
        fi

        # Stale lock recovery
        if [[ -z "$lock_pid" ]]; then
            local lock_age=""
            lock_age=$(_lock_dir_recent_age_seconds "$slug_dir" 2>/dev/null || true)
            if [[ "$lock_age" =~ ^[0-9]+$ ]]; then
                echo -e "${YELLOW}Lock directory is still initializing (${lock_age}s old). Exiting.${NC}"
                return 1
            fi
            echo -e "${YELLOW}Stale lock directory found (${slug_dir}; PID missing after initialization window). Reclaiming.${NC}"
        else
            echo -e "${YELLOW}Stale lock directory found (${slug_dir}; PID ${lock_pid} not running). Reclaiming.${NC}"
        fi

        local reclaim_rc=0
        _claim_stale_lock_recovery "$slug_dir" || reclaim_rc=$?
        if [[ "$reclaim_rc" -ne 0 ]]; then
            if [[ "$reclaim_rc" -eq 2 ]]; then
                return 1
            fi
            echo -e "${RED}Failed to claim stale lock directory at ${slug_dir}.${NC}"
            return 1
        fi

        local verified_pid=""
        if _atomic_write "$slug_dir/pid" "$$"; then
            verified_pid=$(_read_lock_pid "$SLUG")
            if [[ "$verified_pid" == "$$" ]]; then
                rm -rf "$reclaim_dir"
                if ! _finalize_lock_acquisition "$slug_dir"; then
                    rm -rf "$slug_dir"
                    echo -e "${RED}Failed to finalize reclaimed lauren-loop-v2 lock at ${slug_dir}.${NC}"
                    return 1
                fi
                return 0
            fi

            rm -rf "$reclaim_dir"
            echo -e "${YELLOW}Another process won stale lock recovery for '${SLUG}'. Exiting.${NC}"
            return 1
        fi

        echo -e "${YELLOW}Stale lock directory could not rewrite ${slug_dir}/pid. Recreating lock directory.${NC}"
        rm -rf "$slug_dir" || {
            echo -e "${RED}Failed to remove unrecoverable stale lock directory at ${slug_dir}.${NC}"
            return 1
        }

        if mkdir "$slug_dir" 2>/dev/null; then
            if _atomic_write "$slug_dir/pid" "$$"; then
                if ! _finalize_lock_acquisition "$slug_dir"; then
                    rm -rf "$slug_dir"
                    echo -e "${RED}Failed to finalize recreated lauren-loop-v2 lock at ${slug_dir}.${NC}"
                    return 1
                fi
                return 0
            fi

            rm -rf "$slug_dir"
        fi
    done

    echo -e "${RED}Failed to acquire lauren-loop-v2 lock after stale-lock recovery.${NC}"
    return 1
}

release_lock() {
    [[ "$_LOCK_ACQUIRED" == true ]] || return 0
    [[ "$INTERNAL" == true ]] && return 0

    local slug_dir="$LOCK_DIR/$SLUG"
    [[ -d "$slug_dir" ]] || {
        _LOCK_ACQUIRED=false
        return 0
    }

    local lock_pid=""
    lock_pid=$(_read_lock_pid "$SLUG")
    if [[ "$lock_pid" != "$$" ]]; then
        echo -e "${YELLOW}WARN: Refusing to remove lock at ${slug_dir}; owned by PID ${lock_pid:-unknown}, current PID $$${NC}" >&2
        return 0
    fi

    rm -rf "$slug_dir"
    _LOCK_ACQUIRED=false
}

# Active runtime state
_interrupt_marker_path() {
    printf '%s/.interrupted\n' "${_CURRENT_TASK_LOG_DIR:-${TASK_LOG_DIR:-/tmp}}"
}
_set_interrupt_marker() {
    local marker_path
    marker_path=$(_interrupt_marker_path)
    mkdir -p "$(dirname "$marker_path")"
    : > "$marker_path"
}
_clear_interrupt_marker() {
    rm -f "$(_interrupt_marker_path)"
}
_interrupt_marker_exists() {
    [[ -f "$(_interrupt_marker_path)" ]]
}
_clear_active_runtime_state() {
    local runtime_dir
    runtime_dir=$(_active_agent_meta_dir)
    rm -f "$(_interrupt_marker_path)" "$runtime_dir"/.active-agent.*.meta "$runtime_dir"/.active-agent.tmp.*
}
_list_active_job_pids() {
    jobs -p 2>/dev/null || true
}
_terminate_active_jobs() {
    stop_agent_monitor || true
    local active_jobs
    active_jobs=$(_list_active_job_pids)
    [[ -n "$active_jobs" ]] || return 0

    local p
    for p in $active_jobs; do
        if kill -0 "$p" 2>/dev/null; then
            pkill -P "$p" 2>/dev/null || true
            kill "$p" 2>/dev/null || true
        fi
    done

    sleep 1

    for p in $active_jobs; do
        if kill -0 "$p" 2>/dev/null; then
            pkill -P "$p" 2>/dev/null || true
            kill -9 "$p" 2>/dev/null || true
        fi
    done

    for p in $active_jobs; do
        wait "$p" 2>/dev/null || true
    done
}
_is_terminal_status() {
    local status="$1"
    case "$status" in
        "closed"|"needs verification"|"blocked"|"done"|"not started"|"paused"|"backlog")
            # "done" is defensive — pipeline never sets it, but it's in the existing
            # post-loop safety net and should remain terminal if ever used.
            return 0 ;;
        *"-failed"|*"-blocked"|"pipeline-error"|"timed-out"|"needs-human-review")
            return 0 ;;
        *)
            return 1 ;;
    esac
}
cleanup_v2() {
    if [[ "$_CLEANUP_V2_RUNNING" == true || "$_CLEANUP_V2_DONE" == true ]]; then
        return 0
    fi
    _CLEANUP_V2_RUNNING=true

    # Safety net: if the task is still "in progress" when cleanup runs,
    # something exited without setting a terminal status (e.g. set -e).
    if [[ -n "$_CURRENT_TASK_FILE" && -f "$_CURRENT_TASK_FILE" ]]; then
        local _current_status=""
        _current_status=$(grep '^## Status: ' "$_CURRENT_TASK_FILE" 2>/dev/null | sed 's/^## Status: //' || true)
        if ! _is_terminal_status "$_current_status"; then
            set_task_status "$_CURRENT_TASK_FILE" "blocked" || true
            log_execution "$_CURRENT_TASK_FILE" "cleanup_v2: task was still 'in progress' at exit — set to blocked" || true
        fi
    fi

    _terminate_active_jobs || true
    release_lock || true
    _clear_active_runtime_state || true
    _CLEANUP_V2_RUNNING=false
    _CLEANUP_V2_DONE=true
}
trap cleanup_v2 EXIT

_interrupted() {
    local signal="$1"
    local exit_code=1
    case "$signal" in
        INT) exit_code=130 ;;
        TERM) exit_code=143 ;;
        HUP) exit_code=129 ;;
    esac

    trap '' INT TERM HUP
    echo -e "${YELLOW}Pipeline interrupted (signal ${signal})${NC}"

    if [[ -n "$_CURRENT_TASK_FILE" && -f "$_CURRENT_TASK_FILE" ]]; then
        set_task_status "$_CURRENT_TASK_FILE" "blocked" || true
        log_execution "$_CURRENT_TASK_FILE" "Pipeline interrupted (signal ${signal})" || true
        _set_interrupt_marker || true
        _terminate_active_jobs || true
        _append_interrupted_cost_rows "$signal" || true
        _print_cost_summary || true
        _print_phase_timing || true
    fi

    notify_terminal_state "interrupted" "Pipeline interrupted (${signal}) — ${SLUG:-unknown}" || true
    cleanup_v2 || true
    exit "$exit_code"
}

# Prompt assembly
# assemble_claude_prompt <prompt_file>
assemble_claude_prompt() {
    local prompt_file="$1"
    [[ -f "$prompt_file" ]] || { echo "ERROR: Missing $prompt_file" >&2; return 1; }
    if [[ -n "$PROJECT_RULES" ]]; then
        printf '%s\n\n%s' "$PROJECT_RULES" "$(cat "$prompt_file")"
    else
        cat "$prompt_file"
    fi
}

# assemble_codex_prompt <prompt_file> <task_instruction>
assemble_codex_prompt() {
    local prompt_file="$1" task_instruction="$2"
    [[ -f "$prompt_file" ]] || { echo "ERROR: Missing $prompt_file" >&2; return 1; }
    if [[ -n "$PROJECT_RULES" ]]; then
        printf '%s\n\n---\n\n%s\n\n---\n\n%s' "$PROJECT_RULES" "$(cat "$prompt_file")" "$task_instruction"
    else
        echo "[WARN] PROJECT_RULES is empty — Codex prompt will not include project constraints" >&2
        printf '%s\n\n---\n\n%s' "$(cat "$prompt_file")" "$task_instruction"
    fi
}

# assemble_prompt_for_engine <engine> <prompt_file> [task_instruction]
assemble_prompt_for_engine() {
    local engine="$1" prompt_file="$2" task_instruction="${3:-}"
    case "$engine" in
        claude) assemble_claude_prompt "$prompt_file" ;;
        codex) assemble_codex_prompt "$prompt_file" "$task_instruction" ;;
        *) echo "ERROR: Unknown engine for prompt assembly: $engine" >&2; return 1 ;;
    esac
}


# ============================================================
# run_agent — unified agent invocation
# ============================================================

# run_agent <role> <engine> <prompt> <system_prompt> <output_file> <log_file> <timeout> <max_steps> <disallowed_tools>
run_agent() {
    local role="$1" engine="$2" prompt="$3" system_prompt="$4"
    local output_file="$5" log_file="$6" timeout="${7:-10m}" max_steps="${8:-200}"
    local disallowed_tools="${9:-Bash,WebFetch,WebSearch}"
    local exit_code=0 start_ts=$(date +%s)
    local model_name meta_path="" instance_id="" cost_csv="" reasoning_effort="n/a"

    model_name=$(_model_name_for_engine "$engine")
    if [[ "$engine" == "codex" ]]; then
        reasoning_effort=$(_reasoning_effort_for_engine "$engine" "$LAUREN_LOOP_CODEX_PROFILE_HIGH")
    fi

    mkdir -p "$(dirname "$log_file")" "$(dirname "$output_file")" "$(_active_agent_meta_dir)"
    : > "$log_file"
    meta_path=$(_agent_meta_path "$role") || meta_path=""
    if [[ -z "$meta_path" ]] || ! _write_active_agent_meta "$role" "$engine" "$model_name" "$reasoning_effort" "$start_ts" "$timeout" "running" "$meta_path"; then
        _remove_active_agent_meta "$meta_path"
        echo "ERROR: Failed to record active agent metadata for $role" >&2
        return 1
    fi
    instance_id=$(_agent_instance_id_from_meta_path "$meta_path")
    cost_csv=$(_cost_csv_path_for_instance "$instance_id")

    if [[ "$engine" == "claude" ]]; then
        SKIP_SUMMARY_HOOK=1 _timeout "$timeout" env -u CLAUDECODE claude \
            --settings "$AGENT_SETTINGS" --disable-slash-commands \
            -p "$prompt" --system-prompt "$system_prompt" \
            --model "$MODEL" --max-turns "$max_steps" \
            --dangerously-skip-permissions \
            --disallowedTools "$disallowed_tools" \
            --verbose --output-format stream-json \
            >> "$log_file" 2>&1 || exit_code=$?

    elif [[ "$engine" == "codex" ]]; then
        # Codex file-authoring roles write the real artifact via tool edits. Keep `-o`
        # for the final response summary, but direct it to a separate summary file so
        # it cannot overwrite the real artifact path.
        local codex_profile="$LAUREN_LOOP_CODEX_PROFILE_HIGH"
        local attempt_log=""
        local fallback_backoff=""
        local fallback_reason=""
        local attempt_number=1
        local attempt_output_file="$output_file"
        local attempt_prompt="$prompt"
        local attempt_summary_file=""
        local canonical_summary_file=""
        local attempt_artifact_state="not_applicable"
        local tool_written_artifact=false
        attempt_log=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-codex-attempt.XXXXXX") || {
            _remove_active_agent_meta "$meta_path"
            echo "ERROR: Failed to create Codex attempt log for $role" >&2
            return 1
        }

        if _codex_role_uses_tool_written_artifact "$role"; then
            tool_written_artifact=true
            canonical_summary_file=$(_codex_summary_path_for_log "$log_file")
        fi

        if [[ "$tool_written_artifact" == true ]]; then
            attempt_output_file=$(_codex_attempt_artifact_path "$output_file" "$attempt_number")
            attempt_prompt=$(_codex_prompt_with_artifact_path "$prompt" "$attempt_output_file")
            attempt_summary_file=$(_codex_attempt_summary_path "$log_file" "$attempt_number")
        fi

        if _run_codex_agent_attempt "$role" "$codex_profile" "$attempt_prompt" "$attempt_output_file" "$attempt_log" "$log_file" "$timeout" "$attempt_summary_file"; then
            exit_code=0
        else
            exit_code=$?
        fi

        if [[ "$tool_written_artifact" == true ]]; then
            attempt_artifact_state=$(_codex_attempt_artifact_state "$role" "$exit_code" "$attempt_output_file")
            if [[ "$attempt_artifact_state" != "partial_or_invalid" ]] && \
               ! _atomic_promote_file "$attempt_output_file" "$output_file"; then
                rm -f "$attempt_log"
                _remove_active_agent_meta "$meta_path"
                echo "ERROR: Failed to promote Codex attempt artifact for $role" >&2
                return 1
            fi
            if [[ -n "$attempt_summary_file" && -f "$attempt_summary_file" ]] && \
               ! _atomic_promote_file "$attempt_summary_file" "$canonical_summary_file"; then
                rm -f "$attempt_log"
                _remove_active_agent_meta "$meta_path"
                echo "ERROR: Failed to promote Codex summary artifact for $role" >&2
                return 1
            fi
        fi
        printf '[codex-attempt] role=%s profile=%s reasoning=%s attempt=%s artifact_state=%s artifact=%s\n' \
            "$role" "$codex_profile" "$reasoning_effort" "$attempt_number" "$attempt_artifact_state" "$attempt_output_file" >> "$log_file"

        if [[ "$attempt_artifact_state" == "valid" || "$attempt_artifact_state" == "complete_fallback" ]]; then
            fallback_reason=""
        elif fallback_reason=$(_codex_attempt_fallback_reason "$attempt_log" "$exit_code"); then
            codex_profile="$LAUREN_LOOP_CODEX_PROFILE_MEDIUM"

            for fallback_backoff in 15 30 60; do
                echo "WARN: Codex ${fallback_reason} failure for $role; retrying with profile ${codex_profile} after ${fallback_backoff}s backoff." >> "$log_file"
                sleep "$fallback_backoff"
                reasoning_effort=$(_reasoning_effort_for_engine "$engine" "$codex_profile")
                _set_active_agent_reasoning "$meta_path" "$reasoning_effort" || true
                attempt_number=$((attempt_number + 1))
                attempt_output_file="$output_file"
                attempt_prompt="$prompt"
                attempt_summary_file=""
                attempt_artifact_state="not_applicable"
                if [[ "$tool_written_artifact" == true ]]; then
                    attempt_output_file=$(_codex_attempt_artifact_path "$output_file" "$attempt_number")
                    attempt_prompt=$(_codex_prompt_with_artifact_path "$prompt" "$attempt_output_file")
                    attempt_summary_file=$(_codex_attempt_summary_path "$log_file" "$attempt_number")
                fi

                if _run_codex_agent_attempt "$role" "$codex_profile" "$attempt_prompt" "$attempt_output_file" "$attempt_log" "$log_file" "$timeout" "$attempt_summary_file"; then
                    exit_code=0
                else
                    exit_code=$?
                fi

                if [[ "$tool_written_artifact" == true ]]; then
                    attempt_artifact_state=$(_codex_attempt_artifact_state "$role" "$exit_code" "$attempt_output_file")
                    if [[ "$attempt_artifact_state" != "partial_or_invalid" ]] && \
                       ! _atomic_promote_file "$attempt_output_file" "$output_file"; then
                        rm -f "$attempt_log"
                        _remove_active_agent_meta "$meta_path"
                        echo "ERROR: Failed to promote Codex retry artifact for $role" >&2
                        return 1
                    fi
                    if [[ -n "$attempt_summary_file" && -f "$attempt_summary_file" ]] && \
                       ! _atomic_promote_file "$attempt_summary_file" "$canonical_summary_file"; then
                        rm -f "$attempt_log"
                        _remove_active_agent_meta "$meta_path"
                        echo "ERROR: Failed to promote Codex retry summary for $role" >&2
                        return 1
                    fi
                fi
                printf '[codex-attempt] role=%s profile=%s reasoning=%s attempt=%s artifact_state=%s artifact=%s\n' \
                    "$role" "$codex_profile" "$reasoning_effort" "$attempt_number" "$attempt_artifact_state" "$attempt_output_file" >> "$log_file"

                if [[ "$attempt_artifact_state" == "valid" || "$attempt_artifact_state" == "complete_fallback" ]]; then
                    break
                fi

                if ! fallback_reason=$(_codex_attempt_fallback_reason "$attempt_log" "$exit_code"); then
                    break
                fi
            done
        fi

        rm -f "$attempt_log"
    else
        _remove_active_agent_meta "$meta_path"
        echo "ERROR: Unknown engine: $engine" >&2; return 1
    fi

    _set_active_agent_state "$meta_path" "writing_row" || true
    if _interrupt_marker_exists; then
        return $exit_code
    fi
    _append_cost_row "$cost_csv" "$role" "$engine" "$start_ts" "$exit_code" "$log_file" "$output_file" "${#prompt}" "$reasoning_effort"
    _remove_active_agent_meta "$meta_path"

    return $exit_code
}

## _extract_claude_tokens, _extract_codex_tokens, _calculate_cost,
## _is_nonnegative_integer, _is_decimal_number — now in lib/lauren-loop-utils.sh

_active_agent_meta_dir() {
    printf '%s\n' "${_CURRENT_TASK_LOG_DIR:-${TASK_LOG_DIR:-/tmp}}"
}

_safe_agent_role() {
    local safe_role
    safe_role=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s\n' "$safe_role"
}

_agent_meta_path() {
    local role="$1"
    local safe_role tmp_meta basename instance_suffix meta_path
    safe_role=$(_safe_agent_role "$role")
    tmp_meta=$(mktemp "$(_active_agent_meta_dir)/.active-agent.tmp.XXXXXX") || return 1
    basename="${tmp_meta##*/}"
    instance_suffix="${basename#.active-agent.tmp.}"
    meta_path="$(_active_agent_meta_dir)/.active-agent.${safe_role}.${instance_suffix}.meta"
    if ! mv "$tmp_meta" "$meta_path"; then
        rm -f "$tmp_meta"
        return 1
    fi
    printf '%s\n' "$meta_path"
}

_agent_instance_id_from_meta_path() {
    local meta_path="$1"
    local basename="${meta_path##*/}"
    basename="${basename#.active-agent.}"
    basename="${basename%.meta}"
    printf '%s\n' "$basename"
}

_cost_csv_path_for_instance() {
    local instance_id="$1"
    printf '%s/.cost-%s.csv\n' "$(_active_agent_meta_dir)" "$instance_id"
}

_write_active_agent_meta() {
    local role="$1" engine="$2" model_name="$3" reasoning_effort="$4" start_ts="$5" timeout="$6" state="$7" meta_path="$8"
    local tmp_meta
    tmp_meta=$(mktemp "$(_active_agent_meta_dir)/.active-agent.tmp.XXXXXX") || return 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$role" "$engine" "$model_name" "$reasoning_effort" "$start_ts" "$timeout" "$state" > "$tmp_meta"
    mv "$tmp_meta" "$meta_path"
}

_set_active_agent_state() {
    local meta_path="$1" new_state="$2"
    [[ -f "$meta_path" ]] || return 0

    local role engine model_name reasoning_effort start_ts timeout old_state
    IFS=$'\t' read -r role engine model_name reasoning_effort start_ts timeout old_state < "$meta_path" || return 0
    _write_active_agent_meta "$role" "$engine" "$model_name" "$reasoning_effort" "$start_ts" "$timeout" "$new_state" "$meta_path"
}

_set_active_agent_reasoning() {
    local meta_path="$1" new_reasoning_effort="$2"
    [[ -f "$meta_path" ]] || return 0

    local role engine model_name old_reasoning_effort start_ts timeout state
    IFS=$'\t' read -r role engine model_name old_reasoning_effort start_ts timeout state < "$meta_path" || return 0
    _write_active_agent_meta "$role" "$engine" "$model_name" "$new_reasoning_effort" "$start_ts" "$timeout" "$state" "$meta_path"
}

_remove_active_agent_meta() {
    local meta_path="$1"
    [[ -n "$meta_path" ]] && rm -f "$meta_path"
}

## _cost_csv_has_data_row, _emit_normalized_cost_rows, _append_cost_csv_raw_row — now in lib/lauren-loop-utils.sh

_append_interrupted_cost_rows() {
    local signal="$1"
    local exit_code=1
    local meta_dir
    meta_dir=$(_active_agent_meta_dir)

    case "$signal" in
        INT) exit_code=130 ;;
        TERM) exit_code=143 ;;
        HUP) exit_code=129 ;;
    esac

    local meta_path
    for meta_path in "$meta_dir"/.active-agent.*.meta; do
        [[ -f "$meta_path" ]] || continue

        local instance_id
        instance_id=$(_agent_instance_id_from_meta_path "$meta_path")
        local role engine model_name reasoning_effort start_ts timeout state
        IFS=$'\t' read -r role engine model_name reasoning_effort start_ts timeout state < "$meta_path" || continue
        [[ "$state" == "running" || "$state" == "writing_row" ]] || continue
        _is_nonnegative_integer "$start_ts" || continue

        local cost_csv
        cost_csv=$(_cost_csv_path_for_instance "$instance_id")
        if _cost_csv_has_data_row "$cost_csv"; then
            rm -f "$meta_path"
            continue
        fi
        local duration=$(( $(date +%s) - start_ts ))
        (( duration < 0 )) && duration=0

        _append_cost_csv_raw_row \
            "$cost_csv" "$(_iso_timestamp)" "${SLUG:-}" "$role" "$engine" "$model_name" \
            "$reasoning_effort" "0" "0" "0" "0" "0.0000" "$duration" "$exit_code" "interrupted"
        rm -f "$meta_path"
    done
}

## _archive_legacy_cost_csv, _ensure_cost_csv_header, _append_cost_row — now in lib/lauren-loop-utils.sh

_merge_cost_csvs() {
    local task_log_dir="${TASK_LOG_DIR:-/tmp}"
    local cost_csv="${task_log_dir}/cost.csv"
    local tmp_csv
    local agent_csv
    tmp_csv=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-cost-merge.XXXXXX") || return 1

    _ensure_cost_csv_header "$cost_csv"
    printf '%s\n' "$COST_CSV_HEADER" > "$tmp_csv"

    for agent_csv in "$cost_csv" "$task_log_dir"/.cost-*.csv; do
        [[ -f "$agent_csv" ]] || continue
        _ensure_cost_csv_header "$agent_csv"
    done

    {
        _emit_normalized_cost_rows "$cost_csv" || true
        for agent_csv in "$task_log_dir"/.cost-*.csv; do
            [[ -f "$agent_csv" ]] || continue
            _emit_normalized_cost_rows "$agent_csv" || true
        done
    } | awk 'NF { print }' | sort -t, -k1,1 >> "$tmp_csv"

    mv "$tmp_csv" "$cost_csv"

    for agent_csv in "$task_log_dir"/.cost-*.csv; do
        [[ -f "$agent_csv" ]] || continue
        rm -f "$agent_csv"
    done
}

## _format_tokens, _print_cost_summary — now in lib/lauren-loop-utils.sh

_print_phase_timing() {
    local manifest="${comp_dir:-}/run-manifest.json"
    if [[ -f "$manifest" ]] && command -v jq >/dev/null 2>&1; then
        echo -e "${BLUE}=== Phase Timing ===${NC}"
        jq -r '.phases[]? | "  \(.phase) (\(.name)): \(.status) | \(.started_at) → \(.completed_at)"' "$manifest" 2>/dev/null || true
        echo ""
    fi
}

prepare_agent_request() {
    local engine="$1" prompt_file="$2" instruction="$3"
    AGENT_PROMPT_BODY=""
    AGENT_SYSTEM_PROMPT=""

    if [[ "$engine" == "claude" ]]; then
        AGENT_SYSTEM_PROMPT=$(assemble_prompt_for_engine "$engine" "$prompt_file") || return 1
        AGENT_PROMPT_BODY="$instruction"
    else
        AGENT_PROMPT_BODY=$(assemble_prompt_for_engine "$engine" "$prompt_file" "$instruction") || return 1
    fi
}

_backup_artifacts_on_force() {
    local comp_dir="$1"
    local timestamp backup_dir
    timestamp=$(date '+%Y%m%d-%H%M%S')
    backup_dir="${comp_dir}/backups/force-${timestamp}"
    mkdir -p "$backup_dir"

    local artifact
    for artifact in \
        "$comp_dir"/*.md \
        "$comp_dir"/*.patch \
        "$comp_dir"/*.json \
        "$comp_dir"/.plan-mapping \
        "$comp_dir"/.review-mapping \
        "$comp_dir"/.review-mapping.cycle* \
        "$comp_dir"/.cycle-state.json; do
        [[ -f "$artifact" ]] || continue
        cp "$artifact" "$backup_dir"/
    done
}

_clear_force_artifacts() {
    local comp_dir="$1"
    local task_log_dir="$2"

    rm -f \
        "$comp_dir/exploration-summary.md" \
        "$comp_dir/plan-a.md" \
        "$comp_dir/plan-b.md" \
        "$comp_dir/revised-plan.md" \
        "$comp_dir/plan-evaluation.md" \
        "$comp_dir/plan-critique.md" \
        "$comp_dir/execution-diff.patch" \
        "$comp_dir/review-synthesis.md" \
        "$comp_dir/fix-plan.md" \
        "$comp_dir/fix-critique.md" \
        "$comp_dir/fix-execution.md" \
        "$comp_dir/execution-log.md" \
        "$comp_dir/reviewer-a.raw.md" \
        "$comp_dir/reviewer-b.raw.md" \
        "$comp_dir/review-a.md" \
        "$comp_dir/review-b.md" \
        "$comp_dir"/reviewer-a.raw.cycle*.md \
        "$comp_dir"/reviewer-b.raw.cycle*.md \
        "$comp_dir"/review-a.cycle*.md \
        "$comp_dir"/review-b.cycle*.md \
        "$comp_dir"/plan-b.attempt-*.md \
        "$comp_dir"/reviewer-b.raw.attempt-*.md \
        "$comp_dir/plan-1.md" \
        "$comp_dir/plan-2.md" \
        "$comp_dir/.plan-mapping" \
        "$comp_dir/.review-mapping" \
        "$comp_dir"/.review-mapping.cycle* \
        "$comp_dir/human-review-handoff.md" \
        "$comp_dir/blinding-metadata.log" \
        "$comp_dir/run-manifest.json" \
        "$comp_dir/.cycle-state.json" \
        "$comp_dir/plan-evaluation.contract.json" \
        "$comp_dir/plan-critique.contract.json" \
        "$comp_dir/fix-critique.contract.json" \
        "$comp_dir/review-synthesis.contract.json" \
        "$comp_dir/fix-plan.contract.json" \
        "$comp_dir/fix-execution.contract.json"
    rm -f "$comp_dir"/fix-diff-cycle*.patch
    rm -f "$task_log_dir/cost.csv" "$task_log_dir"/.cost-*.csv "$task_log_dir"/*.summary.txt
}

_log_diagnostic_lines() {
    local task_file="$1" details="$2"
    [[ -n "$details" ]] || return 0

    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        log_execution "$task_file" "  diagnostic: $line" || true
    done <<< "$details"
}

_V2_SCOPE_SOURCE=""
_V2_SCOPE_PATHS=""
_V2_LAST_CAPTURE_SCOPE_SOURCE=""
_V2_LAST_CAPTURE_SCOPE_PATHS=""
_V2_LAST_CAPTURE_ALL_FILES=""
_V2_LAST_CAPTURED_FILES=""
_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES=""
_V2_LAST_CAPTURE_UNTRACKED_FILES=""

_v2_unique_nonblank_lines() {
    awk 'NF && !seen[$0]++'
}

_v2_trim_line() {
    printf '%s\n' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

_v2_normalize_scope_path() {
    local raw="$1"
    raw=$(_v2_trim_line "$raw")
    raw="${raw#./}"
    raw="${raw#\`}"
    raw="${raw%\`}"
    case "$raw" in
        ""|"N/A"|"n/a"|"None"|"none")
            return 1
            ;;
        docs/tasks/open/"${SLUG}"/task.md|\
        docs/tasks/open/"${SLUG}"/competitive/*|\
        docs/tasks/open/"${SLUG}"/logs/*|\
        competitive/*|\
        logs/*)
            return 1
            ;;
    esac
    [[ "$raw" == *"/"* || "$raw" == *"."* ]] || return 1
    printf '%s\n' "$raw"
}

_v2_scope_source_is_constrained() {
    case "$1" in
        plan-files-to-modify|\
        plan-xml-files|\
        task-relevant-files|\
        fallback-commit-range|\
        fallback-commit-range-empty|\
        fallback-head-index|\
        fallback-head-index-empty)
            return 0
            ;;
    esac
    return 1
}

_v2_scope_source_uses_commit_range_only() {
    case "$1" in
        fallback-commit-range|fallback-commit-range-empty)
            return 0
            ;;
    esac
    return 1
}

_v2_scope_source_uses_head_index_only() {
    case "$1" in
        fallback-head-index|fallback-head-index-empty)
            return 0
            ;;
    esac
    return 1
}

_v2_snapshot_dirty_files() {
    {
        git diff --name-only 2>/dev/null || true
        git diff --cached --name-only 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
    } | _v2_unique_nonblank_lines
}

_v2_subtract_preexisting_files() {
    local all_files="$1" pre_exec_dirty="$2" before_sha="${3:-}"
    [[ -n "$all_files" ]] || return 0
    [[ -n "$pre_exec_dirty" ]] || { printf '%s\n' "$all_files"; return 0; }
    local committed_files=""
    if [[ -n "$before_sha" ]]; then
        committed_files=$(git diff "$before_sha"..HEAD --name-only 2>/dev/null || true)
    fi
    local file
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if ! printf '%s\n' "$pre_exec_dirty" | grep -qxF "$file"; then
            printf '%s\n' "$file"
        elif [[ -n "$committed_files" ]] && printf '%s\n' "$committed_files" | grep -qxF "$file"; then
            printf '%s\n' "$file"
        fi
    done <<< "$all_files"
}

_v2_collect_commit_range_changed_files() {
    local before_sha="${1:-}"
    shift || true
    [[ -n "$before_sha" ]] || return 0
    if [[ $# -gt 0 ]]; then
        git diff "$before_sha"..HEAD --name-only -- "$@" 2>/dev/null || true
    else
        git diff "$before_sha"..HEAD --name-only 2>/dev/null || true
    fi
}

_v2_collect_head_index_changed_files() {
    if [[ $# -gt 0 ]]; then
        git diff HEAD --name-only -- "$@" 2>/dev/null || true
        git diff --cached --name-only -- "$@" 2>/dev/null || true
    else
        git diff HEAD --name-only 2>/dev/null || true
        git diff --cached --name-only 2>/dev/null || true
    fi
}

_v2_scope_has_directory_convention_entries() {
    local scope_paths="$1"
    local entry base
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        [[ "$entry" != */ ]] || continue
        [[ "$entry" == */* ]] || continue
        base="${entry##*/}"
        [[ "$base" == *.* ]] && continue
        return 0
    done <<< "$scope_paths"
    return 1
}

_v2_scope_diagnostic_lines() {
    local scope_paths="$1"
    local details=""
    local scope_lines=""
    scope_lines=$(_v2_prefix_lines "scope path" "$scope_paths")
    if [[ -n "$scope_lines" ]]; then
        details="$scope_lines"
    fi
    if _v2_scope_has_directory_convention_entries "$scope_paths"; then
        [[ -n "$details" ]] && details+=$'\n'
        details+="scope note: Directory scope requires trailing /; bare entries are exact-match only."
    fi
    printf '%s\n' "$details"
}

_v2_scope_fallback_warning_message() {
    case "$1" in
        fallback-commit-range)
            printf '%s\n' "Scope unresolved — falling back to committed changes since the pre-phase baseline. Plan should declare Files to Modify."
            ;;
        fallback-commit-range-empty)
            printf '%s\n' "Scope unresolved — no committed changes were found since the pre-phase baseline, so scope is empty. Plan should declare Files to Modify."
            ;;
        fallback-head-index)
            printf '%s\n' "Scope unresolved — falling back to HEAD and staged changes because no pre-phase baseline was available. Plan should declare Files to Modify."
            ;;
        fallback-head-index-empty)
            printf '%s\n' "Scope unresolved — no HEAD or staged changes were found and no pre-phase baseline was available, so scope is empty. Plan should declare Files to Modify."
            ;;
    esac
}

_v2_normalize_scope_paths_from_stream() {
    while IFS= read -r path; do
        _v2_normalize_scope_path "$path" || true
    done | _v2_unique_nonblank_lines
}

_v2_extract_files_to_modify_paths() {
    local source_file="$1"
    [[ -f "$source_file" ]] || return 0
    awk '
        /^##+ Files to Modify/ { found=1; next }
        found && /^##+ / { exit }
        found {
            line = $0
            while (match(line, /\*\*`[^`]+`\*\*/)) {
                inner = substr(line, RSTART + 3, RLENGTH - 6)
                print inner
                line = substr(line, RSTART + RLENGTH)
            }
            line = $0
            while (match(line, /`[^`]+`/)) {
                inner = substr(line, RSTART + 1, RLENGTH - 2)
                if (inner ~ /[\/.]/) print inner
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$source_file" \
        | while IFS= read -r path; do
            _v2_normalize_scope_path "$path" || true
        done \
        | _v2_unique_nonblank_lines
}

_v2_extract_xml_task_paths() {
    local source_file="$1"
    [[ -f "$source_file" ]] || return 0
    awk '
        {
            line = $0
            while (match(line, /<files>[^<]+<\/files>/)) {
                inner = substr(line, RSTART + 7, RLENGTH - 15)
                print inner
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$source_file" \
        | tr ',' '\n' \
        | while IFS= read -r path; do
            _v2_normalize_scope_path "$path" || true
        done \
        | _v2_unique_nonblank_lines
}

_v2_extract_relevant_file_paths() {
    local task_file="$1"
    [[ -f "$task_file" ]] || return 0
    awk '
        /^## Relevant Files:/ { found=1; next }
        found && /^## / { exit }
        found {
            line = $0
            while (match(line, /`[^`]+`/)) {
                inner = substr(line, RSTART + 1, RLENGTH - 2)
                if (inner ~ /[\/.]/) print inner
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$task_file" \
        | while IFS= read -r path; do
            _v2_normalize_scope_path "$path" || true
        done \
        | _v2_unique_nonblank_lines
}

_v2_resolve_scope_paths() {
    local task_file="$1" plan_file="${2:-}" before_sha="${3:-}"
    _V2_SCOPE_SOURCE=""
    _V2_SCOPE_PATHS=""

    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        _V2_SCOPE_PATHS=$(_v2_extract_files_to_modify_paths "$plan_file")
        if [[ -n "$_V2_SCOPE_PATHS" ]]; then
            _V2_SCOPE_SOURCE="plan-files-to-modify"
            return 0
        fi

        _V2_SCOPE_PATHS=$(_v2_extract_xml_task_paths "$plan_file")
        if [[ -n "$_V2_SCOPE_PATHS" ]]; then
            _V2_SCOPE_SOURCE="plan-xml-files"
            return 0
        fi
    fi

    _V2_SCOPE_PATHS=$(_v2_extract_relevant_file_paths "$task_file")
    if [[ -n "$_V2_SCOPE_PATHS" ]]; then
        _V2_SCOPE_SOURCE="task-relevant-files"
        return 0
    fi

    if [[ -n "$before_sha" ]]; then
        _V2_SCOPE_PATHS=$(_v2_collect_commit_range_changed_files "$before_sha" | _v2_normalize_scope_paths_from_stream)
        if [[ -n "$_V2_SCOPE_PATHS" ]]; then
            _V2_SCOPE_SOURCE="fallback-commit-range"
        else
            _V2_SCOPE_SOURCE="fallback-commit-range-empty"
        fi
        return 0
    fi

    _V2_SCOPE_PATHS=$(_v2_collect_head_index_changed_files | _v2_normalize_scope_paths_from_stream)
    if [[ -n "$_V2_SCOPE_PATHS" ]]; then
        _V2_SCOPE_SOURCE="fallback-head-index"
    else
        _V2_SCOPE_SOURCE="fallback-head-index-empty"
    fi
    return 0
}

_v2_scope_entry_matches_path() {
    local entry="$1" path="$2"
    if [[ "$entry" == */ ]]; then
        [[ "$path" == "$entry"* ]]
        return
    fi
    [[ "$path" == "$entry" ]]
}

_v2_path_in_scope() {
    local path="$1" scope_paths="$2"
    local entry
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if _v2_scope_entry_matches_path "$entry" "$path"; then
            return 0
        fi
    done <<< "$scope_paths"
    return 1
}

_v2_collect_changed_files_for_scope() {
    local before_sha="$1" scope_paths="$2" scope_source="${3:-}"
    local -a scope_args=()
    local path
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        scope_args+=("$path")
    done <<< "$scope_paths"

    if _v2_scope_source_uses_commit_range_only "$scope_source"; then
        [[ ${#scope_args[@]} -gt 0 ]] || return 0
        _v2_collect_commit_range_changed_files "$before_sha" "${scope_args[@]}"
        return 0
    fi

    if _v2_scope_source_uses_head_index_only "$scope_source"; then
        [[ ${#scope_args[@]} -gt 0 ]] || return 0
        _v2_collect_head_index_changed_files "${scope_args[@]}"
        return 0
    fi

    if [[ ${#scope_args[@]} -eq 0 ]]; then
        if [[ -n "$before_sha" ]]; then
            git diff "$before_sha"..HEAD --name-only 2>/dev/null || true
        fi
        git diff --name-only 2>/dev/null || true
        git diff --cached --name-only 2>/dev/null || true
        return 0
    fi

    if [[ -n "$before_sha" ]]; then
        git diff "$before_sha"..HEAD --name-only -- "${scope_args[@]}" 2>/dev/null || true
    fi
    git diff --name-only -- "${scope_args[@]}" 2>/dev/null || true
    git diff --cached --name-only -- "${scope_args[@]}" 2>/dev/null || true
}

_v2_collect_all_changed_files_for_source() {
    local before_sha="$1" scope_source="${2:-}"

    if _v2_scope_source_uses_commit_range_only "$scope_source"; then
        _v2_collect_commit_range_changed_files "$before_sha" | _v2_normalize_scope_paths_from_stream
        return 0
    fi

    if _v2_scope_source_uses_head_index_only "$scope_source"; then
        _v2_collect_head_index_changed_files | _v2_normalize_scope_paths_from_stream
        return 0
    fi

    if [[ -n "$before_sha" ]]; then
        git diff "$before_sha"..HEAD --name-only 2>/dev/null || true
    fi
    git diff --name-only 2>/dev/null || true
    git diff --cached --name-only 2>/dev/null || true
}

_v2_write_diff_for_scope_source() {
    local before_sha="$1" diff_file="$2" scope_paths="$3" scope_source="$4"
    local -a scope_args=()
    local path

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        scope_args+=("$path")
    done <<< "$scope_paths"

    if _v2_scope_source_uses_commit_range_only "$scope_source"; then
        if [[ ${#scope_args[@]} -gt 0 && -n "$before_sha" ]]; then
            git diff "$before_sha"..HEAD -- "${scope_args[@]}" > "$diff_file" 2>/dev/null || true
        else
            : > "$diff_file"
        fi
        return 0
    fi

    if _v2_scope_source_uses_head_index_only "$scope_source"; then
        if [[ ${#scope_args[@]} -gt 0 ]]; then
            git diff HEAD -- "${scope_args[@]}" > "$diff_file" 2>/dev/null || true
            git diff --cached -- "${scope_args[@]}" >> "$diff_file" 2>/dev/null || true
        else
            : > "$diff_file"
        fi
        return 0
    fi

    if [[ ${#scope_args[@]} -gt 0 ]]; then
        if [[ -n "$before_sha" ]]; then
            git diff "$before_sha"..HEAD -- "${scope_args[@]}" > "$diff_file" 2>/dev/null || true
        else
            : > "$diff_file"
        fi

        if [[ ! -s "$diff_file" ]]; then
            git diff -- "${scope_args[@]}" > "$diff_file" 2>/dev/null || true
            git diff --cached -- "${scope_args[@]}" >> "$diff_file" 2>/dev/null || true
        fi
        return 0
    fi

    if _v2_scope_source_is_constrained "$scope_source"; then
        : > "$diff_file"
        return 0
    fi

    if [[ -n "$before_sha" ]]; then
        git diff "$before_sha"..HEAD > "$diff_file" 2>/dev/null || true
    else
        : > "$diff_file"
    fi

    if [[ ! -s "$diff_file" ]]; then
        git diff > "$diff_file" 2>/dev/null || true
        git diff --cached >> "$diff_file" 2>/dev/null || true
    fi
}

_v2_collect_out_of_scope_paths() {
    local changed_files="$1" scope_paths="$2"
    local path
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if ! _v2_path_in_scope "$path" "$scope_paths"; then
            printf '%s\n' "$path"
        fi
    done <<< "$changed_files"
}

_v2_prefix_lines() {
    local prefix="$1" content="$2"
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf '%s: %s\n' "$prefix" "$line"
    done <<< "$content"
}

_is_ignored_untracked_path() {
    local path="$1"
    case "$path" in
        "docs/tasks/open/${SLUG}/task.md"|\
        "docs/tasks/open/${SLUG}/competitive/"*|\
        "docs/tasks/open/${SLUG}/logs/"*|\
        .playwright-cli/*|\
        .claude/*|\
        .codex/*|\
        .pytest_cache/*|\
        docs/test-reports/*|\
        *.log)
            return 0
            ;;
    esac
    return 1
}

_v2_collect_untracked_files_for_scope() {
    local scope_paths="$1" scope_source="${2:-}"
    if _v2_scope_source_is_constrained "$scope_source" && [[ -z "$scope_paths" ]]; then
        return 0
    fi

    git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if _is_ignored_untracked_path "$path"; then
            continue
        fi
        if _v2_scope_source_is_constrained "$scope_source" && ! _v2_path_in_scope "$path" "$scope_paths"; then
            continue
        fi
        printf '%s\n' "$path"
    done | _v2_unique_nonblank_lines
}

_v2_append_untracked_file_diffs() {
    local diff_file="$1" untracked_files="$2"
    local diff_path="$diff_file"
    local repo_root=""

    [[ -n "$untracked_files" ]] || return 0
    if [[ "$diff_path" != /* ]]; then
        diff_path="$PWD/$diff_file"
    fi

    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    (
        cd "$repo_root" || exit 0
        local path="" diff_status=0
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            [[ -e "$path" ]] || continue
            [[ -s "$diff_path" ]] && printf '\n' >> "$diff_path"
            diff -u /dev/null "$path" >> "$diff_path" 2>/dev/null
            diff_status=$?
            case "$diff_status" in
                0|1) ;;
                *) exit "$diff_status" ;;
            esac
        done <<< "$untracked_files"
    ) || true
}

_collect_blocking_untracked_files() {
    local task_file="$1" plan_file="${2:-}" before_sha="${3:-}"
    _v2_resolve_scope_paths "$task_file" "$plan_file" "$before_sha" || true
    local scope_paths="$_V2_SCOPE_PATHS"
    local scope_source="$_V2_SCOPE_SOURCE"
    _v2_collect_untracked_files_for_scope "$scope_paths" "$scope_source"
}

_filter_to_preexisting() {
    local current="$1" snapshot="${2:-}"
    # If nothing is currently untracked, nothing to block
    [[ -n "$current" ]] || return 0
    # If snapshot is empty (nothing was untracked pre-execution), nothing is pre-existing
    [[ -n "$snapshot" ]] || return 0
    comm -12 <(printf '%s\n' "$current" | sort) <(printf '%s\n' "$snapshot" | sort)
}

_block_on_untracked_files() {
    local task_file="$1" phase_label="$2" plan_file="${3:-}" before_sha="${4:-}"
    local untracked_files=""
    local scope_source=""
    local fallback_warning=""
    _v2_resolve_scope_paths "$task_file" "$plan_file" "$before_sha" || true
    scope_source="$_V2_SCOPE_SOURCE"
    fallback_warning=$(_v2_scope_fallback_warning_message "$scope_source")
    untracked_files=$(_collect_blocking_untracked_files "$task_file" "$plan_file" "$before_sha")

    # If a pre-execution snapshot was taken (5th arg present, even if empty),
    # filter to only pre-existing files. Empty snapshot = nothing pre-existing = nothing blocks.
    if [[ $# -ge 5 ]]; then
        untracked_files=$(_filter_to_preexisting "$untracked_files" "${5:-}")
    fi

    [[ -n "$untracked_files" ]] || return 0

    echo -e "${RED}${phase_label}: blocking on untracked files overlapping task scope${NC}" >&2
    printf '%s\n' "$untracked_files" >&2
    set_task_status "$task_file" "blocked" || true
    log_execution "$task_file" "${phase_label}: Untracked files detected within task scope (source: ${scope_source})" || true
    if [[ -n "$fallback_warning" ]]; then
        log_execution "$task_file" "${phase_label}: WARN: ${fallback_warning}" || true
    fi
    _log_diagnostic_lines "$task_file" "$(_v2_scope_diagnostic_lines "$_V2_SCOPE_PATHS")"
    _log_diagnostic_lines "$task_file" "$untracked_files"
    _print_cost_summary || true
    return 1
}

_check_cost_ceiling() {
    local task_file="$1" comp_dir="$2" fix_cycles="$3"

    if [[ ! "$LAUREN_LOOP_MAX_COST" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo -e "${YELLOW}WARN: Ignoring invalid LAUREN_LOOP_MAX_COST=${LAUREN_LOOP_MAX_COST}${NC}"
        return 0
    fi
    if awk -v max="$LAUREN_LOOP_MAX_COST" 'BEGIN { exit !(max <= 0) }'; then
        return 0
    fi

    _merge_cost_csvs || true

    local cost_csv="${TASK_LOG_DIR:-/tmp}/cost.csv"
    local total_cost
    total_cost=$(awk -F',' 'NR > 1 && $11 != "" { sum += $11 } END { printf "%.4f", sum + 0 }' "$cost_csv" 2>/dev/null)
    [[ -z "$total_cost" ]] && total_cost="0.0000"

    if [[ "$_COST_CEILING_INTERRUPT_WARNED" != true ]] && \
       awk -F',' 'NR > 1 { status = (NF >= 13 ? $13 : "completed"); if (status == "interrupted") found=1 } END { exit !found }' "$cost_csv" 2>/dev/null; then
        echo -e "${YELLOW}WARN: Prior run interrupted — ceiling check may undercount.${NC}"
        log_execution "$task_file" "WARN: Prior run interrupted — ceiling check may undercount." || true
        _COST_CEILING_INTERRUPT_WARNED=true
    fi

    if awk -v total="$total_cost" -v max="$LAUREN_LOOP_MAX_COST" 'BEGIN { exit !(total >= max) }'; then
        echo -e "${YELLOW}Cost ceiling reached: \$${total_cost} >= \$${LAUREN_LOOP_MAX_COST}. Halting for human review.${NC}"
        set_task_status "$task_file" "needs verification" || return 2
        if ! _write_human_review_handoff "COST_CEILING" "$fix_cycles"; then
            set_task_status "$task_file" "blocked" || true
            log_execution "$task_file" "Pipeline FAILED while human-review-handoff: Failed to write cost-ceiling handoff" || true
            return 2
        fi
        _mark_fix_execution_handoff || true
        log_execution "$task_file" "Pipeline halted — cost ceiling exceeded (\$${total_cost} >= \$${LAUREN_LOOP_MAX_COST}). See competitive/human-review-handoff.md" || true
        _print_cost_summary || true
        return 1
    fi

    if [[ "$_COST_CEILING_WARNED" != true ]] && \
       awk -v total="$total_cost" -v max="$LAUREN_LOOP_MAX_COST" 'BEGIN { exit !(total >= (max * 0.8)) }'; then
        echo -e "${YELLOW}WARN: Cost is at \$${total_cost} of \$${LAUREN_LOOP_MAX_COST} ceiling (80% threshold reached).${NC}"
        log_execution "$task_file" "Cost warning: \$${total_cost} of \$${LAUREN_LOOP_MAX_COST} ceiling consumed" || true
        _COST_CEILING_WARNED=true
    fi

    return 0
}

extract_markdown_section_to_file() {
    local source_file="$1" header="$2" output_file="$3"
    local tmp_file
    tmp_file=$(mktemp)
    section_body "$source_file" "$header" > "$tmp_file" 2>/dev/null || {
        rm -f "$tmp_file"
        return 1
    }

    if [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        return 1
    fi

    mv "$tmp_file" "$output_file"
}

clear_markdown_section() {
    local target_file="$1" header="$2"
    local blank_file
    blank_file=$(mktemp)
    : > "$blank_file"
    rewrite_section "$target_file" "$header" "$blank_file"
    rm -f "$blank_file"
}

mirror_plan_into_task_file() {
    local task_file="$1" plan_file="$2"
    rewrite_section "$task_file" "## Current Plan" "$plan_file"
}

capture_diff_artifact() {
    local before_sha="$1" diff_file="$2" task_file="${3:-}" plan_file="${4:-}" pre_exec_dirty="${5:-}"
    local tracked_all_files=""
    local tracked_captured_files=""

    _V2_LAST_CAPTURE_SCOPE_SOURCE=""
    _V2_LAST_CAPTURE_SCOPE_PATHS=""
    _V2_LAST_CAPTURE_ALL_FILES=""
    _V2_LAST_CAPTURED_FILES=""
    _V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES=""
    _V2_LAST_CAPTURE_UNTRACKED_FILES=""

    _v2_resolve_scope_paths "$task_file" "$plan_file" "$before_sha" || true
    _V2_LAST_CAPTURE_SCOPE_SOURCE="$_V2_SCOPE_SOURCE"
    _V2_LAST_CAPTURE_SCOPE_PATHS="$_V2_SCOPE_PATHS"
    _V2_LAST_CAPTURE_UNTRACKED_FILES=$(_v2_collect_untracked_files_for_scope "$_V2_SCOPE_PATHS" "$_V2_SCOPE_SOURCE")

    _v2_write_diff_for_scope_source "$before_sha" "$diff_file" "$_V2_SCOPE_PATHS" "$_V2_SCOPE_SOURCE"
    _v2_append_untracked_file_diffs "$diff_file" "$_V2_LAST_CAPTURE_UNTRACKED_FILES"

    tracked_all_files=$(_v2_collect_all_changed_files_for_source "$before_sha" "$_V2_SCOPE_SOURCE" | _v2_unique_nonblank_lines)
    tracked_captured_files=$(_v2_collect_changed_files_for_scope "$before_sha" "$_V2_SCOPE_PATHS" "$_V2_SCOPE_SOURCE" | _v2_unique_nonblank_lines)

    if [[ -n "$pre_exec_dirty" ]]; then
        tracked_all_files=$(_v2_subtract_preexisting_files "$tracked_all_files" "$pre_exec_dirty" "$before_sha")
        tracked_captured_files=$(_v2_subtract_preexisting_files "$tracked_captured_files" "$pre_exec_dirty" "$before_sha")
        _V2_LAST_CAPTURE_UNTRACKED_FILES=$(_v2_subtract_preexisting_files "$_V2_LAST_CAPTURE_UNTRACKED_FILES" "$pre_exec_dirty" "$before_sha")
    fi

    _V2_LAST_CAPTURE_ALL_FILES=$(printf '%s\n%s\n' "$tracked_all_files" "$_V2_LAST_CAPTURE_UNTRACKED_FILES" | _v2_unique_nonblank_lines)
    _V2_LAST_CAPTURED_FILES=$(printf '%s\n%s\n' "$tracked_captured_files" "$_V2_LAST_CAPTURE_UNTRACKED_FILES" | _v2_unique_nonblank_lines)
    if _v2_scope_source_is_constrained "$_V2_SCOPE_SOURCE" && [[ -n "$_V2_LAST_CAPTURE_ALL_FILES" ]]; then
        _V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES=$(_v2_collect_out_of_scope_paths "$_V2_LAST_CAPTURE_ALL_FILES" "$_V2_SCOPE_PATHS" | _v2_unique_nonblank_lines)
    fi
}

_v2_log_capture_scope_details() {
    local task_file="$1" phase_label="$2"
    local scope_source="${_V2_LAST_CAPTURE_SCOPE_SOURCE:-unresolved}"
    local fallback_warning=""
    log_execution "$task_file" "${phase_label}: Diff scope source: ${scope_source}" || true
    fallback_warning=$(_v2_scope_fallback_warning_message "$scope_source")
    if [[ -n "$fallback_warning" ]]; then
        log_execution "$task_file" "${phase_label}: WARN: ${fallback_warning}" || true
    fi
    _log_diagnostic_lines "$task_file" "$(_v2_scope_diagnostic_lines "${_V2_LAST_CAPTURE_SCOPE_PATHS:-}")"
    _log_diagnostic_lines "$task_file" "$(_v2_prefix_lines "changed file" "${_V2_LAST_CAPTURE_ALL_FILES:-}")"
    _log_diagnostic_lines "$task_file" "$(_v2_prefix_lines "included diff file" "${_V2_LAST_CAPTURED_FILES:-}")"
}

_v2_log_out_of_scope_capture_warning() {
    local task_file="$1" phase_label="$2"
    if [[ -n "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" ]]; then
        echo -e "${YELLOW}WARN: Diff scope check reported changes outside the planned file set${NC}"
        log_execution "$task_file" "${phase_label}: WARNING diff scope check reported out-of-scope changes" || true
        printf '%s\n' "$_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES"
        _log_diagnostic_lines "$task_file" "$(_v2_prefix_lines "out-of-scope diff file" "$_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES")"
        return 0
    fi
    return 1
}

_v2_select_phase7_scope_plan_file() {
    local comp_dir="$1"
    local fix_plan="${comp_dir}/fix-plan.md"
    local revised_plan="${comp_dir}/revised-plan.md"

    if [[ -f "$fix_plan" ]] && [[ -n "$(_v2_extract_xml_task_paths "$fix_plan")" ]]; then
        printf '%s\n' "$fix_plan"
        return 0
    fi

    if [[ -f "$revised_plan" ]]; then
        printf '%s\n' "$revised_plan"
    fi
}

_phase2_planner_artifact_state() {
    local role="$1" exit_code="$2" artifact="$3"
    if _validate_agent_output_for_role "$role" "$artifact" >/dev/null 2>&1; then
        printf 'valid\n'
        return 0
    fi
    if [[ "$exit_code" -ne 0 ]]; then
        printf 'unavailable\n'
    else
        printf 'corrupt\n'
    fi
}

_phase2_checkpoint_plan_state() {
    local role="$1" artifact="$2"
    if [[ ! -e "$artifact" ]]; then
        printf 'missing\n'
        return 0
    fi
    if _validate_agent_output_for_role "$role" "$artifact" >/dev/null 2>&1; then
        printf 'valid\n'
    else
        printf 'corrupt\n'
    fi
}

_phase7_resume_gate_reason() {
    local comp_dir="$1"
    local verdict=""

    if ! _validate_agent_output "${comp_dir}/fix-plan.md" >/dev/null 2>&1; then
        printf 'missing valid fix-plan.md\n'
        return 1
    fi

    if [[ -z "${ENGINE_CRITIC:-}" ]]; then
        return 0
    fi

    if ! _validate_agent_output "${comp_dir}/fix-critique.md" >/dev/null 2>&1; then
        printf 'missing valid fix-critique.md\n'
        return 1
    fi

    verdict=$(_parse_contract "${comp_dir}/fix-critique.md" "verdict")
    if [[ "$verdict" == "EXECUTE" ]]; then
        return 0
    fi

    if [[ -z "$verdict" ]]; then
        printf 'fix-critique verdict is missing\n'
    else
        printf 'fix-critique verdict is %s\n' "$verdict"
    fi
    return 1
}

# ============================================================
# lauren_loop_competitive — 7-phase competitive flow
# ============================================================
lauren_loop_competitive() {
    local slug="$1" goal="$2"
    SLUG="$slug"
    _apply_effective_strict_mode "$slug" "$goal"

    # Directory setup
    local task_dir="$(_v2_task_artifact_dir "$slug")"
    local comp_dir="${task_dir}/competitive"
    local TASK_LOG_DIR="${task_dir}/logs"
    local log_dir="$TASK_LOG_DIR"
    local task_file=""
    local blinding_message=""
    local resolve_rc=0
    task_file="$(_resolve_v2_task_file "$slug")" || resolve_rc=$?
    case "$resolve_rc" in
        0) ;;
        1) task_file="${task_dir}/task.md" ;;
        2) exit 1 ;;
        *) exit "$resolve_rc" ;;
    esac
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"

    if [[ -f "$task_file" && "$task_file" != "${task_dir}/"* ]]; then
        _consolidate_task_to_dir "$task_file" "$task_dir"
        task_file="${task_dir}/task.md"
    fi

    _CURRENT_TASK_FILE="$task_file"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    _clear_active_runtime_state
    if [[ "$FORCE_RERUN" == "true" ]]; then
        _backup_artifacts_on_force "$comp_dir"
        _clear_force_artifacts "$comp_dir" "$TASK_LOG_DIR"
    fi
    _ensure_cost_csv_header "${TASK_LOG_DIR}/cost.csv"
    _merge_cost_csvs || true
    _init_run_manifest || true

    # Task file creation (if not resuming)
    if [[ ! -f "$task_file" ]]; then
        cat > "$task_file" <<TASKEOF
## Task: ${slug}
## Status: in progress
## Execution Mode: competitive
## Goal: ${goal}
## Relevant Files:
- `lauren-loop-v2.sh` — competitive Lauren Loop flow
- `lib/lauren-loop-utils.sh` — shared task-file logging and state helpers
## Context:
Created by lauren-loop-v2 for a new competitive run.
## Done Criteria:
- [ ] Competitive run completes and leaves task in needs verification or blocked with artifacts preserved
## Left Off At:
Competitive run has started.

## Execution Log

## Attempts:
(none yet)

## Current Plan

TASKEOF
        echo -e "${GREEN}Created task file: ${task_file}${NC}"
    fi

    ensure_sections "$task_file"

    local current_status=""
    current_status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    if [[ "$current_status" == "needs verification" && "$FORCE_RERUN" != "true" ]]; then
        echo -e "${YELLOW}Task is already in needs verification: ${task_file}${NC}"
        echo -e "${YELLOW}Skipping competitive execution. Use verify/closeout flow instead of reseeding a new plan.${NC}"
        log_execution "$task_file" "Competitive launch skipped: canonical task already in needs verification; preserve verification state instead of reseeding plan work"
        _append_manifest_phase "phase-0" "preflight" "$(_iso_timestamp)" "$(_iso_timestamp)" "skipped" "needs verification" || true
        _finalize_run_manifest "needs verification" 0 || true
        return 0
    fi

    if [[ "$LAUREN_LOOP_AUTO_STRICT" == "true" ]]; then
        echo -e "${YELLOW}Auto-enabling strict mode: ${LAUREN_LOOP_AUTO_STRICT_REASON}${NC}"
        log_execution "$task_file" "Preflight: auto-enabled strict mode (${LAUREN_LOOP_AUTO_STRICT_REASON})"
    fi

    # Prompt file paths
    local explore_prompt="$SCRIPT_DIR/prompts/exploration-summarizer.md"
    local planner_a_prompt="$SCRIPT_DIR/prompts/planner-a.md"
    local planner_b_prompt="$SCRIPT_DIR/prompts/planner-b.md"
    local evaluator_prompt="$SCRIPT_DIR/prompts/plan-evaluator.md"
    local critic_prompt="$SCRIPT_DIR/prompts/critic.md"
    local reviser_prompt="$SCRIPT_DIR/prompts/reviser.md"
    local executor_prompt="$SCRIPT_DIR/prompts/executor.md"
    # Reviewer A reuses the v1 reviewer prompt (no -a suffix — intentional)
    local reviewer_a_prompt="$SCRIPT_DIR/prompts/reviewer.md"
    # Reviewer B has its own prompt; naming asymmetry with reviewer.md is intentional (v1 reuse)
    local reviewer_b_prompt="$SCRIPT_DIR/prompts/reviewer-b.md"
    local review_evaluator_prompt="$SCRIPT_DIR/prompts/review-evaluator.md"
    local fix_plan_author_prompt="$SCRIPT_DIR/prompts/fix-plan-author.md"
    local fix_executor_prompt="$SCRIPT_DIR/prompts/fix-executor.md"

    # Prompt file gate — fail fast before any phase runs
    local missing=0
    for pf in "$explore_prompt" "$planner_a_prompt" "$planner_b_prompt" \
              "$evaluator_prompt" "$critic_prompt" "$reviser_prompt" \
              "$executor_prompt" "$reviewer_a_prompt" "$reviewer_b_prompt" \
              "$review_evaluator_prompt" "$fix_plan_author_prompt" "$fix_executor_prompt"; do
        if [[ ! -f "$pf" ]]; then
            echo -e "${RED}Missing prompt: $pf${NC}" >&2
            missing=$((missing + 1))
        fi
    done
    if [[ "$missing" -gt 0 ]]; then
        echo -e "${RED}Cannot start: $missing prompt file(s) missing (Phase 2 deliverable)${NC}" >&2
        return 1
    fi

    _write_human_review_handoff() {
        local review_verdict="$1"
        local fix_cycles="$2"
        local handoff_file="${comp_dir}/human-review-handoff.md"
        local tmp_file
        tmp_file=$(mktemp "${TMPDIR:-/tmp}/human-review-handoff.XXXXXX")

        {
            echo "# Human Review Handoff"
            echo
            echo "**Task:** ${task_file}"
            echo "**Final review verdict:** ${review_verdict}"
            echo "**Fix cycles attempted:** ${fix_cycles}"
            echo
            echo "## Unresolved Findings"

            local wrote_findings=false
            local section body
            for section in "## Critical Findings" "## Major Findings" "## Minor Findings" "## Nit Findings"; do
                body=$(section_body "${comp_dir}/review-synthesis.md" "$section" 2>/dev/null || true)
                body=$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d')
                if [[ -n "$body" && "$body" != "None." ]]; then
                    echo
                    echo "$section"
                    printf '%s\n' "$body"
                    wrote_findings=true
                fi
            done

            if [[ "$wrote_findings" == false ]]; then
                echo
                echo "No unresolved findings were extracted from review-synthesis.md."
            fi

            echo
            echo "## Human Reviewer Focus"
            echo "- Review ${comp_dir}/review-synthesis.md for the final synthesized findings and verdict."
            echo "- Review ${comp_dir}/fix-plan.md and ${comp_dir}/fix-execution.md to see what the last automated fix cycle attempted."
            echo "- Review ${latest_fix_diff:-${comp_dir}/execution-diff.patch} for the latest code changes under review."
            echo "- Confirm whether the remaining findings are valid fixes, false positives, or need a narrower follow-up task."
        } > "$tmp_file"

        mv "$tmp_file" "$handoff_file"
    }

    _write_single_planner_handoff() {
        local surviving_plan="$1"
        local handoff_file="${comp_dir}/human-review-handoff.md"
        local tmp_file
        tmp_file=$(mktemp "${TMPDIR:-/tmp}/planner-handoff.XXXXXX")

        {
            echo "# Human Review Handoff"
            echo
            echo "**Task:** ${task_file}"
            echo "**Final review verdict:** SINGLE_PLANNER"
            echo "**Strict mode:** ${LAUREN_LOOP_EFFECTIVE_STRICT}"
            if [[ "$LAUREN_LOOP_AUTO_STRICT" == "true" ]]; then
                echo "**Auto-strict reason:** ${LAUREN_LOOP_AUTO_STRICT_REASON}"
            fi
            echo
            echo "## Available Planning Artifact"
            echo "- Surviving plan: ${surviving_plan}"
            echo "- Exploration summary: ${comp_dir}/exploration-summary.md"
            echo "- Planner A log: ${log_dir}/planner-a.log"
            echo "- Planner B log: ${log_dir}/planner-b.log"
            echo
            echo "## Human Reviewer Focus"
            echo "- Review the surviving plan for missing scope, rollback coverage, and operational safeguards before any execution phase starts."
            echo "- Compare the surviving plan against ${comp_dir}/exploration-summary.md and the task goal to decide whether to approve, revise, or rerun planning."
            echo "- Inspect preserved attempt artifacts in ${comp_dir}/plan-b.attempt-*.md if Codex produced partial or alternate plans during retries."
        } > "$tmp_file"

        mv "$tmp_file" "$handoff_file"
    }

    _snapshot_review_cycle_artifacts() {
        local cycle_number="$1"
        local source_file="" snapshot_file=""

        for source_file in \
            "${comp_dir}/reviewer-a.raw.md" \
            "${comp_dir}/reviewer-b.raw.md" \
            "${comp_dir}/review-a.md" \
            "${comp_dir}/review-b.md"; do
            [[ -f "$source_file" ]] || continue
            snapshot_file="${source_file%.md}.cycle${cycle_number}.md"
            _atomic_promote_file "$source_file" "$snapshot_file" || return 1
        done

        if [[ -f "${comp_dir}/.review-mapping" ]]; then
            _atomic_promote_file "${comp_dir}/.review-mapping" "${comp_dir}/.review-mapping.cycle${cycle_number}" || return 1
        fi
    }

    _mark_fix_execution_handoff() {
        local handoff_file="${comp_dir}/human-review-handoff.md"
        local fix_execution_file="${comp_dir}/fix-execution.md"

        if [[ ! -f "$fix_execution_file" ]]; then
            return 0
        fi

        if grep -q '^## Final Status' "$fix_execution_file"; then
            if grep -q '^\*\*STATUS:\*\* ' "$fix_execution_file"; then
                _sed_i 's/^\*\*STATUS:\*\* .*/**STATUS:** BLOCKED/' "$fix_execution_file" || return 1
            else
                printf '\n**STATUS:** BLOCKED\n' >> "$fix_execution_file"
            fi

            if grep -q '^\*\*Remaining findings:\*\* ' "$fix_execution_file"; then
                _sed_i "s|^\*\*Remaining findings:\*\* .*|**Remaining findings:** See ${comp_dir}/review-synthesis.md and ${handoff_file}.|" "$fix_execution_file" || return 1
            else
                printf '**Remaining findings:** See %s and %s.\n' "${comp_dir}/review-synthesis.md" "$handoff_file" >> "$fix_execution_file"
            fi

            if grep -q '^\*\*Follow-up:\*\* ' "$fix_execution_file"; then
                _sed_i "s|^\*\*Follow-up:\*\* .*|**Follow-up:** Human review required before any further fix planning or task closeout. See ${handoff_file}.|" "$fix_execution_file" || return 1
            else
                printf '**Follow-up:** Human review required before any further fix planning or task closeout. See %s.\n' "$handoff_file" >> "$fix_execution_file"
            fi
        else
            cat >> "$fix_execution_file" <<EOF

## Final Status

**STATUS:** BLOCKED
**Remaining findings:** See ${comp_dir}/review-synthesis.md and ${handoff_file}.
**Follow-up:** Human review required before any further fix planning or task closeout. See ${handoff_file}.
EOF
        fi
    }

    _fail_phase() {
        local phase_status="$1" error_message="$2" recovery_hint="${3:-}"
        echo -e "${RED}${error_message}${NC}"
        if [[ -n "$recovery_hint" ]]; then
            echo -e "${YELLOW}  Hint: ${recovery_hint}${NC}"
        fi
        set_task_status "$task_file" "blocked"
        log_execution "$task_file" "Pipeline FAILED while ${phase_status}: ${error_message}"
        if [[ -n "$recovery_hint" ]]; then
            log_execution "$task_file" "  recovery hint: ${recovery_hint}"
        fi
        return 1
    }

    _artifact_is_valid() {
        local artifact="$1"
        _validate_agent_output "$artifact" >/dev/null 2>&1
    }

    _require_valid_artifact() {
        local artifact="$1" phase_status="$2" error_message="$3" recovery_hint="${4:-}"
        if _validate_agent_output "$artifact"; then
            return 0
        fi
        _fail_phase "$phase_status" "$error_message" "$recovery_hint"
        return 1
    }

    _clear_resume_checkpoint() {
        local target="$1" reason="$2"
        echo -e "${YELLOW}WARN: Resume checkpoint invalid for ${target} (${reason}); restarting from Phase 5.${NC}"
        log_execution "$task_file" "WARN: Resume checkpoint invalid for ${target} (${reason}); restarting from Phase 5"
        _resume_to_subphase=""
    }

    _resume_target_ready() {
        local target="$1"
        local phase7_reason=""
        case "$target" in
            phase-6a)
                if _artifact_is_valid "${comp_dir}/review-a.md" || _artifact_is_valid "${comp_dir}/review-b.md"; then
                    return 0
                fi
                _clear_resume_checkpoint "$target" "missing valid review-a.md/review-b.md"
                return 1
                ;;
            phase-6b)
                if _artifact_is_valid "${comp_dir}/review-synthesis.md"; then
                    return 0
                fi
                _clear_resume_checkpoint "$target" "missing valid review-synthesis.md"
                return 1
                ;;
            phase-6c)
                if _artifact_is_valid "${comp_dir}/fix-plan.md"; then
                    return 0
                fi
                _clear_resume_checkpoint "$target" "missing valid fix-plan.md"
                return 1
                ;;
            phase-7)
                if phase7_reason=$(_phase7_resume_gate_reason "$comp_dir"); then
                    return 0
                fi
                _clear_resume_checkpoint "$target" "$phase7_reason"
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    }

    _classify_diff_risk() {
        local diff_lines=0 has_critical=false
        diff_lines=$(git diff --numstat HEAD 2>/dev/null | awk '{s+=$1+$2}END{print s+0}' || echo 0)
        if git diff --name-only HEAD 2>/dev/null | grep -Eqi '(^|/|[-_.])((security)|(secret|secrets)|(credential|credentials)|(keyvault)|(rbac)|(database)|(schema)|(migrations?)|(\.env))($|/|[-_.])'; then
            has_critical=true
        fi
        if [[ "$has_critical" == true ]]; then
            echo "HIGH"
        elif [[ "${diff_lines:-0}" -gt 500 ]]; then
            echo "MEDIUM"
        else
            echo "LOW"
        fi
    }

    # ---- Phase 1: Explore ----
    local _phase_start=""
    echo -e "${BLUE}=== Phase 1: Explore ===${NC}"
    _phase_start=$(_iso_timestamp)
    if [[ "$FORCE_RERUN" != "true" ]] && [[ -s "${comp_dir}/exploration-summary.md" ]]; then
        echo -e "${GREEN}Phase 1: Skipped (checkpoint — exploration-summary.md exists)${NC}"
        log_execution "$task_file" "Phase 1: Skipped (checkpoint)"
        _append_manifest_phase "phase-1" "explore" "$_phase_start" "$(_iso_timestamp)" "skipped" || true
    else
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 1: Explore started"

        local explore_instruction="You are the exploration agent. Your goal: ${goal}

Read the task file at ${task_file} for context. Explore the codebase to understand the problem space. Write a comprehensive exploration summary to ${comp_dir}/exploration-summary.md covering:
1. Relevant files and their purposes
2. Current behavior vs desired behavior
3. Key constraints and dependencies
4. Recommended approach"
        prepare_agent_request "$ENGINE_EXPLORE" "$explore_prompt" "$explore_instruction" || {
            _fail_phase "exploring" "Failed to assemble explorer prompt" "Check agent log at ${log_dir}/explorer.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
        }
        local explore_prompt_body="$AGENT_PROMPT_BODY"
        local explore_sysprompt="$AGENT_SYSTEM_PROMPT"

        local exit_explore=0
        run_agent "explorer" "$ENGINE_EXPLORE" "$explore_prompt_body" "$explore_sysprompt" \
            "${comp_dir}/exploration-summary.md" "${log_dir}/explorer.log" \
            "$EXPLORE_TIMEOUT" "200" "WebFetch,WebSearch" || exit_explore=$?

        if [[ "$exit_explore" -ne 0 ]]; then
            if [[ "$exit_explore" -eq 124 ]]; then
                echo -e "${RED}Phase 1 timed out (${EXPLORE_TIMEOUT})${NC}"
                log_execution "$task_file" "Phase 1: Explore timed out (${EXPLORE_TIMEOUT})"
            else
                echo -e "${RED}Phase 1 failed (exit $exit_explore)${NC}"
                log_execution "$task_file" "Phase 1: Explore FAILED (exit $exit_explore)"
            fi
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
        fi
        _require_valid_artifact \
            "${comp_dir}/exploration-summary.md" \
            "exploring" \
            "Phase 1 produced an invalid exploration summary" \
            "Check ${comp_dir}/exploration-summary.md and agent log ${log_dir}/explorer.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" || return 1
        log_execution "$task_file" "Phase 1: Explore completed"
        _append_manifest_phase "phase-1" "explore" "$_phase_start" "$(_iso_timestamp)" "completed" || true
    fi

    # ---- Phase 2: Parallel Planning ----
    local phase2_skipped=false
    local plan_a_valid=false
    local plan_b_valid=false
    echo -e "${BLUE}=== Phase 2: Parallel Planning ===${NC}"
    _phase_start=$(_iso_timestamp)
    if [[ "$FORCE_RERUN" != "true" ]] && { [[ -s "${comp_dir}/plan-a.md" ]] || [[ -s "${comp_dir}/plan-b.md" ]]; }; then
        phase2_skipped=true
        echo -e "${GREEN}Phase 2: Skipped (checkpoint — plan artifact(s) exist)${NC}"
        log_execution "$task_file" "Phase 2: Skipped (checkpoint)"
        _append_manifest_phase "phase-2" "planning" "$_phase_start" "$(_iso_timestamp)" "skipped" || true
    else
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 2: Planning started (parallel)"

        local plan_a_instruction="You are Planner A (Claude). Goal: ${goal}

Read the exploration summary at ${comp_dir}/exploration-summary.md and the task file at ${task_file}.
Write a detailed implementation plan to ${comp_dir}/plan-a.md."
        prepare_agent_request "$ENGINE_PLANNER_A" "$planner_a_prompt" "$plan_a_instruction" || {
            _fail_phase "planning" "Failed to assemble planner-a prompt" "Check agent log at ${log_dir}/planner-a.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
        }
        local plan_a_prompt_body="$AGENT_PROMPT_BODY"
        local plan_a_sysprompt="$AGENT_SYSTEM_PROMPT"

        local plan_b_output_path="${comp_dir}/plan-b.md"
        if [[ "$ENGINE_PLANNER_B" == "codex" ]]; then
            plan_b_output_path="$CODEX_ARTIFACT_PATH_PLACEHOLDER"
        fi
        local plan_b_instruction="Goal: ${goal}

Read the exploration summary at ${comp_dir}/exploration-summary.md and the task file at ${task_file}.
Write a detailed implementation plan to ${plan_b_output_path}."
        prepare_agent_request "$ENGINE_PLANNER_B" "$planner_b_prompt" "$plan_b_instruction" || {
            _fail_phase "planning" "Failed to assemble planner-b prompt" "Check agent log at ${log_dir}/planner-b.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
        }
        local plan_b_prompt_body="$AGENT_PROMPT_BODY"
        local plan_b_sysprompt="$AGENT_SYSTEM_PROMPT"

        echo -e "${BLUE}Spawning parallel: planner-a (${ENGINE_PLANNER_A}) + planner-b (${ENGINE_PLANNER_B})${NC}"

        local planner_a_start_ts=0 planner_b_start_ts=0
        local planner_a_duration=0
        local planner_b_backstopped=false

        planner_a_start_ts=$(date +%s)
        run_agent "planner-a" "$ENGINE_PLANNER_A" "$plan_a_prompt_body" "$plan_a_sysprompt" \
            "${comp_dir}/plan-a.md" "${log_dir}/planner-a.log" "$PLANNER_TIMEOUT" "100" &
        local pid_a=$!

        planner_b_start_ts=$(date +%s)
        run_agent "planner-b" "$ENGINE_PLANNER_B" "$plan_b_prompt_body" "$plan_b_sysprompt" \
            "${comp_dir}/plan-b.md" "${log_dir}/planner-b.log" "$PLANNER_TIMEOUT" "100" &
        local pid_b=$!

        local exit_a=0 exit_b=0
        wait $pid_a || exit_a=$?
        planner_a_duration=$(( $(date +%s) - planner_a_start_ts ))
        (( planner_a_duration < 0 )) && planner_a_duration=0
        if [[ "$ENGINE_PLANNER_A" == "claude" ]] && [[ "$ENGINE_PLANNER_B" == "codex" ]] && \
           _validate_agent_output_for_role "planner-a" "${comp_dir}/plan-a.md" >/dev/null 2>&1 && \
           kill -0 "$pid_b" 2>/dev/null; then
            if ! _enforce_codex_phase_backstop "$pid_b" "planner-b" "$planner_b_start_ts" "$PLANNER_TIMEOUT" "$planner_a_duration" "${log_dir}/planner-b.log" "${comp_dir}/plan-b.md"; then
                planner_b_backstopped=true
            fi
        fi
        wait $pid_b || exit_b=$?
        if [[ "$planner_b_backstopped" == true ]]; then
            _append_interrupted_cost_rows TERM || true
        fi
        _merge_cost_csvs || true

        echo -e "${BLUE}Parallel done: A=$exit_a, B=$exit_b${NC}"

        case "$(_phase2_planner_artifact_state "planner-a" "$exit_a" "${comp_dir}/plan-a.md")" in
            valid)
                plan_a_valid=true
                ;;
            corrupt)
                _fail_phase \
                    "planning" \
                    "Phase 2 planner A produced an invalid plan artifact" \
                    "Check ${comp_dir}/plan-a.md and agent log ${log_dir}/planner-a.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
                return 1
                ;;
        esac
        _promote_latest_valid_attempt "planner-b" "${comp_dir}/plan-b.md" || true
        case "$(_phase2_planner_artifact_state "planner-b" "$exit_b" "${comp_dir}/plan-b.md")" in
            valid)
                plan_b_valid=true
                ;;
            corrupt)
                _fail_phase \
                    "planning" \
                    "Phase 2 planner B produced an invalid plan artifact" \
                    "Check ${comp_dir}/plan-b.md and agent log ${log_dir}/planner-b.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
                return 1
                ;;
        esac

        if [[ "$plan_a_valid" != true && "$plan_b_valid" != true ]]; then
            echo -e "${RED}No valid planner outputs survived (A=$exit_a, B=$exit_b)${NC}"
            set_task_status "$task_file" "blocked"
            log_execution "$task_file" "Phase 2: No valid planner outputs survived (A=$exit_a, B=$exit_b)"
            _print_cost_summary
            return 1
        fi
        if [[ "$exit_a" -ne 0 ]]; then
            echo -e "${YELLOW}Planner A failed ($exit_a), continuing without A${NC}"
        fi
        if [[ "$exit_b" -ne 0 ]]; then
            echo -e "${YELLOW}Planner B failed ($exit_b), continuing without B${NC}"
        fi
        log_execution "$task_file" "Phase 2: Planning completed (A=$exit_a, B=$exit_b)"
        _append_manifest_phase "phase-2" "planning" "$_phase_start" "$(_iso_timestamp)" "completed" || true
    fi

    # ---- Single planner survival guard (C2) ----
    local skip_evaluator=false
    local surviving_plan=""

    if [[ "$phase2_skipped" == true ]]; then
        case "$(_phase2_checkpoint_plan_state "planner-a" "${comp_dir}/plan-a.md")" in
            valid)
                plan_a_valid=true
                ;;
            corrupt)
                _fail_phase \
                    "planning" \
                    "Phase 2 checkpointed plan-a.md is invalid" \
                    "Check ${comp_dir}/plan-a.md and agent log ${log_dir}/planner-a.log, then regenerate Phase 2 with --force if needed: bash lauren-loop-v2.sh ${SLUG} '${goal}' --force"
                return 1
                ;;
        esac
        _promote_latest_valid_attempt "planner-b" "${comp_dir}/plan-b.md" || true
        case "$(_phase2_checkpoint_plan_state "planner-b" "${comp_dir}/plan-b.md")" in
            valid)
                plan_b_valid=true
                ;;
            corrupt)
                _fail_phase \
                    "planning" \
                    "Phase 2 checkpointed plan-b.md is invalid" \
                    "Check ${comp_dir}/plan-b.md and agent log ${log_dir}/planner-b.log, then regenerate Phase 2 with --force if needed: bash lauren-loop-v2.sh ${SLUG} '${goal}' --force"
                return 1
                ;;
        esac
    fi

    if [[ "$plan_a_valid" != true && "$plan_b_valid" != true ]]; then
        echo -e "${RED}Both plan files are invalid or missing — cannot continue${NC}"
        set_task_status "$task_file" "blocked"
        log_execution "$task_file" "Phase 2: Both plan files invalid or missing before evaluation"
        _print_cost_summary
        return 1
    fi

    if [[ "$plan_a_valid" != true || "$plan_b_valid" != true ]]; then
        [[ "$plan_a_valid" == true ]] && surviving_plan="${comp_dir}/plan-a.md" || surviving_plan="${comp_dir}/plan-b.md"
        if _strict_contract_mode; then
            echo -e "${YELLOW}Only one plan produced with effective strict mode — halting for human review${NC}"
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Phase 2: Single planner halt (strict=${LAUREN_LOOP_EFFECTIVE_STRICT}, auto_strict=${LAUREN_LOOP_AUTO_STRICT}, surviving_plan=$(basename "$surviving_plan"))"
            _write_single_planner_handoff "$surviving_plan" || true
            _finalize_run_manifest "needs verification" 0 || true
            return 0
        fi

        echo -e "${YELLOW}Only one plan produced — evaluator skipped, surviving plan seeds revised-plan.md${NC}"
        if [[ ! -s "${comp_dir}/revised-plan.md" ]] || [[ "$FORCE_RERUN" == "true" ]]; then
            cp "$surviving_plan" "${comp_dir}/revised-plan.md"
            log_execution "$task_file" "Phase 2: Single plan ($(basename "$surviving_plan")) seeded ${comp_dir}/revised-plan.md"
        else
            echo -e "${BLUE}Preserving existing revised-plan.md checkpoint during single-plan resume${NC}"
            log_execution "$task_file" "Phase 2: Single plan ($(basename "$surviving_plan")) preserved existing ${comp_dir}/revised-plan.md checkpoint"
        fi
        skip_evaluator=true
    fi

    _phase_start=$(_iso_timestamp)
    if [[ "$FORCE_RERUN" != "true" ]] && [[ -s "${comp_dir}/revised-plan.md" ]] && \
       [[ -s "${comp_dir}/plan-critique.md" ]] && \
       [[ "$(_parse_contract "${comp_dir}/plan-critique.md" "verdict")" == "EXECUTE" ]]; then
        echo -e "${GREEN}Phase 3: Skipped (checkpoint — approved revised plan exists)${NC}"
        log_execution "$task_file" "Phase 3: Skipped (checkpoint)"
        _append_manifest_phase "phase-3" "evaluate-critic" "$_phase_start" "$(_iso_timestamp)" "skipped" || true
    else
        if [[ "$skip_evaluator" == false ]]; then
            if (( RANDOM % 2 )); then
                cp "${comp_dir}/plan-a.md" "${comp_dir}/plan-1.md"
                cp "${comp_dir}/plan-b.md" "${comp_dir}/plan-2.md"
                _atomic_write "${comp_dir}/.plan-mapping" "plan-1=plan-a plan-2=plan-b"
            else
                cp "${comp_dir}/plan-b.md" "${comp_dir}/plan-1.md"
                cp "${comp_dir}/plan-a.md" "${comp_dir}/plan-2.md"
                _atomic_write "${comp_dir}/.plan-mapping" "plan-1=plan-b plan-2=plan-a"
            fi
            echo -e "${BLUE}Plan randomization: $(cat "${comp_dir}/.plan-mapping")${NC}"

            echo -e "${BLUE}=== Phase 3: Evaluate Plans ===${NC}"
            set_task_status "$task_file" "in progress"
            log_execution "$task_file" "Phase 3: Evaluation started"

            local eval_instruction="You are the Plan Evaluator. Compare the two plans:
- Plan 1: ${comp_dir}/plan-1.md
- Plan 2: ${comp_dir}/plan-2.md
- Exploration summary: ${comp_dir}/exploration-summary.md
- Task file: ${task_file}

Score each plan on all six dimensions, then select the better plan or synthesize a hybrid.
Write your evaluation to ${comp_dir}/plan-evaluation.md. Include a ## Selected Plan section containing the full winning or hybrid plan.
Do NOT modify the task file."
            prepare_agent_request "$ENGINE_EVALUATOR" "$evaluator_prompt" "$eval_instruction" || {
                _fail_phase "evaluating" "Failed to assemble evaluator prompt" "Check agent log at ${log_dir}/evaluator.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
            }

            local exit_eval=0
            rm -f "${comp_dir}/plan-evaluation.contract.json"
            run_agent "evaluator" "$ENGINE_EVALUATOR" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
                "${comp_dir}/plan-evaluation.md" "${log_dir}/evaluator.log" \
                "$EVALUATE_TIMEOUT" "100" || exit_eval=$?

            if [[ "$exit_eval" -ne 0 ]]; then
                if [[ "$exit_eval" -eq 124 ]]; then
                    echo -e "${RED}Phase 3 timed out (${EVALUATE_TIMEOUT})${NC}"
                    log_execution "$task_file" "Phase 3: Evaluation timed out (${EVALUATE_TIMEOUT})"
                else
                    echo -e "${RED}Phase 3 failed (exit $exit_eval)${NC}"
                    log_execution "$task_file" "Phase 3: Evaluation FAILED (exit $exit_eval)"
                fi
                set_task_status "$task_file" "blocked"
                _print_cost_summary
                return 1
            fi
            _require_valid_artifact \
                "${comp_dir}/plan-evaluation.md" \
                "evaluating" \
                "Phase 3 produced an invalid plan evaluation artifact" \
                "Check ${comp_dir}/plan-evaluation.md and agent log ${log_dir}/evaluator.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" || return 1

            if _strict_contract_mode; then
                local _eval_present=""
                _eval_present=$(_parse_contract "${comp_dir}/plan-evaluation.md" "selected_plan_present")
                if [[ "$_eval_present" != "true" ]]; then
                    echo -e "${RED}Strict mode requires plan-evaluation.contract.json selected_plan_present=true${NC}"
                    set_task_status "$task_file" "blocked"
                    log_execution "$task_file" "Phase 3: Strict contract failure for plan-evaluation selected_plan_present"
                    _print_cost_summary
                    return 1
                fi
            fi

            if ! extract_markdown_section_to_file "${comp_dir}/plan-evaluation.md" "## Selected Plan" "${comp_dir}/revised-plan.md"; then
                echo -e "${RED}ERROR: Evaluator did not produce ## Selected Plan — cannot continue${NC}"
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Phase 3: Evaluator failed to produce ## Selected Plan"
                grep -i 'selected.plan' "${comp_dir}/plan-evaluation.md" | head -5 | while IFS= read -r _line; do
                    log_execution "$task_file" "  diagnostic: found heading: $_line"
                done
                _print_cost_summary
                return 1
            fi
            log_execution "$task_file" "Phase 3: Evaluation completed and revised-plan.md seeded"
            blinding_message="Plan randomization: $(cat "${comp_dir}/.plan-mapping")"
            _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
            blinding_message="Plan engine mapping: plan-a=${ENGINE_PLANNER_A}, plan-b=${ENGINE_PLANNER_B}"
            _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
            log_execution "$task_file" "Phase 3: Plan evaluation completed"
        fi

        mirror_plan_into_task_file "$task_file" "${comp_dir}/revised-plan.md" || {
            echo -e "${RED}Failed to mirror initial plan into task file${NC}"
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
        }
        log_execution "$task_file" "Phase 3: Initial plan mirrored before critic loop"

        echo -e "${BLUE}=== Phase 3: Critic Loop ===${NC}"
        local plan_critic_result=0
        run_critic_loop "$task_file" "$comp_dir" "$critic_prompt" "$reviser_prompt" "${comp_dir}/revised-plan.md" "${comp_dir}/plan-critique.md" 3 "plan-critic" "needs verification" "$ENGINE_CRITIC" || plan_critic_result=$?
        case "$plan_critic_result" in
            0)
                set_task_status "$task_file" "in progress"
                log_execution "$task_file" "Phase 3: Plan approved"
                ;;
            1)
                echo -e "${YELLOW}Plan critic loop halted for human review${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}Plan critic loop hard-failed${NC}"
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Phase 3: Critic loop FAILED"
                _print_cost_summary
                return 1
                ;;
        esac
        _append_manifest_phase "phase-3" "evaluate-critic" "$_phase_start" "$(_iso_timestamp)" "completed" || true
    fi

    mirror_plan_into_task_file "$task_file" "${comp_dir}/revised-plan.md" || {
        echo -e "${RED}Failed to mirror revised plan into task file${NC}"
        set_task_status "$task_file" "blocked"
        _print_cost_summary
        return 1
    }
    log_execution "$task_file" "Phase 3: Current Plan mirrored from ${comp_dir}/revised-plan.md for review compatibility"

    local baseline_diff="${comp_dir}/execution-diff.patch"
    local latest_fix_diff=""

    echo -e "${BLUE}=== Phase 4: Execute ===${NC}"
    _phase_start=$(_iso_timestamp)
    if [[ "$FORCE_RERUN" != "true" ]] && [[ -s "${comp_dir}/execution-diff.patch" ]]; then
        echo -e "${GREEN}Phase 4: Skipped (checkpoint — execution-diff.patch exists)${NC}"
        log_execution "$task_file" "Phase 4: Skipped (checkpoint)"
        _append_manifest_phase "phase-4" "execute" "$_phase_start" "$(_iso_timestamp)" "skipped" || true
    else
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 4: Execution started"

        local pre_exec_sha=""
        pre_exec_sha=$(git rev-parse HEAD 2>/dev/null || true)
        local pre_exec_untracked=""
        pre_exec_untracked=$(_collect_blocking_untracked_files "$task_file" "${comp_dir}/revised-plan.md" "$pre_exec_sha")
        local pre_exec_dirty=""
        pre_exec_dirty=$(_v2_snapshot_dirty_files)
        local exec_instruction="You are the Executor. Read the approved plan at ${comp_dir}/revised-plan.md and the task file at ${task_file}.
Implement the plan step by step. Write execution progress to ${comp_dir}/execution-log.md.
Work in small, verifiable steps and stop with BLOCKED if the plan cannot be completed safely."
        prepare_agent_request "$ENGINE_EXECUTOR" "$executor_prompt" "$exec_instruction" || {
            _fail_phase "executing" "Failed to assemble executor prompt" "Check agent log at ${log_dir}/executor.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
        }

        local exit_exec=0
        touch "${log_dir}/executor.log"
        start_agent_monitor "${log_dir}/executor.log" "$task_file"
        run_agent "executor" "$ENGINE_EXECUTOR" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "/dev/null" "${log_dir}/executor.log" \
            "$EXECUTOR_TIMEOUT" "300" "WebFetch,WebSearch" || exit_exec=$?
        stop_agent_monitor

        if [[ "$exit_exec" -ne 0 ]]; then
            if [[ "$exit_exec" -eq 124 ]]; then
                echo -e "${RED}Phase 4 timed out (${EXECUTOR_TIMEOUT})${NC}"
                log_execution "$task_file" "Phase 4: Execution timed out (${EXECUTOR_TIMEOUT})"
            else
                echo -e "${RED}Phase 4 failed (exit $exit_exec)${NC}"
                log_execution "$task_file" "Phase 4: Execution FAILED (exit $exit_exec)"
            fi
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
        fi
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 4: Execution completed"

        capture_diff_artifact "$pre_exec_sha" "$baseline_diff" "$task_file" "${comp_dir}/revised-plan.md" "$pre_exec_dirty"
        if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && [[ -z "${_V2_LAST_CAPTURE_UNTRACKED_FILES:-}" ]]; then
            echo -e "${RED}Executor produced no code changes${NC}"
            set_task_status "$task_file" "blocked"
            log_execution "$task_file" "Phase 4: Executor produced no code changes"
            _print_cost_summary
            return 1
        fi
        _v2_log_capture_scope_details "$task_file" "Phase 4"
        if [[ ! -s "$baseline_diff" ]]; then
            echo -e "${YELLOW}WARN: Execution diff capture produced an empty artifact despite live changes: ${baseline_diff}${NC}"
            log_execution "$task_file" "Phase 4: WARNING diff capture was empty but working tree has changes outside the resolved scope"
        else
            log_execution "$task_file" "Phase 4: Execution diff captured at ${baseline_diff}"
        fi

        _block_on_untracked_files "$task_file" "Phase 4" "${comp_dir}/revised-plan.md" "$pre_exec_sha" "$pre_exec_untracked" || return 1
        _append_manifest_phase "phase-4" "execute" "$_phase_start" "$(_iso_timestamp)" "completed" || true
    fi

    if _v2_log_out_of_scope_capture_warning "$task_file" "Phase 4"; then
        :
    elif [[ -n "${_V2_LAST_CAPTURE_SCOPE_SOURCE:-}" ]]; then
        if [[ "${_V2_LAST_CAPTURE_SCOPE_SOURCE}" == "plan-files-to-modify" ]]; then
            log_execution "$task_file" "Phase 4: Diff scope check passed"
        else
            log_execution "$task_file" "Phase 4: Diff scope check passed with warnings"
        fi
    fi

    local _diff_risk=""
    _diff_risk=$(_classify_diff_risk)
    log_execution "$task_file" "Phase 4: Diff risk classification: ${_diff_risk}"

    if [[ "${_diff_risk}" != "LOW" && "${SINGLE_REVIEWER_POLICY}" == "synthesis" ]]; then
        SINGLE_REVIEWER_POLICY="strict"
        log_execution "$task_file" "Phase 4: Elevated SINGLE_REVIEWER_POLICY to strict (diff_risk=${_diff_risk})"
    fi

    # Cost ceiling check after Phase 4 (most expensive pre-review phase)
    local post_exec_cost_gate=0
    _check_cost_ceiling "$task_file" "$comp_dir" "0" || post_exec_cost_gate=$?
    case "$post_exec_cost_gate" in
        0) ;;
        1)
            log_execution "$task_file" "Phase 4: Cost ceiling reached after execution — halting"
            return 0
            ;;
        *)
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
            ;;
    esac

    ensure_review_sections "$task_file" || {
        echo -e "${RED}Failed to ensure review sections${NC}"
        set_task_status "$task_file" "blocked"
        _print_cost_summary
        return 1
    }

    local fix_cycle=0
    local max_fix_cycles=2
    local pipeline_finished=false
    local pipeline_success=false
    local pipeline_human_review_halt=false
    local _resume_to_subphase=""

    # Cycle checkpoint resume
    if [[ "$FORCE_RERUN" != "true" ]] && _read_cycle_state "$comp_dir"; then
        fix_cycle=$CYCLE_STATE_FIX_CYCLE
        case "$CYCLE_STATE_LAST_COMPLETED" in
            phase-5)  _resume_to_subphase="phase-6a" ;;
            phase-6a) _resume_to_subphase="phase-6b" ;;
            phase-6b) _resume_to_subphase="phase-6c" ;;
            phase-6c) _resume_to_subphase="phase-7" ;;
            phase-7)  fix_cycle=$((fix_cycle + 1)); _resume_to_subphase="" ;;
            *)        _resume_to_subphase="" ;;
        esac
        if [[ -n "$_resume_to_subphase" ]]; then
            if _resume_target_ready "$_resume_to_subphase"; then
                echo -e "${BLUE}Resuming from cycle state: fix_cycle=${fix_cycle}, resume_to=${_resume_to_subphase}${NC}"
                log_execution "$task_file" "Cycle checkpoint resume: fix_cycle=${fix_cycle}, last_completed=${CYCLE_STATE_LAST_COMPLETED}, resume_to=${_resume_to_subphase}"
            fi
        fi
    fi

    while [[ "$pipeline_finished" == false ]]; do
        local cost_gate_result=0
        _check_cost_ceiling "$task_file" "$comp_dir" "$fix_cycle" || cost_gate_result=$?
        case "$cost_gate_result" in
            0) ;;
            1)
                pipeline_finished=true
                pipeline_human_review_halt=true
                break
                ;;
            *)
                set_task_status "$task_file" "blocked"
                _print_cost_summary
                return 1
                ;;
        esac

        local role_suffix=""
        if (( fix_cycle > 0 )); then
            role_suffix="-fix${fix_cycle}"
        fi

        # -- Sub-phase: Phase 5 (review) --
        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" != "phase-5" ]]; then
            echo -e "${BLUE}Phase 5: Skipped (resuming to ${_resume_to_subphase})${NC}"
        else
        _resume_to_subphase=""
        echo -e "${BLUE}=== Phase 5: Parallel Review (cycle $((fix_cycle + 1))) ===${NC}"
        _phase_start=$(_iso_timestamp)
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 5: Review started (cycle $((fix_cycle + 1)))"

        clear_markdown_section "$task_file" "## Review Findings"
        clear_markdown_section "$task_file" "## Review Critique"

        local reviewer_a_prompt_runtime
        reviewer_a_prompt_runtime=$(mktemp "${TMPDIR:-/tmp}/reviewer-a.XXXXXX")
        sed "s|\$PROJECT_NAME|$PROJECT_NAME|g" "$reviewer_a_prompt" > "$reviewer_a_prompt_runtime"

        local review_diff_context="Read the baseline implementation diff at ${baseline_diff}."
        if [[ -n "$latest_fix_diff" ]]; then
            review_diff_context="${review_diff_context} Read the latest fix-cycle diff at ${latest_fix_diff}."
        fi
        local review_a_instruction="Read the task file at ${task_file}. ${review_diff_context} Review all changed files and write findings to ## Review Findings. This is review cycle $((fix_cycle + 1))."
        local review_b_output_path="${comp_dir}/reviewer-b.raw.md"
        if [[ "$ENGINE_REVIEWER_B" == "codex" ]]; then
            review_b_output_path="$CODEX_ARTIFACT_PATH_PLACEHOLDER"
        fi
        local review_b_instruction="Read the task file at ${task_file}. ${review_diff_context} Read ${comp_dir}/exploration-summary.md for context. Write your review to ${review_b_output_path}. This is review cycle $((fix_cycle + 1))."

        prepare_agent_request "$ENGINE_REVIEWER_A" "$reviewer_a_prompt_runtime" "$review_a_instruction" || {
            rm -f "$reviewer_a_prompt_runtime"
            _fail_phase "reviewing" "Failed to assemble reviewer-a prompt" "Check agent log at ${log_dir}/reviewer-a*.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
        }
        local reviewer_a_body="$AGENT_PROMPT_BODY"
        local reviewer_a_system="$AGENT_SYSTEM_PROMPT"

        prepare_agent_request "$ENGINE_REVIEWER_B" "$reviewer_b_prompt" "$review_b_instruction" || {
            rm -f "$reviewer_a_prompt_runtime"
            _fail_phase "reviewing" "Failed to assemble reviewer-b prompt" "Check agent log at ${log_dir}/reviewer-b*.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'"
        }
        local reviewer_b_body="$AGENT_PROMPT_BODY"
        local reviewer_b_system="$AGENT_SYSTEM_PROMPT"

        local reviewer_a_role="reviewer-a${role_suffix}"
        local reviewer_b_role="reviewer-b${role_suffix}"
        local reviewer_a_log="${log_dir}/${reviewer_a_role}.log"
        local reviewer_b_log="${log_dir}/${reviewer_b_role}.log"
        rm -f "${comp_dir}/reviewer-a.raw.md" "${comp_dir}/reviewer-b.raw.md" "${comp_dir}/review-a.md" "${comp_dir}/review-b.md"
        rm -f "${comp_dir}"/reviewer-b.raw.attempt-*.md

        echo -e "${BLUE}Spawning parallel: ${reviewer_a_role} + ${reviewer_b_role}${NC}"

        local reviewer_a_start_ts=0 reviewer_b_start_ts=0
        local reviewer_a_duration=0
        local reviewer_a_usable=false reviewer_b_backstopped=false

        reviewer_a_start_ts=$(date +%s)
        run_agent "$reviewer_a_role" "$ENGINE_REVIEWER_A" "$reviewer_a_body" "$reviewer_a_system" \
            "/dev/null" "$reviewer_a_log" "$REVIEWER_TIMEOUT" "100" &
        local pid_ra=$!

        reviewer_b_start_ts=$(date +%s)
        run_agent "$reviewer_b_role" "$ENGINE_REVIEWER_B" "$reviewer_b_body" "$reviewer_b_system" \
            "${comp_dir}/reviewer-b.raw.md" "$reviewer_b_log" "$REVIEWER_TIMEOUT" "100" &
        local pid_rb=$!

        local exit_ra=0 exit_rb=0
        wait $pid_ra || exit_ra=$?
        reviewer_a_duration=$(( $(date +%s) - reviewer_a_start_ts ))
        (( reviewer_a_duration < 0 )) && reviewer_a_duration=0

        if extract_markdown_section_to_file "$task_file" "## Review Findings" "${comp_dir}/reviewer-a.raw.md"; then
            clear_markdown_section "$task_file" "## Review Findings"
            if _validate_agent_output_for_role "reviewer-a" "${comp_dir}/reviewer-a.raw.md" >/dev/null 2>&1; then
                reviewer_a_usable=true
            fi
        else
            grep -i 'review.findings' "$task_file" | head -5 | while IFS= read -r _line; do
                log_execution "$task_file" "  diagnostic: found heading: $_line"
            done
        fi

        if [[ "$ENGINE_REVIEWER_A" == "claude" ]] && [[ "$ENGINE_REVIEWER_B" == "codex" ]] && \
           [[ "$reviewer_a_usable" == true ]] && \
           kill -0 "$pid_rb" 2>/dev/null; then
            if ! _enforce_codex_phase_backstop "$pid_rb" "$reviewer_b_role" "$reviewer_b_start_ts" "$REVIEWER_TIMEOUT" "$reviewer_a_duration" "$reviewer_b_log" "${comp_dir}/reviewer-b.raw.md"; then
                reviewer_b_backstopped=true
            fi
        fi
        wait $pid_rb || exit_rb=$?
        if [[ "$reviewer_b_backstopped" == true ]]; then
            _append_interrupted_cost_rows TERM || true
        fi
        _merge_cost_csvs || true
        rm -f "$reviewer_a_prompt_runtime"
        _validate_agent_output "${comp_dir}/reviewer-a.raw.md" || true
        _validate_agent_output_for_role "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" || true

        if [[ "$exit_ra" -ne 0 && "$exit_rb" -ne 0 ]]; then
            _fail_phase "reviewing" "Both reviewers failed (A=$exit_ra, B=$exit_rb)" "Both reviewers failed. Check ${log_dir}/reviewer-*.log. Retry with --force to re-run from Phase 5"
        fi

        echo -e "${BLUE}Review parallel done: A=$exit_ra, B=$exit_rb${NC}"
        local has_review_a=false has_review_b=false
        _validate_agent_output "${comp_dir}/reviewer-a.raw.md" >/dev/null 2>&1 && has_review_a=true
        _promote_latest_valid_attempt "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" || true
        _validate_agent_output_for_role "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" >/dev/null 2>&1 && has_review_b=true

        if [[ "$has_review_a" == false ]]; then
            if [[ "$exit_ra" -ne 0 ]]; then
                echo -e "${YELLOW}Reviewer A unavailable (exit $exit_ra; no usable review artifact), continuing with B only${NC}"
            else
                echo -e "${YELLOW}Reviewer A produced no usable review artifact, continuing with B only${NC}"
            fi
        elif [[ "$exit_ra" -ne 0 ]]; then
            echo -e "${YELLOW}Reviewer A exited $exit_ra but produced a usable review artifact${NC}"
        fi

        if [[ "$has_review_b" == false ]]; then
            if [[ "$exit_rb" -ne 0 ]]; then
                echo -e "${YELLOW}Reviewer B unavailable (exit $exit_rb; no usable review artifact), continuing with A only${NC}"
            else
                echo -e "${YELLOW}Reviewer B produced no usable review artifact, continuing with A only${NC}"
            fi
        elif [[ "$exit_rb" -ne 0 ]]; then
            echo -e "${YELLOW}Reviewer B exited $exit_rb but produced a usable review artifact${NC}"
        fi

        if [[ "$has_review_a" == false && "$has_review_b" == false ]]; then
            echo -e "${RED}Parallel review failed to produce any usable raw review artifacts${NC}"
            set_task_status "$task_file" "blocked"
            log_execution "$task_file" "Phase 5: Review artifacts missing (A exit ${exit_ra}, A artifact ${has_review_a}; B exit ${exit_rb}, B artifact ${has_review_b})"
            _print_cost_summary
            return 1
        fi

        if [[ "$has_review_a" == true && "$has_review_b" == true ]]; then
            if (( RANDOM % 2 )); then
                cp "${comp_dir}/reviewer-a.raw.md" "${comp_dir}/review-a.md"
                cp "${comp_dir}/reviewer-b.raw.md" "${comp_dir}/review-b.md"
                _atomic_write "${comp_dir}/.review-mapping" "review-a=reviewer-a.raw review-b=reviewer-b.raw"
            else
                cp "${comp_dir}/reviewer-b.raw.md" "${comp_dir}/review-a.md"
                cp "${comp_dir}/reviewer-a.raw.md" "${comp_dir}/review-b.md"
                _atomic_write "${comp_dir}/.review-mapping" "review-a=reviewer-b.raw review-b=reviewer-a.raw"
            fi
        elif [[ "$has_review_a" == true ]]; then
            cp "${comp_dir}/reviewer-a.raw.md" "${comp_dir}/review-a.md"
            _atomic_write "${comp_dir}/.review-mapping" "review-a=reviewer-a.raw review-b=absent"
        else
            cp "${comp_dir}/reviewer-b.raw.md" "${comp_dir}/review-b.md"
            _atomic_write "${comp_dir}/.review-mapping" "review-a=absent review-b=reviewer-b.raw"
        fi
        _snapshot_review_cycle_artifacts "$((fix_cycle + 1))" || {
            set_task_status "$task_file" "blocked"
            log_execution "$task_file" "Phase 5: Failed to snapshot per-cycle review artifacts"
            _print_cost_summary
            return 1
        }

        # Single-reviewer policy gate
        if [[ "$has_review_a" != "$has_review_b" ]]; then
            if _strict_contract_mode || [[ "$SINGLE_REVIEWER_POLICY" == "strict" ]] || [[ "${_diff_risk:-LOW}" == "HIGH" ]]; then
                echo -e "${YELLOW}Single reviewer available with strict policy, effective strict mode, or HIGH diff risk — halting for human review${NC}"
                set_task_status "$task_file" "needs verification"
                log_execution "$task_file" "Phase 5: Single reviewer halt (strict=${LAUREN_LOOP_EFFECTIVE_STRICT}, policy=${SINGLE_REVIEWER_POLICY}, diff_risk=${_diff_risk:-LOW})"
                _write_human_review_handoff "SINGLE_REVIEWER" "$fix_cycle" || true
                pipeline_finished=true
                pipeline_human_review_halt=true
                break
            else
                log_execution "$task_file" "Phase 5: Single reviewer — continuing to synthesis (policy=${SINGLE_REVIEWER_POLICY}, diff_risk=${_diff_risk:-LOW})"
            fi
        fi

        # Signal: early reviewer consensus — both PASS, skip synthesis
        if ! _strict_contract_mode && [[ "$has_review_a" == true && "$has_review_b" == true ]]; then
            local verdict_review_a="" verdict_review_b=""
            verdict_review_a=$(_parse_contract "${comp_dir}/review-a.md" "verdict")
            verdict_review_b=$(_parse_contract "${comp_dir}/review-b.md" "verdict")
            if [[ "$verdict_review_a" == "PASS" ]] && \
               [[ "$verdict_review_b" == "PASS" ]]; then
                # Check for critical/major findings before fast-pathing
                local _crit_a=0 _crit_b=0
                _crit_a=$(grep -ciE '\[(critical|major)(/|])' "${comp_dir}/review-a.md" 2>/dev/null || true)
                _crit_b=$(grep -ciE '\[(critical|major)(/|])' "${comp_dir}/review-b.md" 2>/dev/null || true)
                if [[ "${_crit_a:-0}" -eq 0 && "${_crit_b:-0}" -eq 0 ]]; then
                    echo -e "${GREEN}Both reviewers signaled PASS — skipping synthesis${NC}"
                    set_task_status "$task_file" "needs verification"
                    blinding_message="Phase 5: Review mapping: $(cat "${comp_dir}/.review-mapping" 2>/dev/null || echo 'missing')"
                    _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
                    blinding_message="Review engine mapping: reviewer-a=${ENGINE_REVIEWER_A}, reviewer-b=${ENGINE_REVIEWER_B}"
                    _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
                    log_execution "$task_file" "Phase 5: Review randomization completed"
                    log_execution "$task_file" "Phase 5/6: Both reviewers PASS — early consensus"
                    _append_manifest_phase "phase-5" "review-cycle-$((fix_cycle+1))" "$_phase_start" "$(_iso_timestamp)" "completed" "PASS" || true
                    pipeline_finished=true
                    pipeline_success=true
                    break
                else
                    echo -e "${YELLOW}Both reviewers PASS but critical/major findings detected (a=${_crit_a}, b=${_crit_b}) — falling through to synthesis${NC}"
                    log_execution "$task_file" "Phase 5: Dual-PASS overridden: critical/major findings (a=${_crit_a}, b=${_crit_b})"
                fi
            fi
        elif _strict_contract_mode && [[ "$has_review_a" == true && "$has_review_b" == true ]]; then
            log_execution "$task_file" "Phase 5: Strict mode disabled raw reviewer PASS fast path"
        fi
        _append_manifest_phase "phase-5" "review-cycle-$((fix_cycle+1))" "$_phase_start" "$(_iso_timestamp)" "completed" "" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-5" || true
        fi  # end Phase 5 skip guard

        # -- Sub-phase: Phase 6a (review evaluation) --
        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" != "phase-6a" ]]; then
            echo -e "${BLUE}Phase 6a: Skipped (resuming to ${_resume_to_subphase})${NC}"
        else
        _resume_to_subphase=""
        echo -e "${BLUE}=== Phase 6: Review Evaluation (cycle $((fix_cycle + 1))) ===${NC}"
        local _phase6_start=""
        _phase6_start=$(_iso_timestamp)
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 6: Review evaluation started (cycle $((fix_cycle + 1)))"

        local review_evaluator_role="review-evaluator${role_suffix}"
        local review_inputs=""
        [[ -f "${comp_dir}/review-a.md" ]] && review_inputs="${review_inputs}- ${comp_dir}/review-a.md"$'\n'
        [[ -f "${comp_dir}/review-b.md" ]] && review_inputs="${review_inputs}- ${comp_dir}/review-b.md"$'\n'
        local review_eval_instruction="The task file is ${task_file}. Read ${comp_dir}/exploration-summary.md and the available review inputs:
${review_inputs}Synthesize only the review files that exist and write the result to ${comp_dir}/review-synthesis.md."
        prepare_agent_request "$ENGINE_EVALUATOR" "$review_evaluator_prompt" "$review_eval_instruction" || {
            _fail_phase "evaluating-reviews" "Failed to assemble review evaluator prompt" "Check ${comp_dir}/review-a.md and ${comp_dir}/review-b.md for review content. Agent log: ${log_dir}/${review_evaluator_role}.log"
        }

        local exit_review_eval=0
        rm -f "${comp_dir}/review-synthesis.contract.json"
        run_agent "$review_evaluator_role" "$ENGINE_EVALUATOR" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "${comp_dir}/review-synthesis.md" "${log_dir}/${review_evaluator_role}.log" \
            "$SYNTHESIZE_TIMEOUT" "100" || exit_review_eval=$?

        if [[ "$exit_review_eval" -ne 0 ]]; then
            if [[ "$exit_review_eval" -eq 124 ]]; then
                echo -e "${RED}Phase 6 review evaluation timed out (${SYNTHESIZE_TIMEOUT})${NC}"
                log_execution "$task_file" "Phase 6: Review evaluation timed out (${SYNTHESIZE_TIMEOUT})"
            else
                echo -e "${RED}Phase 6 review evaluation failed (exit $exit_review_eval)${NC}"
                log_execution "$task_file" "Phase 6: Review evaluation FAILED (exit $exit_review_eval)"
            fi
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
        fi
        _require_valid_artifact \
            "${comp_dir}/review-synthesis.md" \
            "evaluating-reviews" \
            "Phase 6 review evaluation produced an invalid synthesis artifact" \
            "Check ${comp_dir}/review-a.md and ${comp_dir}/review-b.md, then inspect agent log ${log_dir}/${review_evaluator_role}.log" || return 1
        blinding_message="Phase 5: Review mapping: $(cat "${comp_dir}/.review-mapping" 2>/dev/null || echo 'missing')"
        _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
        blinding_message="Review engine mapping: reviewer-a=${ENGINE_REVIEWER_A}, reviewer-b=${ENGINE_REVIEWER_B}"
        _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
        log_execution "$task_file" "Phase 5: Review randomization completed"

        local review_verdict=""
        review_verdict=$(_parse_contract "${comp_dir}/review-synthesis.md" "verdict")
        if [[ -z "$review_verdict" ]]; then
            echo -e "${RED}Phase 6 review evaluation produced no verdict${NC}"
            set_task_status "$task_file" "blocked"
            log_execution "$task_file" "Phase 6: Review evaluation missing verdict"
            _print_cost_summary
            return 1
        fi
        log_execution "$task_file" "Phase 6: Review verdict ${review_verdict}"

        if [[ "$review_verdict" == "PASS" ]]; then
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Pipeline complete: review synthesis PASS"
            _append_manifest_phase "phase-6" "review-eval-cycle-$((fix_cycle+1))" "$_phase6_start" "$(_iso_timestamp)" "completed" "PASS" || true
            pipeline_finished=true
            pipeline_success=true
            break
        fi

        if [[ "$review_verdict" != "CONDITIONAL" && "$review_verdict" != "FAIL" ]]; then
            echo -e "${RED}Unexpected review verdict: $review_verdict${NC}"
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
        fi

        if (( fix_cycle >= max_fix_cycles )); then
            echo -e "${YELLOW}Review still has findings after ${max_fix_cycles} fix cycle(s); stopping for human review${NC}"
            set_task_status "$task_file" "needs verification"
            if ! _write_human_review_handoff "$review_verdict" "$max_fix_cycles" || ! _mark_fix_execution_handoff; then
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Pipeline FAILED while human-review-handoff: Failed to write handoff artifacts"
                _print_cost_summary
                return 1
            fi
            log_execution "$task_file" "Pipeline halted — human review required after ${max_fix_cycles} fix cycles. See competitive/human-review-handoff.md"
            pipeline_finished=true
            pipeline_human_review_halt=true
            break
        fi
        _append_manifest_phase "phase-6a" "review-eval-cycle-$((fix_cycle+1))" "$_phase6_start" "$(_iso_timestamp)" "completed" "$review_verdict" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-6a" "$review_verdict" || true
        fi  # end Phase 6a skip guard

        # -- Sub-phase: Phase 6b (fix plan authoring) --
        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" != "phase-6b" ]]; then
            echo -e "${BLUE}Phase 6b: Skipped (resuming to ${_resume_to_subphase})${NC}"
        else
        _resume_to_subphase=""
        local _phase6b_start=""
        _phase6b_start=$(_iso_timestamp)
        echo -e "${BLUE}=== Phase 6: Author Fix Plan (cycle $((fix_cycle + 1))) ===${NC}"
        cost_gate_result=0
        _check_cost_ceiling "$task_file" "$comp_dir" "$fix_cycle" || cost_gate_result=$?
        case "$cost_gate_result" in
            0) ;;
            1)
                pipeline_finished=true
                pipeline_human_review_halt=true
                break
                ;;
            *)
                set_task_status "$task_file" "blocked"
                _print_cost_summary
                return 1
                ;;
        esac
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 6: Fix plan author started (cycle $((fix_cycle + 1)))"

        local fix_plan_author_role="fix-plan-author${role_suffix}"
        local fix_plan_instruction="The task file is ${task_file}. Read ${comp_dir}/review-synthesis.md and write the fix plan to ${comp_dir}/fix-plan.md."
        prepare_agent_request "$ENGINE_EVALUATOR" "$fix_plan_author_prompt" "$fix_plan_instruction" || {
            _fail_phase "authoring-fix-plan" "Failed to assemble fix-plan-author prompt" "Check ${comp_dir}/review-synthesis.md for synthesis verdict. Agent log: ${log_dir}/${fix_plan_author_role}.log"
        }

        local exit_fix_plan=0
        rm -f "${comp_dir}/fix-plan.contract.json"
        run_agent "$fix_plan_author_role" "$ENGINE_EVALUATOR" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "${comp_dir}/fix-plan.md" "${log_dir}/${fix_plan_author_role}.log" \
            "$EVALUATE_TIMEOUT" "100" || exit_fix_plan=$?

        if [[ "$exit_fix_plan" -ne 0 ]]; then
            if [[ "$exit_fix_plan" -eq 124 ]]; then
                echo -e "${RED}Phase 6 fix-plan-author timed out (${EVALUATE_TIMEOUT})${NC}"
                log_execution "$task_file" "Phase 6: Fix plan author timed out (${EVALUATE_TIMEOUT})"
            else
                echo -e "${RED}Phase 6 fix-plan-author failed (exit $exit_fix_plan)${NC}"
                log_execution "$task_file" "Phase 6: Fix plan author FAILED (exit $exit_fix_plan)"
            fi
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
        fi
        _require_valid_artifact \
            "${comp_dir}/fix-plan.md" \
            "authoring-fix-plan" \
            "Phase 6 fix-plan author produced an invalid fix plan artifact" \
            "Check ${comp_dir}/review-synthesis.md and agent log ${log_dir}/${fix_plan_author_role}.log, then retry" || return 1

        # Signal: fix-plan author READY: no
        local fix_plan_ready=""
        fix_plan_ready=$(_parse_contract "${comp_dir}/fix-plan.md" "ready")
        local fix_plan_ready_upper=""
        fix_plan_ready_upper=$(echo "$fix_plan_ready" | tr '[:lower:]' '[:upper:]')
        if _strict_contract_mode && [[ "$fix_plan_ready_upper" != "YES" && "$fix_plan_ready_upper" != "NO" ]]; then
            echo -e "${RED}Strict mode requires fix-plan.contract.json ready=true|false${NC}"
            set_task_status "$task_file" "blocked"
            log_execution "$task_file" "Phase 6: Strict contract failure for fix-plan ready signal"
            _print_cost_summary
            return 1
        fi
        if [[ "$fix_plan_ready_upper" == "NO" ]]; then
            echo -e "${YELLOW}Fix plan author signaled READY: no — halting for human review${NC}"
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Phase 6: Fix plan READY: no — human review required"
            pipeline_finished=true
            pipeline_human_review_halt=true
            _write_human_review_handoff "READY_NO" "$((fix_cycle))" || true
            break
        fi

        _append_manifest_phase "phase-6b" "fix-plan-author-cycle-$((fix_cycle+1))" "$_phase6b_start" "$(_iso_timestamp)" "completed" "" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-6b" || true
        fi  # end Phase 6b skip guard

        # -- Sub-phase: Phase 6c (fix plan critic) --
        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" != "phase-6c" ]]; then
            echo -e "${BLUE}Phase 6c: Skipped (resuming to ${_resume_to_subphase})${NC}"
        else
        _resume_to_subphase=""
        local _phase6c_start=""
        _phase6c_start=$(_iso_timestamp)
        local fix_critic_prefix="fix-critic${role_suffix}"
        local fix_critic_result=0
        echo -e "${BLUE}=== Phase 6: Critique Fix Plan (cycle $((fix_cycle + 1))) ===${NC}"
        run_critic_loop "$task_file" "$comp_dir" "$critic_prompt" "$reviser_prompt" "${comp_dir}/fix-plan.md" "${comp_dir}/fix-critique.md" 3 "$fix_critic_prefix" "needs verification" "$ENGINE_CRITIC" || fix_critic_result=$?
        case "$fix_critic_result" in
            0)
                set_task_status "$task_file" "in progress"
                log_execution "$task_file" "Phase 6: Fix plan approved"
                ;;
            1)
                echo -e "${YELLOW}Fix plan critic loop halted for human review${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}Fix plan critic loop hard-failed${NC}"
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Phase 6: Fix plan critic loop FAILED"
                log_execution "$task_file" "  recovery hint: Check ${comp_dir}/fix-plan.md for the plan being critiqued. Agent log: ${log_dir}/${fix_critic_prefix}-*.log"
                _print_cost_summary
                return 1
                ;;
        esac
        _append_manifest_phase "phase-6c" "fix-plan-critic-cycle-$((fix_cycle+1))" "$_phase6c_start" "$(_iso_timestamp)" "completed" "" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-6c" || true
        fi  # end Phase 6c skip guard

        # -- Sub-phase: Phase 7 (fix execution) --
        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" != "phase-7" ]]; then
            echo -e "${BLUE}Phase 7: Skipped (resuming to ${_resume_to_subphase})${NC}"
        else
        _resume_to_subphase=""
        echo -e "${BLUE}=== Phase 7: Execute Review Fixes (cycle $((fix_cycle + 1))) ===${NC}"
        local _phase7_start=""
        _phase7_start=$(_iso_timestamp)
        cost_gate_result=0
        _check_cost_ceiling "$task_file" "$comp_dir" "$fix_cycle" || cost_gate_result=$?
        case "$cost_gate_result" in
            0) ;;
            1)
                pipeline_finished=true
                pipeline_human_review_halt=true
                break
                ;;
            *)
                set_task_status "$task_file" "blocked"
                _print_cost_summary
                return 1
                ;;
        esac
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 7: Fix execution started (cycle $((fix_cycle + 1)))"

        local pre_fix_sha=""
        pre_fix_sha=$(git rev-parse HEAD 2>/dev/null || true)
        local pre_fix_scope_plan=""
        pre_fix_scope_plan=$(_v2_select_phase7_scope_plan_file "$comp_dir")
        local pre_fix_untracked=""
        pre_fix_untracked=$(_collect_blocking_untracked_files "$task_file" "$pre_fix_scope_plan" "$pre_fix_sha")
        local pre_fix_dirty=""
        pre_fix_dirty=$(_v2_snapshot_dirty_files)
        local fix_executor_role="fix-executor${role_suffix}"
        local fix_exec_instruction="The task file is ${task_file}. Read ${comp_dir}/review-synthesis.md and ${comp_dir}/fix-plan.md. Execute the planned fixes and write execution progress to ${comp_dir}/fix-execution.md."
        prepare_agent_request "$ENGINE_FIX" "$fix_executor_prompt" "$fix_exec_instruction" || {
            _fail_phase "executing-fixes" "Failed to assemble fix-executor prompt" "See ${comp_dir}/fix-execution.md for blocking issues. Address manually, then retry"
        }

        local exit_fix_exec=0
        rm -f "${comp_dir}/fix-execution.contract.json"
        touch "${log_dir}/${fix_executor_role}.log"
        start_agent_monitor "${log_dir}/${fix_executor_role}.log" "$task_file"
        run_agent "$fix_executor_role" "$ENGINE_FIX" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "/dev/null" "${log_dir}/${fix_executor_role}.log" \
            "$EXECUTOR_TIMEOUT" "300" "WebFetch,WebSearch" || exit_fix_exec=$?
        stop_agent_monitor

        # Signal: fix executor STATUS: BLOCKED
        local fix_exec_status=""
        fix_exec_status=$(_parse_contract "${comp_dir}/fix-execution.md" "status")
        local fix_exec_status_upper=""
        fix_exec_status_upper=$(echo "$fix_exec_status" | tr '[:lower:]' '[:upper:]')
        if _strict_contract_mode && [[ "$fix_exec_status_upper" != "COMPLETE" && "$fix_exec_status_upper" != "BLOCKED" ]]; then
            echo -e "${RED}Strict mode requires fix-execution.contract.json status=COMPLETE|BLOCKED${NC}"
            set_task_status "$task_file" "blocked"
            log_execution "$task_file" "Phase 7: Strict contract failure for fix-execution status signal"
            _print_cost_summary
            return 1
        fi
        if [[ "$fix_exec_status_upper" == "BLOCKED" ]]; then
            echo -e "${YELLOW}Fix executor signaled BLOCKED — halting for human review${NC}"
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Phase 7: Fix executor STATUS: BLOCKED — human review required"
            _write_human_review_handoff "BLOCKED" "$((fix_cycle + 1))" || true
            _mark_fix_execution_handoff || true
            pipeline_finished=true
            pipeline_human_review_halt=true
            break
        fi

        if [[ "$exit_fix_exec" -ne 0 ]]; then
            if [[ "$exit_fix_exec" -eq 124 ]]; then
                echo -e "${RED}Phase 7 timed out (${EXECUTOR_TIMEOUT})${NC}"
                log_execution "$task_file" "Phase 7: Fix execution timed out (${EXECUTOR_TIMEOUT})"
            else
                echo -e "${RED}Phase 7 failed (exit $exit_fix_exec)${NC}"
                log_execution "$task_file" "Phase 7: Fix execution FAILED (exit $exit_fix_exec)"
            fi
            set_task_status "$task_file" "blocked"
            _print_cost_summary
            return 1
        fi

        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 7: Fix execution completed"

        latest_fix_diff="${comp_dir}/fix-diff-cycle$((fix_cycle + 1)).patch"
        local phase7_scope_plan_file=""
        phase7_scope_plan_file=$(_v2_select_phase7_scope_plan_file "$comp_dir")
        if [[ -n "$phase7_scope_plan_file" ]]; then
            log_execution "$task_file" "Phase 7: Scope plan file: ${phase7_scope_plan_file}" || true
        else
            log_execution "$task_file" "Phase 7: Scope plan file: fallback only" || true
        fi
        capture_diff_artifact "$pre_fix_sha" "$latest_fix_diff" "$task_file" "$phase7_scope_plan_file" "$pre_fix_dirty"
        _v2_log_capture_scope_details "$task_file" "Phase 7"
        if [[ ! -s "$latest_fix_diff" ]]; then
            if _strict_contract_mode; then
                echo -e "${RED}Strict mode requires a non-empty fix execution diff${NC}"
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Phase 7: Strict mode blocked empty fix execution diff"
                _print_cost_summary
                return 1
            fi
            echo -e "${YELLOW}WARN: Fix execution diff is empty after cycle $((fix_cycle + 1))${NC}"
            log_execution "$task_file" "Phase 7: Fix execution diff captured but empty"
        else
            log_execution "$task_file" "Phase 7: Fix execution diff captured at ${latest_fix_diff}"
        fi

        _v2_log_out_of_scope_capture_warning "$task_file" "Phase 7" || true
        _block_on_untracked_files "$task_file" "Phase 7" "$phase7_scope_plan_file" "$pre_fix_sha" "$pre_fix_untracked" || return 1
        _append_manifest_phase "phase-7" "fix-exec-cycle-$((fix_cycle+1))" "${_phase7_start:-$(_iso_timestamp)}" "$(_iso_timestamp)" "completed" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-7" || true
        fi  # end Phase 7 skip guard

        _resume_to_subphase=""
        fix_cycle=$((fix_cycle + 1))
    done

    if [[ "$pipeline_success" == true ]]; then
        log_execution "$task_file" "Pipeline complete — status: $(grep '^## Status:' "$task_file" | sed 's/## Status: //')"
    fi
    local _final_status="completed"
    [[ "$pipeline_success" == true ]] && _final_status="success"
    [[ "$pipeline_human_review_halt" == true ]] && _final_status="human_review"
    _finalize_run_manifest "$_final_status" "$fix_cycle" || true
    _print_cost_summary
    _print_phase_timing || true
    if [[ "$pipeline_success" == true ]]; then
        notify_terminal_state "pass" "Pipeline complete — ${slug}" || true
        echo -e "${GREEN}=== Competitive pipeline complete ===${NC}"
    elif [[ "$pipeline_human_review_halt" == true ]]; then
        # Safety net: some halt paths (cost ceiling) don't set status individually.
        # Invert the check: if status is NOT already terminal, set it.
        local _halt_status=""
        _halt_status=$(grep '^## Status: ' "$task_file" 2>/dev/null | sed 's/^## Status: //' || true)
        if [[ -n "$_halt_status" ]] && ! _is_terminal_status "$_halt_status"; then
            set_task_status "$task_file" "needs verification" || true
        fi
        notify_terminal_state "human-review" "Human review needed — ${slug}" || true
        echo -e "${YELLOW}=== Competitive pipeline halted for human review ===${NC}"
    else
        set_task_status "$task_file" "blocked" || true
        notify_terminal_state "blocked" "Pipeline finished without success — ${slug}" || true
        echo -e "${BLUE}=== Competitive pipeline finished ===${NC}"
    fi
    echo -e "${GREEN}Task file: ${task_file}${NC}"
    echo -e "${GREEN}Competitive artifacts: ${comp_dir}/${NC}"
    echo -e "${GREEN}Logs: ${log_dir}/${NC}"
}

# ============================================================
# CLI Entry Point
# ============================================================

usage() {
    echo "Usage: $0 <slug> <goal> [--dry-run] [--model <model>] [--force] [--strict]"
    echo ""
    echo "Subcommands:"
    echo "  chaos <slug>                  Run chaos-critic against approved plan"
    echo "  verify <slug>                 Goal-backward verification of task outcomes"
    echo "  plan-check <slug>             Validate XML plan structure"
    echo "  progress <slug>               Show task progress summary"
    echo "  pause <slug>                  Snapshot task state for later resume"
    echo "  resume <slug>                 Restore paused task and continue"
    echo "  notify-dry-run <slug>         Test terminal notification without running pipeline"
    # === INSERT NEW SUBCOMMAND USAGE ABOVE ===
    echo ""
    echo "Options:"
    echo "  --dry-run    Print planned phases without executing"
    echo "  --model      Set model (default: opus)"
    echo "  --force      Force rerun of all phases (skip checkpoint checks)"
    echo "  --strict     Require JSON contract sidecars and stricter runtime gates"
    exit 1
}

# ============================================================
# Subcommand Dispatch
# ============================================================
# Each subcommand is a self-contained block that shifts args and exits.
# The main pipeline (slug + goal) falls through if no subcommand matches.

# ============================================================
# Subcommand: plan-check — Validate XML plan structure
# ============================================================
if [[ "${1:-}" == "plan-check" ]]; then
    shift

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Usage: $0 plan-check <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    TASK_DIR="$SCRIPT_DIR/docs/tasks/open/${SLUG}"

    if [[ ! -d "$TASK_DIR" ]]; then
        echo -e "${RED}Task directory not found: $TASK_DIR${NC}"
        exit 1
    fi

    # Find main task .md file in the task directory
    TASK_FILE=$(find "$TASK_DIR" -maxdepth 1 -name '*.md' ! -name 'human-review-handoff.md' | head -1)

    if [[ -z "$TASK_FILE" || ! -f "$TASK_FILE" ]]; then
        echo -e "${RED}No task markdown file found in: $TASK_DIR${NC}"
        exit 1
    fi

    # Extract plan section
    PLAN_CONTENT=$(_plancheck_extract_plan "$TASK_FILE")
    if [[ -z "$PLAN_CONTENT" ]]; then
        echo -e "${RED}No plan found in task file${NC}"
        exit 1
    fi

    echo -e "${BLUE}Validating plan structure...${NC}"

    # Detect format
    if _plancheck_is_xml "$PLAN_CONTENT"; then
        echo "  Format: XML"
        _plancheck_validate_xml "$PLAN_CONTENT"
        RESULT=$?
    else
        echo -e "  ${YELLOW}Format: Legacy (numbered steps) — consider migrating to XML${NC}"
        RESULT=0
    fi

    if [[ "$RESULT" -eq 0 ]]; then
        echo -e "${GREEN}Plan validation passed${NC}"
    else
        echo -e "${RED}Plan validation failed${NC}"
    fi
    exit "$RESULT"
fi

# ============================================================
# Subcommand: verify — Goal-backward verification of task outcomes
# ============================================================
if [[ "${1:-}" == "verify" ]]; then
    shift

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Usage: $0 verify <slug> [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    # Parse optional flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            *) echo -e "${RED}Unknown option for 'verify': $1${NC}"; usage ;;
        esac
    done

    TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"
    VERIFY_PROMPT="$SCRIPT_DIR/prompts/verifier.md"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1
    _CURRENT_TASK_FILE="$TASK_FILE"

    if [[ ! -f "$VERIFY_PROMPT" ]]; then
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

    if [[ -z "$GOAL_TEXT" ]]; then
        echo -e "${RED}No goal found in task file${NC}"
        exit 1
    fi

    echo -e "${BLUE}Running goal verifier (model: $MODEL)...${NC}"

    COMP_DIR="${TASK_DIR}/competitive"
    TASK_LOG_DIR="${TASK_DIR}/logs"
    mkdir -p "$COMP_DIR" "$TASK_LOG_DIR"
    LOG_FILE="${TASK_LOG_DIR}/verify.log"

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

    # Write verification artifact to competitive dir
    VERIFY_ARTIFACT="${COMP_DIR}/verification-${SLUG}.md"
    {
        echo "# Verification: ${SLUG}"
        echo ""
        echo "Verified: $(_iso_timestamp) | PASS: ${PASS_COUNT} | FAIL: ${FAIL_COUNT}"
        echo ""
        cat "$VERIFY_OUTPUT"
    } > "$VERIFY_ARTIFACT"

    # Also append results to task file
    _verify_append_results "$TASK_FILE" "$VERIFY_OUTPUT" "$PASS_COUNT" "$FAIL_COUNT"

    echo ""
    echo -e "${BLUE}Verification results:${NC}"
    echo "  PASS: $PASS_COUNT / $TOTAL"
    echo "  FAIL: $FAIL_COUNT / $TOTAL"
    echo "  Artifact: $VERIFY_ARTIFACT"

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
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
# Subcommand: chaos — Run chaos-critic against approved plan
# ============================================================
if [[ "${1:-}" == "chaos" ]]; then
    shift

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Usage: $0 chaos <slug> [--model <model>]${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    # Parse optional flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model) MODEL="$2"; shift 2 ;;
            *) echo -e "${RED}Unknown option for 'chaos': $1${NC}"; usage ;;
        esac
    done

    TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"
    CHAOS_PROMPT="$SCRIPT_DIR/prompts/chaos-critic.md"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1
    if [[ ! -f "$CHAOS_PROMPT" ]]; then
        echo -e "${RED}Chaos-critic prompt not found: $CHAOS_PROMPT${NC}"
        exit 1
    fi

    _CURRENT_TASK_FILE="$TASK_FILE"

    # Status gate: only plan-approved tasks
    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    if [[ "$CURRENT_STATUS" != "plan-approved" && "$CURRENT_STATUS" != "planned" ]]; then
        echo -e "${RED}Task status is '$CURRENT_STATUS', expected 'plan-approved' or 'planned'${NC}"
        exit 1
    fi

    # Extract plan from task file
    PLAN_CONTENT=$(_chaos_extract_plan "$TASK_FILE")
    if [[ -z "$PLAN_CONTENT" ]]; then
        echo -e "${RED}No plan found in task file${NC}"
        exit 1
    fi

    echo -e "${BLUE}Running chaos-critic (model: $MODEL)...${NC}"

    # Ensure competitive dir exists for artifact output
    COMP_DIR="$TASK_DIR/competitive"
    mkdir -p "$COMP_DIR"
    LOG_DIR_V2="$TASK_DIR/logs"
    mkdir -p "$LOG_DIR_V2"

    LOG_FILE="$LOG_DIR_V2/chaos-critic.log"
    CHAOS_ARTIFACT="$COMP_DIR/chaos-findings.md"

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

    if [[ "$BLOCKING_COUNT" -gt 0 ]]; then
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
# Subcommand: progress — Show task progress summary
# ============================================================
if [[ "${1:-}" == "progress" ]]; then
    shift

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Usage: $0 progress <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"
    STATE_FILE="$SCRIPT_DIR/.planning/${SLUG}.json"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1

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

    # Show competitive artifacts if present
    COMP_DIR="${TASK_DIR}/competitive"
    if [ -d "$COMP_DIR" ]; then
        ARTIFACT_COUNT=$(ls "$COMP_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
        if [ "$ARTIFACT_COUNT" -gt 0 ]; then
            echo ""
            echo -e "${BLUE}Competitive artifacts: ${ARTIFACT_COUNT} files${NC}"
        fi
    fi

    # Show exploration notes if present
    if [ -d "$COMP_DIR" ] && ls "$COMP_DIR"/explore-*.md &>/dev/null; then
        echo -e "  Exploration notes found"
    fi

    # Show execution log tail
    _state_show_recent_log "$TASK_FILE"

    exit 0
fi

# ============================================================
# Subcommand: pause — Snapshot task state for later resume
# ============================================================
if [[ "${1:-}" == "pause" ]]; then
    shift

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Usage: $0 pause <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1

    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')

    # Create .planning directory
    mkdir -p "$SCRIPT_DIR/.planning"

    # Capture state snapshot (include V2-specific fields)
    _state_write_snapshot "$SLUG" "$TASK_FILE" "$CURRENT_STATUS"

    # Append V2-specific fields (phase, competitive dir)
    COMP_DIR="${TASK_DIR}/competitive"
    if [ -d "$COMP_DIR" ]; then
        ARTIFACT_COUNT=$(ls "$COMP_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
    else
        ARTIFACT_COUNT=0
    fi

    STATE_FILE="$SCRIPT_DIR/.planning/${SLUG}.json"
    # Rewrite with V2 fields using python for safe JSON merge
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
d['Lauren Loop'] = 'v2'
d['competitive_artifacts'] = int(sys.argv[2])
d['task_dir'] = sys.argv[3]
with open(sys.argv[1], 'w') as f:
    json.dump(d, f, indent=4)
    f.write('\n')
" "$STATE_FILE" "$ARTIFACT_COUNT" "$TASK_DIR" 2>/dev/null
    fi

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
if [[ "${1:-}" == "resume" ]]; then
    shift

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Usage: $0 resume <slug>${NC}"
        exit 1
    fi

    SLUG="$1"
    shift

    TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"
    STATE_FILE="$SCRIPT_DIR/.planning/${SLUG}.json"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1

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

    # Check competitive artifacts if V2
    COMP_DIR="${TASK_DIR}/competitive"
    if [ -d "$COMP_DIR" ]; then
        COMP_COUNT=$(ls "$COMP_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
        echo "  Competitive artifacts: $COMP_COUNT"
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
# Subcommand: notify-dry-run — Test terminal notification
# ============================================================
if [[ "${1:-}" == "notify-dry-run" ]]; then
    shift

    if [[ $# -lt 1 ]]; then
        echo -e "${RED}Usage: $0 notify-dry-run <slug>${NC}"
        exit 1
    fi

    slug="$1"
    notify_terminal_state "pass" "Dry-run notification test — ${slug}"
    exit 0
fi

# === INSERT NEW SUBCOMMANDS ABOVE ===

# Parse args — main pipeline (no subcommand matched)
if [[ $# -lt 2 ]]; then
    usage
fi

SLUG="$1"; shift
GOAL="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --model) MODEL="$2"; shift 2 ;;
        --internal) INTERNAL=true; shift ;;
        --force) FORCE_RERUN=true; shift ;;
        --strict) LAUREN_LOOP_STRICT=true; shift ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
    esac
done

_apply_effective_strict_mode "$SLUG" "$GOAL"

if [[ "$LAUREN_LOOP_EFFECTIVE_STRICT" == "true" && "$DRY_RUN" != "true" ]]; then
    if [[ ! "$LAUREN_LOOP_MAX_COST" =~ ^[0-9]+([.][0-9]+)?$ ]] || awk -v max="$LAUREN_LOOP_MAX_COST" 'BEGIN { exit !(max <= 0) }'; then
        echo -e "${RED}Strict mode requires LAUREN_LOOP_MAX_COST to be set to a positive value for live runs.${NC}"
        exit 1
    fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
    setup_azure_context 2>/dev/null || true
fi

if [[ "$DRY_RUN" = true ]]; then
    echo -e "${BLUE}=== Competitive Lauren Loop — Dry Run ===${NC}"
    echo ""
    echo "  Slug:    $SLUG"
    echo "  Goal:    $GOAL"
    echo "  Model:   $MODEL"
    echo "  Strict:  $LAUREN_LOOP_EFFECTIVE_STRICT"
    if [[ "$LAUREN_LOOP_AUTO_STRICT" == "true" ]]; then
        echo "  Strict reason: auto (${LAUREN_LOOP_AUTO_STRICT_REASON})"
    elif [[ "$LAUREN_LOOP_STRICT" == "true" ]]; then
        echo "  Strict reason: explicit --strict / LAUREN_LOOP_STRICT"
    fi
    echo ""
    echo "  Task dir:  docs/tasks/open/${SLUG}/"
    echo "  Artifacts: docs/tasks/open/${SLUG}/competitive/"
    echo "  Logs:      docs/tasks/open/${SLUG}/logs/"
    echo ""
    echo -e "${BLUE}--- 7-Phase Pipeline ---${NC}"
    echo ""
    echo "  Phase 1: Explore             | engine=$ENGINE_EXPLORE | timeout=$EXPLORE_TIMEOUT"
    echo "  Phase 2: Plan (||)           | engine=${ENGINE_PLANNER_A}+${ENGINE_PLANNER_B} | timeout=$PLANNER_TIMEOUT"
    echo "  Phase 3: Evaluate + Critic   | engine=${ENGINE_EVALUATOR}+${ENGINE_CRITIC} | timeout=${EVALUATE_TIMEOUT}/${CRITIC_TIMEOUT}"
    echo "  Phase 4: Execute             | engine=$ENGINE_EXECUTOR | timeout=$EXECUTOR_TIMEOUT"
    echo "  Phase 5: Review (||)         | engine=${ENGINE_REVIEWER_A}+${ENGINE_REVIEWER_B} | timeout=$REVIEWER_TIMEOUT"
    echo "  Phase 6: Evaluate/Fix Plan   | engine=${ENGINE_EVALUATOR}+${ENGINE_CRITIC} | timeout=${SYNTHESIZE_TIMEOUT}/${CRITIC_TIMEOUT}"
    echo "  Phase 7: Execute Fixes       | engine=$ENGINE_FIX | timeout=$EXECUTOR_TIMEOUT"
    echo "    Loopback: Phase 5 after Phase 7 until review PASS or 2 fix cycles are exhausted"
    echo ""

    # Validate prompt files
    local_missing=0
    echo -e "${BLUE}--- Prompt File Check ---${NC}"
    for label_and_path in \
        "explore:$SCRIPT_DIR/prompts/exploration-summarizer.md" \
        "planner-a:$SCRIPT_DIR/prompts/planner-a.md" \
        "planner-b:$SCRIPT_DIR/prompts/planner-b.md" \
        "evaluator:$SCRIPT_DIR/prompts/plan-evaluator.md" \
        "critic:$SCRIPT_DIR/prompts/critic.md" \
        "reviser:$SCRIPT_DIR/prompts/reviser.md" \
        "executor:$SCRIPT_DIR/prompts/executor.md" \
        "reviewer-a:$SCRIPT_DIR/prompts/reviewer.md" \
        "reviewer-b:$SCRIPT_DIR/prompts/reviewer-b.md" \
        "review-evaluator:$SCRIPT_DIR/prompts/review-evaluator.md" \
        "fix-plan-author:$SCRIPT_DIR/prompts/fix-plan-author.md" \
        "fix-executor:$SCRIPT_DIR/prompts/fix-executor.md"; do
        local_label="${label_and_path%%:*}"
        local_path="${label_and_path##*:}"
        if [[ -f "$local_path" ]]; then
            local_preview=$(head -3 "$local_path" | tr '\n' ' ' | cut -c1-60)
            echo -e "  ${GREEN}OK${NC}  $local_label: $local_preview..."
        else
            echo -e "  ${RED}MISSING${NC}  $local_label: $local_path"
            local_missing=$((local_missing + 1))
        fi
    done
    echo ""

    if [[ "$local_missing" -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $local_missing prompt file(s) missing — live run will fail${NC}"
    else
        echo -e "${GREEN}All prompt files present${NC}"
    fi
    exit 0
fi

trap '_interrupted INT' INT
trap '_interrupted TERM' TERM
trap '_interrupted HUP' HUP

acquire_lock
_oc_rc=0
lauren_loop_competitive "$SLUG" "$GOAL" || _oc_rc=$?
if [[ "$_oc_rc" -ne 0 ]]; then
    notify_terminal_state "blocked" "Pipeline blocked — ${SLUG}" || true
    exit "$_oc_rc"
fi

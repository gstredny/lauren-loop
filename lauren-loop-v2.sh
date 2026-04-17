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
FORCE_RERUN="${FORCE_RERUN:-false}"
AGENT_SETTINGS='{"disableAllHooks":true}'
## Pricing constants + CSV headers — now in lib/lauren-loop-utils.sh
[[ -f "$HOME/.claude/scripts/context-guard.sh" ]] && source "$HOME/.claude/scripts/context-guard.sh"
# Ensure function exists even if context-guard.sh is absent
type setup_azure_context &>/dev/null || setup_azure_context() { :; }
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
ENGINE_EXECUTOR="${ENGINE_EXECUTOR:-claude}"      # Stream fix shipped (2026-03-07). Codex eligible but kept on claude for executor stability.
ENGINE_REVIEWER_A="${ENGINE_REVIEWER_A:-claude}"  # Phase 6a
ENGINE_REVIEWER_B="${ENGINE_REVIEWER_B:-codex}"   # Phase 6b
ENGINE_FIX="${ENGINE_FIX:-claude}"                # Stream fix shipped (2026-03-07). Codex eligible but kept on claude for fix stability.
ENGINE_FINAL_VERIFY="${ENGINE_FINAL_VERIFY:-codex}"
ENGINE_FINAL_FALSIFY="${ENGINE_FINAL_FALSIFY:-codex}"
ENGINE_FINAL_FIX="${ENGINE_FINAL_FIX:-codex}"
_V2_CODEX_RUN_FAILURES=0                          # Tracks Codex failures (after internal retries) within a single run
_V2_CODEX_AUTH_PREFLIGHT_RAN=false
_V2_CODEX_AUTH_CIRCUIT_OPEN=false
_V2_CODEX_AUTH_CIRCUIT_MESSAGE=""
_V2_EFFECTIVE_ENGINE=""
_V2_LAST_ENGINE_RESOLUTION_REASON="none"
_V2_LAST_ENGINE_RESOLUTION_REQUESTED=""
_V2_LAST_ENGINE_RESOLUTION_RESULT=""
# Timeouts (env-overridable)
EXPLORE_TIMEOUT="${EXPLORE_TIMEOUT:-30m}"
PLANNER_TIMEOUT="${PLANNER_TIMEOUT:-30m}"
EVALUATE_TIMEOUT="${EVALUATE_TIMEOUT:-30m}"
CRITIC_TIMEOUT="${CRITIC_TIMEOUT:-30m}"
EXECUTOR_TIMEOUT="${EXECUTOR_TIMEOUT:-120m}"
REVIEWER_TIMEOUT_EXPLICIT="false"
[[ -n "${REVIEWER_TIMEOUT:-}" ]] && REVIEWER_TIMEOUT_EXPLICIT="true"
REVIEWER_TIMEOUT="${REVIEWER_TIMEOUT:-30m}"
SYNTHESIZE_TIMEOUT="${SYNTHESIZE_TIMEOUT:-30m}"
PHASE8C_TIMEOUT="${PHASE8C_TIMEOUT:-60m}"

# Lock
LOCK_DIR="/tmp/lauren-loop-v2.lock.d"
_LOCK_ACQUIRED=false
_CURRENT_TASK_FILE=""
_CURRENT_TASK_LOG_DIR=""
_CLEANUP_V2_RUNNING=false
_CLEANUP_V2_DONE=false
_COST_CEILING_WARNED=false
_COST_CEILING_INTERRUPT_WARNED=false
_PIPELINE_PRE_SHA=""
_PIPELINE_START_TS=""
_V2_EXEC_WORKTREE_PATH=""
_V2_EXEC_WORKTREE_BRANCH=""
_V2_EXEC_TARGET_REF=""
_V2_EXEC_TARGET_HEAD_SHA=""
_V2_EXEC_PREEXISTING_ROOT_DIRTY=""
_V2_LAST_MERGE_RECOVERABLE=false
_V2_PRESERVED_EXEC_WORKTREE_PATH=""
_V2_PRESERVED_EXEC_WORKTREE_BRANCH=""
_V2_PRESERVED_EXEC_TARGET_REF=""
_V2_PRESERVED_EXEC_TARGET_HEAD_SHA=""
_V2_PRESERVED_EXEC_COMMIT_SHA=""
_V2_PRESERVED_RECOVERY_DIR=""
_V2_PRESERVED_COMBINED_PATCH=""
_V2_PRESERVED_COMMIT_LOG=""
_V2_PRESERVED_FORMAT_PATCH_DIR=""
_V2_PRESERVED_WORKTREE_PATCH=""

_v2_task_artifact_dir() {
    printf '%s/docs/tasks/open/%s\n' "$SCRIPT_DIR" "$1"
}

_v2_task_dir_for_task_file() {
    local task_file="$1"
    case "$task_file" in
        */task.md)
            dirname "$task_file"
            ;;
        *.md)
            printf '%s/%s\n' "$(dirname "$task_file")" "$(basename "$task_file" .md)"
            ;;
        *)
            return 1
            ;;
    esac
}

_v2_collect_nested_exact_task_matches() {
    local open_root="$1"
    local slug="$2"
    local dir_task="$3"
    local flat_task="$4"

    find "$open_root" -type f \
        \( -name "${slug}.md" -o -path "*/${slug}/task.md" \) \
        ! -path "$flat_task" \
        ! -path "$dir_task" \
        ! -path '*/competitive/*' \
        ! -path '*/logs/*' | sort
}

_v2_collect_nightshift_manager_matches() {
    local open_root="$1"
    local slug="$2"

    find "${open_root}/nightshift" -maxdepth 1 -type f \
        -name "????-??-??-${slug}.md" \
        ! -path '*/competitive/*' \
        ! -path '*/logs/*' | sort 2>/dev/null || true
}

_v2_task_file_hint_matches_slug() {
    local task_file="$1"
    local slug="$2"
    local base_name=""

    [[ -n "$task_file" && -f "$task_file" ]] || return 1

    case "$task_file" in
        */task.md)
            base_name="$(basename "$(dirname "$task_file")")"
            ;;
        *.md)
            base_name="$(basename "$task_file" .md)"
            ;;
        *)
            return 1
            ;;
    esac

    if [[ "$base_name" == "$slug" || "$base_name" == "pilot-${slug}" ]]; then
        return 0
    fi

    [[ "$base_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-${slug}$ ]]
}

_v2_should_preserve_flat_task_file() {
    local task_file="$1"

    case "$task_file" in
        */docs/tasks/open/nightshift/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.md)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_resolve_v2_task_file() {
    local slug="$1"
    local open_root="$SCRIPT_DIR/docs/tasks/open"
    local task_dir="$(_v2_task_artifact_dir "$slug")"
    local flat_task="${open_root}/${slug}.md"
    local dir_task="${task_dir}/task.md"
    local candidate=""
    local nested_matches=""
    local first_nested=""
    local second_nested=""
    local hint_task="${LAUREN_LOOP_TASK_FILE_HINT:-}"
    local nightshift_matches=""
    local first_nightshift=""
    local second_nightshift=""

    if [[ -n "$hint_task" && "$hint_task" != /* ]]; then
        hint_task="${SCRIPT_DIR}/${hint_task#./}"
    fi

    if [[ -f "$dir_task" && -f "$flat_task" ]]; then
        echo "ERROR: ambiguous task slug '$slug' matches both $flat_task and $dir_task" >&2
        return 2
    fi

    if _v2_task_file_hint_matches_slug "$hint_task" "$slug"; then
        candidate="$hint_task"
    elif [[ -f "$dir_task" ]]; then
        candidate="$dir_task"
    elif [[ -f "$flat_task" ]]; then
        candidate="$flat_task"
    elif [[ -f "${open_root}/pilot-${slug}.md" ]]; then
        candidate="${open_root}/pilot-${slug}.md"
    else
        nested_matches=$(_v2_collect_nested_exact_task_matches "$open_root" "$slug" "$dir_task" "$flat_task")
        first_nested=$(printf '%s\n' "$nested_matches" | sed -n '1p')
        second_nested=$(printf '%s\n' "$nested_matches" | sed -n '2p')
        if [[ -n "$second_nested" ]]; then
            echo "ERROR: ambiguous task slug '$slug' matches multiple nested task files:" >&2
            while IFS= read -r candidate; do
                [[ -n "$candidate" ]] || continue
                printf '  %s\n' "$candidate" >&2
            done <<< "$nested_matches"
            return 2
        fi
        if [[ -n "$first_nested" ]]; then
            candidate="$first_nested"
        else
            nightshift_matches="$(_v2_collect_nightshift_manager_matches "$open_root" "$slug")"
            first_nightshift=$(printf '%s\n' "$nightshift_matches" | sed -n '1p')
            second_nightshift=$(printf '%s\n' "$nightshift_matches" | sed -n '2p')
            if [[ -n "$second_nightshift" ]]; then
                echo "ERROR: ambiguous nightshift task slug '$slug' matches multiple manager task files:" >&2
                while IFS= read -r candidate; do
                    [[ -n "$candidate" ]] || continue
                    printf '  %s\n' "$candidate" >&2
                done <<< "$nightshift_matches"
                return 2
            fi
            if [[ -n "$first_nightshift" ]]; then
                candidate="$first_nightshift"
            elif [[ -d "$task_dir" ]]; then
                candidate=$(find "$task_dir" -maxdepth 1 -name "*.md" ! -path "*/competitive/*" ! -path "*/logs/*" | sort | head -1)
            fi
        fi
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

_resolve_reviewer_timeout() {
    local diff_risk="${1:-LOW}"

    if [[ "${REVIEWER_TIMEOUT_EXPLICIT:-false}" == "true" ]] && [[ -n "${REVIEWER_TIMEOUT:-}" ]]; then
        printf '%s\n' "$REVIEWER_TIMEOUT"
        return 0
    fi

    case "$diff_risk" in
        HIGH) printf '45m\n' ;;
        MEDIUM) printf '30m\n' ;;
        LOW|"") printf '15m\n' ;;
        *) printf '15m\n' ;;
    esac
}

_reviewer_timeout_resolution_source() {
    if [[ "${REVIEWER_TIMEOUT_EXPLICIT:-false}" == "true" ]] && [[ -n "${REVIEWER_TIMEOUT:-}" ]]; then
        printf 'explicit-override\n'
    else
        printf 'diff-risk-scaling\n'
    fi
}

# Run manifest schema:
# Root fields:
#   run_id, slug, goal, started_at, model, engines, force_rerun, current_phase,
#   active_engines, diff_risk, effective_timeouts, phases, completed_at,
#   total_cost_usd, final_status, fix_cycles, traditional_dev_proxy.
# Phase entry fields:
#   phase, name, started_at, completed_at, status, verdict, cost.
# Error metadata fields (present only when provided by the caller):
#   error_class, error_detail.
# Canonical error_class values currently include:
#   unknown, timeout, invalid_artifact, scope_violation, merge_failure,
#   codex_capacity, codex_stream, codex_circuit_breaker.
_init_run_manifest() {
    local manifest_dir="${comp_dir:-}"
    [[ -n "$manifest_dir" ]] || return 0
    local manifest="${manifest_dir}/run-manifest.json"
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
        --arg engine_final_verify "$ENGINE_FINAL_VERIFY" \
        --arg engine_final_falsify "$ENGINE_FINAL_FALSIFY" \
        --arg engine_final_fix "$ENGINE_FINAL_FIX" \
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
                fix: $engine_fix,
                final_verify: $engine_final_verify,
                final_falsify: $engine_final_falsify,
                final_fix: $engine_final_fix
            },
            force_rerun: $force_rerun,
            current_phase: null,
            active_engines: {
                explore: $engine_explore,
                planner_a: $engine_planner_a,
                planner_b: $engine_planner_b,
                evaluator: $engine_evaluator,
                executor: $engine_executor,
                reviewer_a: $engine_reviewer_a,
                reviewer_b: $engine_reviewer_b,
                fix: $engine_fix,
                final_verify: $engine_final_verify,
                final_falsify: $engine_final_falsify,
                final_fix: $engine_final_fix
            },
            diff_risk: null,
            effective_timeouts: {
                reviewer: null
            },
            phases: []
        }' > "$tmp" && mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

_update_run_manifest_state() {
    local current_phase="$1" diff_risk="${2:-}" reviewer_timeout="${3:-}"
    local reviewer_a_engine="${4:-$ENGINE_REVIEWER_A}" reviewer_b_engine="${5:-$ENGINE_REVIEWER_B}"
    local final_verify_engine="${6:-$ENGINE_FINAL_VERIFY}" final_falsify_engine="${7:-$ENGINE_FINAL_FALSIFY}"
    local final_fix_engine="${8:-$ENGINE_FINAL_FIX}"
    local manifest_dir="${comp_dir:-}"
    [[ -n "$manifest_dir" ]] || return 0
    local manifest="${manifest_dir}/run-manifest.json"
    command -v jq >/dev/null 2>&1 || return 0
    [[ -f "$manifest" ]] || return 0
    local tmp
    tmp=$(same_dir_temp_file "$manifest") || return 1
    jq --arg current_phase "$current_phase" \
       --arg engine_explore "$ENGINE_EXPLORE" \
       --arg engine_planner_a "$ENGINE_PLANNER_A" \
       --arg engine_planner_b "$ENGINE_PLANNER_B" \
       --arg engine_evaluator "$ENGINE_EVALUATOR" \
       --arg engine_executor "$ENGINE_EXECUTOR" \
       --arg engine_reviewer_a "$reviewer_a_engine" \
       --arg engine_reviewer_b "$reviewer_b_engine" \
       --arg engine_fix "$ENGINE_FIX" \
       --arg engine_final_verify "$final_verify_engine" \
       --arg engine_final_falsify "$final_falsify_engine" \
       --arg engine_final_fix "$final_fix_engine" \
       --arg diff_risk "$diff_risk" \
       --arg reviewer_timeout "$reviewer_timeout" \
       '(.diff_risk // null) as $existing_diff_risk |
        (.effective_timeouts // {}) as $existing_timeouts |
        .current_phase = $current_phase |
        .active_engines = {
            explore: $engine_explore,
            planner_a: $engine_planner_a,
            planner_b: $engine_planner_b,
            evaluator: $engine_evaluator,
            executor: $engine_executor,
            reviewer_a: $engine_reviewer_a,
            reviewer_b: $engine_reviewer_b,
            fix: $engine_fix,
            final_verify: $engine_final_verify,
            final_falsify: $engine_final_falsify,
            final_fix: $engine_final_fix
        } |
        .diff_risk = (if $diff_risk == "" then $existing_diff_risk else $diff_risk end) |
        .effective_timeouts = ($existing_timeouts + {
            reviewer: (if $reviewer_timeout == "" then ($existing_timeouts.reviewer // null) else $reviewer_timeout end)
        })' "$manifest" > "$tmp" && mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

_append_manifest_phase() {
    local phase="$1" name="$2" started_at="$3" completed_at="$4" status="$5"
    local verdict="${6:-}" cost="${7:-}" error_class="${8:-}" error_detail="${9:-}" recovery_json="${10:-null}"
    local normalized_error_detail="$error_detail"
    local manifest_dir="${comp_dir:-}"
    [[ -n "$manifest_dir" ]] || return 0
    local manifest="${manifest_dir}/run-manifest.json"
    command -v jq >/dev/null 2>&1 || return 0
    [[ -f "$manifest" ]] || return 0
    if ! printf '%s' "$recovery_json" | jq -e . >/dev/null 2>&1; then
        recovery_json="null"
    fi
    if [[ -n "$error_class" || -n "$error_detail" ]]; then
        normalized_error_detail=$(printf '%s' "$error_detail" | tr '\r\n' '  ')
        if [[ ${#normalized_error_detail} -gt 200 ]]; then
            normalized_error_detail="${normalized_error_detail:0:200}"
        fi
    fi
    local tmp
    tmp=$(same_dir_temp_file "$manifest") || return 1
    jq --arg phase "$phase" \
       --arg name "$name" \
       --arg started_at "$started_at" \
       --arg completed_at "$completed_at" \
       --arg status "$status" \
       --arg verdict "$verdict" \
       --arg cost "$cost" \
       --arg error_class "$error_class" \
       --arg error_detail "$normalized_error_detail" \
       --argjson recovery "$recovery_json" \
       '.phases += [(
           {
               phase: $phase,
               name: $name,
               started_at: $started_at,
               completed_at: $completed_at,
               status: $status,
               verdict: (if $verdict == "" then null else $verdict end),
               cost: (if $cost == "" then null else $cost end)
           } +
           (if $error_class == "" and $error_detail == "" then {} else {
               error_class: (if $error_class == "" then null else $error_class end),
               error_detail: $error_detail
           } end) +
           (if $recovery == null then {} else {
               recovery: $recovery
           } end)
       )]' "$manifest" > "$tmp" && mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

_run_manifest_is_finalized() {
    local manifest="${1:-}"
    if [[ -z "$manifest" ]]; then
        [[ -n "${comp_dir:-}" ]] || return 1
        manifest="${comp_dir}/run-manifest.json"
    fi
    command -v jq >/dev/null 2>&1 || return 1
    [[ -f "$manifest" ]] || return 1
    jq -e '
        (.final_status? | type == "string" and length > 0) and
        (.completed_at? | type == "string" and length > 0)
    ' "$manifest" >/dev/null 2>&1
}

_finalize_run_manifest() {
    local final_status="$1" fix_cycles="$2"
    local manifest_dir="${comp_dir:-}"
    [[ -n "$manifest_dir" ]] || return 0
    local manifest="${manifest_dir}/run-manifest.json"
    local traditional_proxy_json="null"
    local task_log_dir="${TASK_LOG_DIR:-${_CURRENT_TASK_LOG_DIR:-}}"
    command -v jq >/dev/null 2>&1 || return 0
    [[ -f "$manifest" ]] || return 0
    _run_manifest_is_finalized "$manifest" && return 0
    if [[ -n "$task_log_dir" ]]; then
        [[ -n "${TASK_LOG_DIR:-}" ]] || TASK_LOG_DIR="$task_log_dir"
        _merge_cost_csvs || true
    fi
    local total_cost="0.0000"
    local cost_csv=""
    if [[ -n "$task_log_dir" ]]; then
        cost_csv="${task_log_dir}/cost.csv"
    fi
    if [[ -n "$cost_csv" && -f "$cost_csv" ]]; then
        total_cost=$(awk -F',' 'NR > 1 && $11 != "" { sum += $11 } END { printf "%.4f", sum + 0 }' "$cost_csv" 2>/dev/null || echo "0.0000")
    fi
    if [[ -n "${_CURRENT_TASK_FILE:-}" ]]; then
        traditional_proxy_json=$(persist_v2_traditional_dev_proxy_json "$_CURRENT_TASK_FILE" "$fix_cycles" 2>/dev/null || echo "null")
        if [[ -z "$traditional_proxy_json" || "$traditional_proxy_json" == "null" ]]; then
            traditional_proxy_json=$(read_persisted_v2_traditional_dev_proxy_json "$_CURRENT_TASK_FILE" 2>/dev/null || echo "null")
            [[ -z "$traditional_proxy_json" ]] && traditional_proxy_json="null"
        fi
    fi
    local tmp
    tmp=$(same_dir_temp_file "$manifest") || return 1
    jq --arg completed_at "$(_iso_timestamp)" \
       --arg total_cost_usd "$total_cost" \
       --arg final_status "$final_status" \
       --argjson fix_cycles "$fix_cycles" \
       --argjson traditional_dev_proxy "$traditional_proxy_json" \
       '. + {
           completed_at: $completed_at,
           total_cost_usd: $total_cost_usd,
           final_status: $final_status,
           fix_cycles: $fix_cycles,
           traditional_dev_proxy: $traditional_dev_proxy
       }' "$manifest" > "$tmp" && mv "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

_manifest_phase_measured_cost() {
    local task_log_dir="${1:-${TASK_LOG_DIR:-${_CURRENT_TASK_LOG_DIR:-}}}"
    local cost_csv="" measured_phase_cost=""
    [[ -n "$task_log_dir" ]] || {
        printf '0.00\n'
        return 0
    }
    [[ -n "${TASK_LOG_DIR:-}" ]] || TASK_LOG_DIR="$task_log_dir"
    _merge_cost_csvs || true
    cost_csv="${task_log_dir}/cost.csv"
    if [[ -f "$cost_csv" ]]; then
        measured_phase_cost=$(
            awk -F',' '
                NR > 1 && $11 ~ /^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*$/ {
                    sum += $11 + 0
                    found = 1
                }
                END {
                    if (found) {
                        printf "%.4f", sum + 0
                    }
                }
            ' "$cost_csv" 2>/dev/null || true
        )
        if [[ -n "$measured_phase_cost" ]]; then
            printf '%s\n' "$measured_phase_cost"
            return 0
        fi
    fi
    printf '0.00\n'
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

_classify_agent_exit_error_class() {
    local engine="$1" exit_code="$2" log_file="${3:-}"

    if [[ "$exit_code" -eq 124 ]]; then
        printf 'timeout\n'
        return 0
    fi

    case "$engine" in
        codex*)
            if [[ -n "$log_file" && -f "$log_file" ]]; then
                if _codex_attempt_indicates_capacity_failure "$log_file"; then
                    printf 'codex_capacity\n'
                    return 0
                fi
                if _codex_attempt_indicates_stream_failure "$log_file"; then
                    printf 'codex_stream\n'
                    return 0
                fi
            fi
            ;;
    esac

    # TODO: refine error_class when stable non-timeout/non-log failure signals emerge.
    printf 'unknown\n'
}

_v2_record_codex_outcome() {
    local engine="$1" exit_code="$2"
    [[ "$engine" == "codex" ]] || return 0
    if [[ "$exit_code" -ne 0 ]]; then
        _V2_CODEX_RUN_FAILURES=$((_V2_CODEX_RUN_FAILURES + 1))
    fi
    # No reset on success: a single run is 30-60 min. If Codex was broken
    # enough to fail twice (after internal retries each time), it's not
    # recovering mid-run. Resetting would allow 4-6 wasted dispatches in
    # a run with intermittent Codex issues.
}

_v2_reset_codex_auth_preflight_state() {
    _V2_CODEX_AUTH_PREFLIGHT_RAN=false
    _V2_CODEX_AUTH_CIRCUIT_OPEN=false
    _V2_CODEX_AUTH_CIRCUIT_MESSAGE=""
    _V2_EFFECTIVE_ENGINE=""
    _V2_LAST_ENGINE_RESOLUTION_REASON="none"
    _V2_LAST_ENGINE_RESOLUTION_REQUESTED=""
    _V2_LAST_ENGINE_RESOLUTION_RESULT=""
    export _V2_CODEX_AUTH_PREFLIGHT_RAN _V2_CODEX_AUTH_CIRCUIT_OPEN _V2_CODEX_AUTH_CIRCUIT_MESSAGE
}

_v2_preflight_codex_auth_once() {
    local stderr_file="" exit_code=0 normalized_message=""

    [[ "${_V2_CODEX_AUTH_PREFLIGHT_RAN:-false}" == "true" ]] && return 0

    _V2_CODEX_AUTH_PREFLIGHT_RAN=true
    export _V2_CODEX_AUTH_PREFLIGHT_RAN

    if ! type codex54_auth_preflight >/dev/null 2>&1; then
        return 0
    fi

    stderr_file=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-codex-auth.XXXXXX") || return 1

    if codex54_auth_preflight 2>"$stderr_file"; then
        _V2_CODEX_AUTH_CIRCUIT_OPEN=false
        _V2_CODEX_AUTH_CIRCUIT_MESSAGE=""
        export _V2_CODEX_AUTH_CIRCUIT_OPEN _V2_CODEX_AUTH_CIRCUIT_MESSAGE
        rm -f "$stderr_file"
        return 0
    fi
    exit_code=$?

    if grep -qi 'Key Vault' "$stderr_file" 2>/dev/null; then
        normalized_message="No cached or env Codex 5.4 API key was available and Key Vault lookup failed"
    elif grep -qiE 'az login|Azure authentication required' "$stderr_file" 2>/dev/null; then
        normalized_message="No cached or env Codex 5.4 API key was available and Azure login is required for Key Vault"
    else
        normalized_message="Codex auth preflight failed"
    fi

    _V2_CODEX_AUTH_CIRCUIT_OPEN=true
    _V2_CODEX_AUTH_CIRCUIT_MESSAGE="$normalized_message"
    export _V2_CODEX_AUTH_CIRCUIT_OPEN _V2_CODEX_AUTH_CIRCUIT_MESSAGE
    rm -f "$stderr_file"
    return "$exit_code"
}

_v2_codex_skip_reason() {
    if [[ "${_V2_CODEX_AUTH_CIRCUIT_OPEN:-false}" == "true" ]]; then
        printf 'auth_preflight\n'
        return 0
    fi

    if [[ "${_V2_CODEX_RUN_FAILURES:-0}" -ge 2 ]]; then
        printf 'run_failures\n'
        return 0
    fi

    return 1
}

_v2_should_skip_codex() {
    _v2_codex_skip_reason >/dev/null 2>&1
}

# _resolve_effective_engine <requested_engine>
# Mutates Codex preflight/breaker state in the current shell. Do not call this
# helper via command substitution; read `_V2_EFFECTIVE_ENGINE` after invoking it.
_resolve_effective_engine() {
    local requested_engine="$1"
    local skip_reason=""

    _V2_LAST_ENGINE_RESOLUTION_REQUESTED="$requested_engine"
    _V2_LAST_ENGINE_RESOLUTION_REASON="none"
    _V2_LAST_ENGINE_RESOLUTION_RESULT="$requested_engine"
    _V2_EFFECTIVE_ENGINE="$requested_engine"

    if [[ "$requested_engine" != "codex" ]]; then
        return 0
    fi

    skip_reason=$(_v2_codex_skip_reason 2>/dev/null || true)
    if [[ -z "$skip_reason" ]] && [[ "${_V2_CODEX_AUTH_PREFLIGHT_RAN:-false}" != "true" ]]; then
        _v2_preflight_codex_auth_once || true
        skip_reason=$(_v2_codex_skip_reason 2>/dev/null || true)
    fi

    case "$skip_reason" in
        auth_preflight|run_failures)
            _V2_EFFECTIVE_ENGINE="claude"
            _V2_LAST_ENGINE_RESOLUTION_REASON="$skip_reason"
            _V2_LAST_ENGINE_RESOLUTION_RESULT="claude"
            ;;
        *)
            _V2_EFFECTIVE_ENGINE="codex"
            _V2_LAST_ENGINE_RESOLUTION_REASON="none"
            _V2_LAST_ENGINE_RESOLUTION_RESULT="codex"
            ;;
    esac
}

_v2_engine_resolution_skipped_codex() {
    local requested_engine="$1" effective_engine="$2"
    [[ "$requested_engine" == "codex" && "$effective_engine" != "codex" ]]
}

_jittered_backoff() {
    local base_delay="${1:-0}"
    local jitter_max=0
    if [[ ! "$base_delay" =~ ^[0-9]+$ ]]; then
        printf '0\n'
        return 0
    fi
    jitter_max=$((base_delay / 4))
    printf '%s\n' $((base_delay + (RANDOM % (jitter_max + 1))))
}

_v2_log_codex_circuit_breaker_trip() {
    local task_file="$1" dispatch_label="$2"
    local skip_reason=""
    skip_reason=$(_v2_codex_skip_reason 2>/dev/null || true)

    case "$skip_reason" in
        auth_preflight)
            echo -e "${YELLOW}Codex auth preflight failed — using Claude for ${dispatch_label}${NC}"
            log_execution "$task_file" "Codex auth preflight failed for ${dispatch_label}; overriding codex→claude (${_V2_CODEX_AUTH_CIRCUIT_MESSAGE:-Codex auth preflight failed})" || true
            ;;
        *)
            local failure_count="${_V2_CODEX_RUN_FAILURES:-0}"
            echo -e "${YELLOW}Codex circuit breaker active — using Claude for ${dispatch_label} (${failure_count} cumulative Codex failures in this run)${NC}"
            log_execution "$task_file" "Codex circuit breaker active for ${dispatch_label}; overriding codex→claude (${failure_count} cumulative Codex failures in this run)" || true
            ;;
    esac
}

_v2_append_codex_circuit_breaker_skip() {
    local phase="$1" name="$2" started_at="$3" dispatch_label="$4"
    local skip_reason="" error_class="codex_circuit_breaker" error_detail=""
    skip_reason=$(_v2_codex_skip_reason 2>/dev/null || true)

    case "$skip_reason" in
        auth_preflight)
            error_class="codex_auth_preflight"
            error_detail="dispatch=${dispatch_label}; skipped_engine=codex; fallback_engine=claude; reason=auth_preflight"
            ;;
        *)
            error_detail="dispatch=${dispatch_label}; skipped_engine=codex; fallback_engine=claude; cumulative_failures=${_V2_CODEX_RUN_FAILURES:-0}"
            ;;
    esac

    _append_manifest_phase \
        "$phase" \
        "$name" \
        "$started_at" \
        "$(_iso_timestamp)" \
        "skipped" \
        "" \
        "" \
        "$error_class" \
        "$error_detail" || true
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
    local timeout_seconds phase_deadline cutoff_epoch poll_interval now live_artifact=""

    timeout_seconds=$(_duration_to_seconds "$timeout")
    phase_deadline=$((codex_start_ts + timeout_seconds))
    cutoff_epoch=$phase_deadline
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
                # Promote attempt to canonical so downstream finds it
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

# ============================================================
# Execution worktree helpers — isolate Phase 4/7 execution
# ============================================================

_v2_reset_merge_recovery_state() {
    _V2_EXEC_TARGET_REF=""
    _V2_EXEC_TARGET_HEAD_SHA=""
    _V2_EXEC_PREEXISTING_ROOT_DIRTY=""
    _V2_LAST_MERGE_RECOVERABLE=false
    _V2_PRESERVED_EXEC_WORKTREE_PATH=""
    _V2_PRESERVED_EXEC_WORKTREE_BRANCH=""
    _V2_PRESERVED_EXEC_TARGET_REF=""
    _V2_PRESERVED_EXEC_TARGET_HEAD_SHA=""
    _V2_PRESERVED_EXEC_COMMIT_SHA=""
    _V2_PRESERVED_RECOVERY_DIR=""
    _V2_PRESERVED_COMBINED_PATCH=""
    _V2_PRESERVED_COMMIT_LOG=""
    _V2_PRESERVED_FORMAT_PATCH_DIR=""
    _V2_PRESERVED_WORKTREE_PATCH=""
}

_v2_capture_execution_merge_target() {
    local target_ref=""
    local target_head_sha=""

    target_ref=$(git symbolic-ref -q HEAD 2>/dev/null || true)
    [[ -n "$target_ref" ]] || target_ref="HEAD"

    target_head_sha=$(git rev-parse "$target_ref" 2>/dev/null || true)
    [[ -n "$target_head_sha" ]] || target_head_sha=$(git rev-parse HEAD 2>/dev/null || true)

    _V2_EXEC_TARGET_REF="$target_ref"
    _V2_EXEC_TARGET_HEAD_SHA="$target_head_sha"
    _V2_LAST_MERGE_RECOVERABLE=false
}

_v2_saved_diff_base_dir() {
    local save_dir=""

    if [[ -n "${_CURRENT_TASK_FILE:-}" && -f "$_CURRENT_TASK_FILE" ]]; then
        local task_dir=""
        task_dir=$(_v2_task_dir_for_task_file "$_CURRENT_TASK_FILE" 2>/dev/null || true)
        if [[ -n "$task_dir" ]]; then
            save_dir="${task_dir}/competitive/saved-diffs"
        fi
    fi

    printf '%s\n' "${save_dir:-/tmp/lauren-loop-saved-diffs}"
}

_v2_write_worktree_local_patch() {
    local wt_path="$1"
    local patch_file="$2"
    local untracked=""
    local f=""

    : > "$patch_file"
    git -C "$wt_path" diff HEAD > "$patch_file" 2>/dev/null || true

    untracked=$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null || true)
    if [[ -n "$untracked" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            git -C "$wt_path" diff --no-index -- /dev/null "$wt_path/$f" >> "$patch_file" 2>/dev/null || true
        done <<< "$untracked"
    fi

    [[ -s "$patch_file" ]]
}

_v2_has_recoverable_execution_commit() {
    local target_head_sha="$1"
    local worktree_head="$2"

    [[ -n "$target_head_sha" && -n "$worktree_head" ]] || return 1
    [[ "$target_head_sha" != "$worktree_head" ]] || return 1
    git merge-base --is-ancestor "$target_head_sha" "$worktree_head" 2>/dev/null
}

_v2_short_sha() {
    local sha="$1"

    [[ -n "$sha" ]] || return 0
    if [[ "${#sha}" -le 12 ]]; then
        printf '%s\n' "$sha"
    else
        printf '%s\n' "${sha:0:12}"
    fi
}

_v2_log_execution_target_drift() {
    local target_ref="$1"
    local original_target_head="$2"
    local current_target_head="$3"
    local counts=""
    local original_only="unknown"
    local current_only="unknown"
    local original_short=""
    local current_short=""

    [[ -n "$original_target_head" && -n "$current_target_head" ]] || return 0
    [[ "$original_target_head" != "$current_target_head" ]] || return 0

    counts=$(git rev-list --left-right --count "${original_target_head}...${current_target_head}" 2>/dev/null || true)
    if [[ "$counts" == *$'\t'* ]]; then
        original_only="${counts%%$'\t'*}"
        current_only="${counts##*$'\t'}"
    elif [[ "$counts" == *" "* ]]; then
        original_only="${counts%% *}"
        current_only="${counts##* }"
    fi

    original_short=$(_v2_short_sha "$original_target_head")
    current_short=$(_v2_short_sha "$current_target_head")
    echo -e "${YELLOW}Execution target drift detected for ${target_ref:-HEAD}: ${original_short}...${current_short} (current-only=${current_only}, original-only=${original_only})${NC}"
}

_v2_rebase_execution_worktree_onto_target() {
    local wt_path="$1"
    local wt_branch="$2"
    local original_target_head="$3"
    local current_target_head="$4"
    local original_short=""
    local current_short=""

    [[ -n "$wt_path" && -d "$wt_path" ]] || return 0
    [[ -n "$wt_branch" && -n "$original_target_head" && -n "$current_target_head" ]] || return 0
    [[ "$original_target_head" != "$current_target_head" ]] || return 0

    original_short=$(_v2_short_sha "$original_target_head")
    current_short=$(_v2_short_sha "$current_target_head")
    echo -e "${YELLOW}Rebasing execution worktree branch ${wt_branch} from ${original_short} onto ${current_short}${NC}"

    if git -C "$wt_path" rebase --onto "$current_target_head" "$original_target_head" "$wt_branch" >/dev/null 2>&1; then
        echo -e "${GREEN}Rebased execution worktree branch ${wt_branch} onto ${current_short}${NC}"
        return 0
    fi

    git -C "$wt_path" rebase --abort >/dev/null 2>&1 || true
    echo -e "${RED}Rebase-based merge preparation failed for ${wt_branch}; aborted rebase and preserving recovery state${NC}" >&2
    return 1
}

_v2_recovery_manifest_json() {
    command -v jq >/dev/null 2>&1 || {
        printf 'null\n'
        return 0
    }

    jq -cn \
        --arg target_ref "${_V2_PRESERVED_EXEC_TARGET_REF:-}" \
        --arg target_head_sha "${_V2_PRESERVED_EXEC_TARGET_HEAD_SHA:-}" \
        --arg branch "${_V2_PRESERVED_EXEC_WORKTREE_BRANCH:-}" \
        --arg worktree_path "${_V2_PRESERVED_EXEC_WORKTREE_PATH:-}" \
        --arg preserved_commit "${_V2_PRESERVED_EXEC_COMMIT_SHA:-}" \
        --arg recovery_dir "${_V2_PRESERVED_RECOVERY_DIR:-}" \
        --arg combined_patch "${_V2_PRESERVED_COMBINED_PATCH:-}" \
        --arg commit_log "${_V2_PRESERVED_COMMIT_LOG:-}" \
        --arg format_patch_dir "${_V2_PRESERVED_FORMAT_PATCH_DIR:-}" \
        --arg worktree_patch "${_V2_PRESERVED_WORKTREE_PATCH:-}" \
        '{
            target_ref: $target_ref,
            target_head_sha: $target_head_sha,
            branch: $branch,
            worktree_path: $worktree_path,
            preserved_commit: $preserved_commit,
            recovery_dir: $recovery_dir,
            combined_patch: $combined_patch,
            commit_log: $commit_log,
            format_patch_dir: $format_patch_dir,
            worktree_patch: $worktree_patch
        } | with_entries(select(.value != ""))'
}

_v2_log_recovery_details() {
    local task_file="$1"

    [[ -n "$task_file" && -f "$task_file" ]] || return 0
    [[ "$_V2_LAST_MERGE_RECOVERABLE" == true ]] || return 0

    log_execution "$task_file" "  recovery branch: ${_V2_PRESERVED_EXEC_WORKTREE_BRANCH:-unknown}" || true
    log_execution "$task_file" "  recovery worktree: ${_V2_PRESERVED_EXEC_WORKTREE_PATH:-unknown}" || true
    log_execution "$task_file" "  recovery preserved commit: ${_V2_PRESERVED_EXEC_COMMIT_SHA:-unknown}" || true
    if [[ -n "${_V2_PRESERVED_RECOVERY_DIR:-}" ]]; then
        log_execution "$task_file" "  recovery artifacts: ${_V2_PRESERVED_RECOVERY_DIR}" || true
    fi
    if [[ -n "${_V2_PRESERVED_COMBINED_PATCH:-}" ]]; then
        log_execution "$task_file" "  recovery combined diff: ${_V2_PRESERVED_COMBINED_PATCH}" || true
    fi
    if [[ -n "${_V2_PRESERVED_COMMIT_LOG:-}" ]]; then
        log_execution "$task_file" "  recovery commit log: ${_V2_PRESERVED_COMMIT_LOG}" || true
    fi
    if [[ -n "${_V2_PRESERVED_FORMAT_PATCH_DIR:-}" ]]; then
        log_execution "$task_file" "  recovery format-patch dir: ${_V2_PRESERVED_FORMAT_PATCH_DIR}" || true
    fi
    if [[ -n "${_V2_PRESERVED_WORKTREE_PATCH:-}" ]]; then
        log_execution "$task_file" "  recovery worktree patch: ${_V2_PRESERVED_WORKTREE_PATCH}" || true
    fi
}

_v2_execution_merge_branch_label() {
    printf '%s\n' "${_V2_EXEC_WORKTREE_BRANCH:-${_V2_PRESERVED_EXEC_WORKTREE_BRANCH:-unknown}}"
}

_v2_cleanup_after_failed_merge() {
    local save_diff="${1:-false}"

    if [[ "$_V2_LAST_MERGE_RECOVERABLE" == true ]]; then
        return 0
    fi

    if [[ "$save_diff" == true ]]; then
        _v2_save_worktree_diff || true
    fi
    _v2_cleanup_execution_worktree || true
}

_v2_save_merge_failure_recovery_artifacts() {
    local wt_path="$1"
    local preserved_commit="$2"
    local save_root=""
    local timestamp=""
    local recovery_dir=""
    local combined_patch=""
    local commit_log=""
    local format_patch_dir=""
    local worktree_patch=""
    local merge_base=""

    save_root=$(_v2_saved_diff_base_dir)
    mkdir -p "$save_root" 2>/dev/null || return 0

    timestamp=$(date +%Y%m%d-%H%M%S)
    recovery_dir="${save_root}/${SLUG:-unknown}-${timestamp}"
    mkdir -p "$recovery_dir" 2>/dev/null || return 0

    _V2_PRESERVED_RECOVERY_DIR="$recovery_dir"

    if [[ -n "${_V2_PRESERVED_EXEC_TARGET_REF:-}" ]]; then
        merge_base=$(git merge-base "${_V2_PRESERVED_EXEC_TARGET_REF}" "$preserved_commit" 2>/dev/null || true)
    fi
    if [[ -z "$merge_base" && -n "${_V2_PRESERVED_EXEC_TARGET_HEAD_SHA:-}" ]]; then
        merge_base=$(git merge-base "${_V2_PRESERVED_EXEC_TARGET_HEAD_SHA}" "$preserved_commit" 2>/dev/null || true)
    fi
    if [[ -z "$merge_base" ]]; then
        merge_base="${_V2_PRESERVED_EXEC_TARGET_HEAD_SHA:-}"
    fi

    if [[ -n "$merge_base" ]]; then
        combined_patch="${recovery_dir}/combined.patch"
        git diff "${merge_base}..${preserved_commit}" > "$combined_patch" 2>/dev/null || true
        if [[ -s "$combined_patch" ]]; then
            _V2_PRESERVED_COMBINED_PATCH="$combined_patch"
        else
            rm -f "$combined_patch"
        fi

        commit_log="${recovery_dir}/commits.txt"
        git log --reverse --format=fuller "${merge_base}..${preserved_commit}" > "$commit_log" 2>/dev/null || true
        if [[ -s "$commit_log" ]]; then
            _V2_PRESERVED_COMMIT_LOG="$commit_log"
        else
            rm -f "$commit_log"
        fi

        format_patch_dir="${recovery_dir}/format-patch"
        mkdir -p "$format_patch_dir" 2>/dev/null || true
        git format-patch --quiet -o "$format_patch_dir" "${merge_base}..${preserved_commit}" >/dev/null 2>&1 || true
        if compgen -G "${format_patch_dir}/*.patch" >/dev/null; then
            _V2_PRESERVED_FORMAT_PATCH_DIR="$format_patch_dir"
        else
            rmdir "$format_patch_dir" 2>/dev/null || true
        fi
    fi

    worktree_patch="${recovery_dir}/worktree.patch"
    if _v2_write_worktree_local_patch "$wt_path" "$worktree_patch"; then
        _V2_PRESERVED_WORKTREE_PATCH="$worktree_patch"
    else
        rm -f "$worktree_patch"
    fi
}

_v2_preserve_recoverable_merge_failure() {
    local wt_path="$1"
    local wt_branch="$2"
    local worktree_head="$3"

    _V2_LAST_MERGE_RECOVERABLE=true
    _V2_PRESERVED_EXEC_WORKTREE_PATH="$wt_path"
    _V2_PRESERVED_EXEC_WORKTREE_BRANCH="$wt_branch"
    _V2_PRESERVED_EXEC_TARGET_REF="${_V2_EXEC_TARGET_REF:-}"
    _V2_PRESERVED_EXEC_TARGET_HEAD_SHA="${_V2_EXEC_TARGET_HEAD_SHA:-}"
    _V2_PRESERVED_EXEC_COMMIT_SHA="$worktree_head"
    _V2_PRESERVED_RECOVERY_DIR=""
    _V2_PRESERVED_COMBINED_PATCH=""
    _V2_PRESERVED_COMMIT_LOG=""
    _V2_PRESERVED_FORMAT_PATCH_DIR=""
    _V2_PRESERVED_WORKTREE_PATCH=""

    _v2_save_merge_failure_recovery_artifacts "$wt_path" "$worktree_head" || true
    git merge --abort >/dev/null 2>&1 || true

    echo -e "${RED}Merge conflict from execution worktree branch ${wt_branch}${NC}" >&2
    echo -e "${YELLOW}Recoverable merge failure — execution worktree preserved at ${wt_path}${NC}" >&2
    echo -e "${YELLOW}Preserved branch: ${wt_branch}${NC}" >&2
    echo -e "${YELLOW}Preserved commit: ${worktree_head}${NC}" >&2
    if [[ -n "${_V2_PRESERVED_RECOVERY_DIR:-}" ]]; then
        echo -e "${YELLOW}Recovery artifacts: ${_V2_PRESERVED_RECOVERY_DIR}${NC}" >&2
    fi

    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""
    _V2_EXEC_TARGET_REF=""
    _V2_EXEC_TARGET_HEAD_SHA=""
    _V2_EXEC_PREEXISTING_ROOT_DIRTY=""
}

_v2_create_execution_worktree() {
    local branch_name="ll-exec-${SLUG:-unknown}-${RANDOM}"
    local worktree_path="/tmp/lauren-loop-wt-${SLUG:-unknown}-$$"

    _v2_reset_merge_recovery_state
    _v2_capture_execution_merge_target

    # Clean up stale worktree from a previous crash at the same path
    if [[ -d "$worktree_path" ]]; then
        echo -e "${YELLOW}Cleaning stale worktree at ${worktree_path}${NC}"
        git worktree remove "$worktree_path" --force 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Prune any stale worktree bookkeeping entries
    git worktree prune 2>/dev/null || true

    git worktree add "$worktree_path" -b "$branch_name" HEAD || {
        echo -e "${RED}Failed to create execution worktree at ${worktree_path}${NC}" >&2
        return 1
    }

    _V2_EXEC_WORKTREE_PATH="$worktree_path"
    _V2_EXEC_WORKTREE_BRANCH="$branch_name"
    echo -e "${BLUE}Created execution worktree: ${worktree_path} (branch: ${branch_name})${NC}"
}

_v2_commit_execution_worktree_pending_changes() {
    local wt_path="${_V2_EXEC_WORKTREE_PATH:-}"
    local untracked="" path=""
    local tracked_files=""

    [[ -n "$wt_path" && -d "$wt_path" ]] || return 0

    tracked_files=$(git -C "$wt_path" ls-files 2>/dev/null || true)
    if [[ -n "$tracked_files" ]]; then
        git -C "$wt_path" add -u -- . || return 1
    fi

    untracked=$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null || true)
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if _is_ignored_untracked_path "$path"; then
            continue
        fi
        git -C "$wt_path" add -- "$path" || return 1
    done <<< "$untracked"

    if git -C "$wt_path" diff --cached --quiet HEAD -- 2>/dev/null; then
        return 0
    fi

    git -C "$wt_path" \
        -c user.name="Lauren Loop" \
        -c user.email="lauren-loop@local" \
        commit -m "lauren-loop: persist execution worktree changes" >/dev/null 2>&1 || {
            echo -e "${RED}Failed to commit pending execution worktree changes${NC}" >&2
            return 1
        }
}

_v2_prestage_baseline_diff_if_missing() {
    # Belt-and-suspenders: if the fix-execution worktree is missing the
    # baseline code changes (e.g., commit-before-merge failed silently),
    # auto-apply the latest execution diff patch before fix-executor starts.
    local wt_path="${_V2_EXEC_WORKTREE_PATH:-}"
    local comp_dir="$1"

    [[ -n "$wt_path" && -d "$wt_path" ]] || return 0

    # Find the latest diff to check: fix-diff-cycleN.patch or execution-diff.patch
    local latest_patch=""
    latest_patch=$(ls -t "$comp_dir"/fix-diff-cycle*.patch 2>/dev/null | head -1)
    [[ -z "$latest_patch" ]] && latest_patch="${comp_dir}/execution-diff.patch"
    [[ -f "$latest_patch" && -s "$latest_patch" ]] || return 0

    # Check if the patch would apply (meaning changes are NOT already present)
    if git -C "$wt_path" apply --check "$latest_patch" 2>/dev/null; then
        echo -e "${YELLOW}Worktree missing baseline changes — auto-applying ${latest_patch}${NC}"
        if git -C "$wt_path" apply "$latest_patch"; then
            echo -e "${GREEN}Baseline diff pre-staged successfully${NC}"
            return 0
        else
            echo -e "${RED}Failed to pre-stage baseline diff — fix-executor may report BLOCKED${NC}" >&2
            return 1
        fi
    fi
    # Patch would not apply cleanly = changes already present (or conflict). Nothing to do.
    return 0
}

_v2_merge_lock_file() {
    printf '%s\n' "${LAUREN_LOOP_V2_MERGE_LOCK_FILE:-/tmp/lauren-loop-v2-merge.lock}"
}

_v2_merge_lock_timeout_seconds() {
    printf '%s\n' "${LAUREN_LOOP_V2_MERGE_LOCK_TIMEOUT_SEC:-300}"
}

_v2_release_merge_lock_fd() {
    local lock_fd="$1"
    [[ "$lock_fd" =~ ^[0-9]+$ ]] || return 0
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
}

_v2_acquire_global_merge_lock() {
    local fd_var_name="$1"
    local lock_file="${2:-$(_v2_merge_lock_file)}"
    local timeout="${3:-$(_v2_merge_lock_timeout_seconds)}"
    local lock_fd=219

    mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
    eval "exec ${lock_fd}>\"$lock_file\"" || {
        echo -e "${RED}Failed to open Lauren Loop V2 global merge lock: ${lock_file}${NC}" >&2
        return 1
    }

    if command -v flock >/dev/null 2>&1; then
        flock -w "$timeout" "$lock_fd" || {
            echo "ERROR: timed out acquiring Lauren Loop V2 global merge lock after ${timeout}s: ${lock_file}" >&2
            _v2_release_merge_lock_fd "$lock_fd"
            return 1
        }
    elif command -v lockf >/dev/null 2>&1; then
        lockf -t "$timeout" "$lock_fd" || {
            echo "ERROR: timed out acquiring Lauren Loop V2 global merge lock after ${timeout}s: ${lock_file}" >&2
            _v2_release_merge_lock_fd "$lock_fd"
            return 1
        }
    else
        echo "ERROR: unable to acquire Lauren Loop V2 global merge lock because neither flock nor lockf is available" >&2
        _v2_release_merge_lock_fd "$lock_fd"
        return 1
    fi

    printf -v "$fd_var_name" '%s' "$lock_fd"
}

_v2_path_matches_any_glob() {
    local path="$1"
    shift

    local pattern=""
    for pattern in "$@"; do
        [[ -n "$pattern" ]] || continue
        if [[ "$path" == $pattern ]]; then
            return 0
        fi
    done

    return 1
}

_v2_merge_expected_root_dirty_globs() {
    local task_file="${_CURRENT_TASK_FILE:-}"
    local task_dir=""
    local task_file_rel=""
    local task_dir_rel=""

    [[ -n "$task_file" ]] || return 0

    task_file_rel=$(_v2_main_repo_relative_path "$task_file" 2>/dev/null || true)
    if [[ -n "$task_file_rel" ]]; then
        printf '%s\n' "$task_file_rel"
    fi

    task_dir=$(_v2_task_dir_for_task_file "$task_file" 2>/dev/null || true)
    task_dir_rel=$(_v2_main_repo_relative_path "$task_dir" 2>/dev/null || true)
    [[ -n "$task_dir_rel" && "$task_dir_rel" != "." ]] || return 0

    printf '%s\n' \
        "${task_dir_rel}/competitive/run-manifest.json" \
        "${task_dir_rel}/competitive/.cycle-state.json" \
        "${task_dir_rel}/competitive/execution-diff.patch" \
        "${task_dir_rel}/competitive/execution-diff.numstat.tsv" \
        "${task_dir_rel}/competitive/fix-diff-cycle*.patch" \
        "${task_dir_rel}/competitive/fix-diff-cycle*.numstat.tsv" \
        "${task_dir_rel}/competitive/fix-diff-cycle*.estimate.numstat.tsv" \
        "${task_dir_rel}/competitive/traditional-dev-proxy.json" \
        "${task_dir_rel}/logs/cost.csv" \
        "${task_dir_rel}/logs/*.log" \
        "${task_dir_rel}/logs/*.summary.txt"
}

_v2_root_dirty_paths() {
    local status_line=""
    local status_path=""

    git -C "$SCRIPT_DIR" status --porcelain --untracked-files=all 2>/dev/null | while IFS= read -r status_line; do
        [[ -n "$status_line" ]] || continue
        status_path="${status_line#?? }"
        case "$status_path" in
            *" -> "*)
                status_path="${status_path##* -> }"
                ;;
        esac
        [[ -n "$status_path" ]] || continue
        printf '%s\n' "$status_path"
    done | _v2_unique_nonblank_lines
}

_v2_unexpected_root_dirty_paths_before_merge() {
    local -a whitelist_globs=()
    local path=""

    _merge_cost_csvs || true
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        whitelist_globs+=("$path")
    done < <(_v2_merge_expected_root_dirty_globs)

    _v2_root_dirty_paths | while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if ! _v2_path_matches_any_glob "$path" "${whitelist_globs[@]}"; then
            printf '%s\n' "$path"
        fi
    done | _v2_unique_nonblank_lines
}

_v2_execution_worktree_read_path_for() {
    local path="$1"
    local worktree_path=""

    worktree_path=$(_v2_execution_worktree_path_for "$path" 2>/dev/null || true)
    if [[ -n "$worktree_path" && -f "$worktree_path" ]]; then
        printf '%s\n' "$worktree_path"
    else
        printf '%s\n' "$path"
    fi
}

_v2_merge_execution_worktree() {
    local -a post_merge_sync_targets=("$@")
    local merge_lock_fd=""
    local merge_lock_file=""
    local merge_lock_timeout=""
    local unexpected_dirty_paths=""
    local unexpected_dirty_list=""
    local worktree_head=""
    local target_head=""
    local target_ref=""
    local saved_target_head=""

    [[ -n "$_V2_EXEC_WORKTREE_PATH" ]] || return 0

    cd "$SCRIPT_DIR"
    _V2_LAST_MERGE_RECOVERABLE=false

    if [[ -z "${_CURRENT_TASK_FILE:-}" ]]; then
        echo "ERROR: cannot run merge preflight without _CURRENT_TASK_FILE set to the active task file." >&2
        return 1
    fi
    if [[ ! -f "$_CURRENT_TASK_FILE" ]]; then
        echo "ERROR: cannot run merge preflight because _CURRENT_TASK_FILE is missing: ${_CURRENT_TASK_FILE}" >&2
        return 1
    fi

    _v2_commit_execution_worktree_pending_changes || return 1

    worktree_head=$(git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
    target_ref="${_V2_EXEC_TARGET_REF:-HEAD}"
    saved_target_head="${_V2_EXEC_TARGET_HEAD_SHA:-}"

    merge_lock_file=$(_v2_merge_lock_file)
    merge_lock_timeout=$(_v2_merge_lock_timeout_seconds)
    _v2_acquire_global_merge_lock merge_lock_fd "$merge_lock_file" "$merge_lock_timeout" || return 1

    unexpected_dirty_paths=$(_v2_unexpected_root_dirty_paths_before_merge)
    unexpected_dirty_paths=$(_v2_filter_out_paths_from_list "$unexpected_dirty_paths" "${_V2_EXEC_PREEXISTING_ROOT_DIRTY:-}")
    if [[ -n "$unexpected_dirty_paths" ]]; then
        unexpected_dirty_list=$(printf '%s\n' "$unexpected_dirty_paths" | paste -sd ',' -)
        echo "ERROR: unexpected dirty files in root checkout before merge: ${unexpected_dirty_list}. This indicates a pre-merge sync that should be deferred to post-merge." >&2
        if _v2_has_recoverable_execution_commit "$saved_target_head" "$worktree_head"; then
            echo -e "${YELLOW}Dirty-root merge preflight blocked merge-back; preserving recoverable execution worktree state${NC}" >&2
            _v2_preserve_recoverable_merge_failure "$_V2_EXEC_WORKTREE_PATH" "$_V2_EXEC_WORKTREE_BRANCH" "$worktree_head"
        fi
        _v2_release_merge_lock_fd "$merge_lock_fd"
        return 1
    fi

    target_head=$(git rev-parse "$target_ref" 2>/dev/null || true)
    [[ -n "$target_head" ]] || target_head=$(git rev-parse HEAD 2>/dev/null || true)

    if [[ -n "$saved_target_head" && -n "$target_head" && "$saved_target_head" != "$target_head" ]]; then
        _v2_log_execution_target_drift "$target_ref" "$saved_target_head" "$target_head"
        if [[ -n "$worktree_head" && "$worktree_head" != "$saved_target_head" ]]; then
            if ! _v2_rebase_execution_worktree_onto_target "$_V2_EXEC_WORKTREE_PATH" "$_V2_EXEC_WORKTREE_BRANCH" "$saved_target_head" "$target_head"; then
                worktree_head=$(git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
                if _v2_has_recoverable_execution_commit "$saved_target_head" "$worktree_head"; then
                    _v2_preserve_recoverable_merge_failure "$_V2_EXEC_WORKTREE_PATH" "$_V2_EXEC_WORKTREE_BRANCH" "$worktree_head"
                fi
                _v2_release_merge_lock_fd "$merge_lock_fd"
                return 1
            fi
            worktree_head=$(git -C "$_V2_EXEC_WORKTREE_PATH" rev-parse HEAD 2>/dev/null || true)
        fi
    fi

    if [[ -n "$worktree_head" && "$worktree_head" != "$target_head" ]]; then
        git merge --no-edit "$_V2_EXEC_WORKTREE_BRANCH" || {
            if _v2_has_recoverable_execution_commit "$saved_target_head" "$worktree_head"; then
                _v2_preserve_recoverable_merge_failure "$_V2_EXEC_WORKTREE_PATH" "$_V2_EXEC_WORKTREE_BRANCH" "$worktree_head"
            else
                git merge --abort >/dev/null 2>&1 || true
            fi
            _v2_release_merge_lock_fd "$merge_lock_fd"
            return 1
        }
    fi

    if [[ "${#post_merge_sync_targets[@]}" -gt 0 ]]; then
        _v2_sync_execution_worktree_files "${post_merge_sync_targets[@]}" || {
            echo -e "${RED}Failed to sync post-merge execution artifacts from worktree${NC}" >&2
            _v2_release_merge_lock_fd "$merge_lock_fd"
            return 1
        }
    fi

    _v2_release_merge_lock_fd "$merge_lock_fd"
    _v2_cleanup_execution_worktree
}

_v2_cleanup_execution_worktree() {
    local wt_path="$_V2_EXEC_WORKTREE_PATH"
    local wt_branch="$_V2_EXEC_WORKTREE_BRANCH"
    local merge_recoverable="$_V2_LAST_MERGE_RECOVERABLE"

    # Clear active execution globals first so re-entry is safe
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""
    _V2_EXEC_TARGET_REF=""
    _V2_EXEC_TARGET_HEAD_SHA=""
    _V2_EXEC_PREEXISTING_ROOT_DIRTY=""
    _V2_LAST_MERGE_RECOVERABLE=false

    # Ensure we're not inside the worktree being removed
    cd "$SCRIPT_DIR" 2>/dev/null || true

    if [[ -n "$wt_path" && -d "$wt_path" ]]; then
        git worktree remove "$wt_path" --force 2>/dev/null || rm -rf "$wt_path"
    fi
    if [[ -n "$wt_branch" ]]; then
        git branch -D "$wt_branch" 2>/dev/null || true
    fi
    git worktree prune 2>/dev/null || true

    if [[ "$merge_recoverable" != true ]]; then
        _V2_PRESERVED_EXEC_WORKTREE_PATH=""
        _V2_PRESERVED_EXEC_WORKTREE_BRANCH=""
        _V2_PRESERVED_EXEC_TARGET_REF=""
        _V2_PRESERVED_EXEC_TARGET_HEAD_SHA=""
        _V2_PRESERVED_EXEC_COMMIT_SHA=""
        _V2_PRESERVED_RECOVERY_DIR=""
        _V2_PRESERVED_COMBINED_PATCH=""
        _V2_PRESERVED_COMMIT_LOG=""
        _V2_PRESERVED_FORMAT_PATCH_DIR=""
        _V2_PRESERVED_WORKTREE_PATCH=""
    fi
}

_v2_save_worktree_diff() {
    local wt_path="${_V2_EXEC_WORKTREE_PATH:-}"
    [[ -n "$wt_path" && -d "$wt_path" ]] || return 0

    local has_changes=false
    if ! git -C "$wt_path" diff --quiet HEAD 2>/dev/null; then
        has_changes=true
    fi
    if ! git -C "$wt_path" diff --cached --quiet HEAD 2>/dev/null; then
        has_changes=true
    fi
    local untracked=""
    untracked=$(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null || true)
    if [[ -n "$untracked" ]]; then
        has_changes=true
    fi
    [[ "$has_changes" == true ]] || return 0

    local save_dir=""
    save_dir=$(_v2_saved_diff_base_dir)
    mkdir -p "$save_dir" 2>/dev/null || return 0

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local patch_file="${save_dir}/${SLUG:-unknown}-${timestamp}.patch"

    if _v2_write_worktree_local_patch "$wt_path" "$patch_file"; then
        echo -e "${YELLOW}Saved worktree diff before cleanup: ${patch_file}${NC}"
    else
        rm -f "$patch_file"
    fi
}

_v2_main_repo_relative_path() {
    local path="$1"
    if [[ "$path" == "$SCRIPT_DIR" ]]; then
        printf '.\n'
        return 0
    fi
    case "$path" in
        "$SCRIPT_DIR/"*)
            printf '%s\n' "${path#$SCRIPT_DIR/}"
            ;;
        /*)
            return 1
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

_v2_execution_worktree_path_for() {
    local path="$1" rel_path=""
    [[ -n "$_V2_EXEC_WORKTREE_PATH" ]] || return 1
    rel_path=$(_v2_main_repo_relative_path "$path") || return 1
    if [[ "$rel_path" == "." ]]; then
        printf '%s\n' "$_V2_EXEC_WORKTREE_PATH"
    else
        printf '%s/%s\n' "$_V2_EXEC_WORKTREE_PATH" "$rel_path"
    fi
}

_v2_execution_runtime_rel_dir() {
    printf '.lauren-loop-runtime/%s\n' "$SLUG"
}

_v2_execution_runtime_task_rel_path() {
    printf '%s/task.md\n' "$(_v2_execution_runtime_rel_dir)"
}

_v2_execution_runtime_task_path() {
    [[ -n "$_V2_EXEC_WORKTREE_PATH" ]] || return 1
    printf '%s/%s\n' "$_V2_EXEC_WORKTREE_PATH" "$(_v2_execution_runtime_task_rel_path)"
}

_v2_stage_execution_worktree_file() {
    local source_path="$1" worktree_path=""
    [[ -f "$source_path" ]] || return 1
    worktree_path=$(_v2_execution_worktree_path_for "$source_path") || return 1
    mkdir -p "$(dirname "$worktree_path")" || return 1
    cp "$source_path" "$worktree_path" || return 1
}

_v2_stage_execution_runtime_task_file() {
    local source_path="$1" runtime_task_path=""
    [[ -f "$source_path" ]] || return 1
    runtime_task_path=$(_v2_execution_runtime_task_path) || return 1
    mkdir -p "$(dirname "$runtime_task_path")" || return 1
    cp "$source_path" "$runtime_task_path" || return 1
}

_v2_stage_execution_worktree_files() {
    local source_path=""
    for source_path in "$@"; do
        [[ -n "$source_path" ]] || continue
        _v2_stage_execution_worktree_file "$source_path" || return 1
    done
}

_v2_sync_execution_worktree_file() {
    local target_path="$1" worktree_path=""
    worktree_path=$(_v2_execution_worktree_path_for "$target_path") || return 1
    [[ -f "$worktree_path" ]] || return 0
    mkdir -p "$(dirname "$target_path")" || return 1
    cp "$worktree_path" "$target_path" || return 1
}

_v2_sync_execution_worktree_files() {
    local target_path=""
    for target_path in "$@"; do
        [[ -n "$target_path" ]] || continue
        _v2_sync_execution_worktree_file "$target_path" || return 1
    done
}

_v2_finalize_halt_without_merge() {
    local sync_rc=0

    [[ -n "$_V2_EXEC_WORKTREE_PATH" ]] || return 0

    _v2_save_worktree_diff || true

    if [[ "$#" -gt 0 ]]; then
        _v2_sync_execution_worktree_files "$@" || sync_rc=$?
        if [[ "$sync_rc" -ne 0 ]]; then
            echo -e "${YELLOW}WARN: Failed to sync halt artifacts from execution worktree${NC}" >&2
        fi
    fi

    _v2_cleanup_execution_worktree || true
    return "$sync_rc"
}

_phase7_handoff_poll_interval_seconds() {
    printf '%s\n' "${LAUREN_LOOP_PHASE7_HANDOFF_POLL_INTERVAL_SEC:-30}"
}

_phase7_handoff_grace_seconds() {
    printf '%s\n' "${LAUREN_LOOP_PHASE7_HANDOFF_GRACE_SEC:-15}"
}

_phase7_normalize_status_token() {
    local raw="$1"
    local normalized=""

    normalized=$(printf '%s' "$raw" \
        | tr -d '\r' \
        | sed 's/\*//g; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -n "$normalized" ]] || return 0

    normalized=$(printf '%s' "$normalized" | tr '[:lower:]' '[:upper:]')
    case "$normalized" in
        BLOCKED|BLOCKED\ *)
            printf 'BLOCKED\n'
            ;;
        COMPLETE|COMPLETE\ *|EXECUTION\ COMPLETE|EXECUTION\ COMPLETE\ *)
            printf 'COMPLETE\n'
            ;;
        FAILED|FAILED\ *|EXECUTION\ FAILED|EXECUTION\ FAILED\ *)
            printf 'FAILED\n'
            ;;
    esac
}

_phase7_read_sidecar_status() {
    local artifact="$1"
    local artifact_path=""
    local sidecar=""
    local raw=""

    artifact_path=$(_v2_execution_worktree_read_path_for "$artifact")
    sidecar="${artifact_path%.*}.contract.json"
    [[ -f "$sidecar" ]] || return 0

    if command -v jq >/dev/null 2>&1; then
        raw=$(jq -r 'if has("status") then .status else empty end' "$sidecar" 2>/dev/null || true)
    else
        raw=$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' "$sidecar" 2>/dev/null \
            | tail -1 \
            | sed -E 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    fi

    _phase7_normalize_status_token "$raw"
}

_phase7_read_status_signal() {
    local artifact="$1"
    local artifact_path=""
    local status=""

    status=$(_phase7_read_sidecar_status "$artifact")
    if [[ -n "$status" ]]; then
        printf '%s\n' "$status"
        return 0
    fi

    artifact_path=$(_v2_execution_worktree_read_path_for "$artifact")
    _parse_contract "$artifact_path" "status"
}

_phase7_sync_fix_execution_artifacts() {
    local comp_dir="$1"
    _v2_sync_execution_worktree_files "${comp_dir}/fix-execution.md" "${comp_dir}/fix-execution.contract.json"
}

_phase7_poll_fix_execution_handoff() {
    local comp_dir="$1" fix_executor_pid="$2" result_file="$3" log_file="${4:-}"
    local poll_interval=""
    local terminal_status=""
    local artifact="${comp_dir}/fix-execution.md"

    poll_interval=$(_phase7_handoff_poll_interval_seconds)
    : > "$result_file"

    while kill -0 "$fix_executor_pid" 2>/dev/null; do
        terminal_status=$(_phase7_read_sidecar_status "$artifact")
        case "$terminal_status" in
            COMPLETE|FAILED)
                printf '%s\n' "$terminal_status" > "$result_file"
                if [[ -n "$log_file" ]]; then
                    printf '[phase7-handoff] worktree status=%s -> terminating fix executor pid=%s\n' \
                        "$terminal_status" "$fix_executor_pid" >> "$log_file"
                fi
                _terminate_pid_tree "$fix_executor_pid" "$(_phase7_handoff_grace_seconds)"
                return 0
                ;;
        esac

        sleep "$poll_interval"
    done
}

_mark_fix_execution_handoff() {
    local fix_execution_file="${1:-${comp_dir}/fix-execution.md}"
    local handoff_file="${comp_dir}/human-review-handoff.md"

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

_v2_file_size_bytes() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        printf '0\n'
        return 0
    fi
    wc -c < "$path" | tr -d '[:space:]'
}

_v2_filtered_worktree_status_lines() {
    local status_line="" status_path=""
    git status --short --untracked-files=all 2>/dev/null | while IFS= read -r status_line; do
        [[ -n "$status_line" ]] || continue
        status_path="${status_line#?? }"
        case "$status_path" in
            *" -> "*)
                status_path="${status_path##* -> }"
                ;;
        esac
        if _v2_is_pipeline_owned_phase4_noise "$status_path"; then
            continue
        fi
        printf '%s\n' "$status_line"
    done
}

_v2_phase_execution_diagnostic_lines() {
    local log_activity="$1" log_path="$2" diff_file="$3"
    local worktree_root="" numstat_file="" status_lines=""
    worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    numstat_file=$(_v2_numstat_artifact_path "$diff_file")
    status_lines=$(_v2_filtered_worktree_status_lines)

    printf 'active worktree path: %s\n' "${_V2_EXEC_WORKTREE_PATH:-unknown}"
    printf 'worktree repo root: %s\n' "${worktree_root:-unknown}"
    printf 'execution log path: %s\n' "$log_path"
    printf 'execution log activity detected: %s\n' "$log_activity"
    printf 'diff artifact state: %s (%s)\n' "$diff_file" "$([[ -s "$diff_file" ]] && printf 'non-empty' || printf 'empty')"
    printf 'numstat artifact state: %s (%s)\n' "$numstat_file" "$([[ -s "$numstat_file" ]] && printf 'non-empty' || printf 'empty')"
    if [[ -n "$status_lines" ]]; then
        _v2_prefix_lines "worktree status" "$status_lines"
    else
        printf 'worktree status: clean\n'
    fi
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
    _V2_EXEC_WORKTREE_PATH=""
    _V2_EXEC_WORKTREE_BRANCH=""
    _V2_EXEC_TARGET_REF=""
    _V2_EXEC_TARGET_HEAD_SHA=""
    _V2_LAST_MERGE_RECOVERABLE=false
    _V2_PRESERVED_EXEC_WORKTREE_PATH=""
    _V2_PRESERVED_EXEC_WORKTREE_BRANCH=""
    _V2_PRESERVED_EXEC_TARGET_REF=""
    _V2_PRESERVED_EXEC_TARGET_HEAD_SHA=""
    _V2_PRESERVED_EXEC_COMMIT_SHA=""
    _V2_PRESERVED_RECOVERY_DIR=""
    _V2_PRESERVED_COMBINED_PATCH=""
    _V2_PRESERVED_COMMIT_LOG=""
    _V2_PRESERVED_FORMAT_PATCH_DIR=""
    _V2_PRESERVED_WORKTREE_PATCH=""
}
_list_active_job_pids() {
    jobs -p 2>/dev/null || true
}
_terminate_active_jobs() {
    stop_agent_monitor || true
    local active_jobs=()
    local p=""

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        active_jobs[${#active_jobs[@]}]="$p"
    done < <(_list_active_job_pids)

    [[ ${#active_jobs[@]} -gt 0 ]] || return 0

    _terminate_pid_tree_set "$(_active_job_terminate_grace_seconds)" "${active_jobs[@]}" || true

    for p in "${active_jobs[@]}"; do
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
    local _cleanup_fix_cycles="${fix_cycle:-0}"

    # Safety net: if the task is still "in progress" when cleanup runs,
    # something exited without setting a terminal status (e.g. set -e).
    if [[ -n "$_CURRENT_TASK_FILE" && -f "$_CURRENT_TASK_FILE" ]]; then
        local _current_status=""
        _current_status=$(grep '^## Status: ' "$_CURRENT_TASK_FILE" 2>/dev/null | sed 's/^## Status: //' || true)
        if ! _is_terminal_status "$_current_status"; then
            set_task_status "$_CURRENT_TASK_FILE" "blocked" || true
            log_execution "$_CURRENT_TASK_FILE" "cleanup_v2: task was still 'in progress' at exit — set to blocked" || true
            finalize_v2_task_metadata "$_CURRENT_TASK_FILE" "cleanup-safety-net" "blocked" "0" || true
        fi
    fi

    _terminate_active_jobs || true
    _finalize_run_manifest "cleanup" "$_cleanup_fix_cycles" || true
    _v2_save_worktree_diff || true
    _v2_cleanup_execution_worktree || true
    release_lock || true
    _clear_active_runtime_state || true
    _CLEANUP_V2_RUNNING=false
    _CLEANUP_V2_DONE=true
}
trap cleanup_v2 EXIT

_interrupted() {
    local signal="$1"
    local exit_code=1
    local _interrupt_fix_cycles="${fix_cycle:-0}"
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
    fi
    _terminate_active_jobs || true
    _append_interrupted_cost_rows "$signal" || true
    _finalize_run_manifest "interrupted" "$_interrupt_fix_cycles" || true
    _print_cost_summary || true
    _print_phase_timing || true
    if [[ -n "$_CURRENT_TASK_FILE" && -f "$_CURRENT_TASK_FILE" ]]; then
        finalize_v2_task_metadata "$_CURRENT_TASK_FILE" "interrupted-${signal}" "interrupted" "$_interrupt_fix_cycles" || true
    fi
    _v2_save_worktree_diff || true
    _v2_cleanup_execution_worktree || true

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
        local jittered_backoff=""
        local fallback_reason=""
        local attempt_number=1
        local attempt_output_file="$output_file"
        local attempt_prompt="$prompt"
        local attempt_summary_file=""
        local canonical_summary_file=""
        local attempt_artifact_state="not_applicable"
        local tool_written_artifact=false
        local timeout_seconds=0
        local dispatch_start_ts=0
        local elapsed_seconds=0
        local retry_stopped_for_wall_cap=false
        attempt_log=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-codex-attempt.XXXXXX") || {
            _remove_active_agent_meta "$meta_path"
            echo "ERROR: Failed to create Codex attempt log for $role" >&2
            return 1
        }
        timeout_seconds=$(_duration_to_seconds "$timeout")
        dispatch_start_ts=$(date +%s)

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
            codex_profile="$LAUREN_LOOP_CODEX_PROFILE_HIGH"

            for fallback_backoff in 15 30 60; do
                elapsed_seconds=$(( $(date +%s) - dispatch_start_ts ))
                if (( elapsed_seconds < 0 )); then
                    elapsed_seconds=0
                fi
                if (( elapsed_seconds * 2 >= timeout_seconds * 3 )); then
                    retry_stopped_for_wall_cap=true
                    echo "WARN: Codex ${fallback_reason} failure for $role hit wall-time cap after ${elapsed_seconds}s across ${attempt_number} attempt(s); wall_cap=${timeout_seconds}s*1.5." >> "$log_file"
                    break
                fi

                jittered_backoff=$(_jittered_backoff "$fallback_backoff")
                echo "WARN: Codex ${fallback_reason} failure for $role; retrying with profile ${codex_profile} after ${jittered_backoff}s jittered backoff (base=${fallback_backoff}s)." >> "$log_file"
                sleep "$jittered_backoff"
                elapsed_seconds=$(( $(date +%s) - dispatch_start_ts ))
                if (( elapsed_seconds < 0 )); then
                    elapsed_seconds=0
                fi
                if (( elapsed_seconds * 2 >= timeout_seconds * 3 )); then
                    retry_stopped_for_wall_cap=true
                    echo "WARN: Codex ${fallback_reason} failure for $role hit wall-time cap after ${elapsed_seconds}s across ${attempt_number} attempt(s); wall_cap=${timeout_seconds}s*1.5." >> "$log_file"
                    break
                fi
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

            if [[ "$retry_stopped_for_wall_cap" != true ]] && [[ -n "$fallback_reason" ]] && [[ "$attempt_artifact_state" != "valid" ]] && [[ "$attempt_artifact_state" != "complete_fallback" ]]; then
                elapsed_seconds=$(( $(date +%s) - dispatch_start_ts ))
                if (( elapsed_seconds < 0 )); then
                    elapsed_seconds=0
                fi
                echo "WARN: Codex ${fallback_reason} failure for $role exhausted retries after ${elapsed_seconds}s across ${attempt_number} attempt(s)." >> "$log_file"
            fi
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
        "$comp_dir"/*.tsv \
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
        "$comp_dir/execution-diff.numstat.tsv" \
        "$comp_dir/execution-diff.estimate.numstat.tsv" \
        "$comp_dir/review-synthesis.md" \
        "$comp_dir/fix-plan.md" \
        "$comp_dir/fix-critique.md" \
        "$comp_dir/fix-execution.md" \
        "$comp_dir/execution-scope-triage.json" \
        "$comp_dir/execution-scope-triage.raw.json" \
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
        "$comp_dir"/execution-scope-triage.raw.attempt-*.json \
        "$comp_dir"/reviewer-b.raw.attempt-*.md \
        "$comp_dir/plan-1.md" \
        "$comp_dir/plan-2.md" \
        "$comp_dir/.plan-mapping" \
        "$comp_dir/.review-mapping" \
        "$comp_dir"/.review-mapping.cycle* \
        "$comp_dir/human-review-handoff.md" \
        "$comp_dir/blinding-metadata.log" \
        "$comp_dir/run-manifest.json" \
        "$comp_dir/traditional-dev-proxy.json" \
        "$comp_dir/.cycle-state.json" \
        "$comp_dir/plan-evaluation.contract.json" \
        "$comp_dir/plan-critique.contract.json" \
        "$comp_dir/fix-critique.contract.json" \
        "$comp_dir/review-synthesis.contract.json" \
        "$comp_dir/fix-plan.contract.json" \
        "$comp_dir/fix-execution.contract.json"
    rm -f "$comp_dir"/fix-diff-cycle*.patch
    rm -f "$comp_dir"/fix-diff-cycle*.numstat.tsv
    rm -f "$comp_dir"/fix-diff-cycle*.estimate.numstat.tsv
    rm -rf "$comp_dir/scope-triage-quarantine"
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
_V2_LAST_ESTIMATE_SCOPE_PATHS=""
_V2_PHASE4_CHECKPOINT_NEEDS_TRIAGE=false
_V2_PHASE4_CHECKPOINT_BEFORE_SHA=""
_V2_PHASE4_CHECKPOINT_PREEXISTING_DIRTY=""
_V2_SCOPE_TRIAGE_MAX_AGENT_CANDIDATES=30

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

        _V2_SCOPE_PATHS=$(_extract_xml_task_paths "$plan_file" | _reject_slug_internal_paths "$SLUG")
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
        ".lauren-loop-runtime/${SLUG}/"*|\
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

_v2_numstat_artifact_path() {
    local diff_file="$1"
    if [[ "$diff_file" == *.patch ]]; then
        printf '%s\n' "${diff_file%.patch}.numstat.tsv"
    else
        printf '%s.numstat.tsv\n' "$diff_file"
    fi
}

_v2_estimate_numstat_artifact_path() {
    local diff_file="$1"
    if [[ "$diff_file" == *.patch ]]; then
        printf '%s\n' "${diff_file%.patch}.estimate.numstat.tsv"
    else
        printf '%s.estimate.numstat.tsv\n' "$diff_file"
    fi
}

_v2_append_untracked_numstat_entries() {
    local numstat_file="$1" untracked_files="$2"
    local numstat_path="$numstat_file"
    local repo_root=""

    [[ -n "$untracked_files" ]] || return 0
    if [[ "$numstat_path" != /* ]]; then
        numstat_path="$PWD/$numstat_file"
    fi

    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    (
        cd "$repo_root" || exit 0
        local path="" line_count=0
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            [[ -f "$path" ]] || continue
            line_count=$(awk 'END { print NR + 0 }' "$path" 2>/dev/null || echo "0")
            printf '%s\t0\t%s\n' "$line_count" "$path" >> "$numstat_path"
        done <<< "$untracked_files"
    ) || true
}

_v2_write_numstat_snapshot() {
    local before_sha="$1" numstat_file="$2" tracked_files="$3" untracked_files="$4"
    local numstat_path="$numstat_file"
    local repo_root=""
    local -a scope_args=()
    local path=""

    if [[ "$numstat_path" != /* ]]; then
        numstat_path="$PWD/$numstat_file"
    fi
    : > "$numstat_path"

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        scope_args+=("$path")
    done <<< "$tracked_files"

    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    (
        cd "$repo_root" || exit 0
        if [[ ${#scope_args[@]} -gt 0 ]]; then
            if [[ -n "$before_sha" ]]; then
                git diff --numstat "$before_sha" -- "${scope_args[@]}" >> "$numstat_path" 2>/dev/null || true
            else
                git diff HEAD --numstat -- "${scope_args[@]}" >> "$numstat_path" 2>/dev/null || true
            fi
        fi
    ) || true

    _v2_append_untracked_numstat_entries "$numstat_path" "$untracked_files"
}

_v2_write_estimate_numstat_snapshot_for_scope() {
    local before_sha="$1" diff_file="$2" scope_paths="$3" scope_source="$4" preexisting_dirty="${5:-}"
    local estimate_numstat_file=""
    local tracked_files=""
    local untracked_files=""

    estimate_numstat_file=$(_v2_estimate_numstat_artifact_path "$diff_file")
    tracked_files=$(_v2_collect_changed_files_for_scope "$before_sha" "$scope_paths" "$scope_source" | _v2_unique_nonblank_lines)
    untracked_files=$(_v2_collect_untracked_files_for_scope "$scope_paths" "$scope_source")

    if [[ -n "$preexisting_dirty" ]]; then
        tracked_files=$(_v2_subtract_preexisting_files "$tracked_files" "$preexisting_dirty" "$before_sha")
        untracked_files=$(_v2_subtract_preexisting_files "$untracked_files" "$preexisting_dirty" "$before_sha")
    fi

    _v2_write_numstat_snapshot "$before_sha" "$estimate_numstat_file" "$tracked_files" "$untracked_files"
}

_v2_refresh_traditional_dev_proxy_artifacts() {
    local task_file="$1" before_sha="$2" diff_file="$3" scope_paths="$4" scope_source="$5"
    local preexisting_dirty="${6:-}" fix_cycles="${7:-0}"

    _v2_write_estimate_numstat_snapshot_for_scope "$before_sha" "$diff_file" "$scope_paths" "$scope_source" "$preexisting_dirty"
    persist_v2_traditional_dev_proxy_json "$task_file" "$fix_cycles" >/dev/null 2>&1 || true
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

# NOTE: relies on ambient _FAIL_PHASE_* phase context set by caller
_block_on_untracked_files() {
    local task_file="$1" phase_label="$2" plan_file="${3:-}" before_sha="${4:-}"
    local untracked_files=""
    local scope_source=""
    local fallback_warning=""
    local untracked_summary=""
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
    log_execution "$task_file" "${phase_label}: Untracked files detected within task scope (source: ${scope_source})" || true
    if [[ -n "$fallback_warning" ]]; then
        log_execution "$task_file" "${phase_label}: WARN: ${fallback_warning}" || true
    fi
    _log_diagnostic_lines "$task_file" "$(_v2_scope_diagnostic_lines "$_V2_SCOPE_PATHS")"
    _log_diagnostic_lines "$task_file" "$untracked_files"
    untracked_summary=$(printf '%s\n' "$untracked_files" | paste -sd ',' -)
    _fail_phase \
        "validating-scope" \
        "${phase_label}: Untracked files detected within task scope" \
        "Move or stage the overlapping untracked files, then retry" \
        "scope_violation" \
        "phase_label=${phase_label}; scope_source=${scope_source}; files=${untracked_summary}" || true
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

_list_markdown_headings_outside_fences() {
    local source_file="$1"
    awk '
        function ltrim(value) {
            sub(/^[[:space:]]+/, "", value)
            return value
        }
        BEGIN { in_fence=0 }
        {
            line = $0
            stripped = ltrim(line)
            if (stripped ~ /^```/) {
                in_fence = !in_fence
                next
            }
            if (!in_fence && stripped ~ /^#{1,6}[[:space:]]+/) {
                printf "%d:%s\n", NR, stripped
            }
        }
    ' "$source_file"
}

_selected_plan_heading_line() {
    local source_file="$1"
    awk '
        function ltrim(value) {
            sub(/^[[:space:]]+/, "", value)
            return value
        }
        function rtrim(value) {
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function heading_level(line, stripped) {
            stripped = ltrim(line)
            if (stripped ~ /^#{1,6}[[:space:]]+/) {
                match(stripped, /^#+/)
                return RLENGTH
            }
            return 0
        }
        function heading_text(line, stripped) {
            stripped = ltrim(line)
            sub(/^#{1,6}[[:space:]]+/, "", stripped)
            return rtrim(stripped)
        }
        BEGIN { in_fence=0; found=0 }
        {
            line = $0
            stripped = ltrim(line)
            is_fence = (stripped ~ /^```/)
            if (!in_fence) {
                level = heading_level(line)
                if (level >= 2 && level <= 3 && tolower(heading_text(line)) == "selected plan") {
                    print NR
                    found = 1
                    exit 0
                }
            }
            if (is_fence) {
                in_fence = !in_fence
            }
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$source_file"
}

_selected_plan_extraction_diagnostics() {
    local source_file="$1"
    local matched_line=""
    local headings=""

    matched_line=$(_selected_plan_heading_line "$source_file" 2>/dev/null || true)
    headings=$(_list_markdown_headings_outside_fences "$source_file" 2>/dev/null || true)

    printf 'matched Selected Plan heading line: %s\n' "${matched_line:-none}"
    printf 'all headings in %s:\n' "$(basename "$source_file")"
    if [[ -n "$headings" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            printf 'heading: %s\n' "$line"
        done <<< "$headings"
    else
        printf 'heading: (none)\n'
    fi
}

_extract_selected_plan_to_file() {
    local source_file="$1" output_file="$2"
    local tmp_file
    tmp_file=$(mktemp)

    awk '
        function ltrim(value) {
            sub(/^[[:space:]]+/, "", value)
            return value
        }
        function rtrim(value) {
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function heading_level(line, stripped) {
            stripped = ltrim(line)
            if (stripped ~ /^#{1,6}[[:space:]]+/) {
                match(stripped, /^#+/)
                return RLENGTH
            }
            return 0
        }
        function heading_text(line, stripped) {
            stripped = ltrim(line)
            sub(/^#{1,6}[[:space:]]+/, "", stripped)
            return rtrim(stripped)
        }
        BEGIN {
            in_fence = 0
            matched = 0
            matched_level = 0
            saw_body = 0
        }
        {
            line = $0
            stripped = ltrim(line)
            is_fence = (stripped ~ /^```/)

            if (!in_fence) {
                level = heading_level(line)
                if (!matched && level >= 2 && level <= 3 && tolower(heading_text(line)) == "selected plan") {
                    matched = 1
                    matched_level = level
                    next
                }
                if (matched && level > 0 && level <= matched_level) {
                    exit 0
                }
            }

            if (matched) {
                print line
                if (line ~ /[^[:space:]]/) {
                    saw_body = 1
                }
            }

            if (is_fence) {
                in_fence = !in_fence
            }
        }
        END {
            if (!matched || !saw_body) {
                exit 1
            }
        }
    ' "$source_file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

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
    local scope_override_paths="${6:-}" scope_override_source="${7:-}"
    local numstat_file=""
    local tracked_all_files=""
    local tracked_captured_files=""

    _V2_LAST_CAPTURE_SCOPE_SOURCE=""
    _V2_LAST_CAPTURE_SCOPE_PATHS=""
    _V2_LAST_CAPTURE_ALL_FILES=""
    _V2_LAST_CAPTURED_FILES=""
    _V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES=""
    _V2_LAST_CAPTURE_UNTRACKED_FILES=""

    _v2_resolve_scope_paths "$task_file" "$plan_file" "$before_sha" || true
    if [[ -n "$scope_override_paths" ]]; then
        _V2_SCOPE_SOURCE="${scope_override_source:-$_V2_SCOPE_SOURCE}"
        _V2_SCOPE_PATHS="$scope_override_paths"
    fi
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

    numstat_file=$(_v2_numstat_artifact_path "$diff_file")
    _v2_write_numstat_snapshot "$before_sha" "$numstat_file" "$tracked_captured_files" "$_V2_LAST_CAPTURE_UNTRACKED_FILES"
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

_v2_scope_triage_state_path() {
    local comp_dir="$1"
    printf '%s\n' "${comp_dir}/execution-scope-triage.json"
}

_v2_scope_triage_raw_output_path() {
    local comp_dir="$1"
    printf '%s\n' "${comp_dir}/execution-scope-triage.raw.json"
}

_v2_scope_triage_quarantine_dir() {
    local comp_dir="$1"
    printf '%s\n' "${comp_dir}/scope-triage-quarantine"
}

_v2_repo_relative_path() {
    local path="$1"
    local repo_root=""
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$repo_root" && "$path" == "$repo_root/"* ]]; then
        printf '%s\n' "${path#$repo_root/}"
    else
        printf '%s\n' "$path"
    fi
}

_v2_filter_out_paths_from_list() {
    local source_paths="$1" paths_to_remove="$2"
    local path
    [[ -n "$source_paths" ]] || return 0
    if [[ -z "$paths_to_remove" ]]; then
        printf '%s\n' "$source_paths"
        return 0
    fi
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if ! printf '%s\n' "$paths_to_remove" | grep -qxF "$path"; then
            printf '%s\n' "$path"
        fi
    done <<< "$source_paths" | _v2_unique_nonblank_lines
}

_v2_path_changed_in_commit_range() {
    local before_sha="$1" path="$2"
    [[ -n "$before_sha" ]] || return 1
    git diff "$before_sha"..HEAD --name-only -- "$path" 2>/dev/null | grep -qxF "$path"
}

_v2_is_untracked_path() {
    local path="$1"
    git ls-files --others --exclude-standard -- "$path" 2>/dev/null | grep -qxF "$path"
}

_v2_is_pipeline_owned_phase4_noise() {
    local path="$1"
    local task_file="${_CURRENT_TASK_FILE:-}"
    local task_dir=""
    local task_file_rel=""
    local task_dir_rel=""

    if [[ -n "$task_file" ]]; then
        task_file_rel=$(_v2_main_repo_relative_path "$task_file" 2>/dev/null || true)
        task_dir=$(_v2_task_dir_for_task_file "$task_file" 2>/dev/null || true)
        task_dir_rel=$(_v2_main_repo_relative_path "$task_dir" 2>/dev/null || true)
    fi

    case "$path" in
        ".lauren-loop-runtime/${SLUG}/"*)
            return 0
            ;;
    esac

    if [[ -n "$task_file_rel" && "$path" == "$task_file_rel" ]]; then
        return 0
    fi

    if [[ -n "$task_dir_rel" ]]; then
        case "$path" in
            "${task_dir_rel}/competitive/"*|\
            "${task_dir_rel}/logs/"*)
                return 0
                ;;
        esac
    fi

    case "$path" in
        "docs/tasks/open/${SLUG}/task.md"|\
        "docs/tasks/open/${SLUG}/competitive/"*|\
        "docs/tasks/open/${SLUG}/logs/"*)
            return 0
            ;;
    esac

    return 1
}

_v2_filter_pipeline_owned_task_artifact_paths() {
    local source_paths="$1"
    local path=""

    [[ -n "$source_paths" ]] || return 0

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if _v2_is_pipeline_owned_phase4_noise "$path"; then
            printf '%s\n' "$path"
        fi
    done <<< "$source_paths" | _v2_unique_nonblank_lines
}

_v2_capture_preexisting_pipeline_owned_root_dirty() {
    local current_dirty="${1:-}"

    if [[ -z "$current_dirty" ]]; then
        current_dirty=$(_v2_snapshot_dirty_files)
    fi

    _V2_EXEC_PREEXISTING_ROOT_DIRTY=$(_v2_filter_pipeline_owned_task_artifact_paths "$current_dirty")
}

_v2_collect_out_of_scope_untracked_paths_for_triage() {
    local scope_paths="$1" scope_source="$2" pre_exec_dirty="${3:-}"
    local current=""
    _v2_scope_source_is_constrained "$scope_source" || return 0
    current=$(git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if _is_ignored_untracked_path "$path"; then
            continue
        fi
        if _v2_path_in_scope "$path" "$scope_paths"; then
            continue
        fi
        printf '%s\n' "$path"
    done | _v2_unique_nonblank_lines)
    _v2_subtract_preexisting_files "$current" "$pre_exec_dirty"
}

_v2_scope_triage_diff_for_path() {
    local before_sha="$1" path="$2"
    local tmp_file=""
    if _v2_is_untracked_path "$path"; then
        [[ -e "$path" ]] || return 0
        diff -u /dev/null "$path" 2>/dev/null || true
        return 0
    fi
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/scope-triage-diff.XXXXXX") || return 1
    if [[ -n "$before_sha" ]]; then
        git diff "$before_sha"..HEAD -- "$path" > "$tmp_file" 2>/dev/null || true
    else
        : > "$tmp_file"
    fi
    if [[ ! -s "$tmp_file" ]]; then
        git diff -- "$path" > "$tmp_file" 2>/dev/null || true
        git diff --cached -- "$path" >> "$tmp_file" 2>/dev/null || true
    fi
    cat "$tmp_file"
    rm -f "$tmp_file"
}

_v2_build_scope_triage_instruction() {
    local task_file="$1" plan_file="$2" output_path="$3" scope_paths="$4" triage_candidates="$5" before_sha="$6"
    local scope_block="None declared."
    local triage_block=""
    local path diff_text
    if [[ -n "$scope_paths" ]]; then
        scope_block=""
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            scope_block+="- ${path}"$'\n'
        done <<< "$scope_paths"
    fi
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        diff_text=$(_v2_scope_triage_diff_for_path "$before_sha" "$path")
        [[ -n "$diff_text" ]] || diff_text="(no diff available)"
        triage_block+="### ${path}"$'\n'
        triage_block+='```diff'$'\n'
        triage_block+="${diff_text}"$'\n'
        triage_block+='```'$'\n'$'\n'
    done <<< "$triage_candidates"
    printf '%s\n' "The task file is ${task_file}. Read the approved plan at ${plan_file}."
    printf '%s\n' "Write the JSON classification array to ${output_path}."
    printf '\n%s\n' "Declared plan scope from ## Files to Modify:"
    printf '%s' "$scope_block"
    printf '\n%s\n' "Out-of-scope files to classify:"
    printf '%s' "$triage_block"
}

_v2_scope_triage_entries_as_tsv() {
    local json_file="$1"
    [[ -f "$json_file" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$json_file" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(data, list):
    raise SystemExit(1)
seen = set()
for item in data:
    if not isinstance(item, dict):
        raise SystemExit(1)
    file_path = item.get("file")
    classification = item.get("classification")
    reasoning = item.get("reasoning")
    if not all(isinstance(value, str) for value in (file_path, classification, reasoning)):
        raise SystemExit(1)
    if classification not in ("PLAN_GAP", "NOISE"):
        raise SystemExit(1)
    if file_path in seen:
        print(f"scope-triage: duplicate entry for file: {file_path}", file=sys.stderr)
        raise SystemExit(1)
    seen.add(file_path)
    reasoning = reasoning.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()
    print("\t".join((file_path, classification, reasoning)))
PY
}

_v2_scope_triage_records_cover_candidates() {
    local triage_candidates="$1" triage_records="$2"
    local path record_count=0
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        record_count=$(printf '%s\n' "$triage_records" | awk -F'\t' -v target="$path" '$1 == target { count++ } END { print count + 0 }')
        [[ "$record_count" -eq 1 ]] || return 1
    done <<< "$triage_candidates"
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if ! printf '%s\n' "$triage_candidates" | grep -qxF "${path%%$'\t'*}"; then
            return 1
        fi
    done <<< "$triage_records"
}

_v2_restore_tracked_noise_path() {
    local path="$1"
    git reset -q HEAD -- "$path" >/dev/null 2>&1 || true
    if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
        git checkout -- "$path" >/dev/null 2>&1 || return 1
    else
        rm -f -- "$path" >/dev/null 2>&1 || return 1
    fi
}

_v2_quarantine_untracked_noise_path() {
    local comp_dir="$1" path="$2"
    local quarantine_root=""
    local destination=""
    quarantine_root=$(_v2_scope_triage_quarantine_dir "$comp_dir")
    destination="${quarantine_root}/${path}"
    mkdir -p "$(dirname "$destination")" || return 1
    mv -- "$path" "$destination" || return 1
    printf '%s\n' "$destination"
}

_v2_ensure_scope_triage_log_section() {
    local task_file="$1"
    local count=0 insert_line="" tmp_file=""
    count=$(grep -n -F -x '## Scope Triage Log' "$task_file" | wc -l | tr -d ' ')
    if [[ "$count" -gt 1 ]]; then
        echo "Expected exactly one section: ## Scope Triage Log" >&2
        return 1
    fi
    if [[ "$count" -eq 1 ]]; then
        return 0
    fi
    insert_line=$(grep -n -F -x '## Execution Log' "$task_file" | head -1 | cut -d: -f1)
    tmp_file=$(same_dir_temp_file "$task_file") || return 1
    if [[ -n "$insert_line" ]]; then
        awk -v insert_line="$insert_line" '
            NR == insert_line {
                print "## Scope Triage Log"
                print ""
            }
            { print }
        ' "$task_file" > "$tmp_file" && mv "$tmp_file" "$task_file" || { rm -f "$tmp_file"; return 1; }
    else
        {
            cat "$task_file"
            printf '\n## Scope Triage Log\n'
        } > "$tmp_file" && mv "$tmp_file" "$task_file" || { rm -f "$tmp_file"; return 1; }
    fi
}

_v2_append_scope_triage_log_entry() {
    local task_file="$1" phase_label="$2" result="$3" classifications="$4" actions="$5" failure_reason="${6:-}"
    local section_line="" tmp_file=""
    _v2_ensure_scope_triage_log_section "$task_file" || return 1
    section_line=$(grep -n -F -x '## Scope Triage Log' "$task_file" | head -1 | cut -d: -f1)
    [[ -n "$section_line" ]] || return 1
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/scope-triage-log.XXXXXX") || return 1
    {
        printf '### %s Scope Triage - %s\n' "$phase_label" "$(_iso_timestamp)"
        printf -- '- Result: %s\n' "$result"
        if [[ -n "$failure_reason" ]]; then
            printf -- '- Failure: %s\n' "$failure_reason"
        fi
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            local path="" classification="" reasoning="" action_line=""
            path=$(printf '%s\n' "$line" | awk -F'\t' '{ print $1 }')
            classification=$(printf '%s\n' "$line" | awk -F'\t' '{ print $2 }')
            reasoning=$(printf '%s\n' "$line" | awk -F'\t' '{ print $3 }')
            action_line=$(printf '%s\n' "$actions" | awk -F'\t' -v target="$path" '$1 == target { print $2 ": " $3; exit }')
            if [[ -n "$action_line" ]]; then
                printf -- '- %s: `%s` - %s [%s]\n' "$classification" "$path" "$reasoning" "$action_line"
            else
                printf -- '- %s: `%s` - %s\n' "$classification" "$path" "$reasoning"
            fi
        done <<< "$classifications"
        printf '\n'
    } > "$tmp_file"
    _sed_i "${section_line}r ${tmp_file}" "$task_file"
    rm -f "$tmp_file"
}

_v2_write_scope_triage_state() {
    local state_file="$1" status="$2" before_sha="$3" plan_file="$4" diff_file="$5" preexisting_dirty="$6"
    local raw_output_file="${7:-}" failure_reason="${8:-}" classifications="${9:-}" actions="${10:-}"
    local tmp_file=""
    command -v python3 >/dev/null 2>&1 || return 1
    tmp_file=$(same_dir_temp_file "$state_file") || return 1
    TRIAGE_SCOPE_SOURCE="${_V2_LAST_CAPTURE_SCOPE_SOURCE:-}" \
    TRIAGE_SCOPE_PATHS="${_V2_LAST_CAPTURE_SCOPE_PATHS:-}" \
    TRIAGE_ESTIMATE_SCOPE_PATHS="${_V2_LAST_ESTIMATE_SCOPE_PATHS:-}" \
    TRIAGE_ALL_FILES="${_V2_LAST_CAPTURE_ALL_FILES:-}" \
    TRIAGE_CAPTURED_FILES="${_V2_LAST_CAPTURED_FILES:-}" \
    TRIAGE_OUT_OF_SCOPE_FILES="${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" \
    TRIAGE_UNTRACKED_FILES="${_V2_LAST_CAPTURE_UNTRACKED_FILES:-}" \
    TRIAGE_PREEXISTING_DIRTY="$preexisting_dirty" \
    TRIAGE_CLASSIFICATIONS="$classifications" \
    TRIAGE_ACTIONS="$actions" \
    python3 - "$tmp_file" "$status" "$before_sha" "$plan_file" "$diff_file" "$raw_output_file" "$failure_reason" "$(_iso_timestamp)" <<'PY'
import json
import os
import sys

tmp_file, status, before_sha, plan_file, diff_file, raw_output_file, failure_reason, timestamp = sys.argv[1:9]

def lines(name):
    return [line for line in os.environ.get(name, "").splitlines() if line.strip()]

def classification_records():
    records = []
    for line in lines("TRIAGE_CLASSIFICATIONS"):
        file_path, classification, reasoning = (line.split("\t", 2) + ["", "", ""])[:3]
        if file_path and classification:
            records.append(
                {
                    "file": file_path,
                    "classification": classification,
                    "reasoning": reasoning,
                }
            )
    return records

def action_records():
    records = []
    for line in lines("TRIAGE_ACTIONS"):
        file_path, action, details = (line.split("\t", 2) + ["", "", ""])[:3]
        if file_path and action:
            records.append(
                {
                    "file": file_path,
                    "action": action,
                    "details": details,
                }
            )
    return records

data = {
    "status": status,
    "timestamp": timestamp,
    "before_sha": before_sha or None,
    "plan_file": plan_file or None,
    "diff_file": diff_file or None,
    "raw_output_file": raw_output_file or None,
    "failure_reason": failure_reason or None,
    "scope_source": os.environ.get("TRIAGE_SCOPE_SOURCE") or None,
    "scope_paths": lines("TRIAGE_SCOPE_PATHS"),
    "estimate_scope_paths": lines("TRIAGE_ESTIMATE_SCOPE_PATHS"),
    "all_files": lines("TRIAGE_ALL_FILES"),
    "captured_files": lines("TRIAGE_CAPTURED_FILES"),
    "out_of_scope_files": lines("TRIAGE_OUT_OF_SCOPE_FILES"),
    "untracked_files": lines("TRIAGE_UNTRACKED_FILES"),
    "preexisting_dirty": lines("TRIAGE_PREEXISTING_DIRTY"),
    "classifications": classification_records(),
    "actions": action_records(),
}

with open(tmp_file, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
    mv "$tmp_file" "$state_file" || { rm -f "$tmp_file"; return 1; }
}

_v2_read_scope_triage_state_field() {
    local state_file="$1" field="$2"
    [[ -f "$state_file" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$state_file" "$field" <<'PY'
import json
import sys

state_file, field = sys.argv[1:3]
with open(state_file, encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(field)
if isinstance(value, str):
    print(value)
elif value is None:
    print("")
else:
    raise SystemExit(1)
PY
}

_v2_read_scope_triage_state_lines() {
    local state_file="$1" field="$2"
    [[ -f "$state_file" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$state_file" "$field" <<'PY'
import json
import sys

state_file, field = sys.argv[1:3]
with open(state_file, encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(field, [])
if not isinstance(value, list):
    raise SystemExit(1)
for item in value:
    if isinstance(item, str) and item.strip():
        print(item)
PY
}

_v2_handle_phase4_checkpoint() {
    local task_file="$1" baseline_diff="$2" scope_triage_state_file="$3" phase4_scope_plan_file="$4"
    local scope_triage_state=""
    local checkpoint_before_sha=""
    local checkpoint_preexisting_dirty=""
    local checkpoint_scope_source=""
    local checkpoint_scope_paths=""
    local checkpoint_estimate_scope_paths=""

    _V2_PHASE4_CHECKPOINT_NEEDS_TRIAGE=false
    _V2_PHASE4_CHECKPOINT_BEFORE_SHA=""
    _V2_PHASE4_CHECKPOINT_PREEXISTING_DIRTY=""

    [[ "${FORCE_RERUN:-false}" != "true" ]] || return 1
    [[ -f "$baseline_diff" ]] || return 1

    scope_triage_state=$(_v2_read_scope_triage_state_field "$scope_triage_state_file" "status" 2>/dev/null || true)
    if [[ -z "$scope_triage_state" ]]; then
        echo -e "${YELLOW}WARN: Phase 4 scope triage state missing or unreadable; resuming as pending from checkpoint${NC}"
        log_execution "$task_file" "Phase 4: WARNING scope triage state missing or unreadable; resuming as pending from checkpoint" || true
        scope_triage_state="pending"
    fi

    case "$scope_triage_state" in
        pending)
            echo -e "${BLUE}Phase 4: Executor skipped (checkpoint — scope triage pending)${NC}"
            log_execution "$task_file" "Phase 4: Executor skipped (checkpoint — scope triage pending)"
            checkpoint_before_sha=$(_v2_read_scope_triage_state_field "$scope_triage_state_file" "before_sha" 2>/dev/null || true)
            checkpoint_preexisting_dirty=$(_v2_read_scope_triage_state_lines "$scope_triage_state_file" "preexisting_dirty" 2>/dev/null || true)
            _V2_PHASE4_CHECKPOINT_BEFORE_SHA="$checkpoint_before_sha"
            _V2_PHASE4_CHECKPOINT_PREEXISTING_DIRTY="$checkpoint_preexisting_dirty"
            _V2_PHASE4_CHECKPOINT_NEEDS_TRIAGE=true
            capture_diff_artifact \
                "$checkpoint_before_sha" \
                "$baseline_diff" \
                "$task_file" \
                "$phase4_scope_plan_file" \
                "$checkpoint_preexisting_dirty"
            ;;
        skipped|completed|failed-open)
            echo -e "${GREEN}Phase 4: Skipped (checkpoint — execution diff and scope triage exist)${NC}"
            log_execution "$task_file" "Phase 4: Skipped (checkpoint)"
            checkpoint_before_sha=$(_v2_read_scope_triage_state_field "$scope_triage_state_file" "before_sha" 2>/dev/null || true)
            checkpoint_preexisting_dirty=$(_v2_read_scope_triage_state_lines "$scope_triage_state_file" "preexisting_dirty" 2>/dev/null || true)
            checkpoint_scope_source=$(_v2_read_scope_triage_state_field "$scope_triage_state_file" "scope_source" 2>/dev/null || true)
            checkpoint_scope_paths=$(_v2_read_scope_triage_state_lines "$scope_triage_state_file" "scope_paths" 2>/dev/null || true)
            checkpoint_estimate_scope_paths=$(_v2_read_scope_triage_state_lines "$scope_triage_state_file" "estimate_scope_paths" 2>/dev/null || true)
            if [[ -z "$checkpoint_estimate_scope_paths" ]]; then
                checkpoint_estimate_scope_paths="$checkpoint_scope_paths"
            fi
            if [[ -n "$checkpoint_scope_source" || -n "$checkpoint_estimate_scope_paths" ]]; then
                _v2_refresh_traditional_dev_proxy_artifacts \
                    "$task_file" \
                    "$checkpoint_before_sha" \
                    "$baseline_diff" \
                    "$checkpoint_estimate_scope_paths" \
                    "$checkpoint_scope_source" \
                    "$checkpoint_preexisting_dirty" \
                    0
            else
                persist_v2_traditional_dev_proxy_json "$task_file" 0 >/dev/null 2>&1 || true
            fi
            _append_manifest_phase "phase-4" "execute" "$_phase_start" "$(_iso_timestamp)" "skipped" || true
            ;;
        *)
            echo -e "${GREEN}Phase 4: Skipped (legacy checkpoint — execution-diff.patch exists)${NC}"
            log_execution "$task_file" "Phase 4: Skipped (legacy checkpoint)"
            persist_v2_traditional_dev_proxy_json "$task_file" 0 >/dev/null 2>&1 || true
            _append_manifest_phase "phase-4" "execute" "$_phase_start" "$(_iso_timestamp)" "skipped" || true
            ;;
    esac

    return 0
}

_v2_run_scope_triage() {
    local task_file="$1" phase_label="$2" comp_dir="$3" before_sha="$4" plan_file="$5" diff_file="$6" preexisting_dirty="${7:-}" fix_cycles="${8:-0}"
    local state_file="" raw_output_file="" task_file_rel="" scope_source="" scope_paths="" triage_candidates=""
    local supplemental_untracked="" triage_output_path="" triage_instruction="" triage_records="" failure_reason=""
    local classifications="" actions="" plan_gap_paths="" estimate_plan_gap_paths="" suppressed_noise_paths="" result="completed"
    local estimate_scope_paths="" raw_classification=""
    local triage_count=0 plan_gap_count=0 noise_count=0
    local record="" path="" classification="" reasoning="" action_detail="" quarantine_path=""
    local start_ts=""

    state_file=$(_v2_scope_triage_state_path "$comp_dir")
    raw_output_file=$(_v2_scope_triage_raw_output_path "$comp_dir")
    task_file_rel=$(_v2_repo_relative_path "$task_file")
    rm -f "$raw_output_file"
    scope_source="${_V2_LAST_CAPTURE_SCOPE_SOURCE:-}"
    scope_paths="${_V2_LAST_CAPTURE_SCOPE_PATHS:-}"
    _V2_LAST_ESTIMATE_SCOPE_PATHS=""
    supplemental_untracked=$(_v2_collect_out_of_scope_untracked_paths_for_triage "$scope_paths" "$scope_source" "$preexisting_dirty")
    triage_candidates=$(printf '%s\n%s\n' "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" "$supplemental_untracked" | _v2_unique_nonblank_lines)
    _V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES="$triage_candidates"
    _v2_write_scope_triage_state "$state_file" "pending" "$before_sha" "$plan_file" "$diff_file" "$preexisting_dirty" "$raw_output_file" || true

    if [[ -z "$triage_candidates" ]]; then
        _V2_LAST_ESTIMATE_SCOPE_PATHS="$scope_paths"
        log_execution "$task_file" "${phase_label}: Scope triage skipped (no out-of-scope files)" || true
        _v2_write_scope_triage_state "$state_file" "skipped" "$before_sha" "$plan_file" "$diff_file" "$preexisting_dirty" "$raw_output_file" || true
        _v2_refresh_traditional_dev_proxy_artifacts \
            "$task_file" \
            "$before_sha" \
            "$diff_file" \
            "$scope_paths" \
            "$scope_source" \
            "$preexisting_dirty" \
            "$fix_cycles"
        return 0
    fi

    triage_count=$(printf '%s\n' "$triage_candidates" | awk 'NF { count++ } END { print count + 0 }')
    start_ts=$(_iso_timestamp)
    log_execution "$task_file" "${phase_label}: Scope triage started (${triage_count} file(s))" || true

    if [[ "$triage_count" -gt "$_V2_SCOPE_TRIAGE_MAX_AGENT_CANDIDATES" ]]; then
        failure_reason="Scope triage skipped agent call because candidate volume exceeded ${_V2_SCOPE_TRIAGE_MAX_AGENT_CANDIDATES} files"
        echo -e "${YELLOW}WARN: ${phase_label} scope triage skipped agent call because candidate volume exceeded ${_V2_SCOPE_TRIAGE_MAX_AGENT_CANDIDATES} files${NC}"
        log_execution "$task_file" "${phase_label}: WARNING scope triage skipped agent call because candidate volume exceeded ${_V2_SCOPE_TRIAGE_MAX_AGENT_CANDIDATES} files" || true
    else
        local _requested_scope_triage_engine="$ENGINE_EVALUATOR"
        local _effective_scope_triage_engine="$ENGINE_EVALUATOR"
        _resolve_effective_engine "$_requested_scope_triage_engine"
        _effective_scope_triage_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_scope_triage_engine" "$_effective_scope_triage_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "scope-triage"
            _v2_append_codex_circuit_breaker_skip "phase-4" "scope-triage" "$start_ts" "scope-triage"
        fi
        triage_output_path="$raw_output_file"
        if [[ "$_effective_scope_triage_engine" == "codex" ]]; then
            triage_output_path="$CODEX_ARTIFACT_PATH_PLACEHOLDER"
        fi
        triage_instruction=$(_v2_build_scope_triage_instruction "$task_file" "$plan_file" "$triage_output_path" "$scope_paths" "$triage_candidates" "$before_sha")

        if ! prepare_agent_request "$_effective_scope_triage_engine" "$scope_triage_prompt" "$triage_instruction"; then
            failure_reason="Failed to assemble scope triage prompt"
        else
            local exit_triage=0
            touch "${log_dir}/scope-triage.log"
            run_agent "scope-triage" "$_effective_scope_triage_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
                "$raw_output_file" "${log_dir}/scope-triage.log" "$EVALUATE_TIMEOUT" "100" "Bash,WebFetch,WebSearch" || exit_triage=$?
            if [[ "$_effective_scope_triage_engine" == "codex" ]]; then
                _v2_record_codex_outcome "$_effective_scope_triage_engine" "$exit_triage"
            fi
            if [[ "$exit_triage" -ne 0 ]]; then
                if [[ "$exit_triage" -eq 124 ]]; then
                    failure_reason="Scope triage timed out (${EVALUATE_TIMEOUT})"
                else
                    failure_reason="Scope triage failed (exit ${exit_triage})"
                fi
            fi
        fi
    fi

    if [[ -z "$failure_reason" ]]; then
        triage_records=$(_v2_scope_triage_entries_as_tsv "$raw_output_file") || failure_reason="Scope triage returned unparseable JSON"
    fi
    if [[ -z "$failure_reason" ]] && ! _v2_scope_triage_records_cover_candidates "$triage_candidates" "$triage_records"; then
        failure_reason="Scope triage output did not classify the expected file set"
    fi

    if [[ -n "$failure_reason" ]]; then
        result="failed-open"
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            if [[ "$path" == "$task_file_rel" ]] || _v2_is_pipeline_owned_phase4_noise "$path"; then
                classifications+="${path}"$'\t'"NOISE"$'\t'"Pipeline-owned task artifact; excluded from executor scope review."$'\n'
                actions+="${path}"$'\t'"suppressed"$'\t'"Kept pipeline artifact in place during fail-open"$'\n'
                suppressed_noise_paths+="${path}"$'\n'
                noise_count=$((noise_count + 1))
            else
                classifications+="${path}"$'\t'"PLAN_GAP"$'\t'"${failure_reason}. Kept by default."$'\n'
                actions+="${path}"$'\t'"kept"$'\t'"Fail-open default to PLAN_GAP"$'\n'
                plan_gap_paths+="${path}"$'\n'
                estimate_plan_gap_paths+="${path}"$'\n'
                plan_gap_count=$((plan_gap_count + 1))
            fi
        done <<< "$triage_candidates"
        log_execution "$task_file" "${phase_label}: Scope triage failed open (${failure_reason})" || true
    else
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            record=$(printf '%s\n' "$triage_records" | awk -F'\t' -v target="$path" '$1 == target { print; exit }')
            classification=$(printf '%s\n' "$record" | awk -F'\t' '{ print $2 }')
            reasoning=$(printf '%s\n' "$record" | awk -F'\t' '{ print $3 }')
            action_detail=""
            raw_classification="$classification"

            if [[ "$path" == "$task_file_rel" ]] || _v2_is_pipeline_owned_phase4_noise "$path"; then
                classification="NOISE"
                reasoning="Pipeline-owned task artifact; excluded from executor scope review."
                action_detail="suppressed: kept pipeline artifact in place"
                suppressed_noise_paths+="${path}"$'\n'
                noise_count=$((noise_count + 1))
            elif [[ "$raw_classification" == "NOISE" ]]; then
                if _v2_is_untracked_path "$path"; then
                    quarantine_path=$(_v2_quarantine_untracked_noise_path "$comp_dir" "$path") || quarantine_path=""
                    if [[ -n "$quarantine_path" ]]; then
                        action_detail="quarantined: ${quarantine_path}"
                        noise_count=$((noise_count + 1))
                    else
                        classification="PLAN_GAP"
                        reasoning="Failed to quarantine untracked noise safely; kept by default."
                    fi
                elif [[ -n "$before_sha" ]] && _v2_path_changed_in_commit_range "$before_sha" "$path"; then
                    classification="PLAN_GAP"
                    reasoning="Committed change cannot be auto-reverted safely without rewriting history; kept by default."
                elif _v2_restore_tracked_noise_path "$path"; then
                    action_detail="reverted: restored path to HEAD"
                    noise_count=$((noise_count + 1))
                else
                    classification="PLAN_GAP"
                    reasoning="Failed to revert tracked noise safely; kept by default."
                fi
            elif [[ "$raw_classification" == "PLAN_GAP" ]]; then
                estimate_plan_gap_paths+="${path}"$'\n'
            fi

            if [[ "$classification" == "PLAN_GAP" ]]; then
                plan_gap_paths+="${path}"$'\n'
                plan_gap_count=$((plan_gap_count + 1))
                [[ -n "$action_detail" ]] || action_detail="kept: added to effective scope"
            fi

            classifications+="${path}"$'\t'"${classification}"$'\t'"${reasoning}"$'\n'
            actions+="${path}"$'\t'"${action_detail%%:*}"$'\t'"${action_detail#*: }"$'\n'
        done <<< "$triage_candidates"

        log_execution "$task_file" "${phase_label}: Scope triage completed (PLAN_GAP=${plan_gap_count}, NOISE=${noise_count})" || true
    fi

    estimate_scope_paths=$(printf '%s\n%s\n' "$scope_paths" "$estimate_plan_gap_paths" | _v2_unique_nonblank_lines)
    _V2_LAST_ESTIMATE_SCOPE_PATHS="$estimate_scope_paths"

    capture_diff_artifact \
        "$before_sha" \
        "$diff_file" \
        "$task_file" \
        "$plan_file" \
        "$preexisting_dirty" \
        "$(printf '%s\n%s\n' "$scope_paths" "$plan_gap_paths" | _v2_unique_nonblank_lines)" \
        "$scope_source"

    if [[ -n "$suppressed_noise_paths" ]]; then
        _V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES=$(_v2_filter_out_paths_from_list "${_V2_LAST_CAPTURE_OUT_OF_SCOPE_FILES:-}" "$suppressed_noise_paths")
    fi

    if [[ ! -s "$diff_file" ]]; then
        echo -e "${YELLOW}WARN: ${phase_label} scope triage left an empty execution diff: ${diff_file}${NC}"
        log_execution "$task_file" "${phase_label}: Scope triage left the execution diff empty" || true
    else
        log_execution "$task_file" "${phase_label}: Scope triage regenerated execution diff at ${diff_file}" || true
    fi

    _v2_refresh_traditional_dev_proxy_artifacts \
        "$task_file" \
        "$before_sha" \
        "$diff_file" \
        "$estimate_scope_paths" \
        "$scope_source" \
        "$preexisting_dirty" \
        "$fix_cycles"

    _v2_append_scope_triage_log_entry "$task_file" "$phase_label" "$result" "$classifications" "$actions" "$failure_reason" || true
    # NOTE: execution-scope-triage.raw.json preserves the agent's unmodified output.
    # This canonical artifact reflects shell-side overrides (task file forced to NOISE,
    # pipeline-owned files forced to NOISE). The two files may disagree on
    # individual classifications; this file is authoritative.
    _v2_write_scope_triage_state "$state_file" "$result" "$before_sha" "$plan_file" "$diff_file" "$preexisting_dirty" "$raw_output_file" "$failure_reason" "$classifications" "$actions" || true
    return 0
}

_v2_select_phase7_scope_plan_file() {
    local comp_dir="$1"
    local fix_plan="${comp_dir}/fix-plan.md"
    local revised_plan="${comp_dir}/revised-plan.md"

    if [[ -f "$fix_plan" ]] && [[ -n "$(_extract_xml_task_paths "$fix_plan" | _reject_slug_internal_paths "$SLUG")" ]]; then
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
    _PIPELINE_START_TS=$(date +%s)
    _apply_effective_strict_mode "$slug" "$goal"

    # Directory setup
    local default_task_dir="$(_v2_task_artifact_dir "$slug")"
    local task_dir="$default_task_dir"
    local comp_dir=""
    local TASK_LOG_DIR=""
    local log_dir=""
    local task_file=""
    local blinding_message=""
    local _FAIL_PHASE_PHASE_ID=""
    local _FAIL_PHASE_PHASE_NAME=""
    local _FAIL_PHASE_PHASE_STARTED_AT=""
    local resolve_rc=0
    task_file="$(_resolve_v2_task_file "$slug")" || resolve_rc=$?
    case "$resolve_rc" in
        0) ;;
        1) task_file="${task_dir}/task.md" ;;
        2) exit 1 ;;
        *) exit "$resolve_rc" ;;
    esac
    if [[ -f "$task_file" ]]; then
        task_dir=$(_v2_task_dir_for_task_file "$task_file") || task_dir="$default_task_dir"
    fi
    comp_dir="${task_dir}/competitive"
    TASK_LOG_DIR="${task_dir}/logs"
    log_dir="$TASK_LOG_DIR"
    mkdir -p "$comp_dir" "$TASK_LOG_DIR"

    # Consolidate flat/pilot task files into directory layout
    if [[ -f "$task_file" && "$task_file" != "${task_dir}/"* ]] && ! _v2_should_preserve_flat_task_file "$task_file"; then
        _consolidate_task_to_dir "$task_file" "$task_dir"
        task_file="${task_dir}/task.md"
    fi

    _CURRENT_TASK_FILE="$task_file"
    _CURRENT_TASK_LOG_DIR="$TASK_LOG_DIR"
    _v2_reset_codex_auth_preflight_state
    _clear_active_runtime_state
    if [[ "$FORCE_RERUN" == "true" ]]; then
        _backup_artifacts_on_force "$comp_dir"
        _clear_force_artifacts "$comp_dir" "$TASK_LOG_DIR"
    fi
    [[ ! -f "${comp_dir}/run-manifest.json" ]] && _init_run_manifest || true
    _ensure_cost_csv_header "${TASK_LOG_DIR}/cost.csv"
    _merge_cost_csvs || true
    _PIPELINE_PRE_SHA=$(git rev-parse HEAD 2>/dev/null || true)

    # Task file creation (if not resuming)
    if [[ ! -f "$task_file" ]]; then
        _write_v2_task_file "$task_file" "$slug" "$goal" || {
            echo -e "${RED}Failed to create task file: ${task_file}${NC}"
            exit 1
        }
        echo -e "${GREEN}Created task file: ${task_file}${NC}"
    fi

    ensure_sections "$task_file"

    local current_status=""
    current_status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    if [[ "$current_status" == "needs verification" && "$FORCE_RERUN" != "true" ]]; then
        echo -e "${YELLOW}Task is already in needs verification: ${task_file}${NC}"
        echo -e "${YELLOW}Skipping competitive execution. Use verify/closeout flow instead of reseeding a new plan.${NC}"
        log_execution "$task_file" "Competitive launch skipped: canonical task already in needs verification; preserve verification state instead of reseeding plan work"
        _update_run_manifest_state "phase-0" || true
        _append_manifest_phase "phase-0" "preflight" "$(_iso_timestamp)" "$(_iso_timestamp)" "skipped" "needs verification" || true
        _finalize_run_manifest "needs verification" 0 || true
        return 0
    fi

    if _should_enforce_task_file_content_gate "$DRY_RUN" "false" "${_LAUREN_LOOP_RESUME_HINT:-0}"; then
        _validate_task_file_content "$task_file" || return 1
    fi

    if ! _preflight_dependency_check "$task_file" "$FORCE_RERUN"; then
        log_execution "$task_file" "Preflight: dependency check failed — aborting"
        return 1
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
    local scope_triage_prompt="$SCRIPT_DIR/prompts/scope-triage.md"
    # Reviewer A reuses the v1 reviewer prompt (no -a suffix — intentional)
    local reviewer_a_prompt="$SCRIPT_DIR/prompts/reviewer.md"
    # Reviewer B has its own prompt; naming asymmetry with reviewer.md is intentional (v1 reuse)
    local reviewer_b_prompt="$SCRIPT_DIR/prompts/reviewer-b.md"
    local review_evaluator_prompt="$SCRIPT_DIR/prompts/review-evaluator.md"
    local fix_plan_author_prompt="$SCRIPT_DIR/prompts/fix-plan-author.md"
    local fix_executor_prompt="$SCRIPT_DIR/prompts/fix-executor.md"
    local final_verify_prompt="$SCRIPT_DIR/prompts/final-verifier.md"
    local final_falsify_prompt="$SCRIPT_DIR/prompts/final-falsifier.md"
    local final_fix_prompt="$SCRIPT_DIR/prompts/final-fixer.md"

    # Prompt file gate — fail fast before any phase runs
    local missing=0
    for pf in "$explore_prompt" "$planner_a_prompt" "$planner_b_prompt" \
              "$evaluator_prompt" "$critic_prompt" "$reviser_prompt" \
              "$executor_prompt" "$scope_triage_prompt" "$reviewer_a_prompt" "$reviewer_b_prompt" \
              "$review_evaluator_prompt" "$fix_plan_author_prompt" "$fix_executor_prompt" \
              "$final_verify_prompt" "$final_falsify_prompt" "$final_fix_prompt"; do
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
        local synthesis_file="${comp_dir}/review-synthesis.md"
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
            if [[ -f "$synthesis_file" ]]; then
                for section in "## Critical Findings" "## Major Findings" "## Minor Findings" "## Nit Findings"; do
                    body=$(section_body "$synthesis_file" "$section" 2>/dev/null || true)
                    body=$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d')
                    if [[ -n "$body" && "$body" != "None." ]]; then
                        echo
                        echo "$section"
                        printf '%s\n' "$body"
                        wrote_findings=true
                    fi
                done
            fi

            if [[ ! -f "$synthesis_file" ]]; then
                echo
                echo "review-synthesis.md is missing, so unresolved findings could not be extracted."
            elif [[ "$wrote_findings" == false ]]; then
                echo
                echo "No unresolved findings were extracted from review-synthesis.md."
            fi

            echo
            echo "## Human Reviewer Focus"
            if [[ -f "$synthesis_file" ]]; then
                echo "- Review ${synthesis_file} for the final synthesized findings and verdict."
            else
                echo "- review-synthesis.md was not produced for this halt; use the reviewer logs and raw review artifacts instead."
            fi
            echo "- Review ${comp_dir}/fix-plan.md and ${comp_dir}/fix-execution.md to see what the last automated fix cycle attempted."
            echo "- Review ${latest_fix_diff:-${comp_dir}/execution-diff.patch} for the latest code changes under review."
            echo "- Confirm whether the remaining findings are valid fixes, false positives, or need a narrower follow-up task."
        } > "$tmp_file"

        mv "$tmp_file" "$handoff_file"
    }

    _write_phase8_human_review_handoff() {
        local phase8_halt_subphase="$1"
        local handoff_file="${comp_dir}/human-review-handoff.md"
        local final_verify_file="${comp_dir}/final-verify.md"
        local final_falsify_file="${comp_dir}/final-falsify.md"
        local final_fix_file="${comp_dir}/final-fix.md"
        local final_verify_initial_file="${comp_dir}/final-verify.initial.md"
        local final_falsify_initial_file="${comp_dir}/final-falsify.initial.md"
        local final_verify_contract="${comp_dir}/final-verify.contract.json"
        local final_falsify_contract="${comp_dir}/final-falsify.contract.json"
        local final_fix_contract="${comp_dir}/final-fix.contract.json"
        local final_verify_initial_contract="${comp_dir}/final-verify.initial.contract.json"
        local final_falsify_initial_contract="${comp_dir}/final-falsify.initial.contract.json"
        local final_verify_verdict=""
        local final_falsify_verdict=""
        local final_fix_status=""
        local final_verify_initial_verdict=""
        local final_falsify_initial_verdict=""
        local tmp_file
        final_verify_verdict=$(_parse_contract "$final_verify_file" "verdict")
        final_falsify_verdict=$(_parse_contract "$final_falsify_file" "verdict")
        final_fix_status=$(_parse_contract "$final_fix_file" "status")
        final_verify_initial_verdict=$(_parse_contract "$final_verify_initial_file" "verdict")
        final_falsify_initial_verdict=$(_parse_contract "$final_falsify_initial_file" "verdict")
        tmp_file=$(mktemp "${TMPDIR:-/tmp}/human-review-handoff.XXXXXX")

        {
            echo "# Human Review Handoff"
            echo
            echo "**Task:** ${task_file}"
            echo "**Phase 8 halt sub-phase:** ${phase8_halt_subphase}"
            echo "**Final verify verdict:** ${final_verify_verdict:-not available}"
            echo "**Final falsify verdict:** ${final_falsify_verdict:-not available}"
            echo "**Final fix status:** ${final_fix_status:-not available}"
            echo
            echo "## Phase 8 Halt Reason"
            echo "- Halted in ${phase8_halt_subphase}."
            echo "- final-verify verdict: ${final_verify_verdict:-not available}"
            echo "- final-falsify verdict: ${final_falsify_verdict:-not available}"
            echo "- final-fix status: ${final_fix_status:-not available}"
            echo
            echo "## Original Findings"
            echo "- final-verify.initial: ${final_verify_initial_file} (contract: ${final_verify_initial_contract}; verdict: ${final_verify_initial_verdict:-not available})"
            echo "- final-falsify.initial: ${final_falsify_initial_file} (contract: ${final_falsify_initial_contract}; verdict: ${final_falsify_initial_verdict:-not available})"
            echo
            echo "## Post-fix Results"
            echo "- final-verify: ${final_verify_file} (contract: ${final_verify_contract}; verdict: ${final_verify_verdict:-not available})"
            echo "- final-falsify: ${final_falsify_file} (contract: ${final_falsify_contract}; verdict: ${final_falsify_verdict:-not available})"
            echo "- final-fix: ${final_fix_file} (contract: ${final_fix_contract}; status: ${final_fix_status:-not available})"
            echo
            echo "## Human Reviewer Focus"
            echo "- Compare the original findings snapshots against the canonical Phase 8 artifacts to confirm what changed after the automated fix."
            echo "- Use ${final_verify_contract}, ${final_falsify_contract}, and ${final_fix_contract} to confirm the parsed Phase 8 verdicts/status."
            echo "- Inspect ${final_verify_file}, ${final_falsify_file}, and ${final_fix_file} for the full verifier, falsifier, and fixer narratives."
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

    _append_review_blinding_metadata() {
        local reviewer_a_engine="$1"
        local reviewer_b_engine="$2"

        blinding_message="Phase 5: Review mapping: $(cat "${comp_dir}/.review-mapping" 2>/dev/null || echo 'missing')"
        _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
        blinding_message="Review engine mapping: reviewer-a=${reviewer_a_engine}, reviewer-b=${reviewer_b_engine}"
        _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
    }

    _describe_artifact_state() {
        local artifact_path="$1"

        if [[ -f "$artifact_path" ]]; then
            if [[ -s "$artifact_path" ]]; then
                printf 'exists (%s bytes)\n' "$(wc -c < "$artifact_path" | tr -d ' ')"
            else
                printf 'exists (empty)\n'
            fi
        else
            printf 'missing\n'
        fi
    }

    _log_phase_artifact_diagnostics() {
        local phase_label="$1"
        local artifact_path="$2"
        local artifact_label="$3"
        local artifact_log="${4:-}"
        local validation_err="${5:-}"
        local artifact_state=""
        local normalized_validation=""

        artifact_state=$(_describe_artifact_state "$artifact_path")
        log_execution "$task_file" "${phase_label}: ${artifact_label} path: ${artifact_path}" || true
        log_execution "$task_file" "${phase_label}: ${artifact_label} state: ${artifact_state}" || true

        normalized_validation="${validation_err//$'\n'/ | }"
        if [[ -n "$normalized_validation" ]]; then
            log_execution "$task_file" "${phase_label}: ${artifact_label} validation failure: ${normalized_validation}" || true
        fi

        if [[ -f "$artifact_log" ]] && [[ -s "$artifact_log" ]]; then
            local artifact_log_tail=""
            artifact_log_tail=$(tail -20 "$artifact_log" 2>/dev/null || true)
            if [[ -n "$artifact_log_tail" ]]; then
                log_execution "$task_file" "${phase_label}: Agent log tail (last 20 lines):" || true
                _log_diagnostic_lines "$task_file" "$artifact_log_tail"
            fi
        fi
    }

    _capture_reviewer_a_raw_artifact() {
        local source_task_file="$1"
        local output_file="$2"

        rm -f "$output_file"
        if ! extract_markdown_section_to_file "$source_task_file" "## Review Findings" "$output_file"; then
            printf "WARN: reviewer-a raw artifact extraction failed: missing or empty '## Review Findings' section in %s\n" "$source_task_file" >&2
            return 1
        fi

        clear_markdown_section "$source_task_file" "## Review Findings"
        _validate_agent_output_for_role "reviewer-a" "$output_file"
    }

    _review_phase_codex_retry_already_attempted() {
        local role_log="$1"
        [[ -f "$role_log" ]] || return 1
        grep -Eqi 'WARN: Codex (capacity|stream) failure .*retrying' "$role_log"
    }

    _fail_phase() {
        local phase_status="$1" error_message="$2" recovery_hint="${3:-}" error_class="${4:-unknown}" error_detail="${5:-}"
        local task_log_dir="${TASK_LOG_DIR:-${_CURRENT_TASK_LOG_DIR:-}}"
        local cost_csv="" phase_cost="0.00" measured_phase_cost=""
        local manifest_phase="${_FAIL_PHASE_PHASE_ID:-}"
        local manifest_name="${_FAIL_PHASE_PHASE_NAME:-}"
        local manifest_started_at="${_FAIL_PHASE_PHASE_STARTED_AT:-}"
        local completed_at=""
        [[ -n "$error_class" ]] || error_class="unknown"
        echo -e "${RED}${error_message}${NC}"
        if [[ -n "$recovery_hint" ]]; then
            echo -e "${YELLOW}  Hint: ${recovery_hint}${NC}"
        fi
        if [[ -n "$task_log_dir" ]]; then
            [[ -n "${TASK_LOG_DIR:-}" ]] || TASK_LOG_DIR="$task_log_dir"
            _merge_cost_csvs || true
            cost_csv="${task_log_dir}/cost.csv"
            if [[ -f "$cost_csv" ]]; then
                measured_phase_cost=$(
                    awk -F',' '
                        NR > 1 && $11 ~ /^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*$/ {
                            sum += $11 + 0
                            found = 1
                        }
                        END {
                            if (found) {
                                printf "%.4f", sum + 0
                            }
                        }
                    ' "$cost_csv" 2>/dev/null || true
                )
                if [[ -n "$measured_phase_cost" ]]; then
                    phase_cost="$measured_phase_cost"
                fi
            fi
        fi
        completed_at=$(_iso_timestamp)
        [[ -n "$manifest_started_at" ]] || manifest_started_at="$completed_at"
        _append_manifest_phase \
            "$manifest_phase" \
            "$manifest_name" \
            "$manifest_started_at" \
            "$completed_at" \
            "failed" \
            "" \
            "$phase_cost" \
            "$error_class" \
            "$error_detail" \
            "$(if [[ "$_V2_LAST_MERGE_RECOVERABLE" == true ]]; then _v2_recovery_manifest_json; else printf 'null\n'; fi)" || true
        set_task_status "$task_file" "blocked"
        log_execution "$task_file" "Pipeline FAILED while ${phase_status}: ${error_message}"
        if [[ -n "$recovery_hint" ]]; then
            log_execution "$task_file" "  recovery hint: ${recovery_hint}"
        fi
        if [[ "$_V2_LAST_MERGE_RECOVERABLE" == true ]]; then
            _v2_log_recovery_details "$task_file"
        fi
        _finalize_run_manifest "blocked" "${fix_cycle:-0}" || true
        finalize_v2_task_metadata "$task_file" "$phase_status" "blocked" "${fix_cycle:-0}" || true
        return 1
    }

    _artifact_is_valid() {
        local artifact="$1"
        _validate_agent_output "$artifact" >/dev/null 2>&1
    }

    _require_valid_artifact() {
        local artifact="$1" phase_status="$2" error_message="$3" recovery_hint="${4:-}"
        local diagnostics_label="${5:-}" diagnostics_log="${6:-}" artifact_label="${7:-Artifact}" error_class="${8:-invalid_artifact}"
        local validation_err=""
        local error_detail=""
        if validation_err=$(_validate_agent_output "$artifact" 2>&1 1>/dev/null); then
            return 0
        fi
        if [[ -n "$diagnostics_label" ]]; then
            _log_phase_artifact_diagnostics "$diagnostics_label" "$artifact" "$artifact_label" "$diagnostics_log" "$validation_err"
        fi
        error_detail="artifact=${artifact}; label=${artifact_label}"
        if [[ -n "$validation_err" ]]; then
            error_detail="${error_detail}; validation=${validation_err}"
        fi
        _fail_phase "$phase_status" "$error_message" "$recovery_hint" "$error_class" "$error_detail"
        return 1
    }

    _clear_resume_checkpoint() {
        local target="$1" reason="$2"
        echo -e "${YELLOW}WARN: Resume checkpoint invalid for ${target} (${reason}); restarting from Phase 5.${NC}"
        log_execution "$task_file" "WARN: Resume checkpoint invalid for ${target} (${reason}); restarting from Phase 5"
        _resume_to_subphase=""
    }

    _phase8_contract_artifact_ready() {
        local artifact="$1" field="$2"
        local contract="${artifact%.*}.contract.json"
        local parsed=""
        [[ -f "$contract" ]] || return 1
        parsed=$(_parse_contract "$artifact" "$field")
        [[ -n "$parsed" ]]
    }

    _phase8c_route_label() {
        case "$1" in
            phase-8a) printf '%s\n' "phase-8a initial FAIL -> phase-8c" ;;
            phase-8b) printf '%s\n' "phase-8b initial FAIL -> phase-8c" ;;
            *) return 1 ;;
        esac
    }

    _phase8c_route_requires_falsify() {
        [[ "$1" == "phase-8b" ]]
    }

    _phase8c_route_required_inputs() {
        local comp_dir="$1" predecessor="$2"
        printf '%s\n' "${comp_dir}/final-verify.md"
        printf '%s\n' "${comp_dir}/final-verify.contract.json"
        if _phase8c_route_requires_falsify "$predecessor"; then
            printf '%s\n' "${comp_dir}/final-falsify.md"
            printf '%s\n' "${comp_dir}/final-falsify.contract.json"
        fi
    }

    _phase8c_route_first_missing_input() {
        local comp_dir="$1" predecessor="$2"
        local required_input=""
        while IFS= read -r required_input; do
            [[ -n "$required_input" ]] || continue
            if [[ ! -f "$required_input" ]]; then
                printf '%s\n' "$required_input"
                return 0
            fi
        done < <(_phase8c_route_required_inputs "$comp_dir" "$predecessor")
        return 1
    }

    _phase8c_final_fix_input_instruction() {
        local verify_rel="$1" verify_contract_rel="$2" predecessor="$3"
        local falsify_rel="${4:-}" falsify_contract_rel="${5:-}"
        if _phase8c_route_requires_falsify "$predecessor"; then
            printf '%s\n' "Read ${verify_rel}, ${verify_contract_rel}, ${falsify_rel}, and ${falsify_contract_rel}."
        else
            printf '%s\n' "Read ${verify_rel} and ${verify_contract_rel}. Do not require competitive/final-falsify.md or competitive/final-falsify.contract.json on this route."
        fi
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
            phase-8a)
                return 0
                ;;
            phase-8b)
                if _phase8_contract_artifact_ready "${comp_dir}/final-verify.md" "verdict"; then
                    return 0
                fi
                _clear_resume_checkpoint "$target" "missing parseable final-verify.contract.json"
                return 1
                ;;
            phase-8c)
                case "$CYCLE_STATE_LAST_COMPLETED" in
                    phase-8a)
                        if _phase8_contract_artifact_ready "${comp_dir}/final-verify.md" "verdict"; then
                            return 0
                        fi
                        _clear_resume_checkpoint "$target" "missing parseable final-verify.contract.json for phase-8a/${CYCLE_STATE_PHASE8_RESULT:-unknown}"
                        return 1
                        ;;
                    phase-8b)
                        if _phase8_contract_artifact_ready "${comp_dir}/final-falsify.md" "verdict"; then
                            return 0
                        fi
                        _clear_resume_checkpoint "$target" "missing parseable final-falsify.contract.json for phase-8b/${CYCLE_STATE_PHASE8_RESULT:-unknown}"
                        return 1
                        ;;
                    phase-8c)
                        if _phase8_contract_artifact_ready "${comp_dir}/final-fix.md" "status"; then
                            return 0
                        fi
                        _clear_resume_checkpoint "$target" "missing parseable final-fix.contract.json for phase-8c/${CYCLE_STATE_PHASE8_RESULT:-unknown}"
                        return 1
                        ;;
                esac
                _clear_resume_checkpoint "$target" "unexpected phase-8c resume predecessor: ${CYCLE_STATE_LAST_COMPLETED:-unknown}"
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
    _FAIL_PHASE_PHASE_ID="phase-1"
    _FAIL_PHASE_PHASE_NAME="explore"
    _FAIL_PHASE_PHASE_STARTED_AT="$_phase_start"
    _update_run_manifest_state "phase-1" || true
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
        # TODO: refine error_class if prompt assembly failures split into stable categories.
        local _requested_explore_engine="$ENGINE_EXPLORE"
        local _effective_explore_engine="$ENGINE_EXPLORE"
        _resolve_effective_engine "$_requested_explore_engine"
        _effective_explore_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_explore_engine" "$_effective_explore_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "explorer"
            _v2_append_codex_circuit_breaker_skip "phase-1" "explorer" "$_phase_start" "explorer"
        fi

        prepare_agent_request "$_effective_explore_engine" "$explore_prompt" "$explore_instruction" || {
            _fail_phase "exploring" "Failed to assemble explorer prompt" "Check agent log at ${log_dir}/explorer.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "unknown" "role=explorer; step=prepare_agent_request"
        }
        local explore_prompt_body="$AGENT_PROMPT_BODY"
        local explore_sysprompt="$AGENT_SYSTEM_PROMPT"

        local exit_explore=0
        run_agent "explorer" "$_effective_explore_engine" "$explore_prompt_body" "$explore_sysprompt" \
            "${comp_dir}/exploration-summary.md" "${log_dir}/explorer.log" \
            "$EXPLORE_TIMEOUT" "200" "WebFetch,WebSearch" || exit_explore=$?
        if [[ "$_effective_explore_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_explore_engine" "$exit_explore"
        fi

        if [[ "$exit_explore" -ne 0 ]]; then
            local explore_error_class=""
            local explore_error_message=""
            explore_error_class=$(_classify_agent_exit_error_class "$_effective_explore_engine" "$exit_explore" "${log_dir}/explorer.log")
            if [[ "$exit_explore" -eq 124 ]]; then
                explore_error_message="Phase 1: Explore timed out (${EXPLORE_TIMEOUT})"
            else
                explore_error_message="Phase 1: Explore FAILED (exit $exit_explore)"
            fi
            _fail_phase \
                "exploring" \
                "$explore_error_message" \
                "Check agent log at ${log_dir}/explorer.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "$explore_error_class" \
                "role=explorer; engine=${_effective_explore_engine}; exit_code=${exit_explore}; log=${log_dir}/explorer.log" || true
            _print_cost_summary
            return 1
        fi
        _require_valid_artifact \
            "${comp_dir}/exploration-summary.md" \
            "exploring" \
            "Phase 1 produced an invalid exploration summary" \
            "Check ${comp_dir}/exploration-summary.md and agent log ${log_dir}/explorer.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
            "Phase 1" \
            "${log_dir}/explorer.log" \
            "Exploration summary" || return 1
        log_execution "$task_file" "Phase 1: Explore completed"
        _append_manifest_phase "phase-1" "explore" "$_phase_start" "$(_iso_timestamp)" "completed" || true
    fi

    # ---- Phase 2: Parallel Planning ----
    local phase2_skipped=false
    local plan_a_valid=false
    local plan_b_valid=false
    echo -e "${BLUE}=== Phase 2: Parallel Planning ===${NC}"
    _phase_start=$(_iso_timestamp)
    _FAIL_PHASE_PHASE_ID="phase-2"
    _FAIL_PHASE_PHASE_NAME="planning"
    _FAIL_PHASE_PHASE_STARTED_AT="$_phase_start"
    _update_run_manifest_state "phase-2" || true
    if [[ "$FORCE_RERUN" != "true" ]] && { [[ -s "${comp_dir}/plan-a.md" ]] || [[ -s "${comp_dir}/plan-b.md" ]]; }; then
        phase2_skipped=true
        echo -e "${GREEN}Phase 2: Skipped (checkpoint — plan artifact(s) exist)${NC}"
        log_execution "$task_file" "Phase 2: Skipped (checkpoint)"
        _append_manifest_phase "phase-2" "planning" "$_phase_start" "$(_iso_timestamp)" "skipped" || true
    else
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 2: Planning started (parallel)"

        local plan_a_instruction="You are Planner A. Goal: ${goal}

Read the exploration summary at ${comp_dir}/exploration-summary.md and the task file at ${task_file}.
Write a detailed implementation plan to ${comp_dir}/plan-a.md."
        local plan_a_fallback_instruction="You are Planner A (Claude). Goal: ${goal}

Read the exploration summary at ${comp_dir}/exploration-summary.md and the task file at ${task_file}.
Write a detailed implementation plan to ${comp_dir}/plan-a.md."
        local _requested_planner_a_engine="$ENGINE_PLANNER_A"
        local _effective_planner_a_engine="$ENGINE_PLANNER_A"
        _resolve_effective_engine "$_requested_planner_a_engine"
        _effective_planner_a_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_planner_a_engine" "$_effective_planner_a_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "planner-a"
            _v2_append_codex_circuit_breaker_skip "phase-2" "planning-a" "$_phase_start" "planner-a"
        fi
        # TODO: refine error_class if planner prompt assembly failures split into stable categories.
        prepare_agent_request "$_effective_planner_a_engine" "$planner_a_prompt" "$plan_a_instruction" || {
            _fail_phase "planning" "Failed to assemble planner-a prompt" "Check agent log at ${log_dir}/planner-a.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "unknown" "role=planner-a; step=prepare_agent_request"
        }
        local plan_a_prompt_body="$AGENT_PROMPT_BODY"
        local plan_a_sysprompt="$AGENT_SYSTEM_PROMPT"

        local _requested_planner_b_engine="$ENGINE_PLANNER_B"
        local _effective_planner_b_engine="$ENGINE_PLANNER_B"
        _resolve_effective_engine "$_requested_planner_b_engine"
        _effective_planner_b_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_planner_b_engine" "$_effective_planner_b_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "planner-b"
            _v2_append_codex_circuit_breaker_skip "phase-2" "planning-b" "$_phase_start" "planner-b"
        fi
        local plan_b_output_path="${comp_dir}/plan-b.md"
        if [[ "$_effective_planner_b_engine" == "codex" ]]; then
            plan_b_output_path="$CODEX_ARTIFACT_PATH_PLACEHOLDER"
        fi
        local plan_b_instruction="Goal: ${goal}

Read the exploration summary at ${comp_dir}/exploration-summary.md and the task file at ${task_file}.
Write a detailed implementation plan to ${plan_b_output_path}."
        local plan_b_fallback_instruction="You are Planner B (Claude). Goal: ${goal}

Read the exploration summary at ${comp_dir}/exploration-summary.md and the task file at ${task_file}.
Write a detailed implementation plan to ${comp_dir}/plan-b.md."

        prepare_agent_request "$_effective_planner_b_engine" "$planner_b_prompt" "$plan_b_instruction" || {
            _fail_phase "planning" "Failed to assemble planner-b prompt" "Check agent log at ${log_dir}/planner-b.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "unknown" "role=planner-b; step=prepare_agent_request"
        }
        local plan_b_prompt_body="$AGENT_PROMPT_BODY"
        local plan_b_sysprompt="$AGENT_SYSTEM_PROMPT"

        echo -e "${BLUE}Spawning parallel: planner-a (${_effective_planner_a_engine}) + planner-b (${_effective_planner_b_engine})${NC}"

        local planner_a_start_ts=0 planner_b_start_ts=0
        local planner_a_duration=0
        local planner_b_backstopped=false

        planner_a_start_ts=$(date +%s)
        run_agent "planner-a" "$_effective_planner_a_engine" "$plan_a_prompt_body" "$plan_a_sysprompt" \
            "${comp_dir}/plan-a.md" "${log_dir}/planner-a.log" "$PLANNER_TIMEOUT" "100" &
        local pid_a=$!

        planner_b_start_ts=$(date +%s)
        run_agent "planner-b" "$_effective_planner_b_engine" "$plan_b_prompt_body" "$plan_b_sysprompt" \
            "${comp_dir}/plan-b.md" "${log_dir}/planner-b.log" "$PLANNER_TIMEOUT" "100" &
        local pid_b=$!

        local exit_a=0 exit_b=0
        wait $pid_a || exit_a=$?
        if [[ "$_effective_planner_a_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_planner_a_engine" "$exit_a"
        fi
        planner_a_duration=$(( $(date +%s) - planner_a_start_ts ))
        (( planner_a_duration < 0 )) && planner_a_duration=0
        if [[ "$_effective_planner_a_engine" == "claude" ]] && [[ "$_effective_planner_b_engine" == "codex" ]] && \
           _validate_agent_output_for_role "planner-a" "${comp_dir}/plan-a.md" >/dev/null 2>&1 && \
           kill -0 "$pid_b" 2>/dev/null; then
            if ! _enforce_codex_phase_backstop "$pid_b" "planner-b" "$planner_b_start_ts" "$PLANNER_TIMEOUT" "$planner_a_duration" "${log_dir}/planner-b.log" "${comp_dir}/plan-b.md"; then
                planner_b_backstopped=true
            fi
        fi
        wait $pid_b || exit_b=$?
        if [[ "$_effective_planner_b_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_planner_b_engine" "$exit_b"
        fi
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
                    "Check ${comp_dir}/plan-a.md and agent log ${log_dir}/planner-a.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                    "invalid_artifact" "role=planner-a; artifact=${comp_dir}/plan-a.md"
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
                    "Check ${comp_dir}/plan-b.md and agent log ${log_dir}/planner-b.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                    "invalid_artifact" "role=planner-b; artifact=${comp_dir}/plan-b.md"
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
                    "Check ${comp_dir}/plan-a.md and agent log ${log_dir}/planner-a.log, then regenerate Phase 2 with --force if needed: bash lauren-loop-v2.sh ${SLUG} '${goal}' --force" \
                    "checkpoint_corruption" "artifact=${comp_dir}/plan-a.md; source=checkpoint"
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
                    "Check ${comp_dir}/plan-b.md and agent log ${log_dir}/planner-b.log, then regenerate Phase 2 with --force if needed: bash lauren-loop-v2.sh ${SLUG} '${goal}' --force" \
                    "checkpoint_corruption" "artifact=${comp_dir}/plan-b.md; source=checkpoint"
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

        local fallback_validator_role="" fallback_run_role="" fallback_prompt_file="" fallback_instruction=""
        local fallback_output="" fallback_log="" fallback_prompt_body="" fallback_sysprompt=""
        if [[ "$plan_a_valid" != true ]]; then
            fallback_validator_role="planner-a"
            fallback_run_role="planner-a-claude-fallback"
            fallback_prompt_file="$planner_a_prompt"
            fallback_instruction="$plan_a_fallback_instruction"
            fallback_output="${comp_dir}/plan-a.md"
            fallback_log="${log_dir}/planner-a-claude-fallback.log"
        else
            fallback_validator_role="planner-b"
            fallback_run_role="planner-b-claude-fallback"
            fallback_prompt_file="$planner_b_prompt"
            fallback_instruction="$plan_b_fallback_instruction"
            fallback_output="${comp_dir}/plan-b.md"
            fallback_log="${log_dir}/planner-b-claude-fallback.log"
        fi

        echo -e "${YELLOW}One planner failed — falling back to Claude for ${fallback_validator_role} (competitive guarantee)${NC}"
        log_execution "$task_file" "Phase 2: ${fallback_validator_role} failed, launching Claude fallback with original persona"

        local fallback_exit=0
        local fallback_prepared=false
        local fallback_start_ts fallback_duration
        if prepare_agent_request "claude" "$fallback_prompt_file" "$fallback_instruction"; then
            fallback_prepared=true
            fallback_prompt_body="$AGENT_PROMPT_BODY"
            fallback_sysprompt="$AGENT_SYSTEM_PROMPT"
            fallback_start_ts=$(date +%s)
            # Fallback gets its own full PLANNER_TIMEOUT — not a remainder from the failed planner.
            run_agent "$fallback_run_role" "claude" "$fallback_prompt_body" "$fallback_sysprompt" \
                "$fallback_output" "$fallback_log" "$PLANNER_TIMEOUT" "100"; fallback_exit=$?
            fallback_duration=$(( $(date +%s) - fallback_start_ts ))
        else
            log_execution "$task_file" "Phase 2: Failed to assemble Claude fallback prompt for ${fallback_validator_role}"
        fi
        _merge_cost_csvs || true

        local fallback_validation_err=""
        local _fb_validation_ok=false
        if [[ "$fallback_prepared" == true ]] && [[ "$fallback_exit" -eq 0 ]]; then
            if fallback_validation_err=$(_validate_agent_output_for_role "$fallback_validator_role" "$fallback_output" 2>&1 1>/dev/null); then
                _fb_validation_ok=true
            fi
        fi
        if [[ "$_fb_validation_ok" == true ]]; then
            echo -e "${GREEN}Claude fallback for ${fallback_validator_role} succeeded — both plans available${NC}"
            log_execution "$task_file" "Phase 2: Claude fallback for ${fallback_validator_role} succeeded"
            if [[ "$fallback_validator_role" == "planner-a" ]]; then
                plan_a_valid=true
            else
                plan_b_valid=true
            fi
        else
            echo -e "${YELLOW}Claude fallback for ${fallback_validator_role} also failed — single plan, evaluator skipped${NC}"
            local _fb_output_state="missing"
            if [[ -f "$fallback_output" ]]; then
                if [[ -s "$fallback_output" ]]; then
                    _fb_output_state="exists ($(wc -c < "$fallback_output") bytes)"
                else
                    _fb_output_state="exists (empty)"
                fi
            fi
            log_execution "$task_file" "Phase 2: Claude fallback for ${fallback_validator_role} failed (prepared=${fallback_prepared}, exit=${fallback_exit}, duration=${fallback_duration:-?}s, output=${_fb_output_state})"
            if [[ -n "${fallback_validation_err:-}" ]]; then
                log_execution "$task_file" "Phase 2: Fallback validation failure: ${fallback_validation_err}"
            fi
            if [[ -f "$fallback_log" ]] && [[ -s "$fallback_log" ]]; then
                local _fb_log_tail
                _fb_log_tail=$(tail -20 "$fallback_log" 2>/dev/null || true)
                if [[ -n "$_fb_log_tail" ]]; then
                    log_execution "$task_file" "Phase 2: Fallback agent log tail (last 20 lines):"
                    _log_diagnostic_lines "$task_file" "$_fb_log_tail"
                fi
            fi
            if [[ ! -s "${comp_dir}/revised-plan.md" ]] || [[ "$FORCE_RERUN" == "true" ]]; then
                cp "$surviving_plan" "${comp_dir}/revised-plan.md"
                log_execution "$task_file" "Phase 2: Single plan ($(basename "$surviving_plan")) seeded ${comp_dir}/revised-plan.md"
            else
                echo -e "${BLUE}Preserving existing revised-plan.md checkpoint during single-plan resume${NC}"
                log_execution "$task_file" "Phase 2: Single plan ($(basename "$surviving_plan")) preserved existing ${comp_dir}/revised-plan.md checkpoint"
            fi
            skip_evaluator=true
        fi
    fi

    _phase_start=$(_iso_timestamp)
    _FAIL_PHASE_PHASE_ID="phase-3"
    _FAIL_PHASE_PHASE_NAME="evaluate-critic"
    _FAIL_PHASE_PHASE_STARTED_AT="$_phase_start"
    _update_run_manifest_state "phase-3" || true
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
            # TODO: refine error_class if evaluator prompt assembly failures split into stable categories.
            local _requested_plan_evaluator_engine="$ENGINE_EVALUATOR"
            local _effective_plan_evaluator_engine="$ENGINE_EVALUATOR"
            _resolve_effective_engine "$_requested_plan_evaluator_engine"
            _effective_plan_evaluator_engine="$_V2_EFFECTIVE_ENGINE"
            if _v2_engine_resolution_skipped_codex "$_requested_plan_evaluator_engine" "$_effective_plan_evaluator_engine"; then
                _v2_log_codex_circuit_breaker_trip "$task_file" "phase-3 evaluator"
                _v2_append_codex_circuit_breaker_skip "phase-3" "evaluator" "$_phase_start" "phase-3-evaluator"
            fi

            prepare_agent_request "$_effective_plan_evaluator_engine" "$evaluator_prompt" "$eval_instruction" || {
                _fail_phase "evaluating" "Failed to assemble evaluator prompt" "Check agent log at ${log_dir}/evaluator.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                    "unknown" "role=evaluator; step=prepare_agent_request"
            }

            local exit_eval=0
            rm -f "${comp_dir}/plan-evaluation.contract.json"
            run_agent "evaluator" "$_effective_plan_evaluator_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
                "${comp_dir}/plan-evaluation.md" "${log_dir}/evaluator.log" \
                "$EVALUATE_TIMEOUT" "100" || exit_eval=$?
            if [[ "$_effective_plan_evaluator_engine" == "codex" ]]; then
                _v2_record_codex_outcome "$_effective_plan_evaluator_engine" "$exit_eval"
            fi

            if [[ "$exit_eval" -ne 0 ]]; then
                local eval_error_class=""
                local eval_error_message=""
                eval_error_class=$(_classify_agent_exit_error_class "$_effective_plan_evaluator_engine" "$exit_eval" "${log_dir}/evaluator.log")
                if [[ "$exit_eval" -eq 124 ]]; then
                    eval_error_message="Phase 3: Evaluation timed out (${EVALUATE_TIMEOUT})"
                else
                    eval_error_message="Phase 3: Evaluation FAILED (exit $exit_eval)"
                fi
                _fail_phase \
                    "evaluating" \
                    "$eval_error_message" \
                    "Check agent log at ${log_dir}/evaluator.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                    "$eval_error_class" \
                    "role=evaluator; engine=${_effective_plan_evaluator_engine}; exit_code=${exit_eval}; log=${log_dir}/evaluator.log" || true
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
                    _fail_phase \
                        "evaluating" \
                        "Strict mode requires plan-evaluation.contract.json selected_plan_present=true" \
                        "Check ${comp_dir}/plan-evaluation.contract.json and ${comp_dir}/plan-evaluation.md, then retry" \
                        "invalid_artifact" \
                        "artifact=${comp_dir}/plan-evaluation.contract.json; field=selected_plan_present; value=${_eval_present:-empty}" || true
                    _print_cost_summary
                    return 1
                fi
            fi

            if ! _extract_selected_plan_to_file "${comp_dir}/plan-evaluation.md" "${comp_dir}/revised-plan.md"; then
                _log_diagnostic_lines "$task_file" "$(_selected_plan_extraction_diagnostics "${comp_dir}/plan-evaluation.md")"
                _fail_phase \
                    "evaluating" \
                    "Phase 3: Evaluator failed to produce ## Selected Plan (case-insensitive, level 2-3)" \
                    "Check ${comp_dir}/plan-evaluation.md and ${log_dir}/evaluator.log, then retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                    "invalid_artifact" \
                    "artifact=${comp_dir}/plan-evaluation.md; section=## Selected Plan; state=missing_or_empty" || true
                _print_cost_summary
                return 1
            fi
            log_execution "$task_file" "Phase 3: Evaluation completed and revised-plan.md seeded"
            blinding_message="Plan randomization: $(cat "${comp_dir}/.plan-mapping")"
            _atomic_append "${comp_dir}/blinding-metadata.log" "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $blinding_message"
            blinding_message="Plan engine mapping: plan-a=${_effective_planner_a_engine}, plan-b=${_effective_planner_b_engine}"
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
        local _requested_plan_critic_engine="$ENGINE_CRITIC"
        local _effective_plan_critic_engine="$ENGINE_CRITIC"
        _resolve_effective_engine "$_requested_plan_critic_engine"
        _effective_plan_critic_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_plan_critic_engine" "$_effective_plan_critic_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "plan-critic"
            _v2_append_codex_circuit_breaker_skip "phase-3" "plan-critic" "$_phase_start" "plan-critic"
        fi
        run_critic_loop "$task_file" "$comp_dir" "$critic_prompt" "$reviser_prompt" "${comp_dir}/revised-plan.md" "${comp_dir}/plan-critique.md" 3 "plan-critic" "needs verification" "$_effective_plan_critic_engine" || plan_critic_result=$?
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
    local scope_triage_state_file="${comp_dir}/execution-scope-triage.json"
    local latest_fix_diff=""
    local phase4_before_sha=""
    local phase4_pre_exec_dirty=""
    local phase4_scope_plan_file="${comp_dir}/revised-plan.md"
    local phase4_needs_triage=false

    echo -e "${BLUE}=== Phase 4: Execute ===${NC}"
    _phase_start=$(_iso_timestamp)
    _FAIL_PHASE_PHASE_ID="phase-4"
    _FAIL_PHASE_PHASE_NAME="execute"
    _FAIL_PHASE_PHASE_STARTED_AT="$_phase_start"
    _update_run_manifest_state "phase-4" || true
    if _v2_handle_phase4_checkpoint "$task_file" "$baseline_diff" "$scope_triage_state_file" "$phase4_scope_plan_file"; then
        phase4_before_sha="${_V2_PHASE4_CHECKPOINT_BEFORE_SHA:-}"
        phase4_pre_exec_dirty="${_V2_PHASE4_CHECKPOINT_PREEXISTING_DIRTY:-}"
        phase4_needs_triage="${_V2_PHASE4_CHECKPOINT_NEEDS_TRIAGE:-false}"
    else
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 4: Execution started"

        local pre_exec_sha=""
        pre_exec_sha=$(git rev-parse HEAD 2>/dev/null || true)
        local pre_exec_untracked=""
        pre_exec_untracked=$(_collect_blocking_untracked_files "$task_file" "${comp_dir}/revised-plan.md" "$pre_exec_sha")
        local pre_exec_dirty=""
        pre_exec_dirty=$(_v2_snapshot_dirty_files)
        local pre_exec_log_bytes=0
        local post_exec_log_bytes=0
        local exec_log_activity="false"
        pre_exec_log_bytes=$(_v2_file_size_bytes "${comp_dir}/execution-log.md")
        # TODO: refine error_class for Phase 4 setup failures if git/worktree helpers return structured causes.
        if ! _normalize_verify_tags_with_timeout_in_file "${comp_dir}/revised-plan.md" "V2 phase 4 plan"; then
            _fail_phase "executing" "Failed to wrap repo-standard pytest verification commands in revised-plan.md" "Check ${comp_dir}/revised-plan.md for verify tag formatting drift, then retry" \
                "unknown" "artifact=${comp_dir}/revised-plan.md; step=normalize_verify_tags"
            return 1
        fi
        if ! _validate_verify_commands_in_file "${comp_dir}/revised-plan.md" "V2 phase 4 plan"; then
            _fail_phase "executing" "Invalid verify commands found in revised-plan.md" "Check ${comp_dir}/revised-plan.md for bad verify commands, then retry" \
                "unknown" "artifact=${comp_dir}/revised-plan.md; step=validate_verify_commands"
            return 1
        fi

        # Create isolated worktree for execution
        _v2_create_execution_worktree || {
            _fail_phase "executing" "Failed to create execution worktree" "Check disk space and git state" \
                "unknown" "step=_v2_create_execution_worktree"
            return 1
        }
        _v2_capture_preexisting_pipeline_owned_root_dirty "$pre_exec_dirty"
        _v2_stage_execution_runtime_task_file "$task_file" || {
            _fail_phase "executing" "Failed to stage runtime task file into worktree" "Check worktree path permissions and task artifacts, then retry" \
                "unknown" "artifact=${task_file}; step=_v2_stage_execution_runtime_task_file"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        _v2_stage_execution_worktree_files "${comp_dir}/revised-plan.md" || {
            _fail_phase "executing" "Failed to stage execution context into worktree" "Check worktree path permissions and task artifacts, then retry" \
                "unknown" "artifact=${comp_dir}/revised-plan.md; step=_v2_stage_execution_worktree_files"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        if [[ -f "${comp_dir}/execution-log.md" ]]; then
            _v2_stage_execution_worktree_file "${comp_dir}/execution-log.md" || {
                _fail_phase "executing" "Failed to stage execution log into worktree" "Check worktree path permissions and task artifacts, then retry" \
                    "unknown" "artifact=${comp_dir}/execution-log.md; step=_v2_stage_execution_worktree_file"
                _v2_save_worktree_diff || true
                _v2_cleanup_execution_worktree || true
                return 1
            }
        fi
        local exec_plan_rel=""
        local exec_task_rel=""
        local exec_log_rel=""
        exec_plan_rel=$(_v2_main_repo_relative_path "${comp_dir}/revised-plan.md") || {
            _fail_phase "executing" "Failed to resolve worktree-local plan path" "Check task artifact location, then retry" \
                "unknown" "artifact=${comp_dir}/revised-plan.md; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        exec_task_rel=$(_v2_execution_runtime_task_rel_path)
        exec_log_rel=$(_v2_main_repo_relative_path "${comp_dir}/execution-log.md") || {
            _fail_phase "executing" "Failed to resolve worktree-local execution log path" "Check task artifact location, then retry" \
                "unknown" "artifact=${comp_dir}/execution-log.md; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        local exec_instruction="You are the Executor. Your project root is the current working directory (${_V2_EXEC_WORKTREE_PATH}).
Read the approved plan at ${exec_plan_rel} and the task file at ${exec_task_rel}.
Implement the plan step by step. Write execution progress to ${exec_log_rel}.
All repo file reads and writes must stay inside the current working directory. Do not use absolute paths under ${SCRIPT_DIR}.
        Work in small, verifiable steps and stop with BLOCKED if the plan cannot be completed safely.
        If any verification command exits 124, append 'BLOCKED: $(_verification_timeout_message) - <command>' and stop immediately."
        local _requested_executor_engine="$ENGINE_EXECUTOR"
        local _effective_executor_engine="$ENGINE_EXECUTOR"
        _resolve_effective_engine "$_requested_executor_engine"
        _effective_executor_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_executor_engine" "$_effective_executor_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "executor"
            _v2_append_codex_circuit_breaker_skip "phase-4" "executor" "$_phase_start" "executor"
        fi
        prepare_agent_request "$_effective_executor_engine" "$executor_prompt" "$exec_instruction" || {
            _fail_phase "executing" "Failed to assemble executor prompt" "Check agent log at ${log_dir}/executor.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "unknown" "role=executor; step=prepare_agent_request"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        if [[ "$_effective_executor_engine" == "claude" ]]; then
            AGENT_SYSTEM_PROMPT=$(printf '%s' "$AGENT_SYSTEM_PROMPT" | _normalize_executor_prompt_timeout_content "V2 phase 4 executor prompt") || {
                _fail_phase "executing" "Executor prompt timeout normalization drifted" "Check ${executor_prompt} for repo-standard pytest command changes before retrying" \
                    "unknown" "artifact=${executor_prompt}; step=_normalize_executor_prompt_timeout_content; target=system_prompt"
                _v2_save_worktree_diff || true
                _v2_cleanup_execution_worktree || true
                return 1
            }
        else
            AGENT_PROMPT_BODY=$(printf '%s' "$AGENT_PROMPT_BODY" | _normalize_executor_prompt_timeout_content "V2 phase 4 executor prompt") || {
                _fail_phase "executing" "Executor prompt timeout normalization drifted" "Check ${executor_prompt} for repo-standard pytest command changes before retrying" \
                    "unknown" "artifact=${executor_prompt}; step=_normalize_executor_prompt_timeout_content; target=prompt_body"
                _v2_save_worktree_diff || true
                _v2_cleanup_execution_worktree || true
                return 1
            }
        fi
        cd "$_V2_EXEC_WORKTREE_PATH"

        local exit_exec=0
        local pre_exec_timeout_blocks=0
        local post_exec_timeout_blocks=0
        local exec_timeout_block_line=""
        local exec_log_read_path=""
        pre_exec_timeout_blocks=$(_timeout_block_count_in_file "${comp_dir}/execution-log.md")
        touch "${log_dir}/executor.log"
        start_agent_monitor "${log_dir}/executor.log" "$task_file"
        run_agent "executor" "$_effective_executor_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "/dev/null" "${log_dir}/executor.log" \
            "$EXECUTOR_TIMEOUT" "300" "WebFetch,WebSearch" || exit_exec=$?
        stop_agent_monitor
        if [[ "$_effective_executor_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_executor_engine" "$exit_exec"
        fi
        exec_log_read_path=$(_v2_execution_worktree_read_path_for "${comp_dir}/execution-log.md")
        post_exec_timeout_blocks=$(_timeout_block_count_in_file "$exec_log_read_path")
        post_exec_log_bytes=$(_v2_file_size_bytes "$exec_log_read_path")
        if [[ "${post_exec_log_bytes:-0}" -gt "${pre_exec_log_bytes:-0}" ]]; then
            exec_log_activity="true"
        fi
        if [[ "${post_exec_timeout_blocks:-0}" -gt "${pre_exec_timeout_blocks:-0}" ]]; then
            exec_timeout_block_line=$(_latest_timeout_block_line "$exec_log_read_path" || true)
            echo -e "${YELLOW}$(_verification_timeout_message)${NC}"
            log_execution "$task_file" "Phase 4: $(_verification_timeout_message)"
            set_task_status "$task_file" "blocked"
            if [[ -n "$exec_timeout_block_line" ]]; then
                echo "  Reason: $exec_timeout_block_line"
            fi
            _v2_sync_execution_worktree_files "${comp_dir}/execution-log.md" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi

        if [[ "$exit_exec" -ne 0 ]]; then
            local exec_error_class=""
            local exec_error_message=""
            exec_error_class=$(_classify_agent_exit_error_class "$_effective_executor_engine" "$exit_exec" "${log_dir}/executor.log")
            if [[ "$exit_exec" -eq 124 ]]; then
                exec_error_message="Phase 4: Execution timed out (${EXECUTOR_TIMEOUT})"
            else
                exec_error_message="Phase 4: Execution FAILED (exit $exit_exec)"
            fi
            _fail_phase \
                "executing" \
                "$exec_error_message" \
                "Check agent log at ${log_dir}/executor.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "$exec_error_class" \
                "role=executor; engine=${_effective_executor_engine}; exit_code=${exit_exec}; log=${log_dir}/executor.log" || true
            _v2_sync_execution_worktree_files "${comp_dir}/execution-log.md" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 4: Execution completed"

        # Capture diff inside the worktree (isolated from other pipelines)
        phase4_before_sha="$pre_exec_sha"
        phase4_pre_exec_dirty="$pre_exec_dirty"
        capture_diff_artifact "$pre_exec_sha" "$baseline_diff" "$task_file" "${comp_dir}/revised-plan.md" "$pre_exec_dirty"
        if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && [[ -z "${_V2_LAST_CAPTURE_UNTRACKED_FILES:-}" ]]; then
            local phase4_worktree_error_message=""
            local phase4_worktree_error_detail=""
            _log_diagnostic_lines "$task_file" "$(_v2_phase_execution_diagnostic_lines "$exec_log_activity" "$exec_log_read_path" "$baseline_diff")"
            if [[ "$exec_log_activity" == "true" ]]; then
                echo -e "${RED}Execution activity detected but execution worktree is clean${NC}"
                log_execution "$task_file" "Phase 4: Execution activity detected but execution worktree is clean — suspected out-of-worktree write or non-persisted executor change"
                phase4_worktree_error_message="Phase 4: Execution activity detected but execution worktree is clean — suspected out-of-worktree write or non-persisted executor change"
                phase4_worktree_error_detail="phase=phase-4; activity_detected=true; worktree=clean; diff=${baseline_diff}"
            else
                echo -e "${RED}Executor produced no code changes${NC}"
                log_execution "$task_file" "Phase 4: Executor produced no code changes"
                phase4_worktree_error_message="Phase 4: Executor produced no code changes"
                phase4_worktree_error_detail="phase=phase-4; activity_detected=false; worktree=clean; diff=${baseline_diff}"
            fi
            _fail_phase \
                "executing" \
                "$phase4_worktree_error_message" \
                "Inspect ${comp_dir}/execution-log.md and ${comp_dir}/revised-plan.md, then retry after keeping executor writes inside the execution worktree" \
                "scope_violation" \
                "$phase4_worktree_error_detail" || true
            _v2_sync_execution_worktree_files "${comp_dir}/execution-log.md" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi
        _v2_log_capture_scope_details "$task_file" "Phase 4"
        if [[ ! -s "$baseline_diff" ]]; then
            echo -e "${YELLOW}WARN: Execution diff capture produced an empty artifact despite live changes: ${baseline_diff}${NC}"
            log_execution "$task_file" "Phase 4: WARNING diff capture was empty but working tree has changes outside the resolved scope"
        else
            log_execution "$task_file" "Phase 4: Execution diff captured at ${baseline_diff}"
        fi

        _block_on_untracked_files "$task_file" "Phase 4" "${comp_dir}/revised-plan.md" "$pre_exec_sha" "$pre_exec_untracked" || {
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }

        # Capture worktree diff count BEFORE merge (cleanup clears _V2_EXEC_WORKTREE_PATH)
        _worktree_diff_lines=0
        if [[ -d "${_V2_EXEC_WORKTREE_PATH:-}" ]]; then
            _worktree_diff_lines=$(cd "$_V2_EXEC_WORKTREE_PATH" && git diff --stat HEAD | wc -l 2>/dev/null || echo "0")
        fi

        # Merge worktree changes back to the main branch
        cd "$SCRIPT_DIR"
        local phase4_merge_branch=""
        phase4_merge_branch=$(_v2_execution_merge_branch_label)
        _v2_merge_execution_worktree "${comp_dir}/execution-log.md" || {
            _fail_phase "executing" "Failed to merge execution worktree" "Check for merge conflicts; resolve manually then retry" \
                "merge_failure" "phase=phase-4; step=_v2_merge_execution_worktree; branch=${phase4_merge_branch}"
            _v2_cleanup_after_failed_merge true
            return 1
        }

        phase4_needs_triage=true
    fi

    if [[ "$phase4_needs_triage" == true ]]; then
        _v2_run_scope_triage "$task_file" "Phase 4" "$comp_dir" "$phase4_before_sha" "$phase4_scope_plan_file" "$baseline_diff" "$phase4_pre_exec_dirty" 0
        _append_manifest_phase "phase-4" "execute" "$_phase_start" "$(_iso_timestamp)" "completed" || true
    fi

    if [[ "$phase4_needs_triage" == true ]]; then
        if _v2_log_out_of_scope_capture_warning "$task_file" "Phase 4"; then
            :
        elif [[ -n "${_V2_LAST_CAPTURE_SCOPE_SOURCE:-}" ]]; then
            if [[ "${_V2_LAST_CAPTURE_SCOPE_SOURCE}" == "plan-files-to-modify" ]]; then
                log_execution "$task_file" "Phase 4: Diff scope check passed"
            else
                log_execution "$task_file" "Phase 4: Diff scope check passed with warnings"
            fi
        fi
    fi

    # Activity-detected-but-empty-diff guard: halt if executor showed activity
    # but scope triage left the in-scope diff empty (all changes were NOISE).
    if [[ "$phase4_needs_triage" == true && ! -s "$baseline_diff" && "${exec_log_activity:-false}" == "true" ]]; then
        local phase4_empty_diff_completed_at=""
        local phase4_empty_diff_cost=""
        phase4_empty_diff_completed_at=$(_iso_timestamp)
        phase4_empty_diff_cost=$(_manifest_phase_measured_cost)
        _append_manifest_phase \
            "${_FAIL_PHASE_PHASE_ID:-phase-4}" \
            "${_FAIL_PHASE_PHASE_NAME:-execute}" \
            "${_FAIL_PHASE_PHASE_STARTED_AT:-$phase4_empty_diff_completed_at}" \
            "$phase4_empty_diff_completed_at" \
            "failed" \
            "" \
            "$phase4_empty_diff_cost" \
            "scope_violation" \
            "phase=phase-4; reason=activity_quarantined_by_scope_triage; diff=${baseline_diff}" || true
        echo -e "${RED}Phase 4: Executor activity detected but in-scope diff is empty after scope triage — halting${NC}"
        log_execution "$task_file" "Phase 4: HALTED — executor activity detected but all changes quarantined by scope triage. In-scope diff is empty. Review scope plan for accuracy, then re-run."
        _write_human_review_handoff "BLOCKED" "0" || true
        set_task_status "$task_file" "needs verification"
        _finalize_run_manifest "human_review" 0 || true
        _print_cost_summary
        return 0
    fi

    local _diff_risk=""
    local _effective_reviewer_timeout=""
    _diff_risk=$(_classify_diff_risk)
    _effective_reviewer_timeout=$(_resolve_reviewer_timeout "$_diff_risk")
    log_execution "$task_file" "Phase 4: Diff risk classification: ${_diff_risk}"
    log_execution "$task_file" "Phase 4: Reviewer timeout resolved to ${_effective_reviewer_timeout} (source=$(_reviewer_timeout_resolution_source), diff_risk=${_diff_risk})"
    _update_run_manifest_state "phase-4" "$_diff_risk" "$_effective_reviewer_timeout" || true

    if [[ "${_diff_risk}" != "LOW" ]]; then
        log_execution "$task_file" "Phase 4: Diff risk advisory only (diff_risk=${_diff_risk}; single-reviewer halt now requires explicit LAUREN_LOOP_STRICT=true)"
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

    local _worktree_diff_lines=0

    # Empty-diff guard: halt if execution produced no captured files (phantom execution detection)
    if [[ "$phase4_needs_triage" == true ]]; then
        local _captured_count=0
        _captured_count=$(echo "${_V2_LAST_CAPTURED_FILES:-}" | grep -c '.' 2>/dev/null || true)
        # _worktree_diff_lines captured before merge (above) — worktree no longer exists here
        if [[ "$_captured_count" -eq 0 && ! -s "$baseline_diff" && "$_worktree_diff_lines" -eq 0 ]]; then
            echo -e "${RED}Phase 4: Execution produced no captured files, diff is empty, and worktree has no changes — halting (phantom execution suspected)${NC}"
            log_execution "$task_file" "Phase 4: HALTED — zero captured files, empty diff, and clean worktree after scope triage. Phantom execution suspected. Re-run with FORCE_RERUN=true."
            _fail_phase \
                "executing" \
                "Phase 4: Execution produced no captured files, diff is empty, and worktree has no changes — phantom execution suspected" \
                "Re-run with FORCE_RERUN=true after checking scope triage and executor writes" \
                "scope_violation" \
                "phase=phase-4; captured_count=${_captured_count}; diff=empty; worktree_diff_lines=${_worktree_diff_lines}" || true
            _print_cost_summary
            return 1
        fi
    fi

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
    local _resume_phase8_halt_subphase=""
    local _phase8_round="initial"
    local needs_phase8c=false
    local _phase8c_source_phase=""
    local _phase8_cumulative_diff=""
    local _phase8_changed_files=""

    # Cycle checkpoint resume
    if [[ "$FORCE_RERUN" != "true" ]] && _read_cycle_state "$comp_dir"; then
        fix_cycle=$CYCLE_STATE_FIX_CYCLE
        case "$CYCLE_STATE_LAST_COMPLETED" in
            phase-5)  _resume_to_subphase="phase-6a" ;;
            phase-6a) _resume_to_subphase="phase-6b" ;;
            phase-6b) _resume_to_subphase="phase-6c" ;;
            phase-6c) _resume_to_subphase="phase-7" ;;
            phase-7)  _resume_to_subphase="phase-8a" ;;
            phase-8a)
                _phase8_round="${CYCLE_STATE_PHASE8_ROUND:-initial}"
                case "${_phase8_round}:${CYCLE_STATE_PHASE8_RESULT:-}" in
                    initial:PASS|post-fix:PASS)
                        _resume_to_subphase="phase-8b"
                        ;;
                    initial:FAIL)
                        _resume_to_subphase="phase-8c"
                        needs_phase8c=true
                        _phase8c_source_phase="phase-8a"
                        ;;
                    initial:BLOCKED|post-fix:FAIL|post-fix:BLOCKED)
                        pipeline_finished=true
                        pipeline_human_review_halt=true
                        _resume_phase8_halt_subphase="phase-8a"
                        ;;
                    *)
                        _clear_resume_checkpoint "phase-8a" "unsupported phase8 checkpoint: round=${_phase8_round:-empty}, result=${CYCLE_STATE_PHASE8_RESULT:-empty}"
                        ;;
                esac
                ;;
            phase-8b)
                _phase8_round="${CYCLE_STATE_PHASE8_ROUND:-initial}"
                case "${_phase8_round}:${CYCLE_STATE_PHASE8_RESULT:-}" in
                    initial:PASS|post-fix:PASS)
                        pipeline_finished=true
                        pipeline_success=true
                        ;;
                    initial:FAIL)
                        _resume_to_subphase="phase-8c"
                        needs_phase8c=true
                        _phase8c_source_phase="phase-8b"
                        ;;
                    initial:BLOCKED|post-fix:FAIL|post-fix:BLOCKED)
                        pipeline_finished=true
                        pipeline_human_review_halt=true
                        _resume_phase8_halt_subphase="phase-8b"
                        ;;
                    *)
                        _clear_resume_checkpoint "phase-8b" "unsupported phase8 checkpoint: round=${_phase8_round:-empty}, result=${CYCLE_STATE_PHASE8_RESULT:-empty}"
                        ;;
                esac
                ;;
            phase-8c)
                _phase8_round="${CYCLE_STATE_PHASE8_ROUND:-post-fix}"
                case "${_phase8_round}:${CYCLE_STATE_PHASE8_RESULT:-}" in
                    post-fix:COMPLETE)
                        _resume_to_subphase="phase-8a"
                        ;;
                    initial:BLOCKED)
                        pipeline_finished=true
                        pipeline_human_review_halt=true
                        _resume_phase8_halt_subphase="phase-8c"
                        ;;
                    *)
                        _clear_resume_checkpoint "phase-8c" "unsupported phase8 checkpoint: round=${_phase8_round:-empty}, result=${CYCLE_STATE_PHASE8_RESULT:-empty}"
                        ;;
                esac
                ;;
            *)        _resume_to_subphase="" ;;
        esac
        if [[ "$pipeline_human_review_halt" == true ]] && [[ -n "$_resume_phase8_halt_subphase" ]]; then
            set_task_status "$task_file" "needs verification"
            if ! _write_phase8_human_review_handoff "$_resume_phase8_halt_subphase"; then
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Pipeline FAILED while human-review-handoff: Failed to write Phase 8 handoff artifacts"
                _print_cost_summary
                return 1
            fi
            log_execution "$task_file" "Cycle checkpoint resume: Phase 8 ${_resume_phase8_halt_subphase} requires human review. See competitive/human-review-handoff.md"
        elif [[ "$pipeline_success" == true ]]; then
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Cycle checkpoint resume: success finalization from ${CYCLE_STATE_LAST_COMPLETED}"
        fi
        if [[ -n "$_resume_to_subphase" ]]; then
            if _resume_target_ready "$_resume_to_subphase"; then
                echo -e "${BLUE}Resuming from cycle state: fix_cycle=${fix_cycle}, resume_to=${_resume_to_subphase}${NC}"
                log_execution "$task_file" "Cycle checkpoint resume: fix_cycle=${fix_cycle}, last_completed=${CYCLE_STATE_LAST_COMPLETED}, resume_to=${_resume_to_subphase}, phase8_round=${CYCLE_STATE_PHASE8_ROUND:-}, phase8_result=${CYCLE_STATE_PHASE8_RESULT:-}"
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
        _FAIL_PHASE_PHASE_ID="phase-5"
        _FAIL_PHASE_PHASE_NAME="review-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase_start"
        _update_run_manifest_state "phase-5" "$_diff_risk" "$_effective_reviewer_timeout" || true
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
        local _requested_reviewer_a_engine="$ENGINE_REVIEWER_A"
        local _effective_reviewer_a_engine="$ENGINE_REVIEWER_A"
        _resolve_effective_engine "$_requested_reviewer_a_engine"
        _effective_reviewer_a_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_reviewer_a_engine" "$_effective_reviewer_a_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "reviewer-a"
            _v2_append_codex_circuit_breaker_skip "phase-5" "review-cycle-$((fix_cycle+1))-a" "$_phase_start" "reviewer-a"
        fi
        local _requested_reviewer_b_engine="$ENGINE_REVIEWER_B"
        local _effective_reviewer_b_engine="$ENGINE_REVIEWER_B"
        _resolve_effective_engine "$_requested_reviewer_b_engine"
        _effective_reviewer_b_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_reviewer_b_engine" "$_effective_reviewer_b_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "reviewer-b"
            _v2_append_codex_circuit_breaker_skip "phase-5" "review-cycle-$((fix_cycle+1))-b" "$_phase_start" "reviewer-b"
        fi
        local review_b_output_path="${comp_dir}/reviewer-b.raw.md"
        if [[ "$_effective_reviewer_b_engine" == "codex" ]]; then
            review_b_output_path="$CODEX_ARTIFACT_PATH_PLACEHOLDER"
        fi
        local review_b_instruction="Read the task file at ${task_file}. ${review_diff_context} Read ${comp_dir}/exploration-summary.md for context. Write your review to ${review_b_output_path}. This is review cycle $((fix_cycle + 1))."

        # TODO: refine error_class if review prompt assembly and dual-reviewer failures split into stable categories.
        prepare_agent_request "$_effective_reviewer_a_engine" "$reviewer_a_prompt_runtime" "$review_a_instruction" || {
            rm -f "$reviewer_a_prompt_runtime"
            _fail_phase "reviewing" "Failed to assemble reviewer-a prompt" "Check agent log at ${log_dir}/reviewer-a*.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "unknown" "role=reviewer-a; step=prepare_agent_request"
        }
        local reviewer_a_body="$AGENT_PROMPT_BODY"
        local reviewer_a_system="$AGENT_SYSTEM_PROMPT"

        prepare_agent_request "$_effective_reviewer_b_engine" "$reviewer_b_prompt" "$review_b_instruction" || {
            rm -f "$reviewer_a_prompt_runtime"
            _fail_phase "reviewing" "Failed to assemble reviewer-b prompt" "Check agent log at ${log_dir}/reviewer-b*.log. Retry: bash lauren-loop-v2.sh ${SLUG} '${goal}'" \
                "unknown" "role=reviewer-b; step=prepare_agent_request"
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
        run_agent "$reviewer_a_role" "$_effective_reviewer_a_engine" "$reviewer_a_body" "$reviewer_a_system" \
            "/dev/null" "$reviewer_a_log" "$_effective_reviewer_timeout" "100" &
        local pid_ra=$!

        reviewer_b_start_ts=$(date +%s)
        run_agent "$reviewer_b_role" "$_effective_reviewer_b_engine" "$reviewer_b_body" "$reviewer_b_system" \
            "${comp_dir}/reviewer-b.raw.md" "$reviewer_b_log" "$_effective_reviewer_timeout" "100" &
        local pid_rb=$!

        local exit_ra=0 exit_rb=0
        wait $pid_ra || exit_ra=$?
        if [[ "$_effective_reviewer_a_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_reviewer_a_engine" "$exit_ra"
        fi
        reviewer_a_duration=$(( $(date +%s) - reviewer_a_start_ts ))
        (( reviewer_a_duration < 0 )) && reviewer_a_duration=0

        if _capture_reviewer_a_raw_artifact "$task_file" "${comp_dir}/reviewer-a.raw.md"; then
            reviewer_a_usable=true
        else
            grep -i 'review.findings' "$task_file" | head -5 | while IFS= read -r _line; do
                log_execution "$task_file" "  diagnostic: found heading: $_line"
            done
        fi

        if [[ "$_effective_reviewer_a_engine" == "claude" ]] && [[ "$_effective_reviewer_b_engine" == "codex" ]] && \
           [[ "$reviewer_a_usable" == true ]] && \
           kill -0 "$pid_rb" 2>/dev/null; then
            if ! _enforce_codex_phase_backstop "$pid_rb" "$reviewer_b_role" "$reviewer_b_start_ts" "$_effective_reviewer_timeout" "$reviewer_a_duration" "$reviewer_b_log" "${comp_dir}/reviewer-b.raw.md"; then
                reviewer_b_backstopped=true
            fi
        fi
        wait $pid_rb || exit_rb=$?
        if [[ "$_effective_reviewer_b_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_reviewer_b_engine" "$exit_rb"
        fi
        if [[ "$reviewer_b_backstopped" == true ]]; then
            _append_interrupted_cost_rows TERM || true
        fi
        _merge_cost_csvs || true
        rm -f "$reviewer_a_prompt_runtime"
        _validate_agent_output_for_role "$reviewer_a_role" "${comp_dir}/reviewer-a.raw.md" || true
        _validate_agent_output_for_role "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" || true

        if [[ "$exit_ra" -ne 0 && "$exit_rb" -ne 0 ]]; then
            _fail_phase "reviewing" "Both reviewers failed (A=$exit_ra, B=$exit_rb)" "Both reviewers failed. Check ${log_dir}/reviewer-*.log. Retry with --force to re-run from Phase 5" \
                "unknown" "reviewer_a_exit=${exit_ra}; reviewer_b_exit=${exit_rb}"
        fi

        echo -e "${BLUE}Review parallel done: A=$exit_ra, B=$exit_rb${NC}"
        local has_review_a=false has_review_b=false
        local effective_reviewer_a_engine="$_effective_reviewer_a_engine"
        local effective_reviewer_b_engine="$_effective_reviewer_b_engine"
        local reviewer_a_fallback_attempted=false reviewer_b_fallback_attempted=false
        local reviewer_a_fallback_succeeded=false reviewer_b_fallback_succeeded=false
        _validate_agent_output_for_role "$reviewer_a_role" "${comp_dir}/reviewer-a.raw.md" >/dev/null 2>&1 && has_review_a=true
        _promote_latest_valid_attempt "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" || true
        _validate_agent_output_for_role "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" >/dev/null 2>&1 && has_review_b=true

        if [[ "$has_review_a" == false && "$has_review_b" == false ]]; then
            echo -e "${RED}Parallel review failed to produce any usable raw review artifacts${NC}"
            _fail_phase \
                "reviewing" \
                "Phase 5: Review artifacts missing" \
                "Check ${log_dir}/reviewer-*.log and the raw review artifacts, then retry Phase 5" \
                "invalid_artifact" \
                "reviewer_a_exit=${exit_ra}; reviewer_a_artifact=${has_review_a}; reviewer_b_exit=${exit_rb}; reviewer_b_artifact=${has_review_b}" || true
            _print_cost_summary
            return 1
        fi

        if [[ "$has_review_a" != "$has_review_b" ]]; then
            local fallback_missing_label="" fallback_engine="" fallback_run_role="" fallback_log=""
            local fallback_prompt_file="" fallback_instruction="" fallback_output=""
            local fallback_prompt_body="" fallback_sysprompt=""
            local fallback_exit=0 fallback_prepared=false fallback_start_ts=0 fallback_duration=0
            local skip_engine_fallback=false fallback_review_b_output_path="" fallback_source_engine=""
            local reviewer_a_fallback_prompt_runtime="" fallback_diag_output="" fallback_output_state="" fallback_validation_err=""
            local _effective_reviewer_fallback_engine=""
            local fallback_dispatch_label=""

            if [[ "$has_review_a" == false ]]; then
                fallback_missing_label="reviewer-a"
                fallback_engine="codex"
                fallback_source_engine="$ENGINE_REVIEWER_A"
                if [[ "$ENGINE_REVIEWER_A" == "codex" ]]; then
                    fallback_engine="claude"
                fi
                fallback_output="/dev/null"
                fallback_diag_output="${comp_dir}/reviewer-a.raw.md"
                fallback_instruction="$review_a_instruction"

                if [[ ! -f "$reviewer_a_prompt_runtime" ]]; then
                    reviewer_a_fallback_prompt_runtime=$(mktemp "${TMPDIR:-/tmp}/reviewer-a-fallback.XXXXXX")
                    sed "s|\$PROJECT_NAME|$PROJECT_NAME|g" "$reviewer_a_prompt" > "$reviewer_a_fallback_prompt_runtime"
                    fallback_prompt_file="$reviewer_a_fallback_prompt_runtime"
                else
                    fallback_prompt_file="$reviewer_a_prompt_runtime"
                fi
            else
                fallback_missing_label="reviewer-b"
                fallback_engine="claude"
                fallback_source_engine="$ENGINE_REVIEWER_B"
                if [[ "$ENGINE_REVIEWER_B" == "claude" ]]; then
                    fallback_engine="codex"
                fi
                fallback_output="${comp_dir}/reviewer-b.raw.md"
                fallback_diag_output="$fallback_output"
                fallback_review_b_output_path="$fallback_output"
                if [[ "$fallback_engine" == "codex" ]]; then
                    fallback_review_b_output_path="$CODEX_ARTIFACT_PATH_PLACEHOLDER"
                fi
                fallback_instruction="Read the task file at ${task_file}. ${review_diff_context} Read ${comp_dir}/exploration-summary.md for context. Write your review to ${fallback_review_b_output_path}. This is review cycle $((fix_cycle + 1))."
                    fallback_prompt_file="$reviewer_b_prompt"
            fi

            _effective_reviewer_fallback_engine="$fallback_engine"
            fallback_dispatch_label="${fallback_missing_label}-fallback"
            _resolve_effective_engine "$fallback_engine"
            _effective_reviewer_fallback_engine="$_V2_EFFECTIVE_ENGINE"
            if _v2_engine_resolution_skipped_codex "$fallback_engine" "$_effective_reviewer_fallback_engine"; then
                _v2_log_codex_circuit_breaker_trip "$task_file" "$fallback_dispatch_label"
                _v2_append_codex_circuit_breaker_skip "phase-5" "review-cycle-$((fix_cycle+1))" "$_phase_start" "$fallback_dispatch_label"
            fi
            fallback_run_role="${fallback_missing_label}-${_effective_reviewer_fallback_engine}-fallback${role_suffix}"
            fallback_log="${log_dir}/${fallback_run_role}.log"
            if [[ "$fallback_missing_label" == "reviewer-b" ]]; then
                if [[ "$_effective_reviewer_fallback_engine" == "codex" ]]; then
                    fallback_review_b_output_path="$CODEX_ARTIFACT_PATH_PLACEHOLDER"
                else
                    fallback_review_b_output_path="$fallback_output"
                fi
                fallback_instruction="Read the task file at ${task_file}. ${review_diff_context} Read ${comp_dir}/exploration-summary.md for context. Write your review to ${fallback_review_b_output_path}. This is review cycle $((fix_cycle + 1))."
            fi

            if [[ "$fallback_source_engine" == "codex" ]]; then
                if [[ "$fallback_missing_label" == "reviewer-a" ]] && _review_phase_codex_retry_already_attempted "$reviewer_a_log"; then
                    skip_engine_fallback=true
                elif [[ "$fallback_missing_label" == "reviewer-b" ]] && _review_phase_codex_retry_already_attempted "$reviewer_b_log"; then
                    skip_engine_fallback=true
                fi
            fi

            if [[ "$skip_engine_fallback" == true ]]; then
                [[ -n "$reviewer_a_fallback_prompt_runtime" ]] && rm -f "$reviewer_a_fallback_prompt_runtime"
                log_execution "$task_file" "Phase 5: ${fallback_missing_label} missing, skipping opposite-engine fallback because Codex already entered capacity/stream retry handling"
            else
                if [[ "$fallback_missing_label" == "reviewer-a" ]]; then
                    reviewer_a_fallback_attempted=true
                else
                    reviewer_b_fallback_attempted=true
                fi
                echo -e "${YELLOW}Single reviewer available — retrying ${fallback_missing_label} once with ${_effective_reviewer_fallback_engine}${NC}"
                log_execution "$task_file" "Phase 5: ${fallback_missing_label} missing, launching ${_effective_reviewer_fallback_engine} fallback"
                if [[ "$fallback_missing_label" == "reviewer-a" ]]; then
                    _update_run_manifest_state "phase-5" "$_diff_risk" "$_effective_reviewer_timeout" "${_effective_reviewer_fallback_engine} (fallback)" "$effective_reviewer_b_engine" || true
                else
                    _update_run_manifest_state "phase-5" "$_diff_risk" "$_effective_reviewer_timeout" "$effective_reviewer_a_engine" "${_effective_reviewer_fallback_engine} (fallback)" || true
                fi

                if [[ "$fallback_missing_label" == "reviewer-a" ]]; then
                    clear_markdown_section "$task_file" "## Review Findings"
                    rm -f "${comp_dir}/reviewer-a.raw.md"
                else
                    rm -f "${comp_dir}/reviewer-b.raw.md"
                fi

                if prepare_agent_request "$_effective_reviewer_fallback_engine" "$fallback_prompt_file" "$fallback_instruction"; then
                    fallback_prepared=true
                    fallback_prompt_body="$AGENT_PROMPT_BODY"
                    fallback_sysprompt="$AGENT_SYSTEM_PROMPT"
                    fallback_start_ts=$(date +%s)
                    run_agent "$fallback_run_role" "$_effective_reviewer_fallback_engine" "$fallback_prompt_body" "$fallback_sysprompt" \
                        "$fallback_output" "$fallback_log" "$_effective_reviewer_timeout" "100"
                    fallback_exit=$?
                    if [[ "$_effective_reviewer_fallback_engine" == "codex" ]]; then
                        _v2_record_codex_outcome "$_effective_reviewer_fallback_engine" "$fallback_exit"
                    fi
                    fallback_duration=$(( $(date +%s) - fallback_start_ts ))
                    (( fallback_duration < 0 )) && fallback_duration=0
                else
                    log_execution "$task_file" "Phase 5: Failed to assemble ${_effective_reviewer_fallback_engine} fallback prompt for ${fallback_missing_label}"
                fi

                _merge_cost_csvs || true

                if [[ "$fallback_missing_label" == "reviewer-a" ]]; then
                    if fallback_validation_err=$(_capture_reviewer_a_raw_artifact "$task_file" "${comp_dir}/reviewer-a.raw.md" 2>&1 1>/dev/null); then
                        reviewer_a_fallback_succeeded=true
                        effective_reviewer_a_engine="${_effective_reviewer_fallback_engine} (fallback)"
                    else
                        fallback_output_state=$(_describe_artifact_state "$fallback_diag_output")
                    fi
                    [[ -n "$reviewer_a_fallback_prompt_runtime" ]] && rm -f "$reviewer_a_fallback_prompt_runtime"
                else
                    if fallback_validation_err=$(_validate_agent_output_for_role "$fallback_run_role" "${comp_dir}/reviewer-b.raw.md" 2>&1 1>/dev/null); then
                        reviewer_b_fallback_succeeded=true
                    else
                        local fallback_retry_validation_err=""
                        fallback_output_state=$(_describe_artifact_state "$fallback_diag_output")
                        rm -f "${comp_dir}/reviewer-b.raw.md"
                        if _promote_latest_valid_attempt "$fallback_run_role" "${comp_dir}/reviewer-b.raw.md" >/dev/null 2>&1; then
                            if fallback_retry_validation_err=$(_validate_agent_output_for_role "$fallback_run_role" "${comp_dir}/reviewer-b.raw.md" 2>&1 1>/dev/null); then
                                reviewer_b_fallback_succeeded=true
                            elif [[ -n "$fallback_retry_validation_err" ]]; then
                                fallback_validation_err="$fallback_retry_validation_err"
                            fi
                        fi
                        if [[ "$reviewer_b_fallback_succeeded" != true ]] && [[ -z "$fallback_output_state" || "$fallback_output_state" == "missing" ]]; then
                            fallback_output_state=$(_describe_artifact_state "$fallback_diag_output")
                        fi
                    fi
                    if [[ "$reviewer_b_fallback_succeeded" == true ]]; then
                        effective_reviewer_b_engine="${_effective_reviewer_fallback_engine} (fallback)"
                    fi
                fi

                has_review_a=false
                has_review_b=false
                _validate_agent_output_for_role "$reviewer_a_role" "${comp_dir}/reviewer-a.raw.md" >/dev/null 2>&1 && has_review_a=true
                _promote_latest_valid_attempt "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" || true
                _validate_agent_output_for_role "$reviewer_b_role" "${comp_dir}/reviewer-b.raw.md" >/dev/null 2>&1 && has_review_b=true

                if [[ "$has_review_a" == true && "$has_review_b" == true ]]; then
                    echo -e "${GREEN}Opposite-engine fallback for ${fallback_missing_label} succeeded — both reviews available${NC}"
                    log_execution "$task_file" "Phase 5: ${fallback_missing_label} fallback succeeded"
                else
                    local _fb_output_state=""
                    local _fb_validation_err=""
                    echo -e "${YELLOW}Opposite-engine fallback for ${fallback_missing_label} failed — continuing with single reviewer${NC}"
                    _fb_output_state="${fallback_output_state:-$(_describe_artifact_state "$fallback_diag_output")}"
                    log_execution "$task_file" "Phase 5: ${fallback_missing_label} fallback failed (prepared=${fallback_prepared}, exit=${fallback_exit}, duration=${fallback_duration}s, output=${_fb_output_state})"
                    _fb_validation_err="${fallback_validation_err//$'\n'/ | }"
                    if [[ -n "$_fb_validation_err" ]]; then
                        log_execution "$task_file" "Phase 5: Fallback validation failure: ${_fb_validation_err}"
                    fi
                    if [[ -f "$fallback_log" ]] && [[ -s "$fallback_log" ]]; then
                        local _fb_log_tail
                        _fb_log_tail=$(tail -20 "$fallback_log" 2>/dev/null || true)
                        if [[ -n "$_fb_log_tail" ]]; then
                            log_execution "$task_file" "Phase 5: Fallback agent log tail (last 20 lines):"
                            _log_diagnostic_lines "$task_file" "$_fb_log_tail"
                        fi
                    fi
                fi
            fi
        fi

        if [[ "$has_review_a" == false ]]; then
            if [[ "$reviewer_a_fallback_attempted" == true && "$reviewer_a_fallback_succeeded" == false ]]; then
                echo -e "${YELLOW}Reviewer A remains unavailable after opposite-engine fallback, continuing with B only${NC}"
            elif [[ "$exit_ra" -ne 0 ]]; then
                echo -e "${YELLOW}Reviewer A unavailable (exit $exit_ra; no usable review artifact), continuing with B only${NC}"
            else
                echo -e "${YELLOW}Reviewer A produced no usable review artifact, continuing with B only${NC}"
            fi
        elif [[ "$reviewer_a_fallback_succeeded" != true && "$exit_ra" -ne 0 ]]; then
            echo -e "${YELLOW}Reviewer A exited $exit_ra but produced a usable review artifact${NC}"
        fi

        if [[ "$has_review_b" == false ]]; then
            if [[ "$reviewer_b_fallback_attempted" == true && "$reviewer_b_fallback_succeeded" == false ]]; then
                echo -e "${YELLOW}Reviewer B remains unavailable after opposite-engine fallback, continuing with A only${NC}"
            elif [[ "$exit_rb" -ne 0 ]]; then
                echo -e "${YELLOW}Reviewer B unavailable (exit $exit_rb; no usable review artifact), continuing with A only${NC}"
            else
                echo -e "${YELLOW}Reviewer B produced no usable review artifact, continuing with A only${NC}"
            fi
        elif [[ "$reviewer_b_fallback_succeeded" != true && "$exit_rb" -ne 0 ]]; then
            echo -e "${YELLOW}Reviewer B exited $exit_rb but produced a usable review artifact${NC}"
        fi

        [[ "$has_review_a" == true ]] || rm -f "${comp_dir}/reviewer-a.raw.md"
        [[ "$has_review_b" == true ]] || rm -f "${comp_dir}/reviewer-b.raw.md"

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
            _fail_phase \
                "reviewing" \
                "Phase 5: Failed to snapshot per-cycle review artifacts" \
                "Check review-a.md, review-b.md, and .review-mapping, then retry the review snapshot step" \
                "invalid_artifact" \
                "phase=phase-5; step=_snapshot_review_cycle_artifacts; cycle=$((fix_cycle + 1))" || true
            _print_cost_summary
            return 1
        }

        # Single-reviewer policy gate
        if [[ "$has_review_a" != "$has_review_b" ]]; then
            if [[ "$LAUREN_LOOP_STRICT" == "true" ]]; then
                echo -e "${YELLOW}Single reviewer available with explicit strict mode — halting for human review${NC}"
                set_task_status "$task_file" "needs verification"
                log_execution "$task_file" "Phase 5: Single reviewer halt (explicit_strict=${LAUREN_LOOP_STRICT}, diff_risk=${_diff_risk:-LOW})"
                _write_human_review_handoff "SINGLE_REVIEWER" "$fix_cycle" || true
                pipeline_finished=true
                pipeline_human_review_halt=true
                break
            else
                echo -e "${YELLOW}WARN: Single reviewer available; explicit strict mode not set — continuing to synthesis${NC}"
                log_execution "$task_file" "Phase 5: WARN — single reviewer continuing to synthesis (explicit_strict=${LAUREN_LOOP_STRICT}, diff_risk=${_diff_risk:-LOW})"
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
                    _append_review_blinding_metadata "$effective_reviewer_a_engine" "$effective_reviewer_b_engine"
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
        _FAIL_PHASE_PHASE_ID="phase-6a"
        _FAIL_PHASE_PHASE_NAME="review-eval-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase6_start"
        _update_run_manifest_state "phase-6a" "$_diff_risk" "$_effective_reviewer_timeout" || true
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 6: Review evaluation started (cycle $((fix_cycle + 1)))"

        local review_evaluator_role="review-evaluator${role_suffix}"
        local review_inputs=""
        [[ -f "${comp_dir}/review-a.md" ]] && review_inputs="${review_inputs}- ${comp_dir}/review-a.md"$'\n'
        [[ -f "${comp_dir}/review-b.md" ]] && review_inputs="${review_inputs}- ${comp_dir}/review-b.md"$'\n'
        local review_eval_instruction="The task file is ${task_file}. Read ${comp_dir}/exploration-summary.md and the available review inputs:
${review_inputs}Synthesize only the review files that exist and write the result to ${comp_dir}/review-synthesis.md."
        # TODO: refine error_class if Phase 6 prompt assembly failures split into stable categories.
        local _requested_review_evaluator_engine="$ENGINE_EVALUATOR"
        local _effective_review_evaluator_engine="$ENGINE_EVALUATOR"
        _resolve_effective_engine "$_requested_review_evaluator_engine"
        _effective_review_evaluator_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_review_evaluator_engine" "$_effective_review_evaluator_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "phase-6 review synthesis"
            _v2_append_codex_circuit_breaker_skip "phase-6a" "review-eval-cycle-$((fix_cycle+1))" "$_phase6_start" "phase-6-review-synthesis"
        fi
        prepare_agent_request "$_effective_review_evaluator_engine" "$review_evaluator_prompt" "$review_eval_instruction" || {
            _fail_phase "evaluating-reviews" "Failed to assemble review evaluator prompt" "Check ${comp_dir}/review-a.md and ${comp_dir}/review-b.md for review content. Agent log: ${log_dir}/${review_evaluator_role}.log" \
                "unknown" "role=review-evaluator; step=prepare_agent_request"
        }

        local exit_review_eval=0
        rm -f "${comp_dir}/review-synthesis.contract.json"
        run_agent "$review_evaluator_role" "$_effective_review_evaluator_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "${comp_dir}/review-synthesis.md" "${log_dir}/${review_evaluator_role}.log" \
            "$SYNTHESIZE_TIMEOUT" "100" || exit_review_eval=$?
        if [[ "$_effective_review_evaluator_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_review_evaluator_engine" "$exit_review_eval"
        fi

        if [[ "$exit_review_eval" -ne 0 ]]; then
            local review_eval_error_class=""
            local review_eval_error_message=""
            review_eval_error_class=$(_classify_agent_exit_error_class "$_effective_review_evaluator_engine" "$exit_review_eval" "${log_dir}/${review_evaluator_role}.log")
            if [[ "$exit_review_eval" -eq 124 ]]; then
                review_eval_error_message="Phase 6: Review evaluation timed out (${SYNTHESIZE_TIMEOUT})"
            else
                review_eval_error_message="Phase 6: Review evaluation FAILED (exit $exit_review_eval)"
            fi
            _fail_phase \
                "evaluating-reviews" \
                "$review_eval_error_message" \
                "Check ${log_dir}/${review_evaluator_role}.log and retry the review evaluation step" \
                "$review_eval_error_class" \
                "role=${review_evaluator_role}; engine=${_effective_review_evaluator_engine}; exit_code=${exit_review_eval}; log=${log_dir}/${review_evaluator_role}.log" || true
            _print_cost_summary
            return 1
        fi
        _require_valid_artifact \
            "${comp_dir}/review-synthesis.md" \
            "evaluating-reviews" \
            "Phase 6 review evaluation produced an invalid synthesis artifact" \
            "Check ${comp_dir}/review-a.md and ${comp_dir}/review-b.md, then inspect agent log ${log_dir}/${review_evaluator_role}.log" || return 1
        _append_review_blinding_metadata "$effective_reviewer_a_engine" "$effective_reviewer_b_engine"
        log_execution "$task_file" "Phase 5: Review randomization completed"

        local review_verdict=""
        review_verdict=$(_parse_contract "${comp_dir}/review-synthesis.md" "verdict")
        if [[ -z "$review_verdict" ]]; then
            _fail_phase \
                "evaluating-reviews" \
                "Phase 6 review evaluation produced no verdict" \
                "Check ${comp_dir}/review-synthesis.md and review-synthesis.contract.json, then retry" \
                "invalid_artifact" \
                "artifact=${comp_dir}/review-synthesis.contract.json; field=verdict; value=empty" || true
            _print_cost_summary
            return 1
        fi
        log_execution "$task_file" "Phase 6: Review verdict ${review_verdict}"

        if [[ "$review_verdict" == "PASS" ]]; then
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Pipeline complete: review synthesis PASS"
            _append_manifest_phase "phase-6a" "review-eval-cycle-$((fix_cycle+1))" "$_phase6_start" "$(_iso_timestamp)" "completed" "PASS" || true
            pipeline_finished=true
            pipeline_success=true
            break
        fi

        if [[ "$review_verdict" != "CONDITIONAL" && "$review_verdict" != "FAIL" ]]; then
            _fail_phase \
                "evaluating-reviews" \
                "Unexpected review verdict: $review_verdict" \
                "Check ${comp_dir}/review-synthesis.md and review-synthesis.contract.json, then retry" \
                "invalid_artifact" \
                "artifact=${comp_dir}/review-synthesis.contract.json; field=verdict; value=${review_verdict}" || true
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
        _FAIL_PHASE_PHASE_ID="phase-6b"
        _FAIL_PHASE_PHASE_NAME="fix-plan-author-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase6b_start"
        _update_run_manifest_state "phase-6b" "$_diff_risk" "$_effective_reviewer_timeout" || true
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
        local _requested_fix_plan_author_engine="$ENGINE_EVALUATOR"
        local _effective_fix_plan_author_engine="$ENGINE_EVALUATOR"
        _resolve_effective_engine "$_requested_fix_plan_author_engine"
        _effective_fix_plan_author_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_fix_plan_author_engine" "$_effective_fix_plan_author_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "phase-6 fix-plan author"
            _v2_append_codex_circuit_breaker_skip "phase-6b" "fix-plan-author-cycle-$((fix_cycle+1))" "$_phase6b_start" "phase-6-fix-plan-author"
        fi
        prepare_agent_request "$_effective_fix_plan_author_engine" "$fix_plan_author_prompt" "$fix_plan_instruction" || {
            _fail_phase "authoring-fix-plan" "Failed to assemble fix-plan-author prompt" "Check ${comp_dir}/review-synthesis.md for synthesis verdict. Agent log: ${log_dir}/${fix_plan_author_role}.log" \
                "unknown" "role=fix-plan-author; step=prepare_agent_request"
        }

        local exit_fix_plan=0
        rm -f "${comp_dir}/fix-plan.contract.json"
        run_agent "$fix_plan_author_role" "$_effective_fix_plan_author_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "${comp_dir}/fix-plan.md" "${log_dir}/${fix_plan_author_role}.log" \
            "$EVALUATE_TIMEOUT" "100" || exit_fix_plan=$?
        if [[ "$_effective_fix_plan_author_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_fix_plan_author_engine" "$exit_fix_plan"
        fi

        if [[ "$exit_fix_plan" -ne 0 ]]; then
            local fix_plan_error_class=""
            local fix_plan_error_message=""
            fix_plan_error_class=$(_classify_agent_exit_error_class "$_effective_fix_plan_author_engine" "$exit_fix_plan" "${log_dir}/${fix_plan_author_role}.log")
            if [[ "$exit_fix_plan" -eq 124 ]]; then
                fix_plan_error_message="Phase 6: Fix plan author timed out (${EVALUATE_TIMEOUT})"
            else
                fix_plan_error_message="Phase 6: Fix plan author FAILED (exit $exit_fix_plan)"
            fi
            _fail_phase \
                "authoring-fix-plan" \
                "$fix_plan_error_message" \
                "Check ${log_dir}/${fix_plan_author_role}.log and retry the fix-plan authoring step" \
                "$fix_plan_error_class" \
                "role=${fix_plan_author_role}; engine=${_effective_fix_plan_author_engine}; exit_code=${exit_fix_plan}; log=${log_dir}/${fix_plan_author_role}.log" || true
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
            _fail_phase \
                "authoring-fix-plan" \
                "Strict mode requires fix-plan.contract.json ready=true|false" \
                "Check ${comp_dir}/fix-plan.md and fix-plan.contract.json, then retry" \
                "invalid_artifact" \
                "artifact=${comp_dir}/fix-plan.contract.json; field=ready; value=${fix_plan_ready:-empty}" || true
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
        _FAIL_PHASE_PHASE_ID="phase-6c"
        _FAIL_PHASE_PHASE_NAME="fix-plan-critic-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase6c_start"
        _update_run_manifest_state "phase-6c" "$_diff_risk" "$_effective_reviewer_timeout" || true
        local _requested_fix_critic_engine="$ENGINE_CRITIC"
        local _effective_fix_critic_engine="$ENGINE_CRITIC"
        _resolve_effective_engine "$_requested_fix_critic_engine"
        _effective_fix_critic_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_fix_critic_engine" "$_effective_fix_critic_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "$fix_critic_prefix"
            _v2_append_codex_circuit_breaker_skip "phase-6c" "fix-plan-critic-cycle-$((fix_cycle+1))" "$_phase6c_start" "$fix_critic_prefix"
        fi
        run_critic_loop "$task_file" "$comp_dir" "$critic_prompt" "$reviser_prompt" "${comp_dir}/fix-plan.md" "${comp_dir}/fix-critique.md" 3 "$fix_critic_prefix" "needs verification" "$_effective_fix_critic_engine" || fix_critic_result=$?
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
        _FAIL_PHASE_PHASE_ID="phase-7"
        _FAIL_PHASE_PHASE_NAME="fix-exec-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase7_start"
        _update_run_manifest_state "phase-7" "$_diff_risk" "$_effective_reviewer_timeout" || true
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
        # TODO: refine error_class for Phase 7 setup failures if git/worktree helpers return structured causes.
        if ! _normalize_verify_tags_with_timeout_in_file "${comp_dir}/fix-plan.md" "V2 phase 7 fix plan"; then
            _fail_phase "executing-fixes" "Failed to wrap repo-standard pytest verification commands in fix-plan.md" "Check ${comp_dir}/fix-plan.md for verify tag formatting drift, then retry" \
                "unknown" "artifact=${comp_dir}/fix-plan.md; step=normalize_verify_tags"
            return 1
        fi
        if ! _validate_verify_commands_in_file "${comp_dir}/fix-plan.md" "V2 phase 7 fix plan"; then
            _fail_phase "executing-fixes" "Invalid verify commands found in fix-plan.md" "Check ${comp_dir}/fix-plan.md for bad verify commands, then retry" \
                "unknown" "artifact=${comp_dir}/fix-plan.md; step=validate_verify_commands"
            return 1
        fi
        # Create isolated worktree for fix execution
        _v2_create_execution_worktree || {
            _fail_phase "executing-fixes" "Failed to create fix execution worktree" "Check disk space and git state" \
                "unknown" "step=_v2_create_execution_worktree"
            return 1
        }
        _v2_capture_preexisting_pipeline_owned_root_dirty "$pre_fix_dirty"
        _v2_stage_execution_runtime_task_file "$task_file" || {
            _fail_phase "executing-fixes" "Failed to stage runtime task file into worktree" "Check worktree path permissions and task artifacts, then retry" \
                "unknown" "artifact=${task_file}; step=_v2_stage_execution_runtime_task_file"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        _v2_stage_execution_worktree_files "${comp_dir}/review-synthesis.md" "${comp_dir}/fix-plan.md" || {
            _fail_phase "executing-fixes" "Failed to stage fix context into worktree" "Check worktree path permissions and fix artifacts, then retry" \
                "unknown" "artifacts=${comp_dir}/review-synthesis.md,${comp_dir}/fix-plan.md; step=_v2_stage_execution_worktree_files"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        if [[ -f "${comp_dir}/fix-execution.md" ]]; then
            _v2_stage_execution_worktree_file "${comp_dir}/fix-execution.md" || {
                _fail_phase "executing-fixes" "Failed to stage fix execution log into worktree" "Check worktree path permissions and fix artifacts, then retry" \
                    "unknown" "artifact=${comp_dir}/fix-execution.md; step=_v2_stage_execution_worktree_file"
                _v2_save_worktree_diff || true
                _v2_cleanup_execution_worktree || true
                return 1
            }
        fi
        # Pre-stage baseline diff if worktree is missing expected changes
        _v2_prestage_baseline_diff_if_missing "$comp_dir" || {
            log_execution "$task_file" "Phase 7: WARN — baseline diff pre-staging failed; fix-executor may report BLOCKED"
        }
        local fix_task_rel=""
        local fix_review_rel=""
        local fix_plan_rel=""
        local fix_execution_rel=""
        local pre_fix_execution_bytes=0
        local post_fix_execution_bytes=0
        local fix_execution_activity="false"
        local fix_execution_worktree_path=""
        local fix_execution_contract_worktree_path=""
        pre_fix_execution_bytes=$(_v2_file_size_bytes "${comp_dir}/fix-execution.md")
        fix_task_rel=$(_v2_execution_runtime_task_rel_path)
        fix_review_rel=$(_v2_main_repo_relative_path "${comp_dir}/review-synthesis.md") || {
            _fail_phase "executing-fixes" "Failed to resolve worktree-local review synthesis path" "Check fix artifact location, then retry" \
                "unknown" "artifact=${comp_dir}/review-synthesis.md; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        fix_plan_rel=$(_v2_main_repo_relative_path "${comp_dir}/fix-plan.md") || {
            _fail_phase "executing-fixes" "Failed to resolve worktree-local fix plan path" "Check fix artifact location, then retry" \
                "unknown" "artifact=${comp_dir}/fix-plan.md; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        fix_execution_rel=$(_v2_main_repo_relative_path "${comp_dir}/fix-execution.md") || {
            _fail_phase "executing-fixes" "Failed to resolve worktree-local fix execution path" "Check fix artifact location, then retry" \
                "unknown" "artifact=${comp_dir}/fix-execution.md; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        fix_execution_worktree_path=$(_v2_execution_worktree_path_for "${comp_dir}/fix-execution.md") || {
            _fail_phase "executing-fixes" "Failed to resolve worktree-local fix execution path" "Check fix artifact location, then retry" \
                "unknown" "artifact=${comp_dir}/fix-execution.md; step=_v2_execution_worktree_path_for"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        fix_execution_contract_worktree_path=$(_v2_execution_worktree_path_for "${comp_dir}/fix-execution.contract.json") || {
            _fail_phase "executing-fixes" "Failed to resolve worktree-local fix execution contract path" "Check fix artifact location, then retry" \
                "unknown" "artifact=${comp_dir}/fix-execution.contract.json; step=_v2_execution_worktree_path_for"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        local fix_exec_instruction="The task file is ${fix_task_rel}. Your project root is the current working directory (${_V2_EXEC_WORKTREE_PATH}). Read ${fix_review_rel} and ${fix_plan_rel}. Execute the planned fixes and write execution progress to ${fix_execution_rel}. All repo file reads and writes must stay inside the current working directory. Do not use absolute paths under ${SCRIPT_DIR}. If any verification command exits 124, append 'BLOCKED: $(_verification_timeout_message) - <command>' and stop immediately."
        local _requested_fix_executor_engine="$ENGINE_FIX"
        local _effective_fix_executor_engine="$ENGINE_FIX"
        _resolve_effective_engine "$_requested_fix_executor_engine"
        _effective_fix_executor_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_fix_executor_engine" "$_effective_fix_executor_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "$fix_executor_role"
            _v2_append_codex_circuit_breaker_skip "phase-7" "$fix_executor_role" "$_phase7_start" "$fix_executor_role"
        fi
        prepare_agent_request "$_effective_fix_executor_engine" "$fix_executor_prompt" "$fix_exec_instruction" || {
            _fail_phase "executing-fixes" "Failed to assemble fix-executor prompt" "See ${comp_dir}/fix-execution.md for blocking issues. Address manually, then retry" \
                "unknown" "role=fix-executor; step=prepare_agent_request"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        cd "$_V2_EXEC_WORKTREE_PATH"

        local exit_fix_exec=0
        local pre_fix_timeout_blocks=0
        local post_fix_timeout_blocks=0
        local fix_timeout_block_detected=false
        local phase7_handoff_status_file=""
        local phase7_handoff_status=""
        local phase7_handoff_poll_pid=""
        local fix_execution_read_path=""
        rm -f "${comp_dir}/fix-execution.contract.json"
        pre_fix_timeout_blocks=$(_timeout_block_count_in_file "${comp_dir}/fix-execution.md")
        touch "${log_dir}/${fix_executor_role}.log"
        phase7_handoff_status_file=$(mktemp "${TMPDIR:-/tmp}/lauren-loop-phase7-handoff.XXXXXX") || {
            _fail_phase "executing-fixes" "Failed to create Phase 7 handoff tracker" "Check tmpdir permissions, then retry" \
                "unknown" "step=mktemp_phase7_handoff_status_file"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        start_agent_monitor "${log_dir}/${fix_executor_role}.log" "$task_file"
        run_agent "$fix_executor_role" "$_effective_fix_executor_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "/dev/null" "${log_dir}/${fix_executor_role}.log" \
            "$EXECUTOR_TIMEOUT" "300" "WebFetch,WebSearch" &
        local pid_fix_exec=$!
        _phase7_poll_fix_execution_handoff "$comp_dir" "$pid_fix_exec" "$phase7_handoff_status_file" \
            "${log_dir}/${fix_executor_role}.log" &
        phase7_handoff_poll_pid=$!
        wait "$pid_fix_exec" || exit_fix_exec=$?
        phase7_handoff_status=$(tr -d '[:space:]' < "$phase7_handoff_status_file" 2>/dev/null || true)
        if [[ -n "$phase7_handoff_poll_pid" ]]; then
            if [[ -n "$phase7_handoff_status" ]]; then
                wait "$phase7_handoff_poll_pid" 2>/dev/null || true
            else
                kill "$phase7_handoff_poll_pid" 2>/dev/null || true
                wait "$phase7_handoff_poll_pid" 2>/dev/null || true
            fi
        fi
        stop_agent_monitor
        if [[ "$_effective_fix_executor_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_fix_executor_engine" "$exit_fix_exec"
        fi
        rm -f "$phase7_handoff_status_file"
        fix_execution_read_path=$(_v2_execution_worktree_read_path_for "${comp_dir}/fix-execution.md")
        post_fix_timeout_blocks=$(_timeout_block_count_in_file "$fix_execution_read_path")
        post_fix_execution_bytes=$(_v2_file_size_bytes "$fix_execution_read_path")
        if [[ "${post_fix_execution_bytes:-0}" -gt "${pre_fix_execution_bytes:-0}" ]]; then
            fix_execution_activity="true"
        fi
        if [[ "${post_fix_timeout_blocks:-0}" -gt "${pre_fix_timeout_blocks:-0}" ]]; then
            fix_timeout_block_detected=true
            printf '{"status":"BLOCKED"}\n' > "$fix_execution_contract_worktree_path"
            echo -e "${YELLOW}$(_verification_timeout_message)${NC}"
            log_execution "$task_file" "Phase 7: $(_verification_timeout_message)"
        fi

        # Signal: fix executor STATUS: BLOCKED
        local fix_exec_status=""
        if [[ "$fix_timeout_block_detected" == true ]]; then
            fix_exec_status="BLOCKED"
        elif [[ -n "$phase7_handoff_status" ]]; then
            fix_exec_status="$phase7_handoff_status"
        else
            fix_exec_status=$(_phase7_read_status_signal "${comp_dir}/fix-execution.md")
        fi
        local fix_exec_status_upper=""
        fix_exec_status_upper=$(echo "$fix_exec_status" | tr '[:lower:]' '[:upper:]')
        if _strict_contract_mode && [[ "$fix_exec_status_upper" != "COMPLETE" && "$fix_exec_status_upper" != "BLOCKED" && "$fix_exec_status_upper" != "FAILED" ]]; then
            _fail_phase \
                "executing-fixes" \
                "Strict mode requires fix-execution.contract.json status=COMPLETE|BLOCKED|FAILED" \
                "Check ${comp_dir}/fix-execution.md and fix-execution.contract.json, then retry" \
                "invalid_artifact" \
                "artifact=${comp_dir}/fix-execution.contract.json; field=status; value=${fix_exec_status:-empty}" || true
            _phase7_sync_fix_execution_artifacts "$comp_dir" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi
        if [[ "$fix_exec_status_upper" == "BLOCKED" ]]; then
            local phase7_blocked_completed_at=""
            local phase7_blocked_cost=""
            local phase7_blocked_error_class="unknown"
            local phase7_blocked_recovery_json="null"
            phase7_blocked_completed_at=$(_iso_timestamp)
            phase7_blocked_cost=$(_manifest_phase_measured_cost)
            if [[ "$fix_timeout_block_detected" == true ]]; then
                phase7_blocked_error_class="timeout"
            fi
            echo -e "${YELLOW}Fix executor signaled BLOCKED — halting for human review${NC}"
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Phase 7: Fix executor STATUS: BLOCKED — human review required"
            _write_human_review_handoff "BLOCKED" "$((fix_cycle + 1))" || true
            _mark_fix_execution_handoff "$fix_execution_worktree_path" || true
            # Sync human-facing artifacts back for human review without merging partial code.
            cd "$SCRIPT_DIR"
            _v2_finalize_halt_without_merge "${comp_dir}/fix-execution.md" "${comp_dir}/fix-execution.contract.json" || true
            # TODO: refine error_class when non-timeout Phase 7 BLOCKED signals split into stable categories.
            _append_manifest_phase \
                "${_FAIL_PHASE_PHASE_ID:-phase-7}" \
                "${_FAIL_PHASE_PHASE_NAME:-fix-exec-cycle-$((fix_cycle + 1))}" \
                "${_FAIL_PHASE_PHASE_STARTED_AT:-$phase7_blocked_completed_at}" \
                "$phase7_blocked_completed_at" \
                "failed" \
                "" \
                "$phase7_blocked_cost" \
                "$phase7_blocked_error_class" \
                "status_signal=BLOCKED; timeout_block_detected=${fix_timeout_block_detected}; handoff_status=${phase7_handoff_status:-none}" \
                "$phase7_blocked_recovery_json" || true
            pipeline_finished=true
            pipeline_human_review_halt=true
            break
        fi
        if [[ "$fix_exec_status_upper" == "FAILED" ]]; then
            _fail_phase \
                "executing-fixes" \
                "Phase 7: Fix executor STATUS: FAILED" \
                "Check ${comp_dir}/fix-execution.md and fix-execution.contract.json, then retry" \
                "invalid_artifact" \
                "status_signal=FAILED; handoff_status=${phase7_handoff_status:-none}" || true
            _phase7_sync_fix_execution_artifacts "$comp_dir" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi

        if [[ "$phase7_handoff_status" == "COMPLETE" ]]; then
            exit_fix_exec=0
            log_execution "$task_file" "Phase 7: Early handoff detected from worktree fix-execution.contract.json (STATUS: COMPLETE)"
        fi

        if [[ "$exit_fix_exec" -ne 0 ]]; then
            local fix_exec_error_class=""
            local fix_exec_error_message=""
            fix_exec_error_class=$(_classify_agent_exit_error_class "$_effective_fix_executor_engine" "$exit_fix_exec" "${log_dir}/${fix_executor_role}.log")
            if [[ "$exit_fix_exec" -eq 124 ]]; then
                fix_exec_error_message="Phase 7: Fix execution timed out (${EXECUTOR_TIMEOUT})"
            else
                fix_exec_error_message="Phase 7: Fix execution FAILED (exit $exit_fix_exec)"
            fi
            _fail_phase \
                "executing-fixes" \
                "$fix_exec_error_message" \
                "Check ${log_dir}/${fix_executor_role}.log and retry the fix execution step" \
                "$fix_exec_error_class" \
                "role=${fix_executor_role}; engine=${_effective_fix_executor_engine}; exit_code=${exit_fix_exec}; log=${log_dir}/${fix_executor_role}.log" || true
            _phase7_sync_fix_execution_artifacts "$comp_dir" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi

        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 7: Fix execution completed"

        # Capture diff inside the worktree (isolated from other pipelines)
        latest_fix_diff="${comp_dir}/fix-diff-cycle$((fix_cycle + 1)).patch"
        local phase7_scope_plan_file=""
        phase7_scope_plan_file=$(_v2_select_phase7_scope_plan_file "$comp_dir")
        if [[ -n "$phase7_scope_plan_file" ]]; then
            log_execution "$task_file" "Phase 7: Scope plan file: ${phase7_scope_plan_file}" || true
        else
            log_execution "$task_file" "Phase 7: Scope plan file: fallback only" || true
        fi
        capture_diff_artifact "$pre_fix_sha" "$latest_fix_diff" "$task_file" "$phase7_scope_plan_file" "$pre_fix_dirty"
        _v2_refresh_traditional_dev_proxy_artifacts \
            "$task_file" \
            "$pre_fix_sha" \
            "$latest_fix_diff" \
            "${_V2_LAST_CAPTURE_SCOPE_PATHS:-}" \
            "${_V2_LAST_CAPTURE_SCOPE_SOURCE:-}" \
            "$pre_fix_dirty" \
            "$((fix_cycle + 1))"
        _v2_log_capture_scope_details "$task_file" "Phase 7"
        if [[ ! -s "$latest_fix_diff" ]]; then
            _log_diagnostic_lines "$task_file" "$(_v2_phase_execution_diagnostic_lines "$fix_execution_activity" "$fix_execution_read_path" "$latest_fix_diff")"
            if _strict_contract_mode; then
                local phase7_strict_empty_diff_message=""
                if [[ "$fix_execution_activity" == "true" ]]; then
                    echo -e "${RED}Fix execution activity detected but execution worktree is clean${NC}"
                    log_execution "$task_file" "Phase 7: Fix execution activity detected but execution worktree is clean — suspected out-of-worktree write or non-persisted fix change"
                    phase7_strict_empty_diff_message="Phase 7: Fix execution activity detected but execution worktree is clean — suspected out-of-worktree write or non-persisted fix change"
                else
                    echo -e "${RED}Strict mode requires a non-empty fix execution diff${NC}"
                    log_execution "$task_file" "Phase 7: Strict mode blocked empty fix execution diff"
                    phase7_strict_empty_diff_message="Phase 7: Strict mode blocked empty fix execution diff"
                fi
                _fail_phase \
                    "executing-fixes" \
                    "$phase7_strict_empty_diff_message" \
                    "Inspect ${comp_dir}/fix-execution.md and the phase-7 scope plan, then retry after keeping fix writes in scope" \
                    "scope_violation" \
                    "phase=phase-7; strict_mode=true; activity_detected=${fix_execution_activity}; diff=${latest_fix_diff}" || true
                _phase7_sync_fix_execution_artifacts "$comp_dir" || true
                _print_cost_summary
                _v2_save_worktree_diff || true
                _v2_cleanup_execution_worktree || true
                return 1
            fi
            if [[ "$fix_execution_activity" == "true" ]]; then
                local phase7_clean_worktree_completed_at=""
                local phase7_clean_worktree_cost=""
                phase7_clean_worktree_completed_at=$(_iso_timestamp)
                phase7_clean_worktree_cost=$(_manifest_phase_measured_cost)
                _append_manifest_phase \
                    "${_FAIL_PHASE_PHASE_ID:-phase-7}" \
                    "${_FAIL_PHASE_PHASE_NAME:-fix-exec-cycle-$((fix_cycle + 1))}" \
                    "${_FAIL_PHASE_PHASE_STARTED_AT:-$phase7_clean_worktree_completed_at}" \
                    "$phase7_clean_worktree_completed_at" \
                    "failed" \
                    "" \
                    "$phase7_clean_worktree_cost" \
                    "scope_violation" \
                    "phase=phase-7; activity_detected=true; worktree=clean; diff=${latest_fix_diff}" || true
                echo -e "${RED}Phase 7: Fix execution activity detected but worktree is clean — halting (suspected out-of-worktree write)${NC}"
                log_execution "$task_file" "Phase 7: HALTED — fix execution activity detected but execution worktree is clean after cycle $((fix_cycle + 1)). Suspected out-of-worktree write or non-persisted fix change."
                set_task_status "$task_file" "needs verification"
                _write_human_review_handoff "BLOCKED" "$((fix_cycle + 1))" || true
                _mark_fix_execution_handoff "$fix_execution_worktree_path" || true
                cd "$SCRIPT_DIR"
                _v2_finalize_halt_without_merge "${comp_dir}/fix-execution.md" "${comp_dir}/fix-execution.contract.json" || true
                pipeline_finished=true
                pipeline_human_review_halt=true
                break
            else
                echo -e "${YELLOW}WARN: Fix execution diff is empty after cycle $((fix_cycle + 1))${NC}"
                log_execution "$task_file" "Phase 7: Fix execution diff captured but empty"
            fi
        else
            log_execution "$task_file" "Phase 7: Fix execution diff captured at ${latest_fix_diff}"
        fi

        _v2_log_out_of_scope_capture_warning "$task_file" "Phase 7" || true
        _block_on_untracked_files "$task_file" "Phase 7" "$phase7_scope_plan_file" "$pre_fix_sha" "$pre_fix_untracked" || {
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }

        # Merge worktree changes back to the main branch
        cd "$SCRIPT_DIR"
        local phase7_merge_branch=""
        phase7_merge_branch=$(_v2_execution_merge_branch_label)
        _v2_merge_execution_worktree "${comp_dir}/fix-execution.md" "${comp_dir}/fix-execution.contract.json" || {
            _fail_phase "executing-fixes" "Failed to merge fix execution worktree" "Check for merge conflicts; resolve manually then retry" \
                "merge_failure" "phase=phase-7; step=_v2_merge_execution_worktree; branch=${phase7_merge_branch}"
            _v2_cleanup_after_failed_merge true
            return 1
        }

        _append_manifest_phase "phase-7" "fix-exec-cycle-$((fix_cycle+1))" "${_phase7_start:-$(_iso_timestamp)}" "$(_iso_timestamp)" "completed" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-7" || true
        set_task_status "$task_file" "needs verification"
        log_execution "$task_file" "Pipeline complete: Phase 7 fix execution merged successfully"
        _phase8_round="initial"
        needs_phase8c=false
        _phase8_cumulative_diff=$(git diff --stat "$_PIPELINE_PRE_SHA"..HEAD)
        _phase8_changed_files=$(git diff --name-only "$_PIPELINE_PRE_SHA"..HEAD)
        _resume_to_subphase="phase-8a"
        fi  # end Phase 7 skip guard

        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" == phase-8* ]] && [[ -z "$_phase8_cumulative_diff" && -z "$_phase8_changed_files" ]]; then
            _phase8_cumulative_diff=$(git diff --stat "$_PIPELINE_PRE_SHA"..HEAD)
            _phase8_changed_files=$(git diff --name-only "$_PIPELINE_PRE_SHA"..HEAD)
        fi
        if [[ "$_phase8_round" == "initial" ]] && [[ "$_resume_to_subphase" == "phase-8a" ]] && [[ -z "$_phase8_cumulative_diff" && -z "$_phase8_changed_files" ]]; then
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Phase 8: empty cumulative diff, skipping verification"
            pipeline_finished=true
            pipeline_success=true
            fix_cycle=$((fix_cycle + 1))
            break
        fi

        # -- Sub-phase: Phase 8a (final verify) --
        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" != "phase-8a" ]]; then
            echo -e "${BLUE}Phase 8a: Skipped (resuming to ${_resume_to_subphase})${NC}"
        else
        _resume_to_subphase=""
        local _phase8a_start=""
        _phase8a_start=$(_iso_timestamp)
        echo -e "${BLUE}=== Phase 8a: Final Verify (${_phase8_round}, cycle $((fix_cycle + 1))) ===${NC}"
        _FAIL_PHASE_PHASE_ID="phase-8a"
        _FAIL_PHASE_PHASE_NAME="final-verify-${_phase8_round}-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase8a_start"
        _update_run_manifest_state "phase-8a" "$_diff_risk" "$_effective_reviewer_timeout" || true
        cost_gate_result=0
        _check_cost_ceiling "$task_file" "$comp_dir" "$fix_cycle" || cost_gate_result=$?
        case "$cost_gate_result" in
            0) ;;
            1)
                pipeline_finished=true
                pipeline_human_review_halt=true
                fix_cycle=$((fix_cycle + 1))
                break
                ;;
            *)
                set_task_status "$task_file" "blocked"
                _print_cost_summary
                return 1
                ;;
        esac
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 8a: Final verify started (${_phase8_round}, cycle $((fix_cycle + 1)))"

        local _requested_final_verify_engine="$ENGINE_FINAL_VERIFY"
        local _effective_final_verify_engine="$ENGINE_FINAL_VERIFY"
        _resolve_effective_engine "$_requested_final_verify_engine"
        _effective_final_verify_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_final_verify_engine" "$_effective_final_verify_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "phase-8a final-verify"
            _v2_append_codex_circuit_breaker_skip "phase-8a" "final-verify-${_phase8_round}-cycle-$((fix_cycle+1))" "$_phase8a_start" "phase-8a-final-verify"
        fi
        local _phase8_verify_diff="${_phase8_cumulative_diff:-<empty cumulative diff>}"
        local _phase8_verify_changed="${_phase8_changed_files:-<no changed files>}"
        local phase8_verify_instruction="The task file is ${task_file}. Treat competitive/ as a sibling of that task file.
Phase 8 round: ${_phase8_round}.
Cumulative diff (${_PIPELINE_PRE_SHA}..HEAD):
${_phase8_verify_diff}

Changed files:
${_phase8_verify_changed}

Write the verification artifact to ${comp_dir}/final-verify.md and the contract sidecar to ${comp_dir}/final-verify.contract.json."
        prepare_agent_request "$_effective_final_verify_engine" "$final_verify_prompt" "$phase8_verify_instruction" || {
            _fail_phase "verifying-final" "Failed to assemble final-verifier prompt" "Check ${comp_dir}/final-verify.md and ${log_dir}/final-verify.log, then retry" \
                "unknown" "role=final-verify; step=prepare_agent_request"
            _print_cost_summary
            return 1
        }

        local phase8_verify_role="final-verify${role_suffix}"
        local exit_phase8a=0
        rm -f "${comp_dir}/final-verify.contract.json"
        run_agent "$phase8_verify_role" "$_effective_final_verify_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "${comp_dir}/final-verify.md" "${log_dir}/final-verify.log" \
            "$_effective_reviewer_timeout" "100" || exit_phase8a=$?
        if [[ "$_effective_final_verify_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_final_verify_engine" "$exit_phase8a"
        fi

        if [[ "$exit_phase8a" -ne 0 ]]; then
            local phase8a_error_class=""
            local phase8a_error_message=""
            phase8a_error_class=$(_classify_agent_exit_error_class "$_effective_final_verify_engine" "$exit_phase8a" "${log_dir}/final-verify.log")
            if [[ "$exit_phase8a" -eq 124 ]]; then
                phase8a_error_message="Phase 8a: Final verifier timed out (${_effective_reviewer_timeout})"
            else
                phase8a_error_message="Phase 8a: Final verifier FAILED (exit $exit_phase8a)"
            fi
            _fail_phase \
                "verifying-final" \
                "$phase8a_error_message" \
                "Check ${log_dir}/final-verify.log and retry the final verifier step" \
                "$phase8a_error_class" \
                "role=${phase8_verify_role}; engine=${_effective_final_verify_engine}; exit_code=${exit_phase8a}; log=${log_dir}/final-verify.log" || true
            _print_cost_summary
            return 1
        fi
        _require_valid_artifact \
            "${comp_dir}/final-verify.md" \
            "verifying-final" \
            "Phase 8a final verifier produced an invalid verification artifact" \
            "Check ${comp_dir}/final-verify.md and ${log_dir}/final-verify.log, then retry" || return 1

        local _phase8_verdict=""
        _phase8_verdict=$(_parse_contract "${comp_dir}/final-verify.md" "verdict")
        if [[ "$_phase8_verdict" != "PASS" && "$_phase8_verdict" != "FAIL" && "$_phase8_verdict" != "BLOCKED" ]]; then
            _fail_phase \
                "verifying-final" \
                "Phase 8a: final-verifier contract verdict must be PASS|FAIL|BLOCKED" \
                "Check ${comp_dir}/final-verify.md and final-verify.contract.json, then retry" \
                "invalid_artifact" \
                "artifact=${comp_dir}/final-verify.contract.json; field=verdict; value=${_phase8_verdict:-empty}" || true
            _print_cost_summary
            return 1
        fi

        _append_manifest_phase "phase-8a" "final-verify-${_phase8_round}-cycle-$((fix_cycle+1))" "$_phase8a_start" "$(_iso_timestamp)" "completed" "$_phase8_verdict" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-8a" "" "$_phase8_round" "$_phase8_verdict" || true
        if [[ "$_phase8_verdict" == "PASS" ]]; then
            log_execution "$task_file" "Phase 8a: Final verify PASS (${_phase8_round})"
        elif [[ "$_phase8_round" == "initial" && "$_phase8_verdict" == "FAIL" ]]; then
            log_execution "$task_file" "Phase 8a: Final verify ${_phase8_verdict} (${_phase8_round}) — routing to final fix"
            needs_phase8c=true
            _resume_to_subphase="phase-8c"
            _phase8c_source_phase="phase-8a"
        else
            set_task_status "$task_file" "needs verification"
            if ! _write_phase8_human_review_handoff "phase-8a"; then
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Pipeline FAILED while human-review-handoff: Failed to write Phase 8 handoff artifacts"
                _print_cost_summary
                return 1
            fi
            log_execution "$task_file" "Phase 8a: Final verify ${_phase8_verdict} (${_phase8_round}) — human review required"
            pipeline_human_review_halt=true
            pipeline_finished=true
            fix_cycle=$((fix_cycle + 1))
            break
        fi
        fi  # end Phase 8a skip guard

        # -- Sub-phase: Phase 8b (final falsify) --
        if [[ -n "$_resume_to_subphase" ]] && [[ "$_resume_to_subphase" != "phase-8b" ]]; then
            echo -e "${BLUE}Phase 8b: Skipped (resuming to ${_resume_to_subphase})${NC}"
        else
        _resume_to_subphase=""
        local _phase8b_start=""
        _phase8b_start=$(_iso_timestamp)
        echo -e "${BLUE}=== Phase 8b: Final Falsify (${_phase8_round}, cycle $((fix_cycle + 1))) ===${NC}"
        _FAIL_PHASE_PHASE_ID="phase-8b"
        _FAIL_PHASE_PHASE_NAME="final-falsify-${_phase8_round}-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase8b_start"
        _update_run_manifest_state "phase-8b" "$_diff_risk" "$_effective_reviewer_timeout" || true
        cost_gate_result=0
        _check_cost_ceiling "$task_file" "$comp_dir" "$fix_cycle" || cost_gate_result=$?
        case "$cost_gate_result" in
            0) ;;
            1)
                pipeline_finished=true
                pipeline_human_review_halt=true
                fix_cycle=$((fix_cycle + 1))
                break
                ;;
            *)
                set_task_status "$task_file" "blocked"
                _print_cost_summary
                return 1
                ;;
        esac
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 8b: Final falsify started (${_phase8_round}, cycle $((fix_cycle + 1)))"

        local _requested_final_falsify_engine="$ENGINE_FINAL_FALSIFY"
        local _effective_final_falsify_engine="$ENGINE_FINAL_FALSIFY"
        _resolve_effective_engine "$_requested_final_falsify_engine"
        _effective_final_falsify_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_final_falsify_engine" "$_effective_final_falsify_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "phase-8b final-falsify"
            _v2_append_codex_circuit_breaker_skip "phase-8b" "final-falsify-${_phase8_round}-cycle-$((fix_cycle+1))" "$_phase8b_start" "phase-8b-final-falsify"
        fi
        local _phase8_falsify_diff="${_phase8_cumulative_diff:-<empty cumulative diff>}"
        local _phase8_falsify_changed="${_phase8_changed_files:-<no changed files>}"
        local phase8_falsify_instruction="The task file is ${task_file}. Treat competitive/ as a sibling of that task file.
Phase 8 round: ${_phase8_round}.
Read competitive/final-verify.md and competitive/final-verify.contract.json before writing any tests.
Cumulative diff (${_PIPELINE_PRE_SHA}..HEAD):
${_phase8_falsify_diff}

Changed files:
${_phase8_falsify_changed}

Write the falsification artifact to ${comp_dir}/final-falsify.md and the contract sidecar to ${comp_dir}/final-falsify.contract.json."
        prepare_agent_request "$_effective_final_falsify_engine" "$final_falsify_prompt" "$phase8_falsify_instruction" || {
            _fail_phase "falsifying-final" "Failed to assemble final-falsifier prompt" "Check ${comp_dir}/final-falsify.md and ${log_dir}/final-falsify.log, then retry" \
                "unknown" "role=final-falsify; step=prepare_agent_request"
            _print_cost_summary
            return 1
        }

        local phase8_falsify_role="final-falsify${role_suffix}"
        local exit_phase8b=0
        rm -f "${comp_dir}/final-falsify.contract.json"
        run_agent "$phase8_falsify_role" "$_effective_final_falsify_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "${comp_dir}/final-falsify.md" "${log_dir}/final-falsify.log" \
            "$_effective_reviewer_timeout" "100" || exit_phase8b=$?
        if [[ "$_effective_final_falsify_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_final_falsify_engine" "$exit_phase8b"
        fi

        if [[ "$exit_phase8b" -ne 0 ]]; then
            local phase8b_error_class=""
            local phase8b_error_message=""
            phase8b_error_class=$(_classify_agent_exit_error_class "$_effective_final_falsify_engine" "$exit_phase8b" "${log_dir}/final-falsify.log")
            if [[ "$exit_phase8b" -eq 124 ]]; then
                phase8b_error_message="Phase 8b: Final falsifier timed out (${_effective_reviewer_timeout})"
            else
                phase8b_error_message="Phase 8b: Final falsifier FAILED (exit $exit_phase8b)"
            fi
            _fail_phase \
                "falsifying-final" \
                "$phase8b_error_message" \
                "Check ${log_dir}/final-falsify.log and retry the final falsifier step" \
                "$phase8b_error_class" \
                "role=${phase8_falsify_role}; engine=${_effective_final_falsify_engine}; exit_code=${exit_phase8b}; log=${log_dir}/final-falsify.log" || true
            _print_cost_summary
            return 1
        fi
        _require_valid_artifact \
            "${comp_dir}/final-falsify.md" \
            "falsifying-final" \
            "Phase 8b final falsifier produced an invalid falsification artifact" \
            "Check ${comp_dir}/final-falsify.md and ${log_dir}/final-falsify.log, then retry" || return 1

        local _phase8_falsify_verdict=""
        _phase8_falsify_verdict=$(_parse_contract "${comp_dir}/final-falsify.md" "verdict")
        if [[ "$_phase8_falsify_verdict" != "PASS" && "$_phase8_falsify_verdict" != "FAIL" && "$_phase8_falsify_verdict" != "BLOCKED" ]]; then
            _fail_phase \
                "falsifying-final" \
                "Phase 8b: final-falsify contract verdict must be PASS|FAIL|BLOCKED" \
                "Check ${comp_dir}/final-falsify.md and final-falsify.contract.json, then retry" \
                "invalid_artifact" \
                "artifact=${comp_dir}/final-falsify.contract.json; field=verdict; value=${_phase8_falsify_verdict:-empty}" || true
            _print_cost_summary
            return 1
        fi

        _append_manifest_phase "phase-8b" "final-falsify-${_phase8_round}-cycle-$((fix_cycle+1))" "$_phase8b_start" "$(_iso_timestamp)" "completed" "$_phase8_falsify_verdict" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-8b" "" "$_phase8_round" "$_phase8_falsify_verdict" || true
        if [[ "$_phase8_falsify_verdict" == "PASS" ]]; then
            set_task_status "$task_file" "needs verification"
            log_execution "$task_file" "Phase 8b: Final falsify PASS (${_phase8_round}) — pipeline success"
            pipeline_finished=true
            pipeline_success=true
            fix_cycle=$((fix_cycle + 1))
            break
        elif [[ "$_phase8_round" == "initial" && "$_phase8_falsify_verdict" == "FAIL" ]]; then
            log_execution "$task_file" "Phase 8b: Final falsify ${_phase8_falsify_verdict} (${_phase8_round}) — routing to final fix"
            needs_phase8c=true
            _resume_to_subphase="phase-8c"
            _phase8c_source_phase="phase-8b"
        else
            set_task_status "$task_file" "needs verification"
            if ! _write_phase8_human_review_handoff "phase-8b"; then
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Pipeline FAILED while human-review-handoff: Failed to write Phase 8 handoff artifacts"
                _print_cost_summary
                return 1
            fi
            log_execution "$task_file" "Phase 8b: Final falsify ${_phase8_falsify_verdict} (${_phase8_round}) — human review required"
            pipeline_human_review_halt=true
            pipeline_finished=true
            fix_cycle=$((fix_cycle + 1))
            break
        fi
        fi  # end Phase 8b skip guard

        # -- Sub-phase: Phase 8c (final fix) --
        if [[ "$needs_phase8c" == true ]]; then
        _resume_to_subphase=""
        local _phase8c_start=""
        local _phase8c_predecessor="${_phase8c_source_phase:-${CYCLE_STATE_LAST_COMPLETED:-}}"
        local _phase8c_route_label=""
        local _phase8c_requires_falsify=false
        local _phase8c_required_input=""
        local _phase8c_stage_artifacts_detail=""
        local -a _phase8c_required_inputs=()
        _phase8c_start=$(_iso_timestamp)
        echo -e "${BLUE}=== Phase 8c: Final Fix (cycle $((fix_cycle + 1))) ===${NC}"
        _FAIL_PHASE_PHASE_ID="phase-8c"
        _FAIL_PHASE_PHASE_NAME="final-fix-cycle-$((fix_cycle + 1))"
        _FAIL_PHASE_PHASE_STARTED_AT="$_phase8c_start"
        _update_run_manifest_state "phase-8c" "$_diff_risk" "$_effective_reviewer_timeout" || true
        cost_gate_result=0
        _check_cost_ceiling "$task_file" "$comp_dir" "$fix_cycle" || cost_gate_result=$?
        case "$cost_gate_result" in
            0) ;;
            1)
                pipeline_finished=true
                pipeline_human_review_halt=true
                fix_cycle=$((fix_cycle + 1))
                break
                ;;
            *)
                set_task_status "$task_file" "blocked"
                _print_cost_summary
                return 1
                ;;
        esac
        _phase8c_route_label=$(_phase8c_route_label "$_phase8c_predecessor") || {
            _fail_phase "executing-final-fix" \
                "Unsupported Phase 8c predecessor: ${_phase8c_predecessor:-unknown}" \
                "Check the Phase 8 checkpoint state and rerun the required predecessor phase before retrying" \
                "invalid_artifact" \
                "predecessor=${_phase8c_predecessor:-unknown}; step=phase8c_route_selection"
            return 1
        }
        if _phase8c_route_requires_falsify "$_phase8c_predecessor"; then
            _phase8c_requires_falsify=true
        fi
        while IFS= read -r _phase8c_required_input; do
            [[ -n "$_phase8c_required_input" ]] || continue
            _phase8c_required_inputs+=("$_phase8c_required_input")
        done < <(_phase8c_route_required_inputs "$comp_dir" "$_phase8c_predecessor")
        if [[ "${#_phase8c_required_inputs[@]}" -eq 0 ]]; then
            _fail_phase "executing-final-fix" \
                "Phase 8c could not resolve required route inputs" \
                "Check the Phase 8 checkpoint state and rerun the required predecessor phase before retrying" \
                "invalid_artifact" \
                "predecessor=${_phase8c_predecessor:-unknown}; step=phase8c_route_required_inputs"
            return 1
        fi
        set_task_status "$task_file" "in progress"
        log_execution "$task_file" "Phase 8c: Final fix started (cycle $((fix_cycle + 1)))"
        _phase8c_stage_artifacts_detail="artifacts=${task_file}"
        for _phase8c_required_input in "${_phase8c_required_inputs[@]}"; do
            _phase8c_stage_artifacts_detail="${_phase8c_stage_artifacts_detail},${_phase8c_required_input}"
        done
        _phase8c_required_input=$(_phase8c_route_first_missing_input "$comp_dir" "$_phase8c_predecessor" || true)
        if [[ -n "$_phase8c_required_input" ]]; then
            _fail_phase "executing-final-fix" \
                "Phase 8c missing required input artifact: $(basename "$_phase8c_required_input")" \
                "Re-run the required predecessor phase or restore the missing artifact, then retry" \
                "invalid_artifact" \
                "artifact=${_phase8c_required_input}; route=${_phase8c_predecessor}; step=phase8c_input_ready"
            return 1
        fi

        if [[ -f "${comp_dir}/final-verify.md" ]] && [[ ! -f "${comp_dir}/final-verify.initial.md" ]]; then
            cp "${comp_dir}/final-verify.md" "${comp_dir}/final-verify.initial.md" || {
                _fail_phase "executing-final-fix" "Failed to snapshot final-verify.md" "Check competitive artifacts and retry" \
                    "unknown" "artifact=${comp_dir}/final-verify.initial.md; step=snapshot_final_verify"
                return 1
            }
        fi
        if [[ -f "${comp_dir}/final-verify.contract.json" ]] && [[ ! -f "${comp_dir}/final-verify.initial.contract.json" ]]; then
            cp "${comp_dir}/final-verify.contract.json" "${comp_dir}/final-verify.initial.contract.json" || {
                _fail_phase "executing-final-fix" "Failed to snapshot final-verify.contract.json" "Check competitive artifacts and retry" \
                    "unknown" "artifact=${comp_dir}/final-verify.initial.contract.json; step=snapshot_final_verify_contract"
                return 1
            }
        fi
        if [[ -f "${comp_dir}/final-falsify.md" ]] && [[ ! -f "${comp_dir}/final-falsify.initial.md" ]]; then
            cp "${comp_dir}/final-falsify.md" "${comp_dir}/final-falsify.initial.md" || {
                _fail_phase "executing-final-fix" "Failed to snapshot final-falsify.md" "Check competitive artifacts and retry" \
                    "unknown" "artifact=${comp_dir}/final-falsify.initial.md; step=snapshot_final_falsify"
                return 1
            }
        fi
        if [[ -f "${comp_dir}/final-falsify.contract.json" ]] && [[ ! -f "${comp_dir}/final-falsify.initial.contract.json" ]]; then
            cp "${comp_dir}/final-falsify.contract.json" "${comp_dir}/final-falsify.initial.contract.json" || {
                _fail_phase "executing-final-fix" "Failed to snapshot final-falsify.contract.json" "Check competitive artifacts and retry" \
                    "unknown" "artifact=${comp_dir}/final-falsify.initial.contract.json; step=snapshot_final_falsify_contract"
                return 1
            }
        fi

        _v2_create_execution_worktree || {
            _fail_phase "executing-final-fix" "Failed to create final-fix execution worktree" "Check disk space and git state" \
                "unknown" "step=_v2_create_execution_worktree"
            return 1
        }
        _v2_capture_preexisting_pipeline_owned_root_dirty
        _v2_stage_execution_runtime_task_file "$task_file" || {
            _fail_phase "executing-final-fix" "Failed to stage runtime task file into worktree" "Check worktree path permissions and retry" \
                "unknown" "artifact=${task_file}; step=_v2_stage_execution_runtime_task_file"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        _v2_stage_execution_worktree_files \
            "$task_file" \
            "${_phase8c_required_inputs[@]}" || {
            _fail_phase "executing-final-fix" "Failed to stage final verification artifacts into worktree" "Check worktree path permissions and retry" \
                "unknown" "${_phase8c_stage_artifacts_detail}; step=_v2_stage_execution_worktree_files"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }

        local _requested_final_fix_engine="$ENGINE_FINAL_FIX"
        local _effective_final_fix_engine="$ENGINE_FINAL_FIX"
        _resolve_effective_engine "$_requested_final_fix_engine"
        _effective_final_fix_engine="$_V2_EFFECTIVE_ENGINE"
        if _v2_engine_resolution_skipped_codex "$_requested_final_fix_engine" "$_effective_final_fix_engine"; then
            _v2_log_codex_circuit_breaker_trip "$task_file" "phase-8c final-fix"
            _v2_append_codex_circuit_breaker_skip "phase-8c" "final-fix-cycle-$((fix_cycle+1))" "$_phase8c_start" "phase-8c-final-fix"
        fi

        local final_fix_task_rel=""
        local final_fix_runtime_task_rel=""
        local final_fix_verify_rel=""
        local final_fix_verify_contract_rel=""
        local final_fix_falsify_rel=""
        local final_fix_falsify_contract_rel=""
        local final_fix_artifact_rel=""
        local final_fix_contract_rel=""
        local final_fix_worktree_path=""
        local final_fix_contract_worktree_path=""
        final_fix_task_rel=$(_v2_main_repo_relative_path "$task_file") || {
            _fail_phase "executing-final-fix" "Failed to resolve worktree-local task path" "Check task artifact location and retry" \
                "unknown" "artifact=${task_file}; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        final_fix_runtime_task_rel=$(_v2_execution_runtime_task_rel_path)
        final_fix_verify_rel=$(_v2_main_repo_relative_path "${comp_dir}/final-verify.md") || {
            _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-verify artifact path" "Check task artifact location and retry" \
                "unknown" "artifact=${comp_dir}/final-verify.md; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        final_fix_verify_contract_rel=$(_v2_main_repo_relative_path "${comp_dir}/final-verify.contract.json") || {
            _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-verify contract path" "Check task artifact location and retry" \
                "unknown" "artifact=${comp_dir}/final-verify.contract.json; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        if [[ "$_phase8c_requires_falsify" == true ]]; then
            final_fix_falsify_rel=$(_v2_main_repo_relative_path "${comp_dir}/final-falsify.md") || {
                _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-falsify artifact path" "Check task artifact location and retry" \
                    "unknown" "artifact=${comp_dir}/final-falsify.md; step=_v2_main_repo_relative_path"
                _v2_save_worktree_diff || true
                _v2_cleanup_execution_worktree || true
                return 1
            }
            final_fix_falsify_contract_rel=$(_v2_main_repo_relative_path "${comp_dir}/final-falsify.contract.json") || {
                _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-falsify contract path" "Check task artifact location and retry" \
                    "unknown" "artifact=${comp_dir}/final-falsify.contract.json; step=_v2_main_repo_relative_path"
                _v2_save_worktree_diff || true
                _v2_cleanup_execution_worktree || true
                return 1
            }
        fi
        final_fix_artifact_rel=$(_v2_main_repo_relative_path "${comp_dir}/final-fix.md") || {
            _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-fix artifact path" "Check task artifact location and retry" \
                "unknown" "artifact=${comp_dir}/final-fix.md; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        final_fix_contract_rel=$(_v2_main_repo_relative_path "${comp_dir}/final-fix.contract.json") || {
            _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-fix contract path" "Check task artifact location and retry" \
                "unknown" "artifact=${comp_dir}/final-fix.contract.json; step=_v2_main_repo_relative_path"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        final_fix_worktree_path=$(_v2_execution_worktree_path_for "${comp_dir}/final-fix.md") || {
            _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-fix artifact path" "Check task artifact location and retry" \
                "unknown" "artifact=${comp_dir}/final-fix.md; step=_v2_execution_worktree_path_for"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        final_fix_contract_worktree_path=$(_v2_execution_worktree_path_for "${comp_dir}/final-fix.contract.json") || {
            _fail_phase "executing-final-fix" "Failed to resolve worktree-local final-fix contract path" "Check task artifact location and retry" \
                "unknown" "artifact=${comp_dir}/final-fix.contract.json; step=_v2_execution_worktree_path_for"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }

        local phase8_fix_input_instruction=""
        phase8_fix_input_instruction=$(_phase8c_final_fix_input_instruction \
            "$final_fix_verify_rel" \
            "$final_fix_verify_contract_rel" \
            "$_phase8c_predecessor" \
            "$final_fix_falsify_rel" \
            "$final_fix_falsify_contract_rel") || {
            _fail_phase "executing-final-fix" "Failed to assemble final-fixer input instruction" "Check Phase 8 route metadata and retry" \
                "invalid_artifact" "predecessor=${_phase8c_predecessor:-unknown}; step=phase8c_final_fix_input_instruction"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }
        local phase8_fix_instruction="The task file is ${final_fix_task_rel}. A runtime-staged copy is available at ${final_fix_runtime_task_rel}; use the canonical task path so competitive/ resolves as a sibling directory.
This Phase 8c run entered from ${_phase8c_route_label}.
Your project root is the current working directory (${_V2_EXEC_WORKTREE_PATH}).
${phase8_fix_input_instruction}
Write the final fix artifact to ${final_fix_artifact_rel} and the contract sidecar to ${final_fix_contract_rel}.
All repo file reads and writes must stay inside the current working directory. Do not use absolute paths under ${SCRIPT_DIR}."
        prepare_agent_request "$_effective_final_fix_engine" "$final_fix_prompt" "$phase8_fix_instruction" || {
            _fail_phase "executing-final-fix" "Failed to assemble final-fixer prompt" "Check ${log_dir}/final-fix.log and retry the final-fix step" \
                "unknown" "role=final-fix; step=prepare_agent_request"
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }

        cd "$_V2_EXEC_WORKTREE_PATH"

        local phase8_fix_role="final-fix${role_suffix}"
        local exit_phase8c=0
        rm -f "$final_fix_artifact_rel" "$final_fix_contract_rel"
        run_agent "$phase8_fix_role" "$_effective_final_fix_engine" "$AGENT_PROMPT_BODY" "$AGENT_SYSTEM_PROMPT" \
            "/dev/null" "${log_dir}/final-fix.log" \
            "$PHASE8C_TIMEOUT" "300" "WebFetch,WebSearch" || exit_phase8c=$?
        if [[ "$_effective_final_fix_engine" == "codex" ]]; then
            _v2_record_codex_outcome "$_effective_final_fix_engine" "$exit_phase8c"
        fi

        if [[ "$exit_phase8c" -ne 0 ]]; then
            local phase8c_error_class=""
            local phase8c_error_message=""
            phase8c_error_class=$(_classify_agent_exit_error_class "$_effective_final_fix_engine" "$exit_phase8c" "${log_dir}/final-fix.log")
            if [[ "$exit_phase8c" -eq 124 ]]; then
                phase8c_error_message="Phase 8c: Final fix timed out (${PHASE8C_TIMEOUT})"
            else
                phase8c_error_message="Phase 8c: Final fix FAILED (exit $exit_phase8c)"
            fi
            _fail_phase \
                "executing-final-fix" \
                "$phase8c_error_message" \
                "Check ${log_dir}/final-fix.log and retry the final-fix step" \
                "$phase8c_error_class" \
                "role=${phase8_fix_role}; engine=${_effective_final_fix_engine}; exit_code=${exit_phase8c}; log=${log_dir}/final-fix.log" || true
            _v2_sync_execution_worktree_files "${comp_dir}/final-fix.md" "${comp_dir}/final-fix.contract.json" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi

        cd "$SCRIPT_DIR"
        _require_valid_artifact \
            "$final_fix_worktree_path" \
            "executing-final-fix" \
            "Phase 8c final-fix produced an invalid final-fix artifact" \
            "Check ${comp_dir}/final-fix.md and ${log_dir}/final-fix.log, then retry" || {
            _v2_sync_execution_worktree_files "${comp_dir}/final-fix.md" "${comp_dir}/final-fix.contract.json" || true
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        }

        local phase8_fix_status=""
        local phase8_requires_reverification=""
        phase8_fix_status=$(_parse_contract "$final_fix_worktree_path" "status")
        phase8_requires_reverification=$(_parse_contract "$final_fix_worktree_path" "requires_reverification")
        if [[ "$phase8_fix_status" != "COMPLETE" && "$phase8_fix_status" != "BLOCKED" ]]; then
            _fail_phase \
                "executing-final-fix" \
                "Phase 8c: final-fix contract status must be COMPLETE|BLOCKED" \
                "Check ${comp_dir}/final-fix.md and final-fix.contract.json, then retry" \
                "invalid_artifact" \
                "artifact=${comp_dir}/final-fix.contract.json; field=status; value=${phase8_fix_status:-empty}" || true
            _v2_sync_execution_worktree_files "${comp_dir}/final-fix.md" "${comp_dir}/final-fix.contract.json" || true
            _print_cost_summary
            _v2_save_worktree_diff || true
            _v2_cleanup_execution_worktree || true
            return 1
        fi
        if [[ "$phase8_fix_status" == "COMPLETE" ]] && [[ "$phase8_requires_reverification" != "true" ]]; then
            echo -e "${YELLOW}WARN: Phase 8c COMPLETE without requires_reverification=true${NC}"
            log_execution "$task_file" "Phase 8c: WARNING final-fix reported COMPLETE without requires_reverification=true"
        fi

        if [[ "$phase8_fix_status" == "BLOCKED" ]]; then
            local phase8c_blocked_completed_at=""
            local phase8c_blocked_cost=""
            local phase8c_blocked_recovery_json="null"
            phase8c_blocked_completed_at=$(_iso_timestamp)
            phase8c_blocked_cost=$(_manifest_phase_measured_cost)
            _write_cycle_state "$comp_dir" "$fix_cycle" "phase-8c" "" "initial" "BLOCKED" || true
            echo -e "${YELLOW}Phase 8c: Final fixer signaled BLOCKED — halting for human review${NC}"
            cd "$SCRIPT_DIR"
            _v2_finalize_halt_without_merge "${comp_dir}/final-fix.md" "${comp_dir}/final-fix.contract.json" || true
            _append_manifest_phase \
                "${_FAIL_PHASE_PHASE_ID:-phase-8c}" \
                "${_FAIL_PHASE_PHASE_NAME:-final-fix-cycle-$((fix_cycle + 1))}" \
                "${_FAIL_PHASE_PHASE_STARTED_AT:-$phase8c_blocked_completed_at}" \
                "$phase8c_blocked_completed_at" \
                "failed" \
                "" \
                "$phase8c_blocked_cost" \
                "blocked" \
                "status_signal=BLOCKED; requires_reverification=${phase8_requires_reverification:-empty}" \
                "$phase8c_blocked_recovery_json" || true
            set_task_status "$task_file" "needs verification"
            if ! _write_phase8_human_review_handoff "phase-8c"; then
                set_task_status "$task_file" "blocked"
                log_execution "$task_file" "Pipeline FAILED while human-review-handoff: Failed to write Phase 8 handoff artifacts"
                _print_cost_summary
                return 1
            fi
            log_execution "$task_file" "Phase 8c: Final fix STATUS: BLOCKED — human review required"
            pipeline_human_review_halt=true
            pipeline_finished=true
            fix_cycle=$((fix_cycle + 1))
            break
        fi

        cd "$SCRIPT_DIR"
        local phase8c_merge_branch=""
        phase8c_merge_branch=$(_v2_execution_merge_branch_label)
        _v2_merge_execution_worktree "${comp_dir}/final-fix.md" "${comp_dir}/final-fix.contract.json" || {
            _fail_phase "executing-final-fix" "Failed to merge final-fix execution worktree" "Check for merge conflicts; resolve manually then retry" \
                "merge_failure" "phase=phase-8c; step=_v2_merge_execution_worktree; branch=${phase8c_merge_branch}"
            _v2_cleanup_after_failed_merge true
            return 1
        }

        _append_manifest_phase "phase-8c" "final-fix-cycle-$((fix_cycle+1))" "$_phase8c_start" "$(_iso_timestamp)" "completed" "COMPLETE" || true
        _write_cycle_state "$comp_dir" "$fix_cycle" "phase-8c" "" "post-fix" "COMPLETE" || true
        log_execution "$task_file" "Phase 8c: Final fix COMPLETE — starting post-fix re-verification"
        _phase8_round="post-fix"
        needs_phase8c=false
        _phase8_cumulative_diff=$(git diff --stat "$_PIPELINE_PRE_SHA"..HEAD)
        _phase8_changed_files=$(git diff --name-only "$_PIPELINE_PRE_SHA"..HEAD)
        _resume_to_subphase="phase-8a"
        continue
        fi  # end Phase 8c guard

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
        finalize_v2_task_metadata "$task_file" "pipeline-complete" "success" "$fix_cycle" || true
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
        finalize_v2_task_metadata "$task_file" "human-review-halt" "human_review" "$fix_cycle" || true
        notify_terminal_state "human-review" "Human review needed — ${slug}" || true
        echo -e "${YELLOW}=== Competitive pipeline halted for human review ===${NC}"
    else
        set_task_status "$task_file" "blocked" || true
        finalize_v2_task_metadata "$task_file" "pipeline-blocked" "blocked" "$fix_cycle" || true
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

    VERIFY_PROMPT="$SCRIPT_DIR/prompts/verifier.md"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1
    TASK_DIR=$(_v2_task_dir_for_task_file "$TASK_FILE") || TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"
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

    CHAOS_PROMPT="$SCRIPT_DIR/prompts/chaos-critic.md"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1
    TASK_DIR=$(_v2_task_dir_for_task_file "$TASK_FILE") || TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"
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

    STATE_FILE="$SCRIPT_DIR/.planning/${SLUG}.json"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1
    TASK_DIR=$(_v2_task_dir_for_task_file "$TASK_FILE") || TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"

    CURRENT_STATUS=$(grep '^## Status:' "$TASK_FILE" | head -1 | sed 's/^## Status: //')
    GOAL_TEXT=$(_verify_extract_goal "$TASK_FILE")

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

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1
    TASK_DIR=$(_v2_task_dir_for_task_file "$TASK_FILE") || TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"

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

    STATE_FILE="$SCRIPT_DIR/.planning/${SLUG}.json"

    TASK_FILE="$(_require_v2_task_file "$SLUG")" || exit 1
    TASK_DIR=$(_v2_task_dir_for_task_file "$TASK_FILE") || TASK_DIR="$(_v2_task_artifact_dir "$SLUG")"

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

if [[ "$DRY_RUN" != "true" ]] && { [[ -n "${CLAUDE_CODE_USE_FOUNDRY:-}" ]] || [[ -z "${ANTHROPIC_BASE_URL:-}" ]] || [[ -z "${ANTHROPIC_API_KEY:-}" ]]; }; then
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
    echo "    Success exit: stop after a successful Phase 7 merge; otherwise halt for human review or failure"
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
        "scope-triage:$SCRIPT_DIR/prompts/scope-triage.md" \
        "reviewer-a:$SCRIPT_DIR/prompts/reviewer.md" \
        "reviewer-b:$SCRIPT_DIR/prompts/reviewer-b.md" \
        "review-evaluator:$SCRIPT_DIR/prompts/review-evaluator.md" \
        "fix-plan-author:$SCRIPT_DIR/prompts/fix-plan-author.md" \
        "fix-executor:$SCRIPT_DIR/prompts/fix-executor.md" \
        "final-verify:$SCRIPT_DIR/prompts/final-verifier.md" \
        "final-falsify:$SCRIPT_DIR/prompts/final-falsifier.md" \
        "final-fix:$SCRIPT_DIR/prompts/final-fixer.md"; do
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

_v2_direct_summary() {
    local slug="$1"
    local task_file="" cost="" trad_proxy="" duration="" display_duration=""

    task_file=$(_require_v2_task_file "$slug" 2>/dev/null) || task_file=""
    cost=$(read_v2_total_cost "$slug")

    if [[ -n "$task_file" ]]; then
        trad_proxy=$(read_persisted_v2_traditional_dev_proxy_summary "$task_file" 2>/dev/null) || trad_proxy=""
    fi
    [[ -z "$trad_proxy" ]] && trad_proxy="N/A"

    duration=$(( $(date +%s) - ${_PIPELINE_START_TS:-$(date +%s)} ))
    [[ "$duration" -lt 0 ]] && duration=0
    display_duration=$(format_auto_duration "$duration")

    echo ""
    echo -e "${BLUE}=============================================="
    echo "     Auto Route Summary"
    echo -e "==============================================${NC}"
    echo ""
    echo "  Pipeline: V2 (direct)"
    echo "  Duration: ${display_duration}"
    echo "  Cost:     ${cost}"
    echo "  Traditional Dev Proxy: ${trad_proxy}"
}

acquire_lock
_oc_rc=0
lauren_loop_competitive "$SLUG" "$GOAL" || _oc_rc=$?
if [[ "$_oc_rc" -ne 0 ]]; then
    notify_terminal_state "blocked" "Pipeline blocked — ${SLUG}" || true
    exit "$_oc_rc"
fi

# Print summary when launched directly (v1 wrapper prints its own summary)
if [[ "${_LAUREN_LOOP_AUTO_WRAPPER:-}" != "1" ]]; then
    _v2_direct_summary "$SLUG"
fi

#!/bin/bash
# lib/lauren-loop-utils.sh — Shared utility functions for lauren-loop.sh and lauren-loop-v2.sh
# Sourced (not executed). Expects caller to set: SCRIPT_DIR, color vars (RED, GREEN, YELLOW, BLUE, NC).
# Uses only a minimal helper-state global (_NOTIFIED), plus functions. No traps, no exit calls.

_NOTIFIED="${_NOTIFIED:-0}"
LAUREN_LOOP_UTILS_DIR="${LAUREN_LOOP_UTILS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

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

_duration_to_seconds() {
    local duration="$1"
    case "$duration" in
        *m) printf '%s\n' $(( ${duration%m} * 60 )) ;;
        *h) printf '%s\n' $(( ${duration%h} * 3600 )) ;;
        *s) printf '%s\n' "${duration%s}" ;;
        *)  printf '%s\n' "$duration" ;;
    esac
}

_agent_poll_interval_seconds() {
    printf '%s\n' "${LAUREN_LOOP_AGENT_POLL_INTERVAL_SEC:-5}"
}

_agent_terminate_grace_seconds() {
    printf '%s\n' "${LAUREN_LOOP_AGENT_KILL_GRACE_SEC:-5}"
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

_verification_timeout_message() {
    printf '%s\n' "Verification timed out after 20m"
}

_should_enforce_task_file_content_gate() {
    local dry_run="${1:-false}"
    local resume_flag="${2:-false}"
    local resume_hint="${3:-${_LAUREN_LOOP_RESUME_HINT:-0}}"
    local v1_auto_wrapper="${4:-${_LAUREN_LOOP_V1_AUTO_WRAPPER:-0}}"

    [[ "$dry_run" == "true" ]] && return 1
    [[ "$resume_flag" == "true" ]] && return 1
    case "$v1_auto_wrapper" in
        1|true|TRUE|yes|YES) return 1 ;;
    esac
    case "$resume_hint" in
        1|true|TRUE|yes|YES) return 1 ;;
    esac
    return 0
}

_trim_nonblank_lines() {
    awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "") {
                lines[++count] = line
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                printf "%s", lines[i]
                if (i < count) {
                    printf "\n"
                }
            }
        }
    '
}

_trim_joined_text() {
    awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line != "") {
                lines[++count] = line
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                printf "%s", lines[i]
                if (i < count) {
                    printf " "
                }
            }
        }
    '
}

_task_workflow_canonical_header() {
    case "$1" in
        left_off) printf '## Left Off At\n' ;;
        attempts) printf '## Attempts\n' ;;
        *)
            echo "Unknown workflow section key: $1" >&2
            return 1
            ;;
    esac
}

_task_workflow_legacy_header() {
    case "$1" in
        left_off) printf '## Left Off At:\n' ;;
        attempts) printf '## Attempts:\n' ;;
        *)
            echo "Unknown workflow section key: $1" >&2
            return 1
            ;;
    esac
}

_task_workflow_variant_pattern() {
    local key="$1"
    local variant="$2"

    case "$key:$variant" in
        left_off:canonical) printf '^## Left Off At[[:space:]]*$\n' ;;
        left_off:legacy) printf '^## Left Off At:[[:space:]]*$\n' ;;
        attempts:canonical) printf '^## Attempts[[:space:]]*$\n' ;;
        attempts:legacy) printf '^## Attempts:[[:space:]]*$\n' ;;
        *)
            echo "Unknown workflow section variant: ${key}:${variant}" >&2
            return 1
            ;;
    esac
}

_task_workflow_pattern() {
    case "$1" in
        left_off) printf '^## Left Off At:?[[:space:]]*$\n' ;;
        attempts) printf '^## Attempts:?[[:space:]]*$\n' ;;
        *)
            echo "Unknown workflow section key: $1" >&2
            return 1
            ;;
    esac
}

_task_workflow_default_body() {
    case "$1" in
        left_off) printf 'Not started.\n' ;;
        attempts) printf '(none yet)\n' ;;
        *)
            echo "Unknown workflow section key: $1" >&2
            return 1
            ;;
    esac
}

_task_workflow_count_matches() {
    printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '
}

_task_workflow_variant_count() {
    local task_file="$1"
    local key="$2"
    local variant="$3"
    local pattern

    pattern=$(_task_workflow_variant_pattern "$key" "$variant") || return 1
    awk -v pattern="$pattern" '$0 ~ pattern { count++ } END { print count + 0 }' "$task_file"
}

_task_workflow_section_matches() {
    local task_file="$1"
    local key="$2"
    local pattern

    pattern=$(_task_workflow_pattern "$key") || return 1
    awk -v pattern="$pattern" '$0 ~ pattern { print NR }' "$task_file"
}

_task_workflow_count() {
    local task_file="$1"
    local key="$2"
    local matches

    matches=$(_task_workflow_section_matches "$task_file" "$key") || return 1
    _task_workflow_count_matches "$matches"
}

_task_workflow_first_line() {
    local task_file="$1"
    local key="$2"
    local pattern

    pattern=$(_task_workflow_pattern "$key") || return 1
    awk -v pattern="$pattern" '$0 ~ pattern { print NR; exit }' "$task_file"
}

_task_workflow_first_line_for_variant() {
    local task_file="$1"
    local key="$2"
    local variant="$3"
    local pattern

    pattern=$(_task_workflow_variant_pattern "$key" "$variant") || return 1
    awk -v pattern="$pattern" '$0 ~ pattern { print NR; exit }' "$task_file"
}

_task_workflow_bounds_at_line() {
    local task_file="$1"
    local start="$2"
    local end

    end=$(awk -v start="$start" 'NR > start && /^## / { print NR; exit }' "$task_file")
    if [ -z "$end" ]; then
        end=$(( $(wc -l < "$task_file") + 1 ))
    fi

    printf '%s %s\n' "$start" "$end"
}

_task_workflow_bounds() {
    local task_file="$1"
    local key="$2"
    local count start header

    count=$(_task_workflow_count "$task_file" "$key") || return 1
    header=$(_task_workflow_canonical_header "$key") || return 1
    if [ "$count" -ne 1 ]; then
        echo "Expected exactly one logical section: $header" >&2
        return 1
    fi

    start=$(_task_workflow_first_line "$task_file" "$key")
    [ -n "$start" ] || {
        echo "Expected exactly one logical section: $header" >&2
        return 1
    }

    _task_workflow_bounds_at_line "$task_file" "$start"
}

_task_workflow_body() {
    local task_file="$1"
    local key="$2"
    local start end

    read -r start end < <(_task_workflow_bounds "$task_file" "$key") || return 1
    if [ $((end - start)) -le 1 ]; then
        return 0
    fi

    sed -n "$((start + 1)),$((end - 1))p" "$task_file"
}

_task_workflow_attempt_line_is_placeholder() {
    local line="$1"
    local trimmed=""

    trimmed=$(printf '%s\n' "$line" | _trim_nonblank_lines)
    [[ -z "$trimmed" ]] && return 0

    case "$trimmed" in
        "(none yet)"|"(none)")
            return 0
            ;;
    esac

    if printf '%s\n' "$trimmed" | grep -Fq 'what was tried' && \
        printf '%s\n' "$trimmed" | grep -Fq 'result (worked/failed/partial)'; then
        return 0
    fi

    return 1
}

_filter_task_workflow_attempt_lines() {
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        if _task_workflow_attempt_line_is_placeholder "$line"; then
            continue
        fi
        printf '%s\n' "$line"
    done
}

_task_workflow_body_is_placeholder() {
    local key="$1"
    local body="$2"
    local trimmed=""
    local normalized=""

    trimmed=$(printf '%s\n' "$body" | _trim_nonblank_lines)
    [[ -z "$trimmed" ]] && return 0
    normalized=$(printf '%s\n' "$trimmed" | _trim_joined_text)

    case "$key" in
        left_off)
            case "$normalized" in
                "Not started.")
                    return 0
                    ;;
            esac
            if printf '%s\n' "$normalized" | grep -Eq '^\[exactly where work stopped'; then
                return 0
            fi
            ;;
        attempts)
            case "$normalized" in
                "(none yet)"|"(none)")
                    return 0
                    ;;
            esac
            if printf '%s\n' "$normalized" | grep -Fq 'what was tried' && \
                printf '%s\n' "$normalized" | grep -Fq 'result (worked/failed/partial)'; then
                return 0
            fi
            ;;
    esac

    return 1
}

_task_goal_content() {
    local task_file="$1"
    awk '
        /^## Goal:[[:space:]]*[^[:space:]].*$/ {
            line = $0
            sub(/^## Goal:[[:space:]]*/, "", line)
            print line
            found = 1
            exit 0
        }
        /^## Goal:?[[:space:]]*$/ { found = 1; capture = 1; next }
        /^## [^#]/ && capture { exit 0 }
        capture { print }
        END { exit(found ? 0 : 1) }
    ' "$task_file"
}

_goal_content_is_placeholder() {
    local goal_text="$1"
    local trimmed=""
    local normalized=""

    trimmed=$(printf '%s\n' "$goal_text" | _trim_nonblank_lines)
    normalized=$(printf '%s\n' "$trimmed" | _trim_joined_text | tr '[:upper:]' '[:lower:]')

    [[ -z "$trimmed" ]] && return 0

    case "$normalized" in
        todo|tbd|placeholder|goal|{{goal}}|"[goal]"|"[name]")
            return 0
            ;;
    esac

    if printf '%s\n' "$trimmed" | grep -Fq 'One sentence: the observable outcome when this is done.'; then
        return 0
    fi

    if printf '%s\n' "$trimmed" | grep -Fq 'Write as a behavior: "Users can X" or "System does Y when Z"'; then
        return 0
    fi

    return 1
}

_task_file_looks_like_v1_shell_skeleton() {
    local task_file="$1"
    local current_plan=""
    local critique=""
    local plan_history=""
    local left_off=""
    local attempts=""

    current_plan=$(section_body "$task_file" "## Current Plan" 2>/dev/null | _trim_nonblank_lines || true)
    critique=$(section_body "$task_file" "## Critique" 2>/dev/null | _trim_nonblank_lines || true)
    plan_history=$(section_body "$task_file" "## Plan History" 2>/dev/null | _trim_nonblank_lines || true)
    left_off=$(_task_workflow_body "$task_file" "left_off" 2>/dev/null | _trim_nonblank_lines || true)
    attempts=$(_task_workflow_body "$task_file" "attempts" 2>/dev/null | _trim_nonblank_lines || true)

    [[ "$current_plan" == "(Planner writes here)" ]] || return 1
    [[ "$critique" == "(Critic writes here)" ]] || return 1
    [[ "$plan_history" == "(Archived plan+critique rounds)" ]] || return 1
    [[ "$left_off" == "Not started." ]] || return 1
    [[ "$attempts" == "(none yet)" ]] || return 1
    return 0
}

_task_file_looks_like_v2_shell_skeleton() {
    local task_file="$1"
    local status_line=""
    local context_body=""
    local done_body=""
    local left_off=""
    local attempts=""
    local current_plan=""
    local execution_log=""
    local relevant_files=""

    status_line=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status:[[:space:]]*//')
    [[ "$status_line" == "in progress" ]] || return 1

    context_body=$(section_body "$task_file" "## Context:" 2>/dev/null | _trim_nonblank_lines || true)
    done_body=$(section_body "$task_file" "## Done Criteria:" 2>/dev/null | _trim_nonblank_lines || true)
    left_off=$(_task_workflow_body "$task_file" "left_off" 2>/dev/null | _trim_nonblank_lines || true)
    attempts=$(_task_workflow_body "$task_file" "attempts" 2>/dev/null | _trim_nonblank_lines || true)
    current_plan=$(section_body "$task_file" "## Current Plan" 2>/dev/null | _trim_nonblank_lines || true)
    execution_log=$(section_body "$task_file" "## Execution Log" 2>/dev/null | _trim_nonblank_lines || true)
    relevant_files=$(section_body "$task_file" "## Relevant Files:" 2>/dev/null | _trim_nonblank_lines || true)

    [[ "$context_body" == "Created by lauren-loop-v2 for a new competitive run." ]] || return 1
    [[ "$done_body" == "- [ ] Competitive run completes and leaves task in needs verification or blocked with artifacts preserved" ]] || return 1
    [[ "$left_off" == "Competitive run has started." ]] || return 1
    [[ "$attempts" == "(none yet)" ]] || return 1
    [[ -z "$current_plan" ]] || return 1
    [[ -z "$execution_log" ]] || return 1
    [[ "$relevant_files" == *'`lauren-loop-v2.sh` — competitive Lauren Loop flow'* ]] || return 1
    [[ "$relevant_files" == *'`lib/lauren-loop-utils.sh` — shared task-file logging and state helpers'* ]] || return 1
    return 0
}

_validate_task_file_content() {
    local task_file="$1"
    local goal_text=""
    local trimmed_goal=""

    if ! goal_text=$(_task_goal_content "$task_file"); then
        echo "## Goal section is missing" >&2
        return 1
    fi

    trimmed_goal=$(printf '%s\n' "$goal_text" | _trim_nonblank_lines)
    if [[ -z "$trimmed_goal" ]]; then
        echo "## Goal section is empty" >&2
        return 1
    fi

    if _goal_content_is_placeholder "$trimmed_goal"; then
        echo "## Goal section still contains placeholder text" >&2
        return 1
    fi

    if _task_file_looks_like_v1_shell_skeleton "$task_file" || _task_file_looks_like_v2_shell_skeleton "$task_file"; then
        echo "Task file is still an untouched Lauren Loop skeleton. Replace the generated boilerplate before starting a live run." >&2
        return 1
    fi

    return 0
}

_timeout_wrapped_verification_command() {
    local command_text="$1"
    local helper_path inner_script=""

    helper_path="$(_lauren_loop_repo_root)/lib/lauren-loop-utils.sh"
    printf -v inner_script 'source %q && _timeout 20m bash -lc %q' "$helper_path" "$command_text"
    printf 'bash -lc %q\n' "$inner_script"
}

_is_implementation_tasks_heading() {
    local line="$1"
    [[ "$line" =~ ^##[[:space:]]+Implementation[[:space:]]+Tasks:?[[:space:]]*$ ]]
}

_trim_verify_fragment() {
    local text="$1"

    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "$text"
}

_append_verify_fragment() {
    local joined="$1"
    local fragment="$2"
    local separator=" && "

    fragment=$(_trim_verify_fragment "$fragment")
    [[ -n "$fragment" ]] || {
        printf '%s' "$joined"
        return 0
    }

    if [[ "$fragment" == \#* ]]; then
        printf '%s' "$joined"
        return 0
    fi

    if [[ -z "$joined" ]]; then
        printf '%s' "$fragment"
        return 0
    fi

    case "$joined" in
        (*'&&'|*'||'|*';') separator=" " ;;
    esac
    case "$fragment" in
        ('&&'*|'||'*|';'*) separator=" " ;;
    esac

    printf '%s%s%s' "$joined" "$separator" "$fragment"
}

_lauren_loop_repo_root() {
    if [[ -n "${SCRIPT_DIR:-}" ]]; then
        printf '%s\n' "$SCRIPT_DIR"
    else
        printf '%s\n' "${LAUREN_LOOP_UTILS_DIR%/lib}"
    fi
}

_command_requires_repo_pytest_timeout() {
    local command_text="$1"

    printf '%s\n' "$command_text" | grep -Eq '(^|[^[:alnum:]_])pytest([^[:alnum:]_]|$)' || return 1
    printf '%s\n' "$command_text" | grep -Eq '(^|[[:space:]])tests/([[:space:]]|$)' || return 1
    printf '%s\n' "$command_text" | grep -Eq '(^|[[:space:]])-x([[:space:]]|$)' || return 1
    printf '%s\n' "$command_text" | grep -Eq '(^|[[:space:]])-q([[:space:]]|$)' || return 1
    return 0
}

_command_uses_timeout_wrapper() {
    local command_text="$1"
    local helper_path=""
    local helper_path_q=""
    local plain_prefix=""
    local escaped_prefix=""

    helper_path="$(_lauren_loop_repo_root)/lib/lauren-loop-utils.sh"
    printf -v helper_path_q '%q' "$helper_path"
    plain_prefix="source ${helper_path} && _timeout 20m bash -lc "
    escaped_prefix="source\\ ${helper_path_q}\\ \\&\\&\\ _timeout\\ 20m\\ bash\\ -lc\\ "

    [[ "$command_text" == bash\ -lc\ * ]] || return 1
    [[ "$command_text" == *"$plain_prefix"* || "$command_text" == *"$escaped_prefix"* ]]
}

_task_is_timeout_verification_retry_eligible() {
    local task_file="$1"
    local current_status="${2:-}"
    local blocked_line=""
    local timeout_message=""

    if [[ -z "$current_status" ]]; then
        current_status=$(grep '^## Status:' "$task_file" | head -1 | sed 's/^## Status: //')
    fi

    case "$current_status" in
        execution-blocked|fix-blocked) ;;
        *) return 1 ;;
    esac

    blocked_line=$(grep 'BLOCKED:' "$task_file" 2>/dev/null | tail -1 || true)
    [[ -n "$blocked_line" ]] || return 1

    timeout_message=$(_verification_timeout_message)
    printf '%s\n' "$blocked_line" | grep -Fq "$timeout_message"
}

_normalize_executor_prompt_timeout_content() {
    local context="$1"
    local prompt_content=""
    local canonical_pytest='.venv/bin/python -m pytest tests/ -x -q'
    local replacement=""
    local match_count=0

    prompt_content=$(cat)
    replacement=$(_timeout_wrapped_verification_command "$canonical_pytest") || return 1
    match_count=$(printf '%s' "$prompt_content" | grep -oF "$canonical_pytest" | wc -l | tr -d ' ')
    if [[ "${match_count:-0}" -eq 0 ]]; then
        echo "ERROR: ${context}: expected repo-standard pytest verification command in executor prompt but found none" >&2
        return 1
    fi

    prompt_content=${prompt_content//"$canonical_pytest"/"$replacement"}
    if printf '%s' "$prompt_content" | grep -qF "$canonical_pytest"; then
        echo "ERROR: ${context}: unwrapped repo-standard pytest verification command remained after timeout normalization" >&2
        return 1
    fi

    printf '%s' "$prompt_content"
}

_normalize_verify_tags_with_timeout_in_file() {
    local target_file="$1"
    local context="$2"
    local tmp_file=""
    local saw_verify_line=0
    local saw_wrapped_candidate=0
    local saw_timeout_candidate=0
    local in_implementation_tasks=0
    local accumulating_verify=0
    local verify_prefix=""
    local verify_joined=""
    local opener_remainder=""
    local closing_prefix=""
    local suffix=""

    [[ -f "$target_file" ]] || {
        echo "ERROR: ${context}: file not found: ${target_file}" >&2
        return 1
    }

    tmp_file=$(same_dir_temp_file "$target_file")
    while IFS= read -r verify_line || [[ -n "$verify_line" ]]; do
        if [[ "$accumulating_verify" -eq 1 ]]; then
            if [[ "$verify_line" =~ ^##[[:space:]]+ ]]; then
                rm -f "$tmp_file"
                echo "ERROR: ${context}: unterminated multi-line <verify> tag crossed a section boundary" >&2
                return 1
            fi

            if [[ "$verify_line" == *"<verify>"* ]]; then
                rm -f "$tmp_file"
                echo "ERROR: ${context}: nested <verify> tags are not supported" >&2
                return 1
            fi

            if [[ "$verify_line" == *"</verify>"* ]]; then
                closing_prefix="${verify_line%%</verify>*}"
                verify_joined=$(_append_verify_fragment "$verify_joined" "$closing_prefix")

                suffix="${verify_line#*</verify>}"
                verify_line="${verify_prefix}<verify>${verify_joined}</verify>${suffix}"
                accumulating_verify=0
                verify_prefix=""
                verify_joined=""
                closing_prefix=""
                suffix=""
            else
                verify_joined=$(_append_verify_fragment "$verify_joined" "$verify_line")
                continue
            fi
        fi

        if _is_implementation_tasks_heading "$verify_line"; then
            in_implementation_tasks=1
        elif [[ "$in_implementation_tasks" -eq 1 && "$verify_line" =~ ^##[[:space:]]+ ]]; then
            in_implementation_tasks=0
        fi

        if [[ "$in_implementation_tasks" -eq 1 ]]; then
            if [[ "$verify_line" == *"<verify>"* ]] && [[ "$verify_line" != *"</verify>"* ]]; then
                verify_prefix="${verify_line%%<verify>*}"
                opener_remainder="${verify_line#*<verify>}"
                if [[ "$opener_remainder" == *"<verify>"* ]]; then
                    rm -f "$tmp_file"
                    echo "ERROR: ${context}: nested <verify> tags are not supported" >&2
                    return 1
                fi

                verify_joined=""
                verify_joined=$(_append_verify_fragment "$verify_joined" "$opener_remainder")
                accumulating_verify=1
                continue
            fi

            if [[ "$verify_line" == *"</verify>"* ]] && [[ "$verify_line" != *"<verify>"* ]]; then
                rm -f "$tmp_file"
                echo "ERROR: ${context}: timeout normalization found a closing </verify> tag without a matching opener" >&2
                return 1
            fi

            if [[ "$verify_line" == *"<verify>"*"</verify>"* ]]; then
                local prefix=""
                local verify_body=""
                local suffix=""
                local wrapped=""

                prefix="${verify_line%%<verify>*}"
                verify_body="${verify_line#*<verify>}"
                verify_body="${verify_body%%</verify>*}"
                suffix="${verify_line#*</verify>}"
                if _command_requires_repo_pytest_timeout "$verify_body"; then
                    saw_timeout_candidate=1
                    if ! _command_uses_timeout_wrapper "$verify_body"; then
                        wrapped=$(_timeout_wrapped_verification_command "$verify_body") || {
                            rm -f "$tmp_file"
                            return 1
                        }
                        verify_line="${prefix}<verify>${wrapped}</verify>${suffix}"
                    fi
                fi
            fi
        fi

        printf '%s\n' "$verify_line" >> "$tmp_file"
    done < "$target_file"

    if [[ "$accumulating_verify" -eq 1 ]]; then
        rm -f "$tmp_file"
        echo "ERROR: ${context}: unterminated multi-line <verify> tag" >&2
        return 1
    fi

    mv "$tmp_file" "$target_file"

    in_implementation_tasks=0
    while IFS= read -r verify_line || [[ -n "$verify_line" ]]; do
        if _is_implementation_tasks_heading "$verify_line"; then
            in_implementation_tasks=1
        elif [[ "$in_implementation_tasks" -eq 1 && "$verify_line" =~ ^##[[:space:]]+ ]]; then
            in_implementation_tasks=0
        fi

        if [[ "$in_implementation_tasks" -eq 1 ]]; then
            if { [[ "$verify_line" == *"<verify>"* ]] || [[ "$verify_line" == *"</verify>"* ]]; } && [[ "$verify_line" != *"<verify>"*"</verify>"* ]]; then
                echo "ERROR: ${context}: multi-line <verify> tags remained after timeout normalization" >&2
                return 1
            fi

            if [[ "$verify_line" == *"<verify>"*"</verify>"* ]]; then
                saw_verify_line=1
                local verify_body=""
                verify_body="${verify_line#*<verify>}"
                verify_body="${verify_body%%</verify>*}"
                if _command_uses_timeout_wrapper "$verify_body"; then
                    saw_wrapped_candidate=1
                fi
                if _command_requires_repo_pytest_timeout "$verify_body"; then
                    if ! _command_uses_timeout_wrapper "$verify_body"; then
                        echo "ERROR: ${context}: repo-standard pytest verification command remained unwrapped in ${target_file}" >&2
                        return 1
                    fi
                    saw_wrapped_candidate=1
                fi
            fi
        fi
    done < "$target_file"

    if [[ "$saw_verify_line" -eq 0 ]]; then
        return 0
    fi

    if [[ "$saw_timeout_candidate" -eq 1 && "$saw_wrapped_candidate" -eq 0 ]]; then
        echo "ERROR: ${context}: timeout normalization did not wrap a repo-standard pytest verify command" >&2
        return 1
    fi

    return 0
}

_latest_timeout_block_line() {
    local source_file="$1"
    local sentinel=""

    [[ -f "$source_file" ]] || return 1
    sentinel=$(_verification_timeout_message)
    grep 'BLOCKED:' "$source_file" 2>/dev/null | grep -F "$sentinel" | tail -1
}

_timeout_block_count_in_file() {
    local source_file="$1"
    local sentinel=""

    [[ -f "$source_file" ]] || {
        printf '0\n'
        return 0
    }

    sentinel=$(_verification_timeout_message)
    grep 'BLOCKED:' "$source_file" 2>/dev/null | grep -F "$sentinel" | wc -l | tr -d ' '
}

_validate_single_verify_command() {
    local cmd="$1"
    local context="$2"
    local line_number="${3:-?}"
    local trimmed first_token

    # Trim whitespace
    trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    if [[ -z "$trimmed" ]]; then
        echo "ERROR: ${context} (line ${line_number}): empty verify command" >&2
        return 1
    fi

    # Check for unbalanced quotes
    local single_count double_count
    single_count=$(printf '%s' "$trimmed" | tr -cd "'" | wc -c | tr -d ' ')
    double_count=$(printf '%s' "$trimmed" | tr -cd '"' | wc -c | tr -d ' ')
    if [[ $((single_count % 2)) -ne 0 ]]; then
        echo "ERROR: ${context} (line ${line_number}): unbalanced single quotes in verify command: ${trimmed}" >&2
        return 1
    fi
    if [[ $((double_count % 2)) -ne 0 ]]; then
        echo "ERROR: ${context} (line ${line_number}): unbalanced double quotes in verify command: ${trimmed}" >&2
        return 1
    fi

    # For compound commands, validate only the first segment
    local first_segment="$trimmed"
    if [[ "$first_segment" == *" && "* ]]; then
        first_segment="${first_segment%% && *}"
    elif [[ "$first_segment" == *" || "* ]]; then
        first_segment="${first_segment%% || *}"
    elif [[ "$first_segment" == *" | "* ]]; then
        first_segment="${first_segment%% | *}"
    fi

    # Extract first token (the command name)
    first_token="${first_segment%% *}"

    # Allowed command prefixes
    case "$first_token" in
        pytest|python|bash|sh|npm|npx|node|make|cd|timeout|env|grep|diff|wc) return 0 ;;
        .venv/bin/python|.venv/bin/pytest) return 0 ;;
    esac

    echo "ERROR: ${context} (line ${line_number}): unknown command prefix '${first_token}' in verify command: ${trimmed}" >&2
    return 1
}

_validate_verify_commands_in_file() {
    local target_file="$1"
    local context="$2"
    local in_implementation_tasks=0
    local line_number=0
    local has_error=0
    local vline cmd

    [[ -f "$target_file" ]] || {
        echo "ERROR: ${context}: file not found: ${target_file}" >&2
        return 1
    }

    while IFS= read -r vline || [[ -n "$vline" ]]; do
        line_number=$((line_number + 1))

        if _is_implementation_tasks_heading "$vline"; then
            in_implementation_tasks=1
        elif [[ "$in_implementation_tasks" -eq 1 && "$vline" =~ ^##[[:space:]]+ ]]; then
            in_implementation_tasks=0
        fi

        if [[ "$in_implementation_tasks" -eq 1 ]]; then
            if [[ "$vline" == *"<verify>"*"</verify>"* ]]; then
                cmd="${vline#*<verify>}"
                cmd="${cmd%%</verify>*}"
                if ! _validate_single_verify_command "$cmd" "$context" "$line_number"; then
                    has_error=1
                fi
            fi
        fi
    done < "$target_file"

    return "$has_error"
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

    if [[ "$my_version" == "v1" ]]; then
        # v1 checking v2: per-slug lock dirs under v2_dir/<slug>/pid
        local v2_dir="${_V2_LOCK_DIR:-/tmp/lauren-loop-v2.lock.d}"
        local v2_slug_pid_file="$v2_dir/$my_slug/pid"
        [[ -f "$v2_slug_pid_file" ]] || return 0
        local other_pid
        other_pid=$(tr -d '[:space:]' < "$v2_slug_pid_file" 2>/dev/null) || return 0
        [[ -n "$other_pid" ]] || return 0
        kill -0 "$other_pid" 2>/dev/null || return 0
        echo -e "${YELLOW:-}Warning: v1 and V2 are both operating on '${my_slug}' (V2 PID ${other_pid})${NC:-}" >&2
        echo -e "${YELLOW:-}Concurrent modifications to the same task file may cause corruption.${NC:-}" >&2
        return 1
    else
        # v2 checking v1: unchanged (v1's lock structure is not changing)
        local v1_file="${_V1_LOCK_FILE:-/tmp/lauren-loop-pilot.lock}"
        local other_slug_file="${v1_file}.slug"
        [[ -f "$v1_file" ]] || return 0
        local other_pid
        other_pid=$(cat "$v1_file" 2>/dev/null)
        kill -0 "$other_pid" 2>/dev/null || return 0
        local other_slug=""
        [[ -f "$other_slug_file" ]] && other_slug=$(cat "$other_slug_file" 2>/dev/null)
        [[ -z "$other_slug" ]] && return 0
        if [[ "$other_slug" == "$my_slug" ]]; then
            echo -e "${YELLOW:-}Warning: V2 and v1 are both operating on '${my_slug}' (v1 PID ${other_pid})${NC:-}" >&2
            echo -e "${YELLOW:-}Concurrent modifications to the same task file may cause corruption.${NC:-}" >&2
            return 1
        fi
        return 0
    fi
}

# ============================================================
# Process / lock helpers (shared across v1 and v2)
# ============================================================

_process_alive() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -d "/proc/$pid" ]]; then
        return 0
    fi
    kill -0 "$pid" 2>/dev/null
}

# List all running V2 instances by scanning per-slug lock subdirectories.
# Output: one line per alive instance — "<slug> <pid> <goal>"
# Uses _V2_LOCK_DIR env var override for testability.
_list_running_v2_instances() {
    local lock_dir="${_V2_LOCK_DIR:-/tmp/lauren-loop-v2.lock.d}"
    local slug pid goal pid_file
    [[ -d "$lock_dir" ]] || return 0
    for pid_file in "$lock_dir"/*/pid; do
        [[ -f "$pid_file" ]] || continue
        pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null) || continue
        [[ -n "$pid" ]] || continue
        _process_alive "$pid" || continue
        slug=$(basename "$(dirname "$pid_file")")
        goal=""
        [[ -f "$(dirname "$pid_file")/goal" ]] && goal=$(cat "$(dirname "$pid_file")/goal" 2>/dev/null)
        printf '%s\t%s\t%s\n' "$slug" "$pid" "$goal"
    done
}

# Check if a specific slug is currently running under V2.
# Returns 0 if running, 1 otherwise.
_is_slug_running_v2() {
    local slug="$1"
    local lock_dir="${_V2_LOCK_DIR:-/tmp/lauren-loop-v2.lock.d}"
    local pid_file="$lock_dir/$slug/pid"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null) || return 1
    [[ -n "$pid" ]] || return 1
    _process_alive "$pid"
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

_capture_repo_diff_since_ref() {
    local before_sha="$1"
    local diff_file="$2"

    : > "$diff_file" || return 1
    git diff "$before_sha"..HEAD > "$diff_file" 2>/dev/null || true
    git diff >> "$diff_file" 2>/dev/null || true
    git diff --cached >> "$diff_file" 2>/dev/null || true
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

_atomic_promote_file() {
    local source_file="$1"
    local target_file="$2"
    local tmp

    [[ -f "$source_file" ]] || return 1
    tmp=$(same_dir_temp_file "$target_file") || return 1
    cp "$source_file" "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$target_file"
}

_write_v2_task_file() {
    local target_file="$1"
    local slug="$2"
    local goal="$3"
    local tmp

    mkdir -p "$(dirname "$target_file")" || return 1
    tmp=$(same_dir_temp_file "$target_file") || return 1
    {
        printf '## Task: %s\n' "$slug"
        printf '## Status: in progress\n'
        printf '## Execution Mode: competitive\n'
        printf '## Goal: %s\n' "$goal"
        printf '## Relevant Files:\n'
        printf '%s\n' '- `lauren-loop-v2.sh` — competitive Lauren Loop flow'
        printf '%s\n' '- `lib/lauren-loop-utils.sh` — shared task-file logging and state helpers'
        printf '## Context:\n'
        printf '%s\n' 'Created by lauren-loop-v2 for a new competitive run.'
        printf '## Done Criteria:\n'
        printf '%s\n' '- [ ] Competitive run completes and leaves task in needs verification or blocked with artifacts preserved'
        printf '## Left Off At\n'
        printf '%s\n' 'Competitive run has started.'
        printf '\n'
        printf '## Execution Log\n'
        printf '\n'
        printf '## Attempts\n'
        printf '%s\n' '(none yet)'
        printf '\n'
        printf '## Current Plan\n'
        printf '\n'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$target_file"
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

_agent_output_requires_semantic_validation() {
    case "$1" in
        planner-b|reviewer-b*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_codex_role_uses_tool_written_artifact() {
    case "$1" in
        planner-b|reviewer-b*|scope-triage|final-verify*|final-falsify*|final-fix*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_repo_root_for_lauren_loop_utils() {
    if [[ -n "${SCRIPT_DIR:-}" && -d "${SCRIPT_DIR}/prompts" ]]; then
        printf '%s\n' "$SCRIPT_DIR"
    else
        printf '%s\n' "${LAUREN_LOOP_UTILS_DIR%/lib}"
    fi
}

_regex_escape_ere() {
    printf '%s' "$1" | sed -e 's/[][(){}.^$+*?|\\/-]/\\&/g'
}

_markdown_section_body() {
    local file="$1"
    local heading_regex="$2"
    awk -v heading="$heading_regex" '
        BEGIN { in_section=0 }
        $0 ~ heading {
            in_section=1
            next
        }
        in_section && /^##[[:space:]]+/ {
            exit 0
        }
        in_section {
            print
        }
    ' "$file"
}

_markdown_section_has_nonblank_body() {
    local file="$1"
    local heading_regex="$2"
    awk -v heading="$heading_regex" '
        BEGIN { in_section=0; saw_body=0 }
        $0 ~ heading {
            in_section=1
            next
        }
        in_section && /^##[[:space:]]+/ {
            exit(saw_body ? 0 : 1)
        }
        in_section && $0 ~ /[^[:space:]]/ {
            saw_body=1
        }
        END {
            if (in_section) {
                exit(saw_body ? 0 : 1)
            }
            exit 1
        }
    ' "$file"
}

_markdown_fences_are_balanced() {
    local file="$1"
    local fence_count
    fence_count=$(grep -Ec '^[[:space:]]*```' "$file" || true)
    (( fence_count % 2 == 0 ))
}

_planner_contract_tags_balanced() {
    local file="$1"
    local section_body=""
    local wave_open wave_close task_open task_close task_typed
    local task_required_tags=0
    section_body=$(_markdown_section_body "$file" '^#{2,3}[[:space:]]+Implementation Tasks[[:space:]]*$')
    [[ -n "$section_body" ]] || return 1

    wave_open=$(printf '%s\n' "$section_body" | { grep -Eo '<wave[[:space:]][^>]*>' || true; } | wc -l | tr -d ' ')
    wave_close=$(printf '%s\n' "$section_body" | { grep -Eo '</wave>' || true; } | wc -l | tr -d ' ')
    task_open=$(printf '%s\n' "$section_body" | { grep -Eo '<task[[:space:]][^>]*>' || true; } | wc -l | tr -d ' ')
    task_close=$(printf '%s\n' "$section_body" | { grep -Eo '</task>' || true; } | wc -l | tr -d ' ')
    task_typed=$(printf '%s\n' "$section_body" | { grep -Eo '<task[[:space:]][^>]*type="(auto|verify)"[^>]*>' || true; } | wc -l | tr -d ' ')

    (( wave_open > 0 && wave_open == wave_close )) || return 1
    (( task_open > 0 && task_open == task_close )) || return 1
    (( task_typed == task_open )) || return 1

    for required_tag in name files action verify done; do
        local tag_count
        tag_count=$(printf '%s\n' "$section_body" | { grep -Eo "<${required_tag}>" || true; } | wc -l | tr -d ' ')
        (( tag_count >= task_open )) || return 1
        task_required_tags=$((task_required_tags + 1))
    done

    (( task_required_tags == 5 ))
}

_planner_artifact_has_required_sections() {
    local file="$1"
    grep -Eq '^#{2,3}[[:space:]]+Files to Modify[[:space:]]*$' "$file" \
        && _markdown_section_has_nonblank_body "$file" '^#{2,3}[[:space:]]+Files to Modify[[:space:]]*$' \
        && grep -Eq '^#{2,3}[[:space:]]+Implementation Tasks[[:space:]]*$' "$file" \
        && _markdown_section_has_nonblank_body "$file" '^#{2,3}[[:space:]]+Implementation Tasks[[:space:]]*$' \
        && grep -Eq '^#{2,3}[[:space:]]+Testability Design[[:space:]]*$' "$file" \
        && _markdown_section_has_nonblank_body "$file" '^#{2,3}[[:space:]]+Testability Design[[:space:]]*$' \
        && grep -Eq '^#{2,3}[[:space:]]+Test Strategy[[:space:]]*$' "$file" \
        && _markdown_section_has_nonblank_body "$file" '^#{2,3}[[:space:]]+Test Strategy[[:space:]]*$' \
        && grep -Eq '^#{2,3}[[:space:]]+Risk Assessment[[:space:]]*$' "$file" \
        && _markdown_section_has_nonblank_body "$file" '^#{2,3}[[:space:]]+Risk Assessment[[:space:]]*$' \
        && grep -Eq '^#{2,3}[[:space:]]+Dependencies[[:space:]]*$' "$file" \
        && _markdown_section_has_nonblank_body "$file" '^#{2,3}[[:space:]]+Dependencies[[:space:]]*$' \
        && _markdown_fences_are_balanced "$file" \
        && _planner_contract_tags_balanced "$file"
}

_reviewer_b_prompt_path() {
    printf '%s/prompts/reviewer-b.md\n' "$(_repo_root_for_lauren_loop_utils)"
}

_reviewer_b_dimension_specs() {
    local prompt_file
    prompt_file=$(_reviewer_b_prompt_path)
    [[ -f "$prompt_file" ]] || return 1

    sed -nE 's/^\*\*([0-9][0-9]*)\.[[:space:]]+([^*]+):\*\*.*/\1|\2/p' "$prompt_file"
}

_reviewer_b_artifact_has_required_sections() {
    local file="$1"
    local spec_count=0
    local number="" label="" label_pattern=""

    if ! grep -Eq '^#[[:space:]]+Review B[[:space:]]*$' "$file"; then
        echo "WARN: reviewer-b artifact missing '# Review B' heading: $file" >&2
        return 1
    fi
    if ! grep -Eq '^##[[:space:]]+Findings[[:space:]]*$' "$file"; then
        echo "WARN: reviewer-b artifact missing '## Findings' heading: $file" >&2
        return 1
    fi
    if ! _markdown_section_has_nonblank_body "$file" '^##[[:space:]]+Findings[[:space:]]*$'; then
        echo "WARN: reviewer-b artifact has empty '## Findings' section: $file" >&2
        return 1
    fi
    if ! grep -Eq '^##[[:space:]]+Done-Criteria Check[[:space:]]*$' "$file"; then
        echo "WARN: reviewer-b artifact missing '## Done-Criteria Check' heading: $file" >&2
        return 1
    fi
    if ! _markdown_section_has_nonblank_body "$file" '^##[[:space:]]+Done-Criteria Check[[:space:]]*$'; then
        echo "WARN: reviewer-b artifact has empty '## Done-Criteria Check' section: $file" >&2
        return 1
    fi
    if ! grep -Eq '^##[[:space:]]+Dimension Coverage[[:space:]]*$' "$file"; then
        echo "WARN: reviewer-b artifact missing '## Dimension Coverage' heading: $file" >&2
        return 1
    fi
    if ! _markdown_section_has_nonblank_body "$file" '^##[[:space:]]+Dimension Coverage[[:space:]]*$'; then
        echo "WARN: reviewer-b artifact has empty '## Dimension Coverage' section: $file" >&2
        return 1
    fi
    if ! grep -Eq '^##[[:space:]]+Verdict[[:space:]]*$' "$file"; then
        echo "WARN: reviewer-b artifact missing '## Verdict' heading: $file" >&2
        return 1
    fi
    if ! _markdown_section_has_nonblank_body "$file" '^##[[:space:]]+Verdict[[:space:]]*$'; then
        echo "WARN: reviewer-b artifact has empty '## Verdict' section: $file" >&2
        return 1
    fi

    while IFS='|' read -r number label; do
        [[ -n "$number" && -n "$label" ]] || continue
        label_pattern=$(_regex_escape_ere "$label")
        if ! grep -Eq "^\\*\\*${number}\\.[[:space:]]+${label_pattern}:\\*\\*[[:space:]]+.+$" "$file"; then
            echo "WARN: reviewer-b artifact missing dimension coverage line for '${number}. ${label}': $file" >&2
            return 1
        fi
        spec_count=$((spec_count + 1))
    done < <(_reviewer_b_dimension_specs)

    if (( spec_count <= 0 )); then
        echo "WARN: reviewer-b dimension coverage spec list is empty: $file" >&2
        return 1
    fi
    if ! grep -Eq '^\*\*VERDICT:[[:space:]]*(PASS|FAIL|CONDITIONAL)\*\*$' "$file"; then
        echo "WARN: reviewer-b artifact missing '**VERDICT:**' contract line: $file" >&2
        return 1
    fi

    return 0
}

_reviewer_a_artifact_has_required_sections() {
    local file="$1"
    if ! grep -Eq '\*\*VERDICT:[[:space:]]*(PASS|FAIL|CONDITIONAL)\*\*' "$file"; then
        echo "WARN: reviewer-a artifact missing '**VERDICT:**' contract line: $file" >&2
        return 1
    fi

    return 0
}

_validate_agent_output_for_role() {
    local role="$1" file="$2"
    _validate_agent_output "$file" || return 1

    case "$role" in
        planner-a|planner-b)
            _planner_artifact_has_required_sections "$file"
            ;;
        reviewer-a*)
            _reviewer_a_artifact_has_required_sections "$file"
            ;;
        reviewer-b*)
            _reviewer_b_artifact_has_required_sections "$file"
            ;;
        *)
            return 0
            ;;
    esac
}

_promote_latest_valid_attempt() {
    local role="$1" canonical_path="$2"
    local extension="" stem="$canonical_path"
    local artifact_dir artifact_base candidate attempt_number
    local -a attempts=()

    [[ -n "$canonical_path" ]] || return 1
    # If canonical already exists, no promotion needed
    [[ -f "$canonical_path" ]] && return 0

    if [[ "$canonical_path" == *.* ]]; then
        extension=".${canonical_path##*.}"
        stem="${canonical_path%${extension}}"
    fi
    artifact_dir=$(dirname "$canonical_path")
    artifact_base=$(basename "$stem")

    # Collect valid attempt numbers
    for candidate in "$artifact_dir"/"${artifact_base}.attempt-"*"$extension"; do
        [[ -f "$candidate" ]] || continue
        attempt_number=$(basename "$candidate")
        attempt_number="${attempt_number#${artifact_base}.attempt-}"
        attempt_number="${attempt_number%${extension}}"
        [[ "$attempt_number" =~ ^[0-9]+$ ]] || continue
        attempts+=("${attempt_number}:${candidate}")
    done

    # No attempts found
    if [[ ${#attempts[@]} -eq 0 ]]; then
        printf '[codex-attempt-promote] role=%s no valid attempts found\n' "$role" >&2
        return 1
    fi

    # Sort descending by attempt number, try highest first
    local sorted
    sorted=$(printf '%s\n' "${attempts[@]}" | sort -t: -k1 -rn)
    while IFS=: read -r _ path; do
        [[ -n "$path" ]] || continue
        if _validate_agent_output_for_role "$role" "$path" >/dev/null 2>&1; then
            _atomic_promote_file "$path" "$canonical_path" || continue
            printf '[codex-attempt-promote] role=%s attempt=%s -> canonical=%s\n' \
                "$role" "$path" "$canonical_path" >&2
            return 0
        fi
    done <<< "$sorted"

    printf '[codex-attempt-promote] role=%s no valid attempts found\n' "$role" >&2
    return 1
}

_terminate_pid_tree() {
    local pid="$1" grace="${2:-$(_agent_terminate_grace_seconds)}"
    kill -0 "$pid" 2>/dev/null || return 0

    # Snapshot descendants BEFORE TERM — they may reparent if parent exits
    local descendants=""
    descendants=$(pgrep -P "$pid" 2>/dev/null || true)

    # TERM pass
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    sleep "$grace"

    # KILL pass — always fire on all recorded PIDs, even if parent exited
    local dpid
    for dpid in $pid $descendants; do
        if kill -0 "$dpid" 2>/dev/null; then
            kill -9 "$dpid" 2>/dev/null || true
        fi
    done
}

_watch_codex_artifact_for_static_invalid() {
    local role="$1" artifact_file="$2" cmd_pid="$3" marker_file="$4" log_file="$5"
    _agent_output_requires_semantic_validation "$role" || return 0

    local poll_interval last_size="" current_size="" unchanged_polls=0
    poll_interval=$(_agent_poll_interval_seconds)

    while kill -0 "$cmd_pid" 2>/dev/null; do
        if [[ -f "$artifact_file" && -s "$artifact_file" ]]; then
            if _validate_agent_output_for_role "$role" "$artifact_file" >/dev/null 2>&1; then
                return 0
            fi

            current_size=$(wc -c < "$artifact_file" | tr -d ' ')
            if [[ "$current_size" == "$last_size" ]]; then
                unchanged_polls=$((unchanged_polls + 1))
            else
                unchanged_polls=0
            fi
            last_size="$current_size"

            if (( unchanged_polls >= 2 )); then
                printf '[codex-watcher] role=%s static_invalid_artifact bytes=%s unchanged_polls=%s\n' \
                    "$role" "$current_size" "$unchanged_polls" >> "$log_file"
                : > "$marker_file"
                _terminate_pid_tree "$cmd_pid"
                return 1
            fi
        fi

        sleep "$poll_interval"
    done

    return 0
}

# Write cycle state checkpoint for review/fix loop resumability.
# Usage: _write_cycle_state <comp_dir> <fix_cycle> <last_completed> [<review_verdict>] [<phase8_round>] [<phase8_result>]
_write_cycle_state() {
    local comp_dir="$1" fix_cycle="$2" last_completed="$3" review_verdict="${4:-}"
    local phase8_round="${5:-}" phase8_result="${6:-}"
    command -v jq >/dev/null 2>&1 || return 0
    local state_file="${comp_dir}/.cycle-state.json"
    local tmp
    tmp=$(same_dir_temp_file "$state_file") || return 1
    jq -n \
        --argjson fix_cycle "$fix_cycle" \
        --arg last_completed "$last_completed" \
        --arg review_verdict "$review_verdict" \
        --arg phase8_round "$phase8_round" \
        --arg phase8_result "$phase8_result" \
        --arg timestamp "$(_iso_timestamp)" \
        '({
            fix_cycle: $fix_cycle,
            last_completed: $last_completed,
            review_verdict: (if $review_verdict == "" then null else $review_verdict end),
            timestamp: $timestamp
        } +
        (if $phase8_round == "" then {} else { phase8_round: $phase8_round } end) +
        (if $phase8_result == "" then {} else { phase8_result: $phase8_result } end))' > "$tmp" && mv "$tmp" "$state_file" || { rm -f "$tmp"; return 1; }
}

# Read cycle state checkpoint. Sets globals:
#   CYCLE_STATE_FIX_CYCLE, CYCLE_STATE_LAST_COMPLETED, CYCLE_STATE_REVIEW_VERDICT,
#   CYCLE_STATE_PHASE8_ROUND, CYCLE_STATE_PHASE8_RESULT
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
    CYCLE_STATE_PHASE8_ROUND=$(jq -r '.phase8_round // empty' "$state_file" 2>/dev/null) || true
    CYCLE_STATE_PHASE8_RESULT=$(jq -r '.phase8_result // empty' "$state_file" 2>/dev/null) || true
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

_rewrite_task_workflow_section() {
    local task_file="$1"
    local key="$2"
    local replacement_file="$3"
    local start end tmp_file header

    read -r start end < <(_task_workflow_bounds "$task_file" "$key") || return 1
    tmp_file=$(same_dir_temp_file "$task_file")
    header=$(_task_workflow_canonical_header "$key") || return 1

    awk -v start="$start" -v end="$end" -v replacement="$replacement_file" -v header="$header" '
        NR == start {
            print header
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

_delete_task_section_range() {
    local task_file="$1"
    local start="$2"
    local end="$3"
    local tmp_file

    tmp_file=$(same_dir_temp_file "$task_file") || return 1
    awk -v start="$start" -v end="$end" '
        NR >= start && NR < end { next }
        { print }
    ' "$task_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$task_file"
}

_normalize_task_workflow_section() {
    local task_file="$1"
    local key="$2"
    local canonical_count legacy_count total
    local canonical_header legacy_header canonical_start legacy_start
    local first_header second_header first_start first_end second_start second_end
    local first_body="" second_body="" first_trimmed="" second_trimmed=""
    local replacement_file="" merged_input="" merged_output=""

    canonical_count=$(_task_workflow_variant_count "$task_file" "$key" "canonical") || return 1
    legacy_count=$(_task_workflow_variant_count "$task_file" "$key" "legacy") || return 1
    total=$((canonical_count + legacy_count))
    canonical_header=$(_task_workflow_canonical_header "$key") || return 1
    legacy_header=$(_task_workflow_legacy_header "$key") || return 1

    if [ "$canonical_count" -gt 1 ] || [ "$legacy_count" -gt 1 ]; then
        echo "Expected at most one canonical and one legacy section for $canonical_header" >&2
        return 1
    fi

    if [ "$total" -eq 0 ]; then
        return 0
    fi

    if [ "$total" -eq 1 ]; then
        if [ "$legacy_count" -eq 1 ]; then
            replacement_file=$(mktemp)
            _task_workflow_body "$task_file" "$key" > "$replacement_file" 2>/dev/null || true
            _rewrite_task_workflow_section "$task_file" "$key" "$replacement_file" || {
                rm -f "$replacement_file"
                return 1
            }
            rm -f "$replacement_file"
        fi
        return 0
    fi

    canonical_start=$(_task_workflow_first_line_for_variant "$task_file" "$key" "canonical")
    legacy_start=$(_task_workflow_first_line_for_variant "$task_file" "$key" "legacy")
    if [ -z "$canonical_start" ] || [ -z "$legacy_start" ]; then
        echo "Expected both canonical and legacy sections for $canonical_header" >&2
        return 1
    fi

    if [ "$canonical_start" -lt "$legacy_start" ]; then
        first_header="$canonical_header"
        second_header="$legacy_header"
    else
        first_header="$legacy_header"
        second_header="$canonical_header"
    fi

    read -r first_start first_end < <(section_bounds "$task_file" "$first_header") || return 1
    read -r second_start second_end < <(section_bounds "$task_file" "$second_header") || return 1
    first_body=$(section_body "$task_file" "$first_header" 2>/dev/null || true)
    second_body=$(section_body "$task_file" "$second_header" 2>/dev/null || true)
    first_trimmed=$(printf '%s\n' "$first_body" | _trim_nonblank_lines)
    second_trimmed=$(printf '%s\n' "$second_body" | _trim_nonblank_lines)

    case "$key" in
        attempts)
            merged_input=$(mktemp)
            merged_output=$(mktemp)
            {
                printf '%s\n' "$first_body"
                printf '%s\n' "$second_body"
            } > "$merged_input"
            _filter_task_workflow_attempt_lines < "$merged_input" | awk '!seen[$0]++' > "$merged_output"
            rm -f "$merged_input"

            _delete_task_section_range "$task_file" "$second_start" "$second_end" || {
                rm -f "$merged_output"
                return 1
            }
            _rewrite_task_workflow_section "$task_file" "$key" "$merged_output" || {
                rm -f "$merged_output"
                return 1
            }
            rm -f "$merged_output"
            ;;
        left_off)
            if ! _task_workflow_body_is_placeholder "$key" "$first_body" && \
                ! _task_workflow_body_is_placeholder "$key" "$second_body" && \
                [ "$first_trimmed" != "$second_trimmed" ]; then
                echo "Conflicting logical Left Off At sections found; manual cleanup required before rewriting." >&2
                return 1
            fi

            replacement_file=$(mktemp)
            if _task_workflow_body_is_placeholder "$key" "$first_body" && \
                ! _task_workflow_body_is_placeholder "$key" "$second_body"; then
                printf '%s\n' "$second_body" > "$replacement_file"
            elif ! _task_workflow_body_is_placeholder "$key" "$first_body" && \
                _task_workflow_body_is_placeholder "$key" "$second_body"; then
                printf '%s\n' "$first_body" > "$replacement_file"
            elif [ -n "$first_trimmed" ]; then
                printf '%s\n' "$first_body" > "$replacement_file"
            elif [ -n "$second_trimmed" ]; then
                printf '%s\n' "$second_body" > "$replacement_file"
            else
                _task_workflow_default_body "$key" > "$replacement_file"
            fi

            _delete_task_section_range "$task_file" "$second_start" "$second_end" || {
                rm -f "$replacement_file"
                return 1
            }
            _rewrite_task_workflow_section "$task_file" "$key" "$replacement_file" || {
                rm -f "$replacement_file"
                return 1
            }
            rm -f "$replacement_file"
            ;;
    esac
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
    # canonical AskGeorge task files that do not carry V1/V2 sidecar sections.
    local log_start
    log_start=$(grep -n '^## Execution Log' "$task_file" | head -1 | cut -d: -f1)
    if [ -z "$log_start" ]; then
        log_start=$(_task_workflow_first_line "$task_file" "attempts")
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
        _task_workflow_body "$task_file" "attempts" 2>/dev/null | sed -n '/^- \[/ { p; q; }'
    fi
}

latest_execution_test_signal() {
    local task_file="$1"
    local signal

    signal=$(section_body "$task_file" "## Execution Log" 2>/dev/null \
        | sed -n '/^- \[.*\] \(GREEN\|VERIFY\|REFACTOR\):/ { s/^- \[[^]]*\] //; p; q; }')

    if [ -n "$signal" ]; then
        printf '%s\n' "$signal"
        return 0
    fi

    signal=$(latest_execution_log_entry "$task_file" | sed 's/^- \[[^]]*\] //')
    if [ -n "$signal" ]; then
        printf '%s\n' "$signal"
    fi

    return 0
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

ensure_task_workflow_sections() {
    local task_file="$1"
    local exec_count exec_start tmp_file missing_left_off missing_attempts
    local left_off_count attempts_count

    exec_count=$(grep -c '^## Execution Log[[:space:]]*$' "$task_file")
    if [ "$exec_count" -gt 1 ]; then
        echo "Expected exactly one section: ## Execution Log" >&2
        return 1
    fi
    if [ "$exec_count" -eq 0 ]; then
        printf '\n## Execution Log\n' >> "$task_file"
    fi

    _normalize_task_workflow_section "$task_file" "left_off" || return 1
    _normalize_task_workflow_section "$task_file" "attempts" || return 1

    left_off_count=$(_task_workflow_count "$task_file" "left_off") || return 1
    attempts_count=$(_task_workflow_count "$task_file" "attempts") || return 1
    if [ "$left_off_count" -gt 1 ] || [ "$attempts_count" -gt 1 ]; then
        echo "Expected at most one logical Left Off At section and one logical Attempts section" >&2
        return 1
    fi

    missing_left_off=0
    missing_attempts=0
    [ "$left_off_count" -eq 0 ] && missing_left_off=1
    [ "$attempts_count" -eq 0 ] && missing_attempts=1
    if [ "$missing_left_off" -eq 0 ] && [ "$missing_attempts" -eq 0 ]; then
        return 0
    fi

    exec_start=$(grep -n '^## Execution Log[[:space:]]*$' "$task_file" | head -1 | cut -d: -f1)
    tmp_file=$(same_dir_temp_file "$task_file")

    awk -v exec_start="$exec_start" \
        -v missing_left_off="$missing_left_off" \
        -v missing_attempts="$missing_attempts" '
        NR == exec_start {
            if (missing_left_off == 1) {
                print "## Left Off At"
                print "Not started."
                print ""
            }
            if (missing_attempts == 1) {
                print "## Attempts"
                print "(none yet)"
                print ""
            }
        }
        { print }
    ' "$task_file" > "$tmp_file"

    mv "$tmp_file" "$task_file"
}

set_task_left_off_at() {
    local task_file="$1"
    local message="$2"
    local replacement_file=""

    ensure_task_workflow_sections "$task_file" || return 1

    replacement_file=$(mktemp)
    printf '%s\n' "$message" > "$replacement_file"
    _rewrite_task_workflow_section "$task_file" "left_off" "$replacement_file"
    rm -f "$replacement_file"
}

append_task_attempt() {
    local task_file="$1"
    local entry="$2"
    local current_body="" replacement_file=""

    ensure_task_workflow_sections "$task_file" || return 1
    current_body=$(_task_workflow_body "$task_file" "attempts" 2>/dev/null || true)

    replacement_file=$(mktemp)
    if [ -n "$current_body" ]; then
        printf '%s\n' "$current_body" | _filter_task_workflow_attempt_lines > "$replacement_file"
    fi

    if [ -s "$replacement_file" ]; then
        printf '%s\n' "$entry" >> "$replacement_file"
    else
        printf '%s\n' "$entry" > "$replacement_file"
    fi

    _rewrite_task_workflow_section "$task_file" "attempts" "$replacement_file"
    rm -f "$replacement_file"
}

finalize_v1_verification_handoff() {
    local task_file="$1"
    local left_off_message="$2"
    local attempt_entry="$3"

    ensure_task_workflow_sections "$task_file" || return 1
    set_task_status "$task_file" "needs verification" || return 1
    set_task_left_off_at "$task_file" "$left_off_message" || return 1
    append_task_attempt "$task_file" "$attempt_entry" || return 1
}

finalize_v2_task_metadata() {
    local task_file="$1"
    local final_phase="$2"
    local final_status="$3"
    local fix_cycles="$4"
    local extra_context="${5:-}"
    local script_dir="${SCRIPT_DIR:-.}"

    [[ -f "$task_file" ]] || return 0

    ensure_task_workflow_sections "$task_file" || return 0

    # Determine next-step hint
    local hint=""
    case "$final_status" in
        success|"needs verification")
            hint="Review execution diff and test results, then close." ;;
        human_review|needs-human-review)
            hint="See human-review-handoff.md or review-synthesis.md before proceeding." ;;
        blocked|pipeline-error)
            hint="Debug using execution-log.md and run-manifest.json, then retry." ;;
        interrupted)
            hint="Pipeline was interrupted. Resume or retry." ;;
        *)
            hint="Check artifacts and determine next steps." ;;
    esac

    if [[ -n "$extra_context" ]]; then
        hint="${hint} ${extra_context}"
    fi

    # Scan for artifacts
    local comp_dir=""
    local task_dir=""
    task_dir="$(dirname "$task_file")"
    comp_dir="${task_dir}/competitive"
    local artifacts=""
    local artifact_names=("execution-diff.patch" "execution-log.md" "review-synthesis.md" "fix-plan.md" "fix-execution.md" "revised-plan.md" "run-manifest.json")
    for af in "${artifact_names[@]}"; do
        if [[ -f "${comp_dir}/${af}" ]]; then
            if [[ -n "$artifacts" ]]; then
                artifacts="${artifacts}, ${af}"
            else
                artifacts="${af}"
            fi
        fi
    done
    [[ -n "$artifacts" ]] || artifacts="none"

    local left_off_msg="V2 competitive pipeline reached ${final_phase} (status: ${final_status}, fix cycles: ${fix_cycles}). Artifacts: ${artifacts}. Next: ${hint}"

    # Build Attempts entry
    local today=""
    today=$(date '+%Y-%m-%d')

    # Sum cost from logs/cost.csv
    local cost_clause=""
    local cost_csv="${task_dir}/logs/cost.csv"
    if [[ -f "$cost_csv" ]]; then
        local total_cost=""
        total_cost=$(awk -F',' 'NR > 1 && $11 != "" { sum += $11 } END { printf "%.4f", sum + 0 }' "$cost_csv")
        if [[ -n "$total_cost" && "$total_cost" != "0.0000" ]]; then
            cost_clause=", cost: \$${total_cost}"
        fi
    fi

    local attempt_entry="- ${today}: V2 competitive run → reached ${final_phase}, status: ${final_status}, fix cycles: ${fix_cycles}${cost_clause} → ${final_status}"

    set_task_left_off_at "$task_file" "$left_off_msg" || true
    append_task_attempt "$task_file" "$attempt_entry" || true
}

_preflight_dependency_check() {
    local task_file="$1"
    local force="${2:-false}"
    local open_root dep_body own_status slug dep_file dep_status
    local script_dir="${SCRIPT_DIR:-.}"

    [[ -f "$task_file" ]] || return 0

    open_root="$script_dir/docs/tasks/open"

    # Parse ## Depends On section via section_body, fall back to inline grep
    dep_body=$(section_body "$task_file" "## Depends On" 2>/dev/null || true)
    if [[ -z "$dep_body" ]]; then
        # Try inline Depends On: field
        dep_body=$(grep -i '^Depends On:' "$task_file" 2>/dev/null | head -1 | sed 's/^[Dd]epends [Oo]n:[[:space:]]*//' || true)
    fi

    [[ -n "$dep_body" ]] || return 0

    local has_error=0
    local slug_list=""
    # Extract slugs: strip bullets, backticks, commas, trim
    slug_list=$(printf '%s\n' "$dep_body" \
        | sed 's/^[[:space:]]*[-*][[:space:]]*//' \
        | sed 's/`//g' \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^$')

    while IFS= read -r slug; do
        [[ -n "$slug" ]] || continue

        # Resolve dep task file
        dep_file=""
        if [[ -f "${open_root}/${slug}/task.md" ]]; then
            dep_file="${open_root}/${slug}/task.md"
        elif [[ -f "${open_root}/${slug}.md" ]]; then
            dep_file="${open_root}/${slug}.md"
        elif [[ -f "$script_dir/docs/tasks/closed/${slug}.md" ]]; then
            dep_file="$script_dir/docs/tasks/closed/${slug}.md"
        else
            # Not found anywhere — pass conservatively
            continue
        fi

        dep_status=$(grep '^## Status: ' "$dep_file" 2>/dev/null | head -1 | sed 's/^## Status: //')

        if [[ "$dep_status" != "closed" ]]; then
            if [[ "$force" == "true" ]]; then
                echo "WARN: Dependency '${slug}' has status '${dep_status}' (not closed) — force flag overrides" >&2
            else
                echo "ERROR: Dependency '${slug}' has status '${dep_status}' (expected 'closed')" >&2
                has_error=1
            fi
        fi
    done <<< "$slug_list"

    return "$has_error"
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
    local left_off_count attempts_count

    for section in "${required_sections[@]}"; do
        if ! grep -q "^${section}" "$task_file"; then
            echo -e "${RED}Missing section: ${section}${NC}"
            valid=false
        fi
    done

    left_off_count=$(_task_workflow_count "$task_file" "left_off") || left_off_count=0
    attempts_count=$(_task_workflow_count "$task_file" "attempts") || attempts_count=0

    if [ "$left_off_count" -gt 1 ]; then
        echo -e "${RED}Duplicate logical section: ## Left Off At${NC}"
        valid=false
    fi
    if [ "$attempts_count" -gt 1 ]; then
        echo -e "${RED}Duplicate logical section: ## Attempts${NC}"
        valid=false
    fi

    if [ "$valid" = true ]; then
        return 0
    else
        return 1
    fi
}

_v1_list_canonical_open_task_markdown_files() {
    local task_root="${SCRIPT_DIR}/docs/tasks/open"
    [[ -d "$task_root" ]] || return 0

    find "$task_root" -type f -name '*.md' \
        ! -path '*/competitive/*' \
        ! -path '*/logs/*' | LC_ALL=C sort
}

_v1_relpath_from_script_dir() {
    local abs_path="$1"
    case "$abs_path" in
        "$SCRIPT_DIR"/*)
            printf '%s\n' "${abs_path#"$SCRIPT_DIR"/}"
            ;;
        *)
            printf '%s\n' "$abs_path"
            ;;
    esac
}

_v1_snapshot_canonical_open_task_files() {
    local snapshot_dir="$1"
    local active_task_file="${2:-}"
    local abs_path rel_path

    mkdir -p "$snapshot_dir" || return 1

    while IFS= read -r abs_path; do
        [[ -n "$active_task_file" && "$abs_path" == "$active_task_file" ]] && continue
        rel_path=$(_v1_relpath_from_script_dir "$abs_path")
        mkdir -p "$snapshot_dir/$(dirname "$rel_path")" || return 1
        cp "$abs_path" "$snapshot_dir/$rel_path" || return 1
    done < <(_v1_list_canonical_open_task_markdown_files)
}

_v1_detect_canonical_open_task_file_drift() {
    local snapshot_dir="$1"
    local active_task_file="$2"
    local output_file="${3:-}"
    local abs_path rel_path current_path

    if [[ -n "$output_file" ]]; then
        : > "$output_file" || return 1
    fi

    while IFS= read -r abs_path; do
        rel_path="${abs_path#"$snapshot_dir"/}"
        current_path="$SCRIPT_DIR/$rel_path"
        if [[ ! -f "$current_path" ]]; then
            printf 'deleted\t%s\n' "$rel_path"
        elif ! cmp -s "$abs_path" "$current_path"; then
            printf 'modified\t%s\n' "$rel_path"
        fi
    done < <(find "$snapshot_dir" -type f -name '*.md' | LC_ALL=C sort) \
        | {
            if [[ -n "$output_file" ]]; then
                cat > "$output_file"
            else
                cat
            fi
        }

    while IFS= read -r abs_path; do
        [[ "$abs_path" == "$active_task_file" ]] && continue
        rel_path=$(_v1_relpath_from_script_dir "$abs_path")
        [[ -f "$snapshot_dir/$rel_path" ]] && continue
        if [[ -n "$output_file" ]]; then
            printf 'created\t%s\n' "$rel_path" >> "$output_file"
        else
            printf 'created\t%s\n' "$rel_path"
        fi
    done < <(_v1_list_canonical_open_task_markdown_files)
}

_v1_format_canonical_open_task_file_drift() {
    local drift_file="$1"

    awk -F'\t' '
        NF >= 2 {
            if (!seen[$1]++) {
                order[++count] = $1
            }
            paths[$1] = paths[$1] (paths[$1] ? ", " : "") $2
        }
        END {
            for (i = 1; i <= count; i++) {
                kind = order[i]
                printf "%s%s: %s", (i > 1 ? "; " : ""), kind, paths[kind]
            }
            if (count > 0) {
                printf "\n"
            }
        }
    ' "$drift_file"
}

_v1_restore_canonical_open_task_file_drift() {
    local snapshot_dir="$1"
    local drift_file="$2"
    local quarantine_root="$3"
    local status rel_path snapshot_path live_path quarantine_path

    while IFS=$'\t' read -r status rel_path; do
        [[ -n "$status" && -n "$rel_path" ]] || continue
        case "$status" in
            modified|deleted)
                snapshot_path="$snapshot_dir/$rel_path"
                live_path="$SCRIPT_DIR/$rel_path"
                [[ -f "$snapshot_path" ]] || return 1
                mkdir -p "$(dirname "$live_path")" || return 1
                cp "$snapshot_path" "$live_path" || return 1
                ;;
            created)
                live_path="$SCRIPT_DIR/$rel_path"
                [[ -e "$live_path" ]] || continue
                [[ -n "$quarantine_root" ]] || return 1
                quarantine_path="$quarantine_root/$rel_path"
                mkdir -p "$(dirname "$quarantine_path")" || return 1
                mv "$live_path" "$quarantine_path" || return 1
                ;;
            *)
                echo "Unknown V1 task drift status: $status" >&2
                return 1
                ;;
        esac
    done < "$drift_file"
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
    goal_line="$(_verify_extract_goal "$task_file" 2>/dev/null || true)"

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
    [[ "${LAUREN_LOOP_EFFECTIVE_STRICT:-${LAUREN_LOOP_STRICT:-false}}" == "true" ]]
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
            local task_slug
            task_slug=$(basename "$src_dir")
            local v2_lock_pid=""
            if [ -f "$v2_lock_dir/$task_slug/pid" ]; then
                v2_lock_pid=$(tr -d '[:space:]' < "$v2_lock_dir/$task_slug/pid" 2>/dev/null || true)
            fi
            if [[ -n "$v2_lock_pid" ]] && kill -0 "$v2_lock_pid" 2>/dev/null; then
                echo "WARN: closing $src_dir will relocate competitive/ artifacts while lauren-loop-v2.sh PID $v2_lock_pid is active on '$task_slug'. Verify it is not using this task before continuing." >&2
            else
                echo "WARN: closing $src_dir will relocate competitive/ artifacts to docs/tasks/closed. Verify no V2 session is active on '$task_slug' before continuing." >&2
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

_traditional_dev_proxy_trim_line() {
    printf '%s\n' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

_traditional_dev_proxy_unique_nonblank_lines() {
    awk 'NF { if (!seen[$0]++) print $0 }'
}

_normalize_xml_task_path_token() {
    local raw="$1"
    raw=$(printf '%s\n' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    raw="${raw#./}"
    raw="${raw#\`}"
    raw="${raw%\`}"
    case "$raw" in
        ""|"N/A"|"n/a"|"None"|"none")
            return 1
            ;;
    esac
    [[ "$raw" == *"/"* || "$raw" == *"."* ]] || return 1
    printf '%s\n' "$raw"
}

_extract_xml_task_paths() {
    local source_file="$1"
    {
        awk '
            {
                line = $0
                while (match(line, /<files>[^<]+<\/files>/)) {
                    inner = substr(line, RSTART + 7, RLENGTH - 15)
                    print inner
                    line = substr(line, RSTART + RLENGTH)
                }
            }
        ' "$source_file" 2>/dev/null || true
    } | while IFS= read -r raw_content; do
        if [[ "$raw_content" == *,* ]]; then
            printf '%s\n' "$raw_content" | tr ',' '\n'
        else
            printf '%s\n' "$raw_content" | awk '{for(i=1;i<=NF;i++) print $i}'
        fi
    done \
        | while IFS= read -r path; do
            _normalize_xml_task_path_token "$path" || true
        done \
        | awk 'NF && !seen[$0]++'
}

_reject_slug_internal_paths() {
    local slug="$1"
    local path=""
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        case "$path" in
            "docs/tasks/open/${slug}/task.md"|\
            "docs/tasks/open/${slug}/competitive/"*|\
            "docs/tasks/open/${slug}/logs/"*|\
            competitive/*|\
            logs/*)
                ;;
            *)
                printf '%s\n' "$path"
                ;;
        esac
    done
}

_traditional_dev_proxy_normalize_scope_path() {
    local raw="$1"
    raw=$(_traditional_dev_proxy_trim_line "$raw")
    raw="${raw#./}"
    raw="${raw#\`}"
    raw="${raw%\`}"
    case "$raw" in
        ""|"N/A"|"n/a"|"None"|"none")
            return 1
            ;;
    esac
    [[ "$raw" == *"/"* || "$raw" == *"."* ]] || return 1
    printf '%s\n' "$raw"
}

_traditional_dev_proxy_extract_files_to_modify_paths() {
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
            _traditional_dev_proxy_normalize_scope_path "$path" || true
        done \
        | _traditional_dev_proxy_unique_nonblank_lines
}

_traditional_dev_proxy_extract_relevant_file_paths() {
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
            _traditional_dev_proxy_normalize_scope_path "$path" || true
        done \
        | _traditional_dev_proxy_unique_nonblank_lines
}

_traditional_dev_proxy_slug_from_task_file() {
    local task_file="$1"
    case "$task_file" in
        */task.md)
            basename "$(dirname "$task_file")"
            ;;
        *.md)
            basename "$task_file" .md
            ;;
        *)
            return 1
            ;;
    esac
}

_traditional_dev_proxy_competitive_dir() {
    local task_file="$1"
    local slug=""
    slug=$(_traditional_dev_proxy_slug_from_task_file "$task_file") || return 1
    case "$task_file" in
        */task.md)
            printf '%s/competitive\n' "$(dirname "$task_file")"
            ;;
        *.md)
            printf '%s/%s/competitive\n' "$(dirname "$task_file")" "$slug"
            ;;
        *)
            return 1
            ;;
    esac
}

_traditional_dev_proxy_is_engineering_path() {
    local path="$1"
    path=$(_traditional_dev_proxy_trim_line "$path")
    path="${path#./}"
    [[ -n "$path" ]] || return 1

    case "$path" in
        docs/*|logs/*|competitive/*|*.md|*.markdown|*.txt)
            return 1
            ;;
        */competitive/*|*/logs/*)
            return 1
            ;;
    esac

    case "$path" in
        */)
            return 0
            ;;
        test_*.sh|*/test_*.sh|*.py|*.sh|*.js|*.jsx|*.ts|*.tsx|*.css|*.scss|*.html|*.sql|*.json|*.yml|*.yaml|*.toml|*.ini)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_traditional_dev_proxy_filter_engineering_paths() {
    local path=""
    while IFS= read -r path; do
        path=$(_traditional_dev_proxy_trim_line "$path")
        [[ -n "$path" ]] || continue
        path="${path#./}"
        if _traditional_dev_proxy_is_engineering_path "$path"; then
            printf '%s\n' "$path"
        fi
    done | _traditional_dev_proxy_unique_nonblank_lines
}

_traditional_dev_proxy_collect_changed_files() {
    local before_sha="${1:-}"
    if [[ -n "$before_sha" ]]; then
        git diff "$before_sha"..HEAD --name-only 2>/dev/null || true
    fi
    git diff --cached --name-only 2>/dev/null || true
    git diff --name-only 2>/dev/null || true
}

_traditional_dev_proxy_sum_numstat() {
    local kind="$1"
    local before_sha="$2"
    shift 2
    local -a scope_args=("$@")
    local output=""

    case "$kind" in
        committed)
            [[ -n "$before_sha" ]] || { echo "0 0"; return 0; }
            if [[ ${#scope_args[@]} -gt 0 ]]; then
                output=$(git diff --numstat "$before_sha"..HEAD -- "${scope_args[@]}" 2>/dev/null || true)
            else
                output=$(git diff --numstat "$before_sha"..HEAD 2>/dev/null || true)
            fi
            ;;
        staged)
            if [[ ${#scope_args[@]} -gt 0 ]]; then
                output=$(git diff --cached --numstat -- "${scope_args[@]}" 2>/dev/null || true)
            else
                output=$(git diff --cached --numstat 2>/dev/null || true)
            fi
            ;;
        unstaged)
            if [[ ${#scope_args[@]} -gt 0 ]]; then
                output=$(git diff --numstat -- "${scope_args[@]}" 2>/dev/null || true)
            else
                output=$(git diff --numstat 2>/dev/null || true)
            fi
            ;;
        *)
            echo "0 0"
            return 0
            ;;
    esac

    printf '%s\n' "$output" | awk '$1!="-"{i+=$1; d+=$2}END{print i+0, d+0}'
}

_TRADITIONAL_DEV_PROXY_SCOPE_SOURCE=""
_TRADITIONAL_DEV_PROXY_SCOPE_PATHS=""

_traditional_dev_proxy_resolve_scope_paths() {
    local task_file="$1"
    local route="${2:-}"
    local before_sha="${3:-}"
    local scope_paths=""
    local comp_dir=""

    _TRADITIONAL_DEV_PROXY_SCOPE_SOURCE=""
    _TRADITIONAL_DEV_PROXY_SCOPE_PATHS=""
    route=$(printf '%s\n' "$route" | tr '[:upper:]' '[:lower:]')

    if [[ -n "$task_file" && -f "$task_file" ]]; then
        if [[ "$route" == "v2" || ( -z "$route" && -d "$(_traditional_dev_proxy_competitive_dir "$task_file" 2>/dev/null)" ) ]]; then
            comp_dir=$(_traditional_dev_proxy_competitive_dir "$task_file" 2>/dev/null || true)
            if [[ -n "$comp_dir" ]]; then
                scope_paths=$(
                    {
                        _traditional_dev_proxy_extract_files_to_modify_paths "$comp_dir/revised-plan.md"
                        _extract_xml_task_paths "$comp_dir/revised-plan.md"
                        _traditional_dev_proxy_extract_files_to_modify_paths "$comp_dir/fix-plan.md"
                        _extract_xml_task_paths "$comp_dir/fix-plan.md"
                    } | _traditional_dev_proxy_unique_nonblank_lines
                )
                if [[ -n "$scope_paths" ]]; then
                    _TRADITIONAL_DEV_PROXY_SCOPE_SOURCE="plan-scope"
                    _TRADITIONAL_DEV_PROXY_SCOPE_PATHS="$scope_paths"
                    return 0
                fi
            fi
        fi

        if [[ "$route" != "v2" ]]; then
            scope_paths=$(_traditional_dev_proxy_extract_files_to_modify_paths "$task_file")
            if [[ -n "$scope_paths" ]]; then
                _TRADITIONAL_DEV_PROXY_SCOPE_SOURCE="task-files-to-modify"
                _TRADITIONAL_DEV_PROXY_SCOPE_PATHS="$scope_paths"
                return 0
            fi
        fi

        scope_paths=$(_traditional_dev_proxy_extract_relevant_file_paths "$task_file")
        if [[ -n "$scope_paths" ]]; then
            _TRADITIONAL_DEV_PROXY_SCOPE_SOURCE="task-relevant-files"
            _TRADITIONAL_DEV_PROXY_SCOPE_PATHS="$scope_paths"
            return 0
        fi
    fi

    scope_paths=$(
        _traditional_dev_proxy_collect_changed_files "$before_sha" \
            | while IFS= read -r path; do
                _traditional_dev_proxy_normalize_scope_path "$path" || true
            done \
            | _traditional_dev_proxy_unique_nonblank_lines
    )
    if [[ -n "$scope_paths" ]]; then
        _TRADITIONAL_DEV_PROXY_SCOPE_SOURCE="fallback-changed-files"
        _TRADITIONAL_DEV_PROXY_SCOPE_PATHS="$scope_paths"
    else
        _TRADITIONAL_DEV_PROXY_SCOPE_SOURCE="fallback-empty"
        _TRADITIONAL_DEV_PROXY_SCOPE_PATHS=""
    fi
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
    local goal_text=""
    goal_text="$(_task_goal_content "$task_file")" || return 1
    printf '%s\n' "$goal_text" | _trim_joined_text
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
TRADITIONAL_DEV_PROXY_VERSION="v2-cocomo-frozen-snapshot-1"

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
    if [[ -n "${_PIPELINE_START_TS:-}" ]]; then
        local wall_dur=$(( $(date +%s) - _PIPELINE_START_TS ))
        [[ "$wall_dur" -lt 0 ]] && wall_dur=0
        printf '  %-28s %s\n' "Duration:" "$(format_auto_duration "$wall_dur")"
    fi
    printf '  %-28s $%s\n' "Total:" "$total_cost"
    printf '  %-28s ~$%s\n' "Linear equivalent:" "$linear_cost"
    printf '  %-28s +$%s (+%s%%)\n' "Competitive premium:" "$premium" "$pct"
    local trad_proxy=""
    trad_proxy=$(resolve_traditional_dev_proxy_summary "${_PIPELINE_PRE_SHA:-}" "${_CURRENT_TASK_FILE:-}" "v2" 2>/dev/null) || trad_proxy=""
    if [[ -n "$trad_proxy" ]]; then
        printf '  %-28s %s\n' "Traditional Dev Proxy:" "$trad_proxy"
    fi
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

_traditional_dev_proxy_points_per_hour() {
    if [[ -n "${TRADITIONAL_DEV_PROXY_POINTS_PER_HOUR:-}" ]]; then
        printf '%s\n' "$TRADITIONAL_DEV_PROXY_POINTS_PER_HOUR"
    elif [[ -n "${COCOMO_SLOC_PER_HOUR:-}" ]]; then
        printf '%s\n' "$COCOMO_SLOC_PER_HOUR"
    else
        printf '%s\n' "20"
    fi
}

_traditional_dev_proxy_hourly_rate_usd() {
    if [[ -n "${TRADITIONAL_DEV_PROXY_HOURLY_RATE_USD:-}" ]]; then
        printf '%s\n' "$TRADITIONAL_DEV_PROXY_HOURLY_RATE_USD"
    elif [[ -n "${COCOMO_OFFSHORE_RATE:-}" ]]; then
        printf '%s\n' "$COCOMO_OFFSHORE_RATE"
    else
        printf '%s\n' "55"
    fi
}

_traditional_dev_proxy_multiplier() {
    if [[ -n "${TRADITIONAL_DEV_PROXY_MULTIPLIER:-}" ]]; then
        printf '%s\n' "$TRADITIONAL_DEV_PROXY_MULTIPLIER"
    elif [[ -n "${COCOMO_SDLC_MULTIPLIER:-}" ]]; then
        printf '%s\n' "$COCOMO_SDLC_MULTIPLIER"
    else
        printf '%s\n' "1"
    fi
}

_traditional_dev_proxy_format_decimal() {
    local value="${1:-0}" decimals="${2:-2}"
    awk -v value="$value" -v decimals="$decimals" 'BEGIN { printf "%.*f", decimals, value + 0 }' \
        | sed -E 's/(\.[0-9]*[1-9])0+$/\1/; s/\.0+$//'
}

_traditional_dev_proxy_standard_numstat_files_for_task() {
    local task_file="$1"
    local comp_dir=""
    comp_dir=$(_traditional_dev_proxy_competitive_dir "$task_file" 2>/dev/null || true)
    [[ -n "$comp_dir" && -d "$comp_dir" ]] || return 0
    find "$comp_dir" -maxdepth 1 -type f \( -name 'execution-diff.numstat.tsv' -o -name 'fix-diff-cycle*.numstat.tsv' \) | sort
}

_traditional_dev_proxy_estimate_numstat_files_for_task() {
    local task_file="$1"
    local comp_dir=""
    comp_dir=$(_traditional_dev_proxy_competitive_dir "$task_file" 2>/dev/null || true)
    [[ -n "$comp_dir" && -d "$comp_dir" ]] || return 0
    find "$comp_dir" -maxdepth 1 -type f \( -name 'execution-diff.estimate.numstat.tsv' -o -name 'fix-diff-cycle*.estimate.numstat.tsv' \) | sort
}

_traditional_dev_proxy_numstat_mode_for_task() {
    local task_file="$1"
    if _traditional_dev_proxy_estimate_numstat_files_for_task "$task_file" | grep -q .; then
        printf '%s\n' "estimate"
        return 0
    fi
    if _traditional_dev_proxy_standard_numstat_files_for_task "$task_file" | grep -q .; then
        printf '%s\n' "standard"
        return 0
    fi
    printf '%s\n' "none"
}

_traditional_dev_proxy_numstat_files_for_task() {
    local task_file="$1" mode="${2:-}"
    case "$mode" in
        estimate)
            _traditional_dev_proxy_estimate_numstat_files_for_task "$task_file"
            ;;
        standard)
            _traditional_dev_proxy_standard_numstat_files_for_task "$task_file"
            ;;
        *)
            if _traditional_dev_proxy_estimate_numstat_files_for_task "$task_file" | grep -q .; then
                _traditional_dev_proxy_estimate_numstat_files_for_task "$task_file"
            else
                _traditional_dev_proxy_standard_numstat_files_for_task "$task_file"
            fi
            ;;
    esac
}

_traditional_dev_proxy_rollup_numstats() {
    local task_file="$1" mode="${2:-}"
    local -a numstat_files=()
    local path=""

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        numstat_files+=("$path")
    done < <(_traditional_dev_proxy_numstat_files_for_task "$task_file" "$mode")

    [[ ${#numstat_files[@]} -gt 0 ]] || return 1

    awk -F'\t' '
        function is_test_path(path, lower) {
            lower = tolower(path)
            return (lower ~ /(^|\/)tests\// || lower ~ /(^|\/)__tests__\// || lower ~ /\.test\.[^\/]+$/ || lower ~ /(^|\/)test_[^\/]+\.sh$/)
        }

        function is_config_like(path, lower) {
            lower = tolower(path)
            return (lower ~ /\.(json|yml|yaml|toml|ini|css|scss|html)$/)
        }

        function is_engineering(path, lower) {
            lower = tolower(path)
            if (lower ~ /^docs\// || lower ~ /^logs\// || lower ~ /^competitive\// || lower ~ /\/competitive\// || lower ~ /\/logs\//) {
                return 0
            }
            if (lower ~ /\.(md|markdown|txt)$/) {
                return 0
            }
            return (is_test_path(path) || is_config_like(path) || lower ~ /\.(py|sh|js|jsx|ts|tsx|sql)$/)
        }

        NF >= 3 {
            ins = $1
            del = $2
            path = $3

            if (ins == "-" || del == "-") {
                next
            }
            if (!is_engineering(path)) {
                next
            }

            insertions += ins + 0
            deletions += del + 0
            seen[path] = 1
        }

        END {
            files_count = 0
            for (path in seen) {
                files_count++
            }
            if (files_count == 0 && insertions == 0 && deletions == 0) {
                exit 1
            }
            printf "%d\t%d\t%d\t%d\n", files_count, insertions + 0, deletions + 0, (insertions + 0) - (deletions + 0)
        }
    ' "${numstat_files[@]}"
}

_traditional_dev_proxy_summary_text() {
    local scope_label="$1" base_hours="$2" base_cost="$3" loaded_hours="$4" loaded_cost="$5"
    local net_sloc="$6" insertions="$7" deletions="$8" points_per_hour="$9" hourly_rate="${10}" loaded_multiplier="${11}"
    local hours_display cost_display

    hours_display=$(_traditional_dev_proxy_format_decimal "$base_hours" 1)
    cost_display=$(_traditional_dev_proxy_format_decimal "$base_cost" 0)
    local points_display rate_display
    points_display=$(_traditional_dev_proxy_format_decimal "$points_per_hour" 0)
    rate_display=$(_traditional_dev_proxy_format_decimal "$hourly_rate" 0)

    if [[ "$loaded_multiplier" != "1" && "$loaded_multiplier" != "1.0" && "$loaded_multiplier" != "1.00" ]]; then
        local loaded_hours_display loaded_cost_display mult_display
        loaded_hours_display=$(_traditional_dev_proxy_format_decimal "$loaded_hours" 1)
        loaded_cost_display=$(_traditional_dev_proxy_format_decimal "$loaded_cost" 0)
        mult_display=$(_traditional_dev_proxy_format_decimal "$loaded_multiplier" 1)
        printf '~%sh / ~$%s; loaded ~%sh / ~$%s (COCOMO-inspired heuristic; %s net lines at %s SLOC/hr × $%s/hr; %sx SDLC)' \
            "$hours_display" "$cost_display" "$loaded_hours_display" "$loaded_cost_display" "$net_sloc" "$points_display" "$rate_display" "$mult_display"
    else
        printf '~%sh / ~$%s (COCOMO-inspired heuristic; %s net lines at %s SLOC/hr × $%s/hr)' \
            "$hours_display" "$cost_display" "$net_sloc" "$points_display" "$rate_display"
    fi
}

_traditional_dev_proxy_no_changes_summary_text() {
    printf 'N/A  (no scoped engineering changes)'
}

_traditional_dev_proxy_net_deletion_summary_text() {
    local insertions="$1" deletions="$2" scope_label="${3:-scoped}"
    printf 'N/A  (%s net deletion: +%d/-%d)' "$scope_label" "$insertions" "$deletions"
}

_traditional_dev_proxy_artifact_path() {
    local task_file="$1"
    local comp_dir=""
    comp_dir=$(_traditional_dev_proxy_competitive_dir "$task_file" 2>/dev/null || true)
    [[ -n "$comp_dir" ]] || return 1
    printf '%s/traditional-dev-proxy.json\n' "$comp_dir"
}

write_persisted_v2_traditional_dev_proxy_json() {
    local task_file="$1" proxy_json="$2"
    local artifact="" tmp_file=""

    [[ -n "$proxy_json" && "$proxy_json" != "null" ]] || return 0
    artifact=$(_traditional_dev_proxy_artifact_path "$task_file" 2>/dev/null || true)
    [[ -n "$artifact" ]] || return 0

    mkdir -p "$(dirname "$artifact")" || return 1
    tmp_file=$(same_dir_temp_file "$artifact") || return 1
    if command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$proxy_json" | jq '.' > "$tmp_file" 2>/dev/null || {
            rm -f "$tmp_file"
            return 1
        }
    else
        printf '%s\n' "$proxy_json" > "$tmp_file"
    fi
    mv "$tmp_file" "$artifact" || { rm -f "$tmp_file"; return 1; }
}

read_persisted_v2_traditional_dev_proxy_json() {
    local task_file="$1"
    local comp_dir="" manifest="" artifact="" persisted_json=""

    command -v jq >/dev/null 2>&1 || return 0

    artifact=$(_traditional_dev_proxy_artifact_path "$task_file" 2>/dev/null || true)
    if [[ -n "$artifact" && -f "$artifact" ]]; then
        jq -c '.' "$artifact" 2>/dev/null || true
        return 0
    fi

    comp_dir=$(_traditional_dev_proxy_competitive_dir "$task_file" 2>/dev/null || true)
    [[ -n "$comp_dir" ]] || return 0
    manifest="${comp_dir}/run-manifest.json"
    [[ -f "$manifest" ]] || return 0

    persisted_json=$(jq -c '.traditional_dev_proxy // empty | select(type == "object")' "$manifest" 2>/dev/null || true)
    if [[ -n "$persisted_json" ]]; then
        write_persisted_v2_traditional_dev_proxy_json "$task_file" "$persisted_json" || true
        printf '%s\n' "$persisted_json"
    fi
}

build_v2_traditional_dev_proxy_json() {
    local task_file="$1" fix_cycles="${2:-0}"
    local numstat_mode=""
    local rollup=""
    local files_count=0 total_ins=0 total_del=0 rolled_net_lines=0
    local sloc_rate hourly_rate loaded_multiplier
    local net_sloc="" base_hours="" base_cost="" loaded_hours="" loaded_cost="" summary_text=""
    local scope_source="frozen-v2-numstat"

    command -v jq >/dev/null 2>&1 || { printf '%s\n' "null"; return 0; }

    numstat_mode=$(_traditional_dev_proxy_numstat_mode_for_task "$task_file")
    case "$numstat_mode" in
        estimate)
            scope_source="frozen-v2-estimate-numstat"
            ;;
        standard)
            scope_source="frozen-v2-numstat"
            ;;
        none)
            printf '%s\n' "null"
            return 0
            ;;
    esac

    rollup=$(_traditional_dev_proxy_rollup_numstats "$task_file" "$numstat_mode" 2>/dev/null) || {
        sloc_rate=$(_traditional_dev_proxy_points_per_hour)
        hourly_rate=$(_traditional_dev_proxy_hourly_rate_usd)
        loaded_multiplier=$(_traditional_dev_proxy_multiplier)
        summary_text=$(_traditional_dev_proxy_no_changes_summary_text)
        jq -n \
            --arg version "$TRADITIONAL_DEV_PROXY_VERSION" \
            --arg scope_source "$scope_source" \
            --arg summary_text "$summary_text" \
            --argjson files_count 0 \
            --argjson insertions 0 \
            --argjson deletions 0 \
            --argjson net_lines 0 \
            --argjson sloc_per_hour "$sloc_rate" \
            --argjson hourly_rate_usd "$hourly_rate" \
            --argjson loaded_multiplier "$loaded_multiplier" \
            --argjson estimated_hours_base 0 \
            --argjson estimated_cost_usd_base 0 \
            --argjson estimated_hours_loaded 0 \
            --argjson estimated_cost_usd_loaded 0 \
            --argjson fix_cycles "$fix_cycles" \
            '{
                version: $version,
                scope_source: $scope_source,
                files_count: $files_count,
                insertions: $insertions,
                deletions: $deletions,
                net_lines: $net_lines,
                sloc_per_hour: $sloc_per_hour,
                hourly_rate_usd: $hourly_rate_usd,
                loaded_multiplier: $loaded_multiplier,
                estimated_hours_base: $estimated_hours_base,
                estimated_cost_usd_base: $estimated_cost_usd_base,
                estimated_hours_loaded: $estimated_hours_loaded,
                estimated_cost_usd_loaded: $estimated_cost_usd_loaded,
                fix_cycles: $fix_cycles,
                summary_text: $summary_text
            }'
        return 0
    }
    IFS=$'\t' read -r files_count total_ins total_del rolled_net_lines <<< "$rollup"

    sloc_rate=$(_traditional_dev_proxy_points_per_hour)
    hourly_rate=$(_traditional_dev_proxy_hourly_rate_usd)
    loaded_multiplier=$(_traditional_dev_proxy_multiplier)
    net_sloc=$(( rolled_net_lines ))

    if [[ "$net_sloc" -le 0 ]]; then
        summary_text=$(_traditional_dev_proxy_net_deletion_summary_text "$total_ins" "$total_del" "frozen scoped")
        jq -n \
            --arg version "$TRADITIONAL_DEV_PROXY_VERSION" \
            --arg scope_source "$scope_source" \
            --arg summary_text "$summary_text" \
            --argjson files_count "$files_count" \
            --argjson insertions "$total_ins" \
            --argjson deletions "$total_del" \
            --argjson net_lines "$net_sloc" \
            --argjson sloc_per_hour "$sloc_rate" \
            --argjson hourly_rate_usd "$hourly_rate" \
            --argjson loaded_multiplier "$loaded_multiplier" \
            --argjson estimated_hours_base 0 \
            --argjson estimated_cost_usd_base 0 \
            --argjson estimated_hours_loaded 0 \
            --argjson estimated_cost_usd_loaded 0 \
            --argjson fix_cycles "$fix_cycles" \
            '{
                version: $version,
                scope_source: $scope_source,
                files_count: $files_count,
                insertions: $insertions,
                deletions: $deletions,
                net_lines: $net_lines,
                sloc_per_hour: $sloc_per_hour,
                hourly_rate_usd: $hourly_rate_usd,
                loaded_multiplier: $loaded_multiplier,
                estimated_hours_base: $estimated_hours_base,
                estimated_cost_usd_base: $estimated_cost_usd_base,
                estimated_hours_loaded: $estimated_hours_loaded,
                estimated_cost_usd_loaded: $estimated_cost_usd_loaded,
                fix_cycles: $fix_cycles,
                summary_text: $summary_text
            }'
        return 0
    fi

    base_hours=$(awk -v net_sloc="$net_sloc" -v sloc_rate="$sloc_rate" \
        'BEGIN { if ((sloc_rate + 0) <= 0) exit 1; printf "%.2f", (net_sloc + 0) / (sloc_rate + 0) }') || {
        printf '%s\n' "null"
        return 0
    }
    base_cost=$(awk -v hours="$base_hours" -v hourly_rate="$hourly_rate" \
        'BEGIN { printf "%.2f", (hours + 0) * (hourly_rate + 0) }')
    loaded_hours=$(awk -v base_hours="$base_hours" -v loaded_multiplier="$loaded_multiplier" \
        'BEGIN { printf "%.2f", (base_hours + 0) * (loaded_multiplier + 0) }')
    loaded_cost=$(awk -v base_cost="$base_cost" -v loaded_multiplier="$loaded_multiplier" \
        'BEGIN { printf "%.2f", (base_cost + 0) * (loaded_multiplier + 0) }')
    summary_text=$(_traditional_dev_proxy_summary_text "frozen scoped" "$base_hours" "$base_cost" "$loaded_hours" "$loaded_cost" "$net_sloc" "$total_ins" "$total_del" "$sloc_rate" "$hourly_rate" "$loaded_multiplier")

    jq -n \
        --arg version "$TRADITIONAL_DEV_PROXY_VERSION" \
        --arg scope_source "$scope_source" \
        --arg summary_text "$summary_text" \
        --argjson files_count "$files_count" \
        --argjson insertions "$total_ins" \
        --argjson deletions "$total_del" \
        --argjson net_lines "$net_sloc" \
        --argjson sloc_per_hour "$sloc_rate" \
        --argjson hourly_rate_usd "$hourly_rate" \
        --argjson loaded_multiplier "$loaded_multiplier" \
        --argjson estimated_hours_base "$base_hours" \
        --argjson estimated_cost_usd_base "$base_cost" \
        --argjson estimated_hours_loaded "$loaded_hours" \
        --argjson estimated_cost_usd_loaded "$loaded_cost" \
        --argjson fix_cycles "$fix_cycles" \
        '{
            version: $version,
            scope_source: $scope_source,
            files_count: $files_count,
            insertions: $insertions,
            deletions: $deletions,
            net_lines: $net_lines,
            sloc_per_hour: $sloc_per_hour,
            hourly_rate_usd: $hourly_rate_usd,
            loaded_multiplier: $loaded_multiplier,
            estimated_hours_base: $estimated_hours_base,
            estimated_cost_usd_base: $estimated_cost_usd_base,
            estimated_hours_loaded: $estimated_hours_loaded,
            estimated_cost_usd_loaded: $estimated_cost_usd_loaded,
            fix_cycles: $fix_cycles,
            summary_text: $summary_text
        }'
}

persist_v2_traditional_dev_proxy_json() {
    local task_file="$1" fix_cycles="${2:-0}"
    local proxy_json="null"

    command -v jq >/dev/null 2>&1 || {
        printf '%s\n' "$proxy_json"
        return 0
    }

    proxy_json=$(build_v2_traditional_dev_proxy_json "$task_file" "$fix_cycles" 2>/dev/null || echo "null")
    if [[ -n "$proxy_json" && "$proxy_json" != "null" ]]; then
        write_persisted_v2_traditional_dev_proxy_json "$task_file" "$proxy_json" || true
    fi
    printf '%s\n' "$proxy_json"
}

read_persisted_v2_traditional_dev_proxy_summary() {
    local task_file="$1"
    local persisted_json=""

    command -v jq >/dev/null 2>&1 || return 0

    persisted_json=$(read_persisted_v2_traditional_dev_proxy_json "$task_file")
    [[ -n "$persisted_json" ]] || return 0
    printf '%s\n' "$persisted_json" | jq -r '.summary_text // empty' 2>/dev/null || true
}

resolve_traditional_dev_proxy_summary() {
    local before_sha="${1:-}" task_file="${2:-}" route="${3:-}"
    local route_lc="" persisted_summary=""

    route_lc=$(printf '%s\n' "$route" | tr '[:upper:]' '[:lower:]')
    if [[ "$route_lc" == "v2" && -n "$task_file" ]]; then
        persisted_summary=$(read_persisted_v2_traditional_dev_proxy_summary "$task_file")
        if [[ -n "$persisted_summary" ]]; then
            printf '%s\n' "$persisted_summary"
            return 0
        fi
        printf '%s\n' "N/A  (traditional dev proxy unavailable before V2 diff capture)"
        return 0
    fi

    compute_cocomo_estimate "$before_sha" "$task_file" "$route"
}

compute_cocomo_estimate() {
    local before_sha="${1:-}"
    local task_file="${2:-}"
    local route="${3:-}"
    local sloc_rate=""
    local hourly_rate=""
    local loaded_multiplier=""
    local scope_paths=""
    local committed staged unstaged
    local total_ins total_del net_sloc
    local base_hours base_cost loaded_hours loaded_cost
    local -a scope_args=()
    local path=""

    sloc_rate=$(_traditional_dev_proxy_points_per_hour)
    hourly_rate=$(_traditional_dev_proxy_hourly_rate_usd)
    loaded_multiplier=$(_traditional_dev_proxy_multiplier)

    _traditional_dev_proxy_resolve_scope_paths "$task_file" "$route" "$before_sha"
    scope_paths=$(
        printf '%s\n' "$_TRADITIONAL_DEV_PROXY_SCOPE_PATHS" | _traditional_dev_proxy_filter_engineering_paths
    )
    _TRADITIONAL_DEV_PROXY_SCOPE_PATHS="$scope_paths"

    if [[ -z "$scope_paths" ]]; then
        echo "N/A  (no scoped engineering changes)"
        return 0
    fi

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        scope_args+=("$path")
    done <<< "$scope_paths"

    committed=$(_traditional_dev_proxy_sum_numstat committed "$before_sha" "${scope_args[@]}")
    staged=$(_traditional_dev_proxy_sum_numstat staged "$before_sha" "${scope_args[@]}")
    unstaged=$(_traditional_dev_proxy_sum_numstat unstaged "$before_sha" "${scope_args[@]}")
    total_ins=$(( ${committed%% *} + ${staged%% *} + ${unstaged%% *} ))
    total_del=$(( ${committed##* } + ${staged##* } + ${unstaged##* } ))

    if [[ "$total_ins" -eq 0 && "$total_del" -eq 0 ]]; then
        echo "N/A  (no scoped engineering changes)"
        return 0
    fi

    net_sloc=$(( total_ins - total_del ))
    if [[ "$net_sloc" -le 0 ]]; then
        printf 'N/A  (scoped net deletion: +%d/-%d)' "$total_ins" "$total_del"
        return 0
    fi

    base_hours=$(awk -v net_sloc="$net_sloc" -v sloc_rate="$sloc_rate" \
        'BEGIN { if ((sloc_rate + 0) <= 0) exit 1; printf "%.2f", (net_sloc + 0) / (sloc_rate + 0) }') || {
        echo "N/A"
        return 0
    }
    base_cost=$(awk -v hours="$base_hours" -v hourly_rate="$hourly_rate" \
        'BEGIN { printf "%.2f", (hours + 0) * (hourly_rate + 0) }')
    loaded_hours=$(awk -v base_hours="$base_hours" -v loaded_multiplier="$loaded_multiplier" \
        'BEGIN { printf "%.2f", (base_hours + 0) * (loaded_multiplier + 0) }')
    loaded_cost=$(awk -v base_cost="$base_cost" -v loaded_multiplier="$loaded_multiplier" \
        'BEGIN { printf "%.2f", (base_cost + 0) * (loaded_multiplier + 0) }')

    _traditional_dev_proxy_summary_text "scoped" "$base_hours" "$base_cost" "$loaded_hours" "$loaded_cost" "$net_sloc" "$total_ins" "$total_del" "$sloc_rate" "$hourly_rate" "$loaded_multiplier"
}

# ============================================================
# Duration formatting
# ============================================================

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

#!/usr/bin/env bash

task_context_normalize_title() {
    local title="$1"

    printf '%s\n' "${title}" | awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        {
            line = trim($0)
            sub(/^[Tt][Aa][Ss][Kk]:[[:space:]]*/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            print trim(line)
        }
    '
}

task_context_truncate_title() {
    local title="$1"

    if (( ${#title} <= 120 )); then
        printf '%s\n' "${title}"
        return 0
    fi

    printf '%.117s...\n' "${title}"
}

task_context_first_heading_title() {
    local task_file="$1"

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function is_metadata_heading(value_lower) {
            return value_lower ~ /^(task|status|created|execution mode|code review|left off at|attempts|motivation|goal|scope|context|relevant files|anti-patterns|done criteria|team structure|file ownership map|current plan|problem|background|verify commands|priority|depends on|complexity)(:|$)/
        }
        /^[#][#]?[[:space:]]+/ {
            line = $0
            sub(/^[#][#]?[[:space:]]+/, "", line)
            line = trim(line)
            line_lower = tolower(line)
            if (is_metadata_heading(line_lower)) {
                next
            }
            print line
            exit
        }
    ' "${task_file}"
}

task_context_status_is_excluded() {
    local normalized_status="$1"

    backlog_status_is_terminal "${normalized_status}" && return 0

    case "${normalized_status}" in
        reverted*|superseded*|closed*)
            return 0
            ;;
    esac

    return 1
}

task_context_has_task_metadata_field() {
    local task_file="$1"

    grep -Eq '^[#][#]?[[:space:]]+Task:[[:space:]]*' "${task_file}"
}

task_context_has_done_section() {
    local task_file="$1"

    grep -Eq '^##[[:space:]]+(Done Criteria|Done)[[:space:]]*:?[[:space:]]*$' "${task_file}"
}

task_context_has_attempts_section() {
    local task_file="$1"

    grep -Eq '^##[[:space:]]+Attempts[[:space:]]*:?[[:space:]]*$' "${task_file}"
}

task_context_has_shape_signal() {
    local task_file="$1"

    [[ "$(basename "${task_file}")" == "task.md" ]] && return 0
    task_context_has_task_metadata_field "${task_file}" && return 0
    task_context_has_done_section "${task_file}" && return 0
    task_context_has_attempts_section "${task_file}" && return 0
    return 1
}

task_context_collect_existing_open_tasks() {
    local tasks_dir="${REPO_ROOT}/docs/tasks/open"
    local task_file=""
    local status=""
    local task_title=""
    local heading_title=""
    local title=""
    local rel_path=""

    [[ -d "${tasks_dir}" ]] || return 0

    while IFS= read -r task_file; do
        status="$(backlog_normalize_status "$(backlog_extract_field_value "${task_file}" "status")")"
        [[ -n "${status}" ]] || continue
        if task_context_status_is_excluded "${status}"; then
            continue
        fi
        if ! task_context_has_shape_signal "${task_file}"; then
            continue
        fi

        task_title="$(task_context_normalize_title "$(backlog_extract_field_value "${task_file}" "task")")"
        heading_title="$(task_context_normalize_title "$(task_context_first_heading_title "${task_file}")")"

        title="${task_title}"
        if [[ -z "${title}" ]]; then
            title="${heading_title}"
        fi
        if [[ -z "${title}" && "$(basename "${task_file}")" == "task.md" ]]; then
            title="$(task_context_normalize_title "$(basename "$(dirname "${task_file}")")")"
        fi

        if [[ -z "${title}" ]]; then
            continue
        fi

        title="$(task_context_normalize_title "${title}")"
        title="$(task_context_truncate_title "${title}")"
        rel_path="$(backlog_relative_task_path "${task_file}")"
        printf '%s\t%s\t%s\n' "${rel_path}" "${title}" "${status}"
    done < <(find "${tasks_dir}" -type f -name '*.md' | LC_ALL=C sort)
}

task_context_existing_open_tasks_block() {
    local rows=()
    local rel_path=""
    local title=""
    local status=""
    local overflow_count=0

    while IFS=$'\t' read -r rel_path title status; do
        [[ -n "${rel_path}" ]] || continue
        if (( ${#rows[@]} >= 50 )); then
            overflow_count=$(( overflow_count + 1 ))
            continue
        fi
        rows+=("${rel_path}: ${title} [${status}]")
    done < <(task_context_collect_existing_open_tasks)

    printf '## Existing Open Tasks\n\n'
    if (( ${#rows[@]} == 0 )); then
        printf '(none)\n'
        return 0
    fi

    printf '%s\n' "${rows[@]}"
    if (( overflow_count > 0 )); then
        printf '(... and %s more)\n' "${overflow_count}"
    fi
}

task_context_snapshot_task_writer_prompt() {
    local rank="$1"
    local playbook_path="$2"
    local rendered_path=""
    local snapshot_path="${NIGHTSHIFT_RENDERED_DIR}/task-writer-rank-${rank}.md"

    rendered_path="$(agent_render_playbook "${playbook_path}")" || return 1
    mkdir -p "${NIGHTSHIFT_RENDERED_DIR}"
    cp "${rendered_path}" "${snapshot_path}" || return 1
    printf '%s\n' "${snapshot_path}"
}

#!/usr/bin/env bash
# lauren-bridge.sh — Bridge Night Shift digest entries into Lauren Loop V2.

if [[ -n "${_NIGHTSHIFT_LAUREN_BRIDGE_SH:-}" ]]; then
    return 0
fi
_NIGHTSHIFT_LAUREN_BRIDGE_SH=1

_nightshift_lauren_utils_path="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/lib/lauren-loop-utils.sh"
if [[ -r "${_nightshift_lauren_utils_path}" ]]; then
    # shellcheck disable=SC1090
    source "${_nightshift_lauren_utils_path}"
fi
unset _nightshift_lauren_utils_path

bridge_log() {
    printf '[%s] [nightshift-bridge] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

bridge_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

bridge_compact_text() {
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

bridge_slugify() {
    local raw="$1"
    printf '%s' "${raw}" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

bridge_relative_path() {
    local path="$1"
    if [[ -n "${REPO_ROOT:-}" && "${path}" == "${REPO_ROOT}/"* ]]; then
        printf '%s' "${path#${REPO_ROOT}/}"
    else
        printf '%s' "${path}"
    fi
}

bridge_severity_rank() {
    local severity
    severity="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "${severity}" in
        critical) printf '4\n' ;;
        major) printf '3\n' ;;
        minor) printf '2\n' ;;
        observation) printf '1\n' ;;
        *) printf '0\n' ;;
    esac
}

bridge_should_execute() {
    local severity_rank threshold_rank
    severity_rank="$(bridge_severity_rank "${1:-}")"
    threshold_rank="$(bridge_severity_rank "${NIGHTSHIFT_BRIDGE_MIN_SEVERITY:-major}")"
    [[ "${severity_rank}" =~ ^[0-9]+$ ]] || return 1
    [[ "${threshold_rank}" =~ ^[0-9]+$ ]] || return 1
    (( severity_rank > 0 && threshold_rank > 0 && severity_rank >= threshold_rank ))
}

bridge_runtime_slug_from_source_task() {
    local source_task_path="$1"
    local base_name=""
    base_name="$(basename "${source_task_path}" .md)"
    bridge_slugify "nightshift-bridge-${base_name}"
}

bridge_runtime_task_file_path() {
    local runtime_slug="$1"
    printf '%s/docs/tasks/open/%s/task.md' "${REPO_ROOT}" "${runtime_slug}"
}

bridge_extract_goal() {
    local task_file="$1"

    if [[ ! -f "${task_file}" ]]; then
        return 1
    fi

    declare -F _task_goal_content >/dev/null 2>&1 || return 1
    # Canonical Goal parsing lives in _task_goal_content().
    _task_goal_content "${task_file}"
}

bridge_ensure_v2_sections() {
    local task_file="$1"

    if declare -F ensure_sections >/dev/null 2>&1; then
        ensure_sections "${task_file}"
        return 0
    fi

    local section=""
    local sections=("## Current Plan" "## Critique" "## Plan History" "## Execution Log")
    for section in "${sections[@]}"; do
        if ! grep -q "^${section}" "${task_file}"; then
            printf '\n%s\n' "${section}" >> "${task_file}"
        fi
    done
}

bridge_create_fallback_task_file() {
    local target_file="$1"
    local title="$2"
    local severity="$3"
    local category="$4"
    local source_task_path="$5"

    mkdir -p "$(dirname "${target_file}")" || return 1
    cat > "${target_file}" <<EOF
## Task: ${title}
## Status: not started
## Created: ${RUN_DATE}
## Execution Mode: single-agent

## Motivation
Night Shift bridge created this runtime task because the digest referenced a finding but the manager-created source task file was unavailable at bridge time.

## Goal
Resolve the Night Shift finding titled "${title}" and leave clear verification evidence.

## Scope
### In Scope
- Investigate and fix the finding captured by the Night Shift digest entry

### Out of Scope
- Unrelated refactors outside the finding's scope

## Relevant Files
- \`${source_task_path}\` — manager task path referenced by the digest but unavailable during bridge creation

## Context
- Source: Night Shift bridge fallback task
- Severity: ${severity}
- Category: ${category}

## Anti-Patterns
- Do NOT guess beyond the digest entry when the source task is missing

## Done Criteria
- [ ] The finding titled "${title}" is resolved with verification evidence
- [ ] Relevant tests or validation steps pass

## Code Review: not started

## Left Off At
Created by Night Shift bridge because the source manager task file was unavailable.

## Attempts
(none)
EOF
}

bridge_value_looks_like_task_path() {
    local value="$1"
    value="${value//\`/}"
    value="$(bridge_trim "${value}")"
    [[ -n "${value}" ]] && ([[ "${value}" == */* ]] || [[ "${value}" == *.md ]])
}

bridge_digest_first_task_row() {
    local digest_path="$1"

    if [[ ! -f "${digest_path}" ]]; then
        return 1
    fi

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            gsub(/`/, "", value)
            return value
        }

        /^## Ranked Findings/ {
            in_table = 1
            next
        }

        in_table && /^## / {
            exit
        }

        !in_table {
            next
        }

        /^\|---/ {
            next
        }

        /^\|/ {
            if (!header_seen) {
                header_seen = 1
                next
            }

            rank = trim($2)
            first_payload = trim($3)
            second_payload = trim($4)
            title = trim($5)

            if (rank == "" && first_payload == "" && second_payload == "" && title == "") {
                next
            }

            printf "%s\t%s\t%s\t%s\n", rank, first_payload, second_payload, title
            exit
        }
    ' FS='|' "${digest_path}"
}

bridge_digest_is_triage_only() {
    local digest_path="$1"
    local first_row=""
    local rank=""
    local first_payload=""

    first_row="$(bridge_digest_first_task_row "${digest_path}" 2>/dev/null || true)"
    [[ -n "${first_row}" ]] || return 1

    IFS=$'\t' read -r rank first_payload _ <<< "${first_row}"
    bridge_value_looks_like_task_path "${first_payload}" && return 1

    [[ "$(bridge_trim "${rank}")" =~ ^[0-9]+$ ]]
}

bridge_parse_digest() {
    local digest_path="$1"

    if [[ ! -f "${digest_path}" ]]; then
        return 1
    fi

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        /^## Ranked Findings/ {
            in_table = 1
            next
        }

        in_table && /^## / {
            exit
        }

        !in_table {
            next
        }

        /^\|---/ || /^\|[[:space:]]*#/ {
            next
        }

        /^\|/ {
            file = trim($3)
            severity = tolower(trim($4))
            category = tolower(trim($5))
            title = trim($6)
            gsub(/`/, "", file)
            gsub(/[[:space:]]+\|[[:space:]]*$/, "", title)
            if (file == "" || severity == "" || title == "") {
                next
            }
            printf "%s\t%s\t%s\t%s\n", file, severity, category, title
        }
    ' FS='|' "${digest_path}"
}

bridge_manager_task_manifest_path() {
    local manifest_path=""

    # manager-task-manifest.txt is the Nightshift manifest fallback for triage-only digests.
    if declare -F manager_task_manifest_path >/dev/null 2>&1; then
        manifest_path="$(manager_task_manifest_path 2>/dev/null || true)"
    fi

    if [[ -z "${manifest_path}" && -n "${RUN_TMP_DIR:-}" ]]; then
        manifest_path="${RUN_TMP_DIR}/manager-task-manifest.txt"
    fi

    [[ -n "${manifest_path}" ]] || return 1
    printf '%s\n' "${manifest_path}"
}

bridge_resolve_source_task_path() {
    local task_path="$1"

    task_path="$(bridge_trim "${task_path}")"
    [[ -n "${task_path}" ]] || return 1

    if [[ "${task_path}" == /* ]]; then
        printf '%s\n' "${task_path}"
        return 0
    fi

    if [[ -n "${REPO_ROOT:-}" ]]; then
        printf '%s/%s\n' "${REPO_ROOT}" "${task_path}"
        return 0
    fi

    printf '%s\n' "${task_path}"
}

bridge_extract_task_title() {
    local task_file="$1"

    [[ -f "${task_file}" ]] || return 1

    awk '
        /^## Task:[[:space:]]*/ {
            title = $0
            sub(/^## Task:[[:space:]]*/, "", title)
            gsub(/[[:space:]]+$/, "", title)
            print title
            exit
        }
    ' "${task_file}"
}

bridge_create_task_file() {
    local source_task_path="$1"
    local severity="$2"
    local category="$3"
    local title="$4"
    local runtime_slug=""
    local runtime_task_file=""
    local runtime_task_dir=""

    runtime_slug="$(bridge_runtime_slug_from_source_task "${source_task_path}")"
    runtime_task_file="$(bridge_runtime_task_file_path "${runtime_slug}")"
    runtime_task_dir="$(dirname "${runtime_task_file}")"

    mkdir -p "${runtime_task_dir}" || {
        bridge_log "WARN: Failed to create runtime task dir: ${runtime_task_dir}"
        return 1
    }

    if [[ -f "${runtime_task_file}" ]]; then
        bridge_log "Reusing runtime task file: $(bridge_relative_path "${runtime_task_file}")"
    elif [[ -f "${source_task_path}" ]]; then
        if cp "${source_task_path}" "${runtime_task_file}"; then
            bridge_log "Prepared runtime task from source task: $(bridge_relative_path "${runtime_task_file}")"
        else
            bridge_log "WARN: Failed to copy source task into runtime task: $(bridge_relative_path "${source_task_path}")"
            return 1
        fi
    else
        if bridge_create_fallback_task_file "${runtime_task_file}" "${title}" "${severity}" "${category}" "$(bridge_relative_path "${source_task_path}")"; then
            bridge_log "Prepared fallback runtime task: $(bridge_relative_path "${runtime_task_file}")"
        else
            bridge_log "WARN: Failed to create fallback runtime task: $(bridge_relative_path "${runtime_task_file}")"
            return 1
        fi
    fi

    bridge_ensure_v2_sections "${runtime_task_file}" || {
        bridge_log "WARN: Failed to ensure Lauren Loop sections in $(bridge_relative_path "${runtime_task_file}")"
        return 1
    }

    printf '%s\t%s\n' "${runtime_slug}" "${runtime_task_file}"
}

bridge_cost_cap_for_remaining_slots() {
    local remaining_slots="$1"
    local spent="0.0000"

    if ! [[ "${remaining_slots}" =~ ^[0-9]+$ ]] || (( remaining_slots <= 0 )); then
        return 1
    fi

    spent="$(cost_total_value 2>/dev/null || echo "0.0000")"

    awk -v total="${NIGHTSHIFT_COST_CAP_USD}" \
        -v spent="${spent}" \
        -v per_task="${NIGHTSHIFT_BRIDGE_MAX_COST_PER_TASK:-25}" \
        -v slots="${remaining_slots}" '
        BEGIN {
            remaining = total - spent
            if (remaining <= 0 || per_task <= 0 || slots <= 0) {
                exit 1
            }
            cap = remaining / slots
            if (cap > per_task) {
                cap = per_task
            }
            if (cap <= 0) {
                exit 1
            }
            printf "%.2f\n", cap
        }
    '
}

bridge_invoke_lauren_loop() {
    local runtime_slug="$1"
    local runtime_task_file="$2"
    local remaining_slots="$3"
    local goal=""
    local cost_cap=""

    if ! goal="$(bridge_extract_goal "${runtime_task_file}" | bridge_compact_text)"; then
        goal=""
    fi
    if [[ -z "${goal}" ]]; then
        bridge_log "WARN: Runtime task has no usable goal: $(bridge_relative_path "${runtime_task_file}")"
        return 1
    fi

    if ! cost_cap="$(bridge_cost_cap_for_remaining_slots "${remaining_slots}")"; then
        bridge_log "WARN: Could not derive a positive Lauren Loop cost cap for ${runtime_slug}"
        return 1
    fi

    local exit_code=0
    bridge_log "Invoking Lauren Loop V2 for ${runtime_slug} (cost cap: \$${cost_cap})"
    if LAUREN_LOOP_MAX_COST="${cost_cap}" \
        LAUREN_LOOP_NONINTERACTIVE=1 \
        bash "${REPO_ROOT}/lauren-loop-v2.sh" "${runtime_slug}" "${goal}" --strict </dev/null; then
        bridge_log "Lauren Loop V2 completed for ${runtime_slug}"
        return 0
    else
        exit_code=$?
    fi

    bridge_log "WARN: Lauren Loop V2 failed for ${runtime_slug} with exit ${exit_code}"
    return 1
}

bridge_run() {
    local digest_path="$1"
    local dry_run_mode="${2:-false}"
    local candidate_entry=""
    local candidate_source=""
    local source_task_path=""
    local severity=""
    local category=""
    local title=""
    local selected=0
    local created=0
    local invoked=0
    local qualified=0
    local max_tasks="${NIGHTSHIFT_BRIDGE_MAX_TASKS:-3}"
    local runtime_info=""
    local runtime_slug=""
    local runtime_task_file=""
    local triage_only=0
    local manifest_path=""
    local manifest_entry=""
    local resolved_path=""
    local seen_manifest_path=""
    local manifest_path_seen=0
    local manifest_entries=()
    local candidate_rows=()
    local _seen_manifest_paths=()

    BRIDGE_STAGE_PATHS=()

    if [[ ! -f "${digest_path}" ]]; then
        bridge_log "WARN: Digest not found; bridge skipped (${digest_path})"
        return 0
    fi

    if ! [[ "${max_tasks}" =~ ^[0-9]+$ ]] || (( max_tasks <= 0 )); then
        bridge_log "WARN: Invalid NIGHTSHIFT_BRIDGE_MAX_TASKS='${max_tasks}'; bridge skipped"
        return 0
    fi

    if bridge_digest_is_triage_only "${digest_path}"; then
        triage_only=1
    fi

    if [[ "${triage_only}" -eq 1 ]]; then
        manifest_path="$(bridge_manager_task_manifest_path 2>/dev/null || true)"
        if [[ -n "${manifest_path}" && -s "${manifest_path}" ]]; then
            while IFS= read -r manifest_entry || [[ -n "${manifest_entry}" ]]; do
                manifest_entry="$(bridge_trim "${manifest_entry}")"
                [[ -n "${manifest_entry}" ]] || continue
                manifest_entries+=("${manifest_entry}")
            done < "${manifest_path}"
        fi

        if (( ${#manifest_entries[@]} > 0 )); then
            bridge_log "Bridge: digest is triage-only but task manifest exists with ${#manifest_entries[@]} task file(s). Reading paths from manifest."
            for manifest_entry in "${manifest_entries[@]}"; do
                resolved_path="$(bridge_resolve_source_task_path "${manifest_entry}" 2>/dev/null || true)"
                if [[ -n "${resolved_path}" ]]; then
                    manifest_path_seen=0
                    for seen_manifest_path in "${_seen_manifest_paths[@]-}"; do
                        if [[ "${seen_manifest_path}" == "${resolved_path}" ]]; then
                            manifest_path_seen=1
                            break
                        fi
                    done
                    if [[ "${manifest_path_seen}" -eq 1 ]]; then
                        bridge_log "WARN: Bridge: skipping duplicate manifest entry: ${resolved_path}"
                        continue
                    fi
                    _seen_manifest_paths+=("${resolved_path}")
                fi

                source_task_path="${resolved_path}"
                if [[ -z "${source_task_path}" || ! -f "${source_task_path}" ]]; then
                    bridge_log "WARN: Bridge: task file missing: ${source_task_path:-${manifest_entry}}"
                    continue
                fi

                title="$(bridge_extract_task_title "${source_task_path}" 2>/dev/null || true)"
                if [[ -z "${title}" ]]; then
                    title="$(bridge_relative_path "${source_task_path}")"
                fi

                candidate_rows+=("manifest"$'\t'"${source_task_path}"$'\t\t\t'"${title}")
            done
        fi

        if (( ${#candidate_rows[@]} == 0 )); then
            BRIDGE_SKIPPED=1
            bridge_log "Bridge skip: findings-manifest contains triage metadata only — no task files to materialize. Task-writer phase required."
            return 0
        fi
    else
        while IFS=$'\t' read -r source_task_path severity category title; do
            [[ -n "${source_task_path}" ]] || continue
            source_task_path="${REPO_ROOT}/$(bridge_trim "${source_task_path}")"
            candidate_rows+=("digest"$'\t'"${source_task_path}"$'\t'"${severity}"$'\t'"${category}"$'\t'"${title}")
        done < <(bridge_parse_digest "${digest_path}" 2>/dev/null || true)
    fi

    for candidate_entry in "${candidate_rows[@]-}"; do
        [[ -n "${candidate_entry}" ]] || continue
        IFS=$'\t' read -r candidate_source source_task_path severity category title <<< "${candidate_entry}"
        [[ -n "${source_task_path}" ]] || continue

        if [[ "${candidate_source}" == "digest" ]]; then
            if ! bridge_should_execute "${severity}"; then
                bridge_log "Skipping ${title}: severity ${severity} is below threshold ${NIGHTSHIFT_BRIDGE_MIN_SEVERITY}"
                continue
            fi
        else
            # Manifest entries are already severity-filtered by phase_task_writing().
            severity=""
            category=""
            if [[ ! -f "${source_task_path}" ]]; then
                bridge_log "WARN: Bridge: task file missing: ${source_task_path}"
                continue
            fi
        fi

        qualified=$(( qualified + 1 ))
        if (( selected >= max_tasks )); then
            bridge_log "Task cap reached (${max_tasks}); skipping remaining digest candidates"
            break
        fi

        runtime_slug="$(bridge_runtime_slug_from_source_task "${source_task_path}")"
        runtime_task_file="$(bridge_runtime_task_file_path "${runtime_slug}")"

        if [[ "${dry_run_mode}" == "true" ]]; then
            bridge_log "DRY RUN: would prepare runtime task $(bridge_relative_path "${runtime_task_file}") from $(bridge_relative_path "${source_task_path}")"
            if [[ "${NIGHTSHIFT_BRIDGE_AUTO_EXECUTE}" == "true" ]]; then
                bridge_log "DRY RUN: would invoke Lauren Loop V2 for ${runtime_slug}"
            fi
            selected=$(( selected + 1 ))
            continue
        fi

        runtime_info="$(bridge_create_task_file "${source_task_path}" "${severity}" "${category}" "${title}")" || {
            bridge_log "WARN: Failed to prepare runtime task for ${title}"
            selected=$(( selected + 1 ))
            continue
        }
        runtime_info="$(printf '%s\n' "${runtime_info}" | tail -n 1)"
        IFS=$'\t' read -r runtime_slug runtime_task_file <<< "${runtime_info}"
        BRIDGE_STAGE_PATHS+=("$(dirname "${runtime_task_file}")")
        created=$(( created + 1 ))
        selected=$(( selected + 1 ))

        if [[ "${NIGHTSHIFT_BRIDGE_AUTO_EXECUTE}" != "true" ]]; then
            bridge_log "Prepared runtime task without execution: $(bridge_relative_path "${runtime_task_file}")"
            continue
        fi

        if bridge_invoke_lauren_loop "${runtime_slug}" "${runtime_task_file}" "${max_tasks}"; then
            invoked=$(( invoked + 1 ))
        fi
    done

    bridge_log "Bridge summary: qualified=${qualified}, selected=${selected}, prepared=${created}, invoked=${invoked}, dry_run=${dry_run_mode}"
    return 0
}

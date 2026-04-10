#!/usr/bin/env bash
# notify.sh — Non-blocking digest summary rendering and transport helpers.

[[ -n "${_NIGHTSHIFT_NOTIFY_LOADED:-}" ]] && return 0
_NIGHTSHIFT_NOTIFY_LOADED=1

_notify_log() {
    printf '[%s] [nightshift-notify] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

_notify_format_duration() {
    local seconds="${1:-0}"
    local minutes=0
    local hours=0

    if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
        seconds=0
    fi

    hours=$(( seconds / 3600 ))
    minutes=$(( (seconds % 3600) / 60 ))
    seconds=$(( seconds % 60 ))

    if (( hours > 0 )); then
        printf '%dh %dm %ds' "$hours" "$minutes" "$seconds"
    else
        printf '%dm %ds' "$minutes" "$seconds"
    fi
}

_notify_extract_titles() {
    local digest_path="$1"
    [[ -f "$digest_path" ]] || return 0

    awk '
        /^### Finding:/ {
            sub(/^### Finding:[[:space:]]*/, "", $0)
            print
        }
    ' "$digest_path"
}

_notify_severity_counts() {
    local digest_path="$1"
    [[ -f "$digest_path" ]] || {
        printf '0 0 0 0\n'
        return 0
    }

    awk '
        BEGIN {
            critical = 0
            high = 0
            medium = 0
            low = 0
        }
        {
            line = tolower($0)
            gsub(/\*/, "", line)
            sub(/^[[:space:]]+/, "", line)
        }
        /^/ {
            if (line !~ /^severity:/) {
                next
            }
            if (line ~ /critical/) {
                critical++
            } else if (line ~ /high|major/) {
                high++
            } else if (line ~ /medium|minor/) {
                medium++
            } else if (line ~ /low|observation/) {
                low++
            }
        }
        END {
            printf "%d %d %d %d\n", critical, high, medium, low
        }
    ' "$digest_path"
}

_notify_log_tail() {
    local log_file="$1"
    [[ -f "$log_file" ]] || return 0
    tail -n 50 "$log_file" 2>/dev/null || true
}

notify_build_summary() {
    local digest_path="${1:-}"
    local pr_url="${2:-}"
    local cost_total="${3:-0.0000}"
    local run_duration_seconds="${4:-0}"
    local findings_count="${5:-0}"
    local failure_notes="${6:-}"
    local warning_notes="${7:-}"
    local log_file="${8:-}"
    local duration_text=""
    local critical=0
    local high=0
    local medium=0
    local low=0
    local titles=""
    local preview=""

    duration_text="$(_notify_format_duration "$run_duration_seconds")"
    read -r critical high medium low <<< "$(_notify_severity_counts "$digest_path")"
    titles="$(_notify_extract_titles "$digest_path")"
    preview="$(printf '%s\n' "$titles" | sed '/^$/d' | head -n 3)"

    printf 'Nightshift Detective Summary\n'
    printf 'Findings: %s findings\n' "$findings_count"
    printf 'Severity: critical=%s high=%s medium=%s low=%s\n' "$critical" "$high" "$medium" "$low"
    printf 'Cost: $%s\n' "$cost_total"
    printf 'Duration: %s\n' "$duration_text"
    if [[ -n "$pr_url" ]]; then
        printf 'PR: %s\n' "$pr_url"
    else
        printf 'PR: none\n'
    fi

    if (( findings_count > 0 )) && [[ -n "$preview" ]]; then
        printf '\nTop findings:\n'
        while IFS= read -r title; do
            [[ -z "$title" ]] && continue
            printf -- '- %.80s\n' "$title"
        done <<< "$preview"
    fi

    if [[ -n "$warning_notes" ]]; then
        printf '\nWarnings:\n'
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf -- '- %s\n' "$line"
        done <<< "$warning_notes"
    fi

    if [[ -n "$failure_notes" ]]; then
        printf '\nFailures:\n'
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf -- '- %s\n' "$line"
        done <<< "$failure_notes"
        if [[ -n "$log_file" && -f "$log_file" ]]; then
            printf '\nRecent log tail:\n'
            _notify_log_tail "$log_file"
        fi
    fi
}

notify_send_webhook() {
    local summary_text="${1:-}"
    local payload=""

    if [[ -z "${NIGHTSHIFT_WEBHOOK_URL:-}" ]]; then
        _notify_log "No webhook URL configured"
        return 0
    fi

    payload="$(jq -n --arg text "$summary_text" --arg run_date "$(date +%Y-%m-%d)" '{text: $text, run_date: $run_date}')" || {
        _notify_log "Failed to build webhook payload"
        return 0
    }

    if ! curl -s -m 30 -X POST -H "Content-Type: application/json" -d "$payload" "${NIGHTSHIFT_WEBHOOK_URL}" >/dev/null; then
        _notify_log "Webhook delivery failed"
    fi

    return 0
}

notify_send_email() {
    local summary_text="${1:-}"

    if [[ -z "${NIGHTSHIFT_NOTIFY_EMAIL:-}" ]]; then
        _notify_log "No notify email configured"
        return 0
    fi

    if ! {
        printf 'To: %s\n' "${NIGHTSHIFT_NOTIFY_EMAIL}"
        printf 'Subject: Nightshift Detective Summary\n'
        printf '\n%s\n' "$summary_text"
    } | sendmail -t; then
        _notify_log "Email delivery failed"
    fi

    return 0
}

notify_dispatch() {
    local digest_path="${1:-}"
    local pr_url="${2:-}"
    local cost_total="${3:-0.0000}"
    local run_duration_seconds="${4:-0}"
    local findings_count="${5:-0}"
    local failure_notes="${6:-}"
    local warning_notes="${7:-}"
    local log_file="${8:-}"
    local summary=""

    summary="$(notify_build_summary \
        "$digest_path" \
        "$pr_url" \
        "$cost_total" \
        "$run_duration_seconds" \
        "$findings_count" \
        "$failure_notes" \
        "$warning_notes" \
        "$log_file")"

    notify_send_webhook "$summary"
    notify_send_email "$summary"
    return 0
}

#!/usr/bin/env bash
# cost-tracker.sh — Token cost tracking for Nightshift detective runs.
# Sourced by the orchestrator. Requires nightshift.conf to be sourced first.
# State is kept in a JSON file managed by jq. All logging goes to stderr.

# Guard against double-sourcing
[[ -n "${_NIGHTSHIFT_COST_TRACKER_LOADED:-}" ]] && return 0
_NIGHTSHIFT_COST_TRACKER_LOADED=1

# ── Internal Helpers ──────────────────────────────────────────────────────────

_ns_log() {
    printf '[%s] [nightshift-cost] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

# Write content to a file atomically (temp file + mv).
_ns_atomic_write() {
    local target="$1" content="$2"
    local tmp="${target}.tmp.$$"
    printf '%s\n' "$content" > "$tmp" && mv -f "$tmp" "$target"
}

# Append content to a file atomically (temp file + cat >> + rm).
_ns_atomic_append() {
    local target="$1" content="$2"
    local tmp="${target}.tmp.$$"
    printf '%s\n' "$content" > "$tmp" && cat "$tmp" >> "$target" && rm -f "$tmp"
}

# ISO 8601 timestamp, cross-platform.
_ns_iso_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

# Normalize bc output: ensure leading zero, default to 0.0000.
_ns_normalize_decimal() {
    local val="$1"
    [[ -z "$val" ]] && val="0.0000"
    [[ "$val" == .* ]] && val="0${val}"
    [[ "$val" == -\.* ]] && val="-0${val#-}"
    echo "$val"
}

# Format token count for display (e.g., 50000 → "50.0K").
_ns_format_tokens() {
    local n="${1:-0}"
    if (( n >= 1000000 )); then
        printf '%.1fM' "$(echo "scale=1; $n / 1000000" | bc)"
    elif (( n >= 1000 )); then
        printf '%.1fK' "$(echo "scale=1; $n / 1000" | bc)"
    else
        echo "$n"
    fi
}

# ── Pricing Resolution ───────────────────────────────────────────────────────

# Given a model string, return "input_price output_price cache_write_price cache_read_price".
_cost_resolve_rates() {
    local model="${1:-}"
    local input_price output_price cache_write_price cache_read_price

    case "$model" in
        *opus*)
            input_price="$NIGHTSHIFT_CLAUDE_OPUS_INPUT_PRICE"
            output_price="$NIGHTSHIFT_CLAUDE_OPUS_OUTPUT_PRICE"
            cache_write_price="$NIGHTSHIFT_CLAUDE_OPUS_CACHE_WRITE_PRICE"
            cache_read_price="$NIGHTSHIFT_CLAUDE_OPUS_CACHE_READ_PRICE"
            ;;
        *sonnet*)
            input_price="$NIGHTSHIFT_CLAUDE_SONNET_INPUT_PRICE"
            output_price="$NIGHTSHIFT_CLAUDE_SONNET_OUTPUT_PRICE"
            cache_write_price="$NIGHTSHIFT_CLAUDE_SONNET_CACHE_WRITE_PRICE"
            cache_read_price="$NIGHTSHIFT_CLAUDE_SONNET_CACHE_READ_PRICE"
            ;;
        *codex*|*gpt*|*openai*)
            input_price="$NIGHTSHIFT_CODEX_INPUT_PRICE"
            output_price="$NIGHTSHIFT_CODEX_OUTPUT_PRICE"
            cache_write_price="0"
            cache_read_price="0"
            ;;
        *)
            _ns_log "WARN: Unknown model '$model', using Sonnet pricing"
            input_price="$NIGHTSHIFT_CLAUDE_SONNET_INPUT_PRICE"
            output_price="$NIGHTSHIFT_CLAUDE_SONNET_OUTPUT_PRICE"
            cache_write_price="$NIGHTSHIFT_CLAUDE_SONNET_CACHE_WRITE_PRICE"
            cache_read_price="$NIGHTSHIFT_CLAUDE_SONNET_CACHE_READ_PRICE"
            ;;
    esac

    echo "$input_price $output_price $cache_write_price $cache_read_price"
}

# ── Public Functions ──────────────────────────────────────────────────────────

# Initialize or reset the cost tracking state file.
# Usage: cost_init [run_id]
cost_init() {
    local run_id="${1:-nightshift-$(date +%Y-%m-%d)-$$}"
    local state_file="${NIGHTSHIFT_COST_STATE_FILE}"
    local started_at
    started_at="$(_ns_iso_timestamp)"

    local json
    json=$(jq -n \
        --arg run_id "$run_id" \
        --arg started_at "$started_at" \
        '{
            run_id: $run_id,
            started_at: $started_at,
            cumulative_usd: "0.0000",
            call_count: 0,
            last_call_cost: "0.0000",
            consecutive_high_cost_count: 0,
            calls: []
        }')

    if [[ $? -ne 0 ]] || [[ -z "$json" ]]; then
        _ns_log "ERROR: Failed to create initial state JSON (is jq installed?)"
        return 1
    fi

    _ns_atomic_write "$state_file" "$json"
    _ns_log "Cost tracker initialized: run_id=$run_id state=$state_file"
    return 0
}

# Record a single agent call's cost.
# Usage: cost_record_call agent_name model playbook_name input_tokens output_tokens [cache_create_tokens] [cache_read_tokens]
# Prints the call cost (USD) to stdout.
cost_record_call() {
    local agent="$1" model="$2" playbook="$3"
    local input_tokens="${4:-0}" output_tokens="${5:-0}"
    local cache_create_tokens="${6:-0}" cache_read_tokens="${7:-0}"
    local state_file="${NIGHTSHIFT_COST_STATE_FILE}"
    local timestamp
    timestamp="$(_ns_iso_timestamp)"

    # Calculate cost
    local cost_usd cost_source
    if (( input_tokens == 0 && output_tokens == 0 && cache_create_tokens == 0 && cache_read_tokens == 0 )); then
        cost_usd="$NIGHTSHIFT_PER_CALL_CAP_USD"
        cost_source="fallback"
        _ns_log "WARN: Zero tokens for $agent/$playbook — assuming worst case \$$cost_usd"
    else
        local rates input_price output_price cache_write_price cache_read_price
        rates=$(_cost_resolve_rates "$model")
        read -r input_price output_price cache_write_price cache_read_price <<< "$rates"
        cost_usd=$(echo "scale=6; ($input_tokens / 1000000 * $input_price) + ($output_tokens / 1000000 * $output_price) + ($cache_create_tokens / 1000000 * $cache_write_price) + ($cache_read_tokens / 1000000 * $cache_read_price)" | bc)
        cost_usd=$(_ns_normalize_decimal "$cost_usd")
        cost_usd=$(printf '%.4f' "$cost_usd")
        cost_source="parsed"
    fi

    # Determine if this call is over the runaway threshold.
    # Fallback costs are excluded — a jq parse regression should warn, not kill the run.
    local over_threshold=0
    if [[ "$cost_source" == "parsed" ]]; then
        local threshold_check
        threshold_check=$(echo "$cost_usd >= $NIGHTSHIFT_RUNAWAY_THRESHOLD_USD" | bc)
        [[ "$threshold_check" == "1" ]] && over_threshold=1
    fi

    # Update state file atomically
    local updated
    updated=$(jq \
        --arg cost "$cost_usd" \
        --arg cost_source "$cost_source" \
        --arg agent "$agent" \
        --arg model "$model" \
        --arg playbook "$playbook" \
        --argjson input_tokens "$input_tokens" \
        --argjson output_tokens "$output_tokens" \
        --argjson cache_create_tokens "$cache_create_tokens" \
        --argjson cache_read_tokens "$cache_read_tokens" \
        --arg timestamp "$timestamp" \
        --argjson over_threshold "$over_threshold" \
        '
        .call_count += 1 |
        .last_call_cost = $cost |
        .cumulative_usd = ((.cumulative_usd | tonumber) + ($cost | tonumber) | tostring | split(".") |
            if length == 1 then .[0] + ".0000"
            elif (.[1] | length) < 4 then .[0] + "." + .[1] + ("0" * (4 - (.[1] | length)))
            else .[0] + "." + .[1][:4]
            end) |
        .consecutive_high_cost_count = (if $over_threshold == 1 then .consecutive_high_cost_count + 1 else 0 end) |
        .calls += [{
            agent: $agent,
            model: $model,
            playbook: $playbook,
            input_tokens: $input_tokens,
            output_tokens: $output_tokens,
            cache_create_tokens: $cache_create_tokens,
            cache_read_tokens: $cache_read_tokens,
            cost_usd: $cost,
            cost_source: $cost_source,
            timestamp: $timestamp
        }]
        ' "$state_file")

    if [[ $? -ne 0 ]] || [[ -z "$updated" ]]; then
        _ns_log "ERROR: Failed to update cost state for $agent/$playbook"
        echo "$cost_usd"
        return 1
    fi

    _ns_atomic_write "$state_file" "$updated"

    # Append to CSV
    local cumulative
    cumulative=$(echo "$updated" | jq -r '.cumulative_usd')
    cost_append_csv "$timestamp" "$agent" "$model" "$playbook" \
        "$input_tokens" "$output_tokens" "$cache_create_tokens" "$cache_read_tokens" \
        "$cost_usd" "$cost_source" "$cumulative"

    _ns_log "Recorded: $agent model=$model playbook=$playbook in=$(_ns_format_tokens "$input_tokens") cache_w=$(_ns_format_tokens "$cache_create_tokens") cache_r=$(_ns_format_tokens "$cache_read_tokens") out=$(_ns_format_tokens "$output_tokens") cost=\$$cost_usd ($cost_source) cumulative=\$$cumulative"

    # Return the cost
    echo "$cost_usd"
    return 0
}

# Check if cumulative spend has exceeded the cost cap.
# Returns: 0 = under cap, 1 = over cap.
cost_check_cap() {
    local state_file="${NIGHTSHIFT_COST_STATE_FILE}"
    local cumulative
    cumulative=$(jq -r '.cumulative_usd' "$state_file" 2>/dev/null)
    cumulative="${cumulative:-0}"

    local over
    over=$(echo "$cumulative >= $NIGHTSHIFT_COST_CAP_USD" | bc)
    if [[ "$over" == "1" ]]; then
        _ns_log "COST CAP EXCEEDED: \$$cumulative >= \$$NIGHTSHIFT_COST_CAP_USD"
        return 1
    fi
    return 0
}

# Check if a given cost exceeded the per-call cap.
# Usage: cost_check_per_call <cost_usd>
# Returns: 0 = under cap, 1 = over cap. Logs warning on breach.
cost_check_per_call() {
    local cost_usd="${1:-0}"
    local over
    over=$(echo "$cost_usd >= $NIGHTSHIFT_PER_CALL_CAP_USD" | bc)
    if [[ "$over" == "1" ]]; then
        _ns_log "PER-CALL CAP WARNING: \$$cost_usd >= \$$NIGHTSHIFT_PER_CALL_CAP_USD"
        return 1
    fi
    return 0
}

# Check for runaway spending (N consecutive calls over threshold).
# Returns: 0 = no runaway, 1 = runaway detected.
cost_check_runaway() {
    local state_file="${NIGHTSHIFT_COST_STATE_FILE}"
    local consecutive
    consecutive=$(jq -r '.consecutive_high_cost_count' "$state_file" 2>/dev/null)
    consecutive="${consecutive:-0}"

    if (( consecutive >= NIGHTSHIFT_RUNAWAY_CONSECUTIVE )); then
        _ns_log "RUNAWAY DETECTED: $consecutive consecutive calls exceeding \$$NIGHTSHIFT_RUNAWAY_THRESHOLD_USD"
        return 1
    fi
    return 0
}

# Print the current cumulative spend to stdout.
cost_get_total() {
    local state_file="${NIGHTSHIFT_COST_STATE_FILE}"
    jq -r '.cumulative_usd' "$state_file" 2>/dev/null || echo "0.0000"
}

# Print a formatted cost summary to stdout.
cost_get_summary() {
    local state_file="${NIGHTSHIFT_COST_STATE_FILE}"

    if [[ ! -f "$state_file" ]]; then
        echo "No cost data available."
        return 1
    fi

    local run_id cumulative call_count
    run_id=$(jq -r '.run_id' "$state_file")
    cumulative=$(jq -r '.cumulative_usd' "$state_file")
    call_count=$(jq -r '.call_count' "$state_file")

    echo "=== Nightshift Cost Summary: $run_id ==="

    # Per-call breakdown
    jq -r '.calls[] | "  \(.agent) (\(.model))  $\(.cost_usd) [\(.cost_source)]  (\(.input_tokens) in / \(.cache_create_tokens // 0) cw / \(.cache_read_tokens // 0) cr / \(.output_tokens) out)"' "$state_file"

    echo "  ─────────────────────────────────────────"
    echo "  Total:  \$$cumulative"
    echo "  Calls:  $call_count"
    echo "  Cap:    \$$NIGHTSHIFT_COST_CAP_USD"
}

# Print a 7-day cost summary from the historical CSV.
# Usage: cost_weekly_summary
cost_weekly_summary() {
    local csv_file="${NIGHTSHIFT_COST_CSV}"
    local rows=""
    local total="0.0000"

    printf 'date,cost_usd\n'

    if [[ ! -f "$csv_file" ]] || [[ ! -s "$csv_file" ]]; then
        printf 'total,%s\n' "$total"
        return 0
    fi

    rows=$(awk -F',' '
        NR == 1 { next }
        NF < 9 { next }
        {
            split($1, parts, "T")
            date = parts[1]
            if (date == "") {
                next
            }
            sums[date] += ($9 + 0)
        }
        END {
            for (date in sums) {
                printf "%s,%.4f\n", date, sums[date]
            }
        }
    ' "$csv_file" | sort -r | head -n 7)

    if [[ -z "$rows" ]]; then
        printf 'total,%s\n' "$total"
        return 0
    fi

    printf '%s\n' "$rows"
    total=$(printf '%s\n' "$rows" | awk -F',' '{ sum += ($2 + 0) } END { printf "%.4f", sum + 0 }')
    printf 'total,%s\n' "$total"
}

# Append a row to the cost history CSV.
# Usage: cost_append_csv timestamp agent model playbook input_tokens output_tokens cache_create_tokens cache_read_tokens cost_usd cost_source cumulative_usd
cost_append_csv() {
    local timestamp="$1" agent="$2" model="$3" playbook="$4"
    local input_tokens="$5" output_tokens="$6"
    local cache_create_tokens="$7" cache_read_tokens="$8"
    local cost_usd="$9" cost_source="${10}" cumulative_usd="${11}"
    local csv_file="${NIGHTSHIFT_COST_CSV}"

    # Ensure log directory exists
    mkdir -p "$(dirname "$csv_file")"

    # Ensure header exists
    if [[ ! -f "$csv_file" ]] || [[ ! -s "$csv_file" ]]; then
        echo "timestamp,agent,model,playbook,input_tokens,output_tokens,cache_create_tokens,cache_read_tokens,cost_usd,cost_source,cumulative_usd" > "$csv_file"
    fi

    local row="${timestamp},${agent},${model},${playbook},${input_tokens},${output_tokens},${cache_create_tokens},${cache_read_tokens},${cost_usd},${cost_source},${cumulative_usd}"
    _ns_atomic_append "$csv_file" "$row"
}

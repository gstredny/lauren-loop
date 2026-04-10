#!/usr/bin/env bash
# agent-runner.sh — Agent invocation wrapper for Nightshift detective runs.
# Sourced by the orchestrator. Requires nightshift.conf and cost-tracker.sh
# to be sourced first.

# Guard against double-sourcing
[[ -n "${_NIGHTSHIFT_AGENT_RUNNER_LOADED:-}" ]] && return 0
_NIGHTSHIFT_AGENT_RUNNER_LOADED=1

# ── Internal Helpers ──────────────────────────────────────────────────────────

# Portable timeout wrapper — uses GNU timeout if available, falls back to
# a background-process implementation that works on stock macOS.
_agent_timeout() {
    local seconds="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout "$seconds" "$@"
    else
        "$@" &
        local pid=$!
        ( sleep "$seconds" && kill "$pid" 2>/dev/null ) &
        local watcher=$!
        wait "$pid" 2>/dev/null
        local rc=$?
        kill "$watcher" 2>/dev/null
        wait "$watcher" 2>/dev/null
        # If the process was killed by our watcher, map to exit 124
        # (matching GNU timeout convention)
        if [[ $rc -eq 137 ]] || [[ $rc -eq 143 ]]; then
            return 124
        fi
        return $rc
    fi
}

_agent_log() {
    printf '[%s] [nightshift-agent] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

_agent_permission_profile() {
    local playbook_name="$1"
    local perms_dir="${REPO_ROOT}/scripts/nightshift/permissions"

    case "$playbook_name" in
        commit-detective|coverage-detective|security-detective|validation-agent|task-writer)
            echo "${perms_dir}/detective-readonly.json"
            ;;
        conversation-detective|error-detective|product-detective|rcfa-detective|performance-detective)
            echo "${perms_dir}/detective-db.json"
            ;;
        manager-merge)
            echo "${perms_dir}/manager-write.json"
            ;;
        *)
            # Unknown playbook — fail closed to the most restrictive profile.
            echo "${perms_dir}/detective-readonly.json"
            ;;
    esac
}

_agent_codex_sandbox() {
    local playbook_name="$1"

    case "$playbook_name" in
        conversation-detective|error-detective|product-detective|rcfa-detective|performance-detective|manager-merge)
            echo "workspace-write"
            ;;
        commit-detective|coverage-detective|security-detective|validation-agent|task-writer)
            echo "read-only"
            ;;
        *)
            echo "read-only"
            ;;
    esac
}

# ── Template Rendering ────────────────────────────────────────────────────────

# Render a playbook template by substituting {{VAR}} placeholders.
# Usage: agent_render_playbook <template_path>
# Prints the rendered file path to stdout.
agent_render_playbook() {
    local template_path="$1"
    if [[ ! -f "$template_path" ]]; then
        _agent_log "ERROR: Playbook template not found: $template_path"
        return 1
    fi

    local basename
    basename=$(basename "$template_path")
    local rendered_path="${NIGHTSHIFT_RENDERED_DIR}/${basename}"
    mkdir -p "$NIGHTSHIFT_RENDERED_DIR"

    local today run_id
    today=$(date +%Y-%m-%d)
    run_id="${NIGHTSHIFT_RUN_ID:-${today}-$$}"

    sed \
        -e "s|{{DATE}}|${today}|g" \
        -e "s|{{RUN_ID}}|${run_id}|g" \
        -e "s|{{REPO_ROOT}}|${REPO_ROOT}|g" \
        -e "s|{{TASK_FILE_PATH}}|${NIGHTSHIFT_TASK_FILE_PATH:-}|g" \
        -e "s|{{COMMIT_WINDOW_DAYS}}|${NIGHTSHIFT_COMMIT_WINDOW_DAYS}|g" \
        -e "s|{{CONVERSATION_WINDOW_DAYS}}|${NIGHTSHIFT_CONVERSATION_WINDOW_DAYS}|g" \
        -e "s|{{MAX_CONVERSATIONS}}|${NIGHTSHIFT_MAX_CONVERSATIONS}|g" \
        -e "s|{{RCFA_WINDOW_DAYS}}|${NIGHTSHIFT_RCFA_WINDOW_DAYS}|g" \
        -e "s|{{MAX_FINDINGS}}|${NIGHTSHIFT_MAX_FINDINGS_PER_DETECTIVE}|g" \
        -e "s|{{MAX_TASK_FILES}}|${NIGHTSHIFT_MAX_TASK_FILES}|g" \
        -e "s|{{BASE_BRANCH}}|${NIGHTSHIFT_BASE_BRANCH}|g" \
        "$template_path" > "$rendered_path"

    # FINDING_TEXT may span multiple lines, so render it in a second pass instead
    # of forcing it through sed's single-line replacement path.
    if grep -q '{{FINDING_TEXT}}' "$rendered_path"; then
        local finding_rendered_path="${rendered_path}.finding"
        NIGHTSHIFT_RENDER_FINDING_TEXT="${NIGHTSHIFT_FINDING_TEXT:-}" \
            perl -0pe 's/\{\{FINDING_TEXT\}\}/$ENV{NIGHTSHIFT_RENDER_FINDING_TEXT}/g' \
            "$rendered_path" > "$finding_rendered_path"
        mv "$finding_rendered_path" "$rendered_path"
    fi

    _agent_log "Rendered playbook: $basename → $rendered_path"
    echo "$rendered_path"
}

# ── Token Extraction ──────────────────────────────────────────────────────────

agent_extract_json_line() {
    local output_file="$1"

    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        _agent_log "WARN: Output file missing or empty: $output_file"
        return 1
    fi

    grep -m1 '^{' "$output_file" 2>/dev/null
}

agent_extract_claude_result_text() {
    local output_file="$1"
    local json_line=""
    local result_text=""

    json_line="$(agent_extract_json_line "$output_file" || true)"
    if [[ -z "$json_line" ]]; then
        _agent_log "WARN: No JSON object found in $output_file"
        return 1
    fi

    result_text="$(
        echo "$json_line" | jq -r '
            if (.result? | type) == "string" then
                .result
            elif (.message?.content? | type) == "array" then
                [
                    .message.content[]?
                    | select((.type? // "text") == "text")
                    | (.text // empty)
                ] | join("\n")
            elif (.content? | type) == "array" then
                [
                    .content[]?
                    | select((.type? // "text") == "text")
                    | (.text // empty)
                ] | join("\n")
            elif (.message? | type) == "string" then
                .message
            elif (.output_text? | type) == "string" then
                .output_text
            else
                empty
            end
        ' 2>/dev/null
    )"

    if [[ -z "$result_text" ]] || [[ "$result_text" == "null" ]]; then
        _agent_log "WARN: Failed to parse Claude result text from $output_file"
        return 1
    fi

    printf '%s\n' "$result_text"
}

agent_summarize_text_preview() {
    local text="${1:-}"
    local max_chars="${2:-160}"

    text="$(
        printf '%s' "$text" \
            | tr '\r\n\t' '   ' \
            | awk '{$1=$1; print}'
    )"

    if [[ -z "$text" ]]; then
        return 0
    fi

    if (( max_chars > 3 && ${#text} > max_chars )); then
        text="${text:0:max_chars-3}..."
    fi

    printf '%s\n' "$text"
}

agent_output_preview() {
    local output_file="$1"
    local max_chars="${2:-160}"
    local preview=""

    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        return 0
    fi

    preview="$(agent_extract_claude_result_text "$output_file" 2>/dev/null || true)"
    if [[ -z "$preview" ]]; then
        preview="$(sed -n '1p' "$output_file" 2>/dev/null || true)"
    fi

    agent_summarize_text_preview "$preview" "$max_chars"
}

# Extract token counts from Claude --output-format json output.
# Claude CLI writes a status line to stdout before the JSON object,
# so we use tail -1 to grab only the JSON line.
# Usage: agent_extract_tokens <output_file>
# Prints: "input_tokens cache_create_tokens cache_read_tokens output_tokens" (space-separated).
# Falls back to "0 0 0 0" if file is missing, empty, or unparseable.
agent_extract_tokens() {
    local output_file="$1"

    local json_line
    json_line=$(agent_extract_json_line "$output_file" || true)

    if [[ -z "$json_line" ]]; then
        _agent_log "WARN: No JSON object found in $output_file"
        echo "0 0 0 0"
        return 0
    fi

    local tokens
    tokens=$(echo "$json_line" | jq -r '[
        (.usage.input_tokens // 0),
        (.usage.cache_creation_input_tokens // 0),
        (.usage.cache_read_input_tokens // 0),
        (.usage.output_tokens // 0)
    ] | map(tostring) | join(" ")' 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ -z "$tokens" ]] || [[ "$tokens" == "null null null null" ]]; then
        _agent_log "WARN: Failed to parse tokens from $output_file"
        echo "0 0 0 0"
        return 0
    fi

    echo "$tokens"
}

# ── Agent Invocation ──────────────────────────────────────────────────────────

# Run a Claude agent with a playbook.
# Usage: agent_run_claude <playbook_path> <output_path> [model]
# Returns: 0=success, 1=error, 2=timeout (exit code 124 from timeout command)
agent_run_claude() {
    local playbook_path="$1" output_path="$2"
    local model="${3:-$NIGHTSHIFT_CLAUDE_MODEL}"

    # Derive agent name from playbook filename
    local playbook_basename playbook_name agent_name permission_profile
    playbook_basename=$(basename "$playbook_path")
    playbook_name="${playbook_basename%.md}"
    agent_name="${playbook_name}"
    # TODO(nightshift-permissions): Restore playbook-specific Claude permission profiles
    # after the temporary unblock is no longer needed.
    # permission_profile="$(_agent_permission_profile "$playbook_name")"

    _agent_log "Starting Claude agent: $agent_name model=$model playbook=$playbook_basename"

    # Render playbook template
    local rendered_path
    rendered_path=$(agent_render_playbook "$playbook_path")
    if [[ $? -ne 0 ]]; then
        _agent_log "ERROR: Failed to render playbook: $playbook_path"
        return 1
    fi

    # Prepare output directory and stderr log
    mkdir -p "$(dirname "$output_path")"
    local stderr_log="${NIGHTSHIFT_LOG_DIR}/${agent_name}-stderr-$$.log"
    mkdir -p "$NIGHTSHIFT_LOG_DIR"

    # Record start time
    local start_ts exit_code=0
    start_ts=$(date +%s)

    # Invoke Claude CLI
    _agent_timeout "$NIGHTSHIFT_AGENT_TIMEOUT_SECONDS" \
        env -u CLAUDECODE claude \
        --print \
        --output-format json \
        --dangerously-skip-permissions \
        --model "$model" \
        --max-turns "$NIGHTSHIFT_MAX_TURNS" \
        --system-prompt "$(cat "$rendered_path")" \
        "Begin investigation." \
        > "$output_path" 2>"$stderr_log" || exit_code=$?

    local duration=$(( $(date +%s) - start_ts ))

    # Map timeout exit code
    if [[ $exit_code -eq 124 ]]; then
        _agent_log "TIMEOUT: $agent_name exceeded ${NIGHTSHIFT_AGENT_TIMEOUT_SECONDS}s"
        exit_code=2
    fi

    # Extract tokens from output (4 values: input, cache_create, cache_read, output)
    local tokens input_tokens cache_create_tokens cache_read_tokens output_tokens
    tokens=$(agent_extract_tokens "$output_path")
    read -r input_tokens cache_create_tokens cache_read_tokens output_tokens <<< "$tokens"

    # Record cost
    local call_cost
    call_cost=$(cost_record_call "$agent_name" "$model" "$playbook_basename" \
        "$input_tokens" "$output_tokens" "$cache_create_tokens" "$cache_read_tokens")

    # Check per-call cap (warning only — orchestrator decides whether to stop)
    cost_check_per_call "$call_cost" || true

    _agent_log "Completed: $agent_name exit=$exit_code duration=${duration}s cost=\$$call_cost in=$input_tokens cache_w=$cache_create_tokens cache_r=$cache_read_tokens out=$output_tokens"

    return "$exit_code"
}

# Run a Codex/OpenAI agent with a playbook.
# Usage: agent_run_codex <playbook_path> <output_path> [model]
# No-op if NIGHTSHIFT_CODEX_MODEL is empty.
agent_run_codex() {
    local playbook_path="$1" output_path="$2"
    local model="${3:-$NIGHTSHIFT_CODEX_MODEL}"

    # No-op guard
    if [[ -z "$model" ]]; then
        _agent_log "Codex not configured (NIGHTSHIFT_CODEX_MODEL is empty), skipping"
        return 0
    fi

    local playbook_basename playbook_name agent_name sandbox_mode
    playbook_basename=$(basename "$playbook_path")
    playbook_name="${playbook_basename%.md}"
    agent_name="codex-${playbook_name}"
    # TODO(nightshift-permissions): Restore playbook-specific Codex sandbox selection
    # after the temporary unblock is no longer needed.
    # sandbox_mode="$(_agent_codex_sandbox "$playbook_name")"

    _agent_log "Starting Codex agent: $agent_name model=$model playbook=$playbook_basename"

    # Render playbook template
    local rendered_path
    rendered_path=$(agent_render_playbook "$playbook_path")
    if [[ $? -ne 0 ]]; then
        _agent_log "ERROR: Failed to render playbook: $playbook_path"
        return 1
    fi

    # Check if codex CLI is available
    if ! command -v codex &>/dev/null; then
        _agent_log "WARN: codex CLI not found, skipping $agent_name"
        return 1
    fi

    mkdir -p "$(dirname "$output_path")"
    local stderr_log="${NIGHTSHIFT_LOG_DIR}/${agent_name}-stderr-$$.log"
    mkdir -p "$NIGHTSHIFT_LOG_DIR"

    # Auth preflight — ensure AZURE_OPENAI_API_KEY is available before invoking codex.
    # Primary source is ~/.nightshift-env (sourced by nightshift.sh). If that didn't
    # provide the key, fall back to context-guard.sh's cache -> env -> Key Vault chain.
    if [[ -z "${AZURE_OPENAI_API_KEY:-}" ]]; then
        _agent_log "WARN: AZURE_OPENAI_API_KEY not set, attempting auth preflight via context-guard"
        local guard_script="${HOME}/.claude/scripts/context-guard.sh"
        if [[ -f "$guard_script" ]]; then
            # Coupling risk: Night Shift now depends on context-guard.sh exporting
            # codex54_auth_preflight(). Acceptable because that function is stable
            # and tested, but worth flagging if context-guard.sh is ever restructured.
            source "$guard_script"
            if type codex54_auth_preflight &>/dev/null && codex54_auth_preflight 2>>"$stderr_log"; then
                _agent_log "Auth preflight succeeded via context-guard fallback"
            else
                _agent_log "ERROR: Auth preflight failed — skipping $agent_name (no API key)"
                return 1
            fi
        else
            _agent_log "ERROR: No AZURE_OPENAI_API_KEY and no context-guard.sh fallback — skipping $agent_name"
            return 1
        fi
    fi

    local start_ts exit_code=0
    start_ts=$(date +%s)

    # Invoke Codex CLI
    _agent_timeout "$NIGHTSHIFT_AGENT_TIMEOUT_SECONDS" \
        codex exec \
        -p "$model" \
        -C "$REPO_ROOT" \
        -c 'model_reasoning_effort="high"' \
        --dangerously-bypass-approvals-and-sandbox \
        --ephemeral \
        "$(cat "$rendered_path")" \
        > "$output_path" 2>"$stderr_log" || exit_code=$?

    local duration=$(( $(date +%s) - start_ts ))

    if [[ $exit_code -eq 124 ]]; then
        _agent_log "TIMEOUT: $agent_name exceeded ${NIGHTSHIFT_AGENT_TIMEOUT_SECONDS}s"
        exit_code=2
    fi

    # Estimate tokens from character counts (Codex does not report tokens reliably)
    local input_chars output_chars input_tokens output_tokens
    input_chars=$(wc -c < "$rendered_path" 2>/dev/null || echo 0)
    output_chars=$(wc -c < "$output_path" 2>/dev/null || echo 0)
    input_tokens=$(( input_chars / 4 ))
    output_tokens=$(( output_chars / 4 ))

    # Cost tracking prices by model family, not by local Codex profile name.
    local cost_model="$model"
    if [[ "$cost_model" == "azure54" ]]; then
        cost_model="azure54/gpt-5.4"
    fi

    local call_cost
    call_cost=$(cost_record_call "$agent_name" "$cost_model" "$playbook_basename" \
        "$input_tokens" "$output_tokens" "0" "0")

    cost_check_per_call "$call_cost" || true

    _agent_log "Completed: $agent_name exit=$exit_code duration=${duration}s cost=\$$call_cost in=~$input_tokens out=~$output_tokens (estimated)"

    return "$exit_code"
}

#!/usr/bin/env bash
# test_validation.sh — Focused tests for the Nightshift task validation phase.
#
# Usage: bash scripts/nightshift/tests/test_validation.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT_ACTUAL="$(cd "${NS_DIR}/../.." && pwd)"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; }

echo "=== test_validation.sh ==="
echo ""

source "${NS_DIR}/nightshift.conf"
source "${NS_DIR}/lib/cost-tracker.sh"
source "${NS_DIR}/lib/agent-runner.sh"
source "${NS_DIR}/nightshift.sh"

write_validation_result_json() {
    local output_path="$1"
    local result_text="$2"

    jq -cn \
        --arg result "${result_text}" \
        '{
            type: "result",
            result: $result,
            usage: {
                input_tokens: 1,
                cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0,
                output_tokens: 1
            }
        }' > "${output_path}"
}

write_validation_manifest() {
    local manifest_path=""
    local task_path=""

    manifest_path="$(manager_task_manifest_path)"
    mkdir -p "$(dirname "${manifest_path}")"
    : > "${manifest_path}"

    for task_path in "$@"; do
        printf '%s\n' "${task_path}" >> "${manifest_path}"
    done
}

write_findings_manifest_fixture() {
    local manifest_path=""
    local finding_row=""

    manifest_path="$(findings_manifest_path)"
    mkdir -p "$(dirname "${manifest_path}")"
    : > "${manifest_path}"

    for finding_row in "$@"; do
        printf '%s\n' "${finding_row}" >> "${manifest_path}"
    done
}

setup_validation_repo_fixture() {
    local fixture_name="$1"

    REPO_ROOT="${TMP_DIR}/${fixture_name}/repo"
    RUN_TMP_DIR="${TMP_DIR}/${fixture_name}/run"
    AGENT_OUTPUT_DIR="${RUN_TMP_DIR}/agent-outputs"
    NIGHTSHIFT_LOG_DIR="${RUN_TMP_DIR}/logs"
    NIGHTSHIFT_RENDERED_DIR="${RUN_TMP_DIR}/rendered"
    NIGHTSHIFT_PLAYBOOKS_DIR="${NS_DIR}/playbooks"
    RUN_DATE="2026-04-01"
    RUN_ID="test-validation-${fixture_name}"
    DRY_RUN=0
    SETUP_FAILED=0
    RUN_COST_CAP=0
    RUN_CLEAN=0
    RUN_FAILED=0
    CURRENT_PHASE="3.5b"
    VALIDATED_TASKS=()
    VALIDATION_TOTAL_COUNT=0
    VALIDATION_VALID_COUNT=0
    VALIDATION_INVALID_COUNT=0
    DIGEST_PATH=""
    DIGEST_TASK_COUNT_PATCHED=0
    TASK_FILE_COUNT=0
    COST_TRACKING_READY=0
    FAILURE_NOTES=""
    WARNING_NOTES=""
    NIGHTSHIFT_TASK_FILE_PATH=""
    VALIDATION_AGENT_CALL_LOG=""

    mkdir -p \
        "${REPO_ROOT}/docs/tasks/open/nightshift" \
        "${REPO_ROOT}/scripts/nightshift/playbooks" \
        "${REPO_ROOT}/src/services/clean_rag" \
        "${REPO_ROOT}/scripts" \
        "${REPO_ROOT}/tests" \
        "${REPO_ROOT}/frontend/src" \
        "${REPO_ROOT}/docs/tasks" \
        "${AGENT_OUTPUT_DIR}" \
        "${NIGHTSHIFT_LOG_DIR}" \
        "${NIGHTSHIFT_RENDERED_DIR}"

    cp "${REPO_ROOT_ACTUAL}/src/services/clean_rag/embedding_service.py" \
        "${REPO_ROOT}/src/services/clean_rag/embedding_service.py"
    cp "${REPO_ROOT_ACTUAL}/scripts/nightshift/playbooks/validation-agent.md" \
        "${REPO_ROOT}/scripts/nightshift/playbooks/validation-agent.md"
    cp "${REPO_ROOT_ACTUAL}/docs/tasks/TEMPLATE.md" \
        "${REPO_ROOT}/docs/tasks/TEMPLATE.md"
    printf '# fixture\n' > "${REPO_ROOT}/tests/test_validation_fixture.py"
    printf '#!/usr/bin/env bash\n' > "${REPO_ROOT}/scripts/some-path.sh"
    printf 'export const fixture = true;\n' > "${REPO_ROOT}/frontend/src/validation-fixture.ts"
}

write_validation_task_file() {
    local task_path="$1"
    local relevant_files_body="$2"
    local context_body="$3"
    local include_done_criteria="${4:-yes}"
    local extra_sections="${5:-}"
    local goal_body="${6:-System validates \`scripts/nightshift/playbooks/validation-agent.md\` against live repo state.}"
    local scope_in_body="${7:-- Validation fixture coverage}"
    local done_criteria_body="${8:-- [ ] Validation fixture passes or fails deterministically}"

    mkdir -p "$(dirname "${task_path}")"

    {
        cat <<EOF
## Task: Validation fixture
## Status: not started
## Created: 2026-04-01
## Execution Mode: single-agent

## Motivation
Nightshift validation fixture that references live repo paths.

## Goal
${goal_body}

## Scope
### In Scope
${scope_in_body}

### Out of Scope
- Unrelated validation behavior

## Relevant Files
${relevant_files_body}

## Context
${context_body}

## Anti-Patterns
- Do NOT mutate validation fixtures
EOF

        if [[ -n "${extra_sections}" ]]; then
            printf '\n%s\n' "${extra_sections}"
        fi

        if [[ "${include_done_criteria}" == "yes" ]]; then
            cat <<EOF

## Done Criteria
${done_criteria_body}
EOF
        fi

        cat <<'EOF'

## Code Review: not started

## Left Off At
Fixture created for phase_validation tests.

## Attempts
(none)
EOF
    } > "${task_path}"
}

validation_stub_candidate_lines() {
    local task_file="$1"

    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        /^## / {
            in_suggested = ($0 == "## Suggested Test Strategy" || $0 == "## Suggested Verification")
        }

        {
            trimmed = trim($0)
            if (in_suggested) {
                next
            }
            if (trimmed ~ /^- Suggested(:|$)/) {
                next
            }
            print
        }
    ' "${task_file}"
}

validation_stub_extract_paths() {
    local task_file="$1"

    validation_stub_candidate_lines "${task_file}" \
        | grep -oE '([A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]*/?' \
        | sed -E 's/(:[0-9]+|#L[0-9]+)$//' \
        | sort -u || true
}

validation_stub_section_body() {
    local task_file="$1"
    local section_name="$2"

    awk -v section="## ${section_name}" '
        $0 == section {
            in_section = 1
            next
        }

        /^## / && in_section {
            exit
        }

        in_section {
            print
        }
    ' "${task_file}"
}

validation_stub_section_entries() {
    local task_file="$1"
    local section_name="$2"

    validation_stub_section_body "${task_file}" "${section_name}" \
        | awk '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }

            {
                trimmed = trim($0)
                if (trimmed == "" || trimmed ~ /^### /) {
                    next
                }
                print trimmed
            }
        '
}

validation_stub_text_without_section() {
    local task_file="$1"
    local section_name="$2"

    awk -v section="## ${section_name}" '
        $0 == section {
            skip = 1
            next
        }

        /^## / && skip {
            skip = 0
        }

        !skip {
            print
        }
    ' "${task_file}"
}

validation_stub_first_path_token() {
    local entry="$1"

    printf '%s\n' "${entry}" | grep -oE '([A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]*/?' | head -n 1 || true
}

validation_stub_entry_has_placeholder() {
    local entry="$1"

    printf '%s\n' "${entry}" \
        | grep -Eiq '(^|[^A-Za-z])TBD([^A-Za-z]|$)|exact file TBD|grep for|or equivalent|could be tracked|could be|\([^)]*(TBD|exact file TBD|grep for|or equivalent|could be tracked|could be)[^)]*\)'
}

validation_stub_scope_allows_directory() {
    local task_file="$1"
    local dir_path="$2"
    local scope_text=""
    local scope_lower=""
    local dir_lower=""

    scope_text="$(validation_stub_section_body "${task_file}" "Scope")"
    scope_lower="$(printf '%s' "${scope_text}" | tr '[:upper:]' '[:lower:]')"
    dir_lower="$(printf '%s' "${dir_path%/}/" | tr '[:upper:]' '[:lower:]')"

    [[ "${scope_lower}" == *"all files in directory ${dir_lower}"* ]] \
        || [[ "${scope_lower}" == *"all modules in directory ${dir_lower}"* ]]
}

validation_stub_has_specific_path_under_dir() {
    local task_file="$1"
    local dir_path="${2%/}/"
    local candidate=""

    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        if [[ "${candidate}" == "${dir_path}"* && "${candidate}" != "${dir_path}" && "${candidate}" != */ ]]; then
            return 0
        fi
    done < <(validation_stub_extract_paths "${task_file}")

    return 1
}

validation_stub_goal_has_target() {
    local task_file="$1"
    local goal_text=""

    goal_text="$(validation_stub_section_body "${task_file}" "Goal")"
    [[ "${goal_text}" =~ ([A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+ ]] || [[ "${goal_text}" =~ [A-Za-z_][A-Za-z0-9_]*\(\) ]]
}

validation_stub_selected_claims() {
    local task_file="$1"

    validation_stub_candidate_lines "${task_file}" \
        | awk '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }

            {
                line = trim($0)
                lower = tolower(line)

                if (line == "" || line ~ /^## /) {
                    next
                }
                if (lower ~ /^- suggested(:|$)/ || lower ~ /^suggested:/) {
                    next
                }
                if (lower ~ /^- \[[ x]\] verify:/ || lower ~ /^verify:/) {
                    next
                }

                priority = 0
                if (line ~ /[A-Za-z_][A-Za-z0-9_]*\(\)/ || lower ~ /signature|parameter|return type|returns|raises|uses \*\*kwargs|auth dependency|depends\(/) {
                    priority = 1
                } else if (line ~ /([A-Za-z0-9_.-]+\/)+[A-Za-z0-9_.-]+(:[0-9]+|#L[0-9]+)/) {
                    priority = 2
                } else if (line ~ /[0-9]/ && lower ~ /(test|tests|handler|handlers|file|files|module|modules|import|imports|function|functions|route|routes)/) {
                    priority = 3
                } else if (lower ~ /detective|severity|commit/ || line ~ /\b[0-9a-f]{7,40}\b/) {
                    priority = 4
                }

                if (priority > 0) {
                    print priority "|" NR "|" line
                }
            }
        ' \
        | sort -t'|' -k1,1n -k2,2n \
        | head -n 5 \
        | cut -d'|' -f3-
}

validation_agent_stub() {
    local _playbook_path="$1"
    local _output_path="$2"
    local task_file="${NIGHTSHIFT_TASK_FILE_PATH}"
    local -a task_paths=()
    local -a failures=()
    local -a missing_sections=()
    local -a relevant_entries=()
    local -a context_entries=()
    local -a selected_claims=()
    local -a done_refs=()
    local -a done_functions=()
    local -a pitfalls_functions=()
    local path=""
    local entry=""
    local raw_entry=""
    local weak_entry=0
    local missing_summary=""
    local result_status="VALIDATED"
    local structure_summary="complete"
    local passed_paths=0
    local failed_paths=0
    local confirmed_claims=0
    local contradicted_claims=0
    local line_info=""
    local line_no=""
    local result_text=""
    local failure=""
    local section_name=""
    local section_pattern=""
    local goal_text=""
    local done_text=""
    local pitfalls_text=""
    local other_text=""
    local claim=""
    local selected_claim_count=0
    local conflict_found=0
    local overlap_found=0
    local done_ref=""
    local done_function=""
    local pitfalls_function=""
    local total_relevant_entries=0
    local weak_relevant_entries=0

    if [[ -n "${VALIDATION_AGENT_CALL_LOG}" ]]; then
        printf '%s\n' "${task_file}" >> "${VALIDATION_AGENT_CALL_LOG}"
    fi

    case "$(basename "${task_file}")" in
        *invalid-path.md)
            result_text=$'### Validation Result: INVALID\nPaths checked: 2 passed, 1 failed\nClaims checked: 3 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- INVALID:path — src/services/nonexistent_file.py not found'
            write_validation_result_json "${_output_path}" "${result_text}"
            return 0
            ;;
        *double-header.md)
            result_text=$'Interim draft header follows.\n### Validation Result: INVALID\nPaths checked: 0 passed, 1 failed\nClaims checked: 0 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- INVALID:path — stale/path.py not found\n\nFinal answer:\n### Validation Result: VALIDATED\nPaths checked: 3 passed, 0 failed\nClaims checked: 2 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- (none)'
            write_validation_result_json "${_output_path}" "${result_text}"
            return 0
            ;;
        *append-missing.md)
            result_text=$'### Validation Result: INVALID\nPaths checked: 0 passed, 1 failed\nClaims checked: 0 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- INVALID:path — docs/tasks/open/nightshift/missing.md not found'
            write_validation_result_json "${_output_path}" "${result_text}"
            return 0
            ;;
    esac

    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        task_paths+=("${path}")
    done < <(validation_stub_extract_paths "${task_file}")

    while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        relevant_entries+=("${entry}")
    done < <(validation_stub_section_entries "${task_file}" "Relevant Files")

    while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        context_entries+=("${entry}")
    done < <(validation_stub_section_entries "${task_file}" "Context")

    for path in "${task_paths[@]-}"; do
        if [[ -e "${REPO_ROOT}/${path%/}" ]]; then
            passed_paths=$(( passed_paths + 1 ))
        else
            failed_paths=$(( failed_paths + 1 ))
            failures+=("INVALID:path — ${path} not found")
        fi
    done

    for raw_entry in "${relevant_entries[@]-}" "${context_entries[@]-}"; do
        [[ -n "${raw_entry}" ]] || continue
        if validation_stub_entry_has_placeholder "${raw_entry}"; then
            failures+=("INVALID:placeholder — ${raw_entry} contains unresolved placeholder")
        fi
    done

    for entry in "${relevant_entries[@]-}"; do
        [[ -n "${entry}" ]] || continue
        total_relevant_entries=$(( total_relevant_entries + 1 ))
        weak_entry=0
        path="$(validation_stub_first_path_token "${entry}")"

        if validation_stub_entry_has_placeholder "${entry}" || [[ "${entry}" == *"TBD"* ]]; then
            weak_entry=1
        fi

        if [[ -n "${path}" && "${path}" == */ ]]; then
            weak_entry=1
            if ! validation_stub_scope_allows_directory "${task_file}" "${path}" \
                && ! validation_stub_has_specific_path_under_dir "${task_file}" "${path}"; then
                failures+=("INVALID:path — ${path} is directory-level only, no specific file identified")
                if [[ -e "${REPO_ROOT}/${path%/}" && "${passed_paths}" -gt 0 ]]; then
                    passed_paths=$(( passed_paths - 1 ))
                    failed_paths=$(( failed_paths + 1 ))
                fi
            fi
        fi

        if [[ "${weak_entry}" -eq 1 ]]; then
            weak_relevant_entries=$(( weak_relevant_entries + 1 ))
        fi
    done

    while IFS= read -r claim; do
        [[ -n "${claim}" ]] || continue
        selected_claims+=("${claim}")
    done < <(validation_stub_selected_claims "${task_file}")
    selected_claim_count="${#selected_claims[@]}"
    confirmed_claims="${selected_claim_count}"

    for claim in "${selected_claims[@]-}"; do
        [[ -n "${claim}" ]] || continue
        if [[ "${claim}" == *'similarity_search() uses **kwargs'* ]]; then
            line_info="$(rg -n 'async def similarity_search' "${REPO_ROOT}/src/services/clean_rag/embedding_service.py" | head -n 1)"
            line_no="${line_info%%:*}"
            failures+=(
                "INVALID:claim — task says similarity_search() uses **kwargs, actual signature is explicit (src/services/clean_rag/embedding_service.py:${line_no})"
            )
            contradicted_claims=$(( contradicted_claims + 1 ))
        fi
    done

    confirmed_claims=$(( confirmed_claims - contradicted_claims ))
    if [[ "${confirmed_claims}" -lt 0 ]]; then
        confirmed_claims=0
    fi

    while IFS='|' read -r section_name section_pattern; do
        if ! grep -q "${section_pattern}" "${task_file}"; then
            missing_sections+=("${section_name}")
            failures+=("INVALID:structure — missing ${section_name}")
        fi
    done <<'EOF'
Status|^## Status:
Goal|^## Goal$
Scope|^## Scope$
Done Criteria|^## Done Criteria$
Anti-Patterns|^## Anti-Patterns$
EOF

    if (( ${#missing_sections[@]} > 0 )); then
        for section_name in "${missing_sections[@]}"; do
            if [[ -n "${missing_summary}" ]]; then
                missing_summary="${missing_summary}, "
            fi
            missing_summary="${missing_summary}${section_name}"
        done
        structure_summary="missing ${missing_summary}"
    fi

    done_text="$(validation_stub_section_body "${task_file}" "Done Criteria")"
    pitfalls_text="$(validation_stub_section_body "${task_file}" "Pitfalls")"
    other_text="$(validation_stub_text_without_section "${task_file}" "Done Criteria")"

    if [[ -n "${done_text}" && -n "${pitfalls_text}" ]]; then
        while IFS= read -r done_function; do
            [[ -n "${done_function}" ]] || continue
            done_functions+=("${done_function}")
        done < <(printf '%s\n' "${done_text}" | grep -oE '[A-Za-z_][A-Za-z0-9_]*\(\)' | sort -u || true)

        while IFS= read -r pitfalls_function; do
            [[ -n "${pitfalls_function}" ]] || continue
            pitfalls_functions+=("${pitfalls_function}")
        done < <(printf '%s\n' "${pitfalls_text}" | grep -oE '[A-Za-z_][A-Za-z0-9_]*\(\)' | sort -u || true)

        if (( ${#done_functions[@]} > 0 && ${#pitfalls_functions[@]} > 0 )); then
            overlap_found=0
            for done_function in "${done_functions[@]}"; do
                for pitfalls_function in "${pitfalls_functions[@]}"; do
                    if [[ "${done_function}" == "${pitfalls_function}" ]]; then
                        overlap_found=1
                        break
                    fi
                done
                if [[ "${overlap_found}" -eq 1 ]]; then
                    break
                fi
            done

            if [[ "${overlap_found}" -eq 0 ]]; then
                failures+=("INVALID:consistency — Done Criteria conflicts with Pitfalls")
                conflict_found=1
            fi
        fi
    fi

    if [[ "${conflict_found}" -eq 0 && -n "${done_text}" ]]; then
        while IFS= read -r done_ref; do
            [[ -n "${done_ref}" ]] || continue
            done_refs+=("${done_ref}")
        done < <(
            {
                printf '%s\n' "${done_text}" | grep -oE '([A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+' || true
                printf '%s\n' "${done_text}" | grep -oE '[A-Za-z_][A-Za-z0-9_]*\(\)' || true
            } | sort -u
        )

        for done_ref in "${done_refs[@]-}"; do
            [[ -n "${done_ref}" ]] || continue
            if ! printf '%s\n' "${other_text}" | grep -Fq "${done_ref}"; then
                failures+=("INVALID:consistency — Done Criteria references ungrounded artifact")
                break
            fi
        done
    fi

    if (( ${#failures[@]} > 0 )); then
        result_status="INVALID"
    fi

    if [[ "${result_status}" == "VALIDATED" ]]; then
        if (( total_relevant_entries > 0 )) && (( weak_relevant_entries * 2 > total_relevant_entries )); then
            failures+=("INVALID:executability — task lacks sufficient file specificity to execute")
            result_status="INVALID"
        fi

        if ! validation_stub_goal_has_target "${task_file}"; then
            failures+=("INVALID:executability — goal is too abstract to execute")
            result_status="INVALID"
        fi
    fi

    result_text=$(cat <<EOF
### Validation Result: ${result_status}
Paths checked: ${passed_paths} passed, ${failed_paths} failed
Claims checked: ${confirmed_claims} confirmed, ${contradicted_claims} contradicted
Structure: ${structure_summary}
Failed checks:
EOF
)

    if (( ${#failures[@]} == 0 )); then
        result_text="${result_text}"$'\n- (none)'
    else
        for failure in "${failures[@]}"; do
            result_text="${result_text}"$'\n- '"${failure}"
        done
    fi

    write_validation_result_json "${_output_path}" "${result_text}"
}

# ── Test 1: Claude result text extraction (result string) ────────────────────
(
    output_path="${TMP_DIR}/extract-result.json"
    result_text=$'### Validation Result: VALIDATED\nPaths checked: 2 passed, 0 failed'
    write_validation_result_json "${output_path}" "${result_text}"

    extracted="$(agent_extract_claude_result_text "${output_path}")"
    [[ "${extracted}" == "${result_text}" ]]
) && pass "1. agent_extract_claude_result_text returns the Claude result body" \
  || fail "1. agent_extract_claude_result_text returns the Claude result body" "parsed result text did not match"

# ── Test 2: malformed JSON fails closed ───────────────────────────────────────
(
    output_path="${TMP_DIR}/extract-malformed.json"
    printf '{"result": ' > "${output_path}"

    set +e
    extracted="$(agent_extract_claude_result_text "${output_path}" 2>/dev/null)"
    rc=$?
    set -e

    [[ "${rc}" -ne 0 ]]
    [[ -z "${extracted}" ]]
) && pass "2. malformed JSON does not produce extracted Claude result text" \
  || fail "2. malformed JSON does not produce extracted Claude result text" "malformed JSON unexpectedly parsed"

# ── Test 3: message.content arrays join multiple text blocks ──────────────────
(
    output_path="${TMP_DIR}/extract-message-content.json"
    jq -cn '{
        message: {
            content: [
                {type: "text", text: "Alpha block"},
                {type: "tool_use", id: "tool-1"},
                {type: "text", text: "Beta block"}
            ]
        }
    }' > "${output_path}"

    extracted="$(agent_extract_claude_result_text "${output_path}")"
    [[ "${extracted}" == $'Alpha block\nBeta block' ]]
) && pass "3. message.content arrays join text blocks and ignore non-text blocks" \
  || fail "3. message.content arrays join text blocks and ignore non-text blocks" "message.content parsing regressed"

# ── Test 4: content arrays join multiple text blocks ──────────────────────────
(
    output_path="${TMP_DIR}/extract-content-array.json"
    jq -cn '{
        content: [
            {type: "text", text: "First chunk"},
            {type: "image", image_url: "https://example.test/image.png"},
            {type: "text", text: "Second chunk"}
        ]
    }' > "${output_path}"

    extracted="$(agent_extract_claude_result_text "${output_path}")"
    [[ "${extracted}" == $'First chunk\nSecond chunk' ]]
) && pass "4. content arrays join text blocks and ignore non-text blocks" \
  || fail "4. content arrays join text blocks and ignore non-text blocks" "content-array parsing regressed"

# Tests future path when task-writer produces manifests.
# ── Test 5: phase_validation stamps validated tasks on disk ──────────────────
(
    setup_validation_repo_fixture "valid"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-valid-task.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference\n- `tests/test_validation_fixture.py` — fixture test path' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters including `similarity_threshold`.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.\n- `tests/test_validation_fixture.py` exists in this repo fixture.'
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "${VALIDATION_TOTAL_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    [[ "${#VALIDATED_TASKS[@]}" -eq 1 ]] || ok=false
    [[ "${VALIDATED_TASKS[0]}" == "${task_path}" ]] || ok=false
    grep -q '^## Validation: VALIDATED$' "${task_path}" || ok=false
    grep -q "^Validated by Night Shift validation agent on ${RUN_DATE}\\.$" "${task_path}" || ok=false
    ! grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "5. phase_validation stamps validated tasks on disk and records them for follow-up phases" \
  || fail "5. phase_validation stamps validated tasks on disk and records them for follow-up phases" "validated task stamp or bookkeeping regressed"

# ── Test 6: expanded path extraction catches scripts paths and skips Suggested bullets ──
(
    setup_validation_repo_fixture "scripts-path"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-scripts-path.md"
    extra_sections=$'## Suggested Test Strategy\n- Suggested: tests/test_foo.py\n- Suggested test file: `Suggested: tests/test_bar.py`\n\n## Suggested Verification\n- Suggested unit test: `Suggested: pytest tests/test_foo.py -x -q`'
    write_validation_task_file \
        "${task_path}" \
        $'- `scripts/some-path.sh` — live script path fixture\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `scripts/some-path.sh` exists in this repo fixture.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.' \
        "yes" \
        "${extra_sections}"
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "${VALIDATION_VALID_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    ! grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "6. validation catches repo-relative scripts paths without flagging Suggested placeholders" \
  || fail "6. validation catches repo-relative scripts paths without flagging Suggested placeholders" "path extraction or Suggested exclusion regressed"

# ── Test 7: invalid path appends a validation failure section ────────────────
(
    setup_validation_repo_fixture "invalid-path"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-invalid-path.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/nonexistent_file.py` — missing path fixture\n- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters including `similarity_threshold`.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.\n- `tests/test_validation_fixture.py` exists in this repo fixture.'
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "${VALIDATION_VALID_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q 'INVALID:path — src/services/nonexistent_file.py not found' "${task_path}" || ok=false
    grep -q '^## Status: not started$' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "7. invalid task paths still append an INVALID:path validation section" \
  || fail "7. invalid task paths still append an INVALID:path validation section" "missing-path handling regressed"

# ── Test 8: invalid claim appends the contradicted behavior reason ───────────
(
    setup_validation_repo_fixture "invalid-claim"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-invalid-claim.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference\n- `tests/test_validation_fixture.py` — fixture test path' \
        $'- `src/services/clean_rag/embedding_service.py` says `similarity_search() uses **kwargs`.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.\n- `tests/test_validation_fixture.py` exists in this repo fixture.'
    write_validation_manifest "${task_path}"

    signature_line="$(rg -n 'async def similarity_search' "${REPO_ROOT}/src/services/clean_rag/embedding_service.py" | head -n 1)"
    signature_line="${signature_line%%:*}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q "INVALID:claim — task says similarity_search() uses \\*\\*kwargs, actual signature is explicit (src/services/clean_rag/embedding_service.py:${signature_line})" "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "8. contradicted behavior claims append an INVALID:claim reason" \
  || fail "8. contradicted behavior claims append an INVALID:claim reason" "claim-validation handling regressed"

# ── Test 9: missing Done Criteria appends INVALID:structure ──────────────────
(
    setup_validation_repo_fixture "invalid-structure"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-invalid-structure.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference\n- `tests/test_validation_fixture.py` — fixture test path' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters including `similarity_threshold`.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.\n- `tests/test_validation_fixture.py` exists in this repo fixture.' \
        "no"
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q 'INVALID:structure — missing Done Criteria' "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "9. missing required sections append an INVALID:structure reason" \
  || fail "9. missing required sections append an INVALID:structure reason" "structural validation regressed"

# ── Test 10: parser uses the last validation header block ────────────────────
(
    setup_validation_repo_fixture "double-header"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-double-header.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "${VALIDATION_VALID_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    ! grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "10. validation_result_status and failed-check parsing use the final header block" \
  || fail "10. validation_result_status and failed-check parsing use the final header block" "final validation block parsing regressed"

# ── Test 11: append failures warn and validation continues ───────────────────
(
    setup_validation_repo_fixture "append-missing"
    agent_run_claude() { validation_agent_stub "$@"; }

    missing_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-append-missing.md"
    survivor_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-survivor.md"

    write_validation_task_file \
        "${missing_task}" \
        $'- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    write_validation_task_file \
        "${survivor_task}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    write_validation_manifest "${missing_task}" "${survivor_task}"
    rm -f "${missing_task}"

    log_path="${TMP_DIR}/validation-append-missing.log"
    phase_validation >"${log_path}" 2>&1

    ok=true
    grep -q 'Could not append validation failure for docs/tasks/open/nightshift/2026-04-01-append-missing.md: task file is missing' "${log_path}" || ok=false
    grep -q '===== Phase 3.5b: Task Validation OK =====' "${log_path}" || ok=false
    [[ "${VALIDATION_TOTAL_COUNT}" == "2" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${#VALIDATED_TASKS[@]}" -eq 1 ]] || ok=false
    [[ "${VALIDATED_TASKS[0]}" == "${survivor_task}" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "11. append failures warn, count invalid, and continue validating later tasks" \
  || fail "11. append failures warn, count invalid, and continue validating later tasks" "append-guard behavior regressed"

# ── Test 12: validation only processes manifest-listed fresh tasks ───────────
(
    setup_validation_repo_fixture "manifest-scope"
    agent_run_claude() { validation_agent_stub "$@"; }
    VALIDATION_AGENT_CALL_LOG="${TMP_DIR}/manifest-scope.calls"
    : > "${VALIDATION_AGENT_CALL_LOG}"

    fresh_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-fresh.md"
    stale_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-stale.md"

    write_validation_task_file \
        "${fresh_task}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.'
    write_validation_task_file \
        "${stale_task}" \
        $'- `src/services/nonexistent_file.py` — stale missing path fixture' \
        $'- stale task should never be validated in this run.'
    write_validation_manifest "${fresh_task}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "${VALIDATION_TOTAL_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    grep -Fqx "${fresh_task}" "${VALIDATION_AGENT_CALL_LOG}" || ok=false
    ! grep -Fq "${stale_task}" "${VALIDATION_AGENT_CALL_LOG}" || ok=false
    ! grep -q '^## Validation: FAILED$' "${stale_task}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "12. phase_validation reads fresh task paths from the manifest instead of the run-date glob" \
  || fail "12. phase_validation reads fresh task paths from the manifest instead of the run-date glob" "manifest scoping regressed"

# ── Test 13: empty manifest skips validation cleanly ─────────────────────────
(
    setup_validation_repo_fixture "empty-manifest"
    write_validation_manifest

    log_path="${TMP_DIR}/validation-empty-manifest.log"
    phase_validation >"${log_path}" 2>&1

    ok=true
    grep -q 'Task writing produced no task files. Skipping validation.' "${log_path}" || ok=false
    grep -q '===== Phase 3.5b: Task Validation SKIPPED =====' "${log_path}" || ok=false
    [[ "${VALIDATION_TOTAL_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "13. zero-byte task manifests log that task writing produced no task files and skip validation" \
  || fail "13. zero-byte task manifests log that task writing produced no task files and skip validation" "zero-byte manifest handling regressed"

# ── Test 14: cost cap halts remaining validations after processed survivors ──
(
    setup_validation_repo_fixture "cost-cap"
    agent_run_claude() { validation_agent_stub "$@"; }
    guard_calls=0
    cost_guard_after_call() {
        guard_calls=$((guard_calls + 1))
        if [[ "${guard_calls}" -ge 1 ]]; then
            RUN_COST_CAP=1
            return 1
        fi
        return 0
    }

    first_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-first.md"
    second_task="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-second.md"

    write_validation_task_file \
        "${first_task}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference\n- `tests/test_validation_fixture.py` — fixture test path' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters including `similarity_threshold`.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.\n- `tests/test_validation_fixture.py` exists in this repo fixture.'
    write_validation_task_file \
        "${second_task}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference\n- `tests/test_validation_fixture.py` — fixture test path' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters including `similarity_threshold`.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.\n- `tests/test_validation_fixture.py` exists in this repo fixture.'
    write_validation_manifest "${first_task}" "${second_task}"

    log_path="${TMP_DIR}/validation-cost-cap.log"
    phase_validation >"${log_path}" 2>&1

    ok=true
    grep -q '===== Phase 3.5b: Task Validation HALTED =====' "${log_path}" || ok=false
    [[ "${RUN_COST_CAP}" == "1" ]] || ok=false
    [[ "${VALIDATION_TOTAL_COUNT}" == "2" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "1" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    [[ "${#VALIDATED_TASKS[@]}" -eq 1 ]] || ok=false
    [[ "${VALIDATED_TASKS[0]}" == "${first_task}" ]] || ok=false
    ! grep -q '^## Validation: FAILED$' "${second_task}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "14. phase_validation halts remaining tasks when cost_guard_after_call trips" \
  || fail "14. phase_validation halts remaining tasks when cost_guard_after_call trips" "cost-cap halt behavior regressed"

# ── Test 15: invalid autofix severity is rejected during config load ─────────
(
    tmp_home="${TMP_DIR}/home-invalid-autofix"
    mkdir -p "${tmp_home}"
    export HOME="${tmp_home}"

    bad_conf="${TMP_DIR}/nightshift-invalid-autofix.conf"
    sed 's/^NIGHTSHIFT_AUTOFIX_SEVERITY=.*/NIGHTSHIFT_AUTOFIX_SEVERITY="critical,bogus"/' \
        "${NS_DIR}/nightshift.conf" > "${bad_conf}"

    log_path="${TMP_DIR}/invalid-autofix.log"
    set +e
    load_nightshift_configuration "${bad_conf}" "${HOME}/.nightshift-env" >"${log_path}" 2>&1
    rc=$?
    set -e

    [[ "${rc}" -eq 1 ]]
    grep -q 'Invalid NIGHTSHIFT_AUTOFIX_SEVERITY' "${log_path}"
) && pass "15. invalid NIGHTSHIFT_AUTOFIX_SEVERITY fails configuration validation" \
  || fail "15. invalid NIGHTSHIFT_AUTOFIX_SEVERITY fails configuration validation" "autofix severity validation was not enforced"

# ── Test 16: dry-run schedule includes task writing before validation ────────
(
    tmp_home="${TMP_DIR}/home-dry-run-validation"
    mkdir -p "${tmp_home}"
    log_path="${TMP_DIR}/dry-run-validation.log"

    HOME="${tmp_home}" bash "${NS_DIR}/nightshift.sh" --dry-run >"${log_path}" 2>&1

    manager_line="$(grep -n '===== Phase 3: Manager Merge START =====' "${log_path}" | head -n 1)"
    task_writing_line="$(grep -n '===== Phase 3.5a: Task Writing START =====' "${log_path}" | head -n 1)"
    validation_line="$(grep -n '===== Phase 3.5b: Task Validation START =====' "${log_path}" | head -n 1)"
    ship_line="$(grep -n '===== Phase 4: Ship Results START =====' "${log_path}" | head -n 1)"
    manager_line="${manager_line%%:*}"
    task_writing_line="${task_writing_line%%:*}"
    validation_line="${validation_line%%:*}"
    ship_line="${ship_line%%:*}"

    ok=true
    [[ -n "${manager_line}" ]] || ok=false
    [[ -n "${task_writing_line}" ]] || ok=false
    [[ -n "${validation_line}" ]] || ok=false
    [[ -n "${ship_line}" ]] || ok=false
    (( manager_line < task_writing_line )) || ok=false
    (( task_writing_line < validation_line )) || ok=false
    (( validation_line < ship_line )) || ok=false
    grep -q '===== Phase 3.5b: Task Validation SKIPPED =====' "${log_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "16. dry-run phase schedule shows task writing before validation before shipping" \
  || fail "16. dry-run phase schedule shows task writing before validation before shipping" "dry-run phase ordering regressed"

# ── Test 17: playbook text contains the hardened validation contract ─────────
(
    playbook_path="${NS_DIR}/playbooks/validation-agent.md"

    ok=true
    grep -Fq '## Check 1.5: Placeholder / Hedge Detection' "${playbook_path}" || ok=false
    grep -Fq 'Select up to 5 current-state claims total' "${playbook_path}" || ok=false
    grep -Fq 'INVALID:placeholder' "${playbook_path}" || ok=false
    grep -Fq 'INVALID:consistency' "${playbook_path}" || ok=false
    grep -Fq 'INVALID:executability' "${playbook_path}" || ok=false
    grep -Fq 'Do NOT add duplicate-task checking in this pass' "${playbook_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "17. validation playbook text documents placeholder, consistency, executability, and 5-claim rules" \
  || fail "17. validation playbook text documents placeholder, consistency, executability, and 5-claim rules" "playbook hardening text is incomplete"

# ── Test 18: Relevant Files placeholders append INVALID:placeholder ──────────
(
    setup_validation_repo_fixture "placeholder-relevant"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-placeholder-relevant.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — exact file TBD\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.'
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q 'INVALID:placeholder — - `src/services/clean_rag/embedding_service.py` — exact file TBD contains unresolved placeholder' "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "18. Relevant Files entries with exact file TBD append INVALID:placeholder" \
  || fail "18. Relevant Files entries with exact file TBD append INVALID:placeholder" "placeholder detection regressed"

# ── Test 19: directory-only Relevant Files entries need a specific file ──────
(
    setup_validation_repo_fixture "directory-only"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-directory-only.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/` — directory-level target without a pinned file\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q 'INVALID:path — src/services/clean_rag/ is directory-level only, no specific file identified' "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "19. directory-only Relevant Files entries without a pinned file append INVALID:path" \
  || fail "19. directory-only Relevant Files entries without a pinned file append INVALID:path" "directory specificity validation regressed"

# ── Test 20: claim selection scans beyond Context into body sections ─────────
(
    setup_validation_repo_fixture "body-claim"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-body-claim.md"
    extra_sections=$'## Investigation Findings\n- `src/services/clean_rag/embedding_service.py` says `similarity_search() uses **kwargs`.'
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.\n- `tests/test_validation_fixture.py` exists in this repo fixture.' \
        "yes" \
        "${extra_sections}"
    write_validation_manifest "${task_path}"

    signature_line="$(rg -n 'async def similarity_search' "${REPO_ROOT}/src/services/clean_rag/embedding_service.py" | head -n 1)"
    signature_line="${signature_line%%:*}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q "INVALID:claim — task says similarity_search() uses \\*\\*kwargs, actual signature is explicit (src/services/clean_rag/embedding_service.py:${signature_line})" "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "20. behavioral claims in body sections are still selected and contradicted" \
  || fail "20. behavioral claims in body sections are still selected and contradicted" "whole-task claim selection regressed"

# ── Test 21: Done Criteria and Pitfalls conflicts append INVALID:consistency ─
(
    setup_validation_repo_fixture "consistency-conflict"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-consistency-conflict.md"
    extra_sections=$'## Pitfalls\n- Prefer `require_admin()` as the fix approach for this route.'
    done_criteria_body=$'- [ ] Route uses `optional_auth()` as the final dependency.'
    goal_body='System validates route guidance in `scripts/nightshift/playbooks/validation-agent.md`.'
    write_validation_task_file \
        "${task_path}" \
        $'- `scripts/nightshift/playbooks/validation-agent.md` — validation contract reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `scripts/nightshift/playbooks/validation-agent.md` defines the validation checks.' \
        "yes" \
        "${extra_sections}" \
        "${goal_body}" \
        $'- Validation fixture coverage' \
        "${done_criteria_body}"
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q 'INVALID:consistency — Done Criteria conflicts with Pitfalls' "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "21. conflicting Done Criteria and Pitfalls append INVALID:consistency" \
  || fail "21. conflicting Done Criteria and Pitfalls append INVALID:consistency" "consistency validation regressed"

# ── Test 22: weak Relevant Files majorities fail executability ───────────────
(
    setup_validation_repo_fixture "executability"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-executability.md"
    goal_body='System audits `scripts/nightshift/playbooks/validation-agent.md` for execution readiness.'
    scope_in_body=$'- Audit all files in directory src/services/clean_rag/\n- Audit all modules in directory frontend/src/'
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/` — clean_rag directory coverage\n- `frontend/src/` — frontend directory coverage\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.' \
        "yes" \
        "" \
        "${goal_body}" \
        "${scope_in_body}"
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q 'INVALID:executability — task lacks sufficient file specificity to execute' "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "22. more than half weak Relevant Files entries append INVALID:executability" \
  || fail "22. more than half weak Relevant Files entries append INVALID:executability" "executability validation regressed"

# ── Test 23: metadata noise does not block higher-value body claims ──────────
(
    setup_validation_repo_fixture "claim-priority"
    agent_run_claude() { validation_agent_stub "$@"; }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-claim-priority.md"
    extra_sections=$'## Architectural Context\n- `src/services/clean_rag/embedding_service.py` says `similarity_search() uses **kwargs`.'
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- Commit `c6151987` touched validation.\n- Severity label is major.\n- conversation-detective raised this task.' \
        "yes" \
        "${extra_sections}"
    write_validation_manifest "${task_path}"

    signature_line="$(rg -n 'async def similarity_search' "${REPO_ROOT}/src/services/clean_rag/embedding_service.py" | head -n 1)"
    signature_line="${signature_line%%:*}"

    phase_validation >/dev/null 2>&1

    ok=true
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q "INVALID:claim — task says similarity_search() uses \\*\\*kwargs, actual signature is explicit (src/services/clean_rag/embedding_service.py:${signature_line})" "${task_path}" || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "${ok}" == "true" ]]
) && pass "23. claim priority still selects harder behavioral claims ahead of metadata" \
  || fail "23. claim priority still selects harder behavioral claims ahead of metadata" "claim-priority selection regressed"

# ── Test 24: findings-manifest without task files skips validation honestly ──
(
    setup_validation_repo_fixture "triage-only-manifest"

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-unvalidated.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.'
    write_findings_manifest_fixture \
        $'1\tcritical\tregression\tAlpha failure' \
        $'2\tmajor\terror-handling\tBeta error path'

    log_path="${TMP_DIR}/validation-triage-only-manifest.log"
    phase_validation >"${log_path}" 2>&1

    ok=true
    grep -Fq 'Triage metadata found but no task files produced — task-writer phase not yet wired. Skipping validation.' "${log_path}" || ok=false
    grep -q '===== Phase 3.5b: Task Validation SKIPPED =====' "${log_path}" || ok=false
    [[ ! -e "$(manager_task_manifest_path)" ]] || ok=false
    [[ "${VALIDATION_TOTAL_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_VALID_COUNT}" == "0" ]] || ok=false
    [[ "${VALIDATION_INVALID_COUNT}" == "0" ]] || ok=false
    [[ "${#VALIDATED_TASKS[@]}" -eq 0 ]] || ok=false
    ! grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "24. findings-manifest without task files skips validation until task-writer is wired" \
  || fail "24. findings-manifest without task files skips validation until task-writer is wired" "triage-only validation skip regressed"

# ── Test 25: existing VALIDATED section is replaced on successful revalidation ─
(
    setup_validation_repo_fixture "validated-rerun"
    agent_run_claude() {
        write_validation_result_json \
            "$2" \
            $'### Validation Result: VALIDATED\nPaths checked: 2 passed, 0 failed\nClaims checked: 2 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- (none)'
    }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-validated-rerun.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    cat >> "${task_path}" <<'EOF'

## Validation: VALIDATED

Validated by Night Shift validation agent on 2026-03-31.
EOF
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "$(grep -c '^## Validation:' "${task_path}")" == "1" ]] || ok=false
    grep -q '^## Validation: VALIDATED$' "${task_path}" || ok=false
    grep -q "^Validated by Night Shift validation agent on ${RUN_DATE}\\.$" "${task_path}" || ok=false
    ! grep -q '2026-03-31' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "25. revalidation replaces an existing VALIDATED section instead of appending another" \
  || fail "25. revalidation replaces an existing VALIDATED section instead of appending another" "validated rerun stamping regressed"

# ── Test 26: existing FAILED section is replaced by VALIDATED on retry ───────
(
    setup_validation_repo_fixture "failed-to-valid-rerun"
    agent_run_claude() {
        write_validation_result_json \
            "$2" \
            $'### Validation Result: VALIDATED\nPaths checked: 2 passed, 0 failed\nClaims checked: 2 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- (none)'
    }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-failed-to-valid-rerun.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    cat >> "${task_path}" <<'EOF'

## Validation: FAILED
- INVALID:path — stale/path.py not found
EOF
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "$(grep -c '^## Validation:' "${task_path}")" == "1" ]] || ok=false
    grep -q '^## Validation: VALIDATED$' "${task_path}" || ok=false
    ! grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    ! grep -q 'INVALID:path — stale/path.py not found' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "26. successful retry replaces an existing FAILED validation section" \
  || fail "26. successful retry replaces an existing FAILED validation section" "failed-to-valid rerun stamping regressed"

# ── Test 27: existing FAILED section is replaced on repeated failure ─────────
(
    setup_validation_repo_fixture "failed-rerun"
    agent_run_claude() {
        write_validation_result_json \
            "$2" \
            $'### Validation Result: INVALID\nPaths checked: 1 passed, 1 failed\nClaims checked: 1 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- INVALID:path — refreshed/path.py not found'
    }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-failed-rerun.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    cat >> "${task_path}" <<'EOF'

## Validation: FAILED
- INVALID:path — stale/path.py not found
EOF
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "${VALIDATION_INVALID_COUNT}" == "1" ]] || ok=false
    [[ "$(grep -c '^## Validation:' "${task_path}")" == "1" ]] || ok=false
    grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    grep -q 'INVALID:path — refreshed/path.py not found' "${task_path}" || ok=false
    ! grep -q 'INVALID:path — stale/path.py not found' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "27. repeated failure replaces an existing FAILED validation section instead of appending another" \
  || fail "27. repeated failure replaces an existing FAILED validation section instead of appending another" "failed rerun stamping regressed"

# ── Test 28: first validation still writes a single section on clean tasks ───
(
    setup_validation_repo_fixture "fresh-validation-section"
    agent_run_claude() {
        write_validation_result_json \
            "$2" \
            $'### Validation Result: VALIDATED\nPaths checked: 2 passed, 0 failed\nClaims checked: 2 confirmed, 0 contradicted\nStructure: complete\nFailed checks:\n- (none)'
    }

    task_path="${REPO_ROOT}/docs/tasks/open/nightshift/${RUN_DATE}-fresh-validation-section.md"
    write_validation_task_file \
        "${task_path}" \
        $'- `src/services/clean_rag/embedding_service.py` — live signature reference\n- `docs/tasks/TEMPLATE.md` — template contract reference' \
        $'- `src/services/clean_rag/embedding_service.py` defines `similarity_search()` with explicit parameters.\n- `docs/tasks/TEMPLATE.md` includes a `## Done Criteria` section.'
    write_validation_manifest "${task_path}"

    phase_validation >/dev/null 2>&1

    ok=true
    [[ "$(grep -c '^## Validation:' "${task_path}")" == "1" ]] || ok=false
    grep -q '^## Validation: VALIDATED$' "${task_path}" || ok=false
    ! grep -q '^## Validation: FAILED$' "${task_path}" || ok=false
    [[ "${ok}" == "true" ]]
) && pass "28. first validation on a clean task still writes exactly one section" \
  || fail "28. first validation on a clean task still writes exactly one section" "single-section validation stamping regressed"

echo ""
echo "=== Results: $PASS passed, $FAIL failed (28 tests) ==="
[[ "${FAIL}" -eq 0 ]]

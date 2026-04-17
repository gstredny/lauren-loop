#!/usr/bin/env bash

nightshift_suppression_artifacts_dir() {
    printf '%s/suppression\n' "${RUN_TMP_DIR}"
}

nightshift_suppression_report_path() {
    printf '%s/report.json\n' "$(nightshift_suppression_artifacts_dir)"
}

nightshift_suppression_section_path() {
    local section_name="$1"
    printf '%s/%s\n' "$(nightshift_suppression_artifacts_dir)" "${section_name}"
}

nightshift_python_bin() {
    if [[ -x "${REPO_ROOT}/.venv/bin/python" ]]; then
        printf '%s\n' "${REPO_ROOT}/.venv/bin/python"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        command -v python
        return 0
    fi
    return 1
}

nightshift_run_python_cli() {
    local pybin=""

    if ! pybin="$(nightshift_python_bin)"; then
        append_failure "Nightshift suppression helper requires Python but no interpreter was found"
        return 1
    fi

    (
        cd "${REPO_ROOT}/scripts/nightshift/python" &&
        "${pybin}" -m nightshift.cli.suppressions "$@"
    )
}

nightshift_apply_suppressions() {
    local report_path=""
    local warning=""

    SUPPRESSED_FINDINGS_COUNT=0
    FINDINGS_ELIGIBLE_FOR_RANKING="${TOTAL_FINDINGS_AVAILABLE}"

    mkdir -p "$(nightshift_suppression_artifacts_dir)"

    if ! nightshift_run_python_cli apply \
        --findings-dir "${NIGHTSHIFT_FINDINGS_DIR}" \
        --suppressions-file "${NIGHTSHIFT_SUPPRESSIONS_FILE:-${REPO_ROOT}/docs/nightshift/suppressions.yaml}" \
        --digests-dir "${NIGHTSHIFT_DIGESTS_DIR:-${REPO_ROOT}/docs/nightshift/digests}" \
        --run-date "${RUN_DATE}" \
        --output-dir "$(nightshift_suppression_artifacts_dir)"; then
        append_failure "Suppression engine failed; findings flowed through without suppression"
        return 1
    fi

    report_path="$(nightshift_suppression_report_path)"
    if [[ ! -s "${report_path}" ]]; then
        append_failure "Suppression engine did not produce a report artifact"
        return 1
    fi

    SUPPRESSED_FINDINGS_COUNT="$(jq -r '.suppressed_count // 0' "${report_path}")"
    FINDINGS_ELIGIBLE_FOR_RANKING="$(jq -r '.eligible_total // 0' "${report_path}")"

    while IFS= read -r warning; do
        [[ -n "${warning}" ]] || continue
        append_warning "${warning}"
    done < <(jq -r '.warnings[]?' "${report_path}")

    return 0
}

nightshift_write_empty_manager_digest_body() {
    local digest_path="$1"
    mkdir -p "$(dirname "${digest_path}")"
    cat > "${digest_path}" <<'EOF'
# Nightshift Detective Digest

## Ranked Findings

| # | Severity | Category | Title |
|---|----------|----------|-------|

## Minor & Observation Findings

| # | Title | Severity | Category | Source Detective | Evidence Summary |
|---|-------|----------|----------|-----------------|-----------------|
EOF
}

nightshift_render_suppression_sections() {
    local section_file=""
    local any_rendered=0

    for section_file in \
        "$(nightshift_suppression_section_path "suppressed-findings.md")" \
        "$(nightshift_suppression_section_path "expired-suppressions.md")" \
        "$(nightshift_suppression_section_path "expiring-soon.md")" \
        "$(nightshift_suppression_section_path "missing-rule-key.md")"; do
        [[ -s "${section_file}" ]] || continue
        if [[ "${any_rendered}" -eq 1 ]]; then
            printf '\n'
        fi
        cat "${section_file}"
        any_rendered=1
    done
}

nightshift_annotate_digest_with_fingerprints() {
    local digest_path="$1"

    if ! nightshift_run_python_cli annotate-digest \
        --digest-path "${digest_path}" \
        --findings-dir "${NIGHTSHIFT_FINDINGS_DIR}"; then
        append_warning "Digest fingerprint annotation failed for ${digest_path}"
        return 1
    fi

    return 0
}

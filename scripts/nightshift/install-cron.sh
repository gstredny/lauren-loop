#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NIGHTSHIFT_PYTHON_DIR="${REPO_ROOT}/scripts/nightshift/python"
NIGHTSHIFT_PYTHON_BIN="${REPO_ROOT}/.venv/bin/python"
CRON_LOG_PATH="${REPO_ROOT}/scripts/nightshift/logs/cron.log"
BEGIN_MARKER="# BEGIN nightshift-detective"
END_MARKER="# END nightshift-detective"

strip_existing_block() {
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin { in_block = 1; next }
        in_block && $0 == end { in_block = 0; next }
        !in_block { print }
    '
}

main() {
    local existing=""
    local stripped=""
    local cron_line=""

    existing="$(crontab -l 2>/dev/null || true)"
    stripped="$(printf '%s\n' "$existing" | strip_existing_block)"
    cron_line="0 23 * * 1-5 bash -l -c '{ cd ${NIGHTSHIFT_PYTHON_DIR} && ${NIGHTSHIFT_PYTHON_BIN} -m nightshift --smoke; } >> ${CRON_LOG_PATH} 2>&1'"

    {
        if [[ -n "$stripped" ]]; then
            printf '%s\n' "$stripped"
        fi
        printf '%s\n' "$BEGIN_MARKER"
        printf '%s\n' "$cron_line"
        printf '%s\n' "$END_MARKER"
    } | crontab -

    printf 'Installed weeknight Nightshift cron block for %s\n' "$NIGHTSHIFT_PYTHON_DIR"
}

main "$@"

#!/usr/bin/env bash

set -euo pipefail

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

    existing="$(crontab -l 2>/dev/null || true)"
    if [[ "$existing" != *"$BEGIN_MARKER"* ]]; then
        printf 'No nightshift cron entry found\n'
        exit 0
    fi

    stripped="$(printf '%s\n' "$existing" | strip_existing_block)"
    printf '%s\n' "$stripped" | crontab -
    printf 'Removed Nightshift cron block\n'
}

main "$@"

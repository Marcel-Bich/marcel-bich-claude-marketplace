#!/bin/bash
# credo-item-counts - count work items per status folder (read-only).
#
# The folder an item file lives in is the only source of truth for its status
# (see credo-item-move.sh). This helper just counts item files (<id>-<slug>.md)
# per status folder of the resolved project, so any renderer (a terminal, a
# status line, a Claude Code mod, another harness) can show live counts without
# knowing the folder layout.
#
# Usage:
#   credo-item-counts.sh           key=value lines (credo_dir=..., clarify=13, ...)
#   credo-item-counts.sh --json    one JSON object
#
# The project is CREDO_DIR when set, otherwise credo-config.sh resolve-project
# (session pin, hub-aware). Keys: clarify go blocked done verified archived
# hold future (parked = hold + future is left to the renderer).
#
# Exit codes: 0 counts printed, 4 no credo project resolved (prints nothing),
# 1 bad argument.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="kv"
case "${1:-}" in
    "") ;;
    --json) MODE="json" ;;
    *) echo "credo-item-counts: unknown argument: $1" >&2; exit 1 ;;
esac

if [ -n "${CREDO_DIR:-}" ]; then
    DIR="$CREDO_DIR"
else
    DIR="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)" || exit 4
fi
[ -d "$DIR/items" ] || exit 4

count() {
    local d="$DIR/items/$1"
    [ -d "$d" ] || { echo 0; return; }
    find "$d" -maxdepth 1 -type f -name '[0-9]*-*.md' | wc -l | tr -d ' '
}

KEYS=(clarify go blocked "done" verified archived hold future)
PATHS=(1_todo/1_clarify 1_todo/2_go 1_todo/3_blocked 2_done 3_verified 4_archived parked/hold parked/future)

if [ "$MODE" = "json" ]; then
    out="{\"credo_dir\":\"$DIR\""
    for i in "${!KEYS[@]}"; do
        out="$out,\"${KEYS[$i]}\":$(count "${PATHS[$i]}")"
    done
    printf '%s}\n' "$out"
else
    printf 'credo_dir=%s\n' "$DIR"
    for i in "${!KEYS[@]}"; do
        printf '%s=%s\n' "${KEYS[$i]}" "$(count "${PATHS[$i]}")"
    done
fi

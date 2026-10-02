#!/bin/bash
# credo-session-status - print one session's mode, role and autonomy (read-only).
#
# The per-session state files are the only source of truth (written by
# hooks/session-mode-set.sh, hooks/role-set.sh and the autonomy hooks). This
# helper just reads them, so any renderer (a terminal, a status line, a Claude
# Code mod, another harness) can show the session state without knowing where
# it lives.
#
# Usage:
#   credo-session-status.sh [--json] [session_id]
#     (no flag)  key=value lines (session_id=..., mode=..., role=...,
#                autonomy_running=yes|no, autonomy_paused=yes|no,
#                wake_scheduled=<epoch>|)
#     --json     one JSON object:
#                {"session_id":"...","mode":"active"|null,"role":"task"|null,
#                 "autonomy":{"running":true|false,"paused":true|false,
#                             "wake_scheduled":<epoch>|null}}
#
# paused is the session's hard opt-out flag. credo also sets it for every
# active/passive session, so it only means something while mode is
# autonomous (a user message paused the run as a fail-safe).
#
# Session id: the argument, else $CREDO_SESSION_ID, else $CLAUDE_CODE_SESSION_ID
# (same order as hooks/credo-autonomy-lib.sh).
#
# State locations (same overrides as the writers):
#   mode      ${CREDO_SESSION_MODES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-modes}/<sid>
#   role      ${CREDO_SESSION_ROLES_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-roles}/<sid>
#   autonomy  credo_autonomy_dir <sid> (hooks/credo-autonomy-lib.sh)
#
# Exit codes: 0 status printed, 2 no valid session id, 1 bad argument.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/credo-autonomy-lib.sh
. "$SCRIPT_DIR/../hooks/credo-autonomy-lib.sh"

MODE="kv"
ARG_SID=""
for a in "$@"; do
    case "$a" in
        --json) MODE="json" ;;
        -*) echo "credo-session-status: unknown argument: $a" >&2; exit 1 ;;
        *)
            [ -z "$ARG_SID" ] || { echo "credo-session-status: too many arguments" >&2; exit 1; }
            ARG_SID="$a"
            ;;
    esac
done

SID="$(credo_autonomy_resolve_id "$ARG_SID")" || {
    echo "credo-session-status: no valid session id (pass it or set CREDO_SESSION_ID / CLAUDE_CODE_SESSION_ID)" >&2
    exit 2
}

PROFILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MODES_DIR="${CREDO_SESSION_MODES_DIR:-$PROFILE/credo/session-modes}"
ROLES_DIR="${CREDO_SESSION_ROLES_DIR:-$PROFILE/credo/session-roles}"

# first line of a state file, trimmed; empty when missing or empty
first_line() {
    [ -f "$1" ] || return 0
    head -n 1 "$1" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

mode="$(first_line "$MODES_DIR/$SID")"
role="$(first_line "$ROLES_DIR/$SID")"

running="no"
credo_autonomy_running "$SID" && running="yes"

paused="no"
[ -f "$(credo_autonomy_dir "$SID")/paused" ] && paused="yes"

wake=""
wake_file="$(credo_autonomy_dir "$SID")/wake-scheduled"
if [ "$running" = "yes" ]; then
    wake="$(first_line "$wake_file")"
    case "$wake" in
        ""|*[!0-9]*) wake="" ;;
    esac
fi

# JSON string or null; mode/role values are plain words, escape defensively
json_str() {
    if [ -z "$1" ]; then
        printf 'null'
    else
        local s="${1//\\/\\\\}"
        s="${s//\"/\\\"}"
        printf '"%s"' "$s"
    fi
}

if [ "$MODE" = "json" ]; then
    printf '{"session_id":%s,"mode":%s,"role":%s,"autonomy":{"running":%s,"paused":%s,"wake_scheduled":%s}}\n' \
        "$(json_str "$SID")" "$(json_str "$mode")" "$(json_str "$role")" \
        "$([ "$running" = "yes" ] && echo true || echo false)" \
        "$([ "$paused" = "yes" ] && echo true || echo false)" "${wake:-null}"
else
    printf 'session_id=%s\nmode=%s\nrole=%s\nautonomy_running=%s\nautonomy_paused=%s\nwake_scheduled=%s\n' \
        "$SID" "$mode" "$role" "$running" "$paused" "$wake"
fi

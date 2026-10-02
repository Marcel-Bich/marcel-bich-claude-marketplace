#!/usr/bin/env bash
# credo-autonomy-lib.sh - shared helpers for the per-session autonomy state.
#
# SOURCE this file (do not execute it). It only defines functions; it never
# changes shell options, never reads stdin and never writes anything.
#
# Autonomy state is keyed by session_id, exactly like the session modes/roles:
#   <base>/<session_id>/active          full autonomy ON (keep-alive armed)
#   <base>/<session_id>/paused          hard opt-out (Stop hook inert)
#   <base>/<session_id>/wake-scheduled  Unix timestamp of the next self-wake
# with <base> = $CREDO_AUTONOMY_DIR, default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy. Autonomy in one session
# therefore never affects another session.
#
# API:
#   credo_autonomy_valid_id <id>
#       exit 0 when <id> is a safe, non-empty session id (no path traversal).
#   credo_autonomy_resolve_id [explicit]
#       print the session id and exit 0; exit 1 (no output) when none resolves
#       or the first non-empty candidate is invalid. Order: [explicit] (a script
#       argument, or the session_id from a hook's stdin JSON), then
#       $CREDO_SESSION_ID, then $CLAUDE_CODE_SESSION_ID.
#   credo_autonomy_dir <id>
#       print the per-session state dir (not created; caller mkdirs on write).
#   credo_autonomy_running <id>
#       exit 0 when <id> has autonomy active AND not paused, else 1.

credo_autonomy_valid_id() {
    case "${1:-}" in
        ""|*[!A-Za-z0-9._-]*|.|*..*) return 1 ;;
    esac
    return 0
}

credo_autonomy_resolve_id() {
    local cand="${1:-}"
    [ "$cand" = "null" ] && cand=""
    [ -n "$cand" ] || cand="${CREDO_SESSION_ID:-}"
    [ -n "$cand" ] || cand="${CLAUDE_CODE_SESSION_ID:-}"
    credo_autonomy_valid_id "$cand" || return 1
    printf '%s\n' "$cand"
}

credo_autonomy_dir() {
    printf '%s/%s\n' "${CREDO_AUTONOMY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy}" "$1"
}

credo_autonomy_running() {
    local d
    credo_autonomy_valid_id "${1:-}" || return 1
    d="$(credo_autonomy_dir "$1")"
    [ -f "$d/active" ] || return 1
    [ -f "$d/paused" ] && return 1
    return 0
}

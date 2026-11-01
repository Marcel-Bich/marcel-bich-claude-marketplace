#!/usr/bin/env bash
# credo-reminder.sh turn|start - credo plugin hook entry of the periodic reminder
# (scripts/credo-reminder.py). "turn" is the UserPromptSubmit turn counter, "start" the
# SessionStart start of the worker of an armed session. The settings come from the credo
# config (key reminder, per mode).
#
# Cost when off: before python or credo-config.sh run, a cheap shell check looks for an
# active mode key under `reminder:` in the user config layers credo-config.sh may read
# (global, profile, project). None -> exit at once. The builtin template is not checked
# (its mode keys are commented out); a layer that is missed would hide a reminder, so every
# layer credo-config.sh can read is listed below.
#
# Always exits 0 - a hook never blocks a prompt or a session start.
set -u

input="$(cat 2>/dev/null || true)"
command -v python3 >/dev/null 2>&1 || exit 0
case "${1:-}" in
    turn|start) ;;
    *) exit 0 ;;
esac

reminder_mode_key() { # file -> 0 when it sets an active reminder mode
    [ -f "$1" ] || return 1
    awk '
        /^reminder:/ { if ($0 ~ /(active|passive|autonomous)/) found = 1; inblock = 1; next }
        /^[^[:space:]#]/ { inblock = 0 }
        inblock && /^[[:space:]]+(active|passive|autonomous)[[:space:]]*:/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$1"
}

reminder_may_be_set() { # 0 when some user config layer may set an active mode
    local sid pin_root pinned top f
    sid="$(printf '%s' "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/')"
    [ -n "$sid" ] || sid="${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
    pin_root="${CREDO_SESSION_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-projects}"
    pinned=""
    case "$sid" in
        ""|.|..|*[!A-Za-z0-9._-]*) ;;
        *) [ -f "$pin_root/$sid" ] && pinned="$(sed -n '1p' "$pin_root/$sid" 2>/dev/null | tr -d '\r')" ;;
    esac
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
    # the layers credo-config.sh reads: global, profile, project (CREDO_PROJECT, CREDO_DIR,
    # session pin, git toplevel of the cwd, cwd; CLAUDE_PROJECT_DIR is listed as well)
    for f in \
        "${CREDO_GLOBAL:-$HOME/.claude/credo/config}" \
        "${CREDO_PROFILE:-${CLAUDE_CONFIG_DIR:+${CLAUDE_CONFIG_DIR%/}/credo/config}}" \
        "${CREDO_PROJECT:-}" \
        "${CREDO_DIR:+$CREDO_DIR/config}" \
        "${pinned:+$pinned/.credo/config}" \
        "${top:+$top/.credo/config}" \
        "$PWD/.credo/config" \
        "${CLAUDE_PROJECT_DIR:+$CLAUDE_PROJECT_DIR/.credo/config}"; do
        [ -n "$f" ] && reminder_mode_key "$f" && return 0
    done
    return 1
}

reminder_may_be_set || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
printf '%s' "$input" | python3 "$SCRIPT_DIR/../scripts/credo-reminder.py" "$1" >/dev/null 2>&1 || true
exit 0

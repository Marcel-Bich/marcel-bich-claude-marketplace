#!/bin/bash
# Dogma: credo detection for the per-prompt workflow injects
#
# When the credo plugin is active for the session, dogma's workflow injects step
# back (credo's orchestration, items, done gate and release flow govern instead):
# the orchestration flow (subagent-suggestion.sh), the planning and versioning
# reminder lines (user-prompt-submit.sh), the /create-plan hint
# (prompt-intervention-reminder.sh) and the "ask before ticking" rule
# (checklist-tracking.sh). dogma's safety parts are never affected.
#
# "credo active" mirrors credo's own definition (credo-session-start.sh):
#   1. the session has a credo mode (active | passive | autonomous)
#        ${CLAUDE_CONFIG_DIR:-~/.claude}/credo/session-modes/<session_id>, OR
#   2. the session decision is "accepted"
#        ${CLAUDE_CONFIG_DIR:-~/.claude}/credo/session-decisions/<session_id>, OR
#   3. the working directory (git toplevel, else $PWD) is opted in ("accepted")
#        ${CLAUDE_CONFIG_DIR:-~/.claude}/credo/dir-decisions/<sha256 of the dir>
#      This one is persistent across sessions, so it only counts while the
#      credo plugin is enabled in the settings (user settings.json, project
#      .claude/settings.json, .claude/settings.local.json; the last one that
#      names credo@<marketplace> wins).
# Never active when credo's own workflow text stands down: the task backend is gsd
# (CREDO_TASK_BACKEND, else task_backend in the credo config layers) or
# CREDO_SESSION_START_INJECT is not "true".
# The per-session files are written by credo during this very session, so they
# need no settings check. credo's own env overrides are honored:
# CREDO_SESSION_MODES_DIR, CREDO_SESSION_DECISIONS_DIR, CREDO_DIR_DECISIONS_DIR.
#
# Fail open: anything unclear (no session id and no dir opt-in, unreadable
# state, no sha256sum, no jq for the settings check) counts as "not active", so
# dogma keeps its injects exactly as without credo.
#
# ENV: CLAUDE_MB_DOGMA_CREDO_DEFER=true (default) | false - false keeps every
#      dogma workflow inject even when credo is active.
#
# Usage:
#   source lib-credo.sh
#   if dogma_credo_active "$INPUT"; then ... fi   # INPUT = the hook's stdin JSON
# After the call DOGMA_CREDO_MODE holds the session mode (active | passive |
# autonomous) or is empty.

DOGMA_CREDO_MODE=""

# Read the first word of a state file, lowercased (empty when missing).
dogma_credo_state_word() {
    [ -f "$1" ] || return 0
    head -n1 "$1" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

# Is the credo plugin enabled in the settings? 0 = yes, 1 = no or unknown.
dogma_credo_plugin_enabled() {
    local top="$1" base state="" f v
    command -v jq >/dev/null 2>&1 || return 1
    base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    for f in "$base/settings.json" "$top/.claude/settings.json" "$top/.claude/settings.local.json"; do
        [ -f "$f" ] || continue
        v="$(jq -r '[(.enabledPlugins // {}) | to_entries[] | select(.key | startswith("credo@")) | .value] | last // empty' "$f" 2>/dev/null)" || v=""
        case "$v" in
            true|false) state="$v" ;;
        esac
    done
    [ "$state" = "true" ]
}

# The credo task backend (credo-config.sh backend): env CREDO_TASK_BACKEND, else the
# last task_backend of the config layers global < profile < project (CREDO_GLOBAL,
# CREDO_PROFILE, CREDO_PROJECT override the paths), else credo.
dogma_credo_backend() {
    local top="$1" base val="" f v
    if [ -n "${CREDO_TASK_BACKEND:-}" ]; then
        printf '%s\n' "$CREDO_TASK_BACKEND" | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    for f in "${CREDO_GLOBAL:-$HOME/.claude/credo/config}" "${CREDO_PROFILE:-$base/credo/config}" "${CREDO_PROJECT:-$top/.credo/config}"; do
        [ -f "$f" ] || continue
        v="$(sed -n 's/^task_backend:[[:space:]]*["'"'"']\{0,1\}\([A-Za-z0-9_-]*\).*/\1/p' "$f" 2>/dev/null | tail -n1)"
        [ -n "$v" ] && val="$v"
    done
    printf '%s\n' "${val:-credo}" | tr '[:upper:]' '[:lower:]'
}

# Is credo active for this session? 0 = yes, 1 = no or unsure (fail open).
dogma_credo_active() {
    local input="${1:-}" base sid mode decision top hash dir_decision
    DOGMA_CREDO_MODE=""
    [ "${CLAUDE_MB_DOGMA_CREDO_DEFER:-true}" = "true" ] || return 1
    # credo's whole workflow text is off (credo-session-start.sh toggle): not active.
    [ "${CREDO_SESSION_START_INJECT:-true}" = "true" ] || return 1
    base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
    [ -n "$top" ] || top="$PWD"
    # gsd task backend: credo's workflow stands down, so dogma's flow stays.
    [ "$(dogma_credo_backend "$top")" = "gsd" ] && return 1

    sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._-]*\)".*/\1/p' | head -n1)"
    case "$sid" in
        ""|.|*..*) sid="" ;;
    esac

    if [ -n "$sid" ]; then
        mode="$(dogma_credo_state_word "${CREDO_SESSION_MODES_DIR:-$base/credo/session-modes}/$sid")"
        case "$mode" in
            active|passive|autonomous)
                DOGMA_CREDO_MODE="$mode"
                return 0
                ;;
        esac
        decision="$(dogma_credo_state_word "${CREDO_SESSION_DECISIONS_DIR:-$base/credo/session-decisions}/$sid")"
        [ "$decision" = "accepted" ] && return 0
    fi

    # Persistent per-directory opt-in (same key as credo-dir-decision.sh).
    command -v sha256sum >/dev/null 2>&1 || return 1
    hash="$(printf '%s' "$top" | sha256sum | cut -d' ' -f1)"
    [ -n "$hash" ] || return 1
    dir_decision="$(dogma_credo_state_word "${CREDO_DIR_DECISIONS_DIR:-$base/credo/dir-decisions}/$hash")"
    [ "$dir_decision" = "accepted" ] || return 1
    dogma_credo_plugin_enabled "$top"
}

# Can no human answer a confirmation prompt in this session? 0 = yes (credo's autonomy
# keep-alive is running for the session: credo/autonomy/<session_id>/active exists and
# credo/autonomy/<session_id>/paused does not), 1 = no or unsure. Subagents share the
# session_id of their parent, so a subagent of an autonomous run counts as well.
# The state paths mirror credo-autonomy-lib.sh (CREDO_AUTONOMY_DIR overrides the base).
# Fail safe for the caller: anything unclear (no or invalid session id, missing state)
# returns 1, so the caller keeps its "ask".
dogma_credo_unattended() {
    local input="${1:-}" sid dir
    sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9._-]*\)".*/\1/p' | head -n1)"
    case "$sid" in
        ""|.|*..*) return 1 ;;
    esac
    dir="${CREDO_AUTONOMY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy}/$sid"
    [ -f "$dir/active" ] || return 1
    [ -e "$dir/paused" ] && return 1
    return 0
}

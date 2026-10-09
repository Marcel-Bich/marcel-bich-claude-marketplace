#!/usr/bin/env bash
# credo-session-dir-record.sh - credo plugin (SessionStart hook)
#
# Records the session folder (the folder the Claude Code session was started in) so
# scripts run later via the Bash tool find it even after `cd <project> && ...` changed
# their $PWD. credo-dogma-mode.sh reads it for the per-id inheritance of
# DOGMA-PERMISSIONS.md (§r3nx); dogma keeps its own record of the same format, so
# credo works without dogma installed.
#
# Record: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-dirs/<session_id>
#         one line, the absolute session folder. Scripts find it through
#         $CLAUDE_CODE_SESSION_ID (the same id the hooks get as session_id).
# Value:  $CLAUDE_PROJECT_DIR (where Claude Code was started; stable) when set,
#         else the hook's cwd. A cwd-derived value overwrites an existing record only
#         on startup / resume: on clear / compact / fork the cwd may already have
#         drifted, so the first record of the session is kept.
# Pruning: records not rewritten for 30 days are removed.
# Also, for source "compact" only, the self-compact done signal (see below).
#
# Failure-safe: no output, always exit 0; any problem just leaves no record (readers
# then fall back to $PWD exactly as before).

trap 'exit 0' ERR

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0
HAVE_JQ=1
command -v jq >/dev/null 2>&1 || HAVE_JQ=0
# plain string value of a top-level JSON key without jq (ids, sources, statuses only)
str_field() { # key text
    printf '%s' "$2" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
        | sed 's/.*:[[:space:]]*"\(.*\)"$/\1/'
}
sid="" cwd="" src=""
if [ "$HAVE_JQ" = 1 ]; then
    {
        IFS= read -r sid
        IFS= read -r cwd
        IFS= read -r src
    } < <(printf '%s' "$INPUT" | jq -r '(.session_id // "" | tostring), (.cwd // "" | tostring), (.source // "" | tostring)' 2>/dev/null)
else
    # without jq only the self-compact done signal below runs (no session-dir record)
    sid="$(str_field session_id "$INPUT")"
    src="$(str_field source "$INPUT")"
fi
case "$sid" in
    ""|.|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac

# Self-compact done signal: Claude Code fires SessionStart with source "compact" right
# after a compaction finished. When THIS session has a self-compact in flight
# (credo-self-compact.py marker status "typing" or "sent..."), drop the one-line
# marker <configdir>/credo/self-compact-done-<session_id> (epoch seconds, atomic) so
# the detached worker knows deterministically that the compact is done and can wake
# the session with ".". A manual /compact without a pending self-compact writes
# nothing. Cost is one test -f per SessionStart.
if [ "$src" = "compact" ]; then
    cstate="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo"
    if [ -f "$cstate/self-compact-$sid.json" ]; then
        if [ "$HAVE_JQ" = 1 ]; then
            cst="$(jq -r '.status // ""' "$cstate/self-compact-$sid.json" 2>/dev/null)" || cst=""
        else
            cst="$(str_field status "$(cat "$cstate/self-compact-$sid.json" 2>/dev/null)")"
        fi
        case "$cst" in
            typing|sent*)
                cdone="$cstate/self-compact-done-$sid"
                date +%s > "$cdone.tmp.$$" 2>/dev/null && mv -f "$cdone.tmp.$$" "$cdone" 2>/dev/null
                ;;
        esac
    fi
fi
[ "$HAVE_JQ" = 1 ] || exit 0

dir=""
forced=0
case "${CLAUDE_PROJECT_DIR:-}" in
    /*) [ -d "$CLAUDE_PROJECT_DIR" ] && { dir="$CLAUDE_PROJECT_DIR"; forced=1; } ;;
esac
if [ -z "$dir" ]; then
    case "$cwd" in
        /*) [ -d "$cwd" ] && dir="$cwd" ;;
    esac
fi
[ -n "$dir" ] || exit 0

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-dirs"
mkdir -p "$state" 2>/dev/null || exit 0
rec="$state/$sid"
write=1
if [ "$forced" = 0 ] && [ -f "$rec" ]; then
    case "$src" in
        startup|resume) ;;
        *) write=0 ;;
    esac
fi
if [ "$write" = 1 ]; then
    printf '%s\n' "$dir" > "$rec.tmp.$$" 2>/dev/null && mv -f "$rec.tmp.$$" "$rec" 2>/dev/null
fi
find "$state" -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null
exit 0

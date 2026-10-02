#!/usr/bin/env bash
# session-dir-record.sh - dogma plugin (SessionStart hook)
#
# Records the session folder (the folder the Claude Code session was started in) so
# scripts run later via the Bash tool find it even after `cd <project> && ...` changed
# their $PWD. lib-permissions.sh reads it for the per-id inheritance of
# DOGMA-PERMISSIONS.md (§r3nx); credo keeps its own record of the same format, so
# dogma works without credo installed.
#
# Record: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/session-dirs/<session_id>
#         one line, the absolute session folder. Scripts find it through
#         $CLAUDE_CODE_SESSION_ID (the same id the hooks get as session_id).
# Value:  $CLAUDE_PROJECT_DIR (where Claude Code was started; stable) when set,
#         else the hook's cwd. A cwd-derived value overwrites an existing record only
#         on startup / resume: on clear / compact / fork the cwd may already have
#         drifted, so the first record of the session is kept.
# Pruning: records not rewritten for 30 days are removed.
#
# Failure-safe: no output, always exit 0; any problem just leaves no record (readers
# then fall back to $PWD exactly as before).

trap 'exit 0' ERR
[ "${CLAUDE_MB_DOGMA_ENABLED:-true}" = "true" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "$INPUT" ] || exit 0
sid="" cwd="" src=""
{
    IFS= read -r sid
    IFS= read -r cwd
    IFS= read -r src
} < <(printf '%s' "$INPUT" | jq -r '(.session_id // "" | tostring), (.cwd // "" | tostring), (.source // "" | tostring)' 2>/dev/null)
case "$sid" in
    ""|.|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac

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

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dogma/session-dirs"
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

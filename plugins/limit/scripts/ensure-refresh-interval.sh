#!/usr/bin/env bash
# ensure-refresh-interval.sh - limit plugin (SessionStart hook)
#
# Existing users who set up the limit statusline BEFORE the refreshInterval
# feature have a settings.json whose statusLine block has no refreshInterval.
# Without it Claude Code only re-renders the statusline on assistant messages,
# so the line freezes while the main session is idle (e.g. during a long
# subagent) and the remaining budget shown goes stale. A plugin update alone
# cannot fix this: it does not touch the user's settings.json.
#
# This hook fixes it DETERMINISTICALLY: when the configured statusLine is the
# limit one and refreshInterval is missing, it backs up the settings file and
# adds refreshInterval itself (atomic write), then prints one visible notice
# that a restart is needed. It does not rely on the agent acting.
#
# NOTE (scope): this only runs when the limit PLUGIN is enabled (plugin hooks do
# not load for a disabled plugin). Users who run the limit statusline as a plain
# statusLine command with the plugin disabled are covered separately by the same
# heal inside the statusline script itself.
#
# Proof-of-fire: every invocation appends one line to
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.limit-refresh-heal-status
# recording the timestamp, the SessionStart source, and the action taken, so it
# is verifiable whether (and on which source) Claude Code actually runs this hook.
#
# Guards: only our statusLine (usage-statusline.sh / statusline-mb-combined.sh),
# only when refreshInterval is absent, only source startup|resume|clear (never
# compact|fork). Opt-out / value via CLAUDE_MB_LIMIT_AUTO_REFRESH_INTERVAL
# (0|off|false|no disables; a positive integer sets the value; default 5).
#
# Failure-safe: ANY problem -> exit 0. Never block a session.

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HEAL_STATUS="$CONFIG_DIR/.limit-refresh-heal-status"

# Proof-of-fire: record that the hook actually executed, before any guard can
# exit. Builtins + date only; never fails the hook.
_heal_log() {
    { printf '%s source=%s action=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')" "${1:-?}" "${2:-?}" \
        >> "$HEAL_STATUS"; } 2>/dev/null || true
}
_heal_log "?" "fired"

set -euo pipefail
trap 'exit 0' ERR

# --- opt-out / value ---
optval="${CLAUDE_MB_LIMIT_AUTO_REFRESH_INTERVAL:-20}"
case "$optval" in
    0|off|OFF|false|FALSE|no|NO) _heal_log "?" "opt-out"; exit 0 ;;
esac
[[ "$optval" =~ ^[1-9][0-9]*$ ]] || optval=5

command -v jq >/dev/null 2>&1 || { _heal_log "?" "no-jq"; exit 0; }

# --- read hook stdin (source) ---
INPUT=$(cat 2>/dev/null) || INPUT=""
source=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null) || source=""
[[ "$source" == "null" ]] && source=""
case "$source" in
    startup|resume|clear|"") ;;             # human-present (or unknown) -> proceed
    *) _heal_log "$source" "skip-source"; exit 0 ;;
esac

# --- find the settings file that actually defines a statusLine (local overrides base) ---
SETTINGS=""
for f in "$CONFIG_DIR/settings.local.json" "$CONFIG_DIR/settings.json"; do
    [[ -f "$f" ]] || continue
    sl=$(jq -c '.statusLine // empty' "$f" 2>/dev/null) || continue
    [[ -n "$sl" ]] || continue
    SETTINGS="$f"
    break
done
[[ -n "$SETTINGS" ]] || { _heal_log "$source" "no-statusline"; exit 0; }

# --- only act on OUR statusline ---
cmd=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null) || cmd=""
case "$cmd" in
    *usage-statusline.sh*|*statusline-mb-combined.sh*) ;;
    *) _heal_log "$source" "not-ours"; exit 0 ;;
esac

# --- only when refreshInterval is missing ---
ri=$(jq -r '.statusLine.refreshInterval // "none"' "$SETTINGS" 2>/dev/null) || ri="none"
[[ "$ri" == "none" ]] || { _heal_log "$source" "already-set"; exit 0; }

# --- deterministic heal: back up, then add refreshInterval atomically ---
cp -f "$SETTINGS" "${SETTINGS}.bak" 2>/dev/null || true
tmp="${SETTINGS}.mbheal.$$"
if jq --argjson v "$optval" '.statusLine.refreshInterval = $v' "$SETTINGS" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    if mv -f "$tmp" "$SETTINGS" 2>/dev/null; then
        _heal_log "$source" "added:${optval}"
        jq -n --arg ctx "[limit] Added \"statusLine.refreshInterval\": ${optval} to ${SETTINGS} (backup at ${SETTINGS}.bak) so the statusline stays live while the main session is idle (for example during long subagents). RESTART Claude Code to activate it. Set CLAUDE_MB_LIMIT_AUTO_REFRESH_INTERVAL=0 to opt out." \
            '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null || true
        _heal_log "$source" "write-failed"
    fi
else
    rm -f "$tmp" 2>/dev/null || true
    _heal_log "$source" "jq-failed"
fi

exit 0

#!/usr/bin/env bash
# ensure-refresh-interval.sh - limit plugin (SessionStart hook)
#
# Existing users who set up the limit statusline BEFORE the refreshInterval
# feature have a settings.json whose statusLine block has no refreshInterval.
# Without it Claude Code only re-renders the statusline on assistant messages,
# so the line freezes while the main session is idle - for example during a long
# subagent - and the remaining budget shown goes stale. A plugin update alone
# cannot fix this: it does not touch the user's settings.json.
#
# This hook detects that gap and NUDGES the agent (via additionalContext) to add
# the field transparently, with a backup, telling the user and noting the needed
# restart. It never edits settings.json itself - the agent does it in the open.
# Once refreshInterval is present the hook stays silent. New users are unaffected
# (setup already writes the field).
#
# Guards:
#   - Only when the configured statusLine.command is actually the limit one
#     (usage-statusline.sh) or the combined wrapper (statusline-mb-combined.sh).
#   - Only when refreshInterval is absent.
#   - Only on a human-present start (source startup|resume|clear), never compact|fork.
#   - Opt-out / value via CLAUDE_MB_LIMIT_AUTO_REFRESH_INTERVAL (0|off|false|no to
#     disable; a positive integer sets the value; default 5).
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a session.

set -euo pipefail
trap 'exit 0' ERR

# --- opt-out / value ---
optval="${CLAUDE_MB_LIMIT_AUTO_REFRESH_INTERVAL:-5}"
case "$optval" in
    0|off|OFF|false|FALSE|no|NO) exit 0 ;;
esac
[[ "$optval" =~ ^[1-9][0-9]*$ ]] || optval=5

command -v jq >/dev/null 2>&1 || exit 0

# --- read hook stdin (source); drain it either way ---
INPUT=$(cat 2>/dev/null) || exit 0
source=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null) || source=""
case "$source" in
    startup|resume|clear|"") ;;   # human-present (or unknown) -> proceed
    *) exit 0 ;;                   # compact|fork|other -> stay silent
esac

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- find the settings file that actually defines a statusLine (local overrides base) ---
SETTINGS=""
for f in "$CONFIG_DIR/settings.local.json" "$CONFIG_DIR/settings.json"; do
    [[ -f "$f" ]] || continue
    sl=$(jq -c '.statusLine // empty' "$f" 2>/dev/null) || continue
    [[ -n "$sl" ]] || continue
    SETTINGS="$f"
    break
done
[[ -n "$SETTINGS" ]] || exit 0

# --- only act on OUR statusline, and only when refreshInterval is missing ---
cmd=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null) || cmd=""
case "$cmd" in
    *usage-statusline.sh*|*statusline-mb-combined.sh*) ;;   # ours
    *) exit 0 ;;
esac

ri=$(jq -r '.statusLine.refreshInterval // "none"' "$SETTINGS" 2>/dev/null) || ri="none"
[[ "$ri" == "none" ]] || exit 0   # already configured (or the user set it) -> silent

# --- nudge the agent to add it transparently ---
read -r -d '' LINE <<EOF || true
[limit] The limit statusline is active, but ${SETTINGS} has no "statusLine.refreshInterval", so Claude Code only re-renders the statusline on assistant messages - it FREEZES while the main session is idle (for example during a long-running subagent), and the remaining 5h/weekly budget shown goes stale. Fix it now, once, in the open:
1. Back up the file: cp "${SETTINGS}" "${SETTINGS}.bak"
2. Add the field: jq '.statusLine.refreshInterval = ${optval}' "${SETTINGS}" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "${SETTINGS}"
3. Tell the user you added statusLine.refreshInterval = ${optval}, and that Claude Code must be RESTARTED for it to take effect.
Only do this if it is genuinely missing; if refreshInterval is already present, do nothing. Set CLAUDE_MB_LIMIT_AUTO_REFRESH_INTERVAL=0 to suppress this suggestion.
EOF

jq -n --arg ctx "$LINE" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null

exit 0

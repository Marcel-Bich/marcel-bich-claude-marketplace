#!/usr/bin/env bash
# credo-datetime-inject.sh - credo plugin (UserPromptSubmit hook)
#
# Purpose: inject the current local date and time into the model context on
# EVERY prompt, independent of the credo session mode. Two goals: make the agent
# generally date/time-aware, and give the mode-awareness rules a clock signal
# (compare successive injected timestamps to sense a large gap since the last
# user prompt). This hook does NOT gate on session mode or session_id - it always
# injects while enabled.
#
# Output: hookSpecificOutput.additionalContext with suppressOutput true (model
# context only, not the user chat). One short line, for example:
#   [credo-time] 2026-07-22 14:33 (Tue), TZ CEST
#
# No dependency on the limit plugin or any other plugin. jq is optional: used
# when present, otherwise a hand-built JSON string (the content is a controlled
# date format that is additionally stripped of quotes/backslashes, so it is safe
# to embed without jq escaping).
#
# Failure-safe: ANY problem -> exit 0 with no output. Never block a prompt.

# --- toggle (default on) ---
[[ "${CREDO_DATETIME_INJECT:-true}" == "true" ]] || exit 0

# Drain stdin so the producer never blocks on a full pipe; the content is unused
# (this hook injects regardless of session_id or mode).
cat >/dev/null 2>&1

# --- build the local date/time line ---
now=$(date '+%Y-%m-%d %H:%M (%a), TZ %Z' 2>/dev/null) || exit 0
[[ -n "$now" ]] || exit 0
line="[credo-time] ${now}"

# Defensive: keep the manual-JSON path safe even if the locale injected an odd
# character - strip backslashes, double quotes, and any control characters.
line=${line//\\/}
line=${line//\"/}
line=$(printf '%s' "$line" | tr -d '[:cntrl:]' 2>/dev/null) || exit 0
[[ -n "$line" ]] || exit 0

# --- emit JSON (suppressOutput so the user chat is not flooded) ---
if command -v jq >/dev/null 2>&1; then
    jq -n --arg ctx "$line" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}, suppressOutput: true}' 2>/dev/null
else
    printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"},"suppressOutput":true}\n' "$line"
fi

exit 0

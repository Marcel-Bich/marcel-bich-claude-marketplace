#!/usr/bin/env bash
# credo-autonomy-on.sh - activate the full-autonomy keep-alive mode.
#
# Sets the credo-autonomy-active flag and lifts the paused opt-out. Call this
# ONLY when full autonomy plus AFK has been explicitly granted (the session-mode
# set script calls it when switching to the autonomous mode). Never call it on
# your own.
# Optional argument: a short reason / repo hint recorded in the flag file.
set -eu
FLAG="$HOME/.claude/credo-autonomy-active"
rm -f "$HOME/.claude/credo-autonomy-paused" 2>/dev/null || true
mkdir -p "$(dirname "$FLAG")" 2>/dev/null || true
reason="${*:-}"
ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
{
    echo "activated_at: $ts"
    if [ -n "$reason" ]; then echo "reason: $reason"; fi
} > "$FLAG"
echo "credo-autonomy ON ($ts)${reason:+ - $reason}"

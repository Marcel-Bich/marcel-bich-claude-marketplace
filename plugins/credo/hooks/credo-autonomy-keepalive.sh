#!/usr/bin/env bash
# credo-autonomy-keepalive.sh - Stop hook.
#
# In full-autonomy mode (credo-autonomy-active set) the session must not fall
# asleep while there is open work and no self-wake scheduled. If so, this hook
# blocks the stop (exit 2) and instructs the agent to set a ScheduleWakeup now.
# It only acts when the autonomy flag is set, so outside autonomy it is a normal
# no-op stop. Loop-safe via stop_hook_active.
#
# Failure-safe: any error -> exit 0 (never hang a stop).
#
# NOTE: this is a coupling helper built in Phase 2. It is not registered in the
# plugin hooks manifest yet; the live Stop registration is part of the later
# switchover phase.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAG="$HOME/.claude/credo-autonomy-active"
WAKE="$HOME/.claude/credo-wake-scheduled"

input="$(cat 2>/dev/null || true)"

# Loop guard: if this stop was already continued by a Stop hook, do not block
# again (prevents a hang on error).
active="false"
if command -v jq >/dev/null 2>&1; then
    active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
fi
if [ "$active" != "true" ]; then
    if printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
        active="true"
    fi
fi
if [ "$active" = "true" ]; then
    exit 0
fi

# Hard opt-out: if autonomy was deliberately paused (credo-autonomy-off sets
# this), never trigger, even if a stale active flag lingers. Only
# credo-autonomy-on lifts the opt-out.
[ -f "$HOME/.claude/credo-autonomy-paused" ] && exit 0

# Not in autonomy mode -> nothing to do (normal stop).
[ -f "$FLAG" ] || exit 0

# A valid self-wake already in the future -> allow the stop.
if [ -f "$WAKE" ]; then
    wake_ts="$(tr -dc '0-9' < "$WAKE" 2>/dev/null || true)"
    now="$(date +%s)"
    if [ -n "$wake_ts" ] && [ "$wake_ts" -gt "$now" ] 2>/dev/null; then
        exit 0
    fi
fi

# Autonomy active + no valid wake -> block the stop and instruct.
echo "ACTION (autonomy keep-alive): You are in full-autonomy mode (flag ~/.claude/credo-autonomy-active is set) but NO ScheduleWakeup is set. Do NOT just end the turn. Set ScheduleWakeup NOW (chain calls for pauses over 1h) and mark the wake time with '$SCRIPT_DIR/credo-autonomy-wake-mark.sh <delaySeconds>' (same delaySeconds as the ScheduleWakeup). If the autonomous work is truly finished OR there is a showstopper / weekly hard limit: end the mode deliberately with '$SCRIPT_DIR/credo-autonomy-off.sh' - then you may stop." >&2
exit 2

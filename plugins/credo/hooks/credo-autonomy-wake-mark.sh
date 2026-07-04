#!/usr/bin/env bash
# credo-autonomy-wake-mark.sh <delaySeconds>
#
# Record a planned ScheduleWakeup time for the Stop keep-alive hook
# (credo-autonomy-keepalive.sh). Writes the absolute Unix timestamp
# (now + delaySeconds) to ~/.claude/credo-wake-scheduled. The Stop hook then
# lets the turn stop because a self-wake lies in the future. ALWAYS use this
# together with a ScheduleWakeup call, with the same delaySeconds.
set -eu
WAKE="$HOME/.claude/credo-wake-scheduled"
mkdir -p "$(dirname "$WAKE")" 2>/dev/null || true
delay="${1:-}"
case "$delay" in
    ''|*[!0-9]*)
        echo "usage: credo-autonomy-wake-mark.sh <delaySeconds (integer)>" >&2
        exit 1
        ;;
esac
now="$(date +%s)"
target="$((now + delay))"
echo "$target" > "$WAKE"
echo "wake marked for $target (now=$now, +${delay}s)"

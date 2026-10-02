#!/usr/bin/env bash
# credo-autonomy-keepalive.sh - Stop hook.
#
# In full-autonomy mode (this session's autonomy "active" flag set) the session
# must not fall asleep while there is open work and no self-wake scheduled. If
# so, this hook blocks the stop (exit 2) and instructs the agent to set a
# ScheduleWakeup now. It only acts when the autonomy flag of THIS session is set,
# so outside autonomy it is a normal no-op stop. Loop-safe via stop_hook_active.
#
# PER SESSION: the state lives under
#   ${CREDO_AUTONOMY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/autonomy}/<session_id>/
# (see credo-autonomy-lib.sh); the session_id comes from the hook stdin JSON, else
# $CREDO_SESSION_ID / $CLAUDE_CODE_SESSION_ID. An autonomous run in one session
# never keeps another session alive. Unknown session_id -> inert (normal stop).
#
# Failure-safe: any error -> exit 0 (never hang a stop).
#
# NOTE: this is registered in the plugin hooks manifest (hooks/hooks.json) as a
# Stop hook, together with credo-autonomy-clear.sh on UserPromptSubmit. It
# actively enforces the keep-alive discipline at runtime.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || exit 0
# shellcheck source=credo-autonomy-lib.sh
. "$SCRIPT_DIR/credo-autonomy-lib.sh" 2>/dev/null || exit 0

input="$(cat 2>/dev/null || true)"

# Loop guard: if this stop was already continued by a Stop hook, do not block
# again (prevents a hang on error).
active="false"
stdin_session_id=""
if command -v jq >/dev/null 2>&1; then
    active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
    stdin_session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi
if [ "$active" != "true" ]; then
    if printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
        active="true"
    fi
fi
if [ "$active" = "true" ]; then
    exit 0
fi

# Unknown session -> treat as "not autonomous" (never block a stop for that).
session_id="$(credo_autonomy_resolve_id "$stdin_session_id")" || exit 0
STATE_DIR="$(credo_autonomy_dir "$session_id")"
FLAG="$STATE_DIR/active"
WAKE="$STATE_DIR/wake-scheduled"

# Hard opt-out: if autonomy was deliberately paused (credo-autonomy-off sets
# this), never trigger, even if a stale active flag lingers. Only
# credo-autonomy-on lifts the opt-out.
[ -f "$STATE_DIR/paused" ] && exit 0

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
echo "ACTION (autonomy keep-alive): You are in full-autonomy mode (flag $FLAG is set for this session) but NO ScheduleWakeup is set. Do NOT just end the turn. Set ScheduleWakeup NOW (chain calls for pauses over 1h) and mark the wake time with '$SCRIPT_DIR/credo-autonomy-wake-mark.sh <delaySeconds> $session_id' (same delaySeconds as the ScheduleWakeup). If the autonomous work is truly finished OR there is a showstopper / weekly hard limit: end the mode deliberately with '$SCRIPT_DIR/credo-autonomy-off.sh $session_id' - then you may stop. IMPORTANT: if a suspend-on-idle directive is set for this session, EVERY deliberate exit (finished, showstopper, or weekly hard limit) MUST first run the session-autonomous SKILL power-down sequence (drive GO items as far as buildable to done, ntfy, ~20 min veto window, then power down); a bare 'credo-autonomy-off.sh' will REFUSE (exit 1) and keep the keep-alive armed. The power-down sequence calls 'credo-autonomy-off.sh --after-suspend $session_id' as its final step; only an explicit user 'leave it on' justifies 'credo-autonomy-off.sh --override $session_id'. 'GO is not empty' with nothing actually buildable is NOT a reason to skip the suspend." >&2
exit 2

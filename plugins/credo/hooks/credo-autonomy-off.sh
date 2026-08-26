#!/usr/bin/env bash
# credo-autonomy-off.sh - end the full-autonomy keep-alive mode.
#
# Call this when the autonomous work is finished, on a showstopper, or at the
# weekly hard limit (the session-mode set script calls it when switching to the
# active or passive mode). Removes the active flag plus the wake marker and sets
# a hard paused opt-out so the Stop keep-alive hook stays inert until
# credo-autonomy-on.sh is explicitly called again.
#
# This stays a PURE, fail-safe flag flip: no ntfy, no Ask, no presence check, and it
# does NOT delete the durable suspend-on-idle directive (credo-suspend-directive.sh).
# The directive persists until an explicit revocation, so an end-of-run autonomy-off
# must never drop it - otherwise it would be lost on every run (the reported bug). The
# attended "ask before suspend" branch lives in the session-autonomous SKILL, not in
# this hook.
set -u
FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo-autonomy-active"
WAKE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo-wake-scheduled"
mkdir -p "$(dirname "$FLAG")" 2>/dev/null || true
rm -f "$FLAG" "$WAKE" 2>/dev/null || true
: > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo-autonomy-paused" 2>/dev/null || true
echo "credo-autonomy OFF (paused: Stop hook guaranteed inert until credo-autonomy-on)"

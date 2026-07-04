#!/usr/bin/env bash
# credo-autonomy-clear.sh - UserPromptSubmit hook.
#
# The keep-alive obligation (see credo-autonomy-keepalive.sh) may only apply in
# full-autonomy mode. On every real user message the autonomy flag is cleared:
# the user typing = autonomy OFF = no more obligation. This is the primary guard
# against an endless keep-alive loop.
#
# EXCEPTION: self-scheduled ScheduleWakeup wake prompts carry the marker
# [CREDO-AUTONOMY-WAKE] and must NOT clear the flag. Background subagent
# completions (<task-notification>) and automated system events
# ([SYSTEM NOTIFICATION - NOT USER INPUT]) are also exempt, otherwise every
# subagent finish would end autonomy.
#
# Failure-safe: any error -> exit 0 (never block a prompt).
#
# NOTE: this is a coupling helper built in Phase 2. It is not registered in the
# plugin hooks manifest yet; the live UserPromptSubmit registration is part of
# the later switchover phase.
set -u

FLAG="$HOME/.claude/credo-autonomy-active"
WAKE="$HOME/.claude/credo-wake-scheduled"

input="$(cat 2>/dev/null || true)"

prompt=""
if command -v jq >/dev/null 2>&1; then
    prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
fi

case "$prompt$input" in
    *"[CREDO-AUTONOMY-WAKE]"* | *"<task-notification>"* | *"[SYSTEM NOTIFICATION - NOT USER INPUT]"*)
        exit 0
        ;;
esac

# Real user message -> end autonomy: drop flag + wake marker and set the hard
# paused opt-out. The Stop hook then stays inert until credo-autonomy-on is
# explicitly called again.
rm -f "$FLAG" "$WAKE" 2>/dev/null || true
: > "$HOME/.claude/credo-autonomy-paused" 2>/dev/null || true
exit 0

#!/bin/bash
# stop-notify.sh: Desktop notification on task completion
# Part of desktop-notifier plugin for Claude Code

# === CONFIGURATION (via environment variables) ===
# CLAUDE_NOTIFY_HAIKU: "true" to enable AI summaries (default: false)
# CLAUDE_NOTIFY_SOUND_COMPLETE: volume 0.0-1.0 (default: 0.4), 0 to disable

HAIKU_ENABLED="${CLAUDE_NOTIFY_HAIKU:-false}"
SOUND_VOLUME="${CLAUDE_NOTIFY_SOUND_COMPLETE:-0.4}"

# Get plugin root directory
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Load WSL utilities
source "$PLUGIN_ROOT/scripts/wsl-utils.sh"

# Read JSON input
INPUT=$(cat)

# Extract key fields
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // "null"')

# Skip for subagents
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

if [[ "$TRANSCRIPT_PATH" == *"agent-"* ]]; then
    exit 0
fi

if [ -n "$TRANSCRIPT_PATH" ] && [ -n "$SESSION_ID" ]; then
    TRANSCRIPT_BASENAME=$(basename "$TRANSCRIPT_PATH" .jsonl)
    if [[ "$TRANSCRIPT_BASENAME" != *"$SESSION_ID"* ]]; then
        exit 0
    fi
fi

# Global debounce: Only 1 notification per 10 seconds per project
PROJECT=$(basename "$CWD" 2>/dev/null || echo "claude")
DEBOUNCE_FILE="/tmp/claude-notify-${PROJECT}"
NOW=$(date +%s)
if [ -f "$DEBOUNCE_FILE" ]; then
    LAST_TIME=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo "0")
    if [ $((NOW - LAST_TIME)) -lt 10 ]; then
        exit 0
    fi
fi
echo "$NOW" > "$DEBOUNCE_FILE"

# Extract last 5 TEXT messages for context
RAW=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    RAW=$(grep -E '"type":"(user|assistant)"' "$TRANSCRIPT_PATH" 2>/dev/null | \
        jq -r '
            if .type == "user" and (.message.content | type) == "string" then
                "USER: " + .message.content[0:200]
            elif .type == "user" and (.message.content[]? | select(.type=="tool_result" and .is_error==true)) then
                (.message.content[]? | select(.type=="tool_result") | .content // "") as $c |
                if ($c | contains("user said:")) then
                    "USER: " + ($c | split("user said:")[1] // "")[0:200]
                else empty end
            elif .message.content[]?.type == "text" then
                if .type == "user" then
                    "USER: " + ([.message.content[]? | select(.type=="text") | .text] | join(" "))[0:200]
                else
                    "CLAUDE: " + ([.message.content[]? | select(.type=="text") | .text] | join(" "))[0:300]
                end
            else empty end
        ' 2>/dev/null | \
        sed 's/^USER: [\n\r]*/USER: /' | \
        grep -E '^(USER|CLAUDE): .{5,}' | \
        grep -v 'Request interrupted' | \
        grep -v '^USER: \[' | \
        grep -v '^USER: <' | \
        grep -v 'This session is being continued' | \
        tail -5 | \
        head -c 1500)
fi

# Skip generic greetings
if [ -n "$RAW" ]; then
    if echo "$RAW" | grep -qiE "^(ich bin bereit|wie kann ich|was kann ich|hallo|hi,|guten tag)"; then
        exit 0
    fi
fi

# Generate summary
SUMMARY=""

# Option 1: Haiku summary (if enabled and has context)
if [ "$HAIKU_ENABLED" = "true" ] && [ -n "$RAW" ] && [ ${#RAW} -gt 50 ]; then
    if command -v claude &> /dev/null; then
        SUMMARY=$(timeout 15 claude -p --model haiku --no-session-persistence \
            "Summarize in ONE sentence (max 120 chars) what is being worked on. Use the SAME LANGUAGE as the conversation below.

RULES:
- Only ONE sentence, no lists, no markers
- NO tags like [CLAUDE_LOG], [CLAUDE_READY] etc.
- Don't quote, describe directly
- Match the language of USER/CLAUDE messages

Conversation:
$RAW

Summary:" \
            2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | head -c 250)
    fi
fi

# Option 2: Fallback
if [ -z "$SUMMARY" ] || [ ${#SUMMARY} -lt 10 ]; then
    SUMMARY="Task completed - check terminal for details"
fi

# Send notification
"$PLUGIN_ROOT/scripts/notify-replace.sh" "project-${PROJECT}-stop" "✨ Done [$PROJECT]" "$SUMMARY" "dialog-information" 1

# Play completion sound
if is_wsl; then
    # WSL: Use Windows system sound with volume
    windows_sound "complete" "$SOUND_VOLUME"
elif command -v paplay &> /dev/null && [ "$(echo "$SOUND_VOLUME > 0" | bc 2>/dev/null)" = "1" ]; then
    # Linux: Original paplay code
    CURRENT_VOL=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
    PLAY_VOL=$(echo "${CURRENT_VOL:-50} * $SOUND_VOLUME * 655.36" | bc 2>/dev/null | cut -d. -f1)
    [ -n "$PLAY_VOL" ] && paplay --volume="$PLAY_VOL" /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
fi

exit 0

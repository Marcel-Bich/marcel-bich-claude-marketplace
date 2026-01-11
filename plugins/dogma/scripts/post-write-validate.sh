#!/bin/bash
# Dogma: PostToolUse Write/Edit Hook
# Validates content AFTER it was written
# Checks for AI traces that slipped through
#
# IDEA.md line 350-360:
# - PostToolUse Write/Edit: Validates written content
# - AI Traces (Typography): 100% - Pattern-Match
# - AI Traces (Phrases): ~90% - Heuristic
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_POST_WRITE_VALIDATE=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== post-write-validate.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_POST_WRITE_VALIDATE:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only process Write and Edit results
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
    exit 0
fi

# Extract file path and content that was written
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CONTENT=""

if [ "$TOOL_NAME" = "Write" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [ "$TOOL_NAME" = "Edit" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
fi

if [ -z "$CONTENT" ] || [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Get file extension to determine if it's code
EXT="${FILE_PATH##*.}"

# Track violations
VIOLATIONS=""

# ============================================
# 1. Typography Violations (100% detectable)
# ============================================

# Curly quotes (should be straight quotes)
if echo "$CONTENT" | grep -qP '[“”]'; then
    VIOLATIONS="${VIOLATIONS}\n- Curly quotes found (\"\") - should be straight quotes (\"\")"
fi

# Em-dash (should be normal dash)
if echo "$CONTENT" | grep -qP '[—–]'; then
    VIOLATIONS="${VIOLATIONS}\n- Em-dash found (--) - should be normal dash (-)"
fi

# Ellipsis character (should be three dots)
if echo "$CONTENT" | grep -qP '[…]'; then
    VIOLATIONS="${VIOLATIONS}\n- Ellipsis character found (...) - should be three dots (...)"
fi

# Smart apostrophes
if echo "$CONTENT" | grep -qP "[‘’‚]"; then
    VIOLATIONS="${VIOLATIONS}\n- Smart apostrophe found - should be straight apostrophe (')"
fi

# ============================================
# 2. Emojis in Code (only for code files)
# ============================================
case "$EXT" in
    js|ts|jsx|tsx|py|rb|go|java|php|c|cpp|h|rs|swift|kt|sh|bash)
        # Check for emojis in code files
        if echo "$CONTENT" | grep -qP '[\x{1F300}-\x{1F9FF}]|[\x{2600}-\x{26FF}]|[\x{2700}-\x{27BF}]'; then
            VIOLATIONS="${VIOLATIONS}\n- Emoji found in code file - emojis don't belong in code"
        fi
        ;;
esac

# ============================================
# 3. AI Phrases (~90% detectable)
# ============================================
# Only check in comments/docs, not in string literals
# This is heuristic - might have false positives

# Common AI phrases in comments
if echo "$CONTENT" | grep -qiE '(//|#|/\*|\*)\s*(Let me|I'"'"'ll|Sure!|Certainly!|Great question|I'"'"'d be happy)'; then
    VIOLATIONS="${VIOLATIONS}\n- AI-typical phrase found in comment (Let me/I'll/Sure!/Certainly!)"
fi

# ============================================
# 4. German Umlauts (for German text files)
# ============================================
case "$EXT" in
    md|txt|rst)
        # Check for ASCII replacements that should be umlauts
        if echo "$CONTENT" | grep -qE '\b(fuer|koennen|groesse|aehnlich|ueberpruefung|moeglich|wuerde|muessen)\b'; then
            VIOLATIONS="${VIOLATIONS}\n- ASCII instead of umlauts found (fuer->für, oe->ö) - use proper German umlauts"
        fi
        ;;
esac

# ============================================
# Output violations if found
# ============================================
if [ -n "$VIOLATIONS" ]; then
    echo ""
    echo "<dogma-validation>"
    echo "[dogma] WARNING: AI traces detected in written content!"
    echo ""
    echo "File: $FILE_PATH"
    echo ""
    echo "Issues found:"
    echo -e "$VIOLATIONS"
    echo ""
    echo "These patterns reveal AI usage. Please fix:"
    echo "- Run /dogma:cleanup"
    echo "- Or manually replace the characters"
    echo ""
    echo "See: @GUIDES/ai-traces.md"
    echo "</dogma-validation>"
fi

# PostToolUse hooks should not block (content already written)
# Just warn so Claude can fix it
exit 0

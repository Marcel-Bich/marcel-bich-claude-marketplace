#!/bin/bash
# Dogma: PostToolUse Write/Edit Hook
# Validates content AFTER it was written
# Checks for AI traces that slipped through
#
# IDEA.md Zeile 350-360:
# - PostToolUse Write/Edit: Validiert geschriebenen Content
# - AI Traces (Typografie): 100% - Pattern-Match
# - AI Traces (Phrasen): ~90% - Heuristik
#
# ENV: DOGMA_POST_WRITE_VALIDATE=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== post-write-validate.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_POST_WRITE_VALIDATE:-true}"
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
if echo "$CONTENT" | grep -qP '[""]'; then
    VIOLATIONS="${VIOLATIONS}\n- Curly quotes gefunden (\"\") - sollten gerade Quotes sein (\"\")"
fi

# Em-dash (should be normal dash)
if echo "$CONTENT" | grep -qP '[—–]'; then
    VIOLATIONS="${VIOLATIONS}\n- Em-dash gefunden (—) - sollte normaler Dash sein (-)"
fi

# Ellipsis character (should be three dots)
if echo "$CONTENT" | grep -qP '[…]'; then
    VIOLATIONS="${VIOLATIONS}\n- Ellipsis-Zeichen gefunden (...) - sollten drei Punkte sein (...)"
fi

# Smart apostrophes
if echo "$CONTENT" | grep -qP "[''‚]"; then
    VIOLATIONS="${VIOLATIONS}\n- Smart Apostrophe gefunden - sollte gerader Apostroph sein (')"
fi

# ============================================
# 2. Emojis in Code (only for code files)
# ============================================
case "$EXT" in
    js|ts|jsx|tsx|py|rb|go|java|php|c|cpp|h|rs|swift|kt|sh|bash)
        # Check for emojis in code files
        if echo "$CONTENT" | grep -qP '[\x{1F300}-\x{1F9FF}]|[\x{2600}-\x{26FF}]|[\x{2700}-\x{27BF}]'; then
            VIOLATIONS="${VIOLATIONS}\n- Emoji in Code-Datei gefunden - Emojis gehoeren nicht in Code"
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
    VIOLATIONS="${VIOLATIONS}\n- AI-typische Phrase in Kommentar gefunden (Let me/I'll/Sure!/Certainly!)"
fi

# ============================================
# 4. German Umlauts (for German text files)
# ============================================
case "$EXT" in
    md|txt|rst)
        # Check for ASCII replacements that should be umlauts
        if echo "$CONTENT" | grep -qE '\b(fuer|koennen|groesse|aehnlich|ueberpruefung|moeglich|wuerde|muessen)\b'; then
            VIOLATIONS="${VIOLATIONS}\n- ASCII statt Umlaute gefunden (fuer->fuer, oe->oe) - bitte echte Umlaute verwenden"
        fi
        ;;
esac

# ============================================
# Output violations if found
# ============================================
if [ -n "$VIOLATIONS" ]; then
    echo ""
    echo "<dogma-validation>"
    echo "WARNUNG: AI-Traces in geschriebenem Content erkannt!"
    echo ""
    echo "Datei: $FILE_PATH"
    echo ""
    echo "Gefundene Probleme:"
    echo -e "$VIOLATIONS"
    echo ""
    echo "Diese Muster verraten AI-Nutzung. Bitte korrigieren:"
    echo "- /dogma:cleanup ausfuehren"
    echo "- Oder manuell die Zeichen ersetzen"
    echo ""
    echo "Siehe: @CLAUDE/CLAUDE.git.md (ai_traces Sektion)"
    echo "</dogma-validation>"
fi

# PostToolUse hooks should not block (content already written)
# Just warn so Claude can fix it
exit 0

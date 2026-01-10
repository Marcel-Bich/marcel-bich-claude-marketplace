#!/bin/bash
# Dogma: Write/Edit Reminder Hook (PreToolUse)
# Reminds Claude of relevant rules BEFORE writing
# Uses @-references to force Claude to READ the files
#
# IDEA.md Zeile 316-335:
# "Bevor du schreibst, beachte UNBEDINGT:
#  @CLAUDE/CLAUDE.language.md
#  @CLAUDE/CLAUDE.git.md (ai_traces Sektion)"
#
# Prinzip: Immer nur die relevanten Dateien referenzieren
#
# ENV: DOGMA_WRITE_EDIT_REMINDER=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === CONFIGURATION ===
ENABLED="${DOGMA_WRITE_EDIT_REMINDER:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract the tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only process Write and Edit tools
if [ "$TOOL_NAME" != "Write" ] && [ "$TOOL_NAME" != "Edit" ]; then
    exit 0
fi

# Extract file path
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Find CLAUDE directory
CLAUDE_DIR=""
if [ -d "CLAUDE" ]; then
    CLAUDE_DIR="CLAUDE"
elif [ -d ".claude" ]; then
    CLAUDE_DIR=".claude"
fi

# If no CLAUDE directory, skip
if [ -z "$CLAUDE_DIR" ]; then
    exit 0
fi

# Build reminder with @-references
REMINDER=""
REFS=""

# Get file extension
EXT="${FILE_PATH##*.}"

# ============================================
# Determine which files to reference
# ============================================

# Language rules - for all text files
if [ -f "$CLAUDE_DIR/CLAUDE.language.md" ]; then
    REFS="$REFS@$CLAUDE_DIR/CLAUDE.language.md\n"
fi

# AI traces rules - especially for code files
if [ -f "$CLAUDE_DIR/CLAUDE.git.md" ]; then
    case "$EXT" in
        js|ts|jsx|tsx|py|rb|go|java|php|c|cpp|h|rs|swift|kt|sh|bash|md|txt)
            REFS="$REFS@$CLAUDE_DIR/CLAUDE.git.md (ai_traces Sektion)\n"
            ;;
    esac
fi

# ============================================
# Detect existing file language (if file exists)
# ============================================
LANG_NOTE=""
if [ -f "$FILE_PATH" ]; then
    FIRST_CONTENT=$(head -50 "$FILE_PATH" 2>/dev/null | tr -d '\n')

    # Simple German detection
    if echo "$FIRST_CONTENT" | grep -qiE 'der|die|das|und|ist|nicht|eine|wird|kann|haben|werden|auch|bei|aus|nach|wie|nur|oder|durch|noch|als|bis|dieser|keine|muss|sind|aber|wenn|denn|fuer|ueber|hier|heute|jetzt|schon|immer|viel'; then
        LANG_NOTE="ACHTUNG: Datei ist auf Deutsch. Behalte Deutsch bei!"
    fi

    # Simple English detection
    if echo "$FIRST_CONTENT" | grep -qiE '\bthe\b|\band\b|\bis\b|\bto\b|\bof\b|\bthat\b|\bin\b|\bfor\b|\bit\b|\bwith\b|\bas\b|\bon\b|\bthis\b|\bwill\b|\byou\b|\bhave\b|\bare\b|\bbe\b|\bbut\b|\bfrom\b|\bcan\b|\bwas\b'; then
        LANG_NOTE="NOTE: File is in English. Keep it in English!"
    fi
fi

# ============================================
# Output reminder if we have references
# ============================================
if [ -n "$REFS" ]; then
    echo ""
    echo "<dogma-reminder>"
    echo "Bevor du schreibst, beachte UNBEDINGT:"
    echo ""
    echo -e "$REFS"
    if [ -n "$LANG_NOTE" ]; then
        echo ""
        echo "$LANG_NOTE"
    fi
    echo "</dogma-reminder>"
fi

exit 0

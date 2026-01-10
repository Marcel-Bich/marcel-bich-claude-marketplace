#!/bin/bash
# Dogma: UserPromptSubmit Hook
# Runs at the START of EVERY user prompt
# Reminds Claude of rules that cannot be technically enforced
#
# IDEA.md Zeile 284-314:
# - Technisch enforceable (git, secrets) -> Nur PreToolUse (blockiert eh)
# - Teilweise enforceable (Language, AI Traces) -> Hier erinnern + PreToolUse
# - Nicht enforceable (Honesty, Planning, Philosophy) -> NUR hier erinnern!
#
# ENV: DOGMA_PROMPT_REMINDER=true (default) | false

set -e

# === CONFIGURATION ===
ENABLED="${DOGMA_PROMPT_REMINDER:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat)

# Find CLAUDE directory
CLAUDE_DIR=""
if [ -d "CLAUDE" ]; then
    CLAUDE_DIR="CLAUDE"
elif [ -d ".claude" ]; then
    CLAUDE_DIR=".claude"
fi

# If no CLAUDE directory and no CLAUDE.md, skip silently
if [ -z "$CLAUDE_DIR" ] && [ ! -f "CLAUDE.md" ]; then
    exit 0
fi

# Build reminder message
REMINDER=""

# ============================================
# 1. Git Permissions (from CLAUDE.git.md)
# ============================================
GIT_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.git.md" ]; then
    GIT_FILE="$CLAUDE_DIR/CLAUDE.git.md"
elif [ -f "CLAUDE.git.md" ]; then
    GIT_FILE="CLAUDE.git.md"
fi

if [ -n "$GIT_FILE" ]; then
    # Extract permissions section
    PERMS=$(sed -n '/<permissions>/,/<\/permissions>/p' "$GIT_FILE" 2>/dev/null | grep -E '^\s*-\s*\[' | head -5)
    if [ -n "$PERMS" ]; then
        REMINDER="${REMINDER}Git Permissions (siehe @${GIT_FILE}):\n${PERMS}\n\n"
    fi
fi

# ============================================
# 2. Language Rules (teilweise enforceable)
# ============================================
LANG_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.language.md" ]; then
    LANG_FILE="$CLAUDE_DIR/CLAUDE.language.md"
elif [ -f "CLAUDE.language.md" ]; then
    LANG_FILE="CLAUDE.language.md"
fi

if [ -n "$LANG_FILE" ]; then
    REMINDER="${REMINDER}Language: Bestehende Sprache beibehalten, deutsche Umlaute nutzen (siehe @${LANG_FILE})\n\n"
fi

# ============================================
# 3. AI Traces (teilweise enforceable)
# ============================================
if [ -n "$GIT_FILE" ]; then
    HAS_AI_TRACES=$(grep -c '<ai_traces>' "$GIT_FILE" 2>/dev/null || echo "0")
    if [ "$HAS_AI_TRACES" -gt 0 ]; then
        REMINDER="${REMINDER}AI Traces: Keine curly quotes, em-dashes, Emojis im Code, AI-Phrasen (siehe @${GIT_FILE} ai_traces)\n\n"
    fi
fi

# ============================================
# 4. Honesty Rules (NICHT enforceable - NUR hier!)
# ============================================
HONESTY_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.honesty.md" ]; then
    HONESTY_FILE="$CLAUDE_DIR/CLAUDE.honesty.md"
elif [ -f "CLAUDE.honesty.md" ]; then
    HONESTY_FILE="CLAUDE.honesty.md"
fi

if [ -n "$HONESTY_FILE" ]; then
    REMINDER="${REMINDER}Honesty: Bei Unsicherheit zugeben, nicht raten oder erfinden (siehe @${HONESTY_FILE})\n\n"
fi

# ============================================
# 5. Planning Rules (NICHT enforceable - NUR hier!)
# ============================================
PLANNING_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.planning.md" ]; then
    PLANNING_FILE="$CLAUDE_DIR/CLAUDE.planning.md"
elif [ -f "CLAUDE.planning.md" ]; then
    PLANNING_FILE="CLAUDE.planning.md"
fi

if [ -n "$PLANNING_FILE" ]; then
    REMINDER="${REMINDER}Planning: Bei komplexen Tasks erst planen, /create-plan vorschlagen (siehe @${PLANNING_FILE})\n\n"
fi

# ============================================
# 6. Philosophy Rules (NICHT enforceable - NUR hier!)
# ============================================
PHILOSOPHY_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.philosophy.md" ]; then
    PHILOSOPHY_FILE="$CLAUDE_DIR/CLAUDE.philosophy.md"
elif [ -f "CLAUDE.philosophy.md" ]; then
    PHILOSOPHY_FILE="CLAUDE.philosophy.md"
fi

if [ -n "$PHILOSOPHY_FILE" ]; then
    REMINDER="${REMINDER}Philosophy: YAGNI, KISS, keine Over-Engineering (siehe @${PHILOSOPHY_FILE})\n\n"
fi

# ============================================
# 7. File Protection (wichtige Erinnerung)
# ============================================
if [ -n "$GIT_FILE" ]; then
    HAS_PROTECTION=$(grep -c '<file_protection>\|NEVER delete' "$GIT_FILE" 2>/dev/null || echo "0")
    if [ "$HAS_PROTECTION" -gt 0 ]; then
        REMINDER="${REMINDER}File Protection: NIEMALS lokale Dateien loeschen ohne explizite User-Bestaetigung\n\n"
    fi
fi

# ============================================
# Output reminder if we have content
# ============================================
if [ -n "$REMINDER" ]; then
    echo ""
    echo "<dogma-reminder>"
    echo "Bevor du antwortest, beachte diese Regeln:"
    echo ""
    echo -e "$REMINDER"
    echo "</dogma-reminder>"
fi

exit 0

#!/bin/bash
# Dogma: UserPromptSubmit Hook
# Runs at the START of EVERY user prompt
# Reminds Claude of rules that cannot be technically enforced
#
# IDEA.md line 284-314:
# - Technically enforceable (git, secrets) -> PreToolUse only (blocks anyway)
# - Partially enforceable (Language, AI Traces) -> Remind here + PreToolUse
# - Not enforceable (Honesty, Planning, Philosophy) -> ONLY remind here!
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_PROMPT_REMINDER=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
# ENV: CLAUDE_MB_DOGMA_DEBUG=true to enable logging to /tmp/dogma-hooks.log
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== user-prompt-submit.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_PROMPT_REMINDER:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin (required by hook interface)
INPUT=$(cat 2>/dev/null || true)

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
        REMINDER="${REMINDER}Git Permissions (see @${GIT_FILE}):\n${PERMS}\n\n"
    fi
fi

# ============================================
# 2. Language Rules (partially enforceable)
# ============================================
LANG_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.language.md" ]; then
    LANG_FILE="$CLAUDE_DIR/CLAUDE.language.md"
elif [ -f "CLAUDE.language.md" ]; then
    LANG_FILE="CLAUDE.language.md"
fi

if [ -n "$LANG_FILE" ]; then
    REMINDER="${REMINDER}Language: Maintain existing language, use German umlauts (see @${LANG_FILE})\n\n"
fi

# ============================================
# 3. AI Traces (partially enforceable)
# ============================================
if [ -n "$GIT_FILE" ]; then
    HAS_AI_TRACES=$(grep -c '<ai_traces>' "$GIT_FILE" 2>/dev/null | head -1 || echo "0")
    if [ "$HAS_AI_TRACES" -gt 0 ]; then
        REMINDER="${REMINDER}AI Traces: No curly quotes, em-dashes, emojis in code, AI phrases (see @${GIT_FILE} ai_traces)\n\n"
    fi
fi

# ============================================
# 4. Honesty Rules (NOT enforceable - ONLY here!)
# ============================================
HONESTY_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.honesty.md" ]; then
    HONESTY_FILE="$CLAUDE_DIR/CLAUDE.honesty.md"
elif [ -f "CLAUDE.honesty.md" ]; then
    HONESTY_FILE="CLAUDE.honesty.md"
fi

if [ -n "$HONESTY_FILE" ]; then
    REMINDER="${REMINDER}Honesty: Admit uncertainty, don't guess or fabricate (see @${HONESTY_FILE})\n\n"
fi

# ============================================
# 5. Planning Rules (NOT enforceable - ONLY here!)
# ============================================
PLANNING_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.planning.md" ]; then
    PLANNING_FILE="$CLAUDE_DIR/CLAUDE.planning.md"
elif [ -f "CLAUDE.planning.md" ]; then
    PLANNING_FILE="CLAUDE.planning.md"
fi

if [ -n "$PLANNING_FILE" ]; then
    REMINDER="${REMINDER}Planning: Plan complex tasks first, suggest /create-plan (see @${PLANNING_FILE})\n\n"
fi

# ============================================
# 6. Philosophy Rules (NOT enforceable - ONLY here!)
# ============================================
PHILOSOPHY_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.philosophy.md" ]; then
    PHILOSOPHY_FILE="$CLAUDE_DIR/CLAUDE.philosophy.md"
elif [ -f "CLAUDE.philosophy.md" ]; then
    PHILOSOPHY_FILE="CLAUDE.philosophy.md"
fi

if [ -n "$PHILOSOPHY_FILE" ]; then
    REMINDER="${REMINDER}Philosophy: YAGNI, KISS, no over-engineering (see @${PHILOSOPHY_FILE})\n\n"
fi

# ============================================
# 7. Versioning Rules (NOT enforceable - ONLY here!)
# ============================================
VERSIONING_FILE=""
if [ -f "$CLAUDE_DIR/CLAUDE.versioning.md" ]; then
    VERSIONING_FILE="$CLAUDE_DIR/CLAUDE.versioning.md"
elif [ -f "CLAUDE.versioning.md" ]; then
    VERSIONING_FILE="CLAUDE.versioning.md"
fi

if [ -n "$VERSIONING_FILE" ]; then
    REMINDER="${REMINDER}Versioning: Bump version on changes, use commit prefix vX.Y.Z: (see @${VERSIONING_FILE})\n\n"
fi

# ============================================
# 8. File Protection (important reminder)
# ============================================
if [ -n "$GIT_FILE" ]; then
    HAS_PROTECTION=$(grep -cE '<file_protection>|NEVER delete' "$GIT_FILE" 2>/dev/null | head -1 || echo "0")
    if [ "$HAS_PROTECTION" -gt 0 ]; then
        REMINDER="${REMINDER}File Protection: NEVER delete local files without explicit user confirmation\n\n"
    fi
fi

# ============================================
# Output reminder if we have content
# ============================================
if [ -n "$REMINDER" ]; then
    echo ""
    echo "<dogma-reminder>"
    echo "Before responding, follow these rules:"
    echo ""
    echo -e "$REMINDER"
    echo "</dogma-reminder>"
fi

# Debug end marker
if [ "$DEBUG" = "true" ]; then
    echo "=== user-prompt-submit.sh END ===" >&2
fi
exit 0

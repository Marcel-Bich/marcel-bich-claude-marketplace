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
# ENV: DOGMA_PROMPT_REMINDER=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
# ENV: DOGMA_DEBUG=true to enable logging to /tmp/dogma-hooks.log
DEBUG="${DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== user-prompt-submit.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_PROMPT_REMINDER:-true}"
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

# ============================================
# 9. Checklist Tracking (IDEA.md Zeile 301-335)
# ============================================
# ENV: DOGMA_CHECKLIST_TRACKING=true (default) | false

CHECKLIST_ENABLED="${DOGMA_CHECKLIST_TRACKING:-true}"
if [ "$CHECKLIST_ENABLED" = "true" ]; then
    OPEN_CHECKLISTS=""
    TOTAL_OPEN=0

    # Scan specific files (no arrays for compatibility)
    for FILE in PLAN.md TODO.md ROADMAP.md README.md TO-DOS.md; do
        if [ -f "$FILE" ]; then
            COUNT=$(grep -cE '^\s*[-*]\s*\[ \]' "$FILE" 2>/dev/null | head -1 || echo "0")
            if [ "$COUNT" -gt 0 ] 2>/dev/null; then
                OPEN_CHECKLISTS="${OPEN_CHECKLISTS}\n- $FILE ($COUNT open)"
                TOTAL_OPEN=$((TOTAL_OPEN + COUNT))
            fi
        fi
    done

    # Scan directories (simplified, no process substitution)
    for DIR in docs .claude; do
        if [ -d "$DIR" ]; then
            for FILE in "$DIR"/*.md; do
                if [ -f "$FILE" ]; then
                    COUNT=$(grep -cE '^\s*[-*]\s*\[ \]' "$FILE" 2>/dev/null | head -1 || echo "0")
                    if [ "$COUNT" -gt 0 ] 2>/dev/null; then
                        OPEN_CHECKLISTS="${OPEN_CHECKLISTS}\n- $FILE ($COUNT open)"
                        TOTAL_OPEN=$((TOTAL_OPEN + COUNT))
                    fi
                fi
            done
        fi
    done

    # Output checklist reminder if found
    if [ "$TOTAL_OPEN" -gt 0 ] 2>/dev/null; then
        echo ""
        echo "<dogma-checklist-tracking>"
        echo "Open checklists found ($TOTAL_OPEN tasks):"
        echo -e "$OPEN_CHECKLISTS"
        echo ""
        echo "When you complete a task from these lists:"
        echo "1. Ask the user: \"Task 'X' seems complete. Mark as done? [Y/n]\""
        echo "2. Only mark as done after explicit user confirmation"
        echo "3. Never silently check off tasks"
        echo "</dogma-checklist-tracking>"
    fi
fi

# Debug end marker
if [ "$DEBUG" = "true" ]; then
    echo "=== user-prompt-submit.sh END ===" >&2
fi
exit 0

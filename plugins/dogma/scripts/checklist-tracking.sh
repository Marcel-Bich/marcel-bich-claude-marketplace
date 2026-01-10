#!/bin/bash
# Dogma: Checklist Tracking Hook (UserPromptSubmit)
# Scans MD files for open checklists and reminds Claude
#
# IDEA.md line 301-335:
# - Scan MD files for open checklists
# - Inject reminder: "Open checklists: PLAN.md (3 Tasks)"
# - Agent asks interactively whether to check off
#
# Scan-Locations:
# - PLAN.md, TODO.md, ROADMAP.md, README.md
# - docs/**/*.md
# - .claude/*.md
#
# ENV: DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: DOGMA_CHECKLIST_TRACKING=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== checklist-tracking.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
if [ "${DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_CHECKLIST_TRACKING:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# ============================================
# Scan for open checklist items
# ============================================

OPEN_CHECKLISTS=""
TOTAL_OPEN=0

# Scan specific files (no arrays for compatibility)
for FILE in PLAN.md TODO.md ROADMAP.md README.md TO-DOS.md; do
    if [ -f "$FILE" ]; then
        # Count open checkboxes: - [ ] or * [ ]
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

# ============================================
# Output reminder if open checklists found
# ============================================

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

exit 0

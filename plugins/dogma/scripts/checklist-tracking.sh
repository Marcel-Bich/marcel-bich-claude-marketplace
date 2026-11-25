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
# - Root: PLAN.md, TODO.md, ROADMAP.md, README.md, TO-DOS.md, BRIEF.md, MILESTONES.md, whats-next.md
# - docs/*.md, .claude/*.md, .planning/*.md
# - .planning/phases/*/*.md (for taches-cc-resources create-plans)
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_CHECKLIST_TRACKING=true (default) | false
# ENV: CLAUDE_MB_DOGMA_CREDO_DEFER=true (default) | false - credo-aware wording (lib-credo.sh)

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== checklist-tracking.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_CHECKLIST_TRACKING:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin (session id for lib-credo.sh and lib-notify.sh)
INPUT=$(cat 2>/dev/null || true)

# Repeat subagent notification (#215, lib-notify.sh): no dogma inject at all.
# shellcheck source=lib-notify.sh
if command -v jq >/dev/null 2>&1 && source "$(dirname "${BASH_SOURCE[0]}")/lib-notify.sh" 2>/dev/null \
    && dogma_notify_repeat "$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)" \
        "$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)"; then
    exit 0
fi

# ============================================
# Scan for open checklist items
# ============================================

OPEN_CHECKLISTS=""
TOTAL_OPEN=0

# Scan specific files in root (no arrays for compatibility)
for FILE in PLAN.md TODO.md ROADMAP.md README.md TO-DOS.md BRIEF.md MILESTONES.md whats-next.md TO-DELETE.md; do
    if [ -f "$FILE" ]; then
        # Count open checkboxes: - [ ] or * [ ]
        COUNT=$(grep -cE '^\s*[-*]\s*\[ \]' "$FILE" 2>/dev/null | head -1 || echo "0")
        if [ "$COUNT" -gt 0 ] 2>/dev/null; then
            OPEN_CHECKLISTS="${OPEN_CHECKLISTS}\n- $FILE ($COUNT open)"
            TOTAL_OPEN=$((TOTAL_OPEN + COUNT))
        fi
    fi
done

# Scan directories (first level)
for DIR in docs .claude .planning; do
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

# Scan .planning/phases/ subdirectories (for create-plans skill)
if [ -d ".planning/phases" ]; then
    for PHASE_DIR in .planning/phases/*/; do
        if [ -d "$PHASE_DIR" ]; then
            for FILE in "$PHASE_DIR"*.md; do
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
fi

# ============================================
# Output reminder if open checklists found
# ============================================

if [ "$TOTAL_OPEN" -gt 0 ] 2>/dev/null; then
    # credo active for this session (lib-credo.sh): credo's dd / done gate confirms.
    CREDO_ACTIVE="false"
    # shellcheck source=lib-credo.sh
    if source "$(dirname "${BASH_SOURCE[0]}")/lib-credo.sh" 2>/dev/null && dogma_credo_active "$INPUT"; then
        CREDO_ACTIVE="true"
    fi
    echo ""
    echo "<dogma-checklist-tracking>"
    echo "Open checklists found ($TOTAL_OPEN tasks):"
    echo -e "$OPEN_CHECKLISTS"
    echo ""
    if [ "$CREDO_ACTIVE" = "true" ]; then
    echo "credo is active: when you complete a task from these lists, an explicit 'dd' from"
    echo "the user or a passed credo done gate counts as the confirmation to check it off."
    if [ "$DOGMA_CREDO_MODE" = "autonomous" ]; then
    echo "Autonomous mode: never ask; note the candidate in your report instead."
    else
    echo "Without either, ask the user before checking it off."
    fi
    echo "Never silently check off tasks."
    else
    echo "When you complete a task from these lists:"
    echo "1. Ask the user: \"Task 'X' seems complete. Mark as done? [Y/n]\""
    echo "2. Only mark as done after explicit user confirmation"
    echo "3. Never silently check off tasks"
    fi
    echo "</dogma-checklist-tracking>"
fi

exit 0

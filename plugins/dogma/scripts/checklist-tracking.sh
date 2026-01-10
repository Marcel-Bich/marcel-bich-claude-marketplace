#!/bin/bash
# Dogma: Checklist Tracking Hook (UserPromptSubmit)
# Scans MD files for open checklists and reminds Claude
#
# IDEA.md Zeile 301-335:
# - Scan MD-Dateien nach offenen Checklisten
# - Reminder injizieren: "Offene Checklisten: PLAN.md (3 Tasks)"
# - Agent fragt interaktiv ob abhaken
#
# Scan-Locations:
# - PLAN.md, TODO.md, ROADMAP.md, README.md
# - docs/**/*.md
# - .claude/*.md
#
# ENV: DOGMA_CHECKLIST_TRACKING=true (default) | false

set -e

# === CONFIGURATION ===
ENABLED="${DOGMA_CHECKLIST_TRACKING:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Files to scan for checklists
SCAN_FILES=(
    "PLAN.md"
    "TODO.md"
    "ROADMAP.md"
    "README.md"
    "TO-DOS.md"
)

# Directories to scan (if they exist)
SCAN_DIRS=(
    "docs"
    ".claude"
)

# ============================================
# Scan for open checklist items
# ============================================

OPEN_CHECKLISTS=""
TOTAL_OPEN=0

# Scan specific files
for FILE in "${SCAN_FILES[@]}"; do
    if [ -f "$FILE" ]; then
        # Count open checkboxes: - [ ] or * [ ]
        COUNT=$(grep -cE '^\s*[-*]\s*\[ \]' "$FILE" 2>/dev/null || echo "0")
        if [ "$COUNT" -gt 0 ]; then
            OPEN_CHECKLISTS="${OPEN_CHECKLISTS}\n- $FILE ($COUNT open)"
            TOTAL_OPEN=$((TOTAL_OPEN + COUNT))
        fi
    fi
done

# Scan directories
for DIR in "${SCAN_DIRS[@]}"; do
    if [ -d "$DIR" ]; then
        # Find all .md files in directory
        while IFS= read -r FILE; do
            if [ -f "$FILE" ]; then
                COUNT=$(grep -cE '^\s*[-*]\s*\[ \]' "$FILE" 2>/dev/null || echo "0")
                if [ "$COUNT" -gt 0 ]; then
                    OPEN_CHECKLISTS="${OPEN_CHECKLISTS}\n- $FILE ($COUNT open)"
                    TOTAL_OPEN=$((TOTAL_OPEN + COUNT))
                fi
            fi
        done < <(find "$DIR" -name "*.md" -type f 2>/dev/null)
    fi
done

# ============================================
# Output reminder if open checklists found
# ============================================

if [ "$TOTAL_OPEN" -gt 0 ]; then
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

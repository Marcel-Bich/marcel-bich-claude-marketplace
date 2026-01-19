#!/bin/bash
# Dogma: Stop Hook - Checklist Reminder
# Reminds user about checklist-manager subagent when checklists exist in project
#
# ENV: CLAUDE_MB_DOGMA_CHECKLIST_REMINDER=true (default) | false

trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== checklist-reminder.sh START $(date) ===" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === FEATURE TOGGLE (default: on) ===
if [ "${CLAUDE_MB_DOGMA_CHECKLIST_REMINDER:-true}" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin (not used but consumed)
INPUT=$(cat 2>/dev/null || true)

# === CHECK FOR CHECKLIST FILES ===
# Look for files containing unchecked items [ ] - fast grep check
# Exclude common directories and binary files
if ! grep -rlq --include="*.md" --include="*.txt" --include="*.todo" '\[ \]' . 2>/dev/null; then
    exit 0
fi

# === OUTPUT REMINDER ===
echo ""
echo "<dogma-checklist-reminder>"
echo "Session ending. Checklists found in project."
echo ""
echo "Consider: Spawn checklist-manager agent to scan and update checklists."
echo ""
echo "Use: Task tool with subagent_type=\"dogma:checklist-manager\""
echo "</dogma-checklist-reminder>"

exit 0

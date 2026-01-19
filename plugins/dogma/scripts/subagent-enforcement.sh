#!/bin/bash
# Dogma: Subagent-First Pattern Enforcement Hook
# Warns when main agent works directly instead of delegating to subagents
#
# Checks DOGMA-PERMISSIONS.md workflow settings:
# - [x] use Hydra for 2+ independent tasks -> warn if no Task/Hydra tool
# - [x] spawn subagent for verification -> warn if no subagent for verification
#
# This hook warns but does NOT block, as subagent usage is sometimes optional.
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch
# ENV: CLAUDE_MB_DOGMA_SUBAGENT_ENFORCEMENT=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
trap 'exit 0' ERR

# Load shared permissions library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-permissions.sh"

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== subagent-enforcement.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_SUBAGENT_ENFORCEMENT:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# === HYDRA WORKTREE CHECK ===
# Agents in worktrees ARE subagents - they should work freely
if is_hydra_worktree; then
    dogma_debug_log "In hydra worktree - subagent, skip enforcement"
    exit 0
fi

# Get tool name - prefer argument (passed from hooks.json) over stdin
# This avoids consuming stdin that other hooks need!
if [ -n "$1" ]; then
    TOOL_NAME="$1"
    dogma_debug_log "Tool from arg: $TOOL_NAME"
else
    # Fallback: read from stdin (but this consumes it for other hooks)
    INPUT=$(cat 2>/dev/null || true)
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    dogma_debug_log "Tool from stdin: $TOOL_NAME"
fi

# Find permissions file
PERMS_FILE=$(find_permissions_file)
if [ -z "$PERMS_FILE" ]; then
    dogma_debug_log "No permissions file found - skip enforcement"
    exit 0
fi

# Read permissions file content (for pattern matching)
PERMS_CONTENT=$(cat "$PERMS_FILE" 2>/dev/null || true)

# === CHECK HYDRA PERMISSION ===
# Pattern: [x] use Hydra for 2+ independent tasks
HYDRA_ENABLED="false"
if echo "$PERMS_CONTENT" | grep -qiE '^\s*-\s*\[x\].*use Hydra.*2\+.*independent'; then
    HYDRA_ENABLED="true"
    dogma_debug_log "Hydra enforcement enabled"
fi

# === CHECK SUBAGENT FALLBACK PERMISSION ===
# Pattern: [x] spawn subagent for verification
SUBAGENT_FALLBACK_ENABLED="false"
if echo "$PERMS_CONTENT" | grep -qiE '^\s*-\s*\[x\].*spawn subagent.*verification'; then
    SUBAGENT_FALLBACK_ENABLED="true"
    dogma_debug_log "Subagent fallback enforcement enabled"
fi

# Exit early if neither permission is set
if [ "$HYDRA_ENABLED" != "true" ] && [ "$SUBAGENT_FALLBACK_ENABLED" != "true" ]; then
    dogma_debug_log "No subagent enforcement permissions set"
    exit 0
fi

# === STATE FILE FOR TRACKING ===
# Track what's happening in this session
STATE_DIR="/tmp/dogma-subagent-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/$(pwd | md5sum | cut -d' ' -f1)"

# Helper: Track tool usage
track_tool() {
    local tool="$1"
    echo "$tool" >> "$STATE_FILE" 2>/dev/null || true
}

# Helper: Check if tool was used in session
was_tool_used() {
    local tool="$1"
    grep -qF "$tool" "$STATE_FILE" 2>/dev/null
}

# Helper: Count direct work tools (Write, Edit, Bash)
count_direct_work() {
    grep -cE '^(Write|Edit|Bash)$' "$STATE_FILE" 2>/dev/null || echo "0"
}

# === OUTPUT WARNING (not blocking) ===
# Use JSON format that Claude Code understands for PreToolUse hooks
output_warning() {
    local message="$1"
    # Escape message for JSON (replace newlines with \n, escape quotes)
    local escaped_message=$(echo "$message" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"<dogma-subagent-warning>\\n${escaped_message}\\n</dogma-subagent-warning>"}}
EOF
}

# === TRACK CURRENT TOOL ===
track_tool "$TOOL_NAME"

# === SUBAGENT TOOLS ===
# These are tools that indicate proper delegation
SUBAGENT_TOOLS="Task|Skill|hydra"

# === LOGIC: HYDRA CHECK ===
# If Hydra is enabled and we see multiple direct work operations without Task/Hydra
if [ "$HYDRA_ENABLED" = "true" ]; then
    DIRECT_COUNT=$(count_direct_work)

    # After first direct operation without Task/Skill, remind about subagent-first
    if [ "$DIRECT_COUNT" -ge 1 ]; then
        if ! was_tool_used "Task" && ! was_tool_used "Skill"; then
            # Only warn once per session
            if [ ! -f "$STATE_FILE.hydra-warned" ]; then
                touch "$STATE_FILE.hydra-warned" 2>/dev/null || true
                output_warning "Subagent-First Reminder: Direkte Operation ohne Subagent.

Vor JEDER Aktion pruefen (siehe @CLAUDE/CLAUDE.subagents.md):
1. Braucht das User-Interaktion? -> Main Agent OK
2. Gibt es einen spezialisierten Agent? -> Nutzen!
3. Kein passender Agent? -> general-purpose Subagent

Bei 2+ unabhaengigen Tasks: /hydra:parallel nutzen

Falls bewusst direkt: Warnung ignorieren."
            fi
        fi
    fi
fi

# === LOGIC: SUBAGENT FALLBACK CHECK ===
# If subagent fallback enabled and we're about to do verification-like work
if [ "$SUBAGENT_FALLBACK_ENABLED" = "true" ]; then
    # Check if this looks like verification work (test-related commands)
    if [ "$TOOL_NAME" = "Bash" ]; then
        COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // empty')

        # Detect test/build/lint commands
        if echo "$COMMAND" | grep -qiE '(npm\s+(test|run\s+test)|yarn\s+test|pnpm\s+test|vitest|jest|mocha|pytest|cargo\s+test|go\s+test|make\s+test)'; then
            # Check if we have tests in project
            TESTS_EXIST="false"
            if [ -d "tests" ] || [ -d "test" ] || [ -d "__tests__" ] || [ -d "spec" ]; then
                TESTS_EXIST="true"
            fi
            if ls *.test.* *.spec.* 2>/dev/null | head -1 >/dev/null 2>&1; then
                TESTS_EXIST="true"
            fi

            # If no tests exist, suggest subagent for verification
            if [ "$TESTS_EXIST" != "true" ]; then
                if ! was_tool_used "Task"; then
                    # Only warn once per session
                    if [ ! -f "$STATE_FILE.fallback-warned" ]; then
                        touch "$STATE_FILE.fallback-warned" 2>/dev/null || true
                        output_warning "Subagent-Fallback: Keine Tests gefunden, aber Verifikation laeuft.

DOGMA-PERMISSIONS.md sagt: [x] spawn subagent for verification (wenn keine Tests)

Empfehlung:
- Task Tool mit code-reviewer spawnen
- Oder silent-failure-hunter fuer Fehlersuche
- Oder manuell verifizieren und bestaetigen

Falls bewusst ohne Subagent: Warnung ignorieren."
                    fi
                fi
            fi
        fi
    fi
fi

dogma_debug_log "=== subagent-enforcement.sh END ==="
exit 0

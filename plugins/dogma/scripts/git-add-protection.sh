#!/bin/bash
# Dogma: Git Add Protection Hook
# Blocks git add for:
# 1. Files in .git/info/exclude (AI/agent files)
# 2. Secret files (.env, *.pem, *credentials*)
#
# IDEA.md line 164-182 (AI files) and 391-403 (Secret files)
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_GIT_ADD_PROTECTION=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === JSON OUTPUT FOR BLOCKING ===
# Claude Code expects JSON with permissionDecision
# Using "deny" - secrets and AI files must NEVER be committed
output_block() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== git-add-protection.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
# CLAUDE_MB_DOGMA_ENABLED=false disables ALL dogma hooks at once
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_GIT_ADD_PROTECTION:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin
INPUT=$(cat 2>/dev/null || true)

# Extract the command being run
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only process Bash tool calls
if [ "$TOOL_NAME" != "Bash" ]; then
    exit 0
fi

# ============================================
# Part 1: Check for git add commands
# ============================================
if ! echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)git\s+add\s'; then
    # Also check for git commit -a (adds all modified files including secrets)
    if echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\||\$\(|\(|`)git\s+commit\s.*-a'; then
        # Check if .env exists and is modified
        if [ -f ".env" ]; then
            if git status --porcelain .env 2>/dev/null | grep -q '^.M\|^M'; then
                output_block "BLOCKED by dogma: git commit -a would include .env! .env may contain secrets. Use git add <specific-files> without .env, then git commit."
            fi
        fi
    fi
    exit 0
fi

# Note: -f flag is NOT a bypass for Claude
# Both AI files and secret files can NEVER be added by Claude
# User must always run git add manually for these files

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    exit 0
fi

# Extract file paths from git add command
# Stop at && ; | to handle chained commands like "git add file && git commit"
GIT_ADD_PART=$(echo "$TOOL_INPUT" | sed 's/\s*&&.*//; s/\s*;.*//; s/\s*|.*//')
FILES=$(echo "$GIT_ADD_PART" | sed 's/^git\s\+add\s\+//' | tr ' ' '\n' | grep -v '^-')

BLOCKED_AI_FILES=""
BLOCKED_SECRET_FILES=""

# ============================================
# Part 2: Secret File Patterns (IDEA.md 391-403)
# ============================================
SECRET_PATTERNS=(
    ".env"
    ".env.local"
    ".env.production"
    ".env.development"
    "*.pem"
    "*.key"
    "*.p12"
    "*.pfx"
    "*credentials*"
    "*secret*"
    "*.secrets"
    "id_rsa"
    "id_ed25519"
    "id_ecdsa"
)

is_secret_file() {
    local FILE="$1"
    local BASENAME=$(basename "$FILE")
    local EXT="${BASENAME##*.}"

    # Skip script files - they contain code, not secrets
    case "$EXT" in
        sh|bash|py|js|ts|rb|go|rs|java|php|pl)
            return 1
            ;;
    esac

    for PATTERN in "${SECRET_PATTERNS[@]}"; do
        # Convert glob to regex
        local REGEX=$(echo "$PATTERN" | sed 's/\./\\./g' | sed 's/\*/.*/g')
        if echo "$BASENAME" | grep -qiE "^${REGEX}$"; then
            return 0
        fi
        # Also check full path for patterns like .env
        if echo "$FILE" | grep -qiE "(^|/)${REGEX}$"; then
            return 0
        fi
    done
    return 1
}

# ============================================
# Part 3: Check each file
# ============================================
EXCLUDE_FILE=".git/info/exclude"

# Helper: Check if file is ignored by .git/info/exclude (not .gitignore)
# Uses git check-ignore -v which shows the source of the ignore rule
is_excluded_file() {
    local FILE="$1"
    # git check-ignore -v outputs: <source>:<line>:<pattern>\t<file>
    # We only want to block files ignored by .git/info/exclude, not .gitignore
    local RESULT
    RESULT=$(git check-ignore -v "$FILE" 2>/dev/null) || return 1
    # Check if the ignore comes from .git/info/exclude
    if echo "$RESULT" | grep -q "^\.git/info/exclude:"; then
        return 0
    fi
    return 1
}

for FILE in $FILES; do
    # Handle git add . or git add -A
    if [ "$FILE" = "." ] || [ "$FILE" = "-A" ] || [ "$FILE" = "--all" ]; then
        # Check all untracked and modified files
        ALL_FILES=$(git status --porcelain 2>/dev/null | awk '{print $2}')
        for AF in $ALL_FILES; do
            # Check for secret files
            if is_secret_file "$AF"; then
                BLOCKED_SECRET_FILES="$BLOCKED_SECRET_FILES $AF"
            fi
            # Check for AI files in .git/info/exclude
            if is_excluded_file "$AF"; then
                BLOCKED_AI_FILES="$BLOCKED_AI_FILES $AF"
            fi
        done
        continue
    fi

    # Skip if file doesn't exist
    if [ ! -e "$FILE" ]; then
        continue
    fi

    # Check for secret files (always block, even if tracked)
    if is_secret_file "$FILE"; then
        BLOCKED_SECRET_FILES="$BLOCKED_SECRET_FILES $FILE"
        continue
    fi

    # Check for AI files (only if untracked and in .git/info/exclude)
    # Check if file is already tracked
    if ! git ls-files --error-unmatch "$FILE" &>/dev/null; then
        # File is untracked - check if it's in .git/info/exclude
        if is_excluded_file "$FILE"; then
            BLOCKED_AI_FILES="$BLOCKED_AI_FILES $FILE"
        fi
    fi
done

# ============================================
# Part 4: Output blocking messages
# ============================================

# Block AI files - Claude can NEVER add these
if [ -n "$BLOCKED_AI_FILES" ]; then
    FILES_LIST=$(echo $BLOCKED_AI_FILES | tr ' ' ', ')
    output_block "BLOCKED by dogma: AI files in .git/info/exclude ($FILES_LIST). These files reveal AI usage. Claude cannot add these - user must run git add manually."
fi

# Block secret files - Claude can NEVER add these
if [ -n "$BLOCKED_SECRET_FILES" ]; then
    FILES_LIST=$(echo $BLOCKED_SECRET_FILES | tr ' ' ', ')
    output_block "BLOCKED by dogma: Secret files detected ($FILES_LIST). Claude cannot add secrets - user must run git add manually if really intended."
fi

exit 0

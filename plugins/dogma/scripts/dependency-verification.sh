#!/bin/bash
# Dogma: Dependency Verification Hook
# Asks user if they want to search for security risks before installing packages
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_DEPENDENCY_VERIFICATION=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === JSON OUTPUT FOR ASKING ===
# Claude Code expects JSON with permissionDecision
# Using "ask" prompts user to confirm
output_ask() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== dependency-verification.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_DEPENDENCY_VERIFICATION:-true}"
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

# Check for package installation commands
# Pattern matches at start OR after && or ; or || (chained commands)
PACKAGE_MANAGER=""
PACKAGES=""

# npm install <package> (not just npm install without args)
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*)npm\s+(install|i|add)\s+[^-]'; then
    PACKAGE_MANAGER="npm"
    # Extract packages from the npm install part of the command
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'npm\s+(install|i|add)\s+[^;&]+' | sed -E 's/npm\s+(install|i|add)\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# yarn add <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*)yarn\s+add\s+[^-]'; then
    PACKAGE_MANAGER="yarn"
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'yarn\s+add\s+[^;&]+' | sed 's/yarn\s\+add\s\+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# pnpm add <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*)pnpm\s+(add|install)\s+[^-]'; then
    PACKAGE_MANAGER="pnpm"
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'pnpm\s+(add|install)\s+[^;&]+' | sed -E 's/pnpm\s+(add|install)\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# pip install <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*)pip[3]?\s+install\s+[^-]'; then
    PACKAGE_MANAGER="pip"
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'pip[3]?\s+install\s+[^;&]+' | sed -E 's/pip[3]?\s+install\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# cargo add <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*)cargo\s+add\s+'; then
    PACKAGE_MANAGER="cargo"
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'cargo\s+add\s+[^;&]+' | sed 's/cargo\s\+add\s\+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# If no package manager detected or no packages, exit
if [ -z "$PACKAGE_MANAGER" ] || [ -z "$(echo "$PACKAGES" | tr -d '[:space:]')" ]; then
    exit 0
fi

# ============================================
# BLOCK and require verification
# ============================================
PKG_LIST=$(echo "$PACKAGES" | tr '\n' ' ' | sed 's/  */ /g')

output_ask "Dogma: Installing packages: $PKG_LIST ($PACKAGE_MANAGER). Ask the user: Would you like me to search the web for security risks or vulnerabilities for these packages (including specific versions) before installing? Recent npm supply chain attacks often target specific versions. If yes, use WebSearch to check each package and version."

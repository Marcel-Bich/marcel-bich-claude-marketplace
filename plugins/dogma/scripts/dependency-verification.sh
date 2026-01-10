#!/bin/bash
# Dogma: Dependency Verification Hook
# BLOCKS package installations until verified
#
# IDEA.md Zeile 381-388:
# - BLOCKIEREN bis geprueft
# - PFLICHT: WebFetch zu socket.dev/snyk fuer Vulnerabilities
# - Kein Install ohne vorherige Pruefung - das ist das Wichtigste!
#
# ENV: DOGMA_DEPENDENCY_VERIFICATION=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# === JSON OUTPUT FOR BLOCKING ===
# Claude Code expects JSON with permissionDecision for proper blocking
output_deny() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
    exit 0
}

# === DEBUG MODE ===
DEBUG="${DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== dependency-verification.sh START $(date) ===" >&2
    echo "PWD: $(pwd)" >&2
fi

# === CONFIGURATION ===
ENABLED="${DOGMA_DEPENDENCY_VERIFICATION:-true}"
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
PACKAGE_MANAGER=""
PACKAGES=""

# npm install <package> (not just npm install without args)
if echo "$TOOL_INPUT" | grep -qE '^npm\s+(install|i|add)\s+[^-]'; then
    PACKAGE_MANAGER="npm"
    PACKAGES=$(echo "$TOOL_INPUT" | sed -E 's/^npm\s+(install|i|add)\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# yarn add <package>
if echo "$TOOL_INPUT" | grep -qE '^yarn\s+add\s+[^-]'; then
    PACKAGE_MANAGER="yarn"
    PACKAGES=$(echo "$TOOL_INPUT" | sed 's/^yarn\s\+add\s\+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# pnpm add <package>
if echo "$TOOL_INPUT" | grep -qE '^pnpm\s+(add|install)\s+[^-]'; then
    PACKAGE_MANAGER="pnpm"
    PACKAGES=$(echo "$TOOL_INPUT" | sed -E 's/^pnpm\s+(add|install)\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# pip install <package>
if echo "$TOOL_INPUT" | grep -qE '^pip[3]?\s+install\s+[^-]'; then
    PACKAGE_MANAGER="pip"
    PACKAGES=$(echo "$TOOL_INPUT" | sed -E 's/^pip[3]?\s+install\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# cargo add <package>
if echo "$TOOL_INPUT" | grep -qE '^cargo\s+add\s+'; then
    PACKAGE_MANAGER="cargo"
    PACKAGES=$(echo "$TOOL_INPUT" | sed 's/^cargo\s\+add\s\+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# If no package manager detected or no packages, exit
if [ -z "$PACKAGE_MANAGER" ] || [ -z "$(echo "$PACKAGES" | tr -d '[:space:]')" ]; then
    exit 0
fi

# ============================================
# BLOCK and require verification
# ============================================
PKG_LIST=$(echo "$PACKAGES" | tr '\n' ' ' | sed 's/  */ /g')

# Build verification URLs based on package manager
VERIFY_URLS=""
for PKG in $PACKAGES; do
    CLEAN_PKG=$(echo "$PKG" | sed 's/@.*//' | sed 's/\^.*//' | sed 's/~.*//')
    case "$PACKAGE_MANAGER" in
        npm|yarn|pnpm)
            VERIFY_URLS="$VERIFY_URLS socket.dev/npm/package/$CLEAN_PKG"
            ;;
        pip)
            VERIFY_URLS="$VERIFY_URLS snyk.io/advisor/python/$CLEAN_PKG"
            ;;
        cargo)
            VERIFY_URLS="$VERIFY_URLS crates.io/crates/$CLEAN_PKG"
            ;;
    esac
done
VERIFY_URLS=$(echo "$VERIFY_URLS" | tr ' ' ', ')

output_deny "BLOCKED by dogma: Dependency verification required. Packages: $PKG_LIST ($PACKAGE_MANAGER). FIRST use WebFetch to verify: $VERIFY_URLS - Check for typosquatting, malware, vulnerabilities before installing."

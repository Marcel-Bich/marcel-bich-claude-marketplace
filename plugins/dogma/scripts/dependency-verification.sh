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
echo ""
echo "BLOCKED by dogma: dependency verification required"
echo ""
echo "Package Manager: $PACKAGE_MANAGER"
echo "Pakete: $(echo "$PACKAGES" | tr '\n' ' ')"
echo ""
echo "============================================"
echo "PFLICHT: Pakete VOR Installation pruefen!"
echo "============================================"
echo ""
echo "Bevor du installierst, MUSST du:"
echo ""

for PKG in $PACKAGES; do
    # Skip scoped packages display differently
    CLEAN_PKG=$(echo "$PKG" | sed 's/@.*//' | sed 's/\^.*//' | sed 's/~.*//')

    case "$PACKAGE_MANAGER" in
        npm|yarn|pnpm)
            echo "1. WebFetch: https://socket.dev/npm/package/$CLEAN_PKG"
            echo "   -> Pruefe auf Typosquatting, Malware, Vulnerabilities"
            echo ""
            echo "2. Oder WebFetch: https://snyk.io/advisor/npm-package/$CLEAN_PKG"
            echo "   -> Pruefe Security Score und bekannte Schwachstellen"
            echo ""
            echo "3. Oder WebFetch: https://www.npmjs.com/package/$CLEAN_PKG"
            echo "   -> Pruefe Downloads, Maintainer, Last Update"
            ;;
        pip)
            echo "1. WebFetch: https://snyk.io/advisor/python/$CLEAN_PKG"
            echo "   -> Pruefe Security Score und bekannte Schwachstellen"
            echo ""
            echo "2. Oder WebFetch: https://pypi.org/project/$CLEAN_PKG/"
            echo "   -> Pruefe Downloads, Maintainer, Last Update"
            ;;
        cargo)
            echo "1. WebFetch: https://crates.io/crates/$CLEAN_PKG"
            echo "   -> Pruefe Downloads, Maintainer, Last Update"
            ;;
    esac
done

echo ""
echo "============================================"
echo "Worauf achten:"
echo "============================================"
echo "- Typosquatting: Ist der Name korrekt geschrieben?"
echo "- Downloads: Wenige Downloads = verdaechtig"
echo "- Alter: Sehr neues Paket = vorsichtig sein"
echo "- Maintainer: Bekannter/vertrauenswuerdiger Autor?"
echo "- Vulnerabilities: Bekannte Sicherheitsprobleme?"
echo ""
echo "============================================"
echo "Nach der Pruefung:"
echo "============================================"
echo "Wenn das Paket sicher erscheint, fuehre den Install erneut aus."
echo "Claude wird dann fragen ob du geprueft hast."
echo ""
echo "Siehe: @CLAUDE/CLAUDE.security.md"
echo ""

exit 1

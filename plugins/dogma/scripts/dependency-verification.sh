#!/bin/bash
# Dogma: Dependency Verification Hook
# Asks user if they want to search for security risks before installing packages
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch for all hooks
# ENV: CLAUDE_MB_DOGMA_DEPENDENCY_VERIFICATION=true (default) | false

# NOTE: Do NOT use set -e, it causes issues in Claude Code hooks
# Trap all errors and exit cleanly
trap 'exit 0' ERR

# Load shared permissions library (for is_hydra_worktree)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-permissions.sh" 2>/dev/null || true

# === HYDRA WORKTREE CHECK ===
# In worktrees: Only allow installing from lockfile (no new packages)
IN_WORKTREE="false"
if type is_hydra_worktree &>/dev/null && is_hydra_worktree; then
    IN_WORKTREE="true"
fi

# === JSON OUTPUT FOR DENY ===
# Claude Code expects JSON with permissionDecision
# Using "deny" blocks the command and shows the reason
output_deny() {
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
# Pattern matches: start, chained (&&, ;, ||, |), subshells ($(), (), ``), xargs
# CMD_PREFIX covers: ^, &&, ;, ||, |, $(, (, `, xargs
PACKAGE_MANAGER=""
PACKAGES=""

# npm install <package> (not just npm install without args)
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*|\|\s*|\$\(\s*|\(\s*|`\s*|xargs\s+)npm\s+(install|i|add)\s+[^-]'; then
    PACKAGE_MANAGER="npm"
    # Extract packages from the npm install part of the command
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'npm\s+(install|i|add)\s+[^;&]+' | sed -E 's/npm\s+(install|i|add)\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# yarn add <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*|\|\s*|\$\(\s*|\(\s*|`\s*|xargs\s+)yarn\s+add\s+[^-]'; then
    PACKAGE_MANAGER="yarn"
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'yarn\s+add\s+[^;&]+' | sed 's/yarn\s\+add\s\+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# pnpm add <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*|\|\s*|\$\(\s*|\(\s*|`\s*|xargs\s+)pnpm\s+(add|install)\s+[^-]'; then
    PACKAGE_MANAGER="pnpm"
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'pnpm\s+(add|install)\s+[^;&]+' | sed -E 's/pnpm\s+(add|install)\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# pip install <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*|\|\s*|\$\(\s*|\(\s*|`\s*|xargs\s+)pip[3]?\s+install\s+[^-]'; then
    PACKAGE_MANAGER="pip"
    PACKAGES=$(echo "$TOOL_INPUT" | grep -oE 'pip[3]?\s+install\s+[^;&]+' | sed -E 's/pip[3]?\s+install\s+//' | sed 's/\s*--.*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')
fi

# cargo add <package>
if echo "$TOOL_INPUT" | grep -qE '(^|&&\s*|;\s*|\|\|\s*|\|\s*|\$\(\s*|\(\s*|`\s*|xargs\s+)cargo\s+add\s+'; then
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
PKG_LIST=$(echo "$PACKAGES" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/ $//')

# Build the install command for user reference
INSTALL_CMD="$TOOL_INPUT"

# === WORKTREE MODE ===
# In worktrees: Only allow exact versions from main repo lockfile
if [ "$IN_WORKTREE" = "true" ]; then
    # Get main repo path
    MAIN_REPO=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')

    # Check if lockfile exists
    LOCKFILE_FOUND="false"
    case "$PACKAGE_MANAGER" in
        npm|pnpm|yarn)
            [ -f "$MAIN_REPO/pnpm-lock.yaml" ] || [ -f "$MAIN_REPO/package-lock.json" ] || [ -f "$MAIN_REPO/yarn.lock" ] && LOCKFILE_FOUND="true"
            ;;
        pip)
            [ -f "$MAIN_REPO/requirements.lock" ] || [ -f "$MAIN_REPO/requirements.txt" ] || [ -f "$MAIN_REPO/poetry.lock" ] || [ -f "$MAIN_REPO/Pipfile.lock" ] && LOCKFILE_FOUND="true"
            ;;
        cargo)
            [ -f "$MAIN_REPO/Cargo.lock" ] && LOCKFILE_FOUND="true"
            ;;
    esac

    # Fallback: No lockfile found - ask user via main agent
    if [ "$LOCKFILE_FOUND" != "true" ]; then
        output_deny "BLOCKED in worktree: No lockfile found in main repo ($MAIN_REPO). Cannot verify package versions. Ask the main agent or user: Should I install $PKG_LIST? If approved, run manually: $INSTALL_CMD"
    fi

    # Check each package against main repo lockfile
    BLOCKED_PKGS=""
    for PKG in $PACKAGES; do
        MAIN_VERSION=""

        case "$PACKAGE_MANAGER" in
            npm|pnpm|yarn)
                # Extract package name (remove version if specified like pkg@1.2.3)
                PKG_NAME=$(echo "$PKG" | sed 's/@.*//')
                PKG_VERSION=$(echo "$PKG" | grep -oE '@[^@]+$' | sed 's/@//' || true)

                # Check lockfiles
                if [ -f "$MAIN_REPO/pnpm-lock.yaml" ]; then
                    MAIN_VERSION=$(grep -A1 "/$PKG_NAME@" "$MAIN_REPO/pnpm-lock.yaml" 2>/dev/null | head -1 | grep -oE '@[0-9][^:]+' | sed 's/@//' || true)
                elif [ -f "$MAIN_REPO/package-lock.json" ]; then
                    MAIN_VERSION=$(jq -r ".packages[\"\"].dependencies[\"$PKG_NAME\"] // .dependencies[\"$PKG_NAME\"].version // empty" "$MAIN_REPO/package-lock.json" 2>/dev/null || true)
                elif [ -f "$MAIN_REPO/yarn.lock" ]; then
                    MAIN_VERSION=$(grep -A1 "\"$PKG_NAME@" "$MAIN_REPO/yarn.lock" 2>/dev/null | grep "version" | head -1 | grep -oE '"[0-9][^"]+' | sed 's/"//' || true)
                fi
                ;;

            pip)
                # Extract package name (remove version specifier like pkg==1.2.3 or pkg>=1.0)
                PKG_NAME=$(echo "$PKG" | sed -E 's/[=<>!].*//')
                PKG_VERSION=$(echo "$PKG" | grep -oE '==[0-9][^,]+' | sed 's/==//' || true)

                # Check pip lockfiles
                if [ -f "$MAIN_REPO/requirements.lock" ]; then
                    MAIN_VERSION=$(grep -iE "^${PKG_NAME}==" "$MAIN_REPO/requirements.lock" 2>/dev/null | grep -oE '==[0-9][^,]+' | sed 's/==//' || true)
                elif [ -f "$MAIN_REPO/requirements.txt" ]; then
                    MAIN_VERSION=$(grep -iE "^${PKG_NAME}==" "$MAIN_REPO/requirements.txt" 2>/dev/null | grep -oE '==[0-9][^,]+' | sed 's/==//' || true)
                elif [ -f "$MAIN_REPO/poetry.lock" ]; then
                    MAIN_VERSION=$(grep -A2 "name = \"$PKG_NAME\"" "$MAIN_REPO/poetry.lock" 2>/dev/null | grep "version" | head -1 | grep -oE '"[0-9][^"]+' | sed 's/"//' || true)
                elif [ -f "$MAIN_REPO/Pipfile.lock" ]; then
                    MAIN_VERSION=$(jq -r ".default[\"$PKG_NAME\"].version // empty" "$MAIN_REPO/Pipfile.lock" 2>/dev/null | sed 's/==//' || true)
                fi
                ;;

            cargo)
                # Extract crate name (remove version like pkg@1.2.3)
                PKG_NAME=$(echo "$PKG" | sed 's/@.*//')
                PKG_VERSION=$(echo "$PKG" | grep -oE '@[0-9][^@]+' | sed 's/@//' || true)

                # Check Cargo.lock
                if [ -f "$MAIN_REPO/Cargo.lock" ]; then
                    MAIN_VERSION=$(grep -A1 "name = \"$PKG_NAME\"" "$MAIN_REPO/Cargo.lock" 2>/dev/null | grep "version" | head -1 | grep -oE '"[0-9][^"]+' | sed 's/"//' || true)
                fi
                ;;
        esac

        if [ -z "$MAIN_VERSION" ]; then
            # Package not in main repo - block and ask
            BLOCKED_PKGS="$BLOCKED_PKGS $PKG (not in main repo)"
        elif [ -n "$PKG_VERSION" ] && [ "$PKG_VERSION" != "$MAIN_VERSION" ]; then
            # Version mismatch - block
            BLOCKED_PKGS="$BLOCKED_PKGS $PKG (main has $MAIN_VERSION)"
        fi
    done

    if [ -n "$BLOCKED_PKGS" ]; then
        output_deny "BLOCKED in worktree: Package version mismatch with main repo:$BLOCKED_PKGS. Ask the main agent or user: Should I install these packages? Use exact versions from main repo, or add new packages in main repo first. Manual install: $INSTALL_CMD"
    fi

    # All packages match main repo - allow installation
    exit 0
fi

# === MAIN REPO MODE ===
# In main repo: Require security verification
output_deny "BLOCKED: Package installation detected ($PACKAGE_MANAGER: $PKG_LIST). Ask the user: Do you want me to search the web for security risks or vulnerabilities for these packages first? Supply chain attacks often target specific package versions. If the user wants to skip the security check and install directly, show this command: $INSTALL_CMD"

#!/bin/bash
# Dogma: Stop Hook - Lint & Format Check
# Runs prettier AND eslint check when task completes (only on changed files)
#
# ENV: CLAUDE_MB_DOGMA_LINT_ON_STOP=true (default) | false

trap 'exit 0' ERR

# === DEBUG MODE ===
DEBUG="${CLAUDE_MB_DOGMA_DEBUG:-false}"
if [ "$DEBUG" = "true" ]; then
    exec 2>>/tmp/dogma-hooks.log
    set -x
    echo "=== lint-on-stop.sh START $(date) ===" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === FEATURE TOGGLE (default: on) ===
if [ "${CLAUDE_MB_DOGMA_LINT_ON_STOP:-true}" != "true" ]; then
    exit 0
fi

# Read JSON input from stdin (not used but consumed)
INPUT=$(cat 2>/dev/null || true)

# === CHECK IF THIS IS A NODE PROJECT ===
if [ ! -f "package.json" ]; then
    exit 0
fi

# === DETECT INSTALLED TOOLS ===
HAS_PRETTIER=false
HAS_ESLINT=false

if grep -q '"prettier"' package.json 2>/dev/null && [ -d "node_modules/prettier" ]; then
    HAS_PRETTIER=true
fi

if grep -q '"eslint"' package.json 2>/dev/null && [ -d "node_modules/eslint" ]; then
    HAS_ESLINT=true
fi

# Exit if neither tool is installed
if [ "$HAS_PRETTIER" = "false" ] && [ "$HAS_ESLINT" = "false" ]; then
    exit 0
fi

# === GET CHANGED FILES ===
# Only check files that were modified (staged + unstaged + untracked)
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || true)

# Combine all changed files
ALL_CHANGED=$(echo -e "${CHANGED_FILES}\n${STAGED_FILES}\n${UNTRACKED_FILES}" | sort -u | grep -v '^$' || true)

if [ -z "$ALL_CHANGED" ]; then
    exit 0
fi

# Filter files by tool
PRETTIER_FILES=$(echo "$ALL_CHANGED" | grep -E '\.(js|ts|jsx|tsx|json|md|css|scss|vue|php|html|yaml|yml|graphql|twig)$' 2>/dev/null || true)
ESLINT_FILES=$(echo "$ALL_CHANGED" | grep -E '\.(js|ts|jsx|tsx|mjs|cjs)$' 2>/dev/null || true)

# Exit if no relevant files
if [ -z "$PRETTIER_FILES" ] && [ -z "$ESLINT_FILES" ]; then
    exit 0
fi

# === RUN CHECKS ===
# Order: Lint first, then Format (fix code issues before formatting)
echo ""
echo "<dogma-lint-check>"

ESLINT_OK=true
PRETTIER_OK=true

# --- ESLINT (Linter) - runs FIRST ---
if [ "$HAS_ESLINT" = "true" ] && [ -n "$ESLINT_FILES" ]; then
    # Use --quiet to only show errors, not warnings
    if echo "$ESLINT_FILES" | xargs npx eslint --quiet 2>/dev/null; then
        echo "[dogma] ESLint: No errors in changed files."
    else
        ESLINT_OK=false
        echo "[dogma] ESLint: Linting errors found."
        echo "  Fix with: npx eslint --fix <file>"
    fi
fi

# --- PRETTIER (Formatter) - runs SECOND ---
if [ "$HAS_PRETTIER" = "true" ] && [ -n "$PRETTIER_FILES" ]; then
    if echo "$PRETTIER_FILES" | xargs npx prettier --check 2>/dev/null; then
        echo "[dogma] Prettier: All changed files are formatted correctly."
    else
        PRETTIER_OK=false
        echo "[dogma] Prettier: Formatting issues found."
        echo "  Fix with: npx prettier --write <file>"
    fi
fi

# --- SUMMARY ---
if [ "$PRETTIER_OK" = "true" ] && [ "$ESLINT_OK" = "true" ]; then
    echo "[dogma] All checks passed."
fi

echo "</dogma-lint-check>"

exit 0

#!/bin/bash
# Dogma: Stop Hook - Lint Check
# Runs prettier check when task completes (only on changed files)
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

# === CHECK IF PRETTIER EXISTS ===
if [ ! -f "package.json" ]; then
    exit 0
fi

if ! grep -q '"prettier"' package.json 2>/dev/null; then
    exit 0
fi

if [ ! -d "node_modules/prettier" ]; then
    exit 0
fi

# === GET CHANGED FILES ===
# Only check files that were modified (staged + unstaged + untracked)
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>/dev/null || true)

# Combine all changed files
ALL_CHANGED=$(echo -e "${CHANGED_FILES}\n${STAGED_FILES}\n${UNTRACKED_FILES}" | sort -u | grep -v '^$' || true)

# Filter to only prettier-supported files
PRETTIER_FILES=$(echo "$ALL_CHANGED" | grep -E '\.(js|ts|jsx|tsx|json|md|css|scss|vue|php|html|yaml|yml|graphql|twig)$' 2>/dev/null || true)

if [ -z "$PRETTIER_FILES" ]; then
    # No relevant files changed
    exit 0
fi

# === RUN PRETTIER CHECK ===
echo ""
echo "<dogma-lint-check>"

# Check only changed files
if echo "$PRETTIER_FILES" | xargs npx prettier --check 2>/dev/null; then
    echo "[dogma] All changed files are formatted correctly."
else
    echo "[dogma] Formatting issues found in changed files."
    echo "Run 'npm run format:staged' or 'npx prettier --write <file>' to fix."
fi

echo "</dogma-lint-check>"

exit 0

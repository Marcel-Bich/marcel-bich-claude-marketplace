#!/bin/bash
# Dogma: Stop Hook - Lint Check
# Runs prettier check when task completes
#
# ENV: CLAUDE_MB_DOGMA_LINT_ON_STOP=true | false (default)

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

# === FEATURE TOGGLE (default: off) ===
if [ "${CLAUDE_MB_DOGMA_LINT_ON_STOP:-false}" != "true" ]; then
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

# Check if node_modules/prettier exists
if [ ! -d "node_modules/prettier" ]; then
    exit 0
fi

# === RUN PRETTIER CHECK ===
echo ""
echo "<dogma-lint-check>"

if npx prettier --check . 2>/dev/null; then
    echo "[dogma] All files are formatted correctly."
else
    echo "[dogma] Formatting issues found."
    echo "Run 'npm run format' to fix."
fi

echo "</dogma-lint-check>"

exit 0

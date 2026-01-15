#!/bin/bash
# Dogma: Pre-Commit Lint Hook
# Blocks git commit until /dogma:lint has been run
#
# Skip with: CLAUDE_MB_DOGMA_SKIP_LINT_CHECK=true git commit ...
# Claude sets this ENV after running /dogma:lint successfully.
#
# ENV: CLAUDE_MB_DOGMA_ENABLED=true (default) | false - master switch
# ENV: CLAUDE_MB_DOGMA_PRE_COMMIT_LINT=true (default) | false
# ENV: CLAUDE_MB_DOGMA_SKIP_LINT_CHECK=true - skip this check (set by Claude after lint)

trap 'exit 0' ERR

# === JSON OUTPUT FOR BLOCKING ===
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
    echo "=== pre-commit-lint.sh START $(date) ===" >&2
fi

# === MASTER SWITCH ===
if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

# === CONFIGURATION ===
ENABLED="${CLAUDE_MB_DOGMA_PRE_COMMIT_LINT:-true}"
if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# === SKIP CHECK ===
# Claude sets this after running /dogma:lint successfully
if [ "${CLAUDE_MB_DOGMA_SKIP_LINT_CHECK:-false}" = "true" ]; then
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

# Only trigger on git commit
if ! echo "$TOOL_INPUT" | grep -qE '(^|\s|;|&&|\||\|\|)git\s+commit(\s|$)'; then
    exit 0
fi

# === CHECK FOR STAGED FILES ===
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
if [ -z "$STAGED_FILES" ]; then
    # No staged files, allow commit
    exit 0
fi

# === BLOCK COMMIT ===
output_block "BLOCKED: Run /dogma:lint before committing. After successful lint, commit with: CLAUDE_MB_DOGMA_SKIP_LINT_CHECK=true git commit ..."

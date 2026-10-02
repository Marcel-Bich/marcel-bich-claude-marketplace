#!/bin/bash
# Dogma: Delete Guard Hook (PreToolUse:Bash)
# Blocks commands that could destroy protected data: /, first-level directories,
# /home depth 0-2, the home and its direct children, and every absolute path outside
# /tmp/X+ and /var/tmp/X+. Targets are resolved before the check (~, $HOME, relative
# to the working directory and a preceding cd, symlinks via realpath, glob base), so
# a symlink in /tmp pointing at the home cannot smuggle a wipe through. Targets that
# cannot be resolved for sure are blocked. Symlinks onto protected paths are blocked
# at creation as an extra hurdle.
#
# Unlike file-protection.sh this guard does NOT read DOGMA-PERMISSIONS.md and has no
# per-hook switch and no worktree exemption: it always applies. Only the master
# switch CLAUDE_MB_DOGMA_ENABLED=false turns it off.
# Core logic: delete-guard.py (python3). Without python3 a command that looks
# destructive is denied (fail closed).

if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="$(cat 2>/dev/null || true)"

deny() {
    jq -n --arg r "dogma delete-guard: $1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

if ! command -v python3 >/dev/null 2>&1; then
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(rm|unlink|shred|rmdir|mv|ln|find|mkfs|wipefs|dd|truncate)([^[:alnum:]_]|$)'; then
        deny "python3 is missing, destructive-looking command blocked (fail closed)"
    fi
    exit 0
fi

reason="$(printf '%s' "$INPUT" | python3 -I "$SCRIPT_DIR/delete-guard.py" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    deny "guard error (exit $rc), command blocked (fail closed)"
fi
if [ -n "$reason" ]; then
    deny "$reason"
fi
exit 0

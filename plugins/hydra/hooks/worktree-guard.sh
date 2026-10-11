#!/bin/bash
# worktree-guard - PreToolUse hook (Agent, Task, EnterWorktree, Bash).
# Thin wrapper around scripts/worktree-guard.py. Fails open: without python3 or on any
# error the tool call is allowed. The logic prints a deny decision only when the hydra
# flow is active and the call would create a worktree outside hydra's flow.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
python3 "$HERE/../scripts/worktree-guard.py" || true
exit 0

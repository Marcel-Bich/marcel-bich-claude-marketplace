#!/bin/bash
# worktree-guard - PreToolUse hook (Agent, Task, EnterWorktree, Bash).
# Thin wrapper around scripts/worktree-guard.py. The logic prints a deny decision only when
# the hydra flow is active and the call would create a worktree outside hydra's flow; an
# internal error of the logic allows the call (fail open).
#
# Python is looked up as python3, then python, then py -3 (native Windows ships no
# python3.exe; the Microsoft Store stub is rejected), see scripts/lib-python.sh. Without any
# Python 3 the guard is never silently off: a text fallback fails closed for the worktree
# creations it cannot check (Agent/Task isolation worktree, EnterWorktree without a path,
# git worktree add without a ../<repo>-worktrees/ destination) unless the Hydra checkbox in
# DOGMA-PERMISSIONS.md is off, and the first call of a session shows a one-time message.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
PAYLOAD="$(cat)"

# shellcheck source=../scripts/lib-python.sh
if . "$HERE/../scripts/lib-python.sh" 2>/dev/null && hydra_find_python; then
    printf '%s' "$PAYLOAD" | hydra_python -I "$HERE/../scripts/worktree-guard.py" || true
    exit 0
fi

# --- no Python 3: text fallback ---------------------------------------------------
NOPY="hydra: the worktree guard needs Python 3 (python3, python or py -3) and found none - install Python 3 for the full check."
LIMITS="Until then Agent/Task isolation worktree and EnterWorktree without a path are blocked, and git worktree add passes only with a destination under ../<repo>-worktrees/<name>. Create worktrees with /hydra:create <name>."

field() { # name -> first string value of "name": "..." in the payload (escapes not decoded)
    printf '%s' "$PAYLOAD" | grep -o "\"$1\" *: *\"[^\"]*\"" | head -n1 | sed 's/^[^:]*: *"//; s/"$//'
}
has() { printf '%s' "$PAYLOAD" | grep -qE -- "$1"; }

perm_file() { # nearest DOGMA-PERMISSIONS.md upward from the working dir, else in the main checkout
    local d="$PWD" root
    while :; do
        [ -f "$d/DOGMA-PERMISSIONS.md" ] && { echo "$d/DOGMA-PERMISSIONS.md"; return 0; }
        [ "$d" = "/" ] || [ -z "$d" ] && break
        d="$(dirname "$d")"
    done
    root="$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
    [ -n "$root" ] && [ -f "$root/DOGMA-PERMISSIONS.md" ] && echo "$root/DOGMA-PERMISSIONS.md"
    return 0
}

hydra_off() { # the Hydra checkbox is [ ], [?], [0], [1] or [a] (by id, else by text)
    local f
    f="$(perm_file)"
    [ -n "$f" ] || return 1
    if grep -q 'xw1i)' "$f"; then
        grep -qE '^[[:space:]]*-[[:space:]]*\[[ ?01a]\].*xw1i\)' "$f"
    else
        grep -qE '^[[:space:]]*-[[:space:]]*\[[ ?01a]\][[:space:]]*use Hydra for 2\+ independent tasks' "$f"
    fi
}

deny() {
    printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "%s"}}\n' \
        "$NOPY $1 $LIMITS"
}

case "$(field tool_name)" in
    Agent|Task)
        if has '"isolation" *: *"worktree"' && ! hydra_off; then
            deny "Agent with isolation worktree is blocked."
            exit 0
        fi
        ;;
    EnterWorktree)
        if ! has '"path" *: *"[^"]' && ! hydra_off; then
            deny "EnterWorktree without a path is blocked (it creates a worktree outside the hydra flow)."
            exit 0
        fi
        ;;
    Bash)
        if has 'worktree +add' && ! has '-worktrees/' && ! hydra_off; then
            deny "This git worktree add cannot be checked and has no ../<repo>-worktrees/<name> destination."
            exit 0
        fi
        ;;
esac

# allowed: tell the session once that the guard runs in its reduced form
sid="$(field session_id | tr -cd 'A-Za-z0-9_-')"
mark="${TMPDIR:-/tmp}/hydra-guard-no-python.${sid:-nosession}"
if [ ! -e "$mark" ]; then
    : >"$mark" 2>/dev/null
    printf '{"systemMessage": "%s"}\n' "$NOPY $LIMITS"
fi
exit 0

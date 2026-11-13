#!/bin/bash
# Dogma: Delete Guard Hook (PreToolUse:Bash)
# Denies the hard list only: commands that delete, move away or overwrite protected data
# whatever the delete setting says: /, the home and its first level, every path of depth <= 3
# outside the temp roots, mounted storage (depth <= 4 below /mnt and /media, mount points and
# their first level), Windows profile and system paths, whole repositories. Targets are resolved
# before the check (~, $HOME, relative to the working directory and a preceding cd, symlinks via
# realpath, glob base, plain literal variables of the same command), so a symlink in /tmp pointing
# at the home cannot smuggle a wipe through. A target that cannot be resolved for sure (unset or
# re-assigned variable, command substitution, eval, xargs ...) is NOT denied here: it is a delete
# finding and DOGMA-PERMISSIONS.md decides (file-protection.sh). Symlinks onto protected paths are
# denied at creation as an extra hurdle.
#
# Before that check, bash-guard.py normalises the command like a shell (quoting,
# variables, wrappers, nested shells, substitutions, heredocs) and checks every simple
# command on its own: protected paths (also mounts, devices, the working directory and
# its parents), run-time command words next to destructive commands (fail closed),
# data-destroying git commands with a redirected work tree, archive/sync source
# deletion, disk wipe tools, Windows-side deletion from WSL and inline interpreter code.
# It also applies the setting-independent rules of the token, git-add and dependency
# guards (each behind its own switch).
#
# credo's cleanup helper (credo-cleanup.py own-rm, #174) is not a delete command for this guard
# (it names no rm/unlink), so this guard does not judge it; the helper applies its own rules. It
# deletes without a prompt only inside the TMPDIR and scratchpad of a session bound to the
# caller's process tree, single files a successful Write/Edit call of that session created in a
# temp dir (transcript-confirmed), and known build-output dirs (node_modules, dist, ...) ignored by
# a tracked .gitignore in a hydra worktree that session created; everything else it only reports.
# It keeps its own hard denylist (/, the home, ~/.claude*, mounts, repositories, the owner keep
# list) and reads none of its paths or switches from the environment. The session id it uses
# comes from the environment, which is why it must be bound to the calling process tree.
#
# Unlike file-protection.sh this guard does NOT read DOGMA-PERMISSIONS.md and has no
# per-hook switch and no worktree exemption: it always applies. Only the master
# switch CLAUDE_MB_DOGMA_ENABLED=false turns it off.
# Core logic: bash-guard.py + delete-guard.py (python3). Without python3 a command that
# looks destructive is denied (fail closed).

if [ "${CLAUDE_MB_DOGMA_ENABLED:-true}" != "true" ]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="$(cat 2>/dev/null || true)"

deny() {
    local r="$1"
    case "$r" in dogma*) ;; *) r="dogma delete-guard: $r" ;; esac
    jq -n --arg r "$r" \
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

reason="$(printf '%s' "$INPUT" | python3 -I "$SCRIPT_DIR/bash-guard.py" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    deny "guard error (exit $rc), command blocked (fail closed)"
fi
if [ -n "$reason" ]; then
    deny "$reason"
fi
exit 0

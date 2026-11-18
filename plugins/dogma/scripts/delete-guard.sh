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
# Core logic: bash-guard.py + delete-guard.py (Python 3). Without a working POSIX Python 3
# (lib-python.sh: not the Windows Store alias stub, not a native Windows Python) a command
# that looks destructive is denied (fail closed).

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

# --- text fallback for writes (no POSIX Python 3) ----------------------------------------------
# Without bash-guard.py a redirect (>, >>, &>, >|) or tee onto a protected path must still be
# refused. This is a plain text check, so it errs on the strict side for literal paths and lets
# what it cannot read (a variable other than $HOME, a relative path) through, like bash-guard.py
# does for an unresolved redirect of a command. /dev/null, the standard streams and /dev/fd/N are
# never targets to protect.

# True when the literal write target $1 is protected: the home and its first level, dotfiles
# and dot dirs of a home, system dirs, devices, the root level, mounts and Windows drives
# (Git Bash /c/..., C:/... or C:\...) near their top, Windows system and profile config paths.
text_write_protected() {
    local t="$1" home_rest="" depth
    case "$t" in
        \"*\") t="${t#\"}"; t="${t%\"}" ;;
        \'*\') t="${t#\'}"; t="${t%\'}" ;;
    esac
    case "$t" in
        /dev/null|/dev/stdout|/dev/stderr|/dev/stdin|/dev/tty) return 1 ;;
        /dev/fd/[0-9]|/dev/fd/[0-9][0-9]) return 1 ;;
    esac
    # shellcheck disable=SC2088  # the literal word ~ is matched here, not expanded
    case "$t" in
        "~") home_rest="/" ;;
        "~/"*) home_rest="${t#\~}" ;;
        "\$HOME"|"\${HOME}") home_rest="/" ;;
        "\$HOME/"*) home_rest="${t#\$HOME}" ;;
        "\${HOME}/"*) home_rest="${t#*\}}" ;;
        "~"*) return 0 ;;          # ~user: another home
        *"\$"*|*"\`"*) return 1 ;; # run-time value: not readable as text
    esac
    if [ -n "$home_rest" ]; then
        home_rest="$(printf '%s' "$home_rest" | tr -s '/')"
        home_rest="${home_rest#/}"
        home_rest="${home_rest%/}"
        case "$home_rest" in
            ""|.*) return 0 ;;     # the home itself, dotfiles and dot dirs (.bashrc, .ssh/..., .config/...)
            */*) ;;
            *) return 0 ;;         # first level of the home
        esac
        case "$home_rest" in
            [Aa]pp[Dd]ata/[Ll]ocal/[Tt]emp/*) return 1 ;;
            [Aa]pp[Dd]ata/*|[Dd]ocuments/[Pp]ower[Ss]hell/*|[Dd]ocuments/[Ww]indows[Pp]ower[Ss]hell/*) return 0 ;;
        esac
        return 1
    fi
    case "$t" in
        /*|[A-Za-z]:[/\\]*) ;;
        *) return 1 ;;             # relative: inside the working directory
    esac
    # one spelling: forward slashes, lower case, no repeated or trailing slash, C:/ -> /c/
    t="$(printf '%s' "$t" | tr '\\' '/' | tr -s '/' | tr '[:upper:]' '[:lower:]')"
    case "$t" in
        [a-z]:/*) t="/${t%%:*}/${t#?:/}" ;;
    esac
    t="${t%/}"
    case "/$t/" in
        */../*|*/./*) return 0 ;;  # not normalised here: fail closed
    esac
    case "$t" in
        ""|/dev/*|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib32/*|/lib64/*|\
        /boot|/boot/*|/proc/*|/sys/*|/root|/root/*) return 0 ;;
        /var/tmp/*|/tmp/*) return 1 ;;
        /var|/var/*) return 0 ;;
    esac
    depth="$(printf '%s' "$t" | tr -cd '/' | wc -c)"
    [ "$depth" -le 1 ] && return 0                       # the root level (/x, /c)
    case "$t" in
        /home/*) [ "$depth" -le 3 ] && return 0          # /home/<u> and its first level
                 case "${t#/home/*/}" in .*) return 0 ;; esac  # dotfiles and dot dirs of a home
                 return 1 ;;
        /mnt/?/*|/media/?/*) t="/${t#/*/}" ;;            # a WSL drive: the Windows rules below
        /mnt/*|/media/*) [ "$depth" -le 3 ] && return 0; return 1 ;;
    esac
    case "$t" in
        /?/*) ;;                                         # a Windows drive (Git Bash /c/...)
        *) return 1 ;;
    esac
    depth="$(printf '%s' "$t" | tr -cd '/' | wc -c)"
    [ "$depth" -le 2 ] && return 0                       # C:\ and its first level
    case "$t" in
        /?/windows/*|/?/program\ files/*|/?/program\ files\ \(x86\)/*|/?/programdata/*) return 0 ;;
        /?/users/*/appdata/local/temp/*) return 1 ;;
        /?/users/*) [ "$depth" -le 4 ] && return 0       # a profile and its first level
                    case "${t#/?/users/*/}" in
                        .*|appdata/*|documents/powershell/*|documents/windowspowershell/*) return 0 ;;
                    esac ;;
    esac
    return 1
}

# Print the first protected write target of command $1 (redirects and tee operands).
text_protected_write() {
    local word tees
    while IFS= read -r word; do
        word="$(printf '%s' "$word" | sed -E 's/^(&>>?|[0-9]*>>?\|?)[[:space:]]*//')"
        [ -n "$word" ] && text_write_protected "$word" && { printf '%s\n' "$word"; return 0; }
    done < <(printf '%s' "$1" | grep -oE "(&>>?|[0-9]*>>?\|?)[[:space:]]*(\"[^\"]*\"|'[^']*'|[^[:space:];&|()<>\"']+)")
    local -a words
    tees="$(printf '%s' "$1" | grep -oE '(^|[|;&(`[:space:]])tee([[:space:]]+[^|;&()<>`]*)?' | sed -E 's/^.?tee//')"
    read -r -a words <<<"$(printf '%s' "$tees" | tr '\n' ' ')"
    for word in "${words[@]}"; do
        case "$word" in -*) continue ;; esac
        text_write_protected "$word" && { printf '%s\n' "$word"; return 0; }
    done
    return 1
}

# shellcheck source=lib-python.sh
. "$SCRIPT_DIR/lib-python.sh"
if ! dogma_find_python; then
    cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])(rm|unlink|shred|rmdir|mv|ln|find|mkfs|wipefs|dd|truncate)([^[:alnum:]_]|$)'; then
        deny "no working Python 3 (python3/python/py missing, the Windows Store stub or a native Windows Python), destructive-looking command blocked (fail closed)"
    fi
    if target="$(text_protected_write "$cmd")"; then
        deny "no working Python 3: write onto a protected path ($target) blocked (fail closed)"
    fi
    exit 0
fi

reason="$(printf '%s' "$INPUT" | dogma_python -I "$SCRIPT_DIR/bash-guard.py" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    deny "guard error (exit $rc), command blocked (fail closed)"
fi
if [ -n "$reason" ]; then
    deny "$reason"
fi
exit 0

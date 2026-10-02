#!/bin/bash
# credo-dogma-mode - read one checkbox of DOGMA-PERMISSIONS.md without needing dogma.
#
# Mirrors dogma's lib-permissions.sh get_permission_mode (same file resolution, same
# <permissions> block, same "### Subsection" scoping, same checkbox states, same
# inheritance) with one difference: a missing file, subsection or checkbox prints
# "missing" instead of defaulting to auto, so each caller decides its own default.
#
# Stable ids: every setting of the dogma template carries a fixed id "(§xxxx)" right
# after its checkbox (e.g. "- [x] (§xw1i) use Hydra for 2+ independent tasks"; registry:
# dogma docs/permission-ids.md). With --id the id is matched first, anywhere in the
# <permissions> block (subsection and wording do not matter); only when no checkbox line
# carries the id, the old subsection + pattern match runs (files without ids keep working).
#
# Which file applies (same order as dogma):
#   1. dir (the target; callers pass the repo they act on), searched upward; when
#      nothing is found there, the main worktree of the repository as well (a linked
#      worktree may lack the excluded file)
#   2. without dir: the credo pinned project (credo-config.sh resolve-project), unless
#      the session folder lies inside it anyway
#   3. upward from the current dir ($PWD)
# A target / pinned project / current dir without a file of its own gets the session
# folder's file.
#
# Session folder (the folder the Claude Code session was started in): DOGMA_SESSION_DIR
# when set, else the dir the SessionStart hook recorded for this session
# (${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/session-dirs/<id>, then dogma's
# .../dogma/session-dirs/<id>; id = CREDO_SESSION_ID, else CLAUDE_CODE_SESSION_ID) when
# that dir still exists, else $PWD. The record keeps inheritance working when a Bash
# tool command ran `cd <project> && ...` first; without one everything is as before.
#
# Inheritance: when the applied file is not the session folder's file, a setting it
# does not define (no id line, no matching text line) is read from the session folder's
# file, unless the applied file switches it off with "- [ ] (§r3nx) inherit permissions"
# (missing checkbox = on).
#
# Usage:
#   credo-dogma-mode.sh [--id <id>] <subsection> <pattern> [dir]
#     id          stable setting id without "§" and parentheses (4 chars [0-9a-z], e.g. xw1i)
#     subsection  name of the "### <subsection>" heading inside <permissions> (e.g. Hydra)
#     pattern     extended regex matched case-insensitively against the checkbox text
#     dir         the target dir (see above; default: none -> pinned project, then $PWD)
#
# Env (shared with dogma, mainly for tests):
#   DOGMA_SESSION_DIR   session folder and current dir (default: recorded session
#                       folder, else $PWD; current dir $PWD)
#   DOGMA_CREDO_CONFIG  "none" skips the pinned project lookup
#
# Output: auto ([x]), ask ([?]), deny ([ ] or [0]), one ([1]), all ([a]) or missing.
# Exit codes: 0 always (missing is an answer), 1 bad arguments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: credo-dogma-mode.sh [--id <id>] <subsection> <pattern> [dir]"
ID=""
if [ "${1:-}" = "--id" ]; then
    [ -n "${2:-}" ] || { echo "$USAGE" >&2; exit 1; }
    ID="$2"
    shift 2
    case "$ID" in
        [0-9a-z][0-9a-z][0-9a-z][0-9a-z]) ;;
        *) echo "credo-dogma-mode: bad id: $ID (expected 4 chars [0-9a-z])" >&2; exit 1 ;;
    esac
fi
[ $# -ge 2 ] && [ $# -le 3 ] || { echo "$USAGE" >&2; exit 1; }
SECTION="$1"
PATTERN="$2"
TARGET="${3:-}"
if [ -n "$TARGET" ]; then
    [ -d "$TARGET" ] || { echo "credo-dogma-mode: no such dir: $TARGET" >&2; exit 1; }
    TARGET="$(cd "$TARGET" && pwd)"
fi

# the session folder the SessionStart hook recorded for this session (credo's record,
# then dogma's); prints it, returns 1 when there is none or the dir is gone
recorded_session_dir() {
    local sid="${CREDO_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}" base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" rec d
    case "$sid" in
        ""|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    for rec in "$base/credo/session-dirs/$sid" "$base/dogma/session-dirs/$sid"; do
        [ -f "$rec" ] || continue
        d=""
        IFS= read -r d < "$rec" || true
        case "$d" in
            /*) [ -d "$d" ] && { echo "$d"; return 0; } ;;
        esac
    done
    return 1
}

# CUR_DIR: where the lookup without target / pin starts; SESSION_DIR: whose file is
# inherited (both the same unless a recorded session folder differs from $PWD)
if [ -n "${DOGMA_SESSION_DIR:-}" ]; then
    SESSION_DIR="$DOGMA_SESSION_DIR"
    CUR_DIR="$SESSION_DIR"
else
    CUR_DIR="$PWD"
    SESSION_DIR="$(recorded_session_dir)" || SESSION_DIR="$PWD"
fi

find_up() {
    local dir="$1"
    while [ "$dir" != "/" ] && [ -n "$dir" ] && [ "$dir" != "." ]; do
        if [ -f "$dir/DOGMA-PERMISSIONS.md" ]; then
            echo "$dir/DOGMA-PERMISSIONS.md"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# upward, then the main worktree of the repository
find_from() {
    find_up "$1" && return 0
    local main
    main="$(git -C "$1" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || main=""
    if [ -n "$main" ] && [ -f "$main/DOGMA-PERMISSIONS.md" ]; then
        echo "$main/DOGMA-PERMISSIONS.md"
        return 0
    fi
    return 1
}

# the credo pinned project dir, unless the current dir lies inside it
pinned_dir() {
    [ "${DOGMA_CREDO_CONFIG:-}" != "none" ] || return 1
    [ -f "$SCRIPT_DIR/credo-config.sh" ] || return 1
    local credo_dir proj sess
    credo_dir="$(bash "$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)" || return 1
    [ -n "$credo_dir" ] || return 1
    proj="$(dirname "$credo_dir")"
    [ -d "$proj" ] || return 1
    proj="$(cd "$proj" && pwd -P)"
    sess="$(cd "$CUR_DIR" 2>/dev/null && pwd -P)" || sess=""
    case "$sess/" in
        "$proj"/*) return 1 ;;
    esac
    echo "$proj"
}

SESSION_FILE=""
if [ -d "$SESSION_DIR" ]; then
    SESSION_FILE="$(find_up "$(cd "$SESSION_DIR" && pwd)")" || SESSION_FILE=""
fi
START="$TARGET"
[ -n "$START" ] || START="$(pinned_dir)" || START=""
# no target, no pin: the current dir (plus the main-worktree fallback)
if [ -z "$START" ] && [ -d "$CUR_DIR" ]; then
    START="$(cd "$CUR_DIR" && pwd)"
fi
FILE=""
if [ -n "$START" ]; then
    FILE="$(find_from "$START")" || FILE=""
fi
[ -n "$FILE" ] || FILE="$SESSION_FILE"
[ -n "$FILE" ] || { echo "missing"; exit 0; }

INHERIT=""
if [ -n "$SESSION_FILE" ] && [ "$(readlink -f "$FILE" 2>/dev/null || echo "$FILE")" != "$(readlink -f "$SESSION_FILE" 2>/dev/null || echo "$SESSION_FILE")" ]; then
    INHERIT="$SESSION_FILE"
fi

block() {
    sed -n '/<permissions>/,/<\/permissions>/p' "$1" 2>/dev/null
}

PRIMARY_BLOCK="$(block "$FILE")"
INHERIT_BLOCK=""
[ -z "$INHERIT" ] || INHERIT_BLOCK="$(block "$INHERIT")"

printf '%s\n' "$PRIMARY_BLOCK" | SECTION="$SECTION" PATTERN="$PATTERN" PERM_ID="$ID" \
    INHERIT_BLOCK="$INHERIT_BLOCK" python3 -c '
import os, re, sys
env = os.environ
section, pattern, pid = env["SECTION"], env["PATTERN"], env["PERM_ID"]
states = {"x": "auto", "?": "ask", " ": "deny", "0": "deny", "1": "one", "a": "all"}

def by_id(lines, ident):
    tag = "(§" + ident + ")"
    for line in lines:
        m = re.match(r"^-\s*\[(.)\]\s*(.*)$", line.strip())
        if m and tag in m.group(2):
            return m.group(1)
    return None

def lookup(lines):
    """Mode of the setting in one block, or None when the block does not define it."""
    if pid:
        st = by_id(lines, pid)
        if st is not None:
            return states.get(st, "missing")
    inside = False
    for line in lines:
        s = line.strip()
        if s.startswith("#") or s.startswith("</permissions>"):
            inside = bool(re.match(r"^###\s+" + re.escape(section) + r"\s*(?:\(§[0-9a-z]{4}\)\s*)?$", s, re.I))
            continue
        if not inside:
            continue
        m = re.match(r"^-\s*\[(.)\]\s*(.*)$", s)
        if m and m.group(1) in states and re.search(pattern, m.group(2), re.I):
            return states[m.group(1)]
    return None

def inherits(lines):
    """The applied file inherits unless it switches inheritance off (missing = on)."""
    st = by_id(lines, "r3nx")
    if st is None:
        for line in lines:
            m = re.match(r"^-\s*\[(.)\]\s*(.*)$", line.strip())
            if m and re.search(r"inherit permissions", m.group(2), re.I):
                st = m.group(1)
                break
    return st not in (" ", "0")

primary = sys.stdin.read().splitlines()
mode = lookup(primary)
if mode is None and env.get("INHERIT_BLOCK") and inherits(primary):
    mode = lookup(env["INHERIT_BLOCK"].splitlines())
print(mode or "missing")
'

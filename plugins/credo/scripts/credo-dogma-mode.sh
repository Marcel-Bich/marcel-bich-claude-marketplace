#!/bin/bash
# credo-dogma-mode - read one checkbox of DOGMA-PERMISSIONS.md without needing dogma.
#
# Mirrors dogma's lib-permissions.sh get_permission_mode (same file, same <permissions>
# block, same "### Subsection" scoping, same checkbox states) with one difference: a
# missing file, subsection or checkbox prints "missing" instead of defaulting to auto,
# so each caller decides its own default.
#
# Stable ids: every setting of the dogma template carries a fixed id "(§xxxx)" right
# after its checkbox (e.g. "- [x] (§xw1i) use Hydra for 2+ independent tasks"; registry:
# dogma docs/permission-ids.md). With --id the id is matched first, anywhere in the
# <permissions> block (subsection and wording do not matter); only when no checkbox line
# carries the id, the old subsection + pattern match runs (files without ids keep working).
#
# Usage:
#   credo-dogma-mode.sh [--id <id>] <subsection> <pattern> [dir]
#     id          stable setting id without "§" and parentheses (4 chars [0-9a-z], e.g. xw1i)
#     subsection  name of the "### <subsection>" heading inside <permissions> (e.g. Hydra)
#     pattern     extended regex matched case-insensitively against the checkbox text
#     dir         where to start the upward search (default: $PWD); when nothing is found
#                 there, the main worktree of the repository is searched as well (a
#                 linked worktree may lack the excluded file)
#
# Output: auto ([x]), ask ([?]), deny ([ ] or [0]), one ([1]), all ([a]) or missing.
# Exit codes: 0 always (missing is an answer), 1 bad arguments.

set -euo pipefail

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
START="${3:-$PWD}"
[ -d "$START" ] || { echo "credo-dogma-mode: no such dir: $START" >&2; exit 1; }
START="$(cd "$START" && pwd)"

find_up() {
    local dir="$1"
    while [ "$dir" != "/" ] && [ -n "$dir" ]; do
        if [ -f "$dir/DOGMA-PERMISSIONS.md" ]; then
            echo "$dir/DOGMA-PERMISSIONS.md"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

FILE="$(find_up "$START")" || FILE=""
if [ -z "$FILE" ]; then
    MAIN="$(git -C "$START" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || MAIN=""
    if [ -n "$MAIN" ] && [ -f "$MAIN/DOGMA-PERMISSIONS.md" ]; then
        FILE="$MAIN/DOGMA-PERMISSIONS.md"
    fi
fi
[ -n "$FILE" ] || { echo "missing"; exit 0; }

sed -n '/<permissions>/,/<\/permissions>/p' "$FILE" 2>/dev/null | SECTION="$SECTION" PATTERN="$PATTERN" PERM_ID="$ID" python3 -c '
import os, re, sys
section, pattern, pid = os.environ["SECTION"], os.environ["PATTERN"], os.environ["PERM_ID"]
states = {"x": "auto", "?": "ask", " ": "deny", "0": "deny", "1": "one", "a": "all"}
lines = sys.stdin.read().splitlines()
if pid:
    tag = "(\u00a7" + pid + ")"
    for line in lines:
        m = re.match(r"^-\s*\[(.)\]\s*(.*)$", line.strip())
        if m and tag in m.group(2):
            print(states.get(m.group(1), "missing"))
            sys.exit(0)
inside = False
for line in lines:
    s = line.strip()
    if s.startswith("#") or s.startswith("</permissions>"):
        inside = bool(re.match(r"^###\s+" + re.escape(section) + r"\s*(?:\(\u00a7[0-9a-z]{4}\)\s*)?$", s, re.I))
        continue
    if not inside:
        continue
    m = re.match(r"^-\s*\[(.)\]\s*(.*)$", s)
    if m and m.group(1) in states and re.search(pattern, m.group(2), re.I):
        print(states[m.group(1)])
        sys.exit(0)
print("missing")
'

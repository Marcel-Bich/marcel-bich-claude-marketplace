#!/bin/bash
# credo-dogma-mode - read one checkbox of DOGMA-PERMISSIONS.md without needing dogma.
#
# Mirrors dogma's lib-permissions.sh get_permission_mode (same file, same <permissions>
# block, same "### Subsection" scoping, same checkbox states) with one difference: a
# missing file, subsection or checkbox prints "missing" instead of defaulting to auto,
# so each caller decides its own default.
#
# Usage:
#   credo-dogma-mode.sh <subsection> <pattern> [dir]
#     subsection  name of the "### <subsection>" heading inside <permissions> (e.g. Hydra)
#     pattern     extended regex matched case-insensitively against the checkbox text
#     dir         where to start the upward search (default: $PWD); when nothing is found
#                 there, the main worktree of the repository is searched as well (a
#                 linked worktree may lack the excluded file)
#
# Output: auto ([x]), ask ([?]), deny ([ ] or [0]), one ([1]), all ([a]) or missing.
# Exit codes: 0 always (missing is an answer), 1 bad arguments.

set -euo pipefail

[ $# -ge 2 ] && [ $# -le 3 ] || { echo "usage: credo-dogma-mode.sh <subsection> <pattern> [dir]" >&2; exit 1; }
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

sed -n '/<permissions>/,/<\/permissions>/p' "$FILE" 2>/dev/null | SECTION="$SECTION" PATTERN="$PATTERN" python3 -c '
import os, re, sys
section, pattern = os.environ["SECTION"], os.environ["PATTERN"]
states = {"x": "auto", "?": "ask", " ": "deny", "0": "deny", "1": "one", "a": "all"}
inside = False
for line in sys.stdin:
    s = line.strip()
    if s.startswith("#") or s.startswith("</permissions>"):
        inside = bool(re.match(r"^###\s+" + re.escape(section) + r"\s*$", s, re.I))
        continue
    if not inside:
        continue
    m = re.match(r"^-\s*\[(.)\]\s*(.*)$", s)
    if m and m.group(1) in states and re.search(pattern, m.group(2), re.I):
        print(states[m.group(1)])
        sys.exit(0)
print("missing")
'

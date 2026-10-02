#!/bin/bash
# worktree-files - read the worktree files list of DOGMA-PERMISSIONS.md (read-only).
#
# A fresh git worktree only contains versioned files. Excluded or ignored files that
# agents need (CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md, .credo/, ...) are
# missing there. The "Worktree files" list inside the "### Hydra" subsection of the
# <permissions> block says which of them a worktree setup brings over, and how:
#
#   ### Hydra
#   ...
#   Worktree files (§47p9) (excluded files only; versioned files come with git checkout):
#   - link: CLAUDE.md
#   - link: .credo/
#   - copy: .env.local
#
# Kinds: `link` (symlink to the main checkout, the default - a line without a kind is
# a link) and `copy` (only where explicitly given, for files that must differ per
# worktree). Paths are relative to the repo root; backticks around a path are allowed.
# The list ends at the next heading, checkbox line or other non-list text.
# The list label is found by its stable id (§47p9) first (anywhere in the block, any
# wording); only when no line carries the id, by the text "Worktree files" in ### Hydra.
#
# When the file, the section or the list is missing or empty, the default list is
# printed: link CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md and .credo/.
# This reader only reports the list. Whoever applies it (hydra worktree-setup.sh,
# credo credo-worktree-setup.sh) skips paths that do not exist in the main checkout or
# are versioned, and never overwrites an existing path.
#
# Usage:
#   worktree-files.sh [--json] [dir]
#       kv:   one line per entry: "<kind> <path>"  (e.g. "link CLAUDE.md")
#       json: {"file": "..."|null, "source": "configured"|"default",
#              "entries": [{"kind": "link", "path": "CLAUDE.md"}, ...]}
#
# dir: where to start the upward search for DOGMA-PERMISSIONS.md (default: $PWD).
# Invalid entries (absolute paths, "..", unknown kinds) are skipped with a warning on
# stderr.
#
# Exit codes: 0 list printed (configured or default), 1 bad argument.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"

usage_error() {
    echo "worktree-files: $1" >&2
    exit 1
}

MODE="kv"
if [ "${1:-}" = "--json" ]; then
    MODE="json"
    shift
fi
case "${1:-}" in
    -*) usage_error "unknown argument: $1" ;;
esac
[ $# -le 1 ] || usage_error "unexpected argument: $2"
if [ -n "${1:-}" ]; then
    cd "$1" 2>/dev/null || usage_error "no such dir: $1"
fi

FILE="$(find_permissions_file)" || FILE=""

{ if [ -n "$FILE" ]; then get_permissions_section "$FILE"; fi; } | MODE="$MODE" FILE="$FILE" python3 -c '
import json, os, re, sys

DEFAULT = [("link", "CLAUDE.md"), ("link", "CLAUDE/"), ("link", "GUIDES/"),
           ("link", "DOGMA-PERMISSIONS.md"), ("link", ".credo/")]

def warn(msg):
    print("worktree-files: " + msg, file=sys.stderr)

entries = []
in_hydra = False
in_list = False
lines = [re.sub(r"<!--.*?-->", "", l).strip() for l in sys.stdin.read().splitlines()]
# Id first: the list label carrying the stable id (anywhere in the block, any wording);
# only when no line carries it, the old "Worktree files" label inside "### Hydra".
ID_LABEL = re.compile(r"^[^-#].*\(\u00a747p9\)")
by_id = any(ID_LABEL.match(l) for l in lines)
for s in lines:
    if s.startswith("#") or s.startswith("</permissions>"):
        in_hydra = bool(re.match(r"^###\s+hydra\s*(?:\(\u00a7[0-9a-z]{4}\)\s*)?$", s, re.I))
        in_list = False
        continue
    if by_id:
        if ID_LABEL.match(s):
            in_list = True
            continue
    else:
        if not in_hydra:
            continue
        if re.match(r"^worktree\s+files\b", s, re.I):
            in_list = True
            continue
    if not in_list:
        continue
    if not s:
        continue
    if not s.startswith("-") or re.match(r"^-\s*\[.\]", s):
        in_list = False
        continue
    m = re.match(r"^-\s*(?:([A-Za-z]+)\s*:\s*)?(.+)$", s)
    if not m:
        continue
    kind = (m.group(1) or "link").lower()
    path = m.group(2).strip().strip("`").strip()
    if kind not in ("link", "copy"):
        warn("ignoring unknown kind: " + m.group(1))
        continue
    if not path:
        continue
    parts = [p for p in path.rstrip("/").split("/") if p not in ("", ".")]
    if path.startswith("/") or ".." in parts or not parts:
        warn("ignoring path outside the repo: " + path)
        continue
    norm = "/".join(parts) + ("/" if path.endswith("/") else "")
    if any(e[1].rstrip("/") == norm.rstrip("/") for e in entries):
        warn("duplicate path " + norm + ", keeping the first")
        continue
    entries.append((kind, norm))

source = "configured" if entries else "default"
if not entries:
    entries = DEFAULT

if os.environ["MODE"] == "json":
    print(json.dumps({"file": os.environ["FILE"] or None, "source": source,
                      "entries": [{"kind": k, "path": p} for k, p in entries]}))
else:
    for k, p in entries:
        print(k + " " + p)
'

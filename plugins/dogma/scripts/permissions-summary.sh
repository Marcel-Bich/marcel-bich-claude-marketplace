#!/bin/bash
# permissions-summary - list the DOGMA-PERMISSIONS.md entries that restrict Claude (read-only).
#
# Only entries that block or ask are listed; [x] auto entries are implicit and
# left out. Any renderer (a terminal, a status line, a Claude Code mod, another
# harness) can show them without parsing the file itself.
#
# Usage:
#   permissions-summary.sh [dir]          key=value lines (file=..., ask=..., deny=...)
#   permissions-summary.sh --json [dir]   one JSON object {"file", "ask": [...], "deny": [...]}
#
# dir: where to start the upward search for DOGMA-PERMISSIONS.md (default: $PWD).
# Label of an entry: its first `code` span (`git add`), else its text without
# "May", "autonomously" and parentheses (e.g. "delete files").
#
# Exit codes: 0 summary printed, 4 no DOGMA-PERMISSIONS.md found (prints nothing),
# 1 bad argument.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"

MODE="kv"
if [ "${1:-}" = "--json" ]; then
    MODE="json"
    shift
fi
case "${1:-}" in
    -*) echo "permissions-summary: unknown argument: $1" >&2; exit 1 ;;
esac
if [ -n "${1:-}" ]; then
    cd "$1" 2>/dev/null || { echo "permissions-summary: no such dir: $1" >&2; exit 1; }
fi

FILE="$(find_permissions_file)" || exit 4

get_permissions_section "$FILE" | MODE="$MODE" FILE="$FILE" python3 -c '
import json, os, re, sys

ask, deny = [], []
# Only permission sections restrict Claude. Under a "## ... Workflow ..." heading
# the checkboxes are on/off switches ([ ] = off), not deny, so they are skipped.
in_workflow = False
for line in sys.stdin:
    h = re.match(r"^\s*##\s+(.*)$", line)
    if h and not line.lstrip().startswith("###"):
        in_workflow = "workflow" in h.group(1).lower()
        continue
    if in_workflow:
        continue
    m = re.match(r"^\s*-\s*\[([ ?0])\]\s*(.*)$", line)
    if not m:
        continue
    text = re.sub(r"<!--.*?-->", "", m.group(2))
    # drop an inline explanation after " -- " (e.g. "-- deny = log to TO-DELETE.md")
    text = re.split(r"\s+--\s", text, maxsplit=1)[0].strip()
    code = re.search(r"`([^`]+)`", text)
    if code:
        label = code.group(1)
    else:
        label = re.sub(r"\(.*?\)", "", text)
        label = re.sub(r"^May\s+(run\s+)?", "", label, flags=re.I)
        label = re.sub(r"\s+autonomously\b", "", label, flags=re.I).strip()
    (ask if m.group(1) == "?" else deny).append(label)

if os.environ["MODE"] == "json":
    print(json.dumps({"file": os.environ["FILE"], "ask": ask, "deny": deny}))
else:
    print("file=" + os.environ["FILE"])
    for label in ask:
        print("ask=" + label)
    for label in deny:
        print("deny=" + label)
'

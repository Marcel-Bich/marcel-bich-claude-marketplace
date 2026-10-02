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
# dir: the target - where to start the upward search for DOGMA-PERMISSIONS.md (default:
# the credo pinned project, else $PWD). Settings the found file does not define are
# inherited from the session folder's file (lib-permissions.sh load_permissions).
# Label of an entry: its first `code` span (`git add`), else its text without
# "May", "autonomously" and parentheses (e.g. "delete files"). A stable setting id
# "(§xxxx)" is never part of a label.
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
TARGET=""
if [ -n "${1:-}" ]; then
    TARGET="$(cd "$1" 2>/dev/null && pwd)" || { echo "permissions-summary: no such dir: $1" >&2; exit 1; }
fi

# dir = the target (else credo pinned project, else $PWD); the effective view merges
# the settings inherited from the session folder's file (load_permissions)
load_permissions "$TARGET" || exit 4
FILE="$PERMS_FILE"

printf '%s\n' "$PERMS_SECTION" | MODE="$MODE" FILE="$FILE" INHERIT_FILE="$DOGMA_INHERIT_FILE" \
    INHERIT_SECTION="$DOGMA_INHERIT_SECTION" python3 -c '
import json, os, re, sys

ID = re.compile(r"\(§([0-9a-z]{4})\)")

def parse(text):
    """All permission entries of a block: (state, label, id). Workflow switches and
    the inheritance switch are not permissions and are skipped."""
    out = []
    # Only permission sections restrict Claude. Under a "## ... Workflow ..." heading
    # the checkboxes are on/off switches ([ ] = off), not deny, so they are skipped;
    # the same holds for "## Inheritance" (inherit permissions on/off).
    skip = False
    for line in text.splitlines():
        h = re.match(r"^\s*##\s+(.*)$", line)
        if h and not line.lstrip().startswith("###"):
            head = h.group(1).lower()
            skip = "workflow" in head or "inheritance" in head
            continue
        if skip:
            continue
        m = re.match(r"^\s*-\s*\[(.)\]\s*(.*)$", line)
        if not m:
            continue
        text_ = re.sub(r"<!--.*?-->", "", m.group(2))
        idm = ID.search(text_)
        pid = idm.group(1) if idm else ""
        if pid == "r3nx" or re.search(r"inherit permissions", text_, re.I):
            continue
        # the stable setting id "(§xxxx)" is not part of the label
        text_ = ID.sub("", text_)
        text_ = re.sub(r"^\s+", "", text_)
        # drop an inline explanation after " -- " (e.g. "-- deny = log to TO-DELETE.md")
        text_ = re.split(r"\s+--\s", text_, maxsplit=1)[0].strip()
        code = re.search(r"`([^`]+)`", text_)
        if code:
            label = code.group(1)
        else:
            label = re.sub(r"\(.*?\)", "", text_)
            label = re.sub(r"^May\s+(run\s+)?", "", label, flags=re.I)
            label = re.sub(r"\s+autonomously\b", "", label, flags=re.I).strip()
        out.append((m.group(1), label, pid))
    return out

env = os.environ
primary_text = sys.stdin.read()
entries = [(s, l, "") for s, l, _ in parse(primary_text)]
inherit_file = env.get("INHERIT_FILE", "")
if inherit_file:
    # per setting: the resolved file wins (by id anywhere in its block, else by label);
    # settings it does not define come from the session folder file
    own_ids = set(ID.findall(primary_text))
    own_labels = {l for _, l, _ in entries}
    for s, l, pid in parse(env.get("INHERIT_SECTION", "")):
        if (pid and pid in own_ids) or l in own_labels:
            continue
        entries.append((s, l, inherit_file))

ask, deny, source = [], [], {}
for s, l, src in entries:
    if s == "?":
        ask.append(l)
    elif s in (" ", "0"):
        deny.append(l)
    else:
        continue
    if src:
        source[l] = src

if env["MODE"] == "json":
    d = {"file": env["FILE"], "ask": ask, "deny": deny}
    if source:
        d["source"] = source
    print(json.dumps(d))
else:
    print("file=" + env["FILE"])
    for label in ask:
        print("ask=" + label)
    for label in deny:
        print("deny=" + label)
'

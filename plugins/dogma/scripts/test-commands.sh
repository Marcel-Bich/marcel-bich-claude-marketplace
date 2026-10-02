#!/bin/bash
# test-commands - read the per-stage test commands of DOGMA-PERMISSIONS.md (read-only).
#
# The "### Test Commands" subsection of the <permissions> block says WHICH command
# runs at which test stage (the Testing / Final Verification checkboxes say WHEN).
# Everything is optional: a missing section or line means Claude decides as before.
# dogma never runs these commands itself - Claude (or another tool) reads them here
# and runs them at the stage.
#
# Section format (one line per stage, command = first `code` span on the line):
#   ### Test Commands
#   - commit: `npm run lint`
#   - push [main, develop]: `npx vitest related --run`
#   - relevant: `npx vitest related --run`
#   - build: `npm run build`
#   - all [main, stage]: `npm test`
#
# Stages: commit, push, relevant, build, all. The optional [branch, ...] filter limits
# a stage to the listed branches. `relevant` is item-scoped and takes no filter (a
# given one is ignored with a warning on stderr).
#
# Usage:
#   test-commands.sh [--json] [dir]            all defined stages
#       kv:   file=..., <stage>=<command>, <stage>_branches=a,b (only when filtered)
#       json: {"file": "...", "stages": {"<stage>": {"command": "...", "branches": null|[...]}}}
#   test-commands.sh get <stage> [branch] [--dir dir]
#       prints the command when the stage is defined and applies (no filter, branch
#       listed in the filter, or no branch given)
#
# dir: where to start the upward search for DOGMA-PERMISSIONS.md (default: $PWD).
#
# Exit codes: 0 ok, 4 no DOGMA-PERMISSIONS.md / no section / stage not applicable
# (prints nothing), 1 bad argument (including an unknown stage).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-permissions.sh
source "$SCRIPT_DIR/lib-permissions.sh"

STAGES="commit push relevant build all"

usage_error() {
    echo "test-commands: $1" >&2
    exit 1
}

is_stage() {
    case " $STAGES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

MODE="kv"
STAGE=""
BRANCH=""
DIR=""

if [ "${1:-}" = "get" ]; then
    MODE="get"
    shift
    [ -n "${1:-}" ] || usage_error "get needs a stage ($STAGES)"
    STAGE="$1"
    shift
    is_stage "$STAGE" || usage_error "unknown stage: $STAGE (expected one of: $STAGES)"
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)
                [ -n "${2:-}" ] || usage_error "--dir needs a value"
                DIR="$2"
                shift 2
                ;;
            -*) usage_error "unknown argument: $1" ;;
            *)
                [ -z "$BRANCH" ] || usage_error "unexpected argument: $1"
                BRANCH="$1"
                shift
                ;;
        esac
    done
else
    if [ "${1:-}" = "--json" ]; then
        MODE="json"
        shift
    fi
    case "${1:-}" in
        -*) usage_error "unknown argument: $1" ;;
    esac
    DIR="${1:-}"
    [ $# -le 1 ] || usage_error "unexpected argument: $2"
fi

if [ -n "$DIR" ]; then
    cd "$DIR" 2>/dev/null || usage_error "no such dir: $DIR"
fi

FILE="$(find_permissions_file)" || exit 4

get_permissions_section "$FILE" | MODE="$MODE" FILE="$FILE" STAGE="$STAGE" BRANCH="$BRANCH" python3 -c '
import json, os, re, sys

STAGES = ["commit", "push", "relevant", "build", "all"]
stages = {}
found = False
in_section = False
for line in sys.stdin:
    s = line.strip()
    if re.match(r"^###\s+test\s+commands\s*$", s, re.I):
        in_section = found = True
        continue
    if not in_section:
        continue
    if s.startswith("##") or s.startswith("</permissions>"):
        in_section = False
        continue
    m = re.match(r"^-\s*([A-Za-z]+)\s*(?:\[([^\]]*)\])?\s*:\s*(.*)$", s)
    if not m:
        continue
    stage = m.group(1).lower()
    if stage not in STAGES:
        print("test-commands: ignoring unknown stage: " + m.group(1), file=sys.stderr)
        continue
    code = re.search(r"`([^`]+)`", m.group(3))
    if not code or not code.group(1).strip():
        continue
    if stage in stages:
        print("test-commands: duplicate stage " + stage + ", keeping the first", file=sys.stderr)
        continue
    branches = None
    if m.group(2) is not None:
        names = [b.strip() for b in m.group(2).split(",") if b.strip()]
        if stage == "relevant":
            if names:
                print("test-commands: relevant takes no branch filter, ignoring [" + m.group(2) + "]", file=sys.stderr)
        elif names:
            branches = names
    stages[stage] = {"command": code.group(1).strip(), "branches": branches}

if not found:
    sys.exit(4)

mode = os.environ["MODE"]
if mode == "get":
    entry = stages.get(os.environ["STAGE"])
    branch = os.environ["BRANCH"]
    if entry is None:
        sys.exit(4)
    if branch and entry["branches"] is not None and branch not in entry["branches"]:
        sys.exit(4)
    print(entry["command"])
elif mode == "json":
    ordered = {k: stages[k] for k in STAGES if k in stages}
    print(json.dumps({"file": os.environ["FILE"], "stages": ordered}))
else:
    print("file=" + os.environ["FILE"])
    for k in STAGES:
        if k in stages:
            print(k + "=" + stages[k]["command"])
            if stages[k]["branches"] is not None:
                print(k + "_branches=" + ",".join(stages[k]["branches"]))
'

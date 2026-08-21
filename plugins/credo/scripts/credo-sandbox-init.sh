#!/bin/bash
# credo-sandbox-init - create a per-item WIP sandbox folder under .credo/sandbox-tmp/.
#
# The sandbox lets the plan / clarify role do WRITING pre-work for a clarify item -
# a measurement, a mockup, a feasibility proof - WITHOUT touching production code and
# WITHOUT git. See the credo `sandbox` skill for the full two-folder model:
#   .credo/sandbox-tmp/  = UNVERSIONED WIP (this script writes here).
#   .credo/sandbox/      = promotion target for accepted, version-worthy artifacts
#                          (reached only via /credo:sandbox-promote, never this script).
#
# This helper only PREPARES the WIP folder. It never writes production code, never
# touches git, and never installs anything.
#
# exclude ownership: credo-init.sh is the single owner of the managed .git/info/exclude
# block. This helper does NOT write that block; it only WARNS when sandbox-tmp is not
# effectively git-excluded, and tells the user to refresh the block via /credo:setup.
#
# Usage:
#   credo-sandbox-init.sh <id>-<slug>     preferred: item id plus a short slug
#   credo-sandbox-init.sh <slug>          a bare folder name is also accepted
#   CREDO_DIR=/path credo-sandbox-init.sh <name>   operate on an explicit .credo dir
#
# The single argument is one folder NAME (not a path). Only [A-Za-z0-9._-] is allowed;
# no slashes and no path traversal.
#
# Idempotent: re-running for the same name never clobbers an existing README/INDEX.
# On success prints the created path plus a next-steps hint and exits 0.
# On any error exits 1 and changes nothing structural.

set -euo pipefail

die() { echo "credo-sandbox-init: $*" >&2; exit 1; }

# --- args --------------------------------------------------------------------
[ "$#" -eq 1 ] || die "usage: credo-sandbox-init.sh <id>-<slug>  (one folder name; allowed chars: A-Za-z0-9._-)"
NAME="$1"

[ -n "$NAME" ] || die "folder name must not be empty"
case "$NAME" in
    */*)          die "folder name must not contain '/': '$NAME'" ;;
    .|..)         die "folder name must not be '.' or '..'" ;;
    *[!A-Za-z0-9._-]*) die "folder name may only contain [A-Za-z0-9._-], got '$NAME'" ;;
esac

# --- locate the target .credo directory (same method as credo-item-move.sh) --
if [ -n "${CREDO_DIR:-}" ]; then
    CREDO_DIR="$CREDO_DIR"
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    CREDO_DIR="$REPO_ROOT/.credo"
else
    CREDO_DIR="$(pwd)/.credo"
fi

SANDBOX_TMP="$CREDO_DIR/sandbox-tmp"
ITEM_DIR="$SANDBOX_TMP/$NAME"

# --- create the WIP folder (idempotent) --------------------------------------
mkdir -p "$ITEM_DIR"

# --- per-item README (template, only if absent) ------------------------------
README="$ITEM_DIR/README.md"
if [ ! -f "$README" ]; then
    tmp="$ITEM_DIR/.README.tmp.$$"
    cat > "$tmp" <<EOF
# Sandbox pre-work: $NAME

WIP sandbox for clarify pre-work. Unversioned (.credo/sandbox-tmp/); no production
code, no git, no installs. Promote accepted artifacts with /credo:sandbox-promote.

## Item

- Item: #<id> (link the clarify item this pre-work unblocks)

## Goal / deliverable

- What concrete artifact this produces (measurement, mockup, feasibility proof).

## What is measured

- What this pre-work establishes.

## What is NOT measured

- The limits of this pre-work - what it deliberately does NOT prove.

## Status

- WIP
EOF
    mv -f "$tmp" "$README"
fi

# --- WIP INDEX for the sandbox-tmp folder (template, only if absent) ----------
INDEX="$SANDBOX_TMP/INDEX.md"
if [ ! -f "$INDEX" ]; then
    tmp="$SANDBOX_TMP/.INDEX.tmp.$$"
    cat > "$tmp" <<'EOF'
# Sandbox WIP map (.credo/sandbox-tmp/)

Unversioned WIP pre-work for clarify items. One folder per item. See the credo
`sandbox` skill for the model and the reference search order (sandbox/ first,
then sandbox-tmp/).

## Items with pre-work

- #<id> <slug> -> deliverables -> key finding -> which clarify question it unblocks

## Items with NO pre-work (and why)

- #<id> <slug> -> pure product decision, nothing to measure
EOF
    mv -f "$tmp" "$INDEX"
fi

# --- exclude safety check (WARN only; never write the managed block) ----------
# credo-init.sh owns the managed .git/info/exclude block. Here we only verify that
# sandbox-tmp is effectively ignored, and warn if it is not. No abort.
if git rev-parse --git-dir >/dev/null 2>&1; then
    if ! git check-ignore -q "$SANDBOX_TMP" 2>/dev/null; then
        echo "credo-sandbox-init: WARNING - sandbox-tmp is not git-excluded; in a version-tracked credo repo run /credo:setup (or credo-init) to refresh the managed exclude block." >&2
    fi
fi

# --- report ------------------------------------------------------------------
echo "credo-sandbox-init: ready at ${ITEM_DIR#"$CREDO_DIR"/} (under $CREDO_DIR)"
echo "credo-sandbox-init: next - set the item's '## Sandbox pre-work' pointer and update sandbox-tmp/INDEX.md."

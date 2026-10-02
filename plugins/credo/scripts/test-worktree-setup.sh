#!/bin/bash
# Tests for credo-worktree-setup.sh and hydra's worktree-setup.sh (same logic).
# Builds a throwaway git repo in a temp dir (removed on exit) with excluded files and
# a .credo/ tree of mixed tracked/untracked content, then checks links, relative
# targets, no overwrite, the copy kind, versioned paths skipped, idempotency.
#
# Usage: bash test-worktree-setup.sh
#   SETUP_SCRIPTS="<path> [<path>...]" overrides which setup scripts are tested
#   (default: credo's and hydra's when present in this repository).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOGMA_FILES="$PLUGINS_DIR/dogma/scripts/worktree-files.sh"
if [ -z "${SETUP_SCRIPTS:-}" ]; then
    SETUP_SCRIPTS="$SCRIPT_DIR/credo-worktree-setup.sh"
    [ -f "$PLUGINS_DIR/hydra/scripts/worktree-setup.sh" ] && SETUP_SCRIPTS="$SETUP_SCRIPTS $PLUGINS_DIR/hydra/scripts/worktree-setup.sh"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-wt-setup-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

# hermetic: no session-folder file to inherit from, no credo pinned project
mkdir -p "$TMP/session"
export DOGMA_SESSION_DIR="$TMP/session" DOGMA_CREDO_CONFIG=none

# isolate git from the user's global/system config (hooks, signing, ...)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}
kind() { # path -> link|file|dir|none
    if [ -L "$1" ]; then echo link; elif [ -f "$1" ]; then echo file; elif [ -d "$1" ]; then echo dir; else echo none; fi
}

make_repo() { # dir
    local r="$1"
    mkdir -p "$r"
    git -C "$r" init -q -b main
    echo readme > "$r/README.md"
    mkdir -p "$r/.credo/items/2_done" "$r/.credo/process/requirements" "$r/CLAUDE" "$r/GUIDES"
    echo tracked > "$r/.credo/items/2_done/1-tracked.md"
    git -C "$r" add README.md .credo/items/2_done/1-tracked.md
    git -C "$r" commit -q -m init
    # excluded / untracked content in the main checkout
    printf 'CLAUDE.md\nCLAUDE/\nGUIDES/\nDOGMA-PERMISSIONS.md\n.credo/config\n.credo/process/\n.credo/items/2_done/2-untracked.md\n.env.local\n' >> "$r/.git/info/exclude"
    echo rules > "$r/CLAUDE.md"
    echo sub > "$r/CLAUDE/CLAUDE.git.md"
    echo guide > "$r/GUIDES/git.md"
    echo cfg > "$r/.credo/config"
    echo req > "$r/.credo/process/requirements/r.md"
    echo untracked > "$r/.credo/items/2_done/2-untracked.md"
    echo secret-free-local > "$r/.env.local"
}

for SUT in $SETUP_SCRIPTS; do
    name="$(basename "$SUT")"
    echo "--- $name ---"

    # ---------- default list ----------
    R="$TMP/$name/repo"
    make_repo "$R"
    WT="$TMP/$name/repo-worktrees/a"
    git -C "$R" worktree add -q -b wt/a "$WT"
    echo mine > "$WT/CLAUDE.md"   # pre-existing path must never be overwritten

    out="$(WORKTREE_FILES_SCRIPT=none "$SUT" "$WT" 2>"$TMP/err")"; rc=$?
    check "$name default: exit" 0 "$rc"
    contains "$name default: source" "source=default" "$out"
    contains "$name default: main path printed" "main=$(cd "$R" && pwd -P)" "$out"
    check "$name default: CLAUDE.md kept (no overwrite)" "mine" "$(cat "$WT/CLAUDE.md")"
    contains "$name default: kept reported" "kept CLAUDE.md (exists)" "$out"
    check "$name default: CLAUDE/ linked whole" link "$(kind "$WT/CLAUDE")"
    check "$name default: GUIDES/ linked whole" link "$(kind "$WT/GUIDES")"
    check "$name default: link is relative" "../../repo/GUIDES" "$(readlink "$WT/GUIDES")"
    check "$name default: link resolves" guide "$(cat "$WT/GUIDES/git.md")"
    check "$name default: missing DOGMA-PERMISSIONS.md skipped" none "$(kind "$WT/DOGMA-PERMISSIONS.md")"
    check "$name default: .credo stays a real dir" dir "$(kind "$WT/.credo")"
    check "$name default: .credo/config linked" link "$(kind "$WT/.credo/config")"
    check "$name default: untracked .credo/process linked whole" link "$(kind "$WT/.credo/process")"
    check "$name default: tracked item checked out, not linked" file "$(kind "$WT/.credo/items/2_done/1-tracked.md")"
    check "$name default: untracked item linked" link "$(kind "$WT/.credo/items/2_done/2-untracked.md")"
    check "$name default: untracked item resolves" untracked "$(cat "$WT/.credo/items/2_done/2-untracked.md")"
    check "$name default: .env.local not in default list" none "$(kind "$WT/.env.local")"
    check "$name default: worktree status clean (links excluded)" "" "$(git -C "$WT" status --porcelain)"

    contains "$name default: anchored exclude for linked dir" "excluded /CLAUDE" "$out"
    check "$name default: exclude line written once" 1 "$(grep -cxF /CLAUDE "$R/.git/info/exclude")"
    check "$name default: main checkout status unchanged" "" "$(git -C "$R" status --porcelain)"

    out2="$(WORKTREE_FILES_SCRIPT=none "$SUT" "$WT" 2>/dev/null)"
    contains "$name rerun: idempotent" "kept CLAUDE (exists)" "$out2"
    check "$name rerun: nothing new linked" "" "$(printf '%s\n' "$out2" | grep '^linked' || true)"

    # ---------- configured list via dogma's reader ----------
    cat > "$R/DOGMA-PERMISSIONS.md" <<'EOF'
# Dogma Permissions
<permissions>
## Workflow Permissions

### Hydra

Parallel work (only if Hydra available, otherwise sequential):
- [x] use Hydra for 2+ independent tasks

Worktree files (excluded files only; versioned files come with git checkout):
- link: CLAUDE.md
- `GUIDES/`
- copy: .env.local
- link: README.md
- link: ../outside
</permissions>
EOF
    WT2="$TMP/$name/repo-worktrees/b"
    git -C "$R" worktree add -q -b wt/b "$WT2"
    out="$(WORKTREE_FILES_SCRIPT="$DOGMA_FILES" "$SUT" "$WT2" 2>"$TMP/err")"; rc=$?
    err="$(cat "$TMP/err")"
    check "$name configured: exit" 0 "$rc"
    contains "$name configured: source" "source=dogma" "$out"
    check "$name configured: CLAUDE.md linked" link "$(kind "$WT2/CLAUDE.md")"
    check "$name configured: bare entry = link" link "$(kind "$WT2/GUIDES")"
    check "$name configured: copy is a real file" file "$(kind "$WT2/.env.local")"
    check "$name configured: copy content" secret-free-local "$(cat "$WT2/.env.local")"
    contains "$name configured: versioned skipped" "skipped README.md (versioned)" "$out"
    contains "$name configured: versioned warning" "README.md is versioned" "$err"
    check "$name configured: README.md is the checked-out file" file "$(kind "$WT2/README.md")"
    contains "$name configured: outside path rejected" "outside the repo" "$err"
    check "$name configured: CLAUDE/ not in list" none "$(kind "$WT2/CLAUDE")"
    check "$name configured: .credo not in list" none "$(kind "$WT2/.credo/config")"
    check "$name configured: main file untouched" rules "$(cat "$R/CLAUDE.md")"

    # ---------- argument errors ----------
    "$SUT" >/dev/null 2>&1; check "$name no args: exit 1" 1 "$?"
    WORKTREE_FILES_SCRIPT=none "$SUT" "$R" >/dev/null 2>&1; check "$name main checkout itself: exit 2" 2 "$?"
    mkdir -p "$TMP/$name/plain"
    WORKTREE_FILES_SCRIPT=none "$SUT" "$TMP/$name/plain" >/dev/null 2>&1; check "$name not a repo: exit 2" 2 "$?"
done

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

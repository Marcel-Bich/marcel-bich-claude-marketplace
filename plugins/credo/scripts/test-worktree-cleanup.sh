#!/bin/bash
# Tests for credo-worktree-cleanup.sh. Builds a throwaway git repo with several linked
# worktrees in a temp dir (removed on exit): merged+clean removed (branch deleted,
# symlink targets in the main checkout survive), unmerged kept, dirty kept, fresh
# (never committed) kept, locked kept, the worktree the command runs in kept, the main
# worktree never touched, --dry-run removes nothing, JSON output valid.
# Usage: bash test-worktree-cleanup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-worktree-cleanup.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-wt-cleanup-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

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
exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
branch_exists() { if git -C "$R" show-ref --verify --quiet "refs/heads/$1"; then echo yes; else echo no; fi; }

R="$TMP/repo"
W="$TMP/repo-worktrees"
mkdir -p "$R"
git -C "$R" init -q -b main
echo base > "$R/file.txt"
git -C "$R" add file.txt
git -C "$R" commit -q -m init
# excluded files in the main checkout that worktrees link to
printf 'CLAUDE.md\n.credo/\n' >> "$R/.git/info/exclude"
echo rules > "$R/CLAUDE.md"
mkdir -p "$R/.credo/items"
echo item > "$R/.credo/items/1-a.md"

commit_in() { # worktree file content
    echo "$3" > "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q -m "$2"
}

# merged + clean, with untracked scratch and setup symlinks (file and dir)
git -C "$R" worktree add -q -b wt/merged "$W/merged"
commit_in "$W/merged" merged.txt m
git -C "$R" merge -q --no-ff -m "merge merged" wt/merged
mkdir -p "$W/merged/cache"
echo scratch > "$W/merged/cache/tmp.bin"
ln -s ../../repo/CLAUDE.md "$W/merged/CLAUDE.md"
ln -s ../../repo/.credo "$W/merged/.credo"

# unmerged
git -C "$R" worktree add -q -b wt/unmerged "$W/unmerged"
commit_in "$W/unmerged" unmerged.txt u

# merged but dirty (tracked change)
git -C "$R" worktree add -q -b wt/dirty "$W/dirty"
commit_in "$W/dirty" dirty.txt d
git -C "$R" merge -q --no-ff -m "merge dirty" wt/dirty
echo changed >> "$W/dirty/dirty.txt"

# fresh: never committed, just created (an agent may be starting in it)
git -C "$R" worktree add -q -b wt/fresh "$W/fresh"
# never committed with untracked work
git -C "$R" worktree add -q -b wt/fresh-work "$W/fresh-work"
echo newfile > "$W/fresh-work/new.txt"

# merged + clean but locked
git -C "$R" worktree add -q -b wt/locked "$W/locked"
commit_in "$W/locked" locked.txt l
git -C "$R" merge -q --no-ff -m "merge locked" wt/locked
git -C "$R" worktree lock "$W/locked"

# merged + clean, used as the cwd of a run
git -C "$R" worktree add -q -b wt/here "$W/here"
commit_in "$W/here" here.txt h
git -C "$R" merge -q --no-ff -m "merge here" wt/here

# ---------- dry run ----------
out="$("$SUT" --dry-run "$R")"; rc=$?
check "dry-run exit" 0 "$rc"
contains "dry-run base" "base=main" "$out"
contains "dry-run merged candidate" "candidate $W/merged branch=wt/merged reason=merged into main, clean" "$out"
contains "dry-run unmerged kept" "kept $W/unmerged branch=wt/unmerged reason=not merged into main" "$out"
contains "dry-run dirty kept" "kept $W/dirty branch=wt/dirty reason=uncommitted changes to tracked files" "$out"
contains "dry-run fresh kept" "kept $W/fresh branch=wt/fresh reason=no commits yet" "$out"
contains "dry-run locked kept" "kept $W/locked branch=wt/locked reason=locked" "$out"
check "dry-run main not listed" "" "$(printf '%s\n' "$out" | grep " $R branch=" || true)"
check "dry-run removed nothing" "yes yes yes yes yes" "$(exists "$W/merged") $(exists "$W/unmerged") $(exists "$W/dirty") $(exists "$W/fresh") $(exists "$W/here")"
check "dry-run branch kept" yes "$(branch_exists wt/merged)"

# fresh-hours 0: a never-committed, untouched worktree becomes a candidate
out="$("$SUT" --dry-run --fresh-hours 0 "$R")"
contains "fresh-hours 0: fresh candidate" "candidate $W/fresh branch=wt/fresh reason=never committed" "$out"
contains "fresh-hours 0: untracked work kept" "kept $W/fresh-work branch=wt/fresh-work reason=never committed but has 1 untracked file(s)" "$out"

# JSON
json="$("$SUT" --dry-run --json "$R")"
check "json valid" ok "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("ok" if d["dry_run"] and d["base"]=="main" else "bad")' 2>&1)"

# ---------- real run from inside a merged worktree ----------
out="$(cd "$W/here" && "$SUT")"; rc=$?
check "run exit" 0 "$rc"
contains "run merged removed" "removed $W/merged branch=wt/merged" "$out"
contains "run branch deleted" "branch_deleted=wt/merged" "$out"
contains "run cwd worktree kept" "kept $W/here branch=wt/here reason=this command runs inside it" "$out"
check "merged worktree dir gone" no "$(exists "$W/merged")"
check "merged branch gone" no "$(branch_exists wt/merged)"
check "symlinked file target survives" rules "$(cat "$R/CLAUDE.md")"
check "symlinked dir target survives" item "$(cat "$R/.credo/items/1-a.md")"
check "unmerged kept" "yes yes" "$(exists "$W/unmerged") $(branch_exists wt/unmerged)"
check "dirty kept with its change" "d
changed" "$(cat "$W/dirty/dirty.txt")"
check "fresh kept" yes "$(exists "$W/fresh")"
check "fresh-work kept" yes "$(exists "$W/fresh-work/new.txt")"
check "locked kept" yes "$(exists "$W/locked")"
check "here kept" yes "$(exists "$W/here")"
check "main worktree intact" "base" "$(cat "$R/file.txt")"
check "main worktree clean" "" "$(git -C "$R" status --porcelain)"
check "worktree list lost exactly one" 7 "$(git -C "$R" worktree list | wc -l | tr -d ' ')"

# second run from the main checkout removes "here" too; idempotent otherwise
out="$("$SUT" "$R")"
contains "second run removes here" "removed $W/here branch=wt/here" "$out"
check "second run nothing else removed" 1 "$(printf '%s\n' "$out" | grep -c '^removed' || true)"
out="$("$SUT" "$R")"
check "third run removes nothing" 0 "$(printf '%s\n' "$out" | grep -c '^removed' || true)"

# a manually deleted worktree dir is only pruned from the admin data
git -C "$R" worktree add -q -b wt/gone "$W/gone"
rm -rf -- "$W/gone"
"$SUT" "$R" >/dev/null
check "missing dir pruned" 0 "$(git -C "$R" worktree list --porcelain | grep -c "$W/gone" || true)"

# ---------- wiring: credo-item-move.sh runs the cleanup at item close ----------
MOVE="$SCRIPT_DIR/credo-item-move.sh"
R2="$TMP/repo2"
W2="$TMP/repo2-worktrees"
mkdir -p "$R2"
git -C "$R2" init -q -b main
echo base > "$R2/f"; git -C "$R2" add f; git -C "$R2" commit -q -m init
printf '.credo/\nDOGMA-PERMISSIONS.md\n' >> "$R2/.git/info/exclude"
mkdir -p "$R2/.credo/items/1_todo/2_go" "$R2/.credo/items/2_done"
for i in 1 2 3; do printf -- '---\nid: %s\ntitle: t\n---\n' "$i" > "$R2/.credo/items/1_todo/2_go/$i-t.md"; done
git -C "$R2" worktree add -q -b wt/x "$W2/x"
commit_in "$W2/x" x.txt x
git -C "$R2" merge -q --no-ff -m "merge x" wt/x
set_cleanup() { # state
    printf '<permissions>\n## Workflow Permissions\n\n### Hydra\n- [%s] clean up merged worktrees automatically\n</permissions>\n' "$1" > "$R2/DOGMA-PERMISSIONS.md"
}
set_cleanup ' '
out="$(cd "$R2" && CREDO_DIR="$R2/.credo" "$MOVE" 1 done 2>&1)"
check "move [ ]: no cleanup output" "" "$(printf '%s\n' "$out" | grep 'worktree cleanup' || true)"
check "move [ ]: worktree kept" yes "$(exists "$W2/x")"
set_cleanup '?'
out="$(cd "$R2" && CREDO_DIR="$R2/.credo" "$MOVE" 2 done 2>&1)"
contains "move [?]: candidate listed" "worktree cleanup: candidate $W2/x" "$out"
contains "move [?]: ask hint" "ask the user" "$out"
check "move [?]: worktree kept" yes "$(exists "$W2/x")"
set_cleanup x
out="$(cd "$R2" && CREDO_DIR="$R2/.credo" "$MOVE" 3 done 2>&1)"
contains "move [x]: removed" "worktree cleanup: removed $W2/x" "$out"
check "move [x]: worktree gone" no "$(exists "$W2/x")"
check "move [x]: item moved" yes "$(exists "$R2/.credo/items/2_done/3-t.md")"

# argument errors
"$SUT" --bogus >/dev/null 2>&1; check "bad arg exit 1" 1 "$?"
mkdir -p "$TMP/plain"
"$SUT" "$TMP/plain" >/dev/null 2>&1; check "not a repo exit 2" 2 "$?"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

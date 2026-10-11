#!/bin/bash
# Tests for credo-worktree-cleanup.sh. Builds a throwaway git repo with several linked
# worktrees in a temp dir (removed on exit): merged+clean removed (branch deleted,
# symlink targets in the main checkout survive), unmerged kept, dirty kept, fresh
# (never committed) kept, a branch fast-forwarded from main without a commit of its own
# kept while fresh, own commits removed even when fresh, locked kept, the worktree the
# command runs in kept, the main
# worktree never touched, --dry-run removes nothing, JSON output valid. Opt-out: a
# locked worktree is kept and reported with its lock reason (normal, --dry-run, JSON),
# --keep <path|branch> (repeatable) is a one-off exception, --list-locked lists locks,
# and an unlocked worktree is cleaned up again.
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
git -C "$R" worktree lock --reason "keep: owner" "$W/locked"

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
contains "dry-run locked kept with reason" "kept $W/locked branch=wt/locked reason=locked: keep: owner" "$out"
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
check "json locked reason" "kept|keep: owner" "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=[w for w in d["worktrees"] if w["path"].endswith("/locked")][0]; print(e["status"]+"|"+e.get("lock_reason",""))' 2>&1)"

# --list-locked: only locked worktrees with their reason, removes nothing
out="$("$SUT" --list-locked "$R")"; rc=$?
check "list-locked exit" 0 "$rc"
check "list-locked output" "locked $W/locked branch=wt/locked reason=keep: owner" "$out"
json="$("$SUT" --list-locked --json "$R")"
check "list-locked json" "1|keep: owner" "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(len(d["locked"]))+"|"+d["locked"][0]["reason"])' 2>&1)"
check "list-locked removed nothing" yes "$(exists "$W/merged")"

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
contains "run locked reported" "kept $W/locked branch=wt/locked reason=locked: keep: owner" "$out"
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

# ---------- fresh worktrees: a fast-forward from main is not an own commit ----------
R5="$TMP/repo5"
W5="$TMP/repo5-worktrees"
mkdir -p "$R5"
git -C "$R5" init -q -b main
echo base > "$R5/f"; git -C "$R5" add f; git -C "$R5" commit -q -m init
# (a) fresh, never committed, no edits: kept
git -C "$R5" worktree add -q -b wt/pristine "$W5/pristine"
# (a2) fresh, fast-forwarded to a moved main (the reflog gets a second entry), no commit of its own
git -C "$R5" worktree add -q -b wt/synced "$W5/synced"
echo advance > "$R5/g"; git -C "$R5" add g; git -C "$R5" commit -q -m advance
git -C "$W5/synced" merge -q --ff-only main
# (b) own commit, fast-forwarded into main: merged and clean, removed even though it is fresh
git -C "$R5" worktree add -q -b wt/ffown "$W5/ffown"
commit_in "$W5/ffown" ff.txt ff
git -C "$R5" merge -q --ff-only wt/ffown
# (b2) own commit, merged with --no-ff: removed even though it is fresh
git -C "$R5" worktree add -q -b wt/nffown "$W5/nffown"
commit_in "$W5/nffown" nff.txt nff
git -C "$R5" merge -q --no-ff -m "merge nff" wt/nffown

out="$("$SUT" --dry-run "$R5")"
contains "fresh pristine kept" "kept $W5/pristine branch=wt/pristine reason=no commits yet (fresh worktree)" "$out"
contains "fresh ff-synced kept" "kept $W5/synced branch=wt/synced reason=no commits yet (fresh worktree)" "$out"
contains "fresh own commit ff-merged is a candidate" "candidate $W5/ffown branch=wt/ffown reason=merged into main, clean" "$out"
contains "fresh own commit no-ff-merged is a candidate" "candidate $W5/nffown branch=wt/nffown reason=merged into main, clean" "$out"
out="$("$SUT" --dry-run --fresh-hours 0 "$R5")"
contains "fresh-hours 0: ff-synced without commits is a candidate" "candidate $W5/synced branch=wt/synced reason=never committed" "$out"
out="$("$SUT" "$R5")"
check "real run: pristine and ff-synced kept" "yes yes" "$(exists "$W5/pristine") $(exists "$W5/synced")"
contains "real run: ff-merged own commit removed" "removed $W5/ffown branch=wt/ffown" "$out"
contains "real run: no-ff-merged own commit removed" "removed $W5/nffown branch=wt/nffown" "$out"

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
# stable id §36ch: reworded line in another subsection wins over a stale text line
printf -- '---\nid: 4\ntitle: t\n---\n' > "$R2/.credo/items/1_todo/2_go/4-t.md"
git -C "$R2" worktree add -q -b wt/y "$W2/y"
commit_in "$W2/y" y.txt y
git -C "$R2" merge -q --no-ff -m "merge y" wt/y
printf '<permissions>\n## Workflow Permissions\n\n### Hydra\n- [ ] clean up merged worktrees automatically\n\n### Aufräumen\n- [x] (§36ch) Gemergte Worktrees ohne Rückfrage entfernen\n</permissions>\n' > "$R2/DOGMA-PERMISSIONS.md"
out="$(cd "$R2" && CREDO_DIR="$R2/.credo" "$MOVE" 4 done 2>&1)"
contains "move id [x] reworded: removed" "worktree cleanup: removed $W2/y" "$out"
check "move id [x] reworded: worktree gone" no "$(exists "$W2/y")"

# ---------- opt-out: lock and --keep ----------
R3="$TMP/repo3"
W3="$TMP/repo3-worktrees"
mkdir -p "$R3"
git -C "$R3" init -q -b main
echo base > "$R3/f"; git -C "$R3" add f; git -C "$R3" commit -q -m init
for n in a b c d e g; do
    git -C "$R3" worktree add -q -b "wt/$n" "$W3/$n"
    commit_in "$W3/$n" "$n.txt" "$n"
    git -C "$R3" merge -q --no-ff -m "merge $n" "wt/$n"
done
branch3_exists() { if git -C "$R3" show-ref --verify --quiet "refs/heads/$1"; then echo yes; else echo no; fi; }
git -C "$R3" worktree lock --reason "keep: owner" "$W3/a"
git -C "$R3" worktree lock "$W3/b"   # lock without a reason

out="$("$SUT" --dry-run "$R3")"
contains "lock with reason reported" "kept $W3/a branch=wt/a reason=locked: keep: owner" "$out"
contains "lock without reason reported" "kept $W3/b branch=wt/b reason=locked: no reason given" "$out"
contains "unlocked is a candidate" "candidate $W3/c branch=wt/c" "$out"

# --keep by path and by branch (repeatable), one-off, not persistent
out="$("$SUT" --dry-run --keep "$W3/c" --keep wt/d "$R3")"
contains "keep by path" "kept $W3/c branch=wt/c reason=keep requested (--keep)" "$out"
contains "keep by branch" "kept $W3/d branch=wt/d reason=keep requested (--keep)" "$out"
contains "keep leaves others" "candidate $W3/e branch=wt/e" "$out"
out="$("$SUT" --dry-run --keep "$W3/c/" "$R3")"
contains "keep path with trailing slash" "kept $W3/c branch=wt/c reason=keep requested (--keep)" "$out"
out="$("$SUT" --dry-run --keep nope "$R3" 2>&1 >/dev/null)"
contains "keep without match warns" "--keep matches no worktree: nope" "$out"
out="$("$SUT" --keep "$W3/c" --keep wt/d "$R3")"
contains "real run: keep path kept" "kept $W3/c branch=wt/c reason=keep requested (--keep)" "$out"
check "real run: keep dirs survive" "yes yes yes yes" "$(exists "$W3/c") $(exists "$W3/d") $(branch3_exists wt/c) $(branch3_exists wt/d)"
check "real run: locked survive" "yes yes yes yes" "$(exists "$W3/a") $(exists "$W3/b") $(branch3_exists wt/a) $(branch3_exists wt/b)"
check "real run: unlocked, not kept removed" "no no" "$(exists "$W3/e") $(exists "$W3/g")"
json="$("$SUT" --dry-run --json --keep wt/c "$R3")"
check "json keep status" "kept|keep requested (--keep)" "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=[w for w in d["worktrees"] if w["branch"]=="wt/c"][0]; print(e["status"]+"|"+e["reason"])' 2>&1)"
out="$("$SUT" --list-locked "$R3")"
contains "list-locked reason" "locked $W3/a branch=wt/a reason=keep: owner" "$out"
contains "list-locked no reason" "locked $W3/b branch=wt/b reason=no reason given" "$out"
check "list-locked excludes unlocked" "" "$(printf '%s\n' "$out" | grep -E 'wt/(c|d)' || true)"

# a locked worktree whose directory is gone is not pruned (the lock protects the admin entry)
git -C "$R3" worktree add -q -b wt/h "$W3/h"
git -C "$R3" worktree lock --reason "keep: owner" "$W3/h"
rm -rf -- "$W3/h"
out="$("$SUT" "$R3")"
contains "locked missing dir reported as locked" "kept $W3/h branch=wt/h reason=locked: keep: owner" "$out"
check "locked missing dir entry survives" 1 "$(git -C "$R3" worktree list --porcelain | grep -c "$W3/h" || true)"
git -C "$R3" worktree unlock "$W3/h"
git -C "$R3" worktree prune

# unlock releases the keep: cleaned up again
git -C "$R3" worktree unlock "$W3/a"
out="$("$SUT" "$R3")"
contains "unlocked removed" "removed $W3/a branch=wt/a" "$out"
check "unlocked gone, still-locked kept" "no yes" "$(exists "$W3/a") $(exists "$W3/b")"

# ---------- --keep edge cases: locked, cwd, symlink, json warning, path vs branch, multi-line lock ----------
R4="$TMP/repo4"
W4="$TMP/repo4-worktrees"
mkdir -p "$R4"
git -C "$R4" init -q -b main
echo base > "$R4/f"; git -C "$R4" add f; git -C "$R4" commit -q -m init
mk4() { # path branch
    git -C "$R4" worktree add -q -b "$2" "$1"
    commit_in "$1" "$(basename "$1").txt" x
    git -C "$R4" merge -q --no-ff -m "merge $2" "$2"
}
mk4 "$W4/lk" wt/lk
mk4 "$W4/cw" wt/cw
mk4 "$W4/sl" wt/sl
mk4 "$W4/pa" wt/pa
mk4 "$W4/pb" pa            # branch named like the directory of another worktree
mk4 "$W4/ml" wt/ml
git -C "$R4" worktree lock --reason "keep: owner" "$W4/lk"
git -C "$R4" worktree lock --reason "$(printf 'first line\nbranch refs/heads/evil\tsecond')" "$W4/ml"

# --keep naming a locked worktree: no false warning, reason stays the lock reason
out="$("$SUT" --dry-run --keep "$W4/lk" "$R4" 2>&1 >/dev/null)"
check "keep locked by path: no warning" "" "$out"
out="$("$SUT" --dry-run --keep wt/lk "$R4" 2>&1 >/dev/null)"
check "keep locked by branch: no warning" "" "$out"
out="$("$SUT" --dry-run --keep "$W4/lk" "$R4" 2>/dev/null)"
contains "keep locked: reason stays the lock" "kept $W4/lk branch=wt/lk reason=locked: keep: owner" "$out"

# --keep naming the worktree the command runs in: no false warning
out="$(cd "$W4/cw" && "$SUT" --dry-run --keep "$W4/cw" 2>&1 >/dev/null)"
check "keep cwd worktree by path: no warning" "" "$out"
out="$(cd "$W4/cw" && "$SUT" --dry-run --keep wt/cw 2>&1 >/dev/null)"
check "keep cwd worktree by branch: no warning" "" "$out"
out="$(cd "$W4/cw" && "$SUT" --dry-run --keep "$W4/cw" 2>/dev/null)"
contains "keep cwd: reported as running inside" "kept $W4/cw branch=wt/cw reason=this command runs inside it" "$out"

# --keep via a symlinked path
ln -s "$W4/sl" "$TMP/link-sl"
out="$("$SUT" --dry-run --keep "$TMP/link-sl" "$R4" 2>&1)"
contains "keep symlinked path: kept" "kept $W4/sl branch=wt/sl reason=keep requested (--keep)" "$out"
check "keep symlinked path: no warning" "" "$(printf '%s\n' "$out" | grep 'matches no worktree' || true)"

# JSON mode: warning still on stderr, stdout stays valid JSON
out="$("$SUT" --dry-run --json --keep nope "$R4" 2>&1 >/dev/null)"
contains "json keep without match warns on stderr" "--keep matches no worktree: nope" "$out"
json="$("$SUT" --dry-run --json --keep nope "$R4" 2>/dev/null)"
check "json keep without match: stdout valid" "ok" "$(printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' 2>&1)"

# a --keep that is an existing directory (a worktree path) wins over a branch of the same name
out="$(cd "$W4" && "$SUT" --dry-run --keep pa "$R4" 2>&1)"
contains "keep path wins: path worktree kept" "kept $W4/pa branch=wt/pa reason=keep requested (--keep)" "$out"
contains "keep path wins: same-named branch not kept" "candidate $W4/pb branch=pa" "$out"
out="$("$SUT" --dry-run --keep pa "$R4" 2>&1)"
contains "keep branch when no such dir: kept" "kept $W4/pb branch=pa reason=keep requested (--keep)" "$out"

# multi-line lock reason: one clean line, control chars sanitized, branch not spoofed
out="$("$SUT" --dry-run "$R4")"
check "multi-line lock: exactly one report line" 1 "$(printf '%s\n' "$out" | grep -c "^kept $W4/ml " || true)"
contains "multi-line lock: sanitized reason" "kept $W4/ml branch=wt/ml reason=locked: first line branch refs/heads/evil second" "$out"
out="$("$SUT" --list-locked "$R4")"
contains "multi-line lock: list-locked sanitized" "locked $W4/ml branch=wt/ml reason=first line branch refs/heads/evil second" "$out"
check "multi-line lock: list-locked line count" 2 "$(printf '%s\n' "$out" | grep -c '^locked ' || true)"
json="$("$SUT" --dry-run --json "$R4")"
check "multi-line lock: json lock_reason" "wt/ml|first line branch refs/heads/evil second" "$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=[w for w in d["worktrees"] if w["path"].endswith("/ml")][0]; print(e["branch"]+"|"+e["lock_reason"])' 2>&1)"

# argument errors
"$SUT" --bogus >/dev/null 2>&1; check "bad arg exit 1" 1 "$?"
"$SUT" --keep >/dev/null 2>&1; check "--keep without value exit 1" 1 "$?"
mkdir -p "$TMP/plain"
"$SUT" "$TMP/plain" >/dev/null 2>&1; check "not a repo exit 2" 2 "$?"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

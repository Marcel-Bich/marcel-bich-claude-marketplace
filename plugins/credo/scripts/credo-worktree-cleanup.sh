#!/bin/bash
# credo-worktree-cleanup - remove linked worktrees whose work is merged and clean.
#
# Parallel tracks leave worktrees behind; without cleanup they pile up (dozens of
# worktrees, gigabytes). This removes exactly those that are safe to remove and
# reports every other one with the reason it was kept. Every run covers ALL worktrees
# of the repository, so the first run also sweeps the backlog.
#
# A worktree is a candidate only when ALL of these hold:
#   - it is not the main worktree, not the worktree this command runs in, not locked,
#     not on a detached HEAD, its directory exists, and its branch is not the base
#   - its branch is fully merged into the base branch (branch tip is an ancestor)
#   - it has no changes to tracked files (staged or unstaged); untracked agent scratch
#     (cache/, the setup symlinks, ...) goes with it
#   - a branch that never got a commit (its reflog holds only the creation entry) may
#     still be in use by an agent that just started: it is kept while younger than
#     --fresh-hours (default 24) or while it has untracked, non-ignored files, and it
#     is kept when its age cannot be determined
#
# Removal uses `git worktree remove --force <path>` (git unlinks symlinks, it never
# follows them, so link targets in the main checkout survive), then `git branch -d`
# (never -D). Afterwards `git worktree prune` drops admin entries of worktree
# directories that no longer exist. Nothing else is ever deleted.
#
# Usage:
#   credo-worktree-cleanup.sh [--dry-run] [--json] [--base <branch>] [--fresh-hours N] [dir]
#     --dry-run      list candidates and kept worktrees, remove nothing
#     --json         one JSON object instead of key=value lines
#     --base         branch the work must be merged into (default: the branch checked
#                    out in the main worktree)
#     dir            any directory inside the repository (default: $PWD)
#
# Output (kv): base=<branch>, then per worktree
#   candidate <path> branch=<b> reason=<why>       (--dry-run)
#   removed <path> branch=<b> reason=<why>         (+ branch_deleted=<b> or branch_kept=<b>)
#   failed <path> branch=<b> reason=<git error>
#   kept <path> branch=<b> reason=<why>
# Exit codes: 0 done (also with nothing to do), 1 bad arguments, 2 not a git repository
# or no base branch (main worktree on a detached HEAD and no --base).

set -euo pipefail

die() { echo "credo-worktree-cleanup: $1" >&2; exit "${2:-1}"; }

DRY=0
MODE="kv"
BASE=""
FRESH_HOURS=24
DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY=1 ;;
        --json) MODE="json" ;;
        --base) [ -n "${2:-}" ] || die "--base needs a branch"; BASE="$2"; shift ;;
        --fresh-hours)
            case "${2:-}" in ''|*[!0-9]*) die "--fresh-hours needs a whole number" ;; esac
            FRESH_HOURS="$2"; shift ;;
        -*) die "unknown argument: $1" ;;
        *) [ -z "$DIR" ] || die "unexpected argument: $1"; DIR="$1" ;;
    esac
    shift
done
DIR="${DIR:-$PWD}"
[ -d "$DIR" ] || die "no such dir: $DIR"

git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $DIR" 2
PORCELAIN="$(git -C "$DIR" worktree list --porcelain)"
MAIN="$(printf '%s\n' "$PORCELAIN" | sed -n '1s/^worktree //p')"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || die "cannot determine the main worktree" 2
MAIN_REAL="$(cd "$MAIN" && pwd -P)"
HERE="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
HERE_REAL=""
[ -n "$HERE" ] && HERE_REAL="$(cd "$HERE" && pwd -P)"

if [ -z "$BASE" ]; then
    BASE="$(printf '%s\n' "$PORCELAIN" | awk 'NF==0{exit} /^branch /{sub(/^branch refs\/heads\//,""); print; exit}')"
    [ -n "$BASE" ] || die "the main worktree is on a detached HEAD - pass --base <branch>" 2
fi
git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BASE" || die "no such branch: $BASE" 2

NOW="$(date +%s)"
SEP=$'\x1f'  # field separator (not whitespace, so empty fields survive read)
RESULTS=()   # status SEP path SEP branch SEP reason SEP branch-result

add() { RESULTS+=("$1$SEP$2$SEP$3$SEP$4$SEP${5:-}"); }

# Branch age in hours when its reflog holds only the creation entry; "" when the
# branch got further updates (commits); "unknown" when there is no reflog.
fresh_age_hours() { # branch
    local entries count stamp
    entries="$(git -C "$MAIN" reflog show --date=unix --format='%gd' "refs/heads/$1" -- 2>/dev/null || true)"
    count="$(printf '%s' "$entries" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
        echo "unknown"
    elif [ "$count" -eq 1 ]; then
        stamp="$(printf '%s' "$entries" | sed -n 's/.*@{\([0-9]*\)}.*/\1/p')"
        if [ -n "$stamp" ]; then echo $(( (NOW - stamp) / 3600 )); else echo "unknown"; fi
    fi
}

evaluate() { # path branch locked prunable
    local path="$1" branch="$2" locked="$3" prunable="$4" real age untracked
    if [ -n "$prunable" ] || [ ! -d "$path" ]; then
        add kept "$path" "$branch" "directory missing - only its admin entry is pruned"
        return
    fi
    real="$(cd "$path" && pwd -P)"
    if [ "$real" = "$MAIN_REAL" ]; then return; fi
    if [ "$real" = "$HERE_REAL" ]; then add kept "$path" "$branch" "this command runs inside it"; return; fi
    if [ -n "$locked" ]; then add kept "$path" "$branch" "locked"; return; fi
    if [ -z "$branch" ]; then add kept "$path" "" "detached HEAD"; return; fi
    if [ "$branch" = "$BASE" ]; then add kept "$path" "$branch" "is the base branch"; return; fi
    if ! git -C "$MAIN" merge-base --is-ancestor "refs/heads/$branch" "refs/heads/$BASE" 2>/dev/null; then
        add kept "$path" "$branch" "not merged into $BASE"
        return
    fi
    if [ -n "$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null)" ] \
        || ! git -C "$path" status --porcelain >/dev/null 2>&1; then
        add kept "$path" "$branch" "uncommitted changes to tracked files"
        return
    fi
    untracked="$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | grep -c . || true)"
    age="$(fresh_age_hours "$branch")"
    if [ "$age" = "unknown" ]; then
        add kept "$path" "$branch" "no commits and no branch history - may be in use"
        return
    fi
    if [ -n "$age" ]; then
        if [ "$age" -lt "$FRESH_HOURS" ]; then
            add kept "$path" "$branch" "no commits yet, created ${age}h ago - may be in use"
            return
        fi
        if [ "$untracked" -gt 0 ]; then
            add kept "$path" "$branch" "never committed but has $untracked untracked file(s)"
            return
        fi
        add candidate "$path" "$branch" "never committed, unused for ${age}h"
        return
    fi
    if [ "$untracked" -gt 0 ]; then
        add candidate "$path" "$branch" "merged into $BASE, clean ($untracked untracked file(s) go with it)"
    else
        add candidate "$path" "$branch" "merged into $BASE, clean"
    fi
}

# --- walk all worktrees (porcelain blocks are separated by blank lines) -------
wt_path="" wt_branch="" wt_locked="" wt_prunable=""
flush() {
    if [ -n "$wt_path" ]; then evaluate "$wt_path" "$wt_branch" "$wt_locked" "$wt_prunable"; fi
    wt_path="" wt_branch="" wt_locked="" wt_prunable=""
}
while IFS= read -r line; do
    case "$line" in
        "worktree "*) flush; wt_path="${line#worktree }" ;;
        "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
        locked|"locked "*) wt_locked=1 ;;
        prunable|"prunable "*) wt_prunable=1 ;;
        "") flush ;;
    esac
done <<< "$PORCELAIN"
flush

# --- remove (only verified candidates) ----------------------------------------
if [ "$DRY" -eq 0 ]; then
    for i in "${!RESULTS[@]}"; do
        IFS="$SEP" read -r status path branch reason _ <<< "${RESULTS[$i]}"
        [ "$status" = "candidate" ] || continue
        real="$(cd "$path" 2>/dev/null && pwd -P || true)"
        case "$real" in
            ""|/|"$MAIN_REAL"|"$HOME"|"$(dirname "$MAIN_REAL")")
                RESULTS[$i]="failed$SEP$path$SEP$branch${SEP}refused: unsafe path$SEP"
                continue ;;
        esac
        if err="$(git -C "$MAIN" worktree remove --force -- "$path" 2>&1)"; then
            if git -C "$MAIN" branch -d -- "$branch" >/dev/null 2>&1; then
                RESULTS[$i]="removed$SEP$path$SEP$branch$SEP$reason${SEP}branch_deleted"
            else
                RESULTS[$i]="removed$SEP$path$SEP$branch$SEP$reason${SEP}branch_kept"
            fi
        else
            RESULTS[$i]="failed$SEP$path$SEP$branch$SEP$(printf '%s' "$err" | tr '\n\037' '  ')$SEP"
        fi
    done
    git -C "$MAIN" worktree prune 2>/dev/null || true
fi

# --- report ---------------------------------------------------------------------
if [ "$MODE" = "json" ]; then
    printf '%s\n' "${RESULTS[@]+"${RESULTS[@]}"}" | BASE="$BASE" DRY="$DRY" MAIN="$MAIN" python3 -c '
import json, os, sys
items = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    status, path, branch, reason, extra = (line.split("\x1f") + [""] * 5)[:5]
    entry = {"status": status, "path": path, "branch": branch or None, "reason": reason}
    if extra:
        entry["branch_deleted"] = extra == "branch_deleted"
    items.append(entry)
print(json.dumps({"base": os.environ["BASE"], "main": os.environ["MAIN"],
                  "dry_run": os.environ["DRY"] == "1", "worktrees": items}))'
else
    echo "base=$BASE"
    for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
        IFS="$SEP" read -r status path branch reason extra <<< "$r"
        echo "$status $path branch=$branch reason=$reason"
        case "$extra" in
            branch_deleted) echo "branch_deleted=$branch" ;;
            branch_kept) echo "branch_kept=$branch" ;;
        esac
    done
fi

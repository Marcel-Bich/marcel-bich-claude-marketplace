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
#     not named by --keep, not on a detached HEAD, its directory exists, and its branch
#     is not the base
#   - its branch is fully merged into the base branch (branch tip is an ancestor)
#   - it has no changes to tracked files (staged or unstaged); untracked agent scratch
#     (cache/, the setup symlinks, ...) goes with it
#   - a branch without a commit of its own (its reflog has no commit, cherry-pick or revert
#     entry; a fast-forward from the base does not count) may still be in use by an agent
#     that just started: it is kept while younger than --fresh-hours (default 24) or while
#     it has untracked, non-ignored files, and it is kept when its age cannot be determined
#
# Opt-out: a worktree the owner wants to keep is locked (`git worktree lock --reason
# "keep: owner" <path>`). A locked worktree is never removed and is reported with its lock
# reason (`kept <path> branch=<b> reason=locked: <lock reason>`), also on --dry-run. Release
# it with `git worktree unlock <path>`. `--keep <path|branch>` is the one-off variant for a
# single run (a --keep string that names an existing directory is taken as a path, so a
# branch of the same name is not kept as well). `--list-locked` prints only the locked
# worktrees with their reasons. Lock reasons are read from the worktree admin directory
# (`<git-common-dir>/worktrees/<id>/locked`), not from the line-based porcelain output, so a
# multi-line reason cannot break parsing; control characters in a reason are shown as spaces.
#
# Removal uses `git worktree remove --force <path>` (git unlinks symlinks, it never
# follows them, so link targets in the main checkout survive), then `git branch -d`
# (never -D). Afterwards `git worktree prune` drops admin entries of worktree
# directories that no longer exist. Nothing else is ever deleted.
#
# Usage:
#   credo-worktree-cleanup.sh [--dry-run] [--json] [--base <branch>] [--fresh-hours N]
#                             [--keep <path|branch>]... [dir]
#   credo-worktree-cleanup.sh --list-locked [--json] [dir]
#     --dry-run      list candidates and kept worktrees, remove nothing
#     --keep         keep this worktree (by path or branch name) in this run only;
#                    repeatable; an existing directory is matched as a path first; a --keep
#                    that matches no worktree is warned about on stderr
#     --list-locked  list the locked worktrees and their lock reasons, nothing else
#                    (does not need a base branch)
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
#     a locked worktree: kept <path> branch=<b> reason=locked: <lock reason>
# --list-locked (kv): locked <path> branch=<b> reason=<lock reason>
# JSON: kept entries of locked worktrees carry "lock_reason"; --list-locked prints
#   {"main": ..., "locked": [{"path", "branch", "reason"}]}.
# Exit codes: 0 done (also with nothing to do), 1 bad arguments, 2 not a git repository
# or no base branch (main worktree on a detached HEAD and no --base).

set -euo pipefail

die() { echo "credo-worktree-cleanup: $1" >&2; exit "${2:-1}"; }

DRY=0
MODE="kv"
BASE=""
FRESH_HOURS=24
LIST_LOCKED=0
KEEP=()
DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY=1 ;;
        --json) MODE="json" ;;
        --base) [ -n "${2:-}" ] || die "--base needs a branch"; BASE="$2"; shift ;;
        --fresh-hours)
            case "${2:-}" in ''|*[!0-9]*) die "--fresh-hours needs a whole number" ;; esac
            FRESH_HOURS="$2"; shift ;;
        --keep) [ -n "${2:-}" ] || die "--keep needs a path or branch"; KEEP+=("$2"); shift ;;
        --list-locked) LIST_LOCKED=1 ;;
        -*) die "unknown argument: $1" ;;
        *) [ -z "$DIR" ] || die "unexpected argument: $1"; DIR="$1" ;;
    esac
    shift
done
DIR="${DIR:-$PWD}"
[ -d "$DIR" ] || die "no such dir: $DIR"

git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $DIR" 2
# The first porcelain block is always the main worktree (never locked): path and branch only.
PORCELAIN="$(git -C "$DIR" worktree list --porcelain | awk 'NF==0{exit} {print}')"
MAIN="$(printf '%s\n' "$PORCELAIN" | sed -n '1s/^worktree //p')"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || die "cannot determine the main worktree" 2
MAIN_REAL="$(cd "$MAIN" && pwd -P)"
MAIN_BRANCH="$(printf '%s\n' "$PORCELAIN" | sed -n 's/^branch refs\/heads\///p' | head -n 1)"
HERE="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
HERE_REAL=""
[ -n "$HERE" ] && HERE_REAL="$(cd "$HERE" && pwd -P)"
SEP=$'\x1f'  # field separator (not whitespace, so empty fields survive read)

# Real path of an existing dir, else the path as given without a trailing slash.
norm_path() { if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s' "${1%/}"; fi; }

# --- linked worktrees, read from the admin directories ----------------------------
# git worktree list --porcelain is line-based, so a multi-line lock reason would corrupt it
# (older git prints the reason raw). The admin directory files are authoritative:
# gitdir (the worktree's .git file), HEAD, locked (the lock reason; the file exists = locked).
COMMON="$(cd "$DIR" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
WT=()   # path SEP branch SEP locked(1|"") SEP prunable(1|"") SEP lock-reason (sanitized)
for adm in "$COMMON"/worktrees/*/; do
    [ -f "${adm}gitdir" ] || continue
    gd=""
    IFS= read -r gd < "${adm}gitdir" || true
    [ -n "$gd" ] || continue
    case "$gd" in /*) ;; *) gd="${adm}$gd" ;; esac
    wpath="${gd%/.git}"
    wbranch="" wlocked="" wprunable="" wreason="" whead=""
    IFS= read -r whead < "${adm}HEAD" || true
    case "$whead" in "ref: refs/heads/"*) wbranch="${whead#ref: refs/heads/}" ;; esac
    if [ -e "${adm}locked" ]; then
        wlocked=1
        wreason="$(tr '[:cntrl:]' ' ' < "${adm}locked" 2>/dev/null || true)"
        wreason="${wreason#"${wreason%%[![:space:]]*}"}"
        wreason="${wreason%"${wreason##*[![:space:]]}"}"
    fi
    [ -e "$gd" ] || wprunable=1
    WT+=("$wpath$SEP$wbranch$SEP$wlocked$SEP$wprunable$SEP$wreason")
done

# --- list locked worktrees (the opt-out marker) ---------------------------------
if [ "$LIST_LOCKED" -eq 1 ]; then
    LOCKED=()   # path SEP branch SEP reason
    for r in "${WT[@]+"${WT[@]}"}"; do
        IFS="$SEP" read -r path branch locked _ reason <<< "$r"
        [ -n "$locked" ] || continue
        LOCKED+=("$path$SEP$branch$SEP${reason:-no reason given}")
    done
    if [ "$MODE" = "json" ]; then
        printf '%s\n' "${LOCKED[@]+"${LOCKED[@]}"}" | MAIN="$MAIN" python3 -c '
import json, os, sys
items = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    path, branch, reason = (line.split("\x1f") + [""] * 3)[:3]
    items.append({"path": path, "branch": branch or None, "reason": reason})
print(json.dumps({"main": os.environ["MAIN"], "locked": items}))'
    else
        for r in "${LOCKED[@]+"${LOCKED[@]}"}"; do
            IFS="$SEP" read -r path branch reason <<< "$r"
            echo "locked $path branch=$branch reason=$reason"
        done
    fi
    exit 0
fi

if [ -z "$BASE" ]; then
    BASE="$MAIN_BRANCH"
    [ -n "$BASE" ] || die "the main worktree is on a detached HEAD - pass --base <branch>" 2
fi
git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BASE" || die "no such branch: $BASE" 2

NOW="$(date +%s)"
RESULTS=()   # status SEP path SEP branch SEP reason SEP branch-result SEP lock-reason

add() { RESULTS+=("$1$SEP$2$SEP$3$SEP$4$SEP${5:-}$SEP${6:-}"); }

KEEP_REAL=()
KEEP_USED=()
KEEP_PATHHIT=()   # 1 when the --keep string is the path of some worktree: then it is a path only
for k in "${KEEP[@]+"${KEEP[@]}"}"; do
    kr="$(norm_path "$k")"
    KEEP_REAL+=("$kr"); KEEP_USED+=(0)
    hit=0
    if [ "$kr" = "$MAIN_REAL" ]; then hit=1; fi
    for r in "${WT[@]+"${WT[@]}"}"; do
        IFS="$SEP" read -r wp _ <<< "$r"
        if [ "$(norm_path "$wp")" = "$kr" ]; then hit=1; fi
    done
    KEEP_PATHHIT+=("$hit")
done

# Succeeds when this worktree is named by a --keep (by path or by branch name); marks it used.
# A --keep string that is the path of a worktree never matches by branch name.
keep_matches() { # real-path branch
    local i matched=1
    for i in "${!KEEP[@]}"; do
        if [ "${KEEP_REAL[$i]}" = "$1" ] || { [ "${KEEP_PATHHIT[$i]}" -eq 0 ] && [ -n "$2" ] && [ "${KEEP[$i]#refs/heads/}" = "$2" ]; }; then
            KEEP_USED[$i]=1
            matched=0
        fi
    done
    return "$matched"
}

# Hours since the branch was created (its oldest reflog entry); "unknown" without a reflog.
created_age_hours() { # branch
    local entries stamp
    entries="$(git -C "$MAIN" reflog show --date=unix --format='%gd' "refs/heads/$1" -- 2>/dev/null || true)"
    stamp="$(printf '%s\n' "$entries" | sed -n '$s/.*@{\([0-9]*\)}.*/\1/p')"
    if [ -n "$stamp" ]; then echo $(( (NOW - stamp) / 3600 )); else echo "unknown"; fi
}

# Number of commits of the branch itself: reflog entries written by commit, cherry-pick or
# revert. A fast-forward from the base ("merge main: Fast-forward") or a reset is no own commit.
own_commit_entries() { # branch
    local entries
    entries="$(git -C "$MAIN" reflog show --format='%gs' "refs/heads/$1" -- 2>/dev/null || true)"
    printf '%s\n' "$entries" | grep -c -E '^(commit|cherry-pick|revert)' || true
}

evaluate() { # path branch locked prunable lock-reason
    local path="$1" branch="$2" locked="$3" prunable="$4" lock_reason="${5:-}" real age untracked keepit=0
    real="$(norm_path "$path")"
    # Mark --keep usage first, whatever the worktree is kept for otherwise (lock, cwd, ...),
    # so a --keep naming such a worktree is not reported as matching nothing.
    if keep_matches "$real" "$branch"; then keepit=1; fi
    # Locked first: the lock is the owner's opt-out and is reported with its reason (git does
    # not prune a locked worktree whose directory is gone either).
    if [ -n "$locked" ]; then
        add kept "$path" "$branch" "locked: ${lock_reason:-no reason given}" "" "${lock_reason:-no reason given}"
        return
    fi
    if [ -n "$prunable" ] || [ ! -d "$path" ]; then
        add kept "$path" "$branch" "directory missing - only its admin entry is pruned"
        return
    fi
    if [ "$real" = "$MAIN_REAL" ]; then return; fi
    if [ "$real" = "$HERE_REAL" ]; then add kept "$path" "$branch" "this command runs inside it"; return; fi
    if [ "$keepit" -eq 1 ]; then add kept "$path" "$branch" "keep requested (--keep)"; return; fi
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
    if [ "$(own_commit_entries "$branch")" -gt 0 ]; then
        if [ "$untracked" -gt 0 ]; then
            add candidate "$path" "$branch" "merged into $BASE, clean ($untracked untracked file(s) go with it)"
        else
            add candidate "$path" "$branch" "merged into $BASE, clean"
        fi
        return
    fi
    # No commit of its own, so it may be the fresh worktree of an agent that has not committed
    # yet (a fast-forward from the base is not a commit): the age guard applies, not "merged".
    age="$(created_age_hours "$branch")"
    if [ "$age" = "unknown" ]; then
        add kept "$path" "$branch" "no commits and no branch history - may be in use"
        return
    fi
    if [ "$age" -lt "$FRESH_HOURS" ]; then
        add kept "$path" "$branch" "no commits yet (fresh worktree), created ${age}h ago - may be in use"
        return
    fi
    if [ "$untracked" -gt 0 ]; then
        add kept "$path" "$branch" "never committed but has $untracked untracked file(s)"
        return
    fi
    add candidate "$path" "$branch" "never committed, unused for ${age}h"
}

# --- walk all worktrees -----------------------------------------------------------
keep_matches "$MAIN_REAL" "$MAIN_BRANCH" || true   # --keep naming the main worktree is not a miss
for r in "${WT[@]+"${WT[@]}"}"; do
    IFS="$SEP" read -r wt_path wt_branch wt_locked wt_prunable wt_lock_reason <<< "$r"
    evaluate "$wt_path" "$wt_branch" "$wt_locked" "$wt_prunable" "$wt_lock_reason"
done

for i in "${!KEEP[@]}"; do
    [ "${KEEP_USED[$i]}" -eq 1 ] || echo "credo-worktree-cleanup: --keep matches no worktree: ${KEEP[$i]}" >&2
done

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
    status, path, branch, reason, extra, lock_reason = (line.split("\x1f") + [""] * 6)[:6]
    entry = {"status": status, "path": path, "branch": branch or None, "reason": reason}
    if extra:
        entry["branch_deleted"] = extra == "branch_deleted"
    if lock_reason:
        entry["lock_reason"] = lock_reason
    items.append(entry)
print(json.dumps({"base": os.environ["BASE"], "main": os.environ["MAIN"],
                  "dry_run": os.environ["DRY"] == "1", "worktrees": items}))'
else
    echo "base=$BASE"
    for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
        IFS="$SEP" read -r status path branch reason extra _ <<< "$r"
        echo "$status $path branch=$branch reason=$reason"
        case "$extra" in
            branch_deleted) echo "branch_deleted=$branch" ;;
            branch_kept) echo "branch_kept=$branch" ;;
        esac
    done
fi

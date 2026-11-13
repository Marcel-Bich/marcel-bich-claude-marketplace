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
#   - its branch is merged into the base branch. The branch tip is an ancestor of it, or
#     every commit of the branch is patch-equivalent in it (`git cherry` lists no "+", the
#     case of a rebased branch)
#   - it has no changes, or only lossless .credo changes (see below). Changes are the entries
#     of `git status --porcelain --untracked-files=all`: uncommitted changes to tracked files
#     and untracked, non-ignored files. Ignored files (build caches, ...) go with it. An
#     untracked symlink whose real target lies in the main checkout is a setup link (for
#     example node_modules) and is no change
#   - no live process has its working directory inside it (read from /proc; unreadable
#     entries are skipped, so without /proc this check finds nothing)
#   - a branch without a commit of its own (its reflog has no commit, cherry-pick or revert
#     entry; a fast-forward from the base does not count) may still be in use by an agent
#     that just started: it is kept while younger than --fresh-hours (default 24), and it is
#     kept when its age cannot be determined
#
# Still needed. A merged worktree that is locked, has changes or has a live process inside
# is NOT removed. Its report line ends with "(ask owner)": an owner question, which the agent
# asks instead of removing the worktree itself. An unmerged worktree is kept without that
# marker, its work is not finished.
#
# Lossless .credo changes (#141). A merged worktree whose changes are ONLY .credo/ files is
# lossless when every line of each changed worktree file is already in the main checkout's file
# of the same relative path. The check is a multiset: each occurrence of a line needs its own
# occurrence in the main file; lines are compared byte for byte. A deleted, renamed, copied,
# unmerged or type-changed entry, a symlink, a file without a counterpart in the main checkout,
# a path git quotes (special characters) and any path outside .credo/ are never lossless. A file
# with a NUL byte (in the worktree, in the main checkout or in the index) is never lossless either.
# A staged change must be covered in its index version as well. A real ignored file under .credo/
# makes the worktree dirty (a setup link into the main checkout does not count). A lossless worktree
# is removed only when the owner setting "clean up merged worktrees automatically" (DOGMA-PERMISSIONS,
# stable id 36ch, read with credo-dogma-mode.sh) is [x]. With [?] or no such checkbox line it is
# listed as a candidate (`candidate ... (lossless)`) and kept; with [ ] it is kept. A helper that
# is missing or fails is read as [ ]. --allow-lossless <path|branch> (repeatable) approves one
# lossless worktree for this run after the owner answered yes; it never overrides [ ].
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
# (never -D). A rebased branch is not an ancestor of the base, so `git branch -d` refuses
# it. The branch is kept, and the report prints `owner_command=git branch -D <branch>` for
# the owner to run; this script never force-deletes. Afterwards `git worktree prune` drops
# admin entries of worktree directories that no longer exist. Nothing else is ever deleted.
# A lossless worktree gets the same removal; right before it the lossless check and the live-process
# check run again, so a worktree that changed, or got a process inside, since the first check is kept.
#
# Stray .credo files (#174). .credo/ belongs to the main checkout; a linked worktree only has a
# symlink to it. When a worktree has a REAL .credo directory, its untracked (also ignored) files
# are rescued into the main checkout first (credo-cleanup.py rescue-credo: copy, never overwrite).
# A file that differs from the main checkout's copy, or a main checkout without .credo, is a
# conflict: it is reported on stderr and the file stays a change (an untracked or ignored real
# .credo file), so the change classification below keeps the worktree as an owner question. A
# rescued file has its counterpart in the main checkout afterwards, so it can count as lossless.
# --dry-run only reports what would be rescued.
#
# --details adds the content of a worktree that is kept as NOT merged to its reason: the commits
# the base lacks (`git cherry`, "+" lines), the uncommitted changes (`git status --porcelain`
# entries) and the size (du, best effort). Unmerged worktrees are never removed by this script;
# forgotten work stays until the owner decides.
#
# Usage:
#   credo-worktree-cleanup.sh [--dry-run] [--json] [--details] [--base <branch>] [--fresh-hours N]
#                             [--keep <path|branch>]... [--allow-lossless <path|branch>]... [dir]
#   credo-worktree-cleanup.sh --list-locked [--json] [dir]
#     --dry-run      list candidates and kept worktrees, remove nothing
#     --allow-lossless  one-off approval of one lossless worktree (an owner answer): a path or a
#                    branch, repeatable; the worktree is removed in this run although the owner
#                    setting is not [x]; a bare --allow-lossless is an error; never overrides [ ]
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
#   removed <path> branch=<b> reason=<why>         (+ branch_deleted=<b>, or branch_kept=<b>
#                                                   and owner_command=git branch -D <b>)
#   failed <path> branch=<b> reason=<git error>
#   kept <path> branch=<b> reason=<why>            (reason ends with "(ask owner)" when the
#                                                   merged worktree needs an owner decision)
#     a locked worktree: kept <path> branch=<b> reason=locked: <lock reason>
# --list-locked (kv): locked <path> branch=<b> reason=<lock reason>
# A lossless worktree is reported with the same status word and its reason ends with
#   "(lossless)"; JSON adds "lossless": true to it.
# JSON: kept entries of locked worktrees carry "lock_reason"; a removed worktree whose branch
#   was kept carries "owner_command"; --list-locked prints
#   {"main": ..., "locked": [{"path", "branch", "reason"}]}.
# Exit codes: 0 done (also with nothing to do), 1 bad arguments, 2 not a git repository
# or no base branch (main worktree on a detached HEAD and no --base).

set -euo pipefail

die() { echo "credo-worktree-cleanup: $1" >&2; exit "${2:-1}"; }

DRY=0
DETAILS=0
MODE="kv"
BASE=""
FRESH_HOURS=24
LIST_LOCKED=0
ALLOW=()   # --allow-lossless values: a path or a branch each, repeatable
KEEP=()
DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY=1 ;;
        --json) MODE="json" ;;
        --details) DETAILS=1 ;;
        --base) [ -n "${2:-}" ] || die "--base needs a branch"; BASE="$2"; shift ;;
        --fresh-hours)
            case "${2:-}" in ''|*[!0-9]*) die "--fresh-hours needs a whole number" ;; esac
            FRESH_HOURS="$2"; shift ;;
        --keep) [ -n "${2:-}" ] || die "--keep needs a path or branch"; KEEP+=("$2"); shift ;;
        --list-locked) LIST_LOCKED=1 ;;
        --allow-lossless)
            case "${2:-}" in ''|-*) die "--allow-lossless needs a path or branch" ;; esac
            ALLOW+=("$2"); shift ;;
        -*) die "unknown argument: $1" ;;
        *) [ -z "$DIR" ] || die "unexpected argument: $1"; DIR="$1" ;;
    esac
    shift
done
DIR="${DIR:-$PWD}"
[ -d "$DIR" ] || die "no such dir: $DIR"

git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $DIR" 2
# The first porcelain block is always the main worktree (never locked): path and branch only.
# awk reads to the end (no early exit): an early exit makes git die of SIGPIPE on a long
# worktree list, and pipefail plus set -e would end the script silently with 141.
PORCELAIN="$(git -C "$DIR" worktree list --porcelain | awk 'NF==0{done=1} !done{print}')"
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

# Owner setting for lossless removal (DOGMA-PERMISSIONS, stable id 36ch, read without dogma):
# auto ([x]) removes lossless worktrees; ask ([?]) and missing (no such checkbox line) list them as
# candidates; deny ([ ]) keeps them. A helper that is missing or fails, or an unknown answer, is
# deny: the setting cannot be read, so nothing is removed on its behalf.
CLEANUP_MODE="$("$SCRIPT_DIR/credo-dogma-mode.sh" --id 36ch Hydra 'clean up merged worktrees automatically' "$MAIN" 2>/dev/null)" || CLEANUP_MODE=deny
case "$CLEANUP_MODE" in
    auto|ask|missing|deny) ;;
    *) CLEANUP_MODE=deny ;;
esac

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

# --allow-lossless values, matched like --keep: a value that is the path of a worktree names that
# worktree only; any other value names a branch. Each one marks its use for the warning below.
ALLOW_REAL=()
ALLOW_USED=()
ALLOW_PATHHIT=()   # 1 when the value is the path of some worktree: then it is a path only
for k in "${ALLOW[@]+"${ALLOW[@]}"}"; do
    kr="$(norm_path "$k")"
    ALLOW_REAL+=("$kr"); ALLOW_USED+=(0)
    hit=0
    for r in "${WT[@]+"${WT[@]}"}"; do
        IFS="$SEP" read -r wp _ <<< "$r"
        if [ "$(norm_path "$wp")" = "$kr" ]; then hit=1; fi
    done
    ALLOW_PATHHIT+=("$hit")
done

# Succeeds when a --allow-lossless names this worktree (by path, or by branch name unless the value
# is a worktree path); marks it used. Called for every worktree, candidate or not.
allow_matches() { # real-path branch
    local i matched=1
    for i in "${!ALLOW[@]}"; do
        if [ "${ALLOW_REAL[$i]}" = "$1" ] || { [ "${ALLOW_PATHHIT[$i]}" -eq 0 ] && [ -n "$2" ] && [ "${ALLOW[$i]#refs/heads/}" = "$2" ]; }; then
            ALLOW_USED[$i]=1
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

# Merged into the base means the branch tip is an ancestor of it, or every commit of the branch is
# patch-equivalent in it (a rebased branch, `git cherry` marks those "-", a commit the base
# lacks is "+"). Sets MERGED_HOW to ancestor or rebased.
is_merged() { # branch -> 0 when merged
    MERGED_HOW=""
    if git -C "$MAIN" merge-base --is-ancestor "refs/heads/$1" "refs/heads/$BASE" 2>/dev/null; then
        MERGED_HOW="ancestor"
        return 0
    fi
    local cherry
    cherry="$(git -C "$MAIN" cherry "refs/heads/$BASE" "refs/heads/$1" 2>/dev/null)" || return 1
    if grep -q '^+' <<< "$cherry"; then return 1; fi
    MERGED_HOW="rebased"
    return 0
}

# --- change classification (#141) -------------------------------------------------
# An untracked symlink whose real target lies in the main checkout is a setup link, not a change.
# readlink -e fails on a dangling link, which then counts as a change.
link_into_main() { # worktree rel-path -> 0 when the symlink resolves into the main checkout
    local target
    [ -L "$1/$2" ] || return 1
    target="$(readlink -e -- "$1/$2" 2>/dev/null)" || return 1
    case "$target" in "$MAIN_REAL"|"$MAIN_REAL"/*) return 0 ;; esac
    return 1
}

# Prints how many lines of the content file are missing from the main file. A multiset: every
# occurrence of a line needs its own occurrence in the main file. Byte-exact comparison; a
# missing final newline does not matter. The content "-" is read from stdin. A read error
# prints nothing, which the callers treat as not lossless.
missing_lines() { # main-file content-file|-
    awk -v main="$1" '
        FILENAME == main { have[$0 ""]++; next }
        { if (have[$0 ""] > 0) have[$0 ""]--; else missing++ }
        END { print missing + 0 }' "$1" "$2"
}

# Prints how many NUL bytes the input holds. Counted with tr: the awk line handling is not relied on
# for such content.
nul_count() { tr -cd '\000' | wc -c | tr -d ' '; }

# Verdict for one change of a merged worktree: lossless when it is a .credo/ file (not a symlink)
# that exists in the main checkout and whose lines are all there. A deletion, rename, copy,
# conflict or type change, a path git quotes, and any path outside .credo/ are never lossless.
# A staged change is also checked in its index version: removing the worktree drops its index.
lossless_entry() { # worktree XY rel-path -> 0 when this change is lossless
    local wt="$1" xy="$2" p="$3" mf="$MAIN_REAL/$3" idx_nul idx_missing
    case "$p" in .credo/*) ;; *) return 1 ;; esac
    case "$p" in *\"*|*\\*) return 1 ;; esac
    case "$xy" in *[DRCUT]*) return 1 ;; esac
    [ -f "$wt/$p" ] && [ ! -L "$wt/$p" ] || return 1
    [ -f "$mf" ] && [ ! -L "$mf" ] || return 1
    # a NUL byte makes a file never lossless: the line comparison is not trusted for such content
    [ "$(nul_count < "$wt/$p")" = 0 ] || return 1
    [ "$(nul_count < "$mf")" = 0 ] || return 1
    [ "$(missing_lines "$mf" "$wt/$p")" = 0 ] || return 1
    case "${xy:0:1}" in
        ' '|'?') return 0 ;;
    esac
    idx_nul="$(git -C "$wt" show ":$p" 2>/dev/null | nul_count)" || return 1
    [ "$idx_nul" = 0 ] || return 1
    idx_missing="$(git -C "$wt" show ":$p" 2>/dev/null | missing_lines "$mf" -)" || return 1
    [ "$idx_missing" = 0 ]
}

# Classifies the changes of a merged worktree: clean (no change, or only setup links), lossless
# (only lossless .credo changes), dirty (anything else, CHG_WHY gives the reason) or error (git
# status failed). Sets CHG_CLASS and CHG_WHY.
classify_changes() { # worktree-path
    local wt="$1" st="" line="" xy="" p="" p_ign="" ign="" n=0 tracked=0 untracked=0 lossless=1
    local ign_n=0 ign_err=0
    CHG_CLASS="clean"; CHG_WHY=""
    if ! st="$(git -C "$wt" -c core.quotePath=false status --porcelain --untracked-files=all 2>/dev/null)"; then
        CHG_CLASS="error"
        return 0
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        xy="${line:0:2}"; p="${line:3}"
        if [ "$xy" = "??" ] && link_into_main "$wt" "$p"; then continue; fi
        n=$((n + 1))
        if [ "$xy" = "??" ]; then untracked=$((untracked + 1)); else tracked=$((tracked + 1)); fi
        if [ "$lossless" -eq 1 ] && ! lossless_entry "$wt" "$xy" "$p"; then lossless=0; fi
    done <<< "$st"
    # Ignored files are not in the status, but they go with the worktree, so a real ignored file under
    # .credo/ makes it dirty: it may hold the only copy. A setup link into the main checkout is no change.
    if ! ign="$(git -C "$wt" -c core.quotePath=false ls-files --others --ignored --exclude-standard -- .credo/ 2>/dev/null)"; then
        ign_err=1
    else
        while IFS= read -r p_ign; do
            [ -n "$p_ign" ] || continue
            if link_into_main "$wt" "$p_ign"; then continue; fi
            ign_n=$((ign_n + 1))
        done <<< "$ign"
    fi
    if [ "$n" -eq 0 ] && [ "$ign_n" -eq 0 ] && [ "$ign_err" -eq 0 ]; then return 0; fi
    if [ "$n" -gt 0 ] && [ "$lossless" -eq 1 ] && [ "$ign_n" -eq 0 ] && [ "$ign_err" -eq 0 ]; then
        CHG_CLASS="lossless"
        return 0
    fi
    CHG_CLASS="dirty"
    if [ "$tracked" -gt 0 ]; then CHG_WHY="uncommitted changes to tracked files"; fi
    if [ "$untracked" -gt 0 ]; then
        if [ -n "$CHG_WHY" ]; then
            CHG_WHY="$CHG_WHY, $untracked untracked file(s)"
        else
            CHG_WHY="$untracked untracked file(s), not committed"
        fi
    fi
    if [ "$ign_n" -gt 0 ]; then
        if [ -n "$CHG_WHY" ]; then
            CHG_WHY="$CHG_WHY, $ign_n ignored file(s) under .credo/"
        else
            CHG_WHY="$ign_n ignored file(s) under .credo/"
        fi
    fi
    if [ "$ign_err" -eq 1 ]; then
        if [ -n "$CHG_WHY" ]; then
            CHG_WHY="$CHG_WHY, cannot list ignored .credo/ files"
        else
            CHG_WHY="cannot list ignored .credo/ files"
        fi
    fi
    CHG_WHY="${CHG_WHY:-uncommitted changes}"
}

# Live processes whose working directory is inside a path. /proc/<pid>/cwd is read once per run
# (readlink; an unreadable entry is skipped). Sets FOUND_PID when one matches.
PROC_CWDS=""
PROC_READ=0
process_inside() { # real-path -> 0 and FOUND_PID when a live process has its cwd inside
    local link pid cwd
    if [ "$PROC_READ" -eq 0 ]; then
        PROC_READ=1
        for link in /proc/[0-9]*/cwd; do
            [ -L "$link" ] || continue
            cwd="$(readlink "$link" 2>/dev/null)" || continue
            pid="${link#/proc/}"
            PROC_CWDS+="${pid%/cwd}"$'\t'"$cwd"$'\n'
        done
    fi
    while IFS=$'\t' read -r pid cwd; do
        case "$cwd" in
            "$1"|"$1"/*) FOUND_PID="$pid"; return 0 ;;
        esac
    done <<< "$PROC_CWDS"
    return 1
}

# Content of an unmerged worktree for the report (--details only): unique commits, uncommitted
# changes, size. Every part is best effort; a failing part reads "?".
unmerged_details() { # path branch
    [ "$DETAILS" -eq 1 ] || return 0
    local uniq dirty size
    uniq="$(git -C "$MAIN" cherry "refs/heads/$BASE" "refs/heads/$2" 2>/dev/null | grep -c '^+' || true)"
    dirty="$(git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo '?')"
    size="$(timeout 20 du -sm -- "$1" 2>/dev/null | cut -f1 || true)"
    printf ' (unique_commits=%s uncommitted=%s size=%sMB, never removed automatically)' "${uniq:-?}" "${dirty:-?}" "${size:-?}"
}

# A real .credo directory in a linked worktree: rescue its untracked files into the main checkout
# (credo-cleanup.py rescue-credo). Never fails; conflicts go to stderr and stay changes.
rescue_stray_credo() { # path
    RESCUE_WHY=""
    [ -d "$1/.credo" ] && [ ! -L "$1/.credo" ] || return 0
    local dry="" outp rc
    if [ "$DRY" -eq 1 ]; then dry="--dry-run"; fi
    rc=0
    outp="$(python3 -I "$SCRIPT_DIR/credo-cleanup.py" rescue-credo $dry "$1" 2>&1)" || rc=$?
    printf '%s\n' "$outp" | grep -E '^(rescued|would-rescue|conflict) ' \
        | sed "s|^|credo-worktree-cleanup: $1: .credo |" >&2 || true
    [ "$rc" -eq 0 ] || RESCUE_WHY="conflict"
    return 0
}

evaluate() { # path branch locked prunable lock-reason
    local path="$1" branch="$2" locked="$3" prunable="$4" lock_reason="${5:-}" real keepit=0
    local merged=0 ask="" age cand="candidate" tail="clean"
    real="$(norm_path "$path")"
    # Mark --keep usage first, whatever the worktree is kept for otherwise (lock, cwd, ...),
    # so a --keep naming such a worktree is not reported as matching nothing.
    if keep_matches "$real" "$branch"; then keepit=1; fi
    allow_matches "$real" "$branch" || true   # marks the --allow-lossless values that name this worktree
    # Merged is decided before the lock. Only a merged worktree is an owner question.
    if [ -n "$branch" ] && [ "$branch" != "$BASE" ] && is_merged "$branch"; then merged=1; fi
    if [ "$merged" -eq 1 ]; then ask=" (ask owner)"; fi
    # Locked first: the lock is the owner's opt-out and is reported with its reason (git does
    # not prune a locked worktree whose directory is gone either).
    if [ -n "$locked" ]; then
        # a "keep: ..." lock is the owner's answer already; ask only for other locks
        case "$lock_reason" in keep*) ask="" ;; esac
        add kept "$path" "$branch" "locked: ${lock_reason:-no reason given}$ask" "" "${lock_reason:-no reason given}"
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
    if [ "$merged" -eq 0 ]; then add kept "$path" "$branch" "not merged into $BASE$(unmerged_details "$path" "$branch")"; return; fi
    rescue_stray_credo "$path"   # copies missing files only; a conflict keeps the worktree dirty below
    # From here on the worktree is merged. Whatever is still in it is the owner's call, never ours,
    # except lossless .credo changes: the owner setting decides whether the script removes them.
    classify_changes "$path"
    case "$CHG_CLASS" in
        error) add kept "$path" "$branch" "git status failed$ask"; return ;;
        dirty) add kept "$path" "$branch" "$CHG_WHY$ask"; return ;;
    esac
    if [ "$CHG_CLASS" = "lossless" ]; then
        if [ "$CLEANUP_MODE" = "deny" ]; then
            add kept "$path" "$branch" "only .credo changes already in main (lossless), not removed: the cleanup setting is off"
            return
        fi
        cand="candidate-lossless"; tail="only .credo changes already in main (lossless)"
    fi
    if process_inside "$real"; then
        add kept "$path" "$branch" "live process inside it (pid $FOUND_PID)$ask"
        return
    fi
    if [ "$(own_commit_entries "$branch")" -gt 0 ]; then
        if [ "$MERGED_HOW" = "rebased" ]; then
            add "$cand" "$path" "$branch" "merged into $BASE (patch-equivalent after rebase), $tail"
        else
            add "$cand" "$path" "$branch" "merged into $BASE, $tail"
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
    if [ "$CHG_CLASS" = "lossless" ]; then
        add "$cand" "$path" "$branch" "never committed, unused for ${age}h, $tail"
    else
        add candidate "$path" "$branch" "never committed, unused for ${age}h"
    fi
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
for i in "${!ALLOW[@]}"; do
    [ "${ALLOW_USED[$i]}" -eq 1 ] || echo "credo-worktree-cleanup: --allow-lossless matches no worktree: ${ALLOW[$i]}" >&2
done

# --- remove (only verified candidates) ----------------------------------------
if [ "$DRY" -eq 0 ]; then
    for i in "${!RESULTS[@]}"; do
        IFS="$SEP" read -r status path branch reason _ <<< "${RESULTS[$i]}"
        case "$status" in
            candidate) sfx="" ;;
            candidate-lossless)
                # the owner setting [x], or an --allow-lossless that names this worktree (the owner's yes)
                wreal="$(norm_path "$path")"
                if [ "$CLEANUP_MODE" != "auto" ] && { [ "$CLEANUP_MODE" = "deny" ] || ! allow_matches "$wreal" "$branch"; }; then
                    continue
                fi
                sfx="-lossless" ;;
            *) continue ;;
        esac
        if [ -n "$sfx" ]; then
            # the worktree may have changed since the first check: check again right before removal
            classify_changes "$path"
            if [ "$CHG_CLASS" != "lossless" ]; then
                RESULTS[$i]="failed$sfx$SEP$path$SEP$branch$SEP$reason, changed since the check: not removed$SEP"
                continue
            fi
            # the live-process check runs again too, from a fresh /proc read (the one before is older)
            PROC_READ=0; PROC_CWDS=""
            if process_inside "$wreal"; then
                RESULTS[$i]="failed$sfx$SEP$path$SEP$branch$SEP$reason, live process inside it (pid $FOUND_PID): not removed$SEP"
                continue
            fi
        fi
        real="$(cd "$path" 2>/dev/null && pwd -P || true)"
        case "$real" in
            ""|/|"$MAIN_REAL"|"$HOME"|"$(dirname "$MAIN_REAL")")
                RESULTS[$i]="failed$sfx$SEP$path$SEP$branch${SEP}refused: unsafe path$SEP"
                continue ;;
        esac
        if err="$(git -C "$MAIN" worktree remove --force -- "$path" 2>&1)"; then
            if git -C "$MAIN" branch -d -- "$branch" >/dev/null 2>&1; then
                RESULTS[$i]="removed$sfx$SEP$path$SEP$branch$SEP$reason${SEP}branch_deleted"
            else
                RESULTS[$i]="removed$sfx$SEP$path$SEP$branch$SEP$reason${SEP}branch_kept"
            fi
        else
            RESULTS[$i]="failed$sfx$SEP$path$SEP$branch$SEP$(printf '%s' "$err" | tr '\n\037' '  ')$SEP"
        fi
    done
    git -C "$MAIN" worktree prune 2>/dev/null || true
fi

# --- report ---------------------------------------------------------------------
if [ "$MODE" = "json" ]; then
    printf '%s\n' "${RESULTS[@]+"${RESULTS[@]}"}" | BASE="$BASE" DRY="$DRY" MAIN="$MAIN" python3 -c '
import json, os, shlex, sys
items = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    status, path, branch, reason, extra, lock_reason = (line.split("\x1f") + [""] * 6)[:6]
    lossless = status.endswith("-lossless")
    if lossless:
        status = status[: -len("-lossless")]
    entry = {"status": status, "path": path, "branch": branch or None, "reason": reason}
    if lossless:
        entry["lossless"] = True
    if extra:
        entry["branch_deleted"] = extra == "branch_deleted"
    if extra == "branch_kept" and branch:
        entry["owner_command"] = "git branch -D " + shlex.quote(branch)
    if lock_reason:
        entry["lock_reason"] = lock_reason
    items.append(entry)
print(json.dumps({"base": os.environ["BASE"], "main": os.environ["MAIN"],
                  "dry_run": os.environ["DRY"] == "1", "worktrees": items}))'
else
    echo "base=$BASE"
    for r in "${RESULTS[@]+"${RESULTS[@]}"}"; do
        IFS="$SEP" read -r status path branch reason extra _ <<< "$r"
        echo "${status%-lossless} $path branch=$branch reason=$reason"
        case "$extra" in
            branch_deleted) echo "branch_deleted=$branch" ;;
            branch_kept)
                echo "branch_kept=$branch"
                echo "owner_command=git branch -D $(printf '%q' "$branch")" ;;
        esac
    done
fi

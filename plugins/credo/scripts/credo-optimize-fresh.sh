#!/bin/bash
# credo-optimize-fresh - is the repo on its default branch and up to date with the
# remote? Run before every optimisation audit, so an audit never looks at a stale
# state silently. Read-only except `git fetch` (skip it with --no-fetch); it never
# switches or pulls - it only prints the commands to propose to the user.
#
# Default branch: <remote>/HEAD when known, else a local main or master.
# Remote: the upstream remote of the default branch, else origin, else the first
# remote; no remote at all -> only the branch check applies.
#
# Usage:
#   credo-optimize-fresh.sh [--repo DIR] [--no-fetch] [--json]
#
# Output (key=value lines, or one JSON object with --json):
#   branch, default, remote, on_default (yes|no), fetch (ok|failed|skipped|no-remote),
#   behind, ahead (default branch vs <remote>/<default>), dirty (porcelain lines),
#   fresh (yes|no|unknown), and zero or more suggest=<command> lines
#   (git switch <default> / git pull --ff-only).
#
# Exit codes: 0 fresh, 1 stale (suggestions printed), 2 bad arguments,
#   3 freshness unknown (no default branch found, or the fetch failed and nothing
#   else is stale), 4 not a git repo.

set -euo pipefail

die() { echo "credo-optimize-fresh: $1" >&2; exit "${2:-2}"; }

REPO_ARG=""
FETCH=1
JSON=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || die "--repo needs a dir"; REPO_ARG="$2"; shift 2 ;;
        --no-fetch) FETCH=0; shift ;;
        --json) JSON=1; shift ;;
        *) die "usage: credo-optimize-fresh.sh [--repo DIR] [--no-fetch] [--json]" ;;
    esac
done

START="${REPO_ARG:-$PWD}"
[ -d "$START" ] || die "no such dir: $START"
TOP="$(git -C "$START" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repo: $START" 4
g() { git -C "$TOP" "$@"; }

branch="$(g symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch="HEAD"

# --- remote + default branch ---------------------------------------------------
remotes="$(g remote 2>/dev/null)" || remotes=""
remote=""
default=""
for r in origin $remotes; do
    d="$(g symbolic-ref --quiet --short "refs/remotes/$r/HEAD" 2>/dev/null)" || d=""
    if [ -n "$d" ]; then remote="$r"; default="${d#"$r"/}"; break; fi
done
if [ -z "$default" ]; then
    for cand in main master; do
        if g show-ref --verify --quiet "refs/heads/$cand"; then default="$cand"; break; fi
    done
fi
if [ -z "$default" ] && [ -n "$remotes" ]; then
    for cand in main master; do
        for r in origin $remotes; do
            if g show-ref --verify --quiet "refs/remotes/$r/$cand"; then default="$cand"; remote="$r"; break 2; fi
        done
    done
fi
if [ -n "$default" ] && [ -z "$remote" ]; then
    remote="$(g config --get "branch.$default.remote" 2>/dev/null)" || remote=""
    if [ -z "$remote" ]; then
        if printf '%s\n' "$remotes" | grep -qx origin; then remote=origin; else remote="$(printf '%s\n' "$remotes" | head -n1)"; fi
    fi
fi

dirty="$(GIT_OPTIONAL_LOCKS=0 g status --porcelain 2>/dev/null | grep -c . || true)"

emit() { # fresh behind ahead fetch suggestions...
    local fresh="$1" behind="$2" ahead="$3" fetch="$4"; shift 4
    local on_default=no
    [ -n "$default" ] && [ "$branch" = "$default" ] && on_default=yes
    if [ "$JSON" -eq 1 ]; then
        BRANCH="$branch" DEFAULT="$default" REMOTE="$remote" ON="$on_default" FETCH_S="$fetch" \
        BEHIND="$behind" AHEAD="$ahead" DIRTY="$dirty" FRESH="$fresh" python3 -c '
import json, os, sys
e = os.environ
def num(v):
    return int(v) if v.isdigit() else None
print(json.dumps({"branch": e["BRANCH"], "default": e["DEFAULT"] or None, "remote": e["REMOTE"] or None,
    "on_default": e["ON"] == "yes", "fetch": e["FETCH_S"], "behind": num(e["BEHIND"]),
    "ahead": num(e["AHEAD"]), "dirty": int(e["DIRTY"] or 0), "fresh": e["FRESH"],
    "suggest": sys.argv[1:]}))' "$@"
    else
        printf 'branch=%s\ndefault=%s\nremote=%s\non_default=%s\nfetch=%s\nbehind=%s\nahead=%s\ndirty=%s\nfresh=%s\n' \
            "$branch" "$default" "$remote" "$on_default" "$fetch" "$behind" "$ahead" "$dirty" "$fresh"
        local s
        for s in "$@"; do printf 'suggest=%s\n' "$s"; done
    fi
}

if [ -z "$default" ]; then
    emit unknown "" "" skipped
    exit 3
fi

# --- fetch + behind/ahead --------------------------------------------------------
fetch=no-remote
behind=0
ahead=0
if [ -n "$remote" ]; then
    if [ "$FETCH" -eq 1 ]; then
        if g fetch --quiet "$remote" "$default" >/dev/null 2>&1; then fetch=ok; else fetch=failed; fi
    else
        fetch=skipped
    fi
    if g show-ref --verify --quiet "refs/remotes/$remote/$default"; then
        counts="$(g rev-list --left-right --count "refs/heads/$default...refs/remotes/$remote/$default" 2>/dev/null)" || counts=""
        if [ -n "$counts" ]; then
            ahead="$(printf '%s' "$counts" | awk '{print $1}')"
            behind="$(printf '%s' "$counts" | awk '{print $2}')"
        fi
    fi
fi

suggest=()
[ "$branch" = "$default" ] || suggest+=("git switch $default")
[ "${behind:-0}" -gt 0 ] && suggest+=("git pull --ff-only")

if [ "${#suggest[@]}" -gt 0 ]; then
    emit no "$behind" "$ahead" "$fetch" "${suggest[@]}"
    exit 1
fi
# A failed fetch means the remote state is not known: never claim "fresh" then.
if [ "$fetch" = failed ]; then
    emit unknown "$behind" "$ahead" "$fetch"
    exit 3
fi
emit yes "$behind" "$ahead" "$fetch"
exit 0

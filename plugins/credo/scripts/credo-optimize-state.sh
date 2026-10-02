#!/bin/bash
# credo-optimize-state - per-repo state of the credo optimisation audit.
#
# Holds, per repository and per Claude Code profile (CLAUDE_CONFIG_DIR), what the
# optimisation audit needs to stay opt-in and non-intrusive:
#   optin       yes | no | (empty = never answered)
#   last-seen   epoch seconds of the last prompt credo saw in this repo
#   last-offer  epoch seconds of the last time the audit was offered (asked)
#   pending     epoch seconds when a returner offer was detected but not asked yet
#   never       finding ids the user answered "Never" for (one per line)
#
# Repo identity: the MAIN worktree of the repository (first entry of
# `git worktree list`), so linked worktrees share one state with the main checkout.
# Store: <store>/<sha256 of the repo path>/ with one file per field plus "key"
# (cleartext repo path, for human traceability only). Writes are atomic
# (tmp + mv -f).
#
# Usage:
#   credo-optimize-state.sh [--repo DIR] <command> [args]
#     key                      print the repo path and the state dir
#     get [--json]             print every field (key=value lines, or one JSON object)
#     optin [yes|no]           print the opt-in answer, or set it
#     seen [EPOCH]             set last-seen (default: now)
#     get-seen                 print last-seen (empty when never seen)
#     pending [EPOCH]          mark a returner offer as pending (default: now)
#     get-pending              print the pending marker (empty when none)
#     offered [EPOCH]          the offer was asked: set last-offer, clear pending
#     get-offer                print last-offer (empty when never offered)
#     never-add <id>           remember "Never" for a finding id
#     never-has <id>           exit 0 when the id is on the never-list, else 1
#     never-list               print the never-list
#
# Env overrides (tests / custom config):
#   CREDO_OPTIMIZE_DIR   store dir (default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/optimize)
#   CREDO_OPTIMIZE_NOW   "now" as epoch seconds
#
# Exit codes: 0 ok, 1 bad arguments / not found (never-has), 4 not a git repo.

set -euo pipefail

usage() {
    echo "usage: credo-optimize-state.sh [--repo DIR] {key|get [--json]|optin [yes|no]|seen [EPOCH]|get-seen|pending [EPOCH]|get-pending|offered [EPOCH]|get-offer|never-add ID|never-has ID|never-list}" >&2
    exit 1
}

REPO_ARG=""
if [ "${1:-}" = "--repo" ]; then
    [ $# -ge 2 ] || usage
    REPO_ARG="$2"
    shift 2
fi
[ $# -ge 1 ] || usage
CMD="$1"
shift

START="${REPO_ARG:-$PWD}"
[ -d "$START" ] || { echo "credo-optimize-state: no such dir: $START" >&2; exit 1; }

# --- resolve the repo identity: main worktree of the repository -------------
git -C "$START" rev-parse --git-dir >/dev/null 2>&1 || { echo "credo-optimize-state: not a git repo: $START" >&2; exit 4; }
REPO="$(git -C "$START" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')" || REPO=""
[ -n "$REPO" ] || REPO="$(git -C "$START" rev-parse --show-toplevel 2>/dev/null)" || REPO=""
[ -n "$REPO" ] || { echo "credo-optimize-state: cannot resolve repo root: $START" >&2; exit 4; }

STORE="${CREDO_OPTIMIZE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/optimize}"
HASH="$(printf '%s' "$REPO" | sha256sum | cut -d' ' -f1)"
DIR="$STORE/$HASH"

now() {
    if [ -n "${CREDO_OPTIMIZE_NOW:-}" ]; then printf '%s\n' "$CREDO_OPTIMIZE_NOW"; else date +%s; fi
}

epoch_arg() { # value-or-empty -> validated epoch
    local v="${1:-}"
    [ -n "$v" ] || v="$(now)"
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "credo-optimize-state: not an epoch: $v" >&2; exit 1; }
    printf '%s' "$v"
}

read_field() { # name -> first line or empty
    local f="$DIR/$1"
    [ -f "$f" ] && head -n1 "$f" 2>/dev/null | tr -d '[:space:]' || true
}

write_field() { # name value
    mkdir -p "$DIR"
    [ -f "$DIR/key" ] || printf '%s\n' "$REPO" > "$DIR/key"
    local tmp
    tmp="$(mktemp "$DIR/.$1.XXXXXX")"
    printf '%s\n' "$2" > "$tmp"
    mv -f "$tmp" "$DIR/$1"
}

valid_id() {
    [ -n "$1" ] && [[ "$1" != *$'\n'* ]] || { echo "credo-optimize-state: invalid finding id" >&2; exit 1; }
}

case "$CMD" in
    key)
        printf 'repo=%s\nstate_dir=%s\n' "$REPO" "$DIR"
        ;;
    get)
        optin="$(read_field optin)"; seen="$(read_field last-seen)"
        offer="$(read_field last-offer)"; pend="$(read_field pending)"
        never=""
        [ -f "$DIR/never" ] && never="$(cat "$DIR/never")"
        if [ "${1:-}" = "--json" ]; then
            REPO="$REPO" OPTIN="$optin" SEEN="$seen" OFFER="$offer" PEND="$pend" NEVER="$never" python3 -c '
import json, os
def num(v):
    return int(v) if v.isdigit() else None
e = os.environ
print(json.dumps({
    "repo": e["REPO"],
    "optin": e["OPTIN"] or None,
    "last_seen": num(e["SEEN"]),
    "last_offer": num(e["OFFER"]),
    "pending": num(e["PEND"]),
    "never": [l for l in e["NEVER"].splitlines() if l],
}))'
        else
            printf 'repo=%s\noptin=%s\nlast_seen=%s\nlast_offer=%s\npending=%s\nnever_count=%s\n' \
                "$REPO" "$optin" "$seen" "$offer" "$pend" "$(printf '%s' "$never" | grep -c . || true)"
        fi
        ;;
    optin)
        if [ $# -eq 0 ]; then
            v="$(read_field optin)"
            case "$v" in yes|no) printf '%s\n' "$v" ;; *) printf '\n' ;; esac
        else
            case "$1" in yes|no) write_field optin "$1"; echo "credo-optimize optin = $1 (repo $REPO)" ;; *) usage ;; esac
        fi
        ;;
    seen) v="$(epoch_arg "${1:-}")"; write_field last-seen "$v" ;;
    get-seen) printf '%s\n' "$(read_field last-seen)" ;;
    pending) v="$(epoch_arg "${1:-}")"; write_field pending "$v" ;;
    get-pending) printf '%s\n' "$(read_field pending)" ;;
    offered)
        v="$(epoch_arg "${1:-}")"
        write_field last-offer "$v"
        rm -f "$DIR/pending"
        ;;
    get-offer) printf '%s\n' "$(read_field last-offer)" ;;
    never-add)
        [ $# -eq 1 ] || usage
        valid_id "$1"
        if ! { [ -f "$DIR/never" ] && grep -qxF -- "$1" "$DIR/never"; }; then
            existing=""
            [ -f "$DIR/never" ] && existing="$(cat "$DIR/never")"
            if [ -n "$existing" ]; then write_field never "$existing"$'\n'"$1"; else write_field never "$1"; fi
        fi
        ;;
    never-has)
        [ $# -eq 1 ] || usage
        [ -f "$DIR/never" ] && grep -qxF -- "$1" "$DIR/never"
        ;;
    never-list)
        [ -f "$DIR/never" ] && cat "$DIR/never" || true
        ;;
    *) usage ;;
esac

#!/usr/bin/env bash
# credo-dir-decision.sh <key|get|set> [accepted|declined]
#
# Persistent, PER-DIRECTORY credo-workflow decision. Unlike the per-session
# decision (credo-decision-set.sh), this state is keyed by the working directory
# so a "declined" choice stays remembered across every future session in that
# directory - the SessionStart ASK never nags there again, and the [credo]
# UserPromptSubmit line stays silent.
#
# DIR-KEY: the identity of "this directory" for decision purposes:
#   1. the top-level of the git repo   (git rev-parse --show-toplevel), else
#   2. the current working directory   ($PWD)
# Hubs and plain (non-git) directories are NOT repos; they get their own key via
# $PWD, so they are asked once and then remembered just like a repo.
#
# Subcommands:
#   key                      print the resolved DIR-KEY for the cwd.
#   get                      print the persisted state for the cwd's DIR-KEY:
#                            "accepted" | "declined" | "" (none). Always exit 0.
#   set <accepted|declined>  persist the state for the cwd's DIR-KEY.
#
# Store: one file per DIR-KEY under the dir-decisions dir, named by the sha256 of
# the DIR-KEY (so any path is a safe filename). File format:
#   line 1: the state word (accepted|declined)
#   line 2: "# <DIR-KEY>"   (cleartext key, for human traceability only)
# The state is written atomically (tmp + mv -f), mirroring the sibling scripts.
#
# Env overrides (for tests / custom config): CREDO_DIR_DECISIONS_DIR pins the
# store dir; otherwise CLAUDE_CONFIG_DIR (default $HOME/.claude) is used.
set -eu

STORE_DIR="${CREDO_DIR_DECISIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/credo/dir-decisions}"

# --- resolve the DIR-KEY: git toplevel if inside a repo, else $PWD -----------
resolve_key() {
    local top
    if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
        printf '%s' "$top"
    else
        printf '%s' "$PWD"
    fi
}

# --- hash a DIR-KEY into a safe filename -------------------------------------
hash_key() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

cmd="${1:-}"
case "$cmd" in
    key)
        resolve_key
        echo
        ;;
    get)
        key="$(resolve_key)"
        hash="$(hash_key "$key")"
        state_file="$STORE_DIR/$hash"
        if [ -f "$state_file" ]; then
            state="$(head -n1 "$state_file" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" || state=""
            case "$state" in
                accepted|declined) printf '%s\n' "$state" ;;
                *) printf '\n' ;;
            esac
        else
            printf '\n'
        fi
        exit 0
        ;;
    set)
        state="${2:-}"
        case "$state" in
            accepted|declined) ;;
            *)
                echo "Usage: credo-dir-decision.sh set <accepted|declined>" >&2
                exit 1
                ;;
        esac
        key="$(resolve_key)"
        hash="$(hash_key "$key")"
        mkdir -p "$STORE_DIR" || { echo "credo-dir-decision: cannot create store dir $STORE_DIR" >&2; exit 1; }
        state_file="$STORE_DIR/$hash"
        tmp="$(mktemp "${state_file}.XXXXXX")" || { echo "credo-dir-decision: mktemp failed" >&2; exit 1; }
        printf '%s\n# %s\n' "$state" "$key" > "$tmp"
        mv -f "$tmp" "$state_file"
        echo "credo-dir-decision = $state (dir $key)"
        ;;
    *)
        echo "usage: credo-dir-decision.sh {key|get|set <accepted|declined>}" >&2
        exit 1
        ;;
esac

#!/bin/bash
# Token-safe remote values for the dogma commands (sync, docs-update, ignore)
#
# Usage:
#   git-remote-safe.sh [url|host|owner|repo|owner-repo]     (default: url)
#
# The remote is read with git itself (origin, fallback: the first remote), so the script
# works in worktrees too. url prints the URL without userinfo (user, user:token) and
# without query string or fragment. host, owner, repo and owner-repo are taken from
# git-scope.sh. A URL whose userinfo cannot be told apart from the rest is refused, and
# the raw URL is never printed, not even in an error message.
#
# Examples:
#   git-remote-safe.sh url        -> https://github.com/owner/repo.git (userinfo stripped)
#   git-remote-safe.sh host       -> github.com
#   git-remote-safe.sh owner      -> owner
#   git-remote-safe.sh repo       -> repo
#   git-remote-safe.sh owner-repo -> owner/repo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "usage: git-remote-safe.sh [url|host|owner|repo|owner-repo]" >&2
    exit 1
}

fail() {
    echo "git-remote-safe: $1" >&2
    exit 1
}

# read_remote: URL of origin, else of the first remote (empty when there is none)
read_remote() {
    local url name
    url="$(git remote get-url origin 2>/dev/null)" || url=""
    if [ -z "$url" ]; then
        name="$(git remote 2>/dev/null | head -n 1)"
        if [ -n "$name" ]; then
            url="$(git remote get-url "$name" 2>/dev/null)" || url=""
        fi
    fi
    printf '%s' "$url"
}

# safe_url <url>: the URL without userinfo, query string and fragment; returns 1 when the
# userinfo cannot be told apart (a slash before the last @, or an @ in a local path)
safe_url() {
    local url="$1" head
    case "$url" in
        *://*)
            url="${url#*://}"
            url="${url%%\?*}"
            url="${url%%#*}"
            if [[ "$url" == *@* ]]; then
                head="${url%@*}"
                [[ "$head" == */* ]] && return 1
                url="${url##*@}"
            fi
            printf '%s://%s\n' "${1%%://*}" "$url"
            ;;
        *:*)
            if [[ "$url" == *@* ]]; then
                head="${url%@*}"
                [[ "$head" == */* ]] && return 1
                url="${url##*@}"
            fi
            printf '%s\n' "$url"
            ;;
        *)
            [[ "$url" == *@* ]] && return 1
            printf '%s\n' "$url"
            ;;
    esac
}

MODE="${1:-url}"
case "$MODE" in
    url | host | owner | repo | owner-repo) ;;
    *) usage ;;
esac

if [ "$MODE" = url ]; then
    REMOTE="$(read_remote)"
    [ -n "$REMOTE" ] || fail "no git remote configured"
    SAFE="$(safe_url "$REMOTE")" || fail "remote URL cannot be shown safely"
    printf '%s\n' "$SAFE"
    exit 0
fi

# host/owner/repo/owner-repo: git-scope.sh prints host/owner/repo of the same remote
SCOPE="$(bash "$SCRIPT_DIR/git-scope.sh")" || exit 1
case "$MODE" in
    host)
        printf '%s\n' "${SCOPE%%/*}"
        ;;
    owner)
        PARENT="${SCOPE%/*}"
        printf '%s\n' "${PARENT##*/}"
        ;;
    repo)
        printf '%s\n' "${SCOPE##*/}"
        ;;
    owner-repo)
        PARENT="${SCOPE%/*}"
        printf '%s\n' "${PARENT##*/}/${SCOPE##*/}"
        ;;
esac

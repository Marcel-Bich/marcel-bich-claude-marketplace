#!/usr/bin/env bash
# Owner/repo scope check without showing the remote URL.
#
# Prints <host>/<owner>/<repo> of the origin remote (fallback: the first remote) of the
# repository in [dir] (default: current directory). Scheme, userinfo (user or
# user:token), port, query, fragment, trailing slash and a .git suffix are dropped, and
# the result must match a strict character set. The raw URL is never printed, not even
# in an error message, so a token embedded in a remote URL cannot leak.
#
# Usage: git-scope.sh [dir]
# Exit:  0 scope printed, 1 no repository / no remote / no host/owner/repo form, 2 usage
set -u

usage() {
    echo "usage: git-scope.sh [dir]" >&2
    exit 2
}

fail() {
    echo "git-scope: $1" >&2
    exit 1
}

# scope_of <url>: prints host/path, returns 1 when the URL has no host/owner/repo form
scope_of() {
    local url="$1" authority path
    case "$url" in
        *://*)
            url="${url#*://}"
            authority="${url%%/*}"
            path=""
            [ "$authority" != "$url" ] && path="${url#*/}"
            ;;
        *:*)
            authority="${url%%:*}"
            path="${url#*:}"
            ;;
        *)
            return 1
            ;;
    esac
    authority="${authority##*@}"
    authority="${authority%%:*}"
    path="${path%%\?*}"
    path="${path%%#*}"
    path="${path%/}"
    path="${path#/}"
    path="${path%.git}"
    [[ "$authority" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$path" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]] || return 1
    printf '%s/%s\n' "$authority" "$path"
}

case $# in
    0) DIR="." ;;
    1) DIR="$1" ;;
    *) usage ;;
esac

git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || fail "not a git repository"

URL="$(git -C "$DIR" remote get-url origin 2>/dev/null)" || URL=""
if [ -z "$URL" ]; then
    FIRST_REMOTE="$(git -C "$DIR" remote 2>/dev/null | head -n 1)"
    if [ -n "$FIRST_REMOTE" ]; then
        URL="$(git -C "$DIR" remote get-url "$FIRST_REMOTE" 2>/dev/null)" || URL=""
    fi
fi
[ -n "$URL" ] || fail "no git remote configured"

SCOPE="$(scope_of "$URL")" || fail "remote URL has no host/owner/repo form"
printf '%s\n' "$SCOPE"

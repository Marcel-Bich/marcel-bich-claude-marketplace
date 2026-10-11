#!/usr/bin/env bash
# Tests for scripts/git-remote-safe.sh (token-safe remote values for the dogma commands).
#
# SAFETY: the script only reads the remote configuration of throwaway repositories
# created below a fresh mktemp directory. The fixtures carry invented credentials
# (user "dogmauser", token "tok123"); neither may appear in stdout or stderr of any mode.
# HOME and the git system configuration point into the temp root, so no insteadOf rule
# of the real machine can change the expected output.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFE="$HERE/git-remote-safe.sh"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-git-remote-safe-XXXXXX")"
cleanup() {
    case "$TEST_TMP_DIR" in
        "${TMPDIR:-/tmp}"/dogma-git-remote-safe-*) rm -rf -- "$TEST_TMP_DIR" ;;
    esac
}
trap cleanup EXIT

export HOME="$TEST_TMP_DIR/home"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

PASS=0
FAIL=0
pass() {
    PASS=$((PASS + 1))
    printf '[PASS] %s\n' "$1"
}
fail() {
    FAIL=$((FAIL + 1))
    printf '[FAIL] %s\n' "$1"
}

# run_safe <dir> [mode] -> sets OUT (stdout), ERR (stderr), RC (exit code)
run_safe() {
    local dir="$1"
    shift
    local errfile="$TEST_TMP_DIR/stderr"
    OUT="$(cd "$dir" && bash "$SAFE" "$@" 2>"$errfile")" && RC=0 || RC=$?
    ERR="$(cat "$errfile")"
}

# no_leak: the invented credentials and any userinfo marker must not show up
no_leak() {
    case "$OUT$ERR" in
        *tok123* | *dogmauser* | *@*) return 1 ;;
    esac
    return 0
}

# new_repo [remote-name remote-url]... -> sets REPO_DIR to a fresh repository
new_repo() {
    REPO_DIR="$(mktemp -d "$TEST_TMP_DIR/repo-XXXXXX")"
    git -C "$REPO_DIR" init -q
    while [ $# -ge 2 ]; do
        git -C "$REPO_DIR" remote add "$1" "$2"
        shift 2
    done
}

# expect_out <label> <expected> <dir> [mode]: exact stdout, rc 0, nothing on stderr
expect_out() {
    run_safe "$3" "${4:-}"
    if ! no_leak; then
        fail "$1: credential material in output"
    elif [ "$RC" -eq 0 ] && [ "$OUT" = "$2" ] && [ -z "$ERR" ]; then
        pass "$1"
    else
        fail "$1: want '$2' (rc 0), got '$OUT' (rc $RC) stderr '$ERR'"
    fi
}

# expect_refused <label> <needle> <dir> [mode]: nothing on stdout, rc != 0, neutral stderr
expect_refused() {
    run_safe "$3" "${4:-}"
    if ! no_leak; then
        fail "$1: credential material in output"
    elif [ "$RC" -ne 0 ] && [ -z "$OUT" ] && [[ "$ERR" == *"$2"* ]]; then
        pass "$1"
    else
        fail "$1: want rc != 0 with '$2' on stderr, got rc $RC, stdout '$OUT', stderr '$ERR'"
    fi
}

# url_case <label> <expected-url> <remote-url>: origin is <remote-url>, mode url
url_case() {
    new_repo origin "$3"
    expect_out "$1 (url)" "$2" "$REPO_DIR" url
}

# mode_case <label> <host> <owner> <repo> <remote-url>: all derived modes of one remote
mode_case() {
    new_repo origin "$5"
    expect_out "$1 (host)" "$2" "$REPO_DIR" host
    expect_out "$1 (owner)" "$3" "$REPO_DIR" owner
    expect_out "$1 (repo)" "$4" "$REPO_DIR" repo
    expect_out "$1 (owner-repo)" "$3/$4" "$REPO_DIR" owner-repo
}

# --- url: userinfo, query string and fragment never reach the output
url_case "https with user and token" "https://github.com/acme/demo.git" \
    "https://dogmauser:tok123@github.com/acme/demo.git"
url_case "https with a bare token as user" "https://github.com/acme/demo.git" \
    "https://tok123@github.com/acme/demo.git"
url_case "https with @ inside the password" "https://github.com/acme/demo.git" \
    "https://dogmauser:tok@123@github.com/acme/demo.git"
url_case "https query string dropped" "https://github.com/acme/demo.git" \
    "https://github.com/acme/demo.git?token=tok123"
url_case "https fragment dropped" "https://github.com/acme/demo.git" \
    "https://github.com/acme/demo.git#tok123"
url_case "https with port" "https://git.example.com:8443/acme/demo.git" \
    "https://dogmauser:tok123@git.example.com:8443/acme/demo.git"
url_case "ssh with user, token and port" "ssh://example.com:2222/acme/demo.git" \
    "ssh://dogmauser:tok123@example.com:2222/acme/demo.git"
url_case "scp style" "github.com:acme/demo.git" "git@github.com:acme/demo.git"
url_case "scp style with a bare token as user" "github.com:acme/demo.git" \
    "tok123@github.com:acme/demo.git"
url_case "scp style with user:token" "github.com:acme/demo.git" \
    "dogmauser:tok123@github.com:acme/demo.git"
url_case "local path without userinfo" "/srv/repos/demo.git" "/srv/repos/demo.git"

# --- userinfo that cannot be told apart is refused in every mode (never printed)
for mode in url host owner repo owner-repo; do
    new_repo origin "https://dogmauser:tok/123@github.com/acme/demo.git"
    expect_refused "slash inside the https userinfo refused ($mode)" "git-" "$REPO_DIR" "$mode"
    new_repo origin "dogmauser:tok/123@github.com:acme/demo.git"
    expect_refused "slash inside the scp userinfo refused ($mode)" "git-" "$REPO_DIR" "$mode"
    new_repo origin "/srv/dogmauser/tok123@x/demo.git"
    expect_refused "local path with @ refused ($mode)" "git-" "$REPO_DIR" "$mode"
done

# --- host, owner, repo and owner-repo
mode_case "https with user and token" "github.com" "acme" "demo" \
    "https://dogmauser:tok123@github.com/acme/demo.git"
mode_case "scp style" "github.com" "acme" "demo" "git@github.com:acme/demo.git"
mode_case "ssh with port" "example.com" "acme" "demo" "ssh://dogmauser:tok123@example.com:2222/acme/demo"
mode_case "nested group (owner is the parent of the repo)" "gitlab.example.com" "sub" "demo" \
    "https://gitlab.example.com/group/sub/demo.git"

# --- remote selection: origin wins, otherwise the first remote is used
new_repo upstream "https://github.com/other/fork.git" origin "https://dogmauser:tok123@github.com/acme/demo.git"
expect_out "origin preferred over upstream (url)" "https://github.com/acme/demo.git" "$REPO_DIR" url

new_repo upstream "git@gitlab.example.com:team/tool.git"
expect_out "first remote used without origin (url)" "gitlab.example.com:team/tool.git" "$REPO_DIR" url

# --- default mode is url
new_repo origin "https://dogmauser:tok123@github.com/acme/demo.git"
expect_out "no mode argument prints the url" "https://github.com/acme/demo.git" "$REPO_DIR"

# --- worktree: .git is a file there, git itself must find the remote
new_repo origin "https://dogmauser:tok123@github.com/acme/demo.git"
git -C "$REPO_DIR" -c user.name=dogma-test -c user.email=dogma-test@example.invalid commit -q --allow-empty -m init
WORKTREE_DIR="$TEST_TMP_DIR/worktree"
git -C "$REPO_DIR" worktree add -q --detach "$WORKTREE_DIR"
expect_out "worktree url" "https://github.com/acme/demo.git" "$WORKTREE_DIR" url
expect_out "worktree owner-repo" "acme/demo" "$WORKTREE_DIR" owner-repo

# --- errors: nothing on stdout, neutral message, no credential material
new_repo
expect_refused "no remote configured (url)" "git-remote-safe:" "$REPO_DIR" url
expect_refused "no remote configured (owner-repo)" "git-" "$REPO_DIR" owner-repo

PLAIN_DIR="$TEST_TMP_DIR/plain"
mkdir -p "$PLAIN_DIR"
expect_refused "directory is not a git repository (url)" "git-remote-safe:" "$PLAIN_DIR" url

new_repo origin "https://dogmauser:tok123@github.com/acme/demo.git"
expect_refused "unknown mode" "usage:" "$REPO_DIR" bogus

echo "git-remote-safe tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0

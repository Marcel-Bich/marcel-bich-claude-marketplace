#!/usr/bin/env bash
# Tests for scripts/git-scope.sh (owner/repo scope of the origin remote).
#
# SAFETY: the script only reads the remote configuration of throwaway repositories
# created below a fresh mktemp directory. The fixtures carry invented credentials
# (user "dogmauser", token "tok123"); neither may appear in stdout or stderr.
# HOME and the git system configuration point into the temp root, so no insteadOf
# rule of the real machine can change the expected output.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCOPE="$HERE/git-scope.sh"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-git-scope-XXXXXX")"
cleanup() {
    case "$TEST_TMP_DIR" in
        "${TMPDIR:-/tmp}"/dogma-git-scope-*) rm -rf -- "$TEST_TMP_DIR" ;;
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

# run_scope [args...] -> sets OUT (stdout), ERR (stderr), RC (exit code)
run_scope() {
    local errfile="$TEST_TMP_DIR/stderr"
    OUT="$(bash "$SCOPE" "$@" 2>"$errfile")" && RC=0 || RC=$?
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

# expect_scope <label> <expected> <url>: origin is <url>, the scope must be printed
expect_scope() {
    new_repo origin "$3"
    run_scope "$REPO_DIR"
    if ! no_leak; then
        fail "$1: credential material in output"
    elif [ "$RC" -eq 0 ] && [ "$OUT" = "$2" ] && [ -z "$ERR" ]; then
        pass "$1"
    else
        fail "$1: want '$2' (rc 0), got '$OUT' (rc $RC) stderr '$ERR'"
    fi
}

# expect_fail <label> <rc> <stderr-needle> [args...]: nothing on stdout, neutral error
expect_fail() {
    local label="$1" want_rc="$2" needle="$3"
    shift 3
    run_scope "$@"
    if ! no_leak; then
        fail "$label: credential material in output"
    elif [ "$RC" -eq "$want_rc" ] && [ -z "$OUT" ] && [[ "$ERR" == *"$needle"* ]]; then
        pass "$label"
    else
        fail "$label: want rc $want_rc with '$needle' on stderr, got rc $RC, stdout '$OUT', stderr '$ERR'"
    fi
}

# --- URL forms: scheme, userinfo, port, query and .git suffix are all dropped
expect_scope "https with user and token" "github.com/acme/demo" \
    "https://dogmauser:tok123@github.com/acme/demo.git"
expect_scope "https without .git and with trailing slash" "github.com/acme/demo" \
    "https://github.com/acme/demo/"
expect_scope "https with port and query string" "git.example.com/acme/demo" \
    "https://dogmauser:tok123@git.example.com:8443/acme/demo.git?token=tok123"
expect_scope "https with @ inside the password" "github.com/acme/demo" \
    "https://dogmauser:tok@123@github.com/acme/demo.git"
expect_scope "scp style" "github.com/acme/demo" "git@github.com:acme/demo.git"
expect_scope "scp style with a bare token as user" "github.com/acme/demo" \
    "tok123@github.com:acme/demo.git"
expect_scope "scp style with absolute path" "example.com/acme/demo" \
    "git@example.com:/acme/demo.git"
expect_scope "ssh with user and port" "example.com/acme/demo" \
    "ssh://git@example.com:2222/acme/demo"
expect_scope "ssh with user, token and port" "example.com/acme/demo" \
    "ssh://dogmauser:tok123@example.com:2222/acme/demo.git"
expect_scope "git protocol" "example.com/acme/demo" "git://example.com/acme/demo.git"
expect_scope "nested group path" "gitlab.example.com/group/sub/demo" \
    "https://gitlab.example.com/group/sub/demo.git"

# --- remote selection: origin wins, otherwise the first remote is used
new_repo upstream "https://github.com/other/fork.git" origin "https://dogmauser:tok123@github.com/acme/demo.git"
run_scope "$REPO_DIR"
if ! no_leak; then
    fail "origin preferred over upstream: credential material in output"
elif [ "$RC" -eq 0 ] && [ "$OUT" = "github.com/acme/demo" ]; then
    pass "origin preferred over upstream"
else
    fail "origin preferred over upstream: got '$OUT' (rc $RC)"
fi

new_repo upstream "git@gitlab.example.com:team/tool.git"
run_scope "$REPO_DIR"
if ! no_leak; then
    fail "first remote used without origin: credential material in output"
elif [ "$RC" -eq 0 ] && [ "$OUT" = "gitlab.example.com/team/tool" ]; then
    pass "first remote used without origin"
else
    fail "first remote used without origin: got '$OUT' (rc $RC)"
fi

# --- default directory is the current working directory
new_repo origin "https://dogmauser:tok123@github.com/acme/demo.git"
cd "$REPO_DIR" || exit 1
run_scope
cd "$TEST_TMP_DIR" || exit 1
if ! no_leak; then
    fail "no argument uses the current directory: credential material in output"
elif [ "$RC" -eq 0 ] && [ "$OUT" = "github.com/acme/demo" ]; then
    pass "no argument uses the current directory"
else
    fail "no argument uses the current directory: got '$OUT' (rc $RC)"
fi

# --- errors: exit non-zero, neutral message, nothing on stdout, no credential material
new_repo
expect_fail "no remote configured" 1 "no git remote configured" "$REPO_DIR"

PLAIN_DIR="$TEST_TMP_DIR/plain"
mkdir -p "$PLAIN_DIR"
expect_fail "directory is not a git repository" 1 "not a git repository" "$PLAIN_DIR"
expect_fail "directory does not exist" 1 "not a git repository" "$TEST_TMP_DIR/missing"

new_repo origin "/srv/dogmauser/tok123/demo.git"
expect_fail "local path remote has no host" 1 "no host/owner/repo" "$REPO_DIR"

new_repo origin "https://dogmauser:tok123@/"
expect_fail "userinfo without host" 1 "no host/owner/repo" "$REPO_DIR"

new_repo origin "https://dogmauser:tok/123@github.com/acme/demo.git"
expect_fail "slash inside the userinfo is refused" 1 "no host/owner/repo" "$REPO_DIR"

expect_fail "more than one argument" 2 "usage:" "$REPO_DIR" "$REPO_DIR"

echo "git-scope tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0

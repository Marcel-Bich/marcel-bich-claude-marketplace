#!/bin/bash
# Test script for hooks/jq-missing-warn.sh (the SessionStart jq check) and its registration
# in hooks/hooks.json.
# Covers: without jq on PATH the hook prints valid hook JSON (systemMessage for the user,
# additionalContext for the agent) that names the missing jq, the protection hooks that are
# OFF, the install command and the instruction to pass it on; exit 0, no blocking, stdin
# ignored; with jq on PATH no output; CLAUDE_MB_DOGMA_ENABLED=false silent; hooks.json
# registers the hook under SessionStart.
# jq is never installed here: "no jq" is a PATH without it, "jq present" is a stub jq.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/jq-missing-warn.sh"
HOOKS_JSON="$SCRIPT_DIR/../hooks/hooks.json"
BASH_BIN="$(command -v bash)"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-jq-missing-warn-XXXXXX")"
cleanup() {
    case "$TEST_TMP_DIR" in
        "${TMPDIR:-/tmp}"/dogma-jq-missing-warn-??????) rm -rf -- "$TEST_TMP_DIR" ;;
        *) echo "refusing to remove unexpected temp root: '$TEST_TMP_DIR'" >&2 ;;
    esac
}
trap cleanup EXIT

# PATH without jq: every entry of the system bin dirs except jq, linked into a fresh dir.
NOJQ_DIR="$TEST_TMP_DIR/nojq-bin"
mkdir -p "$NOJQ_DIR"
for dir in /usr/local/bin /usr/bin /bin; do
    [ -d "$dir" ] || continue
    for file in "$dir"/*; do
        [ -e "$file" ] || continue
        name="${file##*/}"
        [ "$name" = "jq" ] && continue
        if [ ! -e "$NOJQ_DIR/$name" ] && [ ! -L "$NOJQ_DIR/$name" ]; then
            ln -s "$file" "$NOJQ_DIR/$name"
        fi
    done
done

# PATH with jq: a stub jq in front of the same bin dir (presence is all the hook checks).
JQ_STUB_DIR="$TEST_TMP_DIR/jq-stub-bin"
mkdir -p "$JQ_STUB_DIR"
printf '#!/bin/sh\nexit 0\n' > "$JQ_STUB_DIR/jq"
chmod +x "$JQ_STUB_DIR/jq"
WITH_JQ_PATH="$JQ_STUB_DIR:$NOJQ_DIR"

# Empty stdin, and a SessionStart payload the hook must ignore (no jq to parse it).
STDIN_FILE="$TEST_TMP_DIR/empty-stdin"
: > "$STDIN_FILE"
PAYLOAD_FILE="$TEST_TMP_DIR/session-payload"
printf '%s' '{"session_id":"dogma-test-session","cwd":"/home/myuser/proj","source":"startup"}' > "$PAYLOAD_FILE"

ERRFILE="$TEST_TMP_DIR/stderr"

run_test() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "[FAIL] $description"
        echo "       Expected: '$expected'"
        echo "       Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Runs the hook with the given PATH and STDIN_FILE; sets OUT (stdout) and RC (exit code).
run_hook() {
    OUT="$(env PATH="$1" "$BASH_BIN" "$HOOK" <"$STDIN_FILE" 2>"$ERRFILE")" && RC=0 || RC=$?
}

# Shell lookup of jq on the given PATH: prints the path found, or nothing.
jq_on_path() {
    env PATH="$1" "$BASH_BIN" -c 'command -v jq || true'
}

# Evaluates a Python expression over the parsed hook JSON (d); prints true or false.
json_check() {
    printf '%s' "$OUT" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("false")
    sys.exit(0)
try:
    print("true" if bool(eval(sys.argv[1])) else "false")
except (KeyError, TypeError):
    print("false")
' "$1"
}

# Precondition: the simulation really removes jq and the stub really provides it.
run_test "PATH without jq: jq is not found" "" "$(jq_on_path "$NOJQ_DIR")"
run_test "PATH with the jq stub: jq is found" "$JQ_STUB_DIR/jq" "$(jq_on_path "$WITH_JQ_PATH")"

# Without jq: the warning.
run_hook "$NOJQ_DIR"
run_test "without jq: exit 0" "0" "$RC"
run_test "without jq: hook output is a JSON object" "true" "$(json_check 'isinstance(d, dict)')"
run_test "without jq: SessionStart event" "true" "$(json_check 'd["hookSpecificOutput"]["hookEventName"] == "SessionStart"')"
run_test "without jq: systemMessage says jq is NOT installed" "true" "$(json_check '"jq is NOT installed" in d["systemMessage"]')"
run_test "without jq: systemMessage names the OFF protection hooks" "true" "$(json_check 'all(x in d["systemMessage"] for x in ["delete guard", "git permissions", "dependency verification"])')"
run_test "without jq: systemMessage says other marketplace plugins degrade" "true" "$(json_check '"other marketplace plugins" in d["systemMessage"]')"
run_test "without jq: systemMessage urges installing jq now" "true" "$(json_check '"Install jq now: " in d["systemMessage"] and "install jq" in d["systemMessage"]')"
run_test "without jq: additionalContext says jq is NOT installed" "true" "$(json_check '"jq is NOT installed" in d["hookSpecificOutput"]["additionalContext"]')"
run_test "without jq: additionalContext tells the agent to tell the user prominently" "true" "$(json_check '"Tell the user this prominently" in d["hookSpecificOutput"]["additionalContext"]')"
run_test "without jq: additionalContext forbids the agent to install jq itself" "true" "$(json_check '"Do not install jq yourself" in d["hookSpecificOutput"]["additionalContext"]')"
run_test "without jq: no blocking (no decision, continue not false)" "true" "$(json_check '"decision" not in d and d.get("continue", True) is True')"

# Without jq and with a session payload on stdin: same warning, payload ignored.
STDIN_FILE="$PAYLOAD_FILE"
run_hook "$NOJQ_DIR"
run_test "without jq, with stdin payload: exit 0" "0" "$RC"
run_test "without jq, with stdin payload: warning still valid JSON with jq message" "true" "$(json_check '"jq is NOT installed" in d["systemMessage"]')"
STDIN_FILE="$TEST_TMP_DIR/empty-stdin"

# With jq: nothing changes.
run_hook "$WITH_JQ_PATH"
run_test "with jq: exit 0" "0" "$RC"
run_test "with jq: no output" "" "$OUT"

# Master switch: silent without jq when dogma is disabled.
OUT="$(env CLAUDE_MB_DOGMA_ENABLED=false PATH="$NOJQ_DIR" "$BASH_BIN" "$HOOK" <"$STDIN_FILE" 2>/dev/null)"
run_test "CLAUDE_MB_DOGMA_ENABLED=false without jq: no output" "" "$OUT"

# Wiring: registered under SessionStart in hooks.json and executable.
run_test "hooks.json registers the hook under SessionStart" "true" "$(python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
cmds = [h.get("command", "") for g in d["hooks"]["SessionStart"] for h in g.get("hooks", [])]
print("true" if any("hooks/jq-missing-warn.sh" in c for c in cmds) else "false")
' "$HOOKS_JSON")"
run_test "hook file is executable" "true" "$([ -x "$HOOK" ] && echo true || echo false)"

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_TOTAL total"

[ "$TESTS_FAILED" -eq 0 ]

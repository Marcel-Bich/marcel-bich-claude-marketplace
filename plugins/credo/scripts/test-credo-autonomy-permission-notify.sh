#!/usr/bin/env bash
# Tests for hooks/credo-autonomy-permission-notify.sh: a permission prompt in an
# autonomous session sends one high-priority ntfy; every other case stays silent.
#
# NOTHING real is sent: CREDO_NTFY_SEND points at a stub that records its calls,
# the autonomy state lives in temp dirs, and no network is used.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-autonomy-permission-notify.sh"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
unset CREDO_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_CONFIG_DIR="$TMP/cfg"
export CREDO_NTFY_SEND="$TMP/ntfy-stub.sh"
CALLS="$TMP/calls"

# stub sender: one block per call (priority line, one line per arg, then "end")
cat > "$CREDO_NTFY_SEND" <<STUB
#!/usr/bin/env bash
{
    printf 'priority=%s\n' "\${CREDO_NTFY_PRIORITY:-}"
    for a in "\$@"; do printf 'arg=%s\n' "\$a"; done
    printf 'end\n'
} >> "$CALLS"
STUB
chmod +x "$CREDO_NTFY_SEND"

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

# fresh autonomy dir and empty call log for each case
new_case() {
    n=$((n + 1))
    export CREDO_AUTONOMY_DIR="$TMP/autonomy-$n"
    mkdir -p "$CREDO_AUTONOMY_DIR/$SID"
    : > "$CALLS"
}
arm() { : > "$CREDO_AUTONOMY_DIR/$SID/active"; }
n=0

# notif <message> [notification_type]: a Notification hook payload for the session
notif() {
    jq -n --arg s "$SID" --arg c "$TMP/proj-acme" --arg m "$1" --arg t "${2:-permission_prompt}" \
        '{session_id: $s, cwd: $c, hook_event_name: "Notification", message: $m, notification_type: $t}'
}

# run <stdin>: hook stdout in OUT, exit status in RC
run() {
    OUT="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"
    RC=$?
}

calls_count() { grep -c '^priority=' "$CALLS" 2>/dev/null || true; }

# the sender runs in the background: poll up to ~10 s for its first call
wait_for_call() {
    local i=0
    while [ "$i" -lt 100 ]; do
        [ "$(calls_count)" -ge 1 ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# a negative case never forks the sender; the settle only guards against a late one
settle() { sleep 0.5; }

# --- autonomous session, permission prompt: one high-priority push ----------------
new_case; arm
run "$(notif "Claude needs your permission to use Bash")"
check "permission prompt: rc 0" 0 "$RC"
check "permission prompt: hook prints nothing" "" "$OUT"
if wait_for_call; then got=sent; else got=none; fi
settle
check "autonomous permission prompt sends one ntfy" sent "$got"
check "ntfy count is one" 1 "$(calls_count)"
check "ntfy priority is high" 1 "$(grep -c '^priority=high$' "$CALLS")"
check "title names the blocked run" 1 "$(grep -c '^arg=credo: permission prompt blocks run$' "$CALLS")"
check "body names the project dir basename" 1 "$(grep -c '^arg=.*proj-acme' "$CALLS")"
check "body carries the prompt message" 1 "$(grep -c '^arg=.*Claude needs your permission to use Bash' "$CALLS")"

# --- not autonomous (no active flag): silent --------------------------------------
new_case
run "$(notif "Claude needs your permission to use Bash")"
settle
check "not autonomous: rc 0" 0 "$RC"
check "not autonomous: no ntfy" 0 "$(calls_count)"

# --- autonomy paused (opt-out): silent ---------------------------------------------
new_case; arm; : > "$CREDO_AUTONOMY_DIR/$SID/paused"
run "$(notif "Claude needs your permission to use Bash")"
settle
check "paused: rc 0" 0 "$RC"
check "paused: no ntfy" 0 "$(calls_count)"

# --- other notification types: silent even when autonomous -------------------------
for t in idle_prompt auth_success elicitation_dialog; do
    new_case; arm
    run "$(notif "some notice" "$t")"
    settle
    check "notification_type $t: no ntfy" 0 "$(calls_count)"
done

# --- garbage, empty or incomplete stdin: rc 0, silent -------------------------------
new_case; arm
run ""
check "empty stdin: rc 0" 0 "$RC"
run "not json at all"
check "garbage stdin: rc 0" 0 "$RC"
check "garbage stdin: hook prints nothing" "" "$OUT"
run '{"notification_type": "permission_prompt", "message": "x"'
check "truncated json: rc 0" 0 "$RC"
run '{"notification_type": "permission_prompt", "message": "no session id"}'
check "no session id: rc 0" 0 "$RC"
settle
check "garbage and incomplete stdin: no ntfy" 0 "$(calls_count)"

# --- long message is truncated to about 200 characters -----------------------------
new_case; arm
long="$(printf '%0400d' 0)"
run "$(notif "$long")"
wait_for_call
settle
body="$(grep '^arg=Project' "$CALLS" | head -n 1)"
if [ -n "$body" ] && [ "${#body}" -le 260 ]; then got=short; else got="long(${#body})"; fi
check "long prompt message is truncated" short "$got"

# --- control characters are stripped from the body ---------------------------------
new_case; arm
ctrl="$(printf 'bad\033[31m red\ttext')"
run "$(notif "$ctrl")"
wait_for_call
settle
if grep -q "$(printf '\033')" "$CALLS"; then got=kept; else got=stripped; fi
check "control characters are stripped" stripped "$got"
check "message text survives the strip" 1 "$(grep -c 'bad' "$CALLS")"

# --- no jq on PATH: silent exit 0 ----------------------------------------------------
NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for t in bash cat dirname tr; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
new_case; arm
payload="$(notif "Claude needs your permission to use Bash")"
OUT="$(printf '%s' "$payload" | PATH="$NOJQ" bash "$HOOK" 2>/dev/null)"
RC=$?
check "no jq: rc 0" 0 "$RC"
check "no jq: hook prints nothing" "" "$OUT"
settle
check "no jq: no ntfy" 0 "$(calls_count)"

# --- sender missing or not executable: rc 0, silent ----------------------------------
new_case; arm
payload="$(notif "Claude needs your permission to use Bash")"
OUT="$(printf '%s' "$payload" | CREDO_NTFY_SEND="$TMP/absent-sender" bash "$HOOK" 2>/dev/null)"
RC=$?
check "missing sender: rc 0" 0 "$RC"
check "missing sender: hook prints nothing" "" "$OUT"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]

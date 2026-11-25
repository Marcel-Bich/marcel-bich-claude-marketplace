#!/usr/bin/env bash
# Tests for the paused hint of hooks/credo-autonomy-keepalive.sh (#211): while an owner
# message paused an autonomous run and GO items are open, the Stop hook never blocks
# but prints one systemMessage for the user; every other case is a silent normal stop.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-autonomy-keepalive.sh"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export CREDO_AUTONOMY_DIR="$TMP/autonomy"
export CREDO_SESSION_MODES_DIR="$TMP/modes"
export CLAUDE_CONFIG_DIR="$TMP/cfg"
unset CREDO_DIR CREDO_PROJECT CREDO_SESSION_ID CLAUDE_CODE_SESSION_ID

PROJ="$TMP/proj"
GO="$PROJ/.credo/items/1_todo/2_go"
mkdir -p "$GO" "$PROJ/.credo/items/1_todo/1_clarify" "$CREDO_AUTONOMY_DIR/$SID" "$CREDO_SESSION_MODES_DIR"

check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

state() { # <paused content or "none"> <mode>
    rm -f "$CREDO_AUTONOMY_DIR/$SID/paused" "$CREDO_AUTONOMY_DIR/$SID/active"
    [ "$1" = none ] || printf '%s' "$1" > "$CREDO_AUTONOMY_DIR/$SID/paused"
    printf '%s\n' "$2" > "$CREDO_SESSION_MODES_DIR/$SID"
}

stop() { # [stop_hook_active] -> stdout; rc in $RC
    local act="${1:-false}"
    OUT="$(jq -n --arg s "$SID" --arg c "$PROJ" --argjson a "$act" \
        '{session_id: $s, cwd: $c, stop_hook_active: $a}' | bash "$HOOK" 2>/dev/null)"
    RC=$?
}

: > "$GO/7-some-go-item.md"
: > "$GO/8-other-go-item.md"

state "user-message" autonomous; stop
check "user pause + GO items: exit 0 (never blocks)" 0 "$RC"
case "$OUT" in *'"systemMessage"'*"PAUSED"*) got=hint ;; *) got="none ($OUT)" ;; esac
check "user pause + GO items: systemMessage hint" hint "$got"
case "$OUT" in *"2 GO item(s)"*) got=yes ;; *) got=no ;; esac
check "hint names the GO count" yes "$got"
case "$OUT" in *"/credo:session-autonomous"*"credo-autonomy-on.sh --session $SID"*) got=yes ;; *) got=no ;; esac
check "hint names both ways to end the pause" yes "$got"
printf '%s' "$OUT" | jq -e '.systemMessage' >/dev/null 2>&1 && got=json || got=invalid
check "hint is valid JSON" json "$got"

state "user-message" autonomous; stop true
check "continuation stop (stop_hook_active): no hint" "" "$OUT"

state "" autonomous; stop
check "deliberate off (empty paused): no hint" "" "$OUT"
check "deliberate off: exit 0" 0 "$RC"

state "user-message" active; stop
check "mode active: no hint" "" "$OUT"

state "user-message" passive; stop
check "mode passive: no hint" "" "$OUT"

mv "$GO/7-some-go-item.md" "$GO/8-other-go-item.md" "$PROJ/.credo/items/1_todo/1_clarify/"
state "user-message" autonomous; stop
check "no GO item: no hint" "" "$OUT"
check "no GO item: exit 0" 0 "$RC"
mv "$PROJ/.credo/items/1_todo/1_clarify/7-some-go-item.md" "$GO/"

# no credo project in the cwd: silent
OUT="$(jq -n --arg s "$SID" --arg c "$TMP" '{session_id: $s, cwd: $c, stop_hook_active: false}' \
    | bash "$HOOK" 2>/dev/null)"; RC=$?
check "no project: no hint" "" "$OUT"
check "no project: exit 0" 0 "$RC"

# no jq: fail open, silent normal stop
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for t in bash cat tr date rm grep sed dirname basename ls sort tail find printf head mkdir timeout wc git; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
state "user-message" autonomous
OUT="$(printf '{"session_id": "%s", "cwd": "%s", "stop_hook_active": false}' "$SID" "$PROJ" \
    | PATH="$NOJQ" bash "$HOOK" 2>/dev/null)"; RC=$?
check "no jq: no hint" "" "$OUT"
check "no jq: exit 0" 0 "$RC"

# not paused, autonomy active without wake: the keep-alive block still applies
state none autonomous; : > "$CREDO_AUTONOMY_DIR/$SID/active"; stop
check "active autonomy without wake still blocks" 2 "$RC"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]

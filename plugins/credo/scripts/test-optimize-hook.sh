#!/bin/bash
# Tests for hooks/credo-optimize-hook.sh (SessionStart + UserPromptSubmit). Builds a
# throwaway git repo and isolated credo state dirs in a temp dir (removed on exit)
# and feeds the hook fake hook-stdin JSON. Usage: bash test-optimize-hook.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/credo-optimize-hook.sh"
STATE="$SCRIPT_DIR/credo-optimize-state.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-optimize-hook-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
export CREDO_OPTIMIZE_DIR="$TMP/store" CREDO_GLOBAL="$TMP/no-global" CREDO_PROFILE="$TMP/no-profile"
export CREDO_SESSION_MODES_DIR="$TMP/modes" CREDO_SESSION_DECISIONS_DIR="$TMP/decisions"
export CREDO_DIR_DECISIONS_DIR="$TMP/dirdec" CREDO_AUTONOMY_DIR="$TMP/autonomy"
export CREDO_TASK_BACKEND=credo
unset CREDO_OPTIMIZE_IDLE_DAYS CREDO_DIR CREDO_PROJECT CREDO_OPTIMIZE_HOOK
mkdir -p "$CREDO_SESSION_MODES_DIR" "$CREDO_SESSION_DECISIONS_DIR"

NOW="$(date +%s)"
export CREDO_OPTIMIZE_NOW="$NOW"
OLD="@$((NOW - 10 * 86400))"

R="$TMP/repo"
git init -q "$R"
git -C "$R" commit -q --allow-empty -m init
cd "$R" || exit 1

SID="sess-1"
hook() { # event source
    printf '{"hook_event_name":"%s","session_id":"%s","source":"%s"}' "$1" "$SID" "$2" | "$HOOK"
}
age_all_old() {
    touch -d "$OLD" "$R/.git/logs/HEAD" "$R/.git/index"
    "$STATE" seen "$((NOW - 10 * 86400))"
}

# UserPromptSubmit only records last-seen
out="$(hook UserPromptSubmit "")"
check "prompt silent" "" "$out"
check "prompt sets last-seen" "$NOW" "$("$STATE" get-seen)"

# opt-in question: only when credo is active here, on startup/clear
check "not active -> no opt-in question" "" "$(hook SessionStart startup)"
"$SCRIPT_DIR/credo-dir-decision.sh" set accepted >/dev/null
out="$(hook SessionStart startup)"
contains "active startup -> opt-in question" "Optimisation audit wanted" "$out"
contains "opt-in question names the state script" "optin yes" "$out"
check "resume -> no opt-in question" "" "$(hook SessionStart resume)"
printf 'autonomous\n' > "$CREDO_SESSION_MODES_DIR/$SID"
check "autonomous -> no opt-in question" "" "$(hook SessionStart startup)"
rm -f "$CREDO_SESSION_MODES_DIR/$SID"

# opt-in no: never offered automatically
"$STATE" optin no >/dev/null
age_all_old
check "optin no -> silent" "" "$(hook SessionStart startup)"

# opt-in yes, actively working -> no offer
"$STATE" optin yes >/dev/null
"$STATE" seen "$NOW"
check "active user -> no offer" "" "$(hook SessionStart startup)"
check "active user -> nothing pending" "" "$("$STATE" get-pending)"

# returner -> offer (also on resume), evaluated before last-seen is updated
age_all_old
out="$(hook SessionStart resume)"
contains "returner -> offer" "Welcome-back offer" "$out"
contains "offer names the threshold" "at least 7 days" "$out"
check "offer marks pending" "$NOW" "$("$STATE" get-pending)"
check "last-seen updated after the check" "$NOW" "$("$STATE" get-seen)"
contains "still pending -> offered again" "Welcome-back offer" "$(hook SessionStart startup)"
"$STATE" offered >/dev/null
check "asked once -> no further offer" "" "$(hook SessionStart startup)"

# returner in autonomous mode -> stays pending, no output
age_all_old
mkdir -p "$CREDO_AUTONOMY_DIR/$SID"; : > "$CREDO_AUTONOMY_DIR/$SID/active"
check "autonomous -> no offer" "" "$(hook SessionStart startup)"
check "autonomous -> offer pending" "$NOW" "$("$STATE" get-pending)"
rm -f "$CREDO_AUTONOMY_DIR/$SID/active"
contains "next attended start -> pending offer" "Welcome-back offer" "$(hook SessionStart startup)"
"$STATE" offered >/dev/null

# gsd backend -> SessionStart silent
age_all_old
check "gsd backend -> silent" "" "$(CREDO_TASK_BACKEND=gsd hook SessionStart startup)"

# declined dir -> fully silent, last-seen untouched
"$SCRIPT_DIR/credo-dir-decision.sh" set declined >/dev/null
"$STATE" seen 1000
check "declined -> silent" "" "$(hook SessionStart startup)"
hook UserPromptSubmit "" >/dev/null
check "declined -> last-seen untouched" "1000" "$("$STATE" get-seen)"

# toggle off
"$SCRIPT_DIR/credo-dir-decision.sh" set accepted >/dev/null
"$STATE" seen 1000
CREDO_OPTIMIZE_HOOK=false hook UserPromptSubmit "" >/dev/null
check "toggle off -> nothing written" "1000" "$("$STATE" get-seen)"

# not a git repo -> silent, exit 0
mkdir -p "$TMP/plain"
out="$(cd "$TMP/plain" && printf '{"hook_event_name":"SessionStart","session_id":"x","source":"startup"}' | "$HOOK")"; rc=$?
check "plain dir exit" 0 "$rc"
check "plain dir silent" "" "$out"

printf 'test-optimize-hook: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

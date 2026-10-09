#!/bin/bash
# Tests for the tmux hint of hooks/credo-session-start.sh: shown once per start/resume
# outside tmux while credo is active; never inside tmux, never in autonomous mode, never
# after the user declined it in /credo:setup Step 11 (tmux.hint: false in the credo
# config), never in a non-terminal host (CLAUDE_CODE_ENTRYPOINT set and not "cli"), and
# not with CREDO_TMUX_HINT=false. Temp config dirs only; invented session id.
#
# Usage: bash test-credo-session-start-tmux.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-session-start.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csst.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
SID="99999999-8888-7777-6666-555555555555"
export CLAUDE_CONFIG_DIR="$TMP/cfg" CREDO_SESSION_MODES_DIR="$TMP/modes" \
    CREDO_SESSION_DECISIONS_DIR="$TMP/decisions" CREDO_SKIP_ENSURE=1 \
    CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROFILE="$TMP/none-profile" CREDO_PROJECT="$TMP/none-project"
mkdir -p "$CREDO_SESSION_MODES_DIR" "$CREDO_SESSION_DECISIONS_DIR" "$CLAUDE_CONFIG_DIR"
: > "$CREDO_GLOBAL"

PASS=0
FAIL=0
hint() { # source [extra var assignments...] -> "yes" / "no"
    local src="$1"; shift
    local out
    out="$(printf '{"session_id": "%s", "source": "%s", "cwd": "%s"}' "$SID" "$src" "$TMP" \
        | ( cd "$TMP" && env -u TMUX -u CLAUDE_CODE_ENTRYPOINT "$@" bash "$HOOK" 2>/dev/null ))"
    case "$out" in *"does not run inside tmux"*) echo yes ;; *) echo no ;; esac
}
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s (want %s, got %s)\n' "$1" "$2" "$3"; fi
}

echo active > "$CREDO_SESSION_MODES_DIR/$SID"
check "outside tmux, startup -> hint" yes "$(hint startup)"
check "outside tmux, resume -> hint" yes "$(hint resume)"
check "compact -> no hint" no "$(hint compact)"
check "inside tmux -> no hint" no "$(hint startup TMUX=/tmp/fixture-sock,1,0)"
check "CREDO_TMUX_HINT=false -> no hint" no "$(hint startup CREDO_TMUX_HINT=false)"
check "terminal host (entrypoint cli) -> hint" yes "$(hint startup CLAUDE_CODE_ENTRYPOINT=cli)"
check "non-terminal host -> no hint" no "$(hint startup CLAUDE_CODE_ENTRYPOINT=sdk-ts)"
printf 'tmux:\n  hint: false\n' > "$CREDO_GLOBAL"
check "declined in setup (tmux.hint false) -> no hint" no "$(hint startup)"
printf 'tmux:\n  hint: true\n' > "$CREDO_GLOBAL"
check "tmux.hint true -> hint" yes "$(hint startup)"
echo autonomous > "$CREDO_SESSION_MODES_DIR/$SID"
check "autonomous -> no hint" no "$(hint startup)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

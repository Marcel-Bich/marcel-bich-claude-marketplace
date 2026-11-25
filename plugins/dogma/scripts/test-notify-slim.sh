#!/bin/bash
# Tests for #215: lib-notify.sh (repeat subagent notification detector, own state, no
# credo dependency) and the silent path of the dogma UserPromptSubmit hooks on a repeat
# notification. The first notification of a task-id, Monitor events, owner prompts and
# peer messages keep the full dogma injects.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dogma-notify-slim-XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg"
export DOGMA_SESSION_DIR="$TMP/session" DOGMA_CREDO_CONFIG=none
export CLAUDE_MB_DOGMA_CREDO_DEFER=false
mkdir -p "$TMP/session" "$TMP/project/CLAUDE"
echo "# Subagents" > "$TMP/project/CLAUDE/CLAUDE.subagents.md"
echo "# Intervention" > "$TMP/project/CLAUDE/CLAUDE.prompt-intervention.md"
printf -- '- [ ] open task\n' > "$TMP/project/TODO.md"

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

NL=$'\n'
agent_block() {
    printf '<task-notification>\n<task-id>%s</task-id>\n<status>completed</status>\n<summary>Agent "Build #1" finished</summary>\n</task-notification>' "$1"
}

# shellcheck source=lib-notify.sh
. "$SCRIPT_DIR/lib-notify.sh"
check "lib: no credo reference in the code" "" "$(grep -v '^#' "$SCRIPT_DIR/lib-notify.sh" | grep -i credo)"
check "detector: agent block -> id" "a1" "$(dogma_notify_agent_ids "$(agent_block a1)" | tr -d '\n')"
dogma_notify_agent_ids "fix this${NL}$(agent_block a2)" >/dev/null && r=yes || r=no
check "detector: owner text -> no" no "$r"
dogma_notify_agent_ids "<task-notification>${NL}<task-id>b3</task-id>${NL}<summary>Monitor event: \"x\"</summary>${NL}</task-notification>" >/dev/null && r=yes || r=no
check "detector: Monitor event -> no" no "$r"
dogma_notify_repeat "$(agent_block a4)" "$SID" && r=yes || r=no
check "repeat: first notification -> not slim" no "$r"
dogma_notify_repeat "$(agent_block a4)${NL}<total_tokens>1 tokens left</total_tokens>" "$SID" && r=yes || r=no
check "repeat: second notification of the same id -> slim" yes "$r"
[ -f "$CLAUDE_CONFIG_DIR/dogma/notify-seen/$SID" ] && r=yes || r=no
check "repeat: state lives under dogma/notify-seen" yes "$r"

run() { # script, prompt -> stdout
    (cd "$TMP/project" && jq -n --arg s "$SID" --arg p "$2" '{session_id: $s, prompt: $p, hook_event_name: "UserPromptSubmit"}' \
        | bash "$SCRIPT_DIR/$1" 2>/dev/null)
}
REP="$(agent_block a20)"
rep() { printf '%s\n<total_tokens>%s tokens left</total_tokens>' "$REP" "$1"; }
for s in subagent-suggestion.sh user-prompt-submit.sh prompt-intervention-reminder.sh checklist-tracking.sh; do
    first="$(run "$s" "$REP")"
    [ -n "$first" ] && r=yes || r=no
    check "$s: first notification keeps its inject" yes "$r"
done
n=1
for s in subagent-suggestion.sh user-prompt-submit.sh prompt-intervention-reminder.sh checklist-tracking.sh; do
    check "$s: repeat notification -> nothing" "" "$(run "$s" "$(rep "$n")")"
    n=$((n + 1))
done
for s in subagent-suggestion.sh user-prompt-submit.sh prompt-intervention-reminder.sh checklist-tracking.sh; do
    out="$(run "$s" "<cross-session-message from=\"p\">[info] hi</cross-session-message>")"
    [ -n "$out" ] && r=yes || r=no
    check "$s: peer message keeps its inject" yes "$r"
done
case "$(run checklist-tracking.sh "hello")" in *"TODO.md (1 open)"*) r=yes ;; *) r=no ;; esac
check "checklist-tracking: owner prompt still lists the open checklist" yes "$r"
case "$(run user-prompt-submit.sh "hello")" in *"<dogma-output-convention>"*) r=yes ;; *) r=no ;; esac
check "user-prompt-submit: owner prompt keeps the output convention" yes "$r"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]

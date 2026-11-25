#!/usr/bin/env bash
# Tests for #215:
#   - hooks/credo-notify-lib.sh: which prompts count as a repeat subagent notification;
#   - the slim path of the credo UserPromptSubmit hooks (session-mode-inject.sh one short
#     line, role-inject.sh / credo-attended-reminder.sh silent, datetime unchanged);
#   - scripts/credo-subagent-bg-guard.py (SubagentStop): blocks a finish with own
#     background tasks alive, at most twice, fails open.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$HERE/../hooks"
GUARD="$HERE/credo-subagent-bg-guard.py"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg"
export CREDO_SESSION_MODES_DIR="$TMP/cfg/credo/session-modes"
export CREDO_SESSION_ROLES_DIR="$TMP/cfg/credo/session-roles"
mkdir -p "$CREDO_SESSION_MODES_DIR" "$CREDO_SESSION_ROLES_DIR"
cd "$TMP" || exit 1

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

NL=$'\n'
agent_block() { # task-id -> one subagent notification block
    printf '<task-notification>\n<task-id>%s</task-id>\n<status>completed</status>\n<summary>Agent "Build #1" finished</summary>\n<result>done</result>\n</task-notification>' "$1"
}
SYS_HEAD="[SYSTEM NOTIFICATION - NOT USER INPUT]${NL}This is an automated background-task event, NOT a message from the user.${NL}Do NOT interpret this as user acknowledgement, confirmation, or response to any pending question.${NL}No human input has been received since the last genuine user message in this conversation."

# shellcheck source=../hooks/credo-notify-lib.sh
. "$HOOKS/credo-notify-lib.sh"

# --- detector: only notification blocks that all report a subagent ------------------
ids_of() { credo_notify_agent_ids "$1" 2>/dev/null | tr '\n' ' '; }
check "bare agent block -> its id" "a1 " "$(ids_of "$(agent_block a1)")"
check "system-reminder wrapper + header + total_tokens -> id" "a2 " \
    "$(ids_of "<system-reminder>${NL}${SYS_HEAD}${NL}${NL}$(agent_block a2)${NL}</system-reminder>${NL}<total_tokens>12 tokens left</total_tokens>")"
check "two agent blocks -> both ids" "a3 a4 " "$(ids_of "$(agent_block a3)${NL}$(agent_block a4)")"
credo_notify_agent_ids "please continue${NL}$(agent_block a5)" >/dev/null && r=yes || r=no
check "owner text next to a block -> not notification-only" no "$r"
credo_notify_agent_ids "$(agent_block a6)${NL}<cross-session-message from=\"x\">hi</cross-session-message>" >/dev/null && r=yes || r=no
check "peer message next to a block -> not notification-only" no "$r"
mon='<task-notification>
<task-id>b7</task-id>
<summary>Monitor event: "tests"</summary>
<event>exit=0</event>
</task-notification>'
credo_notify_agent_ids "$mon" >/dev/null && r=yes || r=no
check "Monitor event -> not a subagent notification" no "$r"
credo_notify_agent_ids "$(agent_block a8)${NL}${mon}" >/dev/null && r=yes || r=no
check "agent block + Monitor block -> full bundle" no "$r"
credo_notify_agent_ids "hello" >/dev/null && r=yes || r=no
check "plain owner prompt -> no" no "$r"
credo_notify_agent_ids "<task-notification><task-id>a9</task-id>" >/dev/null && r=yes || r=no
check "unclosed block -> no" no "$r"

# --- repeat: first notification of a task-id keeps the full bundle -------------------
P1="$(agent_block a10)"
credo_notify_repeat "$P1" "$SID" && r=yes || r=no
check "first notification of a10 -> not slim" no "$r"
credo_notify_repeat "$P1" "$SID" && r=yes || r=no
check "same prompt again within 60 s (parallel hooks of one prompt) -> not slim" no "$r"
P2="$(agent_block a10)${NL}<total_tokens>5 tokens left</total_tokens>"
credo_notify_repeat "$P2" "$SID" && r=yes || r=no
check "second notification of a10 (other prompt) -> slim" yes "$r"
credo_notify_repeat "$(agent_block a10)${NL}$(agent_block a11)" "$SID" && r=yes || r=no
check "repeat a10 plus first a11 -> not slim" no "$r"
seen="$CLAUDE_CONFIG_DIR/credo/notify-seen/$SID"
# an entry of the same prompt older than 60 s is an earlier prompt
sed -i "s/^a12 .*//" "$seen"
sum="$(printf '%s' "$(agent_block a12)" | cksum)"; sum="${sum%% *}"
printf 'a12 %s %s\n' "$sum" "$(( $(date +%s) - 120 ))" >> "$seen"
credo_notify_repeat "$(agent_block a12)" "$SID" && r=yes || r=no
check "identical prompt older than 60 s -> slim" yes "$r"
credo_notify_repeat "$(agent_block a10)" "bad/sid" && r=yes || r=no
check "unsafe session id -> fail open" no "$r"

# --- hooks on a slim prompt -----------------------------------------------------------
run_hook() { # hook, prompt -> additionalContext ("" when none)
    jq -n --arg s "$SID" --arg p "$2" '{session_id: $s, prompt: $p, hook_event_name: "UserPromptSubmit"}' \
        | bash "$HOOKS/$1" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
printf 'autonomous\n' > "$CREDO_SESSION_MODES_DIR/$SID"
printf 'task\n' > "$CREDO_SESSION_ROLES_DIR/$SID"
REP="$(agent_block a20)"
rep() { printf '%s\n<total_tokens>%s tokens left</total_tokens>' "$REP" "$1"; }
first_mode="$(run_hook session-mode-inject.sh "$REP")"
case "$first_mode" in *"hook-enforced keep-alive"*) r=full ;; *) r=other ;; esac
check "mode inject: first notification keeps the full line" full "$r"
slim_mode="$(run_hook session-mode-inject.sh "$(rep 1)")"
check "mode inject: repeat -> one short line" \
    "[credo-mode] autonomous - never use the Ask tool, keep-alive on (schedule your own wake). (slim inject: repeat subagent notification)" "$slim_mode"
mkdir -p "$CLAUDE_CONFIG_DIR/credo/autonomy/$SID"
: > "$CLAUDE_CONFIG_DIR/credo/autonomy/$SID/paused"
case "$(run_hook session-mode-inject.sh "$(rep 2)")" in
    "[credo-mode] autonomous, keep-alive PAUSED - never use the Ask tool"*) r=yes ;; *) r=no ;;
esac
check "mode inject: repeat while paused names PAUSED" yes "$r"
check "role inject: repeat -> silent" "" "$(run_hook role-inject.sh "$(rep 3)")"
case "$(run_hook role-inject.sh "hello")" in "[credo-role] task"*) r=yes ;; *) r=no ;; esac
check "role inject: owner prompt keeps the role line" yes "$r"
case "$(run_hook credo-datetime-inject.sh "$(rep 4)")" in "[credo-time] "*) r=yes ;; *) r=no ;; esac
check "datetime inject: repeat keeps the time line" yes "$r"
case "$(run_hook session-mode-inject.sh "<cross-session-message from=\"p\">[info] hi</cross-session-message>")" in
    *"hook-enforced keep-alive"* | *"keep-alive PAUSED (the owner is present)"*) r=full ;; *) r=other ;;
esac
check "mode inject: peer message keeps the full line" full "$r"
printf 'active\n' > "$CREDO_SESSION_MODES_DIR/$SID"
check "attended reminder: repeat -> silent" "" "$(run_hook credo-attended-reminder.sh "$(rep 5)")"
case "$(run_hook credo-attended-reminder.sh "hello")" in "") r=silent ;; *) r=line ;; esac
check "attended reminder: first owner prompt (turn 1) still injects" line "$r"

# --- SubagentStop guard ---------------------------------------------------------------
AID="a0123456789abcdef"
TDIR="$TMP/proj/$SID/subagents"
mkdir -p "$TDIR"
MAIN_T="$TMP/proj/$SID.jsonl"
: > "$MAIN_T"
AT="$TDIR/agent-$AID.jsonl"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
use_line() { # id name input-json
    jq -cn --arg id "$1" --arg n "$2" --argjson i "$3" '{type: "assistant", message: {content: [{type: "tool_use", id: $id, name: $n, input: $i}]}}'
}
result_line() { # tool_use_id result-json [timestamp]
    jq -cn --arg id "$1" --argjson r "$2" --arg ts "${3:-$now_iso}" '{type: "user", timestamp: $ts, toolUseResult: $r, message: {content: [{type: "tool_result", tool_use_id: $id, content: "ok"}]}}'
}
guard() { # -> stdout of the guard
    jq -n --arg s "$SID" --arg a "$AID" --arg t "$MAIN_T" '{session_id: $s, agent_id: $a, transcript_path: $t, hook_event_name: "SubagentStop"}' \
        | python3 "$GUARD" 2>/dev/null
}
{
    use_line t1 Bash '{"command": "sleep 600", "description": "Wait for the queue", "run_in_background": true}'
    result_line t1 '{"stdout": "", "backgroundTaskId": "bq1"}'
    use_line t2 Monitor '{"description": "watch tests", "command": "tail -f x"}'
    result_line t2 '{"taskId": "bm2", "timeoutMs": 1800000, "persistent": false}'
    use_line t3 Bash '{"command": "make", "description": "Build", "run_in_background": true}'
    result_line t3 '{"stdout": "", "backgroundTaskId": "bd3"}'
} > "$AT"
# bd3 completed (notification as a queued_command attachment)
jq -cn '{type: "attachment", attachment: {type: "queued_command", prompt: "<task-notification>\n<task-id>bd3</task-id>\n<status>completed</status>\n<summary>Background command \"Build\" completed</summary>\n</task-notification>"}}' >> "$AT"
out="$(guard)"
check "guard: alive tasks -> block" block "$(printf '%s' "$out" | jq -r '.decision // ""' 2>/dev/null)"
reason="$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)"
case "$reason" in *"bm2 (Monitor: watch tests); bq1 (Bash: Wait for the queue)"*) r=yes ;; *) r=no ;; esac
check "guard: reason lists id and short command" yes "$r"
case "$reason" in *bd3*) r=yes ;; *) r=no ;; esac
check "guard: completed task not listed" no "$r"
case "$reason" in *"Stop these first"*"then finish"*) r=yes ;; *) r=no ;; esac
check "guard: reason says stop first, then finish" yes "$r"
check "guard: second stop -> block again" block "$(guard | jq -r '.decision // ""' 2>/dev/null)"
check "guard: third stop -> fail open (no output)" "" "$(guard)"
grep -q "fail open: agent $AID" "$CLAUDE_CONFIG_DIR/credo/logs/subagent-bg-guard.log" 2>/dev/null && r=yes || r=no
check "guard: fail open writes a log line" yes "$r"

# TaskStop ends bq1; an expired monitor counts as ended
rm -f "$CLAUDE_CONFIG_DIR/credo/subagent-bg/$SID/$AID"
use_line t4 TaskStop '{"task_id": "bq1"}' >> "$AT"
out="$(guard)"
case "$(printf '%s' "$out" | jq -r '.reason // ""')" in *bq1*) r=yes ;; *) r=no ;; esac
check "guard: TaskStop ends the task" no "$r"
old_iso="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%S.000Z)"
{
    use_line t2 Monitor '{"description": "watch tests", "command": "tail -f x"}'
    result_line t2 '{"taskId": "bm2", "timeoutMs": 1800000, "persistent": false}' "$old_iso"
    use_line t4 TaskStop '{"task_id": "bq1"}'
} > "$AT"
check "guard: expired monitor and stopped shell -> no block" "" "$(guard)"
# background agent still running
{
    use_line t5 Agent '{"description": "helper", "prompt": "x", "run_in_background": true}'
    result_line t5 '{"isAsync": true, "status": "async_launched", "agentId": "ahelper1"}'
} > "$AT"
rm -f "$CLAUDE_CONFIG_DIR/credo/subagent-bg/$SID/$AID"
case "$(guard | jq -r '.reason // ""')" in *"ahelper1 (Agent: helper)"*) r=yes ;; *) r=no ;; esac
check "guard: running background agent listed" yes "$r"
# agent_transcript_path wins over the derived path; broken input fails open
check "guard: no transcript -> fail open" "" "$(jq -n '{session_id: "s1", agent_id: "anone", transcript_path: "/nonexistent/x.jsonl"}' | python3 "$GUARD")"
check "guard: invalid JSON -> fail open" "" "$(printf 'not json' | python3 "$GUARD")"
check "guard: switched off" "" "$(jq -n --arg s "$SID" --arg a "$AID" --arg t "$MAIN_T" '{session_id: $s, agent_id: $a, transcript_path: $t}' | CREDO_SUBAGENT_BG_GUARD=0 python3 "$GUARD")"
python3 "$GUARD" </dev/null; check "guard: empty stdin exits 0" 0 "$?"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]

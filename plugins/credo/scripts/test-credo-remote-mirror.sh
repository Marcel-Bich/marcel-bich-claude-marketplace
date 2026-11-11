#!/usr/bin/env bash
# test-credo-remote-mirror.sh - tests for hooks/credo-remote-mirror.sh (credo item #146).
#
# The mirror hooks only observe. Every event type is driven with a fixture hook
# payload, and every "nothing sent" case too. Each hook call must stay silent on
# stdout and exit 0. The sink is a fixture command that appends the event to a file.
# Config, profile, transcripts and dedup state live in a temp dir; nothing real is
# sent and the real credo profile is never touched.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HERE/.."
HOOK="$PLUGIN/hooks/credo-remote-mirror.sh"
REDACT="$PLUGIN/hooks/credo-remote-mirror-redact.jq"
SESSION_START="$PLUGIN/hooks/credo-session-start.sh"
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
TEMPLATE="$PLUGIN/templates/config.default.yaml"
CONFIG_SH="$PLUGIN/scripts/credo-config.sh"

SID="aaaaaaaa-1111-2222-3333-cccccccccccc"  # letters and digits: a real session id shape (must never be masked)
CWD="/work/acme-task"

# Emoji as UTF-8 bytes, so this test source stays ASCII.
Q=$'\xe2\x9d\x93'     # U+2753 question mark ornament
T=$'\xf0\x9f\xa7\xaa' # U+1F9EA test tube
V=$'\xe2\x9c\x8b'     # U+270B raised hand

pass=0
fail=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-remote-mirror.XXXXXX")"
CFG_ROOT="$TMP/cfg"

unset CREDO_SESSION_ID CLAUDE_CODE_SESSION_ID CREDO_PROJECT CREDO_DIR CREDO_PROFILE
unset CLAUDE_PLUGIN_ROOT CREDO_REMOTE_MIRROR_TIMEOUT CREDO_REMOTE_MIRROR_PERM_WINDOW
unset CREDO_MIRROR_DIR
export CLAUDE_CONFIG_DIR="$CFG_ROOT"
export CREDO_GLOBAL="$CFG_ROOT/credo/config"
export CREDO_SKIP_ENSURE=1
export CREDO_REMOTE_MIRROR_SYNC=1

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

# set_global <sink command>: the global layer with the sink (YAML single-quoted)
set_global() {
    mkdir -p "$CFG_ROOT/credo"
    printf "remote:\n  mirror_command: '%s'\n" "$1" > "$CREDO_GLOBAL"
}

# new_case: fresh sink log, transcript, dedup state, and the sink configured
case_n=0
new_case() {
    case_n=$((case_n + 1))
    OUTF="$TMP/sink-$case_n.jsonl"
    TR="$TMP/transcript-$case_n.jsonl"
    STATE="$TMP/state-$case_n/$SID/sent"
    : > "$TR"
    export CREDO_MIRROR_TEST_OUT="$OUTF"
    export CREDO_MIRROR_DIR="$TMP/state-$case_n"
    set_global 'cat >> "$CREDO_MIRROR_TEST_OUT"'
}

count() { # events sent in this case
    if [ -f "$OUTF" ]; then wc -l < "$OUTF" | tr -d ' '; else echo 0; fi
}

jqf() { # jq filter applied to the last sent event of this case
    jq -r "$1" "$OUTF" 2>/dev/null | tail -n 1
}

# run <name> <mode> <payload>: the hook must stay silent (empty stdout, exit 0)
run() {
    local out rc
    out="$(printf '%s' "$3" | bash "$HOOK" "$2" 2>/dev/null)"
    rc=$?
    check "$1: exit 0" 0 "$rc"
    check "$1: stdout empty" "" "$out"
}

# --- fixture payloads ----------------------------------------------------------
ask_payload() { # tool_use_id ("" = absent), question text
    jq -n --arg s "$SID" --arg c "$CWD" --arg id "$1" --arg q "$2" '{
        session_id: $s, cwd: $c, hook_event_name: "PreToolUse",
        tool_name: "AskUserQuestion", tool_use_id: $id,
        tool_input: {questions: [{question: $q, header: "Branch", multiSelect: false,
            options: [{label: "main", description: "the default branch"},
                      {label: "stage", description: "staging"}]}]}
    }'
}

perm_payload() { # tool_name, tool_input (JSON object)
    jq -n --arg s "$SID" --arg c "$CWD" --arg t "$1" --argjson i "$2" '{
        session_id: $s, cwd: $c, hook_event_name: "PermissionRequest",
        tool_name: $t, tool_input: $i, permission_mode: "default"}'
}

stop_payload() { # last_assistant_message ("" = absent), transcript path ("" = absent)
    jq -n --arg s "$SID" --arg c "$CWD" --arg m "$1" --arg tp "$2" '
        {session_id: $s, cwd: $c, hook_event_name: "Stop", stop_hook_active: false}
        + (if $m == "" then {} else {last_assistant_message: $m} end)
        + (if $tp == "" then {} else {transcript_path: $tp} end)'
}

# transcript entries (JSONL, appended to $TR)
tr_prompt() { jq -cn --arg u "$1" --arg t "$2" '{type: "user", uuid: $u, message: {role: "user", content: $t}}' >> "$TR"; }
tr_result() { jq -cn --arg u "$1" '{type: "user", uuid: $u, message: {role: "user", content: [{type: "tool_result", tool_use_id: "toolu_1", content: "ok"}]}}' >> "$TR"; }
tr_tool() { jq -cn --arg u "$1" '{type: "assistant", uuid: $u, message: {role: "assistant", content: [{type: "tool_use", id: "toolu_1", name: "Bash", input: {command: "ls"}}]}}' >> "$TR"; }
tr_text() { jq -cn --arg u "$1" --arg t "$2" '{type: "assistant", uuid: $u, message: {role: "assistant", content: [{type: "text", text: $t}]}}' >> "$TR"; }

# --- config and wiring ---------------------------------------------------------
echo "== config and wiring"
got="$(CREDO_GLOBAL="$TMP/absent/config" CLAUDE_CONFIG_DIR="$TMP/absent-cfg" \
    CREDO_PROJECT=/dev/null bash "$CONFIG_SH" get remote.mirror_command 2>/dev/null)"
rc=$?
check "builtin default: get exits 0" 0 "$rc"
check "builtin default: mirror_command is empty (off)" "" "$got"
check "template carries the remote.mirror_command key" 1 \
    "$(grep -c '^  mirror_command: ""' "$TEMPLATE")"
check "hooks.json parses" 0 "$(jq -e . "$HOOKS_JSON" >/dev/null 2>&1; echo $?)"
check "PreToolUse AskUserQuestion wired to ask" \
    '${CLAUDE_PLUGIN_ROOT}/hooks/credo-remote-mirror.sh ask' \
    "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") | .hooks[0].command' "$HOOKS_JSON")"
check "PermissionRequest wired to permission" \
    '${CLAUDE_PLUGIN_ROOT}/hooks/credo-remote-mirror.sh permission' \
    "$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' "$HOOKS_JSON")"
check "Stop wired to stop (exactly one mirror entry)" \
    '${CLAUDE_PLUGIN_ROOT}/hooks/credo-remote-mirror.sh stop' \
    "$(jq -r '[.hooks.Stop[].hooks[].command | select(test("credo-remote-mirror"))] | join(" ")' "$HOOKS_JSON")"
check "hook is executable" 0 "$([ -x "$HOOK" ] && echo 0 || echo 1)"
LC_ALL=C grep -q -e "$Q" -e "$T" -e "$V" "$HOOK"
check "hook source has no emoji bytes (codes are escaped)" 1 "$?"

# --- off by default -----------------------------------------------------------
echo "== off by default"
new_case
set_global ""
run "empty mirror_command: silent" ask "$(ask_payload toolu_O1 'Which branch?')"
check "empty mirror_command: nothing sent" 0 "$(count)"

new_case
export CREDO_GLOBAL="$TMP/no-such-dir/config"
export CLAUDE_CONFIG_DIR="$TMP/empty-prof"
run "no config file: silent" ask "$(ask_payload toolu_O2 'Which branch?')"
export CREDO_GLOBAL="$CFG_ROOT/credo/config"
export CLAUDE_CONFIG_DIR="$CFG_ROOT"
check "no config file: nothing sent" 0 "$(count)"

new_case
set_global ""
mkdir -p "$TMP/proj-x/.credo"
printf "remote:\n  mirror_command: 'cat >> \"\$CREDO_MIRROR_TEST_OUT\"'\n" > "$TMP/proj-x/.credo/config"
export CREDO_PROJECT="$TMP/proj-x/.credo/config"
run "project layer set: silent" ask "$(ask_payload toolu_O3 'Which branch?')"
unset CREDO_PROJECT
check "project layer value is ignored (repo cannot set the sink)" 0 "$(count)"

new_case
export CREDO_GLOBAL="$TMP/no-such-dir/config"
export CLAUDE_CONFIG_DIR="$TMP/prof"
mkdir -p "$TMP/prof/credo"
printf "remote:\n  mirror_command: 'cat >> \"\$CREDO_MIRROR_TEST_OUT\"'\n" > "$TMP/prof/credo/config"
run "profile layer only: ask silent" ask "$(ask_payload toolu_O4 'Which branch?')"
export CREDO_GLOBAL="$CFG_ROOT/credo/config"
export CLAUDE_CONFIG_DIR="$CFG_ROOT"
check "profile layer sets the sink" 1 "$(count)"

# --- ask box (PreToolUse AskUserQuestion) --------------------------------------
echo "== ask box"
new_case
run "ask: silent" ask "$(ask_payload toolu_A1 'Which branch should the change go to?')"
check "ask: one event" 1 "$(count)"
check "ask: type" ask "$(jqf '.type')"
check "ask: tool_use_id" toolu_A1 "$(jqf '.tool_use_id')"
check "ask: first option label" main "$(jqf '.questions[0].options[0].label')"
check "ask: option description" "the default branch" "$(jqf '.questions[0].options[0].description')"
check "ask: multiSelect" false "$(jqf '.questions[0].multiSelect')"
check "ask: session_id" "$SID" "$(jqf '.session_id')"
check "ask: cwd" "$CWD" "$(jqf '.cwd')"
check "ask: ts is UTC ISO-8601" 1 \
    "$(jqf '.ts' | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
check "ask: no tool_input leaked" false "$(jqf 'has("tool_input")')"
check "ask: main agent" false "$(jqf '.subagent')"

run "ask: same tool_use_id again" ask "$(ask_payload toolu_A1 'Which branch should the change go to?')"
check "ask: same tool_use_id sent once" 1 "$(count)"
run "ask: new tool_use_id" ask "$(ask_payload toolu_A2 'Pick a second thing?')"
check "ask: new tool_use_id sent" 2 "$(count)"

new_case
run "ask: Q code in the question" ask "$(ask_payload toolu_B1 "$Q Q4) Which rank: A or B?")"
check "ask: question with a code sent" 1 "$(count)"
run "ask: reply heading with the same code" stop "$(stop_payload "Summary
### $Q Q4) Which rank: A or B?
A or B?" "")"
check "ask: the same Q code in the reply is not sent again" 1 "$(count)"

new_case
run "ask: subagent origin" ask "$(ask_payload toolu_C1 'Pick one' | jq -c '. + {agent_id: "agent-7", agent_type: "general-purpose"}')"
check "ask: subagent flag" true "$(jqf '.subagent')"
check "ask: subagent type" general-purpose "$(jqf '.agent_type')"

new_case
run "ask: no tool_use_id, first" ask "$(ask_payload "" 'Keep or drop?')"
run "ask: no tool_use_id, repeat" ask "$(ask_payload "" 'Keep or drop?')"
check "ask: without tool_use_id deduped by content" 1 "$(count)"

# --- permission prompts (PermissionRequest) ------------------------------------
echo "== permission prompts"
new_case
run "perm: Bash silent" permission "$(perm_payload Bash '{"command":"git push origin feature-x"}')"
check "perm: one event" 1 "$(count)"
check "perm: type" permission "$(jqf '.type')"
check "perm: tool_name" Bash "$(jqf '.tool_name')"
check "perm: summary is the command" "git push origin feature-x" "$(jqf '.summary')"
check "perm: no raw tool_input" false "$(jqf 'has("tool_input")')"
check "perm: main agent" false "$(jqf '.subagent')"

run "perm: same request in the window" permission "$(perm_payload Bash '{"command":"git push origin feature-x"}')"
check "perm: same request inside the window sent once" 1 "$(count)"

run "perm: Write with content" permission "$(perm_payload Write '{"file_path":"/work/acme-task/notes.txt","content":"SECRET-BODY-TEXT"}')"
check "perm: Write sent" 2 "$(count)"
check "perm: Write summary is the path" "/work/acme-task/notes.txt" "$(jqf '.summary')"
check "perm: file content never leaves the hook" 0 "$(grep -c 'SECRET-BODY-TEXT' "$OUTF")"

run "perm: subagent origin" permission "$(perm_payload Bash '{"command":"make test"}' | jq -c '. + {agent_id: "agent-9", agent_type: "Explore"}')"
check "perm: subagent flag" true "$(jqf '.subagent')"
check "perm: subagent type" Explore "$(jqf '.agent_type')"

new_case
perm1="$(perm_payload Bash '{"command":"npm publish"}')"
run "perm: first" permission "$perm1"
awk -F'\t' 'BEGIN { OFS = "\t" } { $2 = "1" } 1' "$STATE" > "$STATE.aged"
cat "$STATE.aged" > "$STATE"
run "perm: after the window" permission "$perm1"
check "perm: request after the window is sent again" 2 "$(count)"

# --- stop: question codes, test blocks, blockers (last assistant message) -------
echo "== stop: questions, tests and blockers"
new_case
run "stop: normal reply" stop "$(stop_payload "All green. Nothing to decide." "")"
check "stop: normal reply sends nothing" 0 "$(count)"

run "stop: status text" stop "$(stop_payload "Status: 3 items done, waiting for nothing." "")"
check "stop: status text sends nothing" 0 "$(count)"

run "stop: veto codes only" stop "$(stop_payload "### $V$V V2) Veto possible: rename the file $V$V" "")"
check "stop: veto codes only send nothing" 0 "$(count)"

run "stop: question heading" stop "$(stop_payload "Summary
### $Q Q4) Which rank: A or B?
A or B?" "")"
check "stop: question heading sent" 1 "$(count)"
check "stop: type question_codes" question_codes "$(jqf '.type')"
check "stop: question code" Q4 "$(jqf '.code')"
check "stop: question heading text" "Which rank: A or B?" "$(jqf '.heading')"

run "stop: same question again" stop "$(stop_payload "### $Q Q4) Which rank: A or B?" "")"
check "stop: same question sent once" 1 "$(count)"

run "stop: second question" stop "$(stop_payload "### $Q Q5) Ship today?" "")"
check "stop: second question sent" 2 "$(count)"
check "stop: second question code" Q5 "$(jqf '.code')"

run "stop: footer only" stop "$(stop_payload "Still open: **$Q: Q9**" "")"
check "stop: footer without heading sends nothing" 2 "$(count)"

run "stop: test without marker" stop "$(stop_payload "### $T T3) Login check" "")"
check "stop: unmarked test sends nothing" 2 "$(count)"

run "stop: blocking test" stop "$(stop_payload "### $T T4) Login check [blocking]" "")"
check "stop: blocking test sent" 3 "$(count)"
check "stop: test_blocking type" test_blocking "$(jqf '.type')"
check "stop: test code" T4 "$(jqf '.code')"
check "stop: test heading" "Login check [blocking]" "$(jqf '.heading')"

run "stop: blocker" stop "$(stop_payload "**Blocker:** the deploy key is missing on the server" "")"
check "stop: blocker sent" 4 "$(count)"
check "stop: blocker type" blocker "$(jqf '.type')"
check "stop: blocker text" "the deploy key is missing on the server" "$(jqf '.text')"

run "stop: same blocker again" stop "$(stop_payload "**Blocker:** the deploy key is missing on the server" "")"
check "stop: same blocker sent once" 4 "$(count)"

run "stop: blocker none" stop "$(stop_payload "Blocker: none" "")"
run "stop: blocker dash" stop "$(stop_payload "Blocker: -" "")"
run "stop: blocker keine" stop "$(stop_payload "Blocker: keine" "")"
run "stop: blocker without text" stop "$(stop_payload "Blocker:" "")"
check "stop: empty blockers send nothing" 4 "$(count)"

new_case
run "stop: question and blocker together" stop "$(stop_payload "### $Q Q7) Ship now?

Blocker: the owner has to pick the release date" "")"
check "stop: two events from one reply" 2 "$(count)"

# --- stop: remote chat replies --------------------------------------------------
echo "== stop: remote chat replies"
new_case
tr_prompt u-1 "[remote chat c-42] status?"
tr_tool a-1
tr_result u-2
tr_text a-2 "All green."
run "remote: reply to the remote prompt" stop "$(stop_payload "All green." "$TR")"
check "remote: one reply sent" 1 "$(count)"
check "remote: type" remote_reply "$(jqf '.type')"
check "remote: chat id" c-42 "$(jqf '.chat_id')"
check "remote: text is the reply only" "All green." "$(jqf '.text')"
check "remote: event keys" "chat_id,cwd,session_id,text,ts,type" "$(jqf 'keys | join(",")')"

run "remote: same turn stopped again" stop "$(stop_payload "All green." "$TR")"
check "remote: same prompt answered once" 1 "$(count)"

tr_prompt u-3 "[remote chat c-42] again?"
tr_text a-3 "Still green."
run "remote: reply without last_assistant_message" stop "$(stop_payload "" "$TR")"
check "remote: fallback reads the reply from the transcript" 2 "$(count)"
check "remote: fallback text" "Still green." "$(jqf '.text')"

tr_prompt u-4 "fix the typo please"
tr_text a-4 "Done."
run "remote: normal prompt after the remote one" stop "$(stop_payload "Done." "$TR")"
check "remote: a normal prompt is not mirrored" 2 "$(count)"

tr_prompt u-5 "[remote chat a/b] hi"
tr_text a-5 "Hi."
run "remote: invalid chat id" stop "$(stop_payload "Hi." "$TR")"
check "remote: invalid chat id sends nothing" 2 "$(count)"

tr_prompt u-6 "[remote chat c-50] ping"
run "remote: no reply written yet" stop "$(stop_payload "Old text" "$TR")"
check "remote: prompt without a reply sends nothing" 2 "$(count)"

run "remote: unreadable transcript" stop "$(stop_payload "All green." "$TMP/missing.jsonl")"
check "remote: unreadable transcript sends nothing extra" 2 "$(count)"

new_case
tr_prompt u-p1 '<pasted_content id="ab12cd">
[remote chat c-77] pasted status?
</pasted_content>'
tr_text a-p1 "Pasted green."
run "remote: pasted prompt" stop "$(stop_payload "Pasted green." "$TR")"
check "remote: pasted prompt is mirrored" 1 "$(count)"
check "remote: pasted prompt chat id" c-77 "$(jqf '.chat_id')"

# --- robustness: never break the session ---------------------------------------
echo "== redaction (secret-looking text never leaves the hook)"
check "redaction program present" 0 "$([ -f "$REDACT" ] && echo 0 || echo 1)"
new_case
redact_case() { # name, command, expected summary
    run "redact: $1" permission "$(perm_payload Bash "$(jq -n --arg c "$2" '{command: $c}')")"
    check "redact: $1" "$3" "$(jqf '.summary')"
}
redact_case "KEY=value" "TOKEN=abc123 make deploy" "TOKEN=*** make deploy"
redact_case "prefixed env secret" "GITHUB_TOKEN=ghp_0123456789abcdefghij git push" "GITHUB_TOKEN=*** git push"
redact_case "Authorization Bearer header" 'curl -H "Authorization: Bearer eyJhbGci.payload.sig" https://api.example.test/v1' 'curl -H "Authorization: Bearer ***" https://api.example.test/v1'
redact_case "mysql -p attached" "mysql -u root -pS3cretPass db" "mysql -u root -p*** db"
redact_case "sshpass -p" "sshpass -p hunter2 ssh host" "sshpass -p *** ssh host"
redact_case "--password flag" "curl --password hunter2 https://x.test" "curl --password *** https://x.test"
redact_case "--token=value" "tool --token=hunter2 run" "tool --token=*** run"
redact_case "password: value form" "echo password: hunter2" "echo password: ***"
redact_case "URL credentials" "git push https://deploy:s3cretvalue@git.example.test/repo.git" "git push https://deploy:***@git.example.test/repo.git"
redact_case "long hex run" "git show 0123456789abcdef0123456789abcdef" "git show ***"
redact_case "long base64 run" "echo Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MGFiY2RlZmdoaWo=" "echo ***"
redact_case "provider token prefix" "git push origin ghp_abcdefghijklmnop12" "git push origin ***"
redact_case "normal: branch push" "git push origin feature-x" "git push origin feature-x"
redact_case "normal: make" "make test" "make test"
redact_case "normal: mkdir -p" "mkdir -p build/out" "mkdir -p build/out"
redact_case "normal: path" "ls -la /work/acme-task/src" "ls -la /work/acme-task/src"
redact_case "normal: short commit" "git show f237bbd" "git show f237bbd"
redact_case "normal: long word without digits" "echo supercalifragilisticexpialidociousxyz" "echo supercalifragilisticexpialidociousxyz"
run "redact: ask question" ask "$(ask_payload toolu_X1 'Use TOKEN=abc123 for the run?')"
check "redact: ask question masked" "Use TOKEN=*** for the run?" "$(jqf '.questions[0].question')"
new_case
run "redact: blocker" stop "$(stop_payload "Blocker: the key TOKEN=abc123 is missing" "")"
check "redact: blocker text masked" "the key TOKEN=*** is missing" "$(jqf '.text')"
tr_prompt u-r1 "[remote chat c-77] deploy?"
tr_text a-r1 "Done. Authorization: Bearer abcdef.123 is set."
run "redact: remote reply" stop "$(stop_payload "Done. Authorization: Bearer abcdef.123 is set." "$TR")"
check "redact: remote reply masked" "Done. Authorization: Bearer *** is set." "$(jqf '.text')"

echo "== session legend names the markers"
check "legend: Blocker marker named" 1 "$(grep -c -F 'starts its line with "Blocker:"' "$SESSION_START")"
check "legend: [blocking] marker named" 1 "$(grep -c -F '"[blocking]" in its heading' "$SESSION_START")"

echo "== robustness"
new_case
bad_sid="$(ask_payload toolu_R1 'Which branch?' | jq -c '.session_id = "../evil"')"
run "invalid session id: silent" ask "$bad_sid"
check "invalid session id: nothing sent" 0 "$(count)"
check "invalid session id: no path traversal" 0 "$([ -e "$TMP/evil" ] && echo 1 || echo 0)"

run "empty stdin: silent" ask ""
check "empty stdin: nothing sent" 0 "$(count)"
run "malformed stdin: silent" ask "{not json"
check "malformed stdin: nothing sent" 0 "$(count)"

NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for t in bash cat dirname tr date awk tail mkdir wc; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
out="$(printf '%s' "$(ask_payload toolu_R2 'Which branch?')" | PATH="$NOJQ" bash "$HOOK" ask 2>/dev/null)"
rc=$?
check "no jq on PATH: exit 0" 0 "$rc"
check "no jq on PATH: stdout empty" "" "$out"
check "no jq on PATH: nothing sent" 0 "$(count)"

new_case
set_global "false"
run "sink exits 1: silent" ask "$(ask_payload toolu_R3 'Which branch?')"
set_global "/nonexistent/credo-mirror-sink"
run "sink missing: silent" ask "$(ask_payload toolu_R4 'Which branch?')"

# redaction program missing: the copy of the hook cannot mask, so it sends nothing
new_case
mkdir -p "$TMP/failclosed/hooks"
ln -sf "$PLUGIN/scripts" "$TMP/failclosed/scripts"
cp "$HOOK" "$TMP/failclosed/hooks/credo-remote-mirror.sh"
out="$(perm_payload Bash '{"command":"make test"}' | bash "$TMP/failclosed/hooks/credo-remote-mirror.sh" permission 2>/dev/null)"
check "redaction missing: exit 0" 0 "$?"
check "redaction missing: stdout empty" "" "$out"
check "redaction missing: nothing sent" 0 "$(count)"

new_case
set_global 'sleep 5; cat >> "$CREDO_MIRROR_TEST_OUT"'
start="$(date +%s)"
export CREDO_REMOTE_MIRROR_TIMEOUT=1
run "sink hangs (sync, 1 s timeout): silent" ask "$(ask_payload toolu_R5 'Which branch?')"
unset CREDO_REMOTE_MIRROR_TIMEOUT
elapsed=$(( $(date +%s) - start ))
check "sink hangs: the hook gives up after the timeout" 1 "$([ "$elapsed" -le 4 ] && echo 1 || echo 0)"
check "sink hangs: no event written" 0 "$(count)"

new_case
set_global 'sleep 2; cat >> "$CREDO_MIRROR_TEST_OUT"'
start="$(date +%s%N)"
out="$(printf '%s' "$(ask_payload toolu_R6 'Which branch?')" | CREDO_REMOTE_MIRROR_SYNC= bash "$HOOK" ask 2>/dev/null)"
rc=$?
ms=$(( ( $(date +%s%N) - start ) / 1000000 ))
check "async: exit 0" 0 "$rc"
check "async: stdout empty" "" "$out"
check "async: the hook returns before the sink finishes" 1 "$([ "$ms" -lt 1500 ] && echo 1 || echo 0)"

# --- question and test blocks: full text (credo item #158) ------------------------
echo "== question and test blocks: full text"
# codeq <code> <jq expr>: the expression on the last event of that code (raw, no newline)
codeq() {
    jq -s -j --arg c "$1" "[.[] | select(.code == \$c)] | last | $2" "$OUTF" 2>/dev/null
}
FENCE='```'
new_case
q_body="$(printf 'Context: the rank changes the price.\n\n%sbash\n# install step\nmake install\n%s\n\nOptions:\n- A: cheap\n- B: fast' "$FENCE" "$FENCE")"
reply="$(printf 'Summary line\n### %s Q4) Which rank: A or B?\n%s\n### %s T2) Login check\nDone.' "$Q" "$q_body" "$T")"
run "text: question with body, fence and options" stop "$(stop_payload "$reply" "")"
check "text: Q4 text is the whole block" "$q_body" "$(codeq Q4 '.text')"
check "text: Q4 carries the text key" true "$(codeq Q4 'has("text")')"
check "text: short block is not cut" false "$(codeq Q4 'has("cut")')"
check "text: heading unchanged" "Which rank: A or B?" "$(codeq Q4 '.heading')"

new_case
reply="$(printf 'Intro\n### %s Q4) Scope?\nIntro line\n#### Detail kept\nDetail text\n## Other section\nNot part of the question' "$Q")"
run "text: level 2 heading ends the block" stop "$(stop_payload "$reply" "")"
check "text: #### stays inside, ## ends the block" "$(printf 'Intro line\n#### Detail kept\nDetail text')" "$(codeq Q4 '.text')"

new_case
reply="$(printf '### %s Q4) First?\nfirst body\n### %s Q5) Second?\nsecond body' "$Q" "$Q")"
run "text: two codes in one reply" stop "$(stop_payload "$reply" "")"
check "text: first code gets its own block" "first body" "$(codeq Q4 '.text')"
check "text: second code gets its own block" "second body" "$(codeq Q5 '.text')"

new_case
reply="$(printf '### %s T4) Login check [blocking]\nSteps: open the app\nThen sign in\n### %s Q6) Ship?\nyes or no' "$T" "$Q")"
run "text: blocking test block" stop "$(stop_payload "$reply" "")"
check "text: test_blocking carries its block" "$(printf 'Steps: open the app\nThen sign in')" "$(codeq T4 '.text')"
check "text: test_blocking type unchanged" test_blocking "$(codeq T4 '.type')"

new_case
reply="$(printf '### %s Q7) Deploy?\nSet TOKEN=abc123 first.\nThen go.' "$Q")"
run "text: secret in the body is masked" stop "$(stop_payload "$reply" "")"
check "text: masked inside the block" "$(printf 'Set TOKEN=*** first.\nThen go.')" "$(codeq Q7 '.text')"
check "text: raw secret never sent" 0 "$(grep -c 'abc123' "$OUTF")"

new_case
long_body="$(printf 'word %.0s' $(seq 1 1000))"
reply="$(printf '### %s Q8) Long?\n%s' "$Q" "$long_body")"
run "text: over 4000 characters" stop "$(stop_payload "$reply" "")"
check "text: cut true when shortened" true "$(codeq Q8 '.cut')"
check "text: capped at 4000 characters" true "$(codeq Q8 '(.text | length) <= 4000')"
check "text: cut between words" true "$(codeq Q8 '.text | endswith("word")')"

new_case
filler="$(printf 'word %.0s' $(seq 1 798))"
reply="$(printf '### %s Q9) Token?\n%sghp_0123456789abcdefghij0123' "$Q" "$filler")"
run "text: cut at the token keeps no partial secret" stop "$(stop_payload "$reply" "")"
check "text: edge cut marked" true "$(codeq Q9 '.cut')"
check "text: partial token prefix not sent" 0 "$(grep -c 'ghp_0' "$OUTF")"

echo "== permission cut and sha256 (credo item #158)"
new_case
long_cmd="echo $(printf 'part %.0s' $(seq 1 600))TAILMARKER"
run "perm: long command" permission "$(perm_payload Bash "$(jq -n --arg c "$long_cmd" '{command: $c}')")"
check "perm: long command is cut" true "$(jqf '.cut')"
check "perm: summary capped at 2000 characters" true "$(jqf '(.summary | length) <= 2000')"
check "perm: tail of the command not sent" 0 "$(grep -c 'TAILMARKER' "$OUTF")"
check "perm: sha256 is the digest of the full command" \
    "$(printf '%s' "$long_cmd" | sha256sum | awk '{print $1}')" "$(jqf '.sha256')"

run "perm: short command" permission "$(perm_payload Bash '{"command":"make test"}')"
check "perm: short command has no cut" false "$(jqf 'has("cut")')"
check "perm: short command has sha256 of the full command" \
    "$(printf '%s' 'make test' | sha256sum | awk '{print $1}')" "$(jqf '.sha256')"
check "perm: unmasked short command has no masked flag" false "$(jqf 'has("masked")')"

secret_cmd='curl -H "Authorization: Bearer abcdefghij0123456789abcdefghij0123" https://example.invalid'
run "perm: masked command" permission "$(perm_payload Bash "$(jq -n --arg c "$secret_cmd" '{command: $c}')")"
check "perm: masked command is flagged" true "$(jqf '.masked')"
check "perm: masked command sha256 is of the unmasked command" \
    "$(printf '%s' "$secret_cmd" | sha256sum | awk '{print $1}')" "$(jqf '.sha256')"

new_case
perm_same="$(perm_payload Bash "$(jq -n --arg c "$long_cmd" '{command: $c}')")"
run "perm: long command first" permission "$perm_same"
run "perm: same long command again" permission "$perm_same"
check "perm: same long command sent once" 1 "$(count)"
other_cmd="echo $(printf 'part %.0s' $(seq 1 600))OTHERTAIL"
run "perm: other long command, same prefix" permission "$(perm_payload Bash "$(jq -n --arg c "$other_cmd" '{command: $c}')")"
check "perm: a different long command is sent too" 2 "$(count)"

# sha256_hex (the real function text): the digest of stdin, and nothing without a digest tool.
# The config read needs python3, so the no-tool case is checked on the function alone.
SHA_FN="$TMP/sha256_hex.sh"
sed -n '/^sha256_hex() {/,/^}/p' "$HOOK" > "$SHA_FN"
NOSHA="$TMP/nosha"
mkdir -p "$NOSHA"
ln -sf "$(command -v bash)" "$NOSHA/bash"
check "sha256_hex: digest of stdin" "$(printf 'abc' | sha256sum | awk '{print $1}')" \
    "$(printf 'abc' | bash -c '. "$1"; sha256_hex' _ "$SHA_FN")"
check "sha256_hex: no digest tool on PATH prints nothing" "" \
    "$(printf 'abc' | PATH="$NOSHA" bash -c '. "$1"; sha256_hex' _ "$SHA_FN" 2>/dev/null)"

# a hook without a digest (sha256_hex returns nothing): the cut is still marked, sha256 is left out
NODIGEST="$TMP/nodigest"
mkdir -p "$NODIGEST/hooks"
ln -sf "$PLUGIN/scripts" "$NODIGEST/scripts"
cp "$REDACT" "$NODIGEST/hooks/credo-remote-mirror-redact.jq"
sed 's/^sha256_hex() {$/sha256_hex() { return 0;/' "$HOOK" > "$NODIGEST/hooks/credo-remote-mirror.sh"
new_case
np="$(perm_payload Bash "$(jq -n --arg c "$long_cmd" '{command: $c}')")"
out="$(printf '%s' "$np" | bash "$NODIGEST/hooks/credo-remote-mirror.sh" permission 2>/dev/null)"
rc=$?
check "perm no digest: exit 0" 0 "$rc"
check "perm no digest: stdout empty" "" "$out"
check "perm no digest: cut still marked" true "$(jqf '.cut')"
check "perm no digest: sha256 omitted" false "$(jqf 'has("sha256")')"

# --- blocker text: full block (credo item #162) ---------------------------------
echo "== blocker text: full block"
# blockq <index> <jq expr>: the expression on the blocker event at that index (raw, no newline)
blockq() {
    jq -s -j --argjson i "$1" "[.[] | select(.type == \"blocker\")] | .[\$i] | $2" "$OUTF" 2>/dev/null
}

new_case
reply="$(printf 'Summary\n\nBlocker: the deploy key is missing\nThe upload step fails.\nAdd the key, then rerun.')"
run "blocker: multi-line block" stop "$(stop_payload "$reply" "")"
check "blocker: text is the Blocker line plus the lines below" \
    "$(printf 'the deploy key is missing\nThe upload step fails.\nAdd the key, then rerun.')" "$(blockq 0 '.text')"
check "blocker: text starts without the prefix, the summary is not included" false \
    "$(blockq 0 '.text | startswith("Summary")')"
check "blocker: short block has no cut" false "$(blockq 0 'has("cut")')"
check "blocker: event keys unchanged plus text" "cwd,session_id,text,ts,type" "$(blockq 0 'keys | join(",")')"

new_case
reply="$(printf 'Blocker: the rank is open\nTwo options exist.\n### %s Q4) Which rank?\nA or B?\n## Other\nNot in the block' "$Q")"
run "blocker: ends at a code heading" stop "$(stop_payload "$reply" "")"
check "blocker: block stops before the question code" \
    "$(printf 'the rank is open\nTwo options exist.')" "$(blockq 0 '.text')"

new_case
reply="$(printf 'Blocker: the key is missing\nDetail one\n## Next steps\nDo this later')"
run "blocker: ends at a markdown heading" stop "$(stop_payload "$reply" "")"
check "blocker: block stops before a markdown heading" \
    "$(printf 'the key is missing\nDetail one')" "$(blockq 0 '.text')"

new_case
reply="$(printf 'Blocker: first problem\nfirst detail\n\nBlocker: second problem\nsecond detail')"
run "blocker: two blockers" stop "$(stop_payload "$reply" "")"
check "blocker: two blockers, two events" 2 "$(count)"
check "blocker: first event has its own block" "$(printf 'first problem\nfirst detail')" "$(blockq 0 '.text')"
check "blocker: second event has its own block" "$(printf 'second problem\nsecond detail')" "$(blockq 1 '.text')"

new_case
reply="$(printf 'Blocker: first problem\nBlocker: second problem')"
run "blocker: two adjacent blockers" stop "$(stop_payload "$reply" "")"
check "blocker: adjacent blocker line ends the block" "first problem" "$(blockq 0 '.text')"
check "blocker: adjacent second blocker has its own event" "second problem" "$(blockq 1 '.text')"

new_case
reply="$(printf 'Blocker: the script fails\n%sbash\n# not a heading\nmake check\n%s\nEnd of the reply' "$FENCE" "$FENCE")"
run "blocker: fenced comment is text" stop "$(stop_payload "$reply" "")"
check "blocker: fenced block kept whole" \
    "$(printf 'the script fails\n%sbash\n# not a heading\nmake check\n%s\nEnd of the reply' "$FENCE" "$FENCE")" "$(blockq 0 '.text')"

new_case
run "blocker: none with following lines" stop "$(stop_payload "$(printf 'Blocker: none\nsome status text')" "")"
check "blocker: none stays silent" 0 "$(count)"

new_case
line_long="$(printf 'a%.0s' $(seq 1 1500))"
run "blocker: 1500-character line" stop "$(stop_payload "Blocker: $line_long" "")"
check "blocker: a line over 1000 characters is no longer cut" 1500 "$(blockq 0 '.text | length')"
check "blocker: no cut flag below 4000 characters" false "$(blockq 0 'has("cut")')"

new_case
long_body="$(printf 'word %.0s' $(seq 1 1000))"
reply="$(printf 'Blocker: long context\n%s' "$long_body")"
run "blocker: over 4000 characters" stop "$(stop_payload "$reply" "")"
check "blocker: cut true when shortened" true "$(blockq 0 '.cut')"
check "blocker: capped at 4000 characters" true "$(blockq 0 '(.text | length) <= 4000')"
check "blocker: cut between words" true "$(blockq 0 '.text | endswith("word")')"
check "blocker: starts with the Blocker line" true "$(blockq 0 '.text | startswith("long context\nword")')"

new_case
reply="$(printf 'Blocker: the key is missing\nSet TOKEN=abc123 first.\nThen go.')"
run "blocker: secret in the block" stop "$(stop_payload "$reply" "")"
check "blocker: secret masked inside the block" \
    "$(printf 'the key is missing\nSet TOKEN=*** first.\nThen go.')" "$(blockq 0 '.text')"
check "blocker: raw secret never sent" 0 "$(grep -c 'abc123' "$OUTF")"

new_case
filler="$(printf 'word %.0s' $(seq 1 798))"
reply="$(printf 'Blocker: long\n%sghp_0123456789abcdefghij0123' "$filler")"
run "blocker: cut at a token" stop "$(stop_payload "$reply" "")"
check "blocker: edge cut marked" true "$(blockq 0 '.cut')"
check "blocker: partial token prefix not sent" 0 "$(grep -c 'ghp_0' "$OUTF")"

new_case
hexsec="0123456789abcdef0123456789abcdef01234567"
blong="$(printf 'a%.0s' $(seq 1 3968))/"
run "blocker: whitespace-free run at the cut" stop "$(stop_payload "Blocker: $blong$hexsec" "")"
check "blocker: no partial secret at a whitespace-free cut" 0 "$(grep -c '0123456789abcdef' "$OUTF")"
check "blocker: cut flagged at a whitespace-free cut" true "$(blockq 0 '.cut')"

# --- question context: the reply text above the heading (credo item #165) ------------
echo "== question context"
# codeq <type> <index> <jq expr>: the expression on the event of that type at that index
codeq() {
    jq -s -j --argjson i "$2" "[.[] | select(.type == \"$1\")] | .[\$i] | $3" "$OUTF" 2>/dev/null
}

new_case
reply="$(printf 'The problem is the cache.\nIt keeps old rows.\n\n### %s Q7) Clear it?\nA or B?' "$Q")"
run "context: text above the question" stop "$(stop_payload "$reply" "")"
check "context: question carries the text above its heading" \
    "$(printf 'The problem is the cache.\nIt keeps old rows.')" "$(codeq question_codes 0 '.context')"
check "context: text below unchanged" "A or B?" "$(codeq question_codes 0 '.text')"
check "context: short context has no context_cut" false "$(codeq question_codes 0 'has("context_cut")')"

new_case
reply="$(printf 'Intro\n### %s Q1) First?\nfirst body\n## Other\nBetween the two\n### %s Q2) Second?\nsecond body' "$Q" "$Q")"
run "context: second question starts after the first block" stop "$(stop_payload "$reply" "")"
check "context: first question context is the intro" "Intro" "$(codeq question_codes 0 '.context')"
check "context: second question context starts at the end of the first block" \
    "$(printf '## Other\nBetween the two')" "$(codeq question_codes 1 '.context')"

new_case
reply="$(printf '### %s Q3) Bare?\nonly body' "$Q")"
run "context: question at the reply start" stop "$(stop_payload "$reply" "")"
check "context: no context field when nothing is above" false "$(codeq question_codes 0 'has("context")')"

new_case
reply="$(printf 'Why\n%s\n### %s Q9) not a heading\n%s\n### %s Q8) Real?\nbody' "$FENCE" "$Q" "$FENCE" "$Q")"
run "context: fenced heading is context" stop "$(stop_payload "$reply" "")"
check "context: one event only (fenced heading ignored)" 1 "$(count)"
check "context: fenced lines stay in the context" \
    "$(printf 'Why\n%s\n### %s Q9) not a heading\n%s' "$FENCE" "$Q" "$FENCE")" "$(codeq question_codes 0 '.context')"

new_case
reply="$(printf 'Run this first.\n### %s T5) Smoke test [blocking]\nsteps' "$T")"
run "context: blocking test" stop "$(stop_payload "$reply" "")"
check "context: blocking test carries context" "Run this first." "$(codeq test_blocking 0 '.context')"

new_case
long_ctx="$(printf 'word %.0s' $(seq 1 1000))"
reply="$(printf '%s\n### %s Q6) Long?\nbody' "$long_ctx" "$Q")"
run "context: over 4000 characters" stop "$(stop_payload "$reply" "")"
check "context: context_cut true when shortened" true "$(codeq question_codes 0 '.context_cut')"
check "context: capped at 4000" true "$(codeq question_codes 0 '(.context | length) <= 4000')"
check "context: the end right above the heading is kept" true "$(codeq question_codes 0 '.context | endswith("word")')"

new_case
ctx_lines="$(for i in $(seq 1 300); do printf 'line number %03d of the context\n' "$i"; done)"
reply="$(printf '%s\nThe key point right above.\n### %s Q4) Which?\nbody' "$ctx_lines" "$Q")"
run "context: long multi-line context" stop "$(stop_payload "$reply" "")"
check "context: multi-line context_cut" true "$(codeq question_codes 0 '.context_cut')"
check "context: keeps the last line above the heading" true \
    "$(codeq question_codes 0 '.context | endswith("The key point right above.")')"
check "context: the first lines are dropped" false "$(codeq question_codes 0 '.context | contains("line number 001")')"
check "context: starts at a line boundary" true "$(codeq question_codes 0 '.context | test("^line number [0-9]{3} of the context\n")')"
check "context: capped at 4000 (lines)" true "$(codeq question_codes 0 '(.context | length) <= 4000')"

new_case
reply="$(printf 'Use TOKEN=abc123 here.\n### %s Q2) Ok?\nbody' "$Q")"
run "context: secret masked" stop "$(stop_payload "$reply" "")"
check "context: raw secret never sent" 0 "$(grep -c 'abc123' "$OUTF")"

# --- command replies: the answer to a raw slash command (credo item #166) ---------
echo "== command replies"
tr_meta() { jq -cn --arg u "$1" --arg t "$2" '{type: "user", uuid: $u, isMeta: true, timestamp: "2000-01-01T00:00:01Z", message: {role: "user", content: [{type: "text", text: $t}]}}' >> "$TR"; }
tr_cmd() { jq -cn --arg u "$1" --arg t "$2" '{type: "user", uuid: $u, timestamp: "2000-01-01T00:00:00Z", message: {role: "user", content: $t}}' >> "$TR"; }
cmdq() { jq -s -j "[.[] | select(.type == \"command_reply\")] | .[0] | $1" "$OUTF" 2>/dev/null; }

new_case
tr_cmd u-c1 "$(printf '<command-message>credo:review</command-message>\n<command-name>/credo:review</command-name>\n<command-args>now</command-args>')"
tr_meta u-c2 "Base directory for this skill: /x. Skill body with TOKEN=abc123 text."
tr_tool a-c1
tr_result u-c3
tr_text a-c2 "Review done, nothing found."
run "command: skill command with a meta body" stop "$(stop_payload "Review done, nothing found." "$TR")"
check "command: one event" 1 "$(count)"
check "command: type" command_reply "$(cmdq '.type')"
check "command: name with plugin prefix" "/credo:review" "$(cmdq '.command')"
check "command: text is the final reply" "Review done, nothing found." "$(cmdq '.text')"
check "command: prompt timestamp" "2000-01-01T00:00:00Z" "$(cmdq '.prompt_ts')"
check "command: no cut on a short reply" false "$(cmdq 'has("cut")')"
check "command: skill body never sent" 0 "$(grep -c 'abc123' "$OUTF")"

run "command: same turn stopped again" stop "$(stop_payload "Review done, nothing found." "$TR")"
check "command: answered once" 1 "$(count)"

new_case
tr_cmd u-d1 "$(printf '<command-name>/foo</command-name>\n<command-message>foo</command-message>')"
run "command: not answered yet" stop "$(stop_payload "" "$TR")"
check "command: no event without a reply after it" 0 "$(count)"
tr_text a-d1 "$(printf 'word %.0s' $(seq 1 2000))"
run "command: long reply" stop "$(stop_payload "" "$TR")"
check "command: plain name" "/foo" "$(cmdq '.command')"
check "command: a 10000-character reply is sent whole, trimmed (limit 1 MiB)" 9999 "$(cmdq '.text | length')"
check "command: no cut below 1 MiB" false "$(cmdq 'has("cut")')"

new_case
tr_prompt u-e1 "[remote chat c-9] /status please"
tr_text a-e1 "Status ok."
run "command: remote chat prompt" stop "$(stop_payload "Status ok." "$TR")"
check "command: a remote chat prompt stays a remote_reply" remote_reply "$(jqf '.type')"
check "command: no command_reply for it" 0 "$(grep -c command_reply "$OUTF")"

new_case
tr_prompt u-f1 "plain prompt"
tr_text a-f1 "plain answer"
run "command: normal prompt" stop "$(stop_payload "plain answer" "$TR")"
check "command: a normal prompt is not mirrored" 0 "$(count)"

# --- legacy letter codes (credo item #170) ------------------------------------------
echo "== legacy letter codes"
new_case
run "legacy: letter question" stop "$(stop_payload "$(printf '### %s B) #57 rank\nA or B?' "$Q")" "")"
check "legacy: letter question sent" question_codes "$(codeq question_codes 0 '.type')"
check "legacy: code is the letter" B "$(codeq question_codes 0 '.code')"
check "legacy: heading" "#57 rank" "$(codeq question_codes 0 '.heading')"
run "legacy: same letter, same topic again" stop "$(stop_payload "$(printf '### %s B) #57 rank\nA or B?' "$Q")" "")"
check "legacy: same question sent once" 1 "$(count)"
run "legacy: same letter, new topic" stop "$(stop_payload "$(printf '### %s B) #60 colour\nRed?' "$Q")" "")"
check "legacy: a reused letter with a new topic is sent again" 2 "$(count)"
run "legacy: letter test blocking" stop "$(stop_payload "$(printf '### %s B) Smoke [blocking]\nsteps' "$T")" "")"
check "legacy: letter test does not collide with the letter question" 3 "$(count)"
run "legacy: two letters are no code" stop "$(stop_payload "$(printf '### %s AB) nope\nx' "$Q")" "")"
check "legacy: only single letters" 3 "$(count)"

# --- remote chat texts up to 1 MiB, visible marker above (credo item #173) ----------
echo "== remote 1 MiB"
big_payload() { # file with a stop payload whose final reply has the given number of 10-byte lines
    python3 -I - "$1" "$SID" "$CWD" "$TR" > "$TMP/big.json" <<'PY'
import json, sys
n, sid, cwd, tr = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
text = "".join("line %04d\n" % (i % 10000) for i in range(n)) + "THE END"
print(json.dumps({"session_id": sid, "cwd": cwd, "hook_event_name": "Stop",
                  "last_assistant_message": text, "transcript_path": tr}))
PY
}
new_case
tr_prompt u-g1 "[remote chat c-big] long one please"
tr_text a-g1 "placeholder"
big_payload 50000
run "remote: 500 KB reply" stop "$(cat "$TMP/big.json")"
check "remote: a 500 KB reply is sent whole" true "$(jqf '.text | endswith("THE END")')"
check "remote: no cut flag below 1 MiB" false "$(jqf 'has("cut")')"

new_case
tr_prompt u-g2 "[remote chat c-big] longer please"
tr_text a-g2 "placeholder"
big_payload 120000
run "remote: 1.2 MB reply" stop "$(cat "$TMP/big.json")"
check "remote: over the limit refused visibly (too_long)" true "$(jqf '.too_long')"
check "remote: over the limit sends no text" "" "$(jqf '.text')"
check "remote: over the limit carries its length in characters" 1200007 "$(jqf '.length')"
check "remote: over the limit carries the limit" 1048576 "$(jqf '.limit')"
check "remote: never cut" false "$(jqf 'has("cut")')"

new_case
tr_prompt u-g3 "[remote chat c-big] multibyte please"
tr_text a-g3 "placeholder"
python3 -I - "$SID" "$CWD" "$TR" > "$TMP/big.json" <<'PY'
import json, sys
sid, cwd, tr = sys.argv[1], sys.argv[2], sys.argv[3]
text = "\u00e4" * 1048576
print(json.dumps({"session_id": sid, "cwd": cwd, "hook_event_name": "Stop",
                  "last_assistant_message": text, "transcript_path": tr}))
PY
run "remote: 1048576 multibyte characters" stop "$(cat "$TMP/big.json")"
check "remote: the limit counts characters, not bytes (2 MiB of UTF-8 sent whole)" 1048576 "$(jqf '.text | length')"
check "remote: at the limit no too_long" false "$(jqf 'has("too_long")')"

# --- Ask option preview (credo item #175) -----------------------------------------
echo "== ask preview"
new_case
pv_payload="$(jq -n --arg s "$SID" --arg c "$CWD" '{
    session_id: $s, cwd: $c, hook_event_name: "PreToolUse",
    tool_name: "AskUserQuestion", tool_use_id: "toolu_pv",
    tool_input: {questions: [{question: "Layout?", header: "Layout", multiSelect: false,
        options: [{label: "A", description: "left", preview: "+--+\n|A |\n+--+"},
                  {label: "B", description: "right"}]}]}}')"
run "ask: options with a preview" ask "$pv_payload"
check "ask: preview passed on" '"+--+\n|A |\n+--+"' "$(jqf '.questions[0].options[0].preview | @json')"
check "ask: an option without preview has no preview key" false "$(jqf '.questions[0].options[1] | has("preview")')"

# --- transcript read as JSON, broken line fallback (credo item #175) --------------
echo "== transcript json read"
new_case
tr_prompt u-h1 "[remote chat c-h] umlauts?"
printf '%s\n' '{"type":"assistant","broken' >> "$TR"
tr_text a-h1 "Grüße, alles läuft."
run "transcript: a broken line in between" stop "$(stop_payload "" "$TR")"
check "transcript: broken line skipped, reply still sent" remote_reply "$(jqf '.type')"
check "transcript: umlauts intact" "Grüße, alles läuft." "$(jqf '.text')"

new_case
tr_prompt u-h2 "[remote chat c-h] long umlauts?"
long_uml="$(python3 -I -c "print('Größe ' * 15000, end='')")"
tr_text a-h2 "$long_uml"
run "transcript: long multibyte reply from the transcript" stop "$(stop_payload "" "$TR")"
check "transcript: long multibyte reply has no replacement characters" 0 "$(jqf '.text | [scan("�")] | length')"
check "transcript: long multibyte reply length kept" 90000 "$(jqf '.text | length')"

# --- owner at the PC: no questions/permissions mirrored (credo item #179) ----------
echo "== owner present"
tr_owner() { # uuid, text, seconds ago
    jq -cn --arg u "$1" --arg t "$2" --arg ts "$(date -u -d "@$(( $(date +%s) - $3 ))" +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{type: "user", uuid: $u, timestamp: $ts, message: {role: "user", content: $t}}' >> "$TR"
}
ask_tr_payload() { # tool_use_id
    jq -n --arg s "$SID" --arg c "$CWD" --arg id "$1" --arg tr "$TR" '{
        session_id: $s, cwd: $c, hook_event_name: "PreToolUse", transcript_path: $tr,
        tool_name: "AskUserQuestion", tool_use_id: $id,
        tool_input: {questions: [{question: "Pick?", header: "Pick", multiSelect: false,
            options: [{label: "a", description: "x"}, {label: "b", description: "y"}]}]}}'
}
new_case
tr_owner u-o1 "please do x" 60
run "present: ask one minute after an owner prompt" ask "$(ask_tr_payload toolu_p1)"
check "present: ask not mirrored" 0 "$(count)"
run "present: permission one minute after an owner prompt" permission "$(jq -n --arg s "$SID" --arg c "$CWD" --arg tr "$TR" '{session_id: $s, cwd: $c, hook_event_name: "PermissionRequest", transcript_path: $tr, tool_name: "Bash", tool_input: {command: "ls -la"}, permission_mode: "default"}')"
check "present: permission not mirrored" 0 "$(count)"
run "present: question code" stop "$(jq -n --arg s "$SID" --arg c "$CWD" --arg tr "$TR" --arg m "$(printf '### %s Q8) Ship?\nA or B?' "$Q")" '{session_id: $s, cwd: $c, hook_event_name: "Stop", transcript_path: $tr, last_assistant_message: $m}')"
check "present: question code not mirrored" 0 "$(count)"

new_case
tr_owner u-o2 "please do y" 1200
run "away: ask 20 minutes after the last owner prompt" ask "$(ask_tr_payload toolu_p2)"
check "away: ask mirrored" 1 "$(count)"

new_case
tr_owner u-o3 "please do z" 1200
tr_owner u-o4 "$(printf '<cross-session-message from="x">peer text</cross-session-message>')" 30
tr_owner u-o5 "[remote chat c-1] from the app" 20
tr_owner u-o6 "$(printf '<command-name>/reload-skills</command-name>')" 10
tr_owner u-o7 "." 5
run "away: peer, app, reload and dot prompts do not count as the owner at the PC" ask "$(ask_tr_payload toolu_p3)"
check "away: ask mirrored despite recent automated prompts" 1 "$(count)"

new_case
tr_owner u-o8 "please do w" 60
CREDO_REMOTE_MIRROR_IDLE_MINUTES=0 run "idle 0: always mirror" ask "$(ask_tr_payload toolu_p4)"
check "idle 0: ask mirrored even with the owner present" 1 "$(count)"

new_case
tr_owner u-o9 "please do v" 60
mkdir -p "$CFG_ROOT/credo/session-modes"
printf 'autonomous\n' > "$CFG_ROOT/credo/session-modes/$SID"
run "autonomous: mirror" ask "$(ask_tr_payload toolu_p5)"
check "autonomous (not paused): ask mirrored" 1 "$(count)"
mkdir -p "$CFG_ROOT/credo/autonomy/$SID"; : > "$CFG_ROOT/credo/autonomy/$SID/paused"
run "autonomous paused: owner present" ask "$(ask_tr_payload toolu_p6)"
check "autonomous paused with a recent owner prompt: not mirrored" 1 "$(count)"
rm -f "$CFG_ROOT/credo/session-modes/$SID" "$CFG_ROOT/credo/autonomy/$SID/paused"

new_case
tr_owner u-o10 "local prompt at the PC" 120
tr_owner u-o11 "[remote chat c-5] status?" 30
tr_text a-o1 "All fine."
run "present: remote reply still mirrored" stop "$(stop_payload "All fine." "$TR")"
check "present: the reply to the app is mirrored while the owner is at the PC" remote_reply "$(jqf '.type')"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]

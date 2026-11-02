#!/bin/bash
# Tests for the credo session registry: one entry per Claude session (session id, name,
# host, pid and start time, tmux socket and pane, credo mode, updated) under the profile.
#   scripts/credo_session_registry.py   logic (record, verify, prune, paths)
#   scripts/credo-session-registry.py   CLI: record (hook input), list, resolve
#   hooks/credo-session-registry.sh     SessionStart + UserPromptSubmit wrapper
#
# Covered:
#   - hooks.json runs the wrapper under SessionStart and UserPromptSubmit
#   - record: one file per session under <profile>/credo/session-registry/ (0600, dir 0700),
#     exactly the whitelisted keys, a sentinel env value never reaches the file
#   - name: user caption, else the tmux session of the pane, else the short session id
#   - unchanged input rewrites nothing (mtime stable), a changed caption rewrites
#   - tmux pane recorded only when the process tree confirms it (owner check), not when
#     the pane is owned by another pid or its server is gone; no tmux: no pane
#   - no descriptor for the hook's process tree, a subagent call, a bad session id, the
#     off toggle and garbage stdin write nothing; the hook prints nothing
#   - SessionStart prunes dead entries older than a day (live and young ones stay);
#     UserPromptSubmit prunes nothing
#   - resolve: live; stale when the process is gone, its start time changed, its
#     descriptor names another session, its pane is gone, dead or owned by another pid;
#     not-found and ambiguous names; the entry goes stale when the session ends
#   - list and list --json; --all-profiles reaches a second profile, the default does not
#
# Fixtures: the "agent" is a bash process (tests/fixtures agent.sh) whose own pid is the
# session pid, so the hook really runs under it. tmux is a fake binary on PATH that answers
# display-message from a table file; the real tmux server is never contacted. HOME and
# CLAUDE_CONFIG_DIR point into a fresh mktemp directory; the real profile is never touched.
# The temp directory is NOT removed by this script: the credo safety rules forbid a delete
# whose path holds a shell variable, so the path is printed at the end for removal.
#
# Usage: bash test-credo-session-registry.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/credo-session-registry.py"
MODULE="$SCRIPT_DIR/credo_session_registry.py"
HOOK="$SCRIPT_DIR/../hooks/credo-session-registry.sh"
HOOKS_JSON="$SCRIPT_DIR/../hooks/hooks.json"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }
for f in "$CLI" "$MODULE" "$HOOK" "$HOOKS_JSON"; do
    [ -f "$f" ] || { echo "FAIL: $f missing"; echo "passed: 0, failed: 1"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpsr.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
HOME_DIR="$TMP/home"
CFG="$HOME_DIR/.claude"
BIN="$TMP/bin"
TABLE="$TMP/tmux-table"
PIDFILE="$TMP/agent.pid"
AGENT="$TMP/agent.sh"
CLI_WRAP="$TMP/cli.sh"
SOCK="$TMP/tmux.sock"
REG="$CFG/credo/session-registry"
mkdir -p "$CFG/sessions" "$CFG/credo" "$BIN" "$TMP/home"
: > "$TABLE"

PASS=0
FAIL=0
expect() { # name expected actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

# Fake tmux: display-message -p -t PANE FORMAT, answered from FAKE_TMUX_TABLE rows
# "socket<TAB>pane<TAB>pid<TAB>dead<TAB>session". Unknown pane or other server: exit 1.
cat > "$BIN/tmux" <<'PYEOF'
#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
sock = None
if len(args) >= 2 and args[0] == "-S":
    sock, args = args[1], args[2:]
if not args or args[0] != "display-message":
    sys.exit(1)
pane = None
for i, a in enumerate(args):
    if a == "-t" and i + 1 < len(args):
        pane = args[i + 1]
fmt = args[-1]
try:
    with open(os.environ["FAKE_TMUX_TABLE"]) as fh:
        rows = [ln.rstrip("\n").split("\t") for ln in fh if ln.strip()]
except OSError:
    sys.exit(1)
for row in rows:
    if len(row) != 5 or row[0] != sock or row[1] != pane:
        continue
    _, p, pid, dead, session = row
    if "#{session_name}" in fmt:
        print(session)
    else:
        print("\t".join([p, pid, "0", dead]))
    sys.exit(0)
sys.exit(1)
PYEOF
chmod +x "$BIN/tmux"

# Fixture agent: stands in for a Claude Code process. Its own pid is the session pid.
cat > "$AGENT" <<'AGENTEOF'
#!/bin/bash
# Usage: agent.sh <hook-json> <session-id> <name> <name-source>
# Writes the session descriptor for its own pid, optionally a fake tmux row for its own pid,
# runs the registry hook (twice, then with AGENT_SECOND_NAME as a user caption), writes the
# pid file, runs AGENT_SCENARIO while still alive, and exits.
json="$1"
sid="$2"
name="$3"
source="$4"
pid="$$"
start="$(awk '{print $22}' "/proc/$pid/stat")"
desc="$CLAUDE_CONFIG_DIR/sessions/$pid.json"
entry="$CLAUDE_CONFIG_DIR/credo/session-registry/$sid.json"
write_desc() {
    printf '{"pid":%s,"sessionId":"%s","name":"%s","nameSource":"%s","procStart":"%s"}\n' \
        "$pid" "$sid" "$1" "$2" "$start" > "$desc"
}
trace() {
    if [ -n "${AGENT_TRACE:-}" ]; then
        stat -c '%.9Y' "$entry" >> "$AGENT_TRACE" 2>/dev/null || echo missing >> "$AGENT_TRACE"
    fi
}
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
write_desc "$name" "$source"
if [ -n "${AGENT_TABLE_PANE:-}" ]; then
    tpid="$pid"
    if [ -n "${AGENT_TABLE_PID:-}" ]; then tpid="$AGENT_TABLE_PID"; fi
    printf '%s\t%s\t%s\t0\t%s\n' "$AGENT_TABLE_SOCKET" "$AGENT_TABLE_PANE" "$tpid" \
        "${AGENT_TABLE_SESSION:-work}" > "$FAKE_TMUX_TABLE"
fi
printf '%s' "$json" | bash "$AGENT_HOOK"
trace
printf '%s' "$json" | bash "$AGENT_HOOK"
trace
if [ -n "${AGENT_SECOND_NAME:-}" ]; then
    write_desc "$AGENT_SECOND_NAME" "user"
    printf '%s' "$json" | bash "$AGENT_HOOK"
    trace
fi
printf '%s\n' "$pid" > "$AGENT_PID_FILE"
if [ -n "${AGENT_SCENARIO:-}" ]; then
    bash "$AGENT_SCENARIO"
fi
exit 0
AGENTEOF

# Scenarios run inside the live agent ($PPID is the agent pid).
cat > "$TMP/scn-resolve.sh" <<'SCNEOF'
"$CLI_WRAP" resolve "$SCN_SID" --json > "$SCN_OUT"; echo "$?" > "$SCN_OUT.rc"
"$CLI_WRAP" list --json > "$SCN_OUT.list"
SCNEOF
cat > "$TMP/scn-pane-gone.sh" <<'SCNEOF'
: > "$FAKE_TMUX_TABLE"
"$CLI_WRAP" resolve "$SCN_SID" --json > "$SCN_OUT"; echo "$?" > "$SCN_OUT.rc"
SCNEOF
cat > "$TMP/scn-pane-dead.sh" <<'SCNEOF'
printf '%s\t%s\t%s\t1\twork\n' "$SCN_SOCK" "%3" "$PPID" > "$FAKE_TMUX_TABLE"
"$CLI_WRAP" resolve "$SCN_SID" --json > "$SCN_OUT"; echo "$?" > "$SCN_OUT.rc"
SCNEOF
cat > "$TMP/scn-pane-moved.sh" <<'SCNEOF'
printf '%s\t%s\t%s\t0\twork\n' "$SCN_SOCK" "%3" "1" > "$FAKE_TMUX_TABLE"
"$CLI_WRAP" resolve "$SCN_SID" --json > "$SCN_OUT"; echo "$?" > "$SCN_OUT.rc"
SCNEOF
cat > "$TMP/scn-desc-other.sh" <<'SCNEOF'
printf '{"pid":%s,"sessionId":"other-0000-0000-0000-000000000001"}\n' "$PPID" \
    > "$CLAUDE_CONFIG_DIR/sessions/$PPID.json"
"$CLI_WRAP" resolve "$SCN_SID" --json > "$SCN_OUT"; echo "$?" > "$SCN_OUT.rc"
SCNEOF
cat > "$TMP/scn-resolve-name.sh" <<'SCNEOF'
"$CLI_WRAP" resolve "$SCN_NAME" --json > "$SCN_OUT"; echo "$?" > "$SCN_OUT.rc"
SCNEOF
cat > "$TMP/scn-start-changed.sh" <<'SCNEOF'
printf '{"session_id":"%s","name":"x","harness":"claude","host":"fixture-host","pid":%s,"pid_start":"1","mode":null,"tmux":null,"updated":"2001-02-03T04:05:06+00:00"}\n' \
    "$SCN_SID" "$PPID" > "$CLAUDE_CONFIG_DIR/credo/session-registry/$SCN_SID.json"
"$CLI_WRAP" resolve "$SCN_SID" --json > "$SCN_OUT"; echo "$?" > "$SCN_OUT.rc"
SCNEOF

# The CLI with the same clean environment the agents use.
cat > "$CLI_WRAP" <<EOF
#!/bin/bash
exec env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" LANG=C.UTF-8 CLAUDE_CONFIG_DIR="$CFG" FAKE_TMUX_TABLE="$TABLE" python3 "$CLI" "\$@"
EOF
chmod +x "$CLI_WRAP"

cli() { env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" LANG=C.UTF-8 CLAUDE_CONFIG_DIR="$CFG" FAKE_TMUX_TABLE="$TABLE" python3 "$CLI" "$@"; }

agent_run() { # hook-json session-id name name-source [VAR=value ...]
    local json="$1" sid="$2" name="$3" source="$4"
    shift 4
    env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" LANG=C.UTF-8 \
        CLAUDE_CONFIG_DIR="$CFG" FAKE_TMUX_TABLE="$TABLE" AGENT_PID_FILE="$PIDFILE" \
        AGENT_HOOK="$HOOK" CLI_WRAP="$CLI_WRAP" "$@" \
        bash "$AGENT" "$json" "$sid" "$name" "$source"
}

hook_json() { # session-id event [agent-id]
    if [ -n "${3:-}" ]; then
        jq -cn --arg s "$1" --arg e "$2" --arg a "$3" '{session_id: $s, hook_event_name: $e, agent_id: $a}'
    else
        jq -cn --arg s "$1" --arg e "$2" '{session_id: $s, hook_event_name: $e}'
    fi
}

make_entry() { # session-id pid pid-start name tmux-json-or-null [profile-dir]
    local dir="${6:-$CFG}/credo/session-registry"
    mkdir -p "$dir"
    jq -cn --arg sid "$1" --argjson pid "$2" --arg start "$3" --arg name "$4" --argjson tmux "$5" \
        '{session_id: $sid, name: $name, harness: "claude", host: "fixture-host", pid: $pid,
          pid_start: $start, mode: null, tmux: $tmux, updated: "2001-02-03T04:05:06+00:00"}' \
        > "$dir/$1.json"
}

field() { jq -r "$2 // \"null\"" "$1" 2>/dev/null; }

# ---------------------------------------------------------------- hooks.json wiring
jq -e '[.hooks.SessionStart[].hooks[].command] | any(endswith("credo-session-registry.sh"))' "$HOOKS_JSON" >/dev/null 2>&1
expect "hooks.json: SessionStart runs the registry hook" 0 $?
jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | any(endswith("credo-session-registry.sh"))' "$HOOKS_JSON" >/dev/null 2>&1
expect "hooks.json: UserPromptSubmit runs the registry hook" 0 $?

# ---------------------------------------------------------------- record: basic entry
SID_A="a1b2c3d4-0000-4000-8000-00000000000a"
mkdir -p "$CFG/credo/session-modes"
printf 'active\n' > "$CFG/credo/session-modes/$SID_A"
TRACE_A="$TMP/trace-a"
OUT_A="$(agent_run "$(hook_json "$SID_A" SessionStart)" "$SID_A" "box-1" derived \
    ZQ_SENTINEL_SECRET=zq-sentinel-7731 AGENT_TRACE="$TRACE_A" \
    AGENT_SCENARIO="$TMP/scn-resolve.sh" SCN_SID="$SID_A" SCN_OUT="$TMP/out-a.json")"
PID_A="$(cat "$PIDFILE")"
ENTRY_A="$REG/$SID_A.json"
expect "record: hook and agent print nothing" "" "$OUT_A"
[ -f "$ENTRY_A" ]
expect "record: one entry file per session id" 0 $?
expect "record: entry file mode 0600" 600 "$(stat -c %a "$ENTRY_A" 2>/dev/null)"
expect "record: registry dir mode 0700" 700 "$(stat -c %a "$REG" 2>/dev/null)"
expect "record: session_id" "$SID_A" "$(field "$ENTRY_A" .session_id)"
expect "record: harness" "claude" "$(field "$ENTRY_A" .harness)"
expect "record: host is the host name" "$(uname -n)" "$(field "$ENTRY_A" .host)"
expect "record: pid is the session process" "$PID_A" "$(field "$ENTRY_A" .pid)"
expect "record: pid_start is the process start time" \
    "$(field "$CFG/sessions/$PID_A.json" .procStart)" "$(field "$ENTRY_A" .pid_start)"
expect "record: credo mode from the session-modes state" "active" "$(field "$ENTRY_A" .mode)"
expect "record: no tmux pane outside tmux" "null" "$(field "$ENTRY_A" .tmux)"
expect "record: derived name falls back to the short id" "a-0-4-8-0a" "$(field "$ENTRY_A" .name)"
expect "record: exactly the whitelisted keys" \
    "harness,host,mode,name,pid,pid_start,session_id,tmux,updated" \
    "$(jq -r 'keys_unsorted | sort | join(",")' "$ENTRY_A" 2>/dev/null)"
grep -q "zq-sentinel-7731" "$ENTRY_A"
expect "record: no environment value in the file" 1 $?
T1="$(sed -n 1p "$TRACE_A" 2>/dev/null)"
T2="$(sed -n 2p "$TRACE_A" 2>/dev/null)"
expect "record: unchanged second run rewrites nothing (mtime stable)" "$T1" "$T2"
expect "record: a live agent resolves its own entry as live" "live" \
    "$(jq -r .status "$TMP/out-a.json" 2>/dev/null)"
expect "record: live resolve without tmux says so" "no tmux pane recorded" \
    "$(jq -r .reason "$TMP/out-a.json" 2>/dev/null)"
expect "record: resolve exit code while live" 0 "$(cat "$TMP/out-a.json.rc" 2>/dev/null)"
cli resolve "$SID_A" --json >/dev/null 2>&1
expect "resolve: entry of an ended session is stale (exit 1)" 1 $?
expect "resolve: ended session reports the gone process" "process $PID_A is gone" \
    "$(cli resolve "$SID_A" --json 2>/dev/null | jq -r .reason)"

# ---------------------------------------------------------------- record: caption and rewrite
SID_B="b2c3d4e5-0000-4000-8000-00000000000b"
TRACE_B="$TMP/trace-b"
agent_run "$(hook_json "$SID_B" UserPromptSubmit)" "$SID_B" "Build Task" user \
    AGENT_TRACE="$TRACE_B" AGENT_SECOND_NAME="Review Pass" >/dev/null
ENTRY_B="$REG/$SID_B.json"
expect "caption: user name is the entry name after a rename" "Review Pass" "$(field "$ENTRY_B" .name)"
TB1="$(sed -n 1p "$TRACE_B")"
TB2="$(sed -n 2p "$TRACE_B")"
TB3="$(sed -n 3p "$TRACE_B")"
expect "caption: unchanged run keeps the file (mtime stable)" "$TB1" "$TB2"
[ "$TB2" != "$TB3" ]
expect "caption: a changed name rewrites the file" 0 $?

# ---------------------------------------------------------------- record: tmux pane
SID_C="c3d4e5f6-0000-4000-8000-00000000000c"
agent_run "$(hook_json "$SID_C" SessionStart)" "$SID_C" "node-7" derived \
    TMUX="$SOCK,4242,0" TMUX_PANE=%3 AGENT_TABLE_PANE=%3 AGENT_TABLE_SOCKET="$SOCK" \
    AGENT_TABLE_SESSION=work AGENT_SCENARIO="$TMP/scn-resolve.sh" SCN_SID="$SID_C" \
    SCN_OUT="$TMP/out-c.json" >/dev/null
ENTRY_C="$REG/$SID_C.json"
PID_C="$(cat "$PIDFILE")"
expect "pane: socket recorded from TMUX" "$SOCK" "$(field "$ENTRY_C" .tmux.socket)"
expect "pane: pane id recorded from TMUX_PANE" "%3" "$(field "$ENTRY_C" .tmux.pane)"
expect "pane: tmux session recorded" "work" "$(field "$ENTRY_C" .tmux.session)"
expect "pane: owner is the session process" "$PID_C" "$(field "$ENTRY_C" .tmux.owner_pid)"
expect "pane: owner start time recorded" "$(field "$ENTRY_C" .pid_start)" "$(field "$ENTRY_C" .tmux.owner_start)"
expect "pane: name falls back to the tmux session" "work" "$(field "$ENTRY_C" .name)"
expect "pane: live resolve verifies pane and process" "live" "$(jq -r .status "$TMP/out-c.json" 2>/dev/null)"
expect "pane: live resolve message" "pane and process verified" "$(jq -r .reason "$TMP/out-c.json" 2>/dev/null)"
expect "pane: live resolve exit 0" 0 "$(cat "$TMP/out-c.json.rc" 2>/dev/null)"

# pane owned by another process (pid 1 is not this session or its ancestor): not recorded
SID_O="d4e5f6a7-0000-4000-8000-00000000000d"
agent_run "$(hook_json "$SID_O" SessionStart)" "$SID_O" "owned-elsewhere" derived \
    TMUX="$SOCK,4242,0" TMUX_PANE=%3 AGENT_TABLE_PANE=%3 AGENT_TABLE_SOCKET="$SOCK" \
    AGENT_TABLE_PID=1 >/dev/null
expect "pane: a pane owned by another pid is not recorded" "null" "$(field "$REG/$SID_O.json" .tmux)"

# tmux server gone (no row for the socket): not recorded
SID_G="e5f6a7b8-0000-4000-8000-00000000000e"
agent_run "$(hook_json "$SID_G" SessionStart)" "$SID_G" "no-server" derived \
    TMUX="$TMP/gone.sock,4242,0" TMUX_PANE=%3 AGENT_TABLE_PANE=%3 AGENT_TABLE_SOCKET="$SOCK" >/dev/null
expect "pane: a pane on a server that is gone is not recorded" "null" "$(field "$REG/$SID_G.json" .tmux)"

# ---------------------------------------------------------------- record: refusals write nothing
SID_X="f6a7b8c9-0000-4000-8000-00000000000f"
agent_run "$(hook_json "../escape-1" SessionStart)" "../escape-1" "bad-id" derived >/dev/null
[ ! -e "$CFG/credo/escape-1.json" ] && [ ! -e "$TMP/escape-1.json" ]
expect "refusal: a session id with path parts writes nothing" 0 $?
agent_run "$(hook_json "$SID_X" SessionStart "sub-agent-1")" "$SID_X" "sub" derived >/dev/null
[ ! -e "$REG/$SID_X.json" ]
expect "refusal: a subagent call writes nothing" 0 $?
SID_T="a7b8c9d0-0000-4000-8000-000000000010"
agent_run "$(hook_json "$SID_T" SessionStart)" "$SID_T" "off" derived CREDO_SESSION_REGISTRY=0 >/dev/null
[ ! -e "$REG/$SID_T.json" ]
expect "refusal: the off toggle writes nothing" 0 $?
SID_N="b8c9d0e1-0000-4000-8000-000000000011"
printf '%s' "$(hook_json "$SID_N" SessionStart)" | env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
    CLAUDE_CONFIG_DIR="$CFG" FAKE_TMUX_TABLE="$TABLE" bash "$HOOK" > "$TMP/out-n" 2>&1
expect "refusal: no descriptor in the process tree writes nothing" 0 "$(test ! -e "$REG/$SID_N.json"; echo $?)"
expect "refusal: hook without a matching process prints nothing" "" "$(cat "$TMP/out-n")"
printf 'not json at all' | env -i PATH="$BIN:/usr/bin:/bin" HOME="$HOME_DIR" \
    CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" > "$TMP/out-g" 2>&1
expect "refusal: garbage stdin exits 0" 0 $?
expect "refusal: garbage stdin prints nothing" "" "$(cat "$TMP/out-g")"

# ---------------------------------------------------------------- resolve: stale and live
SID_F="c9d0e1f2-0000-4000-8000-000000000012"
agent_run "$(hook_json "$SID_F" SessionStart)" "$SID_F" "pane-moved" derived \
    TMUX="$SOCK,4242,0" TMUX_PANE=%3 AGENT_TABLE_PANE=%3 AGENT_TABLE_SOCKET="$SOCK" \
    AGENT_SCENARIO="$TMP/scn-pane-moved.sh" SCN_SID="$SID_F" SCN_SOCK="$SOCK" SCN_OUT="$TMP/out-f.json" >/dev/null
expect "resolve: pane now owned by another pid is stale" "stale" "$(jq -r .status "$TMP/out-f.json" 2>/dev/null)"
expect "resolve: pane owned by another pid exit 1" 1 "$(cat "$TMP/out-f.json.rc" 2>/dev/null)"
expect "resolve: pane owned by another pid reason" 0 "$(jq -r .reason "$TMP/out-f.json" 2>/dev/null | grep -q 'belongs to pid 1' && echo 0 || echo 1)"

SID_D="d0e1f2a3-0000-4000-8000-000000000013"
agent_run "$(hook_json "$SID_D" SessionStart)" "$SID_D" "pane-gone" derived \
    TMUX="$SOCK,4242,0" TMUX_PANE=%3 AGENT_TABLE_PANE=%3 AGENT_TABLE_SOCKET="$SOCK" \
    AGENT_SCENARIO="$TMP/scn-pane-gone.sh" SCN_SID="$SID_D" SCN_SOCK="$SOCK" SCN_OUT="$TMP/out-d.json" >/dev/null
expect "resolve: pane that vanished is stale" "stale" "$(jq -r .status "$TMP/out-d.json" 2>/dev/null)"
expect "resolve: pane that vanished reason" "tmux pane %3 not found on its server" "$(jq -r .reason "$TMP/out-d.json" 2>/dev/null)"

SID_E="e1f2a3b4-0000-4000-8000-000000000014"
agent_run "$(hook_json "$SID_E" SessionStart)" "$SID_E" "pane-dead" derived \
    TMUX="$SOCK,4242,0" TMUX_PANE=%3 AGENT_TABLE_PANE=%3 AGENT_TABLE_SOCKET="$SOCK" \
    AGENT_SCENARIO="$TMP/scn-pane-dead.sh" SCN_SID="$SID_E" SCN_SOCK="$SOCK" SCN_OUT="$TMP/out-e.json" >/dev/null
expect "resolve: dead pane is stale" "stale" "$(jq -r .status "$TMP/out-e.json" 2>/dev/null)"
expect "resolve: dead pane reason" "tmux pane %3 is dead" "$(jq -r .reason "$TMP/out-e.json" 2>/dev/null)"

SID_H="f2a3b4c5-0000-4000-8000-000000000015"
agent_run "$(hook_json "$SID_H" SessionStart)" "$SID_H" "start-changed" derived \
    AGENT_SCENARIO="$TMP/scn-start-changed.sh" SCN_SID="$SID_H" SCN_OUT="$TMP/out-h.json" >/dev/null
expect "resolve: a reused pid (start time differs) is stale" "stale" "$(jq -r .status "$TMP/out-h.json" 2>/dev/null)"
expect "resolve: reused pid reason" 0 "$(jq -r .reason "$TMP/out-h.json" 2>/dev/null | grep -q 'reused' && echo 0 || echo 1)"

SID_I="a3b4c5d6-0000-4000-8000-000000000016"
agent_run "$(hook_json "$SID_I" SessionStart)" "$SID_I" "desc-other" derived \
    AGENT_SCENARIO="$TMP/scn-desc-other.sh" SCN_SID="$SID_I" SCN_OUT="$TMP/out-i.json" >/dev/null
expect "resolve: a pid that now runs another session is stale" "stale" "$(jq -r .status "$TMP/out-i.json" 2>/dev/null)"
expect "resolve: another session reason" 0 "$(jq -r .reason "$TMP/out-i.json" 2>/dev/null | grep -q 'another session' && echo 0 || echo 1)"

# ---------------------------------------------------------------- resolve: names and lists
DEAD="$(sh -c 'echo $$')"
DEAD_START="1"
make_entry "amb-0001-0000-0000-000000000001" "$DEAD" "$DEAD_START" "Shared Name" null
make_entry "amb-0002-0000-0000-000000000002" "$DEAD" "$DEAD_START" "shared name" null
cli resolve "Shared Name" --json > "$TMP/out-amb.json" 2>/dev/null
expect "resolve: two entries with one name are ambiguous" "ambiguous" "$(jq -r .status "$TMP/out-amb.json")"
expect "resolve: ambiguous exit 3" 3 "$(cli resolve "Shared Name" >/dev/null 2>&1; echo $?)"
expect "resolve: unknown query is not-found (exit 3)" "not-found" \
    "$(cli resolve "no-such-session" --json 2>/dev/null | jq -r .status)"
expect "resolve: not-found exit 3" 3 "$(cli resolve "no-such-session" >/dev/null 2>&1; echo $?)"

make_entry "pn-0001-0000-0000-000000000001" "$DEAD" "$DEAD_START" "plain-one" null
expect "resolve: unique name matches case-insensitively" "stale" \
    "$(cli resolve "PLAIN-ONE" --json 2>/dev/null | jq -r .status)"

OTHER="$HOME_DIR/.claude-other"
mkdir -p "$OTHER/sessions"
make_entry "other-profile-0009" "$DEAD" "$DEAD_START" "other-profile" null "$OTHER"
make_entry "dupstale-0000-0000-0000-000000000041" "$DEAD" "$DEAD_START" "dup-name" null
SID_J="j0000000-0000-4000-8000-000000000040"
agent_run "$(hook_json "$SID_J" SessionStart)" "$SID_J" "dup-name" user \
    AGENT_SCENARIO="$TMP/scn-resolve-name.sh" SCN_NAME="dup-name" SCN_OUT="$TMP/out-j.json" >/dev/null
expect "resolve: a name shared with a stale leftover resolves to the live session" "$SID_J" \
    "$(jq -r .entry.session_id "$TMP/out-j.json" 2>/dev/null)"
expect "resolve: that name resolves live (exit 0 in the agent)" "live" \
    "$(jq -r .status "$TMP/out-j.json" 2>/dev/null)"

# a symlink and a corrupt file in the registry are never read as entries
ln -s "$REG/$SID_J.json" "$REG/symlink-0001.json"
printf 'corrupt{' > "$REG/corrupt-0001.json"
cli list --json > "$TMP/out-list-odd.json" 2>/dev/null
expect "registry: list survives a corrupt file (exit 0)" 0 $?
expect "registry: a symlink entry is not read" "false" \
    "$(jq -r '[.entries[].session_id] | any(. == "symlink-0001")' "$TMP/out-list-odd.json")"
expect "registry: a corrupt entry is not listed" "false" \
    "$(jq -r '[.entries[].session_id] | any(. == "corrupt-0001")' "$TMP/out-list-odd.json")"

expect "profiles: the default list does not show another profile" "false" \
    "$(cli list --json 2>/dev/null | jq -r '[.entries[].session_id] | any(. == "other-profile-0009")')"
expect "profiles: --all-profiles shows the other profile" "$OTHER" \
    "$(cli list --all-profiles --json 2>/dev/null | jq -r '.entries[] | select(.session_id == "other-profile-0009") | .profile')"
expect "profiles: resolve in the default profile is not-found" "not-found" \
    "$(cli resolve other-profile-0009 --json 2>/dev/null | jq -r .status)"
expect "profiles: resolve with --all-profiles finds it" "stale" \
    "$(cli resolve other-profile-0009 --all-profiles --json 2>/dev/null | jq -r .status)"

expect "list: text output has a header" 0 \
    "$(cli list 2>/dev/null | head -1 | grep -q '^STATUS' && echo 0 || echo 1)"
expect "list: JSON rows carry status and reason" 0 \
    "$(cli list --json 2>/dev/null | jq -e '.entries | all(has("status") and has("reason"))' >/dev/null; echo $?)"
expect "list: a live pane row is live in JSON" "live" \
    "$(jq -r --arg s "$SID_C" '.entries[] | select(.session_id == $s) | .status' "$TMP/out-c.json.list" 2>/dev/null)"

# ---------------------------------------------------------------- prune and hook events
DEAD_OLD="dd0ld001-0000-4000-8000-000000000020"
DEAD_NEW="dd0new02-0000-4000-8000-000000000021"
LIVE_OLD="11ve0ld3-0000-4000-8000-000000000022"
mkdir -p "$REG"
make_entry "$DEAD_OLD" "$DEAD" "$DEAD_START" "dead-old" null
make_entry "$DEAD_NEW" "$DEAD" "$DEAD_START" "dead-new" null
LIVE_START="$(awk '{print $22}' /proc/$$/stat)"
make_entry "$LIVE_OLD" "$$" "$LIVE_START" "live-old" null
touch -d '3 days ago' "$REG/$DEAD_OLD.json" "$REG/$LIVE_OLD.json"
SID_U="a0b0c0d0-0000-4000-8000-000000000030"
agent_run "$(hook_json "$SID_U" UserPromptSubmit)" "$SID_U" "prompt-run" derived >/dev/null
[ -f "$REG/$DEAD_OLD.json" ]
expect "prune: UserPromptSubmit does not prune" 0 $?
SID_P="b1c1d1e1-0000-4000-8000-000000000031"
agent_run "$(hook_json "$SID_P" SessionStart)" "$SID_P" "start-run" derived >/dev/null
[ ! -e "$REG/$DEAD_OLD.json" ]
expect "prune: SessionStart drops a dead entry older than a day" 0 $?
[ -f "$REG/$DEAD_NEW.json" ]
expect "prune: a dead entry younger than a day stays" 0 $?
[ -f "$REG/$LIVE_OLD.json" ]
expect "prune: an old entry of a live process stays" 0 $?

# ---------------------------------------------------------------- end-to-end: session ends
expect "e2e: the agent-recorded session is live while running" "live" \
    "$(jq -r .status "$TMP/out-c.json" 2>/dev/null)"
expect "e2e: after the session ends its entry is stale" "stale" \
    "$(cli resolve "$SID_C" --json 2>/dev/null | jq -r .status)"

echo "passed: $PASS, failed: $FAIL"
echo "temp dir (remove by this literal path): $TMP"
[ "$FAIL" -eq 0 ]

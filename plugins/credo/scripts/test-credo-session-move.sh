#!/bin/bash
# Tests for credo-session-move.py - move Claude Code sessions from one profile
# (CLAUDE_CONFIG_DIR) to another: plan (dry run), copy, verify, cleanup-script.
#
# Everything runs against fake profile trees under a throwaway temp root. No real
# profile and no real session is touched, nothing is installed. Live sessions are
# simulated with harmless sleeper processes whose argv[0] is "claude".
#
# Covered:
#   - session resolution: caption from projects/<slug>/<id>/custom-title.json, caption
#     from transcript custom-title records only, full id, ambiguous caption, unknown
#     caption, two sessions with different slugs in one call
#   - artifact discovery from what exists for the id (transcript, id dir, tasks,
#     session-env, file-history, credo / dogma per-session state, mode files), short-id
#     names listed for review only, shared logs and profile-global config never planned
#   - fully separate target (no symlinks): everything planned as COPY, copied, verified
#   - symlink-shared target: items whose target path resolves into the source profile are
#     SHARED (skipped, never copied, never in the cleanup); a target symlink to a third
#     location is BLOCKED; nothing written through a symlink
#   - refusals: current session, live session (claude --resume <id>, live pid file),
#     stale pid file is not live, target == source, missing target, symlinked source item,
#     symlink inside a source session dir
#   - conflict detection (target has a different file) blocks the copy
#   - idempotent re-copy (everything PRESENT, nothing rewritten), mtimes preserved,
#     no misplaced items in the target
#   - verify: byte compare, size, file count; mismatch and missing file -> exit 1
#   - cleanup-script: needs --user-confirmed and a green verify manifest; created under
#     the temp base with dir 0700 / file 0600; only literal paths, no shell variables, no
#     recursive rm; only paths inside the source profile; shared items excluded; works
#     after the target copy changed by a resume; a source file changed after the verify
#     is refused; a dry run of the script with a logging rm only removes the listed
#     source paths and keeps a changed one; the generator refuses paths outside the
#     source profile and paths through a symlink
#   - non-transcript files (anything but the session's main .jsonl transcript) need EXACT
#     size + sha256 equality with the verified target copy, at generation and in the
#     script; only the append-only transcript may have grown (prefix rule)
#   - control characters in a custom title or a slug are never printed raw in the text
#     plan (escaped, with a warning)
#   - liveness details: credoPeerBridge pid files are holders, credoPeerLan mirrors are
#     skipped, a non-positive procStart is unknown (live), the /proc test seam needs
#     CREDO_SESSION_MOVE_TEST=1, unreadable / invalid pid files are listed as WARNING
#   - a file name holding a second full session id is BLOCKED; a stale verify manifest
#     temp file is refused, never truncated; unencodable cleanup text removes only its
#     own temp file
#
# Usage: bash test-credo-session-move.sh

set -uo pipefail
# CREDO_SESSION_MOVE_PROC_ROOT (fake /proc in the tests below) is honoured only with this flag
export CREDO_SESSION_MOVE_TEST=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/credo-session-move.py"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$HELPER" ]; then echo "FAIL: credo-session-move.py missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csm.XXXXXX")"
PIDS=""
cleanup() {
    for p in $PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    for p in $PIDS; do wait "$p" 2>/dev/null || true; done
    case "$TMP" in
        "${TMPDIR:-/tmp}"/csm.??????) rm -rf -- "$TMP" ;;
        *) echo "refusing to remove unexpected temp root: '$TMP'" >&2 ;;
    esac
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

S1="11111111-2222-4333-8444-555555555555"   # caption "credo-bugs" (custom-title.json)
S2="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"   # caption "other" (transcript record only)
S3="33333333-3333-4333-8333-333333333333"   # caption "dup"
S4="44444444-4444-4444-8444-444444444444"   # caption "dup"
S5="55555555-5555-4555-8555-555555555555"   # has a symlinked artifact
S6="66666666-6666-4666-8666-666666666666"   # symlink inside its id dir
S7="77777777-7777-4777-8777-777777777777"   # has a top-level profile entry
S8="88888888-8888-4888-8888-888888888888"   # custom-title.json and transcript disagree
S9="98989898-9898-4989-8989-989898989898"   # control character in the transcript cwd
S10="10101010-1010-4101-8101-101010101010"  # control characters in title and slug

# Run the helper; stdout -> $OUT, exit code -> $RC. No caller session id unless given.
run() {
    OUT="$(env -u CLAUDE_CODE_SESSION_ID CREDO_SESSION_MOVE_TMPDIR="$TMP/cleanup-base" \
        "$PY" "$HELPER" "$@" 2>&1)"
    RC=$?
}
# Same with extra environment: runx VAR=value ... -- helper args
runx() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    OUT="$(env -u CLAUDE_CODE_SESSION_ID CREDO_SESSION_MOVE_TMPDIR="$TMP/cleanup-base" \
        "${envs[@]}" "$PY" "$HELPER" "$@" 2>&1)"
    RC=$?
}
# Start a harmless sleeper; argv0 $1 ("-" = plain python), rest = extra argv.
# The pid lands in $SPID once its cmdline is visible.
sleeper() {
    local a0="$1"; shift
    if [ "$a0" = "-" ]; then
        ( exec "$PY" -c 'import time; time.sleep(600)' "$@" ) &
    else
        ( exec -a "$a0" "$PY" -c 'import time; time.sleep(600)' "$@" ) &
    fi
    SPID=$!; PIDS="$PIDS $SPID"
    for _ in $(seq 1 50); do
        tr '\0' ' ' < "/proc/$SPID/cmdline" 2>/dev/null | grep -q "time.sleep" && break
        sleep 0.1
    done
}
stop() { kill -KILL "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
# start ticks of a live pid (field 22 of /proc/<pid>/stat, as a pid file's procStart)
ticks_of() { sed 's/^.*) //' "/proc/$1/stat" | cut -d' ' -f20; }
# Evaluate a python boolean expression over the JSON in $OUT (as d).
jck() {
    printf '%s' "$OUT" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(2)
sys.exit(0 if eval(sys.argv[1]) else 1)' "$1"
}
action_of() { # json-expr helper: action of rel path $1 in session 0
    printf "[i['action'] for s in d['sessions'] for i in s['items'] if i['rel']=='%s']" "$1"
}

transcript() { # file sid cwd [title]
    {
        printf '{"type":"user","cwd":"%s","sessionId":"%s","message":"hi"}\n' "$3" "$2"
        if [ -n "${4:-}" ]; then
            printf '{"type":"custom-title","customTitle":"old-%s","sessionId":"%s"}\n' "$4" "$2"
            printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$4" "$2"
        fi
        printf '{"type":"assistant","cwd":"%s","sessionId":"%s"}\n' "$3" "$2"
    } > "$1"
}

# Build a source profile with sessions S1..S6.
mk_source() { # dir
    local s="$1" pa="$1/projects/-home-myuser-proj-a" pb="$1/projects/-home-myuser-proj-b"
    mkdir -p "$pa/$S1/subagents" "$pa/$S1/tool-results" "$pb" \
        "$s/tasks/$S1" "$s/session-env/$S1" "$s/file-history/$S1" \
        "$s/credo/session-meta" "$s/credo/session-modes" "$s/credo/autonomy/$S1" \
        "$s/dogma/session-dirs" "$s/.caveman-sessions" "$s/jobs/11111111" "$s/sessions" \
        "$s/plugins/cache" "$s/backups" "$s/shell-snapshots"
    transcript "$pa/$S1.jsonl" "$S1" /home/myuser/proj-a
    printf '{"customTitle":"credo-bugs"}' > "$pa/$S1/custom-title.json"
    printf 'agent line\n' > "$pa/$S1/subagents/agent-a1.jsonl"
    printf 'tool output\n' > "$pa/$S1/tool-results/r1.txt"
    printf '[{"id":1}]' > "$s/tasks/$S1/1.json"
    printf 'v1' > "$s/file-history/$S1/abc@v1"
    printf '{"sid":"%s"}' "$S1" > "$s/credo/session-meta/$S1.json"
    printf 'passive' > "$s/credo/session-modes/$S1"
    printf 'x' > "$s/credo/autonomy/$S1/active"
    printf '{"state":"done"}' > "$s/credo/self-compact-$S1.json"
    printf '/home/myuser/proj-a' > "$s/dogma/session-dirs/$S1"
    printf 'full' > "$s/.caveman-sessions/$S1.mode"
    printf 'job' > "$s/jobs/11111111/state"
    printf 'peer log mentions %s\n' "$S1" > "$s/credo/peer-lan.log"
    printf '{"global":true}' > "$s/settings.json"
    printf '{"oauth":"not-read"}' > "$s/.claude.json"
    printf 'plugin' > "$s/plugins/cache/$S1-not-session-state"
    printf 'old' > "$s/backups/$S1.bak"
    # S2: other slug, caption only in the transcript
    transcript "$pb/$S2.jsonl" "$S2" /home/myuser/proj-b other
    # S3 / S4: duplicate caption
    transcript "$pb/$S3.jsonl" "$S3" /home/myuser/proj-b dup
    transcript "$pb/$S4.jsonl" "$S4" /home/myuser/proj-b dup
    # S5: an artifact that is a symlink out of the profile
    transcript "$pb/$S5.jsonl" "$S5" /home/myuser/proj-b
    mkdir -p "$TMP/outside"
    printf 'secret-ish' > "$TMP/outside/file"
    mkdir -p "$s/todos"
    ln -s "$TMP/outside/file" "$s/todos/$S5-agent.json"
    # S6: a symlink inside its id dir
    transcript "$pb/$S6.jsonl" "$S6" /home/myuser/proj-b
    mkdir -p "$pb/$S6"
    ln -s "$TMP/outside/file" "$pb/$S6/link"
    # S7: an artifact directly at the profile root
    transcript "$pb/$S7.jsonl" "$S7" /home/myuser/proj-b
    printf 'top' > "$s/$S7-state.json"
    # S8: custom-title.json says "alpha", the transcript says "beta"
    transcript "$pb/$S8.jsonl" "$S8" /home/myuser/proj-b beta
    mkdir -p "$pb/$S8"
    printf '{"customTitle":"alpha"}' > "$pb/$S8/custom-title.json"
    # S9: the transcript cwd holds an escape sequence (JSON-escaped in the file)
    transcript "$pb/$S9.jsonl" "$S9" '/home/myuser/pro\u001b[31mj'
    # S10: escape sequence + newline in the custom title, escape sequence in the slug
    local pc="$1/projects/-home-myuser-pro"$'\033'"[31mj"
    mkdir -p "$pc/$S10"
    transcript "$pc/$S10.jsonl" "$S10" /home/myuser/proj-c
    printf '{"customTitle":"evil\\u001b[31mred\\nFAKE: line"}' > "$pc/$S10/custom-title.json"
    # give everything an old mtime so the "recently written" warning stays quiet
    find "$s" -exec touch -h -d '2001-02-03 04:05:06' {} +
}

SRC="$TMP/home/.claude"
mk_source "$SRC"

# Target A: fully separate profile, no symlinks.
DSTA="$TMP/home/.claude-other"
mkdir -p "$DSTA/projects" "$DSTA/credo"
printf '{"other":"settings"}' > "$DSTA/settings.json"

# Target B: symlink-shared profile (credo, plugins, settings.json shared with the source).
DSTB="$TMP/home/.claude-shared"
mkdir -p "$DSTB/projects" "$DSTB/dogma"
ln -s "$SRC/credo" "$DSTB/credo"
ln -s "$SRC/plugins" "$DSTB/plugins"
ln -s "$SRC/settings.json" "$DSTB/settings.json"

snapshot() { # dir -> sorted listing with sizes and mtimes (no content)
    (cd "$1" && find . -printf '%p %y %s %T@\n' | sort)
}

# ---------------------------------------------------------------------------
# 1. plan by caption, separate target
# ---------------------------------------------------------------------------
SRC_BEFORE="$(snapshot "$SRC")"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
ok "plan separate exit 0 (got $RC: $OUT)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
jck "d['ok'] and len(d['sessions'])==1 and d['sessions'][0]['id']=='$S1'"; ok "plan resolves caption to id" $?
jck "d['sessions'][0]['title']=='credo-bugs' and d['sessions'][0]['slug']=='-home-myuser-proj-a'"; ok "plan title + slug" $?
jck "d['sessions'][0]['cwd']=='/home/myuser/proj-a'"; ok "plan cwd from transcript" $?
for rel in "projects/-home-myuser-proj-a/$S1.jsonl" "projects/-home-myuser-proj-a/$S1" \
    "tasks/$S1" "session-env/$S1" "file-history/$S1" "credo/session-meta/$S1.json" \
    "credo/session-modes/$S1" "credo/autonomy/$S1" "credo/self-compact-$S1.json" \
    "dogma/session-dirs/$S1" ".caveman-sessions/$S1.mode"; do
    jck "$(action_of "$rel")==['copy']"; ok "plan COPY $rel" $?
done
jck "[r for s in d['sessions'] for r in s['review']]==['jobs/11111111']"; ok "short-id dir listed for review only" $?
jck "not [i for s in d['sessions'] for i in s['items'] if 'peer-lan' in i['rel'] or 'settings' in i['rel'] or i['rel'].startswith(('plugins/','backups/','sessions/'))]"
ok "shared logs / global config / plugins / backups never planned" $?
jck "'credo' in d['target_layout']['real'] and not d['target_layout']['symlinks']"; ok "separate layout detected" $?
ok "plan changed nothing in the source" "$([ "$SRC_BEFORE" = "$(snapshot "$SRC")" ] && echo 0 || echo 1)"
ok "plan wrote nothing to the target" "$([ -z "$(find "$DSTA/projects" -mindepth 1)" ] && echo 0 || echo 1)"

run plan --source "$SRC" --target "$DSTA" credo-bugs
ok "text plan shows COPY + resume hint" "$(has "$OUT" "COPY" && has "$OUT" "claude --resume $S1" && has "$OUT" "cd '/home/myuser/proj-a'" && echo 0 || echo 1)"

# --- resolution -------------------------------------------------------------
run plan --source "$SRC" --target "$DSTA" other "$S1" --json
jck "d['ok'] and [s['id'] for s in d['sessions']]==['$S2','$S1']"; ok "caption from transcript record + id, two slugs" $?
jck "d['sessions'][0]['title']=='other' and d['sessions'][0]['slug']=='-home-myuser-proj-b'"; ok "newest transcript title wins" $?
run plan --source "$SRC" --target "$DSTA" dup --json
ok "ambiguous caption refused" "$([ "$RC" = 1 ] && has "$OUT" "$S3" && has "$OUT" "$S4" && echo 0 || echo 1)"
run plan --source "$SRC" --target "$DSTA" no-such-title --json
ok "unknown caption refused" "$([ "$RC" = 1 ] && has "$OUT" "no-such-title" && echo 0 || echo 1)"
run plan --source "$SRC" --target "$DSTA" 99999999-9999-4999-8999-999999999999 --json
ok "unknown id refused" "$([ "$RC" = 1 ] && echo 0 || echo 1)"

# --- refusals ---------------------------------------------------------------
OUT="$(env CLAUDE_CODE_SESSION_ID="$S1" "$PY" "$HELPER" plan --source "$SRC" --target "$DSTA" credo-bugs 2>&1)"; RC=$?
ok "current session refused" "$([ "$RC" = 1 ] && has "$OUT" "current session" && echo 0 || echo 1)"
OUT="$(env CLAUDE_CODE_SESSION_ID="$S1" "$PY" "$HELPER" copy --source "$SRC" --target "$DSTA" credo-bugs 2>&1)"; RC=$?
ok "current session refused for copy, nothing copied" "$([ "$RC" = 1 ] && [ -z "$(find "$DSTA/projects" -mindepth 1)" ] && echo 0 || echo 1)"
run plan --source "$SRC" --target "$SRC" credo-bugs
ok "target == source refused" "$([ "$RC" = 1 ] && echo 0 || echo 1)"
run plan --source "$SRC" --target "$TMP/home/.claude-missing" credo-bugs
ok "missing target refused" "$([ "$RC" = 1 ] && echo 0 || echo 1)"
run plan --source "$SRC" --target "$DSTA" "$S5" --json
jck "not d['ok'] and $(action_of "todos/$S5-agent.json")==['blocked']"; ok "symlinked source artifact BLOCKED" $?
run plan --source "$SRC" --target "$DSTA" "$S6" --json
jck "not d['ok'] and $(action_of "projects/-home-myuser-proj-b/$S6")==['blocked']"; ok "symlink inside id dir BLOCKED" $?

# live: a claude process with --resume <id>
( export CLAUDE_CONFIG_DIR="$SRC"; exec -a claude "$PY" -c 'import time; time.sleep(600)' --resume "$S1" ) &
LIVE=$!; PIDS="$PIDS $LIVE"
for _ in $(seq 1 50); do
    tr '\0' ' ' < "/proc/$LIVE/cmdline" 2>/dev/null | grep -q "^claude .*$S1" && break
    sleep 0.1
done
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and d['sessions'][0]['live'] and d['sessions'][0]['live'][0]['pid']==$LIVE"; ok "live --resume process refused" $?
run copy --source "$SRC" --target "$DSTA" credo-bugs
ok "live session: copy refused, nothing copied" "$([ "$RC" = 1 ] && [ -z "$(find "$DSTA/projects" -mindepth 1)" ] && echo 0 || echo 1)"
kill -KILL "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

# live: a pid file naming the session, held by a running claude without the id in argv
( exec -a claude "$PY" -c 'import time; time.sleep(600)' ) &
HOLD=$!; PIDS="$PIDS $HOLD"
for _ in $(seq 1 50); do
    tr '\0' ' ' < "/proc/$HOLD/cmdline" 2>/dev/null | grep -q "^claude " && break
    sleep 0.1
done
printf '{"pid":%s,"sessionId":"%s","cwd":"/home/myuser/proj-a"}' "$HOLD" "$S1" > "$SRC/sessions/$HOLD.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$HOLD]"; ok "live pid file refused" $?
kill -KILL "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "d['ok'] and not d['sessions'][0]['live']"; ok "stale pid file (dead pid) is not live" $?

# a pid file in a SIBLING profile naming the id, held by a live process with any name
SIB="$TMP/home/.claude-sib"
mkdir -p "$SIB/sessions"
sleeper -
printf '{"pid":%s,"sessionId":"%s"}' "$SPID" "$S1" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "live pid file in a sibling profile, non-claude process name -> live" $?
# pid reuse is decided by procStart (start ticks, /proc/<pid>/stat field 22), never by mtime
TK="$(ticks_of "$SPID")"
touch -d '2001-02-03 04:05:06' "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "old pid file mtime (clock step) without procStart stays live" $?
printf '{"pid":%s,"sessionId":"%s","procStart":%s}' "$SPID" "$S1" "$TK" > "$SIB/sessions/$SPID.json"
touch -d '2001-02-03 04:05:06' "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "procStart matches the process start ticks -> live (whatever the mtime)" $?
printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}' "$SPID" "$S1" "$TK" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "procStart given as a string and matching -> live" $?
printf '{"pid":%s,"sessionId":"%s","procStart":%s}' "$SPID" "$S1" "$((TK + 1))" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "d['ok'] and not d['sessions'][0]['live']"; ok "procStart differs from the process start ticks (pid reuse) -> not live" $?
printf '{"pid":%s,"sessionId":"%s","procStart":"not-a-number"}' "$SPID" "$S1" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "unreadable procStart -> live" $?
printf '{"pid":%s,"sessionId":"%s","procStart":%s}' "$SPID" "$S1" "$((TK + 1))" > "$SIB/sessions/$SPID.json"
runx CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" -- plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "ps mode: any alive pid from a pid file is live (procStart not checked)" $?
stop "$SPID"
# a bridge mirror (credoPeerBridge) carries the real pid of a local session: live when alive;
# only credoPeerLan descriptors (our own relay mirrors) are skipped
sleeper -
printf '{"pid":%s,"sessionId":"%s","credoPeerBridge":true}' "$SPID" "$S1" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "credoPeerBridge pid file with a live pid -> live" $?
printf '{"pid":%s,"sessionId":"%s","credoPeerLan":true}' "$SPID" "$S1" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "d['ok'] and not d['sessions'][0]['live']"; ok "credoPeerLan relay mirror is skipped" $?
# a non-positive procStart is not a start time: unknown -> live, never pid reuse
printf '{"pid":%s,"sessionId":"%s","procStart":-1}' "$SPID" "$S1" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "procStart -1 (not positive) -> unknown, live" $?
printf '{"pid":%s,"sessionId":"%s","procStart":0}' "$SPID" "$S1" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "procStart 0 (not positive) -> unknown, live" $?
stop "$SPID"
# a recognised Claude process is never ignored, even with a mismatching procStart
sleeper claude
TK="$(ticks_of "$SPID")"
printf '{"pid":%s,"sessionId":"%s","procStart":%s}' "$SPID" "$S1" "$((TK + 1))" > "$SIB/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "claude process with a mismatching procStart is still live" $?
stop "$SPID"
# a pid file in a profile that is neither a sibling nor given -> unseen; --profile adds it
EXTRA="$TMP/elsewhere/profile-x"
mkdir -p "$EXTRA/sessions"
sleeper -
printf '{"pid":%s,"sessionId":"%s"}' "$SPID" "$S1" > "$EXTRA/sessions/$SPID.json"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "d['ok'] and not d['sessions'][0]['live']"; ok "profile outside the sibling scan is not seen without --profile" $?
run plan --source "$SRC" --target "$DSTA" --profile "$EXTRA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID] and '$EXTRA' in d['sessions'][0]['profiles_checked']"; ok "--profile adds a profile to the liveness scan" $?
run copy --source "$SRC" --target "$DSTA" --profile "$EXTRA" credo-bugs
ok "--profile: live holder refuses copy, nothing copied" "$([ "$RC" = 1 ] && [ -z "$(find "$DSTA/projects" -mindepth 1)" ] && echo 0 || echo 1)"
run plan --source "$SRC" --target "$DSTA" --profile "$TMP/elsewhere/missing" credo-bugs
ok "--profile that does not exist refused" "$([ "$RC" = 1 ] && has "$OUT" "missing" && echo 0 || echo 1)"
stop "$SPID"
stop "$SPID"

# no /proc: ps fallback finds the live --resume process; without ps -> refused
sleeper claude --resume "$S1"
runx CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" -- plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [(l['pid'], l['profile']) for l in d['sessions'][0]['live']]==[($SPID, None)]"; ok "no /proc: ps fallback detects the live session (profile unknown)" $?
stop "$SPID"
# a versioned Claude binary (argv[0] .../claude/versions/<v>), in /proc mode and in ps mode
mkdir -p "$TMP/vbin/claude/versions"
sleeper "$TMP/vbin/claude/versions/2.1.0" --resume "$S1"
run plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "argv[0] under /claude/versions/ recognised (proc mode)" $?
runx CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" -- plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "argv[0] under /claude/versions/ recognised (ps mode)" $?
# ps mode asks for untruncated command lines (-ww)
mkdir -p "$TMP/psbin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > %s\nexec %s "$@"\n' "$TMP/ps.args" "$(command -v ps)" > "$TMP/psbin/ps"
chmod +x "$TMP/psbin/ps"
runx CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" PATH="$TMP/psbin:$PATH" -- plan --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and [l['pid'] for l in d['sessions'][0]['live']]==[$SPID]"; ok "ps wrapper still finds the session" $?
ok "ps mode passes -ww (no truncated command lines)" "$(grep -Eq '(^| )-[a-zA-Z]*ww' "$TMP/ps.args" 2>/dev/null && echo 0 || echo 1)"
stop "$SPID"
mkdir -p "$TMP/emptybin"
runx CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" PATH="$TMP/emptybin" -- plan --source "$SRC" --target "$DSTA" credo-bugs
ok "no /proc and no ps: refused, liveness cannot be determined" "$([ "$RC" = 1 ] && has "$OUT" "liveness cannot be determined" && echo 0 || echo 1)"
runx CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" PATH="$TMP/emptybin" -- copy --source "$SRC" --target "$DSTA" credo-bugs
ok "no /proc and no ps: copy refused, nothing copied" "$([ "$RC" = 1 ] && [ -z "$(find "$DSTA/projects" -mindepth 1)" ] && echo 0 || echo 1)"

# top-level profile entry -> BLOCKED in the plan
run plan --source "$SRC" --target "$DSTA" "$S7" --json
jck "not d['ok'] and $(action_of "$S7-state.json")==['blocked'] and 'top-level' in [i['reason'] for s in d['sessions'] for i in s['items'] if i['rel']=='$S7-state.json'][0]"; ok "top-level entry BLOCKED in the plan" $?

# custom-title.json and transcript title disagree -> caption ambiguous, both shown
run plan --source "$SRC" --target "$DSTA" alpha
ok "title disagreement: caption refused, both titles shown" "$([ "$RC" = 1 ] && has "$OUT" "alpha" && has "$OUT" "beta" && has "$OUT" "$S8" && echo 0 || echo 1)"
run plan --source "$SRC" --target "$DSTA" beta
ok "title disagreement: other caption refused too" "$([ "$RC" = 1 ] && echo 0 || echo 1)"

# a transcript cwd with control characters is never shown or put into the resume command raw
run plan --source "$SRC" --target "$DSTA" "$S9"
ok "control character in the transcript cwd: never printed raw" "$([ "$(printf '%s' "$OUT" | tr -d '\033' | wc -c)" = "$(printf '%s' "$OUT" | wc -c)" ] && echo 0 || echo 1)"
ok "control character in the transcript cwd: warning, placeholder in the resume command" "$(has "$OUT" "WARNING: cwd of $S9" && has "$OUT" "cd <cwd> && CLAUDE_CONFIG_DIR=" && echo 0 || echo 1)"
run plan --source "$SRC" --target "$DSTA" "$S9" --json
jck "d['sessions'][0]['cwd'] is None and any('control' in w for w in d['warnings'])"; ok "control character in the cwd: json cwd empty + warning" $?

# control characters in a custom title and a slug: never printed raw in the text plan
run plan --source "$SRC" --target "$DSTA" "$S10"
ok "control characters in title + slug: no raw escape character printed" "$([ "$(printf '%s' "$OUT" | tr -d '\033' | wc -c)" = "$(printf '%s' "$OUT" | wc -c)" ] && echo 0 || echo 1)"
ok "control characters in title: no injected output line" "$(printf '%s\n' "$OUT" | grep -q '^FAKE' && echo 1 || echo 0)"
ok "control characters in title + slug: escaped in the plan, warning shown" "$(has "$OUT" 'WARNING: ' && has "$OUT" 'control characters' && has "$OUT" '\x1b[31m' && echo 0 || echo 1)"
run plan --source "$SRC" --target "$DSTA" "$S10" --json
jck "d['sessions'][0]['id']=='$S10' and any('title' in w and 'control' in w for w in d['warnings']) and any('slug' in w and 'control' in w for w in d['warnings'])"; ok "json plan: warnings for title and slug" $?

# control characters in profile paths
run plan --source "$SRC" --target "$DSTA
x" credo-bugs
ok "control character in --target refused" "$([ "$RC" = 1 ] && has "$OUT" "control" && echo 0 || echo 1)"

# stale .part from an interrupted copy: BLOCKED, never touched
DSTQ="$TMP/home/.claude-part"
mkdir -p "$DSTQ/projects" "$DSTQ/tasks/$S1"
printf 'x' > "$DSTQ/tasks/$S1/1.json.part"
run plan --source "$SRC" --target "$DSTQ" credo-bugs --json
jck "not d['ok'] and $(action_of "tasks/$S1")==['blocked']"; ok "leftover .part BLOCKED" $?
run copy --source "$SRC" --target "$DSTQ" credo-bugs
ok "leftover .part: copy refused, .part kept, nothing copied" "$([ "$RC" = 1 ] && has "$OUT" "1.json.part" && [ "$(cat "$DSTQ/tasks/$S1/1.json.part")" = x ] && [ -z "$(find "$DSTQ/projects" -mindepth 1)" ] && echo 0 || echo 1)"

# partial earlier copy (some files there, others missing): re-run completes it
DSTP="$TMP/home/.claude-partial"
P0="projects/-home-myuser-proj-a"
mkdir -p "$DSTP/$P0/$S1/subagents"
cp -p "$SRC/$P0/$S1.jsonl" "$DSTP/$P0/$S1.jsonl"
cp -p "$SRC/$P0/$S1/subagents/agent-a1.jsonl" "$DSTP/$P0/$S1/subagents/agent-a1.jsonl"
run plan --source "$SRC" --target "$DSTP" credo-bugs --json
jck "d['ok'] and $(action_of "$P0/$S1.jsonl")==['present'] and $(action_of "$P0/$S1")==['copy']"; ok "partial copy planned: present + copy" $?
run copy --source "$SRC" --target "$DSTP" credo-bugs --json
ok "partial copy re-run completes (got $RC: $OUT)" "$([ "$RC" = 0 ] && cmp -s "$SRC/$P0/$S1/tool-results/r1.txt" "$DSTP/$P0/$S1/tool-results/r1.txt" && echo 0 || echo 1)"
ok "no .part left after copy" "$([ -z "$(find "$DSTP" -name '*.part')" ] && echo 0 || echo 1)"
SRC_BEFORE="$(snapshot "$SRC")"   # the stale pid file stays; it is part of the baseline

# ---------------------------------------------------------------------------
# 2. copy + verify, separate target
# ---------------------------------------------------------------------------
run copy --source "$SRC" --target "$DSTA" credo-bugs --json
ok "copy separate exit 0 (got $RC: $OUT)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
jck "d['verify']['ok']"; ok "copy runs a green verify" $?
P="projects/-home-myuser-proj-a"
same=0
for rel in "$P/$S1.jsonl" "$P/$S1/custom-title.json" "$P/$S1/subagents/agent-a1.jsonl" \
    "$P/$S1/tool-results/r1.txt" "tasks/$S1/1.json" "file-history/$S1/abc@v1" \
    "credo/session-meta/$S1.json" "credo/autonomy/$S1/active" "credo/self-compact-$S1.json" \
    "dogma/session-dirs/$S1" ".caveman-sessions/$S1.mode"; do
    cmp -s "$SRC/$rel" "$DSTA/$rel" || { same=1; echo "  differs: $rel"; }
done
ok "copied files byte-identical" "$same"
ok "empty dir session-env copied" "$([ -d "$DSTA/session-env/$S1" ] && echo 0 || echo 1)"
ok "mtime preserved" "$([ "$(stat -c %Y "$SRC/$P/$S1.jsonl")" = "$(stat -c %Y "$DSTA/$P/$S1.jsonl")" ] && echo 0 || echo 1)"
ok "no misplaced id entries at the target root" "$([ -z "$(find "$DSTA" -maxdepth 1 -name "*$S1*")" ] && [ -z "$(find "$DSTA/credo" "$DSTA/dogma" -maxdepth 1 -name "$S1*")" ] && echo 0 || echo 1)"
ok "short-id dir, shared log, global config not copied" "$([ ! -e "$DSTA/jobs" ] && [ ! -e "$DSTA/credo/peer-lan.log" ] && [ "$(cat "$DSTA/settings.json")" = '{"other":"settings"}' ] && echo 0 || echo 1)"
ok "copy changed nothing in the source" "$([ "$SRC_BEFORE" = "$(snapshot "$SRC")" ] && echo 0 || echo 1)"
ok "verify manifest written" "$([ -f "$DSTA/credo/session-move/$S1.json" ] && echo 0 || echo 1)"

DST_AFTER="$(snapshot "$DSTA/projects")"
run copy --source "$SRC" --target "$DSTA" credo-bugs --json
jck "d['ok'] and all(i['action']=='present' for s in d['sessions'] for i in s['items'])"; ok "idempotent re-copy: all PRESENT" $?
ok "re-copy rewrote nothing" "$([ "$DST_AFTER" = "$(snapshot "$DSTA/projects")" ] && echo 0 || echo 1)"

run verify --source "$SRC" --target "$DSTA" credo-bugs
ok "verify green (text)" "$([ "$RC" = 0 ] && has "$OUT" "OK" && echo 0 || echo 1)"

# verify mismatch + missing
cp -p "$DSTA/tasks/$S1/1.json" "$TMP/keep-1.json"
printf 'changed' >> "$DSTA/tasks/$S1/1.json"
mv "$DSTA/credo/session-modes/$S1" "$TMP/keep-mode"
run verify --source "$SRC" --target "$DSTA" credo-bugs --json
jck "not d['ok'] and any('tasks/' in m for m in d['mismatches']) and any('session-modes' in m for m in d['mismatches'])"; ok "verify mismatch + missing -> exit 1" $?
ok "verify mismatch exit code 1" "$([ "$RC" = 1 ] && echo 0 || echo 1)"
cp -p "$TMP/keep-1.json" "$DSTA/tasks/$S1/1.json"
mv "$TMP/keep-mode" "$DSTA/credo/session-modes/$S1"
run verify --source "$SRC" --target "$DSTA" credo-bugs --json
jck "d['ok']"; ok "verify green again after restore" $?
ok "no .part left in the target" "$([ -z "$(find "$DSTA" -name '*.part')" ] && echo 0 || echo 1)"

# the manifest records source AND target size + sha256 per file
MAN="$DSTA/credo/session-move/$S1.json"
OUT="$(cat "$MAN")"
jck "d['version']==2 and all(set(f)>={'path','size','sha256','dst_size','dst_sha256'} for f in d['files']) and any(f['path'].endswith('$S1.jsonl') for f in d['files'])"; ok "manifest has source + target size and sha256" $?

# verify writes no manifest for a refused session (live / current) and exits 1
mv "$MAN" "$TMP/keep-manifest"
sleeper claude --resume "$S1"
run verify --source "$SRC" --target "$DSTA" credo-bugs --json
ok "verify of a live session: exit 1, no manifest" "$([ "$RC" = 1 ] && [ ! -e "$MAN" ] && echo 0 || echo 1)"
stop "$SPID"
OUT="$(env CLAUDE_CODE_SESSION_ID="$S1" "$PY" "$HELPER" verify --source "$SRC" --target "$DSTA" credo-bugs 2>&1)"; RC=$?
ok "verify of the current session: exit 1, no manifest" "$([ "$RC" = 1 ] && [ ! -e "$MAN" ] && echo 0 || echo 1)"
mv "$TMP/keep-manifest" "$MAN"

# ---------------------------------------------------------------------------
# 3. conflict detection
# ---------------------------------------------------------------------------
DSTC="$TMP/home/.claude-conflict"
mkdir -p "$DSTC/credo/session-meta" "$DSTC/projects"
printf '{"different":1}' > "$DSTC/credo/session-meta/$S1.json"
run plan --source "$SRC" --target "$DSTC" credo-bugs --json
jck "not d['ok'] and $(action_of "credo/session-meta/$S1.json")==['conflict']"; ok "conflict detected" $?
run copy --source "$SRC" --target "$DSTC" credo-bugs
ok "conflict blocks copy, nothing copied" "$([ "$RC" = 1 ] && [ -z "$(find "$DSTC/projects" -mindepth 1)" ] && [ "$(cat "$DSTC/credo/session-meta/$S1.json")" = '{"different":1}' ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# 4. symlink-shared target
# ---------------------------------------------------------------------------
run plan --source "$SRC" --target "$DSTB" credo-bugs --json
ok "plan shared exit 0 (got $RC: $OUT)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
jck "$(action_of "credo/session-meta/$S1.json")==['shared'] and $(action_of "credo/autonomy/$S1")==['shared']"; ok "credo items SHARED" $?
jck "$(action_of "projects/-home-myuser-proj-a/$S1.jsonl")==['copy'] and $(action_of "dogma/session-dirs/$S1")==['copy']"; ok "real target dirs get COPY" $?
jck "sorted(d['target_layout']['symlinks'])==['credo','plugins','settings.json'] and 'dogma' in d['target_layout']['real']"; ok "shared layout detected" $?
run copy --source "$SRC" --target "$DSTB" credo-bugs --json
ok "copy shared exit 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
ok "shared: projects + dogma copied" "$(cmp -s "$SRC/$P/$S1.jsonl" "$DSTB/$P/$S1.jsonl" && [ -f "$DSTB/dogma/session-dirs/$S1" ] && echo 0 || echo 1)"
# the verify manifest lands in the shared credo/ dir (and touches its mtime); nothing else
nomani() { grep -v -e '/session-move' -e '^\./credo d '; }
ok "shared: still symlinks, source tree unchanged apart from the manifest" "$([ -L "$DSTB/credo" ] && [ "$(printf '%s\n' "$SRC_BEFORE" | nomani)" = "$(snapshot "$SRC" | nomani)" ] && echo 0 || echo 1)"

DSTD="$TMP/home/.claude-third"
mkdir -p "$DSTD/projects" "$TMP/third/tasks"
ln -s "$TMP/third/tasks" "$DSTD/tasks"
run plan --source "$SRC" --target "$DSTD" credo-bugs --json
jck "not d['ok'] and $(action_of "tasks/$S1")==['blocked']"; ok "symlink to a third location BLOCKED" $?

# ---------------------------------------------------------------------------
# 5. cleanup-script
# ---------------------------------------------------------------------------
run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs
ok "cleanup-script needs --user-confirmed" "$([ "$RC" != 0 ] && [ ! -e "$TMP/cleanup-base" ] && echo 0 || echo 1)"
run cleanup-script --source "$SRC" --target "$DSTC" credo-bugs --user-confirmed
ok "cleanup-script needs a verify manifest" "$([ "$RC" = 1 ] && echo 0 || echo 1)"

# simulate the resume in the target: transcript grows, new subagent file, rewritten state
printf '{"type":"user","cwd":"/home/myuser/proj-a","sessionId":"%s"}\n' "$S1" >> "$DSTA/$P/$S1.jsonl"
printf 'new\n' > "$DSTA/$P/$S1/subagents/agent-new.jsonl"
printf 'active' > "$DSTA/credo/session-modes/$S1"
# a nested target file went missing, another one changed with the same size
mv "$DSTA/$P/$S1/tool-results/r1.txt" "$TMP/keep-r1"
printf '[{"id":2}]' > "$DSTA/tasks/$S1/1.json"
mkdir -p "$TMP/cleanup-base"

# the sha256 tool: shasum fallback, none -> refused
mkdir -p "$TMP/shabin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/shabin/shasum"
chmod +x "$TMP/shabin/shasum"
runx PATH="$TMP/emptybin" -- cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
ok "no sha256sum / shasum: generation refused" "$([ "$RC" = 1 ] && has "$OUT" "sha256sum" && echo 0 || echo 1)"
runx PATH="$TMP/shabin" -- cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed --json
CSX="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["script"])' 2>/dev/null)"
ok "shasum fallback used in the script (got $RC)" "$([ "$RC" = 0 ] && grep -q 'shasum -a 256' "$CSX" 2>/dev/null && echo 0 || echo 1)"
runx CREDO_SESSION_MOVE_TMPDIR="$TMP/cleanup-base
x" -- cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
ok "control character in CREDO_SESSION_MOVE_TMPDIR refused" "$([ "$RC" = 1 ] && has "$OUT" "control" && echo 0 || echo 1)"

# a holder in a sibling profile (not the target) blocks the cleanup
sleeper -
printf '{"pid":%s,"sessionId":"%s"}' "$SPID" "$S1" > "$SIB/sessions/$SPID.json"
run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
ok "cleanup refused while a sibling profile holds the session" "$([ "$RC" = 1 ] && has "$OUT" "live" && echo 0 || echo 1)"
stop "$SPID"
sleeper -
printf '{"pid":%s,"sessionId":"%s"}' "$SPID" "$S1" > "$EXTRA/sessions/$SPID.json"
run cleanup-script --source "$SRC" --target "$DSTA" --profile "$EXTRA" credo-bugs --user-confirmed
ok "cleanup refused while a --profile profile holds the session" "$([ "$RC" = 1 ] && has "$OUT" "live" && echo 0 || echo 1)"
stop "$SPID"

# a tampered manifest: an item that is not part of this session's plan
cp -p "$MAN" "$TMP/keep-manifest"
"$PY" - "$MAN" "projects/-home-myuser-proj-b/$S2.jsonl" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["items"].append(sys.argv[2])
json.dump(d, open(sys.argv[1], "w"))
PYEOF
run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
ok "manifest item outside the fresh plan refused" "$([ "$RC" = 1 ] && has "$OUT" "$S2" && echo 0 || echo 1)"
cp -p "$TMP/keep-manifest" "$MAN"
# a manifest whose target size / hash differs from the source size / hash is not a green verify
for field in dst_size dst_sha256; do
    "$PY" - "$MAN" "$field" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
f = d["files"][0]
f[sys.argv[2]] = f[sys.argv[2]] + 1 if sys.argv[2] == "dst_size" else "0" * 64
json.dump(d, open(sys.argv[1], "w"))
PYEOF
    run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
    ok "manifest with $field != source value refused" "$([ "$RC" = 1 ] && has "$OUT" "malformed" && echo 0 || echo 1)"
    cp -p "$TMP/keep-manifest" "$MAN"
done

# non-transcript file: a target copy that only GREW (verified bytes still a prefix) is not
# intact - exact size + sha256 equality is required, only the transcript may grow
TS="$DSTA/credo/self-compact-$S1.json"
cp -p "$TS" "$TMP/keep-ts"
printf 'grown' >> "$TS"
run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed --json
jck "any('self-compact' in k['path'] for k in d['kept']) and not any(k['path'].endswith('$S1.jsonl') for k in d['kept'])"
ok "non-transcript target grown (prefix intact) -> source kept at generation, grown transcript still listed (rc $RC)" $?
cp -p "$TMP/keep-ts" "$TS"

run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed --json
ok "cleanup-script after resume exit 0 (got $RC: $OUT)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
jck "any('session-modes' in k['path'] for k in d['kept']) and any('r1.txt' in k['path'] for k in d['kept']) and any('tasks/' in k['path'] for k in d['kept'])"
ok "target counterpart shrunk / missing / changed -> source file kept (reported)" $?
ok "remove hint uses rm -f + rmdir, no recursive rm" "$(has "$OUT" "rm -f -- '" && has "$OUT" "/cleanup.sh' && rmdir -- '" && ! has "$OUT" "rm -r" && echo 0 || echo 1)"
CS="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["script"])' 2>/dev/null)"
ok "script under the temp base" "$(case "$CS" in "$TMP/cleanup-base/"*) echo 0 ;; *) echo 1 ;; esac)"
ok "script dir 0700, file 0600" "$([ "$(stat -c %a "$(dirname "$CS")")" = 700 ] && [ "$(stat -c %a "$CS")" = 600 ] && echo 0 || echo 1)"
BODY="$(cat "$CS" 2>/dev/null)"
# the only expansions allowed are the script's own removed / kept counters
NOVARS="$(printf '%s' "$BODY" | sed -e 's/\$((csm_removed + 1))//g' -e 's/\$((csm_kept + 1))//g' -e 's/\$csm_removed//g' -e 's/\$csm_kept//g')"
ok "script has no shell variables besides its own counters" "$(has "$NOVARS" '$' && echo 1 || echo 0)"
ok "script has no recursive rm" "$(printf '%s\n' "$BODY" | grep -Eq 'rm +-[a-zA-Z]*[rR]' && echo 1 || echo 0)"
ok "script syntax ok" "$(bash -n "$CS" 2>/dev/null && echo 0 || echo 1)"
bad=0
while IFS= read -r p; do
    case "$p" in "$SRC"/*) ;; *) bad=1; echo "  outside source: $p" ;; esac
done < <(printf '%s\n' "$BODY" | grep -oE "(rm -f|rmdir) -- '/[^']*'" | grep -oE "'/[^']*'" | tr -d "'")
ok "every deletion target in the script is inside the source profile" "$bad"
ok "script has deletion targets at all" "$(printf '%s\n' "$BODY" | grep -qE "rm -f -- '/" && echo 0 || echo 1)"
ok "script lists transcript + state, not the short-id dir" "$(has "$BODY" "$SRC/$P/$S1.jsonl" && has "$BODY" "$SRC/credo/session-meta/$S1.json" && ! has "$BODY" "jobs/" && echo 0 || echo 1)"
ok "report tells how to remove the script" "$(has "$OUT" "$(dirname "$CS")" && echo 0 || echo 1)"
ok "kept files are not in the script" "$(has "$BODY" "session-modes/$S1" || has "$BODY" "r1.txt" || has "$BODY" "tasks/$S1/1.json" && echo 1 || echo 0)"
ok "script checks the parent directory at run time (pwd -P)" "$(has "$BODY" "pwd -P" && echo 0 || echo 1)"
ok "script checks the target counterpart at run time" "$(has "$BODY" "[ -f '$DSTA/$P/$S1.jsonl' ]" && echo 0 || echo 1)"
mv "$TMP/keep-r1" "$DSTA/$P/$S1/tool-results/r1.txt"
cp -p "$TMP/keep-1.json" "$DSTA/tasks/$S1/1.json"

# dry run of the script with logging rm / rmdir; one source file changed after generation
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nprintf "rm %%s\\n" "$*" >> %s\n' "$TMP/rm.log" > "$TMP/fakebin/rm"
printf '#!/bin/sh\nprintf "rmdir %%s\\n" "$*" >> %s\n' "$TMP/rm.log" > "$TMP/fakebin/rmdir"
chmod +x "$TMP/fakebin/rm" "$TMP/fakebin/rmdir"
printf 'changed after verify' > "$SRC/file-history/$S1/abc@v1"
: > "$TMP/rm.log"
PATH="$TMP/fakebin:$PATH" sh "$CS" > "$TMP/cs.out" 2> "$TMP/cs.err"
CSRC=$?
LOG="$(cat "$TMP/rm.log")"
ok "script exits 1 and prints removed + kept counts when something was kept (rc $CSRC)" "$([ "$CSRC" = 1 ] && grep -Eq 'removed [1-9][0-9]*, kept [1-9][0-9]*' "$TMP/cs.out" && echo 0 || echo 1)"
ok "dry run removes the transcript" "$(has "$LOG" "rm -f -- $SRC/$P/$S1.jsonl" && echo 0 || echo 1)"
ok "dry run keeps the file changed after verify" "$(has "$LOG" "abc@v1" && echo 1 || echo 0)"
ok "dry run reports the kept file" "$(has "$(cat "$TMP/cs.err")" "abc@v1" && echo 0 || echo 1)"
ok "dry run rmdirs only inside the source" "$(printf '%s\n' "$LOG" | grep '^rmdir' | grep -v -- "-- $SRC/" | grep -q . && echo 1 || echo 0)"
printf 'v1' > "$SRC/file-history/$S1/abc@v1"
touch -d '2001-02-03 04:05:06' "$SRC/file-history/$S1/abc@v1"

# run time: the target counterpart is no longer what was verified -> the source file is kept
TP="$DSTA/credo/session-meta/$S1.json"      # different content
TQ="$DSTA/dogma/session-dirs/$S1"           # truncated
TH="$DSTA/.caveman-sessions/$S1.mode"       # hard link to the source file itself
TD="$DSTA/credo/autonomy/$S1"               # directory swapped for a symlink
mv "$TP" "$TMP/keep-tp"; printf '{"sid":"changed"}' > "$TP"
mv "$TQ" "$TMP/keep-tq"; : > "$TQ"
mv "$TH" "$TMP/keep-th"; ln "$SRC/.caveman-sessions/$S1.mode" "$TH"
mv "$TD" "$TMP/keep-td"; ln -s "$TMP/keep-td" "$TD"
cp -p "$TS" "$TMP/keep-ts"; printf 'grown' >> "$TS"     # non-transcript grown, prefix intact
: > "$TMP/rm.log"
PATH="$TMP/fakebin:$PATH" sh "$CS" > "$TMP/cs.out" 2> "$TMP/cs.err"
LOG="$(cat "$TMP/rm.log")"
ok "run time: target with different content -> source kept" "$(has "$LOG" "$SRC/credo/session-meta/$S1.json" && echo 1 || echo 0)"
ok "run time: truncated target -> source kept" "$(has "$LOG" "$SRC/dogma/session-dirs/$S1" && echo 1 || echo 0)"
ok "run time: target that is the source file itself (hard link) -> source kept" "$(has "$LOG" "$SRC/.caveman-sessions/$S1.mode" && echo 1 || echo 0)"
ok "run time: target dir swapped for a symlink -> source kept" "$(has "$LOG" "$SRC/credo/autonomy/$S1/active" && echo 1 || echo 0)"
ok "run time: non-transcript target grown with the verified bytes as prefix -> source kept" "$(has "$LOG" "$SRC/credo/self-compact-$S1.json" && echo 1 || echo 0)"
ok "run time: intact target (grown transcript) -> still removed" "$(has "$LOG" "rm -f -- $SRC/$P/$S1.jsonl" && echo 0 || echo 1)"
mv "$TMP/keep-tp" "$TP"; mv "$TMP/keep-tq" "$TQ"; mv "$TMP/keep-th" "$TH"
unlink "$TD"; mv "$TMP/keep-td" "$TD"; cp -p "$TMP/keep-ts" "$TS"
: > "$TMP/rm.log"
PATH="$TMP/fakebin:$PATH" sh "$CS" > "$TMP/cs.out" 2> "$TMP/cs.err"
LOG="$(cat "$TMP/rm.log")"
ok "run time: restored targets -> all four removed again (control)" "$(has "$LOG" "rm -f -- $SRC/credo/session-meta/$S1.json" && has "$LOG" "rm -f -- $SRC/dogma/session-dirs/$S1" && has "$LOG" "rm -f -- $SRC/.caveman-sessions/$S1.mode" && has "$LOG" "rm -f -- $SRC/credo/autonomy/$S1/active" && echo 0 || echo 1)"
ok "run time: untouched self-compact state removed again (control)" "$(has "$LOG" "rm -f -- $SRC/credo/self-compact-$S1.json" && echo 0 || echo 1)"
ok "script checks size, prefix hash, same-file and the target directory" "$(has "$BODY" "head -c" && has "$BODY" "-ef" && has "$BODY" "'$DSTA/credo/session-meta'" && echo 0 || echo 1)"
ok "script: non-transcript gets an exact size + full sha256 check, transcript only the prefix" "$(printf '%s\n' "$BODY" | grep "self-compact" | grep -q 'wc -c <' && ! printf '%s\n' "$BODY" | grep "self-compact" | grep -q 'head -c' && printf '%s\n' "$BODY" | grep "$S1.jsonl" | grep -q 'head -c' && ! printf '%s\n' "$BODY" | grep "$S1.jsonl'" | grep -q 'wc -c <' && echo 0 || echo 1)"

# run time: a parent directory swapped for a symlink after generation -> file kept
mv "$SRC/credo/session-meta" "$TMP/moved-meta"
ln -s "$TMP/moved-meta" "$SRC/credo/session-meta"
: > "$TMP/rm.log"
PATH="$TMP/fakebin:$PATH" sh "$CS" > "$TMP/cs.out" 2> "$TMP/cs.err"
ok "dry run keeps a file whose parent became a symlink" "$(has "$(cat "$TMP/rm.log")" "session-meta" && echo 1 || echo 0)"
ok "dry run still removes the transcript then" "$(has "$(cat "$TMP/rm.log")" "rm -f -- $SRC/$P/$S1.jsonl" && echo 0 || echo 1)"
mv "$SRC/credo/session-meta" "$TMP/meta-link"
mv "$TMP/moved-meta" "$SRC/credo/session-meta"

# a source file changed after the verify: generation refused
printf 'grew' >> "$SRC/tasks/$S1/1.json"
run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
ok "source changed after verify -> refused" "$([ "$RC" = 1 ] && has "$OUT" "tasks/$S1" && echo 0 || echo 1)"
printf '[{"id":1}]' > "$SRC/tasks/$S1/1.json"

# shared target: shared items never in the cleanup
run verify --source "$SRC" --target "$DSTB" credo-bugs
run cleanup-script --source "$SRC" --target "$DSTB" credo-bugs --user-confirmed --json
CSB="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["script"])' 2>/dev/null)"
BODYB="$(cat "$CSB" 2>/dev/null)"
ok "shared cleanup generated (got $RC)" "$([ "$RC" = 0 ] && [ -n "$BODYB" ] && echo 0 || echo 1)"
ok "shared items not in the cleanup" "$(has "$BODYB" "/credo/" && echo 1 || echo 0)"
ok "shared cleanup still removes the copied transcript" "$(has "$BODYB" "$SRC/$P/$S1.jsonl" && echo 0 || echo 1)"

: > "$TMP/rm.log"
PATH="$TMP/fakebin:$PATH" sh "$CSB" > "$TMP/csb.out" 2> "$TMP/csb.err"
CSBRC=$?
ok "clean script run: exit 0 and 'removed N, kept 0' (rc $CSBRC: $(cat "$TMP/csb.out" "$TMP/csb.err"))" "$([ "$CSBRC" = 0 ] && grep -Eq 'removed [1-9][0-9]*, kept 0' "$TMP/csb.out" && echo 0 || echo 1)"

# live in the source at cleanup time: refused
( export CLAUDE_CONFIG_DIR="$SRC"; exec -a claude "$PY" -c 'import time; time.sleep(600)' --resume "$S1" ) &
LIVE2=$!; PIDS="$PIDS $LIVE2"
for _ in $(seq 1 50); do
    tr '\0' ' ' < "/proc/$LIVE2/cmdline" 2>/dev/null | grep -q "^claude .*$S1" && break
    sleep 0.1
done
run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
ok "cleanup refused while live in the source" "$([ "$RC" = 1 ] && has "$OUT" "live" && echo 0 || echo 1)"
kill -KILL "$LIVE2" 2>/dev/null; wait "$LIVE2" 2>/dev/null
# live in the TARGET (the resumed session) does not block the cleanup
( export CLAUDE_CONFIG_DIR="$DSTA"; exec -a claude "$PY" -c 'import time; time.sleep(600)' --resume "$S1" ) &
LIVE3=$!; PIDS="$PIDS $LIVE3"
for _ in $(seq 1 50); do
    tr '\0' ' ' < "/proc/$LIVE3/cmdline" 2>/dev/null | grep -q "^claude .*$S1" && break
    sleep 0.1
done
run cleanup-script --source "$SRC" --target "$DSTA" credo-bugs --user-confirmed
ok "resumed session live in the target does not block the cleanup (got $RC: $OUT)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
kill -KILL "$LIVE3" 2>/dev/null; wait "$LIVE3" 2>/dev/null

# generator guard: paths outside the source profile / through a symlink refused
UOUT="$("$PY" - "$HELPER" "$SRC" "$TMP" <<'PYEOF' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("csm", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
src, tmp = sys.argv[2], sys.argv[3]
fails = []
def refused(path):
    try:
        m.check_deletable(src, path, "11111111-2222-4333-8444-555555555555")
    except ValueError:
        return True
    return False
if not refused(os.path.join(tmp, "outside", "file")):
    fails.append("outside path accepted")
if not refused(os.path.join(src, "..", "outside-x")):
    fails.append(".. path accepted")
if not refused(os.path.join(src, "todos", "55555555-5555-4555-8555-555555555555-agent.json")):
    fails.append("symlink accepted")
if not refused(src) or not refused(os.path.join(src, "credo")):
    fails.append("profile root / top-level entry accepted")
if not refused(os.path.join(src, "tasks", "x'\ny")):
    fails.append("newline path accepted")
if not refused(os.path.join(src, "tasks", "33333333-3333-4333-8333-333333333333", "1.json")):
    fails.append("path of another session id accepted")
try:
    m.check_deletable(src, os.path.join(src, "tasks", "11111111-2222-4333-8444-555555555555", "1.json"),
                      "11111111-2222-4333-8444-555555555555")
except ValueError as e:
    fails.append("valid path refused: %s" % e)
print("UNIT_FAIL " + " | ".join(fails) if fails else "UNIT_OK")
PYEOF
)"
ok "generator refuses outside / symlink / top-level paths ($UOUT)" "$(has "$UOUT" UNIT_OK && echo 0 || echo 1)"

# the script file is written under a temp name and renamed; a failure removes only that temp file
WOUT="$("$PY" - "$HELPER" "$TMP/cleanup-base" <<'PYEOF' 2>&1
import importlib.util, os, stat, sys, tempfile
spec = importlib.util.spec_from_file_location("csm", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
base = sys.argv[2]
fails = []
d = tempfile.mkdtemp(prefix="csm-unit-", dir=base)
path = m.write_script(os.path.join(d, "cleanup.sh"), "#!/bin/sh\necho hi\n")
if sorted(os.listdir(d)) != ["cleanup.sh"]:
    fails.append("unexpected files after a good write: %r" % os.listdir(d))
if stat.S_IMODE(os.stat(path).st_mode) != 0o600:
    fails.append("mode not 0600")
d2 = tempfile.mkdtemp(prefix="csm-unit-", dir=base)
with open(os.path.join(d2, "other-file"), "w") as fh:
    fh.write("keep")
real_rename = os.rename
def boom(a, b):
    raise OSError("simulated rename failure")
m.os.rename = boom
try:
    m.write_script(os.path.join(d2, "cleanup.sh"), "x")
    fails.append("failure not reported")
except m.Fail as e:
    if d2 not in str(e):
        fails.append("dir not named in the message: %s" % e)
finally:
    m.os.rename = real_rename
left = sorted(os.listdir(d2))
if left != ["other-file"]:
    fails.append("own temp file not removed or foreign file touched: %r" % left)
print("UNIT_FAIL " + " | ".join(fails) if fails else "UNIT_OK")
PYEOF
)"
ok "script written via temp name + rename; failure removes only its own temp file ($WOUT)" "$(has "$WOUT" UNIT_OK && echo 0 || echo 1)"

# unencodable script text (a lone surrogate): reported as Fail with the dir named, own temp
# file removed, no script produced
EOUT="$("$PY" - "$HELPER" "$TMP/cleanup-base" <<'PYEOF' 2>&1
import importlib.util, os, sys, tempfile
spec = importlib.util.spec_from_file_location("csm", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
base = sys.argv[2]
fails = []
d = tempfile.mkdtemp(prefix="csm-unit-", dir=base)
with open(os.path.join(d, "other-file"), "w") as fh:
    fh.write("keep")
try:
    m.write_script(os.path.join(d, "cleanup.sh"), "echo \udcff\n")
    fails.append("encoding failure not reported")
except m.Fail as e:
    if d not in str(e):
        fails.append("dir not named in the message: %s" % e)
except Exception as e:
    fails.append("unexpected %s: %s" % (type(e).__name__, e))
left = sorted(os.listdir(d))
if left != ["other-file"]:
    fails.append("own temp file not removed or foreign file touched: %r" % left)
print("UNIT_FAIL " + " | ".join(fails) if fails else "UNIT_OK")
PYEOF
)"
ok "unencodable cleanup text: Fail, dir named, own temp file removed ($EOUT)" "$(has "$EOUT" UNIT_OK && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# 6. focused fixtures: one session in its own source and target profile
# ---------------------------------------------------------------------------
mk_mini() { # root -> SRC_M (source profile with one transcript), DST_M (empty target)
    SRC_M="$1/.claude-src"
    DST_M="$1/.claude-dst"
    mkdir -p "$SRC_M/projects/-home-myuser-proj-m" "$DST_M/projects"
    transcript "$SRC_M/projects/-home-myuser-proj-m/$S1.jsonl" "$S1" /home/myuser/proj-m mini-check
    find "$SRC_M" -exec touch -h -d '2001-02-03 04:05:06' {} +
}

# CREDO_SESSION_MOVE_PROC_ROOT is a test seam: ignored unless CREDO_SESSION_MOVE_TEST=1
mk_mini "$TMP/mini-proc"
OUT="$(env -u CLAUDE_CODE_SESSION_ID -u CREDO_SESSION_MOVE_TEST CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" \
    PATH="$TMP/emptybin" CREDO_SESSION_MOVE_TMPDIR="$TMP/cleanup-base" \
    "$PY" "$HELPER" plan --source "$SRC_M" --target "$DST_M" "$S1" --json 2>&1)"; RC=$?
ok "PROC_ROOT without CREDO_SESSION_MOVE_TEST=1 is ignored (real /proc used, plan ok)" "$([ "$RC" = 0 ] && ! has "$OUT" "liveness cannot" && echo 0 || echo 1)"
runx CREDO_SESSION_MOVE_TEST=1 CREDO_SESSION_MOVE_PROC_ROOT="$TMP/noproc" PATH="$TMP/emptybin" -- plan --source "$SRC_M" --target "$DST_M" "$S1"
ok "PROC_ROOT with CREDO_SESSION_MOVE_TEST=1 is honoured (no /proc, no ps: refused)" "$([ "$RC" = 1 ] && has "$OUT" "liveness cannot be determined" && echo 0 || echo 1)"

# unreadable / invalid pid files: listed in a WARNING line, never refusing the plan
mkdir -p "$SRC_M/sessions"
printf '{not json' > "$SRC_M/sessions/junk.json"
printf '[1, 2]' > "$SRC_M/sessions/list.json"
printf '{"sessionId":"%s"}' "$S2" > "$SRC_M/sessions/nopid.json"
run plan --source "$SRC_M" --target "$DST_M" "$S1"
ok "invalid pid files: plan still exit 0 (got $RC: $OUT)" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
ok "invalid pid files: WARNING line names each of them" "$(has "$OUT" "WARNING: " && has "$OUT" "junk.json" && has "$OUT" "list.json" && has "$OUT" "nopid.json" && echo 0 || echo 1)"
run plan --source "$SRC_M" --target "$DST_M" "$S1" --json
jck "d['ok'] and sum(1 for w in d['warnings'] if 'pid file' in w)==3"; ok "invalid pid files: one warning per file, not repeated per session" $?

# a file that names a second full session id is BLOCKED, never copied
OTHER="cafecafe-0000-4000-8000-000000000001"
mk_mini "$TMP/mini-scan"
mkdir -p "$SRC_M/tasks"
printf '[]' > "$SRC_M/tasks/$S1-and-$OTHER.json"
printf '[]' > "$SRC_M/tasks/$S1.json"
run plan --source "$SRC_M" --target "$DST_M" "$S1" --json
jck "not d['ok'] and $(action_of "tasks/$S1-and-$OTHER.json")==['blocked'] and any('names another session too' in i['reason'] for s in d['sessions'] for i in s['items'] if i['rel']=='tasks/$S1-and-$OTHER.json')"
ok "file naming a second full session id is BLOCKED (names another session too)" $?
jck "$(action_of "tasks/$S1.json")==['copy']"; ok "the file with only this session id stays COPY" $?
run copy --source "$SRC_M" --target "$DST_M" "$S1"
ok "copy refused while a file names another session; nothing copied" "$([ "$RC" = 1 ] && [ ! -e "$DST_M/tasks" ] && echo 0 || echo 1)"

# the verify manifest temp file is created exclusively: a stale one is refused, never truncated
mk_mini "$TMP/mini-manifest"
run copy --source "$SRC_M" --target "$DST_M" "$S1"
ok "mini: copy + verify writes the manifest (got $RC: $OUT)" "$([ "$RC" = 0 ] && [ -f "$DST_M/credo/session-move/$S1.json" ] && echo 0 || echo 1)"
printf 'stale' > "$DST_M/credo/session-move/$S1.json.tmp"
run verify --source "$SRC_M" --target "$DST_M" "$S1"
ok "stale <id>.json.tmp: verify refused with the file named (got $RC: $OUT)" "$([ "$RC" = 1 ] && has "$OUT" "$S1.json.tmp" && echo 0 || echo 1)"
ok "stale <id>.json.tmp is not truncated" "$([ "$(cat "$DST_M/credo/session-move/$S1.json.tmp")" = stale ] && echo 0 || echo 1)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

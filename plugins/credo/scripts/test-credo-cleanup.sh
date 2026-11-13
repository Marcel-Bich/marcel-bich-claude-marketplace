#!/bin/bash
# Tests for the provenance ledger (credo-ledger.py) and the cleanup helper (credo-cleanup.py), #174.
#
# Isolation: the runtime code reads no paths or switches of the cleanup from the environment, so
# this suite injects its fixture paths through a shim it generates in its own mktemp dir (it sets
# credo_cleanup_lib.OVERRIDES before running a script). Every path the tests touch lives in that
# dir; nothing real is read for deletion or deleted.
#
# Covered: what may be deleted without a prompt (session TMPDIR, session scratchpad, ignored build
# output of the own linked worktree, Write-created temp entries confirmed by the session
# transcript) and what is report-only (everything the birth-time scan of a Bash call found, home
# and worktrees-dir entries, forged ledger lines, kept results); env overrides are ignored;
# session ids are UUIDs only; pre-existing / moved-in / extracted content, inode change and reuse,
# symlinks and swapped paths, ~/.claude*, keep_paths, mounts (also bind mounts, FUSE in the home
# scan), sockets, live processes and fresh changes are refused; the ledger guard; keep step;
# purge; item-close (report only, time budget); sweep of dead sessions; worktree .credo guard and
# rescue; unmerged worktrees never removed; Playwright prune (Node, pnpm, Python driver, Java jar,
# in-use revisions, unclear search = nothing pruned).
# Usage: bash test-credo-cleanup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="$SCRIPT_DIR/credo-ledger.py"
HELPER="$SCRIPT_DIR/credo-cleanup.py"
WTC="$SCRIPT_DIR/credo-worktree-cleanup.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-cleanup-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}
exists() { [ -e "$1" ] || [ -L "$1" ] && echo yes || echo no; }

if [ "$(stat -c %W "$TMP" 2>/dev/null || echo 0)" = "0" ]; then
    echo "SKIP: no file birth time on this file system (statx btime) - the ledger scan needs it"
    exit 0
fi

SA="aaaaaaaa-0000-4000-8000-000000000001"     # this session
SB="bbbbbbbb-0000-4000-8000-000000000002"     # another session
FH="$TMP/home"                                 # fixture home
R="$TMP/roots/t"                               # fixture temp scan root
CTMP="$TMP/ctmp"                               # session tmp base
ST="$CTMP/$SA"                                 # this session's TMPDIR
PAD="$TMP/scratch/-fix/$SA/scratchpad"         # this session's scratchpad
PROF="$FH/.claude-x"
TX="$PROF/projects/-fix/$SA.jsonl"             # this session's transcript
mkdir -p "$PROF/projects/-fix" "$R" "$TMP/cfg" "$TMP/dsession" "$PAD" "$PROF/sessions"
: > "$TX"

export CREDO_GLOBAL="$TMP/cfg/config" CREDO_PROFILE="" CREDO_CONFIG_STDLIB_YAML=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export DOGMA_CREDO_CONFIG=none DOGMA_SESSION_DIR="$TMP/dsession"
unset CREDO_SESSION_ID CREDO_LEDGER PLAYWRIGHT_BROWSERS_PATH CLAUDE_ENV_FILE CREDO_DIR CREDO_PROJECT CLAUDE_CONFIG_DIR
export CLAUDE_CODE_SESSION_ID="$SA"
printf 'cleanup:\n  keep_paths:\n    - %s\n' "$ST/keepme" > "$CREDO_GLOBAL"

# --- test-only shim: fixture paths go into credo_cleanup_lib.OVERRIDES, never the environment
SHIM="$TMP/shim.py"
cat > "$SHIM" <<'EOF'
import json, os, runpy, sys
cfg = json.load(open(sys.argv[1]))
cfg.update(json.loads(os.environ.get("CREDO_TEST_OV_EXTRA") or "{}"))
script = sys.argv[2]
sys.path.insert(0, os.path.dirname(script))
import credo_cleanup_lib as L
L.OVERRIDES.update(cfg)
sys.argv = [script] + sys.argv[3:]
runpy.run_path(script, run_name="__main__")
EOF
OVJ="$TMP/ov.json"
python3 - "$OVJ" <<EOF
import json, sys
json.dump({"home": "$FH", "state": "$TMP/state", "keep_root": "$TMP/keep", "tmp_base": "$CTMP",
           "scratch_base": "$TMP/scratch", "profiles": ["$PROF"], "roots": ["$R"],
           "home_root": "$FH", "sync": True, "no_maintenance": True,
           "explicit_idle_s": 0, "idle_minutes": 0, "mountinfo": "$TMP/no-mountinfo"},
          open(sys.argv[1], "w"))
EOF
: > "$TMP/no-mountinfo"
helper() { python3 -I "$SHIM" "$OVJ" "$HELPER" "$@"; }
LEDGER_FILE="$TMP/state/ledger/$SA.jsonl"

# pre-existing user data (born before every session entry)
mkdir -p "$FH/userdata" "$FH/proj/config" "$FH/Documents/thesis"
echo precious > "$FH/userdata/thesis.txt"; echo secret-cfg > "$FH/proj/config/app.yml"
echo ch1 > "$FH/Documents/thesis/ch1.txt"
sleep 2.5

N=0
hook() { # mode tool json-tool-input [session] [cwd]
    printf '{"session_id":"%s","tool_name":"%s","tool_use_id":"tu%s","cwd":"%s","tool_input":%s}' \
        "${4:-$SA}" "$2" "$N" "${5:-$R}" "$3" | python3 -I "$SHIM" "$OVJ" "$LEDGER" "$1"
}
cmdjson() { python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
run_call() { # <bash command between pre and post> [session] [cwd]
    N=$((N + 1))
    local cj
    cj="$(cmdjson "$1")"
    hook pre Bash "$cj" "${2:-$SA}" "${3:-$R}"
    sleep 0.05
    bash -c "$1"
    hook post Bash "$cj" "${2:-$SA}" "${3:-$R}"
}
TXN=0
tx_call() { # <tool name> <path> <ok|error|rejected> : one tool_use plus its tool_result in the transcript
    TXN=$((TXN + 1))
    python3 -c '
import json, sys
name, path, how, n = sys.argv[1:5]
use = {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_" + n, "name": name,
       "input": {"file_path": path, "content": "x"}}]}}
res = {"type": "tool_result", "tool_use_id": "toolu_" + n, "content": "ok"}
top = {"type": "user", "message": {"content": [res]}, "toolUseResult": {"type": "create", "filePath": path}}
if how == "error":
    res["is_error"] = True
    top["toolUseResult"] = "Error: write failed"
elif how == "rejected":
    res["is_error"] = True
    top["toolUseResult"] = "User rejected tool use"
print(json.dumps(use, separators=(",", ":")))
print(json.dumps(top, separators=(",", ":")))
' "$1" "$2" "$3" "$TXN" >> "$TX"
}
tx_write() { tx_call Write "$1" ok; }
write_call() { # <file path> : a Write tool call that creates the file (hooks + transcript)
    N=$((N + 1))
    hook pre Write "{\"file_path\":\"$1\"}" >/dev/null
    mkdir -p "$(dirname "$1")"; echo w > "$1"
    hook post Write "{\"file_path\":\"$1\"}"
    tx_write "$1"
}

# the session SA belongs to this shell's process tree (its helper calls are descendants)
printf '{"pid":%s,"sessionId":"%s"}' "$$" "$SA" > "$PROF/sessions/$$.json"

# --- 0. session start: private base, TMPDIR export -----------------------------------------
ENVF="$TMP/envfile"; : > "$ENVF"
o="$(printf '{"session_id":"%s","cwd":"%s","source":"startup"}' "$SA" "$R" | CLAUDE_ENV_FILE="$ENVF" python3 -I "$SHIM" "$OVJ" "$LEDGER" session-start)"
contains "TMPDIR exported" "export TMPDIR='$ST'" "$(cat "$ENVF")"
contains "helper exported" "export CREDO_CLEANUP=" "$(cat "$ENVF")"
check "session tmp base is private" 700 "$(stat -c %a "$CTMP")"
check "session tmp exists" yes "$(exists "$ST")"
contains "hint names the report-only rule" "everything else is report-only" "$o"
o="$(printf '{"session_id":"Documents","cwd":"%s","source":"startup"}' "$R" | CLAUDE_ENV_FILE="$ENVF" python3 -I "$SHIM" "$OVJ" "$LEDGER" session-start)"
check "non-UUID session id: no session dir" no "$(exists "$CTMP/Documents")"

# --- 1. scan entries are report-only (B4) ---------------------------------------------------
mkdir "$R/pre1"
run_call "mkdir $R/own1 && echo x > $R/own1/f"
o="$(helper own-rm "$R/own1")"
contains "scan entry with command evidence is report-only" "refused $R/own1: report only" "$o"
check "scan entry kept" yes "$(exists "$R/own1/f")"
o="$(helper own-rm "$R/pre1")"
contains "pre-existing refused" "refused $R/pre1: not created by this session" "$o"
# the owner and another app create files while a Bash call of the agent runs (reviewer repro2)
N=$((N + 1)); cj="$(cmdjson "npm test")"
hook pre Bash "$cj"
mkdir -p "$FH/notes"; echo meeting > "$FH/notes/plan.md"; mkdir "$R/app-cache-owner"; mkdir "$FH/newproject"
hook post Bash "$cj"
o="$(helper own-rm "$R/app-cache-owner" "$FH/newproject" "$FH/notes/plan.md")"
check "owner's temp dir kept" yes "$(exists "$R/app-cache-owner")"
check "owner's new project kept" yes "$(exists "$FH/newproject")"
check "owner's note kept" yes "$(exists "$FH/notes/plan.md")"
contains "home scan recorded the new home dir (reported)" '"root_kind": "home"' "$(grep newproject "$LEDGER_FILE")"

# --- 2. Write-created temp files: only that single file, only with the transcript ------------
write_call "$R/wrote/out.txt"
contains "the written file is recorded with write evidence" '"evidence": "write"' "$(grep "\"$R/wrote/out.txt\"" "$LEDGER_FILE")"
contains "its new parent dir is only write-parent (report only)" '"evidence": "write-parent"' "$(grep "\"$R/wrote\"" "$LEDGER_FILE")"
o="$(helper own-rm "$R/wrote")"
contains "dir created on the way by a Write is report-only" "refused $R/wrote" "$o"
o="$(helper own-rm "$R/wrote/out.txt")"
contains "the Write-created file (transcript-confirmed) removed" "removed $R/wrote/out.txt" "$o"
# B1: a dir that a Write created owns nothing that lands in it later
write_call "$R/verify/a.txt"
echo other > "$R/verify/from-session-b.txt"; mkdir "$R/verify/owner"; echo o > "$R/verify/owner/notes"
o="$(helper own-rm "$R/verify")"
check "Write-created dir with foreign content kept" yes "$(exists "$R/verify/owner/notes")"
o="$(helper own-rm "$R/verify/from-session-b.txt")"
contains "file another process put into it refused" "not created by this session" "$o"
# B2: post never records anything born before t0
mkdir -p "$R/race/sub"; echo old > "$R/race/sub/f"
sleep 0.05
mkdir -p "$TMP/state/marks/$SA"
python3 -c 'import json,sys,time; json.dump({"new": sys.argv[1], "file": sys.argv[2]}, open(sys.argv[3] + "/%.6f_tuRACE" % time.time(), "w"))' \
    "$R/race" "$R/race/sub/f" "$TMP/state/marks/$SA"
printf '{"session_id":"%s","tool_name":"Write","tool_use_id":"tuRACE","cwd":"%s","tool_input":{"file_path":"%s"}}' "$SA" "$R" "$R/race/sub/f" \
    | python3 -I "$SHIM" "$OVJ" "$LEDGER" post
check "nothing born before t0 is recorded" 0 "$(grep -c "$R/race" "$LEDGER_FILE")"
# M1: the transcript must hold a successful write of exactly that file
N=$((N + 1))
hook pre Write "{\"file_path\":\"$R/notx.txt\"}" >/dev/null
echo w > "$R/notx.txt"
hook post Write "{\"file_path\":\"$R/notx.txt\"}"
o="$(helper own-rm "$R/notx.txt")"
contains "Write entry without transcript call is report-only" "no successful Write/Edit call for exactly this file" "$o"
tx_call Read "$R/notx.txt" ok
o="$(helper own-rm "$R/notx.txt")"
contains "a Read call is no evidence" "no successful Write/Edit call" "$o"
tx_call Write "$R/notx.txt" rejected
tx_call Write "$R/notx.txt" error
o="$(helper own-rm "$R/notx.txt")"
contains "rejected or failed Writes are no evidence" "no successful Write/Edit call" "$o"
tx_call Write "$R/notx.txt.bak" ok
o="$(helper own-rm "$R/notx.txt")"
contains "no prefix match" "no successful Write/Edit call" "$o"
tx_call Edit "$R/notx.txt" ok
o="$(helper own-rm "$R/notx.txt")"
contains "a successful Edit of exactly the file counts" "removed $R/notx.txt" "$o"
write_call "$FH/made-by-write/a.txt"
o="$(helper own-rm "$FH/made-by-write/a.txt")"
contains "Write entry in the home is report-only" "outside the temp roots" "$o"
check "home Write entry kept" yes "$(exists "$FH/made-by-write/a.txt")"
echo old > "$R/existing.txt"
N=$((N + 1))
hook pre Edit "{\"file_path\":\"$R/existing.txt\"}" >/dev/null
hook post Edit "{\"file_path\":\"$R/existing.txt\"}"
tx_write "$R/existing.txt"
o="$(helper own-rm "$R/existing.txt")"
contains "edited existing file refused" "refused $R/existing.txt" "$o"
# a forged ledger line (valid dev/inode/birth, write evidence) for owner data in a temp root
mkdir -p "$R/owner-report"; echo data > "$R/owner-report/final.docx"
python3 -I -c '
import json, os, sys
sys.path.insert(0, sys.argv[3]); import credo_cleanup_lib as L
p = sys.argv[1]; st = os.lstat(p)
open(sys.argv[2], "a").write(json.dumps({"event": "record", "path": p, "dev": st.st_dev, "ino": st.st_ino,
    "type": "file", "btime": L.birth_time(p), "evidence": "write", "root_kind": "write"}) + "\n")
' "$R/owner-report/final.docx" "$LEDGER_FILE" "$SCRIPT_DIR"
o="$(helper own-rm "$R/owner-report/final.docx")"
contains "forged ledger line alone deletes nothing" "no successful Write/Edit call" "$o"
check "forged-line target kept" yes "$(exists "$R/owner-report/final.docx")"
# inode reuse: same dev+inode, other birth time
write_call "$R/reuse.log"
python3 -I -c '
import json, sys
lines = [json.loads(l) for l in open(sys.argv[2])]
for r in lines:
    if r.get("path") == sys.argv[1]:
        r["btime"] = 1.0
open(sys.argv[2], "w").write("".join(json.dumps(r) + "\n" for r in lines))
' "$R/reuse.log" "$LEDGER_FILE"
o="$(helper own-rm "$R/reuse.log")"
contains "inode reuse (other birth time) refused" "replaced since it was recorded" "$o"
write_call "$R/swapped.txt"
rm "$R/swapped.txt"; echo new > "$R/swapped.txt"
o="$(helper own-rm "$R/swapped.txt")"
contains "inode change refused" "replaced since it was recorded" "$o"

# --- 3. session TMPDIR and scratchpad (session-bound) -----------------------------------------
mkdir "$ST/run1"; echo x > "$ST/run1/f"
o="$(helper own-rm "$ST/run1")"
contains "TMPDIR child removed" "removed $ST/run1" "$o"
mkdir "$PAD/rel-clone"; echo y > "$PAD/rel-clone/a"
o="$(helper own-rm "$PAD/rel-clone")"
contains "scratchpad child removed" "removed $PAD/rel-clone" "$o"
o="$(helper own-rm "$ST")"
contains "TMPDIR root itself refused" "refused $ST" "$o"
mkdir -p "$TMP/precious"; echo keep > "$TMP/precious/data"
ln -s "$TMP/precious" "$ST/link1"
o="$(helper own-rm "$ST/link1/data")"
contains "path through a symlink refused" "refused $TMP/precious/data" "$o"
o="$(helper own-rm "$ST/link1")"
contains "own symlink unlinked" "removed $ST/link1" "$o"
check "symlink target kept" yes "$(exists "$TMP/precious/data")"
mkdir "$ST/keepme"
o="$(helper own-rm "$ST/keepme")"
contains "keep_paths refused" "owner's keep list" "$o"
mkdir "$ST/nonuuid"
o="$(CLAUDE_CODE_SESSION_ID=Documents helper own-rm "$ST/nonuuid")"
contains "non-UUID session id refused" "no session id" "$o"

# N1: the session id must belong to the caller's process tree
SC="cccccccc-0000-4000-8000-000000000003"
mkdir -p "$CTMP/$SB"; chmod 700 "$CTMP/$SB"; mkdir "$CTMP/$SB/their-run"
( exec sleep 30 ) &
OTHER=$!
printf '{"pid":%s,"sessionId":"%s"}' "$OTHER" "$SB" > "$PROF/sessions/$OTHER.json"
o="$(CLAUDE_CODE_SESSION_ID="$SB" helper own-rm "$CTMP/$SB/their-run")"
contains "another live session's TMPDIR refused" "alive in another process tree" "$o"
check "other session's run kept" yes "$(exists "$CTMP/$SB/their-run")"
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null
rm -f "$PROF/sessions/$OTHER.json"
mkdir -p "$CTMP/$SC"; chmod 700 "$CTMP/$SC"; mkdir "$CTMP/$SC/x"
o="$(CLAUDE_CODE_SESSION_ID="$SC" helper own-rm "$CTMP/$SC/x")"
contains "unbound session id is report-only" "cannot be bound to the calling process tree" "$o"

# --- 4. env overrides are ignored (B1) ------------------------------------------------------
o="$(CREDO_CLEANUP_SCRATCH_GLOB="$FH/Documents" CREDO_TMP_BASE="$FH" CREDO_CLEANUP_STATE="$TMP/fake" \
    CREDO_KEEP_ROOT="$TMP/fk" CREDO_CLEANUP_PROFILES="$TMP/fp" CREDO_CLEANUP_MOUNTINFO=/dev/null \
    HOME="$TMP/fakehome" XDG_STATE_HOME="$TMP/fake" helper own-rm "$FH/Documents/thesis")"
contains "env overrides do not make owner data session-bound" "refused $FH/Documents/thesis" "$o"
check "owner data kept despite env overrides" yes "$(exists "$FH/Documents/thesis/ch1.txt")"
check "runtime code reads no CREDO_CLEANUP_* / CREDO_TMP_BASE / CREDO_KEEP_ROOT env" 0 \
    "$(cat "$HELPER" "$LEDGER" "$SCRIPT_DIR/credo_cleanup_lib.py" | grep -c -E 'environ[^)]*(CREDO_CLEANUP_|CREDO_TMP_BASE|CREDO_KEEP_ROOT|XDG_STATE_HOME)')"

# --- 5. ~/.claude*/** -------------------------------------------------------------------------
N=$((N + 1))
hook pre Write "{\"file_path\":\"$PROF/new.txt\"}" >/dev/null
echo x > "$PROF/new.txt"
hook post Write "{\"file_path\":\"$PROF/new.txt\"}"
check "profile file never recorded" 0 "$(grep -c 'claude-x/new' "$LEDGER_FILE")"
o="$(helper own-rm "$PROF/new.txt")"
contains "profile path refused" "Claude profile data" "$o"
run_call "mkdir $FH/.claude-y"
check "new profile dir in home never recorded" 0 "$(grep -c 'claude-y' "$LEDGER_FILE")"

# --- 6. ledger guard: writes denied, reads and other words allowed (B3) ----------------------
o="$(hook pre Write "{\"file_path\":\"$LEDGER_FILE\"}")"
contains "Write to ledger denied" '"permissionDecision": "deny"' "$o"
o="$(hook pre Bash "$(cmdjson "echo {} >> $LEDGER_FILE")")"
contains "Bash append to ledger denied" '"permissionDecision": "deny"' "$o"
o="$(hook pre Edit "{\"file_path\":\"$TMP/keep/keep-list.json\"}")"
contains "Edit of keep list denied" '"permissionDecision": "deny"' "$o"
o="$(hook pre Bash "$(cmdjson "cd ~/.local/state/credo && echo {} >> cleanup/ledger/$SA.jsonl")")"
contains "cd + relative ledger write denied" '"permissionDecision": "deny"' "$o"
o="$(hook pre Bash "$(cmdjson "cat $LEDGER_FILE | wc -l")")"
check "reading the ledger allowed" "" "$o"
o="$(hook pre Bash "$(cmdjson "tail -5 $TMP/state/cleanup.log")")"
check "reading the cleanup log allowed" "" "$o"
o="$(hook pre Bash "$(cmdjson "make cleanup && ls ~/.local/state")")"
check "make cleanup allowed" "" "$o"

# --- 7. subagent entries carry the agent id ----------------------------------------------------
N=$((N + 1)); cj="$(cmdjson "mkdir $R/sub1")"
printf '{"session_id":"%s","agent_id":"agent-1","tool_name":"Bash","tool_use_id":"tu%s","cwd":"%s","tool_input":%s}' "$SA" "$N" "$R" "$cj" | python3 -I "$SHIM" "$OVJ" "$LEDGER" pre
mkdir "$R/sub1"
printf '{"session_id":"%s","agent_id":"agent-1","tool_name":"Bash","tool_use_id":"tu%s","cwd":"%s","tool_input":%s}' "$SA" "$N" "$R" "$cj" | python3 -I "$SHIM" "$OVJ" "$LEDGER" post
contains "subagent entry carries agent id" '"agent_id": "agent-1"' "$(grep sub1 "$LEDGER_FILE")"

# --- 8. command evidence needs a whole token (M1) ------------------------------------------------
N=$((N + 1)); cj="$(cmdjson "npm run test")"
hook pre Bash "$cj" "$SA" /elsewhere
echo foreign > "$R/test"
hook post Bash "$cj" "$SA" /elsewhere
contains "a plain word is no command evidence" '"evidence": "window"' "$(grep "\"$R/test\"" "$LEDGER_FILE")"
N=$((N + 1)); cj="$(cmdjson "cd $R && mkdir rel1")"
hook pre Bash "$cj" "$SA" /elsewhere
mkdir "$R/rel1"
hook post Bash "$cj" "$SA" /elsewhere
contains "relative token resolves only against the call cwd" '"evidence": "window"' "$(grep "\"$R/rel1\"" "$LEDGER_FILE")"

# --- 9. keep step: kept results are never deleted by an agent (B2) ------------------------------
mkdir "$ST/export1"; echo m > "$ST/export1/model.bin"
o="$(cd "$R" && helper keep "$ST/export1" onnx-v2 --reason "owner: keep this export" --item 999 --licence "own data" --project acme)"
contains "keep moves" "kept $ST/export1 -> $TMP/keep/acme/onnx-v2" "$o"
check "kept content there" yes "$(exists "$TMP/keep/acme/onnx-v2/model.bin")"
contains "keep list records quote" "owner: keep this export" "$(cat "$TMP/keep/keep-list.json")"
o="$(helper own-rm "$TMP/keep/acme/onnx-v2")"
contains "kept entry is report-only" "the owner may release it" "$o"
helper own-rm "$TMP/keep/acme/onnx-v2" --superseded "owner said so" >/dev/null 2>&1; rc=$?
check "--superseded no longer exists" 2 "$rc"
mkdir -p "$FH/photos/2020"; echo img > "$FH/photos/2020/a.jpg"
printf '[{"path":"%s","item":"1","reason":"x"}]\n' "$FH/photos" > "$TMP/keep/keep-list.json"
o="$(helper own-rm "$FH/photos")"
check "forged keep entry widens nothing" yes "$(exists "$FH/photos/2020/a.jpg")"
check "kept export still there" yes "$(exists "$TMP/keep/acme/onnx-v2/model.bin")"

# --- 10. purge (done-gate) -------------------------------------------------------------------------
write_call "$R/wrote2/out.txt"
mkdir "$ST/build1"
o="$(CREDO_TEST_OV_EXTRA='{"idle_minutes": 30}' helper purge)"
contains "purge keeps a fresh Write entry (idle 30 min)" "refused $R/wrote2/out.txt: report only: changed in the last" "$o"
contains "purge lists the Write-parent dir" "listed $R/wrote2: report only" "$o"
contains "purge lists scan entries" "listed $R/own1: report only: not a file the Write/Edit tool created" "$o"
contains "purge lists TMPDIR children" "listed $ST/build1: session TMPDIR, shared with parallel subagents" "$o"
o="$(helper purge --now)"
contains "purge --now removes the confirmed Write file" "removed $R/wrote2/out.txt" "$o"
check "purge keeps the Write-parent dir" yes "$(exists "$R/wrote2")"
check "purge leaves TMPDIR children" yes "$(exists "$ST/build1")"
check "purge leaves scan entries" yes "$(exists "$R/own1")"
mkdir -p "$ST/bt/result"; echo r > "$ST/bt/result/model.bin"
o="$(helper purge --now --except "$ST/bt/result")"
contains "except: parent of the result listed as excepted" "listed $ST/bt: excepted" "$o"

# --- 11. item-close is report only (M1) ---------------------------------------------------------
mkdir "$ST/idle1"; echo z > "$ST/idle1/f"
o="$(helper item-close)"
contains "item-close lists" "listed $ST/idle1: session TMPDIR, removed by the sweep" "$o"
check "item-close deletes nothing" yes "$(exists "$ST/idle1/f")"
o="$(CREDO_TEST_OV_EXTRA='{"item_close_budget_s": -1}' helper item-close)"
contains "item-close time budget" "time budget used up" "$o"

# --- 12. moved-in, extracted, in use (review regressions) ---------------------------------------
mv "$FH/userdata" "$ST/"
o="$(helper own-rm "$ST/userdata")"
contains "data moved into TMPDIR refused" "pre-existing data moved in" "$o"
check "moved-in data kept" yes "$(exists "$ST/userdata/thesis.txt")"
mkdir "$ST/extracted"; echo old > "$ST/extracted/f"; touch -d '3 days ago' "$ST/extracted/f"
o="$(helper own-rm "$ST/extracted")"
contains "mtime older than birth refused" "modification time older than its birth" "$o"
mkdir -p "$ST/sockdir"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$ST/sockdir/daemon.sock"
o="$(helper own-rm "$ST/sockdir")"
contains "explicit own-rm: socket inside refused" "socket, fifo or device" "$o"
mkdir -p "$ST/busy"
( cd "$ST/busy" && exec sleep 30 ) &
BUSY=$!
sleep 0.3
o="$(helper own-rm "$ST/busy")"
contains "explicit own-rm: live process inside refused" "in use by process" "$o"
kill "$BUSY" 2>/dev/null; wait "$BUSY" 2>/dev/null
mkdir -p "$ST/deep/a/b"; echo live > "$ST/deep/a/b/work.txt"
o="$(CREDO_TEST_OV_EXTRA='{"explicit_idle_s": 120}' helper own-rm "$ST/deep")"
contains "explicit own-rm: fresh deep change refused" "changed in the last 120s" "$o"
# a path swapped for a symlink after the check is not followed
mkdir -p "$TMP/victim"; echo v > "$TMP/victim/keep.txt"
mkdir "$ST/swap"; echo s > "$ST/swap/f"
o="$(python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import credo_cleanup_lib as L
p = sys.argv[2]
st = os.lstat(p)
os.rename(p, p + ".old")
os.symlink(sys.argv[3], p)
print(L.delete_path(p, st, False))
' "$SCRIPT_DIR" "$ST/swap" "$TMP/victim")"
contains "swapped path refused" "replaced since the check" "$o"
check "symlink target untouched" yes "$(exists "$TMP/victim/keep.txt")"
# a mount point (also a same-device bind mount) at or below the target
MI="$TMP/mountinfo"
printf '36 25 8:1 / / rw - ext4 /dev/sda rw\n90 36 8:1 /x %s rw - ext4 /dev/sda rw\n' "$ST/bound/inner" > "$MI"
mkdir -p "$ST/bound/inner"
o="$(CREDO_TEST_OV_EXTRA="{\"mountinfo\": \"$MI\"}" helper own-rm "$ST/bound")"
contains "bind mount below the target refused" "mount point at or below it" "$o"
mkdir -p "$FH/cloudmnt"
printf '36 25 8:1 / / rw - ext4 /dev/sda rw\n91 36 0:99 / %s rw - fuse.example cm rw\n' "$FH/cloudmnt" > "$MI"
N=$((N + 1)); cj="$(cmdjson "mkdir $FH/cloudmnt/newdir")"
CREDO_TEST_OV_EXTRA="{\"mountinfo\": \"$MI\"}" hook pre Bash "$cj"
mkdir "$FH/cloudmnt/newdir"
CREDO_TEST_OV_EXTRA="{\"mountinfo\": \"$MI\"}" hook post Bash "$cj"
check "home scan never enters a mount (FUSE)" 0 "$(grep -c 'cloudmnt' "$LEDGER_FILE")"
# git error fails closed
mkdir "$ST/clone1"; git init -q "$ST/clone1"; echo a > "$ST/clone1/a.txt"
git -C "$ST/clone1" add a.txt; echo garbage > "$ST/clone1/.git/index"
o="$(helper own-rm "$ST/clone1/a.txt")"
contains "git error fails closed" "tracked by git" "$o"

# --- 13. own worktree: only known build-output dirs of a worktree this session created --------
M="$TMP/repo"
git init -q -b main "$M"
mkdir -p "$M/.credo/items"; echo "same" > "$M/.credo/items/a.md"; echo "main" > "$M/.credo/items/c.md"
printf '.credo/\nbuild/\nnode_modules/\n*.local.db\nsettings.local*\n' > "$M/.gitignore"
git -C "$M" add .gitignore && git -C "$M" commit -q -m init
mkdir -p "$TMP/repo-worktrees"
git -C "$M" worktree add -q -b wt/un "$TMP/repo-worktrees/un"     # NOT created by this session
W="$TMP/repo-worktrees/un"
WR="$TMP/repo-worktrees"
CREDO_TEST_OV_EXTRA="{\"roots\": [\"$R\", \"$WR\"]}" run_call "git -C $M worktree add -q -b wt/mine $WR/mine"
MW="$WR/mine"
contains "worktree creation recorded" "\"$MW\"" "$(cat "$LEDGER_FILE")"
mkdir -p "$MW/build/out" "$MW/web/node_modules/pkg" "$MW/dist"; echo bin > "$MW/build/out/app"; echo m > "$MW/web/node_modules/pkg/i.js"
echo db > "$MW/x.local.db"; echo s > "$MW/settings.local.json"; echo c > "$MW/CLAUDE.md"
echo "dist/" >> "$M/.git/info/exclude"; echo "CLAUDE.md" >> "$M/.git/info/exclude"
o="$(cd "$MW" && helper own-rm "$MW/build" "$MW/web/node_modules")"
contains "build/ of the own worktree removed" "removed $MW/build" "$o"
contains "nested node_modules removed" "removed $MW/web/node_modules" "$o"
o="$(cd "$MW" && helper own-rm "$MW/x.local.db" "$MW/settings.local.json" "$MW/CLAUDE.md")"
check "*.local.db kept" yes "$(exists "$MW/x.local.db")"
check "settings.local kept" yes "$(exists "$MW/settings.local.json")"
check "CLAUDE.md kept" yes "$(exists "$MW/CLAUDE.md")"
contains "single files are report-only" "only known build-output directories" "$o"
o="$(cd "$MW" && helper own-rm "$MW/dist")"
contains "dir ignored only by info/exclude refused" "not by a tracked .gitignore" "$o"
# a negation rule (!node_modules/) in a tracked .gitignore re-includes the dir: not ignored
mkdir -p "$MW/neg"; printf '!node_modules/\n' > "$MW/neg/.gitignore"
git -C "$MW" add neg/.gitignore && git -C "$MW" commit -q -m neg
mkdir -p "$MW/neg/node_modules"; echo f > "$MW/neg/node_modules/f"
o="$(cd "$MW" && helper own-rm "$MW/neg/node_modules")"
contains "negated (re-included) dir refused" "refused $MW/neg/node_modules" "$o"
check "negated dir kept" yes "$(exists "$MW/neg/node_modules/f")"
mkdir -p "$W/build/out"; echo bin > "$W/build/out/app"
o="$(cd "$W" && helper own-rm "$W/build")"
contains "worktree not created by this session refused" "does not show it created this worktree" "$o"
check "other worktree's build kept" yes "$(exists "$W/build/out/app")"
o="$(cd "$R" && helper own-rm "$MW/dist")"
contains "worktree the helper does not run in refused" "refused $MW/dist" "$o"
mkdir -p "$WR/subm/build"; printf 'gitdir: %s\n' "$M/.git/modules/subm" > "$WR/subm/.git"
o="$(cd "$WR/subm" && helper own-rm "$WR/subm/build")"
contains "submodule-style .git refused" "not a hydra worktree" "$o"

# --- 14. worktrees: .credo guard, rescue, unmerged never removed --------------------------------
echo work > "$W/f.txt"; git -C "$W" add f.txt; git -C "$W" commit -q -m unique
mkdir -p "$W/.credo/items"; echo "same" > "$W/.credo/items/a.md"; echo "new" > "$W/.credo/items/b.md"; echo "other" > "$W/.credo/items/c.md"
o="$(hook pre Write "{\"file_path\":\"$W/.credo/items/d.md\"}" "$SA" "$W")"
contains "Write into real worktree .credo denied" '"permissionDecision": "deny"' "$o"
contains "deny names the main path" "$M/.credo/items/d.md" "$o"
o="$(hook pre Bash '{"command":"echo x > .credo/items/e.md"}' "$SA" "$W")"
contains "Bash redirect into worktree .credo denied" '"permissionDecision": "deny"' "$o"
o="$(python3 -I "$HELPER" rescue-credo "$W")"; rc=$?
contains "stray file rescued" "rescued .credo/items/b.md" "$o"
contains "identical file same" "same .credo/items/a.md" "$o"
contains "differing file conflict" "conflict .credo/items/c.md" "$o"
check "conflict exit code" 3 "$rc"
check "rescued file in main" "new" "$(cat "$M/.credo/items/b.md")"
check "main file not overwritten" "main" "$(cat "$M/.credo/items/c.md")"
mkdir -p "$M/.credo/items/2_done"; echo done > "$M/.credo/items/2_done/77-x.md"
mkdir -p "$W/.credo/items/1_todo/2_go"; echo stale > "$W/.credo/items/1_todo/2_go/77-x.md"
o="$(python3 -I "$HELPER" rescue-credo "$W")"
contains "rescue: item under another status folder reported" "conflict .credo/items/1_todo/2_go/77-x.md: the item lives under another status folder" "$o"
check "rescue: stale status copy not created" no "$(exists "$M/.credo/items/1_todo/2_go/77-x.md")"
o="$(bash "$WTC" --details "$M" 2>/dev/null)"
contains "unmerged reported with content" "unique_commits=1" "$o"
check "unmerged worktree never removed" yes "$(exists "$W/f.txt")"
git -C "$M" worktree add -q -b wt/two "$ST/wt2"
o="$(helper own-rm "$ST/wt2")"
contains "linked worktree refused" "linked git worktree" "$o"
check "linked worktree kept" yes "$(exists "$ST/wt2/.git")"

# --- 15. sweep of dead sessions --------------------------------------------------------------
DEAD="$CTMP/11111111-2222-4333-8444-555555555555"
mkdir -p "$DEAD/x"; echo y > "$DEAD/x/f"
git -C "$M" worktree add -q -b wip "$DEAD/wt"
echo w > "$DEAD/wt/new.txt"; git -C "$DEAD/wt" add new.txt; git -C "$DEAD/wt" commit -q -m wip
touch -d '1 hour ago' "$DEAD"
o="$(helper sweep)"
check "sweep removes own junk of a dead session" no "$(exists "$DEAD/x")"
check "sweep keeps a linked worktree" yes "$(exists "$DEAD/wt/new.txt")"
contains "sweep reports it" "kept $DEAD/wt" "$o"
check "sweep keeps the live session tmp" yes "$(exists "$ST")"
mkdir -p "$TMP/fakebase/Documents" "$TMP/fakebase/33333333-2222-4333-8444-555555555555"
echo x > "$TMP/fakebase/Documents/a"
o="$(CREDO_TEST_OV_EXTRA="{\"tmp_base\": \"$TMP/fakebase\"}" helper sweep)"
contains "sweep refuses a non-private base" "not a private dir" "$o"
chmod 700 "$TMP/fakebase"; touch -d '1 hour ago' "$TMP/fakebase/Documents"
CREDO_TEST_OV_EXTRA="{\"tmp_base\": \"$TMP/fakebase\"}" helper sweep >/dev/null
check "sweep never touches non-session names" yes "$(exists "$TMP/fakebase/Documents/a")"
ln -s "$TMP/fakebase" "$TMP/linkbase"
o="$(CREDO_TEST_OV_EXTRA="{\"tmp_base\": \"$TMP/linkbase\"}" helper sweep)"
contains "sweep refuses a symlinked base" "not a private dir" "$o"

# --- 16. Playwright prune ----------------------------------------------------------------------
PC="$TMP/pwcache"; S="$TMP/pwsearch"
mkdir -p "$PC"/{chromium-1100,chromium-1200,chromium_headless_shell-1200,ffmpeg-1010,firefox-999,mcp-chrome-abc,webkit-2000,chromium-1300,firefox-1500,webkit-3000} "$PC/.links"
mkdir -p "$S/proj/node_modules/playwright-core" "$S/proj2/node_modules/.pnpm/playwright-core@1.0.0/node_modules/playwright-core" \
    "$S/venv/lib/python3.12/site-packages/playwright/driver/package" "$S/m2"
echo '{"browsers":[{"name":"chromium","revision":"1200"},{"name":"chromium-headless-shell","revision":"1200"},{"name":"ffmpeg","revision":"1010"}]}' > "$S/proj/node_modules/playwright-core/browsers.json"
echo '{"browsers":[{"name":"webkit","revision":"1999","revisionOverrides":{"mac12":"2000"}}]}' > "$S/proj2/node_modules/.pnpm/playwright-core@1.0.0/node_modules/playwright-core/browsers.json"
echo '{"browsers":[{"name":"firefox","revision":"1500"}]}' > "$S/venv/lib/python3.12/site-packages/playwright/driver/package/browsers.json"
python3 -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("driver/package/browsers.json", "{\"browsers\":[{\"name\":\"webkit\",\"revision\":\"3000\"}]}")
' "$S/m2/driver-bundle-1.0.jar"
touch -d '1 day ago' "$PC"/*
( exec -a "$PC/chromium-1300/chrome-linux/chrome" sleep 30 ) &
PWP=$!
sleep 0.3
o="$(helper playwright-prune --cache "$PC" --search "$S")"
kill "$PWP" 2>/dev/null; wait "$PWP" 2>/dev/null
check "unreferenced chromium removed" no "$(exists "$PC/chromium-1100")"
check "unreferenced firefox removed" no "$(exists "$PC/firefox-999")"
check "referenced chromium kept" yes "$(exists "$PC/chromium-1200")"
check "referenced headless shell kept" yes "$(exists "$PC/chromium_headless_shell-1200")"
check "referenced ffmpeg kept" yes "$(exists "$PC/ffmpeg-1010")"
check "revision override kept (pnpm path)" yes "$(exists "$PC/webkit-2000")"
check "Python driver revision kept" yes "$(exists "$PC/firefox-1500")"
check "Java jar revision kept" yes "$(exists "$PC/webkit-3000")"
check "revision used by a running process kept" yes "$(exists "$PC/chromium-1300")"
check "mcp-chrome never touched" yes "$(exists "$PC/mcp-chrome-abc")"
check ".links never touched" yes "$(exists "$PC/.links")"
mkdir "$PC/chromium-1000"; touch -d '1 day ago' "$PC/chromium-1000"
o="$(helper playwright-prune --cache "$PC" --search "$TMP/empty-search")"
contains "no installation found: nothing pruned" "nothing is pruned blind" "$o"
mkdir -p "$S/locked"; chmod 000 "$S/locked"
o="$(helper playwright-prune --cache "$PC" --search "$S")"
chmod 700 "$S/locked"
contains "unreadable dir: nothing pruned" "nothing is pruned when anything is unclear" "$o"
echo '{"broken' > "$S/proj/node_modules/playwright-core/browsers.json"
o="$(helper playwright-prune --cache "$PC" --search "$S")"
contains "malformed Playwright browsers.json: nothing pruned" "nothing is pruned when anything is unclear" "$o"
check "kept while unclear" yes "$(exists "$PC/chromium-1000")"
check "helper never runs an installer" 0 "$(cat "$HELPER" "$LEDGER" | grep -c -E '"(npx|npm|pnpm|yarn|pip|pip3|apt|apt-get)"')"

# N2: a .links target that cannot be read (EIO, a drive that is down, no permission) is unclear
echo '{"browsers":[{"name":"chromium","revision":"1200"}]}' > "$S/proj/node_modules/playwright-core/browsers.json"
mkdir -p "$TMP/linkpkg/locked"; echo '{"browsers":[]}' > "$TMP/linkpkg/locked/browsers.json"
printf '%s' "$TMP/linkpkg/locked" > "$PC/.links/abc"; chmod 000 "$TMP/linkpkg"
o="$(helper playwright-prune --cache "$PC" --search "$S/proj")"
chmod 700 "$TMP/linkpkg"
contains "unreachable .links target: nothing pruned" "nothing is pruned when anything is unclear" "$o"

# .links unreadable, or a target on a drive that is not mounted: unclear, nothing pruned
chmod 000 "$PC/.links"
o="$(helper playwright-prune --cache "$PC" --search "$S/proj")"
chmod 700 "$PC/.links"
contains "unreadable .links: nothing pruned" "nothing is pruned when anything is unclear" "$o"
rm -f "$PC/.links/abc"
printf '%s' "/mnt/credo-test-absent/pkg" > "$PC/.links/mnt1"
o="$(helper playwright-prune --cache "$PC" --search "$S/proj")"
contains "missing target under /mnt: unclear" "not available" "$o"
rm -f "$PC/.links/mnt1"
printf 'nas:/share %s cifs noauto 0 0\n' "$TMP/nasmnt" > "$TMP/fstab"
printf '%s' "$TMP/nasmnt/proj/node_modules/playwright-core" > "$PC/.links/nas1"
o="$(CREDO_TEST_OV_EXTRA="{\"fstab\": \"$TMP/fstab\"}" helper playwright-prune --cache "$PC" --search "$S/proj")"
contains "missing target on an unmounted fstab mount: unclear" "not available" "$o"
rm -f "$PC/.links/nas1"
printf '%s' "$TMP/gone-pkg" > "$PC/.links/gone1"
o="$(helper playwright-prune --cache "$PC" --search "$S/proj")"
contains "a really removed package is a stale link" "installation $S/proj/node_modules/playwright-core/browsers.json" "$o"
rm -f "$PC/.links/gone1"

# CLAUDE_CONFIG_DIR is used for profiles only when it is a real .claude* dir of the home
mkdir -p "$TMP/elsewhere/.claude-z" "$FH/.claude-ok"; ln -s "$TMP/elsewhere/.claude-z" "$FH/.claude-lnk"
o="$(python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1]); import credo_cleanup_lib as L
L.OVERRIDES["home"] = sys.argv[2]
res = []
for cfg in (sys.argv[3], sys.argv[4], sys.argv[5]):
    os.environ["CLAUDE_CONFIG_DIR"] = cfg
    res.append("in" if cfg in L.profile_dirs() else "out")
print(" ".join(res))
' "$SCRIPT_DIR" "$FH" "$TMP/elsewhere/.claude-z" "$FH/.claude-lnk" "$FH/.claude-ok")"
check "CLAUDE_CONFIG_DIR: outside the home ignored, symlink ignored, real home dir used" "out out in" "$o"

# N4: worktree in use by an open file (not cwd), and the background busy check
M2="$TMP/repo3"
git init -q -b main "$M2"; git -C "$M2" commit -q --allow-empty -m init
git -C "$M2" worktree add -q -b wt/m "$TMP/repo3-worktrees/m"
echo w > "$TMP/repo3-worktrees/m/f.txt"; git -C "$TMP/repo3-worktrees/m" add f.txt; git -C "$TMP/repo3-worktrees/m" commit -q -m m
git -C "$M2" merge -q --ff-only wt/m
( cd "$TMP" && exec python3 -c 'import sys, time; f = open(sys.argv[1]); time.sleep(30)' "$TMP/repo3-worktrees/m/f.txt" ) &
HOLD=$!
sleep 0.5
o="$(cd "$TMP" && bash "$WTC" --dry-run "$M2" 2>/dev/null)"
kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null
contains "open file inside keeps a merged worktree" "live process inside it" "$o"
o="$(helper worktree-busy "$TMP/repo3-worktrees/m")"; rc=$?
check "recent change: worktree busy" 0 "$rc"
contains "busy reason names the change" "changed in the last 2h" "$o"

# --- 17. disabled switch -------------------------------------------------------------------------
o="$(CREDO_LEDGER=0 hook pre Write "{\"file_path\":\"$LEDGER_FILE\"}")"
check "CREDO_LEDGER=0 turns the hooks off" "" "$o"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

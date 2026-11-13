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
tx_write() { # record a Write tool call for path in this session's transcript
    python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":sys.argv[1],"content":"x"}}]}}, separators=(",", ":")))' "$1" >> "$TX"
}
write_call() { # <file path> : a Write tool call that creates the file (hooks + transcript)
    N=$((N + 1))
    hook pre Write "{\"file_path\":\"$1\"}" >/dev/null
    mkdir -p "$(dirname "$1")"; echo w > "$1"
    hook post Write "{\"file_path\":\"$1\"}"
    tx_write "$1"
}

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
contains "scan entry with command evidence is report-only" "refused $R/own1: report only: found by the birth-time scan" "$o"
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

# --- 2. Write-created temp entries: deletable only with the transcript ------------------------
write_call "$R/wrote/out.txt"
contains "topmost new dir of a Write recorded" '"evidence": "write"' "$(grep "\"$R/wrote\"" "$LEDGER_FILE")"
o="$(helper own-rm "$R/wrote")"
contains "Write entry confirmed by the transcript removed" "removed $R/wrote" "$o"
N=$((N + 1))
hook pre Write "{\"file_path\":\"$R/notx.txt\"}" >/dev/null
echo w > "$R/notx.txt"
hook post Write "{\"file_path\":\"$R/notx.txt\"}"
o="$(helper own-rm "$R/notx.txt")"
contains "Write entry without transcript call is report-only" "no Write/Edit call for it in this session's transcript" "$o"
write_call "$FH/made-by-write/a.txt"
o="$(helper own-rm "$FH/made-by-write")"
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
    "type": "dir", "btime": L.birth_time(p), "evidence": "write", "root_kind": "write"}) + "\n")
' "$R/owner-report" "$LEDGER_FILE" "$SCRIPT_DIR"
o="$(helper own-rm "$R/owner-report")"
contains "forged ledger line alone deletes nothing" "no Write/Edit call for it in this session's transcript" "$o"
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
write_call "$R/swapped/f"
rm -r "$R/swapped"; mkdir "$R/swapped"
o="$(helper own-rm "$R/swapped")"
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
contains "purge keeps a fresh Write entry (idle 30 min)" "refused $R/wrote2: report only: changed in the last" "$o"
contains "purge lists scan entries" "listed $R/own1: report only: found by the birth-time scan" "$o"
contains "purge lists TMPDIR children" "listed $ST/build1: session TMPDIR, shared with parallel subagents" "$o"
o="$(helper purge --now)"
contains "purge --now removes the confirmed Write entry" "removed $R/wrote2" "$o"
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
mkdir -p "$FH/gdrive"
printf '36 25 8:1 / / rw - ext4 /dev/sda rw\n91 36 0:99 / %s rw - fuse.rclone gd rw\n' "$FH/gdrive" > "$MI"
N=$((N + 1)); cj="$(cmdjson "mkdir $FH/gdrive/newdir")"
CREDO_TEST_OV_EXTRA="{\"mountinfo\": \"$MI\"}" hook pre Bash "$cj"
mkdir "$FH/gdrive/newdir"
CREDO_TEST_OV_EXTRA="{\"mountinfo\": \"$MI\"}" hook post Bash "$cj"
check "home scan never enters a mount (FUSE)" 0 "$(grep -c 'gdrive' "$LEDGER_FILE")"
# git error fails closed
mkdir "$ST/clone1"; git init -q "$ST/clone1"; echo a > "$ST/clone1/a.txt"
git -C "$ST/clone1" add a.txt; echo garbage > "$ST/clone1/.git/index"
o="$(helper own-rm "$ST/clone1/a.txt")"
contains "git error fails closed" "tracked by git" "$o"

# --- 13. own worktree: ignored build output only -------------------------------------------------
M="$TMP/repo"
git init -q -b main "$M"
mkdir -p "$M/.credo/items"; echo "same" > "$M/.credo/items/a.md"; echo "main" > "$M/.credo/items/c.md"
printf '.credo/\nbuild/\n' > "$M/.gitignore"
git -C "$M" add .gitignore && git -C "$M" commit -q -m init
git -C "$M" worktree add -q -b wt/un "$TMP/repo-worktrees/un"
W="$TMP/repo-worktrees/un"
mkdir -p "$W/build/out"; echo bin > "$W/build/out/app"; echo src > "$W/src.txt"
o="$(cd "$W" && helper own-rm "$W/build")"
contains "ignored build output in own worktree removed" "removed $W/build" "$o"
o="$(cd "$W" && helper own-rm "$W/src.txt")"
contains "untracked non-ignored worktree file refused" "refused $W/src.txt" "$o"
o="$(cd "$R" && mkdir -p "$W/build" && helper own-rm "$W/build")"
contains "build output of a worktree the helper does not run in refused" "refused $W/build" "$o"

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
printf '{"pid":%s,"sessionId":"%s"}' "$$" "$SA" > "$PROF/sessions/$$.json"
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

# --- 17. disabled switch -------------------------------------------------------------------------
o="$(CREDO_LEDGER=0 hook pre Write "{\"file_path\":\"$LEDGER_FILE\"}")"
check "CREDO_LEDGER=0 turns the hooks off" "" "$o"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

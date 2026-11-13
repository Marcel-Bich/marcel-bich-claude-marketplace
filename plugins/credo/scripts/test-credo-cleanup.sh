#!/bin/bash
# Tests for the provenance ledger (credo-ledger.py) and the cleanup helper (credo-cleanup.py), #174.
# Everything runs inside a mktemp fixture: HOME, state dir, keep store, session tmp base, scan
# roots, profiles and the Playwright cache are all redirected there; nothing real is touched.
# Covered: ledger-owned delete ok; pre-existing path refused; inode change refused; symlink
# unlinked, target kept; a path through a symlink refused; ~/.claude*/** refused and never
# recorded; owner keep_paths refused; ledger/keep-list writes by tool calls denied (Write and
# Bash); real .credo writes in a linked worktree denied, stray files rescued (conflict reported);
# unmerged worktree reported with content, never removed; Playwright prune keeps referenced
# revisions and mcp-chrome-*; Write-created file recorded, existing file not; ambiguous window
# entries refused; keep step + --superseded; purge (done-gate); session TMPDIR via
# CLAUDE_ENV_FILE; item-close; sweep of a dead session's TMPDIR; linked worktree refused.
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

export HOME="$TMP/home"
export CREDO_CLEANUP_STATE="$TMP/state"
export CREDO_KEEP_ROOT="$TMP/keep"
export CREDO_TMP_BASE="$TMP/ctmp"
export CREDO_CLEANUP_ROOTS="$TMP/roots/t"
export CREDO_CLEANUP_HOME_ROOT="$HOME"
export CREDO_CLEANUP_SYNC=1
export CREDO_CLEANUP_NO_MAINTENANCE=1
export CLAUDE_CONFIG_DIR="$HOME/.claude-x"
export CREDO_CLEANUP_PROFILES="$CLAUDE_CONFIG_DIR"
export CREDO_CLEANUP_SCRATCH_GLOB="$TMP/scratch/{sid}/scratchpad"
export CREDO_GLOBAL="$TMP/cfg/config" CREDO_PROFILE="" CREDO_CONFIG_STDLIB_YAML=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export DOGMA_CREDO_CONFIG=none DOGMA_SESSION_DIR="$TMP/dsession"
unset CREDO_SESSION_ID CREDO_LEDGER PLAYWRIGHT_BROWSERS_PATH CLAUDE_ENV_FILE CREDO_DIR CREDO_PROJECT
export CLAUDE_CODE_SESSION_ID="sess-a"
R="$TMP/roots/t"
mkdir -p "$HOME/.claude-x" "$R" "$TMP/cfg" "$TMP/dsession" "$TMP/scratch/sess-a/scratchpad"
printf 'cleanup:\n  keep_paths:\n    - %s\n' "$R/keepme" > "$CREDO_GLOBAL"
# pre-existing user data for the review regressions (born before every session entry)
mkdir -p "$HOME/userdata" "$HOME/proj/config"
echo precious > "$HOME/userdata/thesis.txt"; echo secret-cfg > "$HOME/proj/config/app.yml"
sleep 2.5

N=0
hook() { # mode tool json-tool-input [session]
    printf '{"session_id":"%s","tool_name":"%s","tool_use_id":"tu%s","cwd":"%s","tool_input":%s}' \
        "${4:-sess-a}" "$2" "$N" "$R" "$3" | python3 -I "$LEDGER" "$1"
}
# run_call <bash command run between the pre and post hook> [session]
run_call() {
    N=$((N + 1))
    local cmdjson
    cmdjson="$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1")"
    hook pre Bash "$cmdjson" "${2:-sess-a}"
    sleep 0.05
    bash -c "$1"
    hook post Bash "$cmdjson" "${2:-sess-a}"
}
rm_own() { CLAUDE_CODE_SESSION_ID="${SID_OVERRIDE:-sess-a}" python3 -I "$HELPER" own-rm "$@"; }

# --- 1. owned delete ok; pre-existing refused; inode change refused ---------------
mkdir "$R/pre1"
run_call "mkdir $R/own1 && echo x > $R/own1/f"
o="$(rm_own "$R/own1")"
contains "owned dir removed" "removed $R/own1" "$o"
check "owned dir gone" no "$(exists "$R/own1")"
o="$(rm_own "$R/pre1")"
contains "pre-existing refused" "refused $R/pre1: not created by this session" "$o"
check "pre-existing kept" yes "$(exists "$R/pre1")"
run_call "mkdir $R/own2"
rmdir "$R/own2"; mkdir "$R/own2"
o="$(rm_own "$R/own2")"
contains "inode change refused" "replaced since it was recorded" "$o"
check "replaced dir kept" yes "$(exists "$R/own2")"

# --- 2. symlinks -----------------------------------------------------------------
mkdir -p "$TMP/precious"; echo keep > "$TMP/precious/data"
run_call "ln -s $TMP/precious $R/own3"
o="$(rm_own "$R/own3/data")"
contains "path through a symlink refused" "refused $TMP/precious/data" "$o"
o="$(rm_own "$R/own3")"
contains "own symlink unlinked" "removed $R/own3" "$o"
check "symlink target kept" yes "$(exists "$TMP/precious/data")"

# --- 3. ~/.claude*/** and keep_paths --------------------------------------------
N=$((N + 1))
hook pre Write "{\"file_path\":\"$HOME/.claude-x/new.txt\"}" >/dev/null
echo x > "$HOME/.claude-x/new.txt"
hook post Write "{\"file_path\":\"$HOME/.claude-x/new.txt\"}"
check "profile file never recorded" 0 "$(grep -c 'claude-x' "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
o="$(rm_own "$HOME/.claude-x/new.txt")"
contains "profile path refused" "Claude profile data" "$o"
check "profile file kept" yes "$(exists "$HOME/.claude-x/new.txt")"
run_call "mkdir $HOME/.claude-y"
check "new profile dir in home never recorded" 0 "$(grep -c 'claude-y' "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
run_call "mkdir $HOME/model-out"
contains "new home dir recorded (home scan)" "\"root_kind\": \"home\"" "$(grep 'model-out' "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
run_call "mkdir $R/keepme"
o="$(rm_own "$R/keepme")"
contains "keep_paths refused" "owner's keep list" "$o"
check "keep_paths dir kept" yes "$(exists "$R/keepme")"

# --- 4. ledger protected against tool writes -------------------------------------
o="$(hook pre Write "{\"file_path\":\"$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl\"}")"
contains "Write to ledger denied" '"permissionDecision": "deny"' "$o"
o="$(hook pre Bash "{\"command\":\"echo {} >> $CREDO_CLEANUP_STATE/ledger/sess-a.jsonl\"}")"
contains "Bash into ledger denied" '"permissionDecision": "deny"' "$o"
o="$(hook pre Edit "{\"file_path\":\"$CREDO_KEEP_ROOT/keep-list.json\"}")"
contains "Edit of keep list denied" '"permissionDecision": "deny"' "$o"
o="$(hook pre Bash '{"command":"ls /tmp"}')"
check "normal Bash not denied" "" "$o"

# --- 5. Write-created file recorded, existing file not ----------------------------
echo old > "$R/existing.txt"
N=$((N + 1))
hook pre Write "{\"file_path\":\"$R/newdir/sub/new.txt\"}" >/dev/null
mkdir -p "$R/newdir/sub"; echo x > "$R/newdir/sub/new.txt"
hook post Write "{\"file_path\":\"$R/newdir/sub/new.txt\"}"
N=$((N + 1))
hook pre Edit "{\"file_path\":\"$R/existing.txt\"}" >/dev/null
hook post Edit "{\"file_path\":\"$R/existing.txt\"}"
contains "topmost new dir of a Write recorded" "\"evidence\": \"write\"" "$(grep "\"$R/newdir\"" "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
o="$(rm_own "$R/existing.txt")"
contains "edited existing file refused" "refused $R/existing.txt" "$o"
o="$(rm_own "$R/newdir/sub/new.txt")"
contains "file below Write-created dir removed" "removed $R/newdir/sub/new.txt" "$o"

# --- 6. subagent entries are the session's (same session id) ---------------------
N=$((N + 1))
cj='{"command":"mkdir '"$R"'/sub1"}'
printf '{"session_id":"sess-a","agent_id":"agent-1","tool_name":"Bash","tool_use_id":"tu%s","cwd":"%s","tool_input":%s}' "$N" "$R" "$cj" | python3 -I "$LEDGER" pre
mkdir "$R/sub1"
printf '{"session_id":"sess-a","agent_id":"agent-1","tool_name":"Bash","tool_use_id":"tu%s","cwd":"%s","tool_input":%s}' "$N" "$R" "$cj" | python3 -I "$LEDGER" post
contains "subagent entry carries agent id" '"agent_id": "agent-1"' "$(grep sub1 "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
o="$(rm_own "$R/sub1")"
contains "main agent removes subagent's dir" "removed $R/sub1" "$o"

# --- 7. ambiguous window entries ---------------------------------------------------
mkdir -p "$CREDO_CLEANUP_STATE/marks/sess-b"
: > "$CREDO_CLEANUP_STATE/marks/sess-b/$(date +%s).000000_tuX"
run_call "python3 -c 'import os; os.mkdir(\"$R/\" + \"am\" + \"b1\")'"
run_call "mkdir $R/named1"
rm -f "$CREDO_CLEANUP_STATE/marks/sess-b/"*
o="$(rm_own "$R/amb1")"
contains "ambiguous window entry refused" "not provably this session's" "$o"
o="$(rm_own "$R/named1")"
contains "command-evidence entry ok despite other session" "removed $R/named1" "$o"
o="$(SID_OVERRIDE=sess-b rm_own "$R/amb1")"
contains "other session cannot remove it either" "refused $R/amb1" "$o"

# --- 8. keep step ------------------------------------------------------------------
run_call "mkdir $R/export1 && echo m > $R/export1/model.bin"
o="$(cd "$R" && python3 -I "$HELPER" keep "$R/export1" onnx-v2 --reason "owner: keep this export" --item 999 --licence "own data" --project acme)"
contains "keep moves" "kept $R/export1 -> $CREDO_KEEP_ROOT/acme/onnx-v2" "$o"
check "kept content there" yes "$(exists "$CREDO_KEEP_ROOT/acme/onnx-v2/model.bin")"
contains "keep list records quote" "owner: keep this export" "$(cat "$CREDO_KEEP_ROOT/keep-list.json")"
o="$(rm_own "$CREDO_KEEP_ROOT/acme/onnx-v2")"
contains "kept entry refused without superseded" "kept on owner request" "$o"
o="$(rm_own "$CREDO_KEEP_ROOT/acme/onnx-v2" --superseded "owner: export no longer needed")"
contains "kept entry removed with superseded" "removed $CREDO_KEEP_ROOT/acme/onnx-v2" "$o"

# --- 9. purge (done-gate): only Write-created temp entries and TMPDIR children ---------
run_call "mkdir $R/scratch-run"
run_call "python3 -c 'import os; os.mkdir(\"$R/\" + \"anon\" + \"1\")'"
N=$((N + 1))
hook pre Write "{\"file_path\":\"$R/wrote/out.txt\"}" >/dev/null
mkdir -p "$R/wrote"; echo x > "$R/wrote/out.txt"
hook post Write "{\"file_path\":\"$R/wrote/out.txt\"}"
o="$(python3 -I "$HELPER" purge)"
contains "purge reports a fresh Write entry (parallel subagents)" "refused $R/wrote: reported, not deleted: changed in the last" "$o"
check "fresh entry kept by plain purge" yes "$(exists "$R/wrote")"
contains "purge only lists command-evidence entries (M1)" "listed $R/scratch-run: recorded from a Bash call (command evidence)" "$o"
o="$(python3 -I "$HELPER" purge --now)"
contains "purge --now removes the Write entry" "removed $R/wrote" "$o"
contains "purge lists window-only entry" "listed $R/anon1" "$o"
check "window-only entry kept by purge" yes "$(exists "$R/anon1")"
check "command-evidence entry kept by purge" yes "$(exists "$R/scratch-run")"

# --- 10. session TMPDIR, item-close, sweep -----------------------------------------
ENVF="$TMP/envfile"; : > "$ENVF"
printf '{"session_id":"sess-a","cwd":"%s","source":"startup"}' "$R" | CLAUDE_ENV_FILE="$ENVF" python3 -I "$LEDGER" session-start >/dev/null
contains "TMPDIR exported" "export TMPDIR='$CREDO_TMP_BASE/sess-a'" "$(cat "$ENVF")"
contains "helper exported" "export CREDO_CLEANUP=" "$(cat "$ENVF")"
check "session tmp exists" yes "$(exists "$CREDO_TMP_BASE/sess-a")"
check "session tmp base is private" 700 "$(stat -c %a "$CREDO_TMP_BASE")"
ST="$CREDO_TMP_BASE/sess-a"
mkdir "$ST/old" "$ST/fresh"; echo x > "$ST/old/f"
python3 -I "$HELPER" item-close >/dev/null
check "item-close keeps a fresh entry" yes "$(exists "$ST/fresh")"
CREDO_CLEANUP_IDLE_MINUTES=0 python3 -I "$HELPER" item-close >/dev/null
check "item-close removes an idle own entry" no "$(exists "$ST/old")"
check "item-close keeps the dir" yes "$(exists "$ST")"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
printf '{"pid":%s,"sessionId":"sess-a"}' "$$" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
DEAD="$CREDO_TMP_BASE/11111111-2222-3333-4444-555555555555"
mkdir -p "$DEAD/x"; echo y > "$DEAD/x/f"
touch -d '1 hour ago' "$DEAD"
CREDO_CLEANUP_IDLE_MINUTES=0 python3 -I "$HELPER" sweep >/dev/null
check "sweep removes a dead session tmp" no "$(exists "$DEAD")"
check "sweep keeps the live session tmp" yes "$(exists "$ST")"
mkdir "$TMP/scratch/sess-a/scratchpad/rel-clone"
o="$(rm_own "$TMP/scratch/sess-a/scratchpad/rel-clone")"
contains "scratchpad child is session-bound" "removed $TMP/scratch/sess-a/scratchpad/rel-clone" "$o"

# --- 11. worktrees: .credo guard, rescue, unmerged never removed ----------------------
M="$TMP/repo"
git init -q -b main "$M"
mkdir -p "$M/.credo/items"; echo "same" > "$M/.credo/items/a.md"; echo "main" > "$M/.credo/items/c.md"
printf '.credo/\n' > "$M/.gitignore"
git -C "$M" add .gitignore && git -C "$M" commit -q -m init
git -C "$M" worktree add -q -b wt/un "$TMP/repo-worktrees/un"
W="$TMP/repo-worktrees/un"
echo work > "$W/f.txt"; git -C "$W" add f.txt; git -C "$W" commit -q -m unique
mkdir -p "$W/.credo/items"; echo "same" > "$W/.credo/items/a.md"; echo "new" > "$W/.credo/items/b.md"; echo "other" > "$W/.credo/items/c.md"
o="$(printf '{"session_id":"sess-a","tool_name":"Write","tool_use_id":"tuW","cwd":"%s","tool_input":{"file_path":"%s/.credo/items/d.md"}}' "$W" "$W" | python3 -I "$LEDGER" pre)"
contains "Write into real worktree .credo denied" '"permissionDecision": "deny"' "$o"
contains "deny names the main path" "$M/.credo/items/d.md" "$o"
o="$(printf '{"session_id":"sess-a","tool_name":"Bash","tool_use_id":"tuB","cwd":"%s","tool_input":{"command":"echo x > .credo/items/e.md"}}' "$W" | python3 -I "$LEDGER" pre)"
contains "Bash redirect into worktree .credo denied" '"permissionDecision": "deny"' "$o"
o="$(python3 -I "$HELPER" rescue-credo "$W")"; rc=$?
contains "stray file rescued" "rescued .credo/items/b.md" "$o"
contains "identical file same" "same .credo/items/a.md" "$o"
contains "differing file conflict" "conflict .credo/items/c.md" "$o"
check "conflict exit code" 3 "$rc"
check "rescued file in main" "new" "$(cat "$M/.credo/items/b.md")"
check "main file not overwritten" "main" "$(cat "$M/.credo/items/c.md")"
o="$(bash "$WTC" --details "$M" 2>/dev/null)"
contains "unmerged reported with content" "unique_commits=1" "$o"
check "unmerged worktree never removed" yes "$(exists "$W/f.txt")"
run_call "git -C $M worktree add -q -b wt/two $TMP/roots/t/wt2"
o="$(rm_own "$R/wt2")"
contains "linked worktree refused" "linked git worktree" "$o"
check "linked worktree kept" yes "$(exists "$R/wt2/.git")"

# --- 12. Playwright prune ---------------------------------------------------------------
PC="$TMP/pwcache"; S="$TMP/pwsearch"
mkdir -p "$PC"/{chromium-1100,chromium-1200,chromium_headless_shell-1200,ffmpeg-1010,firefox-999,mcp-chrome-abc,webkit-2000} "$PC/.links"
mkdir -p "$S/proj/node_modules/playwright-core" "$S/proj2/node_modules/.pnpm/playwright-core@1.0.0/node_modules/playwright-core"
cat > "$S/proj/node_modules/playwright-core/browsers.json" <<'EOF'
{"browsers":[{"name":"chromium","revision":"1200"},{"name":"chromium-headless-shell","revision":"1200"},{"name":"ffmpeg","revision":"1010"}]}
EOF
cat > "$S/proj2/node_modules/.pnpm/playwright-core@1.0.0/node_modules/playwright-core/browsers.json" <<'EOF'
{"browsers":[{"name":"webkit","revision":"1999","revisionOverrides":{"mac12":"2000"}}]}
EOF
touch -d '1 day ago' "$PC"/*
o="$(python3 -I "$HELPER" playwright-prune --cache "$PC" --search "$S")"
check "unreferenced chromium removed" no "$(exists "$PC/chromium-1100")"
check "unreferenced firefox removed" no "$(exists "$PC/firefox-999")"
check "referenced chromium kept" yes "$(exists "$PC/chromium-1200")"
check "referenced headless shell kept" yes "$(exists "$PC/chromium_headless_shell-1200")"
check "referenced ffmpeg kept" yes "$(exists "$PC/ffmpeg-1010")"
check "revision override kept (pnpm path)" yes "$(exists "$PC/webkit-2000")"
check "mcp-chrome never touched" yes "$(exists "$PC/mcp-chrome-abc")"
check ".links never touched" yes "$(exists "$PC/.links")"
mkdir "$PC/chromium-1000"; touch -d '1 day ago' "$PC/chromium-1000"
o="$(python3 -I "$HELPER" playwright-prune --cache "$PC" --search "$TMP/empty-search")"
contains "no installation found: nothing pruned" "nothing is pruned blind" "$o"
check "kept when no installation found" yes "$(exists "$PC/chromium-1000")"
check "helper never runs an installer" 0 "$(cat "$HELPER" "$LEDGER" | grep -c -E '"(npx|npm|pnpm|yarn|pip|pip3|apt|apt-get)"')"

# --- 14. review regressions -------------------------------------------------------------
export CREDO_CLEANUP_IDLE_MINUTES=0
# B1: pre-existing data moved into the session TMPDIR, then item-close / own-rm
mv "$HOME/userdata" "$ST/"
python3 -I "$HELPER" item-close >/dev/null
check "B1 item-close keeps data moved into TMPDIR" yes "$(exists "$ST/userdata/thesis.txt")"
o="$(rm_own "$ST/userdata")"
contains "B1 own-rm refuses data moved into TMPDIR" "pre-existing data moved in" "$o"
# B1: pre-existing tree moved into an own ledger dir
run_call "mkdir $R/bk"
mv "$HOME/proj/config" "$R/bk/"
o="$(rm_own "$R/bk")"
contains "B1 own dir holding moved-in data refused" "pre-existing data moved in" "$o"
o="$(rm_own "$R/bk/config")"
contains "B1 moved-in subdir refused" "refused $R/bk/config" "$o"
check "B1 moved-in data kept" yes "$(exists "$R/bk/config/app.yml")"
# B1: content with a modification time older than its birth (cross-fs mv, tar x, cp -p)
run_call "mkdir $R/extracted"
echo old > "$R/extracted/f"; touch -d '3 days ago' "$R/extracted/f"
o="$(rm_own "$R/extracted")"
contains "B1 mtime older than birth refused" "modification time older than its birth" "$o"
# B2: dead session TMPDIR holding a linked worktree with unmerged work
mkdir -p "$TMP/repo2" && git -C "$TMP/repo2" init -q && git -C "$TMP/repo2" commit -q --allow-empty -m init
DEAD2="$CREDO_TMP_BASE/22222222-2222-3333-4444-555555555555"
mkdir -p "$DEAD2" "$DEAD2/junk"
git -C "$TMP/repo2" worktree add -q -b wip "$DEAD2/wt"
echo work > "$DEAD2/wt/new.txt"; git -C "$DEAD2/wt" add new.txt; git -C "$DEAD2/wt" commit -q -m wip
touch -d '1 hour ago' "$DEAD2"
o="$(python3 -I "$HELPER" sweep)"
check "B2 sweep keeps a linked worktree" yes "$(exists "$DEAD2/wt/new.txt")"
contains "B2 sweep reports it" "kept $DEAD2/wt" "$o"
check "B2 sweep still removes own junk next to it" no "$(exists "$DEAD2/junk")"
# minor: a tmp base that is no private dir is never swept; ordinary names are never swept
mkdir -p "$TMP/fakebase/Documents" "$TMP/fakebase/33333333-2222-3333-4444-555555555555"
echo x > "$TMP/fakebase/Documents/a"
o="$(CREDO_TMP_BASE="$TMP/fakebase" python3 -I "$HELPER" sweep)"
contains "sweep refuses a non-private base" "not a private dir" "$o"
chmod 700 "$TMP/fakebase"
touch -d '1 hour ago' "$TMP/fakebase/Documents"
CREDO_TMP_BASE="$TMP/fakebase" python3 -I "$HELPER" sweep >/dev/null
check "sweep never touches non-session names" yes "$(exists "$TMP/fakebase/Documents/a")"
ln -s "$TMP/fakebase" "$TMP/linkbase"
o="$(CREDO_TMP_BASE="$TMP/linkbase" python3 -I "$HELPER" sweep)"
contains "sweep refuses a symlinked base" "not a private dir" "$o"
# M1: a foreign file whose name is a substring / plain word of the command
run_call "npm test || true" 2>/dev/null
mkdir -p "$R/t2"
N=$((N + 1)); cj='{"command":"npm run test"}'
printf '{"session_id":"sess-a","tool_name":"Bash","tool_use_id":"tu%s","cwd":"/elsewhere","tool_input":%s}' "$N" "$cj" | python3 -I "$LEDGER" pre
echo foreign > "$R/test"
printf '{"session_id":"sess-a","tool_name":"Bash","tool_use_id":"tu%s","cwd":"/elsewhere","tool_input":%s}' "$N" "$cj" | python3 -I "$LEDGER" post
contains "M1 a plain word is no command evidence" '"evidence": "window"' "$(grep "\"$R/test\"" "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
o="$(python3 -I "$HELPER" purge --now)"
check "M1 purge keeps the foreign file" yes "$(exists "$R/test")"
N=$((N + 1))
cj="$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "cd $R && mkdir rel1")"
printf '{"session_id":"sess-a","tool_name":"Bash","tool_use_id":"tu%s","cwd":"/elsewhere","tool_input":%s}' "$N" "$cj" | python3 -I "$LEDGER" pre
mkdir "$R/rel1"
printf '{"session_id":"sess-a","tool_name":"Bash","tool_use_id":"tu%s","cwd":"/elsewhere","tool_input":%s}' "$N" "$cj" | python3 -I "$LEDGER" post
contains "M1 relative token resolves only against the call cwd" '"evidence": "window"' "$(grep "\"$R/rel1\"" "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
# M2: --except of a result inside a TMPDIR subdir
mkdir -p "$ST/build/result"; echo r > "$ST/build/result/model.bin"
o="$(python3 -I "$HELPER" purge --now --except "$ST/build/result")"
check "M2 result inside a TMPDIR subdir survives purge" yes "$(exists "$ST/build/result/model.bin")"
contains "M2 parent of the result is listed" "listed $ST/build: excepted" "$o"
# M3: a path swapped for a symlink after the check is not followed
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
contains "M3 swapped path refused" "replaced since the check" "$o"
check "M3 symlink target untouched" yes "$(exists "$TMP/victim/keep.txt")"
o="$(python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import credo_cleanup_lib as L
p = sys.argv[2]
os.makedirs(p + "/sub")
st = os.lstat(p)
os.rename(p, p + ".moved")
os.symlink(sys.argv[3], p)
print(L.delete_path(sys.argv[2] + "/sub", os.lstat(p + ".moved/sub"), False))
' "$SCRIPT_DIR" "$ST/swap2" "$TMP/victim")"
contains "M3 swapped parent component refused" "without following links" "$o"
check "M3 victim still there" yes "$(exists "$TMP/victim/keep.txt")"
# M4: deep fresh change, socket, process inside -> item-close keeps
unset CREDO_CLEANUP_IDLE_MINUTES
mkdir -p "$ST/deep/a/b"; echo live > "$ST/deep/a/b/work.txt"
CREDO_CLEANUP_IDLE_MINUTES=1 python3 -I "$HELPER" item-close >/dev/null
check "M4 deep fresh change keeps the entry" yes "$(exists "$ST/deep/a/b/work.txt")"
export CREDO_CLEANUP_IDLE_MINUTES=0
mkdir -p "$ST/sockdir"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$ST/sockdir/daemon.sock"
python3 -I "$HELPER" item-close >/dev/null
check "M4 dir with a socket kept" yes "$(exists "$ST/sockdir/daemon.sock")"
mkdir -p "$ST/busy"
( cd "$ST/busy" && exec sleep 30 ) &
BUSY=$!
sleep 0.3
python3 -I "$HELPER" item-close >/dev/null
check "M4 dir with a live process inside kept" yes "$(exists "$ST/busy")"
kill "$BUSY" 2>/dev/null; wait "$BUSY" 2>/dev/null
# M5: a mount point (also same-device bind mount) at or below the target refuses
MI="$TMP/mountinfo"
printf '36 25 8:1 / / rw - ext4 /dev/sda rw\n90 36 8:1 /x %s rw - ext4 /dev/sda rw\n' "$ST/bound/inner" > "$MI"
mkdir -p "$ST/bound/inner"
o="$(CREDO_CLEANUP_MOUNTINFO="$MI" rm_own "$ST/bound")"
contains "M5 bind mount below the target refused" "mount point at or below it" "$o"
check "M5 bound dir kept" yes "$(exists "$ST/bound/inner")"
mkdir -p "$HOME/gdrive"
printf '36 25 8:1 / / rw - ext4 /dev/sda rw\n91 36 0:99 / %s rw - fuse.rclone gd rw\n' "$HOME/gdrive" > "$MI"
CREDO_CLEANUP_MOUNTINFO="$MI" run_call "mkdir $HOME/gdrive/newdir"
check "home scan never enters a mount (FUSE)" 0 "$(grep -c 'gdrive' "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl")"
# minor: inode reuse (same dev+ino, other birth time) refused
echo user > "$R/reuse.log"
python3 -I -c '
import json, os, sys
p = sys.argv[1]; st = os.lstat(p)
rec = {"event": "record", "path": p, "dev": st.st_dev, "ino": st.st_ino, "type": "file",
       "btime": 1.0, "evidence": "command", "root_kind": "temp"}
open(sys.argv[2], "a").write(json.dumps(rec) + "\n")
' "$R/reuse.log" "$CREDO_CLEANUP_STATE/ledger/sess-a.jsonl"
o="$(rm_own "$R/reuse.log")"
contains "inode reuse (other birth time) refused" "replaced since it was recorded" "$o"
# minor: git error other than "not a git repository" refuses (fails closed)
run_call "git init -q $R/clone1 && echo a > $R/clone1/a.txt"
git -C "$R/clone1" add a.txt; echo garbage > "$R/clone1/.git/index"
o="$(rm_own "$R/clone1/a.txt")"
contains "git error fails closed" "tracked by git" "$o"
# minor: Playwright search with an unreadable dir prunes nothing
PC2="$TMP/pwcache2"; S2="$TMP/pwsearch2"
mkdir -p "$PC2/chromium-1100" "$S2/proj/node_modules/playwright-core" "$S2/locked"
echo '{"browsers":[{"name":"chromium","revision":"1200"}]}' > "$S2/proj/node_modules/playwright-core/browsers.json"
touch -d '1 day ago' "$PC2/chromium-1100"; chmod 000 "$S2/locked"
o="$(python3 -I "$HELPER" playwright-prune --cache "$PC2" --search "$S2")"
chmod 700 "$S2/locked"
contains "playwright: unreadable dir = incomplete" "nothing is pruned on an incomplete search" "$o"
check "playwright: nothing pruned when incomplete" yes "$(exists "$PC2/chromium-1100")"
# minor: rescue-credo never resurrects an item that lives under another status folder
mkdir -p "$M/.credo/items/2_done"; echo done > "$M/.credo/items/2_done/77-x.md"
mkdir -p "$W/.credo/items/1_todo/2_go"; echo stale > "$W/.credo/items/1_todo/2_go/77-x.md"
o="$(python3 -I "$HELPER" rescue-credo "$W")"
contains "rescue: item under another status folder reported" "conflict .credo/items/1_todo/2_go/77-x.md: the item lives under another status folder" "$o"
check "rescue: stale status copy not created" no "$(exists "$M/.credo/items/1_todo/2_go/77-x.md")"
# minor: ledger guard catches cd + relative forms
o="$(hook pre Bash '{"command":"cd ~/.local/state/credo && echo {} >> cleanup/ledger/sess-a.jsonl"}')"
contains "guard: cd + relative ledger write denied" '"permissionDecision": "deny"' "$o"
unset CREDO_CLEANUP_IDLE_MINUTES

# --- 13. disabled switch ------------------------------------------------------------------
o="$(CREDO_LEDGER=0 hook pre Write "{\"file_path\":\"$CREDO_CLEANUP_STATE/ledger/x.jsonl\"}")"
check "CREDO_LEDGER=0 turns the hooks off" "" "$o"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

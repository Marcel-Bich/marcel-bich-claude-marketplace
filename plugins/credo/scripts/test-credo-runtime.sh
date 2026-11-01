#!/bin/bash
# Tests for credo_runtime.py - restart survival: scratchpad keep, the restart list of
# background services, tmux pane references, the post-restart check - and their wiring
# into credo-self-restart.py, hooks/credo-session-start.sh and the compact-plus skill.
#
# NOTHING real runs. tmux, systemd-run, systemctl, nohup and ps are FAKE shims that record
# their calls; the real tmux is not on the restricted PATH at all, so no real pane can be
# reached and no key can be sent. No real service is started. Temp project dirs and an
# invented session id only.
#
# It checks:
#   - keep - copies helper scripts and pending lists from a scratchpad into
#     .credo/process/runtime/<session>/scratchpad/, keeps the exec bit, skips symlinks,
#     writes manifest.json (sha256, skipped reasons, pending_restore), never deletes,
#     size cap, missing scratchpad / missing .credo / bad session id
#   - service add/start/status - name validation, per-service script in .credo/process
#     /runtime/services/, tmux when tmux is used (TMUX set or a server), systemd-run
#     --user when systemd is booted, nohup otherwise, start --missing starts only the
#     services that are not running, a zombie nohup child counts as not running
#   - pane add/resolve/status - the pane is resolved by its session:window.pane name, the
#     stored %ID only tells whether it still matches, purpose as a title fallback, SSH
#     liveness via ps -t, and no send-keys ever
#   - check - silent when nothing is registered, reports services not running, SSH panes to
#     reconnect as session:window.pane (purpose, last %ID), the one-shot scratchpad pointer
#   - SessionStart hook: the check is appended on startup/resume only, silent otherwise
#   - self-restart - default scratchpad path, save_scratchpad, --scratchpad accepted
#   - compact-plus skill and self-restart command document the rules (glob, no pinned path)
#
# Usage: bash test-credo-runtime.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="$HERE/credo_runtime.py"
SR="$HERE/credo-self-restart.py"
HOOK="$HERE/../hooks/credo-session-start.sh"
SKILL="$HERE/../skills/compact-plus/SKILL.md"
CMD_SR="$HERE/../commands/self-restart.md"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$RT" ]; then echo "FAIL: $RT missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/crt.XXXXXX")" || exit 1
[ -n "$TMP" ] || exit 1
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
ok() { # name rc (0 = pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}

SID="99999999-8888-7777-6666-555555555555"
SID2="77777777-6666-5555-4444-333333333333"
SID3="66666666-5555-4444-3333-222222222222"

# --- fake binaries (shims) and restricted PATH --------------------------------------
STATE="$TMP/state"; mkdir -p "$STATE"
SHIMS="$TMP/shims"; mkdir -p "$SHIMS"
export FAKE_STATE="$STATE" FAKE_LOG="$TMP/tmux.log" FAKE_SD_LOG="$TMP/systemd.log" \
    FAKE_NOHUP_LOG="$TMP/nohup.log" FAKE_PS_LOG="$TMP/ps.log"
: > "$FAKE_LOG"; : > "$FAKE_SD_LOG"; : > "$FAKE_NOHUP_LOG"; : > "$FAKE_PS_LOG"

cat > "$SHIMS/tmux" <<'SHIM'
#!/bin/bash
printf 'tmux %s\n' "$*" >> "$FAKE_LOG"
S="$FAKE_STATE"
case "$1" in
  -V) [ -f "$S/tmux-broken" ] && exit 1; echo "tmux 3.4"; exit 0 ;;
  list-sessions) [ -f "$S/no-server" ] && exit 1; exit 0 ;;
  has-session) [ -f "$S/no-server" ] && exit 1; grep -qxF -- "${3#=}" "$S/sessions" 2>/dev/null ;;
  new-session)
    name=""; prev=""
    for a in "$@"; do [ "$prev" = "-s" ] && name="$a"; prev="$a"; done
    printf '%s\n' "$name" >> "$S/sessions"; exit 0 ;;
  display-message)
    [ -f "$S/no-server" ] && exit 1
    target=""; prev=""; fmt=""
    for a in "$@"; do [ "$prev" = "-t" ] && target="$a"; prev="$a"; fmt="$a"; done
    col=2; case "$fmt" in *pane_tty*) col=3 ;; esac
    val="$(awk -F'\t' -v t="$target" -v c="$col" '$1==t {print $c; exit}' "$S/panes" 2>/dev/null)"
    [ -n "$val" ] || exit 1
    echo "$val"; exit 0 ;;
  list-panes)
    [ -f "$S/no-server" ] && exit 1
    cut -f1,2,4 "$S/panes" 2>/dev/null; exit 0 ;;
  send-keys) echo "SEND-KEYS CALLED" >> "$FAKE_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
SHIM
cat > "$SHIMS/systemd-run" <<'SHIM'
#!/bin/bash
printf 'systemd-run %s\n' "$*" >> "$FAKE_SD_LOG"; exit 0
SHIM
cat > "$SHIMS/systemctl" <<'SHIM'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "$FAKE_SD_LOG"
for last; do :; done
case " $* " in *" is-active "*) grep -qxF -- "$last" "$FAKE_STATE/active-units" 2>/dev/null; exit $? ;; esac
exit 0
SHIM
cat > "$SHIMS/nohup" <<'SHIM'
#!/bin/bash
printf 'nohup %s\n' "$*" >> "$FAKE_NOHUP_LOG"; exit 0
SHIM
cat > "$SHIMS/ps" <<'SHIM'
#!/bin/bash
printf 'ps %s\n' "$*" >> "$FAKE_PS_LOG"
cat "$FAKE_STATE/ps-out" 2>/dev/null; exit 0
SHIM
chmod +x "$SHIMS"/*

BASE="$TMP/base"; mkdir -p "$BASE"
for t in python3 bash sh env dirname basename cat cmp mkdir mv cp rm ln ls sleep kill find jq printf tr sed grep awk head tail sort date id readlink touch chmod wc cut stat seq; do
    p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -s "$p" "$BASE/$t"
done
FB_ALL="$TMP/fb-all"; FB_NOTMUX="$TMP/fb-notmux"; mkdir -p "$FB_ALL" "$FB_NOTMUX"
for n in tmux systemd-run systemctl nohup ps; do ln -s "$SHIMS/$n" "$FB_ALL/$n"; done
for n in systemctl nohup ps; do ln -s "$SHIMS/$n" "$FB_NOTMUX/$n"; done
SD_BOOTED="$TMP/sd-booted"; mkdir -p "$SD_BOOTED"
NO_SD="$TMP/no-sd"
tmux_calls() { grep -c -- "$1" "$FAKE_LOG" 2>/dev/null || true; }

# --- fixtures ------------------------------------------------------------------------
PROJ="$TMP/proj"; mkdir -p "$PROJ/.credo"
SCR="$TMP/scratch"; mkdir -p "$SCR/sub"
printf '#!/bin/bash\necho helper\n' > "$SCR/helper.sh"; chmod +x "$SCR/helper.sh"
printf 'case A\ncase B\n' > "$SCR/audit-cases.txt"
printf 'rule one\n' > "$SCR/rules.md"
printf 'deep\n' > "$SCR/sub/deep.txt"
printf 'outside\n' > "$TMP/outside.txt"
ln -s "$TMP/outside.txt" "$SCR/link.txt"
RUN="$PROJ/.credo/process/runtime/$SID"
SVC="$PROJ/.credo/process/runtime/services"

# === keep ============================================================================
out="$("$PY" "$RT" keep --root "$PROJ" --session "$SID" --scratchpad "$SCR" 2>&1)"; rc=$?
check "keep: rc 0" 0 "$rc"
cmp -s "$SCR/audit-cases.txt" "$RUN/scratchpad/audit-cases.txt"; ok "keep: collection file copied" "$?"
cmp -s "$SCR/rules.md" "$RUN/scratchpad/rules.md"; ok "keep: rule list copied" "$?"
cmp -s "$SCR/sub/deep.txt" "$RUN/scratchpad/sub/deep.txt"; ok "keep: subdirectory copied" "$?"
cmp -s "$SCR/helper.sh" "$RUN/scratchpad/helper.sh"; ok "keep: helper script copied" "$?"
[ -x "$RUN/scratchpad/helper.sh" ]; ok "keep: exec bit kept" "$?"
[ ! -e "$RUN/scratchpad/link.txt" ] && [ ! -L "$RUN/scratchpad/link.txt" ]; ok "keep: symlink not copied" "$?"
MAN="$RUN/manifest.json"
check "manifest: 4 regular files saved" 4 \
    "$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["files"]))' "$MAN" 2>/dev/null)"
check "manifest: symlink listed as skipped" symlink \
    "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next((s["reason"] for s in d["skipped"] if s["path"]=="link.txt"),"-"))' "$MAN" 2>/dev/null)"
check "manifest: every entry has a sha256" True \
    "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(all(len(f["sha256"])==64 for f in d["files"]))' "$MAN" 2>/dev/null)"
check "manifest: pending_restore set" True \
    "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_restore"])' "$MAN" 2>/dev/null)"
printf 'leftover\n' > "$RUN/scratchpad/old-leftover.txt"
printf 'rule two\n' > "$SCR/rules.md"
"$PY" "$RT" keep --root "$PROJ" --session "$SID" --scratchpad "$SCR" >/dev/null 2>&1
cmp -s "$SCR/rules.md" "$RUN/scratchpad/rules.md"; ok "keep: rerun refreshes changed file" "$?"
[ -f "$RUN/scratchpad/old-leftover.txt" ]; ok "keep: never deletes files already in the snapshot" "$?"
printf '0123456789' > "$SCR/big.bin"
CREDO_RUNTIME_MAX_FILE_BYTES=5 "$PY" "$RT" keep --root "$PROJ" --session "$SID2" --scratchpad "$SCR" >/dev/null 2>&1
[ ! -e "$PROJ/.credo/process/runtime/$SID2/scratchpad/big.bin" ]; ok "keep: file over the size cap not copied" "$?"
check "keep: size cap reason recorded" 1 \
    "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for s in d["skipped"] if s["path"]=="big.bin" and "larger" in s["reason"]))' "$PROJ/.credo/process/runtime/$SID2/manifest.json" 2>/dev/null)"
out="$("$PY" "$RT" keep --root "$PROJ" --session "$SID3" --scratchpad "$TMP/does-not-exist" 2>&1)"; rc=$?
check "keep: missing scratchpad rc 0" 0 "$rc"
case "$out" in *"no scratchpad"*) ok "keep: missing scratchpad reported" 0 ;; *) ok "keep: missing scratchpad reported" 1 ;; esac
[ ! -d "$PROJ/.credo/process/runtime/$SID3" ]; ok "keep: missing scratchpad creates nothing" "$?"
BARE="$TMP/bare"; mkdir -p "$BARE"
out="$("$PY" "$RT" keep --root "$BARE" --session "$SID" --scratchpad "$SCR" 2>&1)"; rc=$?
check "keep: no .credo rc 0" 0 "$rc"
case "$out" in *"no .credo"*) ok "keep: no .credo reported" 0 ;; *) ok "keep: no .credo reported" 1 ;; esac
[ ! -e "$BARE/.credo" ]; ok "keep: no .credo created" "$?"
"$PY" "$RT" keep --root "$PROJ" --session "../escape" --scratchpad "$SCR" >/dev/null 2>&1
check "keep: invalid session id rc 1" 1 "$?"

# === service: add / start / status ===================================================
PATH_ALL="$FB_ALL:$BASE"
out="$(env -u TMUX PATH="$PATH_ALL" "$PY" "$RT" service add 'bad/name' --cmd 'true' --root "$PROJ" 2>&1)"; rc=$?
check "service add: bad name rc 1" 1 "$rc"
env -u TMUX PATH="$PATH_ALL" "$PY" "$RT" service add keepalive --cmd 'sleep 3600' --cwd "$TMP" --root "$PROJ" >/dev/null 2>&1
check "service add: rc 0" 0 "$?"
grep -q 'sleep 3600' "$SVC/keepalive.sh" 2>/dev/null; ok "service add: script holds the command" "$?"
env -u TMUX PATH="$PATH_ALL" "$PY" "$RT" service add devsrv --cmd 'python3 -m http.server 8765' --cwd "$TMP" --root "$PROJ" >/dev/null 2>&1
"$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print([s["name"] for s in d["services"]])' "$PROJ/.credo/process/runtime/services.json" 2>/dev/null \
    | grep -q "keepalive" ; ok "service add: registry lists the service" "$?"
: > "$FAKE_LOG"
TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" service start keepalive --root "$PROJ" >/dev/null 2>&1
check "service start (tmux used): rc 0" 0 "$?"
grep -qF "new-session -d -s credo-svc-keepalive" "$FAKE_LOG"; ok "service start: detached tmux session per service" "$?"
grep -qF "bash $SVC/keepalive.sh" "$FAKE_LOG"; ok "service start: tmux runs the durable script" "$?"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" service status --root "$PROJ" 2>&1)"
case "$out" in *"keepalive: running (tmux)"*) ok "service status: keepalive running" 0 ;; *) ok "service status: keepalive running" 1 ;; esac
case "$out" in *"devsrv: NOT running (never started)"*) ok "service status: never started reported" 0 ;; *) ok "service status: never started reported" 1 ;; esac
TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" service start --missing --root "$PROJ" >/dev/null 2>&1
check "start --missing: keepalive not started twice" 1 "$(tmux_calls 'new-session -d -s credo-svc-keepalive')"
check "start --missing: devsrv started" 1 "$(tmux_calls 'new-session -d -s credo-svc-devsrv')"
printf 'credo-svc-devsrv\n' > "$STATE/sessions"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" service status --root "$PROJ" 2>&1)"
case "$out" in *"keepalive: NOT running (tmux)"*) ok "service status: vanished session is NOT running" 0 ;; *) ok "service status: vanished session is NOT running" 1 ;; esac
env -u TMUX PATH="$PATH_ALL" "$PY" "$RT" service add syssvc --cmd 'sleep 1' --cwd "$TMP" --root "$PROJ" >/dev/null 2>&1
: > "$FAKE_SD_LOG"; touch "$STATE/no-server"
env -u TMUX CREDO_RUNTIME_SD_BOOTED_DIR="$SD_BOOTED" PATH="$PATH_ALL" "$PY" "$RT" service start syssvc --root "$PROJ" >/dev/null 2>&1
check "service start (no tmux, systemd): rc 0" 0 "$?"
grep -qF -- "--unit=credo-svc-syssvc" "$FAKE_SD_LOG"; ok "service start: systemd-run --user unit" "$?"
grep -qF -- "--user" "$FAKE_SD_LOG"; ok "service start: systemd-run is --user" "$?"
echo "credo-svc-syssvc.service" > "$STATE/active-units"
out="$(env -u TMUX CREDO_RUNTIME_SD_BOOTED_DIR="$SD_BOOTED" PATH="$PATH_ALL" "$PY" "$RT" service status --root "$PROJ" 2>&1)"
case "$out" in *"syssvc: running (systemd)"*) ok "service status: systemd unit active" 0 ;; *) ok "service status: systemd unit active" 1 ;; esac
env -u TMUX PATH="$FB_NOTMUX:$BASE" CREDO_RUNTIME_SD_BOOTED_DIR="$NO_SD" "$PY" "$RT" service add nohupsvc --cmd 'sleep 1' --cwd "$TMP" --root "$PROJ" >/dev/null 2>&1
: > "$FAKE_NOHUP_LOG"
env -u TMUX PATH="$FB_NOTMUX:$BASE" CREDO_RUNTIME_SD_BOOTED_DIR="$NO_SD" "$PY" "$RT" service start nohupsvc --root "$PROJ" >/dev/null 2>&1
check "service start (nohup): rc 0" 0 "$?"
grep -qF "bash $SVC/nohupsvc.sh" "$FAKE_NOHUP_LOG"; ok "service start: nohup fallback" "$?"
out="$(env -u TMUX PATH="$FB_NOTMUX:$BASE" CREDO_RUNTIME_SD_BOOTED_DIR="$NO_SD" "$PY" "$RT" service status --root "$PROJ" 2>&1)"
case "$out" in *"nohupsvc: NOT running (nohup)"*) ok "service status: finished nohup child is not running" 0 ;; *) ok "service status: finished nohup child is not running" 1 ;; esac

# === pane: add / resolve / status ====================================================
rm -f "$STATE/no-server"
printf 'work:1.2\t%%14\t/dev/pts/7\tstage ssh\n' > "$STATE/panes"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" pane add work:1.2 --purpose "stage ssh" --ssh --root "$PROJ" 2>&1)"; rc=$?
check "pane add: rc 0" 0 "$rc"
check "pane add: last %ID stored" "%14" \
    "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["panes"][0]["last_id"])' "$PROJ/.credo/process/runtime/panes.json" 2>/dev/null)"
check "pane add: ssh flag stored" True \
    "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["panes"][0]["ssh"])' "$PROJ/.credo/process/runtime/panes.json" 2>/dev/null)"
TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" pane add nocolon --purpose x --root "$PROJ" >/dev/null 2>&1
check "pane add: target without session:window.pane rc 1" 1 "$?"
printf 'work:1.2\t%%12\t/dev/pts/7\tstage ssh\n' > "$STATE/panes"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" pane resolve work:1.2 --root "$PROJ" 2>&1)"; rc=$?
check "pane resolve: rc 0" 0 "$rc"
check "pane resolve: pane id comes from the name (now %12)" "%12" \
    "$(echo "$out" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["pane_id"])')"
check "pane resolve: stored id no longer matches" False \
    "$(echo "$out" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["id_matches"])')"
printf 'moved:3.1\t%%12\t/dev/pts/7\tstage ssh\n' > "$STATE/panes"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" pane resolve work:1.2 --root "$PROJ" 2>&1)"; rc=$?
check "pane resolve: found by purpose when the name is gone" "purpose" \
    "$(echo "$out" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["found_by"])' 2>/dev/null)"
TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" pane resolve missing:9.9 --root "$PROJ" >/dev/null 2>&1
check "pane resolve: unknown target rc 1" 1 "$?"
printf 'work:1.2\t%%12\t/dev/pts/7\tstage ssh\n' > "$STATE/panes"
echo bash > "$STATE/ps-out"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" pane status --root "$PROJ" 2>&1)"
case "$out" in *"work:1.2"*"ssh: NOT running"*) ok "pane status: no ssh process on the pane tty" 0 ;; *) ok "pane status: no ssh process on the pane tty" 1 ;; esac
printf 'bash\nssh.exe\n' > "$STATE/ps-out"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" pane status --root "$PROJ" 2>&1)"
case "$out" in *"ssh: running"*) ok "pane status: ssh seen on the pane tty" 0 ;; *) ok "pane status: ssh seen on the pane tty" 1 ;; esac
grep -qF "ps -t pts/7" "$FAKE_PS_LOG"; ok "pane status: ps -t on the pane tty" "$?"

# === check (post-restart report) =====================================================
EMPTY="$TMP/empty"; mkdir -p "$EMPTY/.credo"
out="$(env -u TMUX PATH="$FB_NOTMUX:$BASE" "$PY" "$RT" check --root "$EMPTY" --session "$SID" 2>&1)"; rc=$?
check "check: nothing registered -> rc 0" 0 "$rc"
check "check: nothing registered -> silent" "" "$out"
touch "$STATE/no-server"; : > "$STATE/sessions"
out="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" check --root "$PROJ" --session "$SID" 2>&1)"
case "$out" in *"NOT running"*"keepalive"*"service start --missing"*) ok "check: services not running reported with the restart command" 0 ;; *) ok "check: services not running reported with the restart command" 1 ;; esac
case "$out" in *"reconnect"*"work:1.2 (stage ssh, last %14)"*) ok "check: SSH pane named session:window.pane (purpose, last %ID)" 0 ;; *) ok "check: SSH pane named session:window.pane (purpose, last %ID)" 1 ;; esac
case "$out" in *"Scratchpad helpers saved before the restart"*"manifest.json"*) ok "check: scratchpad pointer shown" 0 ;; *) ok "check: scratchpad pointer shown" 1 ;; esac
out2="$(TMUX=/fake/socket,1,0 PATH="$PATH_ALL" "$PY" "$RT" check --root "$PROJ" --session "$SID" 2>&1)"
case "$out2" in *"Scratchpad helpers saved"*) ok "check: scratchpad pointer is one-shot" 1 ;; *) ok "check: scratchpad pointer is one-shot" 0 ;; esac
check "check: pending_restore cleared" False \
    "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending_restore"])' "$MAN" 2>/dev/null)"
out="$(env -u TMUX PATH="$FB_NOTMUX:$BASE" "$PY" "$RT" check --root "$PROJ" --session "$SID" 2>&1)"
case "$out" in *"reconnect"*) ok "check: no tmux -> no SSH pane note" 1 ;; *) ok "check: no tmux -> no SSH pane note" 0 ;; esac
: > "$FAKE_LOG"; rm -f "$STATE/no-server"

# === SessionStart hook: post-restart check on startup/resume only ====================
HPROJ="$TMP/hookproj"; mkdir -p "$HPROJ/.credo/process/runtime"
printf '{"services":[{"name":"keepalive","cmd":"sleep 3600","script":"%s","method":"tmux","added":"2000-01-01T00:00:00+00:00"}]}\n' "$SVC/keepalive.sh" \
    > "$HPROJ/.credo/process/runtime/services.json"
MODES="$TMP/modes"; DEC="$TMP/decisions"; CFG="$TMP/cfg"; mkdir -p "$MODES" "$DEC" "$CFG"
hook_out() { # source
    printf '{"session_id": "%s", "source": "%s", "cwd": "%s"}' "$SID" "$1" "$HPROJ" \
        | ( cd "$HPROJ" && env -u TMUX -u CLAUDE_CODE_ENTRYPOINT PATH="$FB_NOTMUX:$BASE" \
            CLAUDE_CONFIG_DIR="$CFG" CREDO_SESSION_MODES_DIR="$MODES" CREDO_SESSION_DECISIONS_DIR="$DEC" \
            CREDO_SKIP_ENSURE=1 CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROFILE="$TMP/none-p" \
            CREDO_PROJECT="$TMP/none-q" bash "$HOOK" 2>/dev/null )
}
echo active > "$MODES/$SID"
out="$(hook_out startup | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
case "$out" in *"NOT running"*"keepalive"*) ok "hook startup: restart check appended" 0 ;; *) ok "hook startup: restart check appended" 1 ;; esac
out="$(hook_out resume | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
case "$out" in *"NOT running"*) ok "hook resume: restart check appended" 0 ;; *) ok "hook resume: restart check appended" 1 ;; esac
out="$(hook_out compact | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
case "$out" in *"NOT running"*) ok "hook compact: no restart check" 1 ;; *) ok "hook compact: no restart check" 0 ;; esac
out="$(printf '{"session_id": "%s", "source": "startup", "cwd": "%s"}' "$SID" "$BARE" \
    | ( cd "$BARE" && env -u TMUX PATH="$FB_NOTMUX:$BASE" CLAUDE_CONFIG_DIR="$CFG" CREDO_SESSION_MODES_DIR="$MODES" \
        CREDO_SESSION_DECISIONS_DIR="$DEC" CREDO_SKIP_ENSURE=1 CREDO_GLOBAL="$TMP/global.yaml" \
        CREDO_PROFILE="$TMP/none-p" CREDO_PROJECT="$TMP/none-q" bash "$HOOK" 2>/dev/null ))"
case "$out" in *"NOT running"*|*"Restart check"*) ok "hook: silent without a runtime registry" 1 ;; *) ok "hook: silent without a runtime registry" 0 ;; esac

# === self-restart wiring ==============================================================
SRIN="$TMP/sr-unit.py"
cat > "$SRIN" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("csr", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ.pop("CREDO_SCRATCHPAD_DIR", None)
d = m.default_scratchpad("/home/x/proj", "sid1")
print("default_path_ok", d.endswith("/-home-x-proj/sid1/scratchpad") and d.startswith("/tmp/claude-"))
os.environ["CREDO_SCRATCHPAD_DIR"] = "/fixture/override"
print("override_ok", m.default_scratchpad("/home/x/proj", "sid1") == "/fixture/override")
note = m.save_scratchpad({"session_id": sys.argv[3], "cwd": sys.argv[4]}, sys.argv[2])
print("saved_ok", os.path.isfile(os.path.join(sys.argv[4], ".credo", "process", "runtime", sys.argv[3], "manifest.json")), note != "")
PYEOF
PROJSR="$TMP/proj-sr"; mkdir -p "$PROJSR/.credo"
out="$("$PY" "$SRIN" "$SR" "$SCR" "$SID" "$PROJSR" 2>&1)"
case "$out" in *"default_path_ok True"*) ok "self-restart: default scratchpad path" 0 ;; *) ok "self-restart: default scratchpad path" 1 ;; esac
case "$out" in *"override_ok True"*) ok "self-restart: CREDO_SCRATCHPAD_DIR override" 0 ;; *) ok "self-restart: CREDO_SCRATCHPAD_DIR override" 1 ;; esac
case "$out" in *"saved_ok True True"*) ok "self-restart: save_scratchpad writes the snapshot" 0 ;; *) ok "self-restart: save_scratchpad writes the snapshot" 1 ;; esac
out="$(env -u CLAUDE_CODE_SESSION_ID -u CREDO_SELF_RESTART_SESSION_ID CREDO_SELF_RESTART_TARGET_PID=$$ \
    CREDO_SELF_RESTART_NTFY_URL=off CLAUDE_CONFIG_DIR="$CFG" PATH="$FB_NOTMUX:$BASE" \
    "$PY" "$SR" run --no-background-work --user-confirmed --scratchpad "$SCR" 2>&1)"
case "$out" in *"unrecognized arguments"*) ok "self-restart: --scratchpad is accepted" 1 ;; *) ok "self-restart: --scratchpad is accepted" 0 ;; esac

# === docs: compact-plus and self-restart rules ========================================
grep -qF 'credo_runtime.py" keep' "$SKILL"; ok "compact-plus: keeps the scratchpad via credo_runtime.py" "$?"
grep -qF 'sort -V' "$SKILL"; ok "compact-plus: plugin path resolved by glob with sort -V" "$?"
if grep -Eq 'plugins/cache/[^ ]*credo/[0-9]+\.[0-9]+\.[0-9]+' "$SKILL"; then ok "compact-plus: no pinned plugin version path" 1; else ok "compact-plus: no pinned plugin version path" 0; fi
grep -qF 'session:window.pane' "$SKILL"; ok "compact-plus: tmux pane reference format documented" "$?"
grep -qF -- '--scratchpad' "$CMD_SR"; ok "self-restart command: --scratchpad documented" "$?"
check "no command ever sent keys to a pane" 0 "$(tmux_calls 'SEND-KEYS')"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

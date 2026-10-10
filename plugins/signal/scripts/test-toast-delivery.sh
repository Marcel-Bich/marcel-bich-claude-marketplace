#!/bin/bash
# test-toast-delivery.sh: tests for powershell.exe resolution, the toast switch and the
# exit-code handling of the notification channels (wsl-utils.sh, notify-replace.sh).
#
# Everything is faked: /proc/mounts and /proc/version (env seams), a state dir under the
# temp root, stub powershell.exe / gdbus / notify-send. The PATH only holds the stubs and
# symlinks to a few system tools, so no real powershell.exe, gdbus or notify-send is ever
# reachable and nothing real is toggled or shown. Fixtures are invented.
#
# Usage: bash plugins/signal/scripts/test-toast-delivery.sh

set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sigtoast.XXXXXX")" || exit 1
SLOT="sigtoast-$$"
cleanup() {
    rm -f -- "/tmp/claude-mb-notify-id-$SLOT" "/tmp/claude-mb-notify-id-$SLOT.lock"
    case "$TMP" in
        "${TMPDIR:-/tmp}"/sigtoast.??????) rm -rf -- "$TMP" ;;
        *) echo "refusing to remove unexpected temp root: '$TMP'" >&2 ;;
    esac
}
trap cleanup EXIT

pass=0
fail=0
check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$name" "$want" "$got"
    fi
}
check_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass=$((pass + 1)) ;;
        *) fail=$((fail + 1)); printf 'FAIL %s\n  missing: [%s]\n  in:      [%s]\n' "$name" "$needle" "$hay" ;;
    esac
}

# --- hermetic PATH ------------------------------------------------------------------

SYSBIN="$TMP/sysbin"
BIN="$TMP/bin"
mkdir -p "$SYSBIN" "$BIN"
for t in bash cat grep sed awk tr head tail cut date stat mkdir touch mv rm rmdir flock timeout \
         dirname basename id sleep mktemp wc readlink env sort ls cp ln tee find bc kill jq chmod base64 iconv realpath; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$SYSBIN/$t"
done
PATH_STUBS="$BIN:$SYSBIN"
PATH_NONE="$SYSBIN"
export PATH="$PATH_STUBS"

# --- stubs --------------------------------------------------------------------------

export PS_LOG="$TMP/ps.log"
export GDBUS_LOG="$TMP/gdbus.log"
export NS_LOG="$TMP/ns.log"
: > "$PS_LOG"; : > "$GDBUS_LOG"; : > "$NS_LOG"

# mkps <path>: stub powershell.exe. Logs its args (CALL), its stdin target (STDIN) and the decoded
# -EncodedCommand script (SCRIPT, newlines flattened); FAKE_PS_RC / FAKE_PS_ERR / FAKE_PS_SLEEP /
# FAKE_PS_OUT steer it.
mkps() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
#!/bin/bash
{ printf 'CALL'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "$PS_LOG"
printf 'STDIN=%s\n' "$(readlink /proc/self/fd/0 2>/dev/null)" >> "$PS_LOG"
prev=""
for a in "$@"; do
    if [ "$prev" = "-EncodedCommand" ]; then
        dec="$(printf '%s' "$a" | base64 -d | iconv -f UTF-16LE -t UTF-8)"
        printf 'SCRIPT %s\n' "$(printf '%s' "$dec" | tr '\n' ' ')" >> "$PS_LOG"
        printf 'TERMS=%s\n' "$(printf '%s\n' "$dec" | grep -c "^'@")" >> "$PS_LOG"
    fi
    prev="$a"
done
if [ -n "${FAKE_PS_SLEEP:-}" ]; then
    sleep "$FAKE_PS_SLEEP" & SP=$!
    trap 'kill $SP 2>/dev/null; exit 143' TERM
    wait $SP
fi
[ -n "${FAKE_PS_ERR:-}" ] && echo "$FAKE_PS_ERR" >&2
[ -n "${FAKE_PS_OUT:-}" ] && printf '%s\r\n' "$FAKE_PS_OUT"
exit "${FAKE_PS_RC:-0}"
EOF
    chmod +x "$1"
}

cat > "$BIN/gdbus" <<'EOF'
#!/bin/bash
echo "gdbus $*" >> "$GDBUS_LOG"
case "$*" in
    *GetServerInformation*) [ "${FAKE_GDBUS_INFO_RC:-0}" = 0 ] && echo "('fake-server', 'x', '1', '1.2')"; exit "${FAKE_GDBUS_INFO_RC:-0}" ;;
    *Notify*) [ "${FAKE_GDBUS_NOTIFY_RC:-0}" = 0 ] && echo "${FAKE_GDBUS_NOTIFY_OUT-(uint32 7,)}"; exit "${FAKE_GDBUS_NOTIFY_RC:-0}" ;;
    *) exit 0 ;;
esac
EOF
cat > "$BIN/notify-send" <<'EOF'
#!/bin/bash
echo "notify-send $*" >> "$NS_LOG"
exit "${FAKE_NS_RC:-0}"
EOF
chmod +x "$BIN/gdbus" "$BIN/notify-send"

# --- fixtures: state dir, fake /proc files, fake Windows drive mounts ----------------

export CLAUDE_MB_SIGNAL_STATE_DIR="$TMP/state"
export CLAUDE_MB_SIGNAL_PROC_MOUNTS="$TMP/mounts"
export CLAUDE_MB_SIGNAL_PROC_VERSION="$TMP/version"
WIN="$TMP/win"
PS_REL="Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
echo "Linux version 5.15.0-microsoft-standard-WSL2" > "$TMP/version.wsl"
echo "Linux version 6.8.0-generic (buildd@host)" > "$TMP/version.linux"

# Decoys come first on purpose: a non-Windows mount and the WSL "drivers" 9p mount both carry a
# powershell.exe stub that must NOT be picked.
mkps "$WIN/decoy/$PS_REL"
mkps "$WIN/drv/$PS_REL"
mkps "$WIN/c/$PS_REL"
mkps "$WIN/my drive/$PS_REL"
write_mounts_c() {
    {
        echo "sysfs /sys sysfs rw,nosuid 0 0"
        echo "/dev/sdb1 $WIN/decoy ext4 rw 0 0"
        echo "drivers $WIN/drv 9p ro,nosuid,aname=drivers;fmask=222,cache=0x5 0 0"
        echo "C:\\134 $WIN/c 9p rw,noatime,aname=drvfs;path=C:\\;uid=1000 0 0"
    } > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
}
write_mounts_c

# shellcheck source=/dev/null
source "$SRC_DIR/wsl-utils.sh"

# Every reset points the state dir at a fresh path below the temp root (nothing is removed
# between cases; the whole root goes away with the cleanup trap).
STATE_N=0
reset_state() {
    STATE_N=$((STATE_N + 1))
    export CLAUDE_MB_SIGNAL_STATE_DIR="$TMP/state.$STATE_N"
    : > "$PS_LOG"; : > "$GDBUS_LOG"; : > "$NS_LOG"
}
st_has() { [ -e "$CLAUDE_MB_SIGNAL_STATE_DIR/$1" ] && echo yes || echo no; }

# --- resolve_powershell -------------------------------------------------------------

# (a) PATH hit
reset_state
mkps "$BIN/powershell.exe"
check "resolve: PATH hit" "$BIN/powershell.exe" "$(resolve_powershell)"
check "resolve: PATH hit is cached" "$BIN/powershell.exe" "$(head -n1 "$CLAUDE_MB_SIGNAL_STATE_DIR/powershell-path" 2>/dev/null)"
rm -f -- "$BIN/powershell.exe"

# (b) PATH miss -> Windows drive mount from the fake /proc/mounts (decoys are skipped)
reset_state
check "resolve: drive mount, no PATH hit" "$WIN/c/$PS_REL" "$(resolve_powershell)"
check "resolve: drive mount is cached" "$WIN/c/$PS_REL" "$(head -n1 "$CLAUDE_MB_SIGNAL_STATE_DIR/powershell-path" 2>/dev/null)"

# state dir is private
check "state dir mode" "700" "$(stat -c %a "$CLAUDE_MB_SIGNAL_STATE_DIR")"

# mount point with a space (\040 in /proc/mounts), drvfs fstype, device-less "C:" style
reset_state
{
    echo "drivers $WIN/drv 9p ro,aname=drivers 0 0"
    echo "D: $WIN/my\\040drive drvfs rw,noatime 0 0"
} > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
check "resolve: drvfs mount with escaped space" "$WIN/my drive/$PS_REL" "$(resolve_powershell)"
write_mounts_c

# (c) no hardcoded /mnt/c guess in the production code (comments excluded)
hard="$(grep -v '^[[:space:]]*#' "$SRC_DIR/wsl-utils.sh" "$SRC_DIR/toast-preflight.sh" 2>/dev/null | grep -c '/mnt/c')"
check "no hardcoded /mnt/c path in code" "0" "$hard"

# cache re-validation: stale cache (file gone) -> rediscovery
reset_state
mkdir -p "$CLAUDE_MB_SIGNAL_STATE_DIR" && chmod 700 "$CLAUDE_MB_SIGNAL_STATE_DIR"
echo "$WIN/gone/$PS_REL" > "$CLAUDE_MB_SIGNAL_STATE_DIR/powershell-path"
check "resolve: stale cache falls back to mounts" "$WIN/c/$PS_REL" "$(resolve_powershell)"
check "resolve: stale cache is replaced" "$WIN/c/$PS_REL" "$(head -n1 "$CLAUDE_MB_SIGNAL_STATE_DIR/powershell-path")"

# cache pointing at a non-executable file / wrong basename / relative path is ignored
reset_state
mkdir -p "$CLAUDE_MB_SIGNAL_STATE_DIR" && chmod 700 "$CLAUDE_MB_SIGNAL_STATE_DIR"
printf '#!/bin/bash\n' > "$TMP/notexec.exe"; chmod 644 "$TMP/notexec.exe"
echo "$TMP/notexec.exe" > "$CLAUDE_MB_SIGNAL_STATE_DIR/powershell-path"
check "resolve: non-executable cache ignored" "$WIN/c/$PS_REL" "$(resolve_powershell)"
echo "$BIN/gdbus" > "$CLAUDE_MB_SIGNAL_STATE_DIR/powershell-path"
check "resolve: wrong basename in cache ignored" "$WIN/c/$PS_REL" "$(resolve_powershell)"
echo "powershell.exe" > "$CLAUDE_MB_SIGNAL_STATE_DIR/powershell-path"
check "resolve: relative path in cache ignored" "$WIN/c/$PS_REL" "$(resolve_powershell)"

# (d) not found: return 1, print nothing, warn once (rate-limited), log
reset_state
: > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
out="$(resolve_powershell 2>"$TMP/err1")"; rc=$?
check "resolve: not found rc" "1" "$rc"
check "resolve: not found prints nothing" "" "$out"
check "resolve: not found stays quiet by itself" "" "$(cat "$TMP/err1")"
signal_warn_once ps-missing "powershell.exe not found" 2>"$TMP/err2"
check_contains "warn once: first message on stderr" "powershell.exe not found" "$(cat "$TMP/err2")"
signal_warn_once ps-missing "powershell.exe not found" 2>"$TMP/err3"
check "warn once: second call silent" "" "$(cat "$TMP/err3")"
check_contains "warn once: logged" "powershell.exe not found" "$(cat "$CLAUDE_MB_SIGNAL_STATE_DIR/signal.log")"
# after 24h the warning is allowed again
touch -d '2 days ago' "$CLAUDE_MB_SIGNAL_STATE_DIR/warned-ps-missing"
signal_warn_once ps-missing "powershell.exe not found" 2>"$TMP/err4"
check_contains "warn once: allowed again after a day" "powershell.exe not found" "$(cat "$TMP/err4")"
write_mounts_c

# a missing /proc/mounts is not an error message: rc 1, silent
reset_state
CLAUDE_MB_SIGNAL_PROC_MOUNTS="$TMP/no-such-mounts" resolve_powershell >/dev/null 2>"$TMP/errm"; rc=$?
check "resolve: missing /proc/mounts rc" "1" "$rc"
check "resolve: missing /proc/mounts prints no shell error" "" "$(cat "$TMP/errm")"

# unwritable state: resolution still works, nothing cached, no crash
reset_state
export CLAUDE_MB_SIGNAL_STATE_DIR="/proc/nonexistent/state"
check "resolve: works without a usable state dir" "$WIN/c/$PS_REL" "$(resolve_powershell)"
signal_state_dir >/dev/null 2>&1; rc=$?
check "state dir: unusable path -> rc 1" "1" "$rc"

# a symlinked state dir is refused, a too open mode is tightened
reset_state
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/linkstate"
export CLAUDE_MB_SIGNAL_STATE_DIR="$TMP/linkstate"
signal_state_dir >/dev/null 2>&1; rc=$?
check "state dir: symlink refused" "1" "$rc"
reset_state
mkdir -p "$CLAUDE_MB_SIGNAL_STATE_DIR" && chmod 755 "$CLAUDE_MB_SIGNAL_STATE_DIR"
signal_state_dir >/dev/null 2>&1; rc=$?
check "state dir: open mode is tightened, rc 0" "0" "$rc"
check "state dir: mode after tightening" "700" "$(stat -c %a "$CLAUDE_MB_SIGNAL_STATE_DIR")"

# the default location follows XDG_STATE_HOME
reset_state
( unset CLAUDE_MB_SIGNAL_STATE_DIR; XDG_STATE_HOME="$TMP/xdg" signal_state_dir > "$TMP/xdg.out" )
check "state dir: default below XDG_STATE_HOME" "$TMP/xdg/claude-mb-signal" "$(cat "$TMP/xdg.out")"

# below $HOME every level must be a real directory owned by the user and not group/world-writable
reset_state
FH="$TMP/fakehome"
mkdir -p "$FH/real/inner"
chmod 700 "$FH" "$FH/real" "$FH/real/inner"
ln -s "$FH/real" "$FH/linked"
( unset CLAUDE_MB_SIGNAL_STATE_DIR; HOME="$FH" XDG_STATE_HOME='' signal_state_dir > "$TMP/h.out" 2>/dev/null ); rc=$?
check "state dir: default below HOME works" "0" "$rc"
check "state dir: default below HOME path" "$FH/.local/state/claude-mb-signal" "$(cat "$TMP/h.out")"
( CLAUDE_MB_SIGNAL_STATE_DIR="$FH/linked/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: symlinked parent below HOME refused" "1" "$rc"
chmod 770 "$FH/real"
( CLAUDE_MB_SIGNAL_STATE_DIR="$FH/real/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: group-writable parent of the user's own group accepted" "0" "$rc"
( _signal_user_groups() { echo 99999; }; CLAUDE_MB_SIGNAL_STATE_DIR="$FH/real/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: group-writable parent of a foreign group refused" "1" "$rc"
chmod 1777 "$FH/real"
( CLAUDE_MB_SIGNAL_STATE_DIR="$FH/real/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: world-writable parent with sticky bit accepted" "0" "$rc"
chmod 777 "$FH/real"
( CLAUDE_MB_SIGNAL_STATE_DIR="$FH/real/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: world-writable parent without sticky bit refused" "1" "$rc"
chmod 707 "$FH/real"
( CLAUDE_MB_SIGNAL_STATE_DIR="$FH/real/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: world-writable parent refused" "1" "$rc"
chmod 700 "$FH/real"
( CLAUDE_MB_SIGNAL_STATE_DIR="$FH/real/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: private parents accepted" "0" "$rc"
check "state dir: created levels are private" "700" "$(stat -c %a "$FH/real/inner/st")"
( CLAUDE_MB_SIGNAL_STATE_DIR="$FH/real/../real/inner/st" HOME="$FH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: dot-dot path refused" "1" "$rc"

# default Ubuntu umask 002: ~/.local and ~/.local/state are 775 (group-writable, own group)
UH="$TMP/umask-home"
mkdir -p "$UH" && chmod 700 "$UH"
( umask 002; mkdir -p "$UH/.local/state" )
check "umask 002 fixture: parents are 775" "775" "$(stat -c %a "$UH/.local")"
( unset CLAUDE_MB_SIGNAL_STATE_DIR; HOME="$UH" XDG_STATE_HOME='' signal_state_dir > "$TMP/u.out" 2>/dev/null ); rc=$?
check "state dir: default below HOME with umask-002 parents works" "0" "$rc"
check "state dir: default below HOME with umask-002 parents path" "$UH/.local/state/claude-mb-signal" "$(cat "$TMP/u.out")"

# BSD-style stat (no -c, -f with %Mp%Lp) is understood: no silent loss of the state dir
mkdir -p "$TMP/bsdbin"
cat > "$TMP/bsdbin/stat" <<'EOF'
#!/bin/bash
[ "$1" = "-f" ] || { echo "stat: illegal option -- ${1#-}" >&2; exit 1; }
shift 2
[ "$1" = "--" ] && shift
read -r u m g < <("$REAL_STAT" -c '%u %a %g' -- "$1") || exit 1
printf '%s %04o %s\n' "$u" "$((8#$m))" "$g"
EOF
chmod +x "$TMP/bsdbin/stat"
REAL_STAT="$(command -v stat)"
export REAL_STAT
( CLAUDE_MB_SIGNAL_STATE_DIR="$UH/.local/state/bsd" HOME="$UH" PATH="$TMP/bsdbin:$PATH" signal_state_dir >/dev/null 2>&1 ); rc=$?
check "state dir: BSD-style stat accepted" "0" "$rc"
( CLAUDE_MB_SIGNAL_STATE_DIR="$UH/.local/state/bsd" HOME="$UH" PATH="$TMP/bsdbin:$PATH"; signal_log "bsd log line"; grep -c 'bsd log line' "$UH/.local/state/bsd/signal.log" > "$TMP/bsdlog.out" )
check "log: works without GNU stat" "1" "$(cat "$TMP/bsdlog.out")"

# files in the state dir are never written through a symlink
reset_state
signal_state_dir >/dev/null
SD="$CLAUDE_MB_SIGNAL_STATE_DIR"
: > "$TMP/victim.log"
ln -s "$TMP/victim.log" "$SD/signal.log"
signal_log "should not land in the victim"
check "log: symlinked signal.log is not written through" "0" "$(wc -c < "$TMP/victim.log")"
rm -f -- "$SD/signal.log"
ln -s "$TMP/victim.new" "$SD/warned-linked"
signal_warn_once linked "linked marker" 2>/dev/null
check "warn marker: dangling symlink target is not created" "no" "$([ -e "$TMP/victim.new" ] && echo yes || echo no)"
ln -s "$TMP/victim.cache" "$SD/powershell-path.$$"
resolve_powershell >/dev/null
check "ps cache: temp symlink target is not created" "no" "$([ -e "$TMP/victim.cache" ] && echo yes || echo no)"
rm -f -- "$SD/powershell-path.$$"
mkdir "$SD/adir"
echo x | _signal_atomic_write "$SD/adir"; rc=$?
check "atomic write: directory destination refused" "1" "$rc"
check "atomic write: nothing moved into the directory" "" "$(ls -A "$SD/adir")"
echo data | _signal_atomic_write "$SD/plain"; rc=$?
check "atomic write: plain destination rc" "0" "$rc"
check "atomic write: plain destination content" "data" "$(cat "$SD/plain")"
check "atomic write: no temp file left behind" "0" "$(printf '%s\n' "$SD"/plain.* | grep -c 'plain\.[A-Za-z0-9]\{6\}$')"
ln -s "$TMP/victim.atomic" "$SD/atomic-link"
echo x | _signal_atomic_write "$SD/atomic-link"; rc=$?
check "atomic write: symlink destination refused" "1" "$rc"
check "atomic write: symlink target is not created" "no" "$([ -e "$TMP/victim.atomic" ] && echo yes || echo no)"

# without a usable state dir the warning is limited by a per-user marker in TMPDIR, not repeated
FB="$TMP/fbtmp"
mkdir -p "$FB"
( unset CLAUDE_MB_SIGNAL_STATE_DIR XDG_STATE_HOME; HOME=''; export TMPDIR="$FB"
  signal_warn_once nostate "no state here" 2>"$TMP/w1"
  signal_warn_once nostate "no state here" 2>"$TMP/w2" )
check_contains "warn once without state dir: first call warns" "no state here" "$(cat "$TMP/w1")"
check "warn once without state dir: second call silent" "" "$(cat "$TMP/w2")"
check "warn once without state dir: marker is private" "600" "$(stat -c %a "$FB"/claude-mb-signal-warned-* 2>/dev/null | head -n1)"
FB2="$TMP/fbtmp2"
mkdir -p "$FB2"
ln -s "$TMP/victim.warn" "$FB2/claude-mb-signal-warned-$(id -u)-linked"
( unset CLAUDE_MB_SIGNAL_STATE_DIR XDG_STATE_HOME; HOME=''; export TMPDIR="$FB2"
  signal_warn_once linked "linked fallback" 2>"$TMP/w3" )
check "warn once without state dir: symlinked marker stays silent" "" "$(cat "$TMP/w3")"
check "warn once without state dir: symlink target is not created" "no" "$([ -e "$TMP/victim.warn" ] && echo yes || echo no)"

# --- windows_notify -----------------------------------------------------------------

reset_state
windows_notify "Done" "All good" "tag-1" 1; rc=$?
wait
check "notify: rc 0 when launched" "0" "$rc"
check_contains "notify: stub called with the toast text" "All good" "$(cat "$PS_LOG")"
check_contains "notify: -NoProfile passed" "<-NoProfile>" "$(cat "$PS_LOG")"
check_contains "notify: script goes through -EncodedCommand" "<-EncodedCommand>" "$(cat "$PS_LOG")"
check "notify: no -Command with a multi-line argv string" "0" "$(grep -c '<-Command>' "$PS_LOG")"
check "notify: every argv stays on one line" "0" "$(grep -c -v -E '^(CALL|STDIN=|SCRIPT |TERMS=)' "$PS_LOG")"
check_contains "notify: decoded script carries the text" "All good" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "notify: script silences progress output" "ProgressPreference" "$(grep '^SCRIPT' "$PS_LOG")"

# control characters (invalid in XML 1.0) are stripped, tab survives
reset_state
windows_notify $'ti\x01tle\x1b[31m' $'bo\x07dy\x0bx\ty' "tag-c" 1
wait
check "notify: no control characters reach the script" "0" "$(grep '^SCRIPT' "$PS_LOG" | LC_ALL=C grep -c $'[\x01-\x08\x0b\x0c\x0e-\x1f]')"
check_contains "notify: title text around stripped controls kept" "title[31m" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "notify: body text around stripped controls kept, tab kept" "bodyx"$'\t'"y" "$(grep '^SCRIPT' "$PS_LOG")"

# the encoded command stays far below the 32767 character Windows limit even when escaping
# inflates every character (2000 x '&' becomes 5 characters each)
reset_state
big="$(head -c 2000 /dev/zero | tr '\0' '&')"
bigt="$(head -c 300 /dev/zero | tr '\0' '<')"
windows_notify "$bigt" "$big" "tag-big" 1
wait
check "notify: worst-case encoded command stays far below the limit" "1" "$([ "$(grep '^CALL' "$PS_LOG" | head -n1 | wc -c)" -lt 20000 ] && echo 1 || echo 0)"
check "notify: capped text keeps well-formed entities" "0" "$(grep '^SCRIPT' "$PS_LOG" | sed 's/&amp;//g; s/&lt;//g; s/&gt;//g' | grep -c '&')"

# non-ASCII text survives the UTF-16LE round trip
reset_state
windows_notify "Prüfung ✨ done" "Größe ok" "tag-u" 1
wait
check_contains "notify: umlauts and symbols survive the encoding" "Prüfung ✨ done" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "notify: umlaut body survives" "Größe ok" "$(grep '^SCRIPT' "$PS_LOG")"

# quotes and apostrophes in the text reach the toast verbatim (the script is not an argv string)
reset_state
windows_notify "It's \"q\"" "don't & <x>" "tag-q" 1
wait
check_contains "notify: apostrophe and quotes verbatim in the title" "It's \"q\"" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "notify: body is XML-escaped, apostrophe verbatim" "don't &amp; &lt;x&gt;" "$(grep '^SCRIPT' "$PS_LOG")"

# the tag is restricted to [A-Za-z0-9-] before it reaches the script (session id is untrusted)
reset_state
windows_notify "T" "m" "x'; Start-Process calc; '" 1
wait
check_contains "notify: tag is restricted to [A-Za-z0-9-]" ".Tag = 'x---Start-Process-calc---'" "$(grep '^SCRIPT' "$PS_LOG")"
check "notify: hostile tag adds no statement" "0" "$(grep '^SCRIPT' "$PS_LOG" | grep -c 'Start-Process calc')"
reset_state
windows_notify "T" "m" $'ab\nStart-Process calc\n$(id)' 1
wait
check_contains "notify: newline in the tag is neutralized" ".Tag = 'ab-Start-Process-calc---id-'" "$(grep '^SCRIPT' "$PS_LOG")"
# a title cannot break out of the here-string with a line starting with the terminator
reset_state
windows_notify $'x\n\'@\nStart-Process calc' "m" "tag" 1
wait
check "notify: here-string terminator appears once, at a line start" "TERMS=1" "$(grep '^TERMS=' "$PS_LOG" | head -n1)"

# the background run never inherits the hook's stdin
reset_state
signal_ps_bg probe "$WIN/c/$PS_REL" 'Write-Output 1' <<< "payload"
wait
check "ps_bg: stdin is /dev/null" "STDIN=/dev/null" "$(grep '^STDIN=' "$PS_LOG" | head -n1)"

# switch off -> no attempt at all, rc 3
reset_state
CLAUDE_MB_NOTIFY_TOAST=false windows_notify "Done" "x" "tag" 1; rc=$?
wait
check "notify: switch off rc" "3" "$rc"
check "notify: switch off makes no call" "" "$(cat "$PS_LOG")"
for v in 0 no off OFF False disabled Disabled ' false ' $'\tNo\n'; do
    CLAUDE_MB_NOTIFY_TOAST=$v signal_toast_enabled; rc=$?
    check "switch value '$v' is off" "1" "$rc"
done
for v in true 1 yes on ' true ' ""; do
    CLAUDE_MB_NOTIFY_TOAST=$v signal_toast_enabled; rc=$?
    check "switch value '$v' is on" "0" "$rc"
done
unset CLAUDE_MB_NOTIFY_TOAST

# powershell not resolvable -> rc 1, no call
reset_state
: > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
windows_notify "Done" "x" "tag" 1 2>/dev/null; rc=$?
wait
check "notify: unresolvable rc" "1" "$rc"
check "notify: unresolvable makes no call" "" "$(cat "$PS_LOG")"
write_mounts_c

# async failure of the powershell run is evaluated and logged
reset_state
FAKE_PS_RC=5 FAKE_PS_ERR="boom" windows_notify "Done" "x" "tag" 1
wait
check_contains "notify: failure exit code logged" "exit 5" "$(cat "$CLAUDE_MB_SIGNAL_STATE_DIR/signal.log" 2>/dev/null)"
check_contains "notify: failure stderr logged" "boom" "$(cat "$CLAUDE_MB_SIGNAL_STATE_DIR/signal.log" 2>/dev/null)"

# the failure marker is per kind: a successful run of another kind does not hide it
reset_state
FAKE_PS_RC=5 FAKE_PS_ERR="boom" windows_notify "Done" "x" "tag" 1
wait
check "ps failure: toast marker written" "yes" "$(st_has ps-failed-toast)"
windows_sound complete 0.4
wait
check "ps failure: a successful sound run keeps the toast marker" "yes" "$(st_has ps-failed-toast)"
windows_notify "Done" "x" "tag" 1 2>"$TMP/pw.err"
wait
check_contains "ps failure: earlier toast failure is reported by the next toast" "toast failed" "$(cat "$TMP/pw.err")"
check "ps failure: a successful toast run clears its marker" "no" "$(st_has ps-failed-toast)"
reset_state
FAKE_PS_RC=3 windows_sound complete 0.4
wait
check "ps failure: sound marker written" "yes" "$(st_has ps-failed-sound)"
windows_sound complete 0.4 2>"$TMP/pw2.err"
wait
check_contains "ps failure: earlier sound failure is reported by the next sound" "sound failed" "$(cat "$TMP/pw2.err")"

# a hanging powershell never blocks the caller and is killed by the timeout
reset_state
t0=$(date +%s%N)
FAKE_PS_SLEEP=30 CLAUDE_MB_SIGNAL_PS_TIMEOUT=1 windows_notify "Done" "x" "tag" 1; rc=$?
t1=$(date +%s%N)
check "notify: hang does not block the caller" "1" "$([ $(( (t1 - t0) / 1000000 )) -lt 800 ] && echo 1 || echo 0)"
wait
check_contains "notify: hung run is killed and logged" "exit 124" "$(cat "$CLAUDE_MB_SIGNAL_STATE_DIR/signal.log" 2>/dev/null)"

# --- windows_sound ------------------------------------------------------------------

reset_state
windows_sound complete 0.4; rc=$?
wait
check "sound: rc 0" "0" "$rc"
check_contains "sound: stub called with MediaPlayer" "MediaPlayer" "$(cat "$PS_LOG")"
check_contains "sound: script silences progress output" "ProgressPreference" "$(grep '^SCRIPT' "$PS_LOG")"
reset_state
: > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
windows_sound complete 0.4 2>/dev/null; rc=$?
wait
check "sound: unresolvable rc" "1" "$rc"
check "sound: unresolvable makes no call" "" "$(cat "$PS_LOG")"
write_mounts_c
# the sound does not depend on the toast switch
reset_state
CLAUDE_MB_NOTIFY_TOAST=false windows_sound complete 0.4
wait
check_contains "sound: independent of the toast switch" "MediaPlayer" "$(cat "$PS_LOG")"

# --- notify-replace.sh (separate process) -------------------------------------------

nr() { # nr <version-file> [path]; runs notify-replace.sh with a unique slot
    CLAUDE_MB_SIGNAL_PROC_VERSION="$1" PATH="${2:-$PATH_STUBS}" bash "$SRC_DIR/notify-replace.sh" "$SLOT" "T" "B" "dialog-information" 1 2>"$TMP/nr.err"
}

# WSL, powershell resolvable via mounts: delivered
reset_state
nr "$TMP/version.wsl"; rc=$?
wait
sleep 0.3
check "nr wsl: rc 0" "0" "$rc"
check_contains "nr wsl: toast launched through the resolved path" "<-NoProfile>" "$(cat "$PS_LOG")"

# WSL, no powershell anywhere: rc 1, one warning, then rate-limited
reset_state
: > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
nr "$TMP/version.wsl"; rc=$?
check "nr wsl missing: rc 1" "1" "$rc"
check_contains "nr wsl missing: warning on stderr" "powershell.exe" "$(cat "$TMP/nr.err")"
nr "$TMP/version.wsl"; rc=$?
check "nr wsl missing 2nd: rc still 1" "1" "$rc"
check "nr wsl missing 2nd: no repeated warning" "" "$(cat "$TMP/nr.err")"
write_mounts_c

# WSL, toast switch off: no call, rc 0
reset_state
CLAUDE_MB_NOTIFY_TOAST=false nr "$TMP/version.wsl"; rc=$?
check "nr switch off: rc 0" "0" "$rc"
check "nr switch off: no powershell call" "" "$(cat "$PS_LOG")"

# Linux, gdbus works
reset_state
rm -f -- "/tmp/claude-mb-notify-id-$SLOT"
nr "$TMP/version.linux"; rc=$?
check "nr linux gdbus: rc 0" "0" "$rc"
check "nr linux gdbus: id stored" "7" "$(cat "/tmp/claude-mb-notify-id-$SLOT" 2>/dev/null)"
check "nr linux: powershell never called" "" "$(cat "$PS_LOG")"

# Linux, gdbus Notify succeeds (rc 0) but the id cannot be parsed: still delivered, no duplicate
reset_state
rm -f -- "/tmp/claude-mb-notify-id-$SLOT"
FAKE_GDBUS_NOTIFY_OUT="()" nr "$TMP/version.linux"; rc=$?
check "nr linux unparsable id: rc 0" "0" "$rc"
check "nr linux unparsable id: no duplicate via notify-send" "" "$(cat "$NS_LOG")"
check "nr linux unparsable id: no id stored" "no" "$([ -e "/tmp/claude-mb-notify-id-$SLOT" ] && echo yes || echo no)"

# Linux, gdbus Notify fails -> notify-send fallback
reset_state
rm -f -- "/tmp/claude-mb-notify-id-$SLOT"
FAKE_GDBUS_NOTIFY_RC=1 nr "$TMP/version.linux"; rc=$?
check "nr linux fallback: rc 0" "0" "$rc"
check_contains "nr linux fallback: notify-send used" "notify-send" "$(cat "$NS_LOG")"

# Linux, both fail -> rc 1 with one warning
reset_state
rm -f -- "/tmp/claude-mb-notify-id-$SLOT"
FAKE_GDBUS_NOTIFY_RC=1 FAKE_NS_RC=1 nr "$TMP/version.linux"; rc=$?
check "nr linux both fail: rc 1" "1" "$rc"
check_contains "nr linux both fail: warning" "no notification channel" "$(cat "$TMP/nr.err")"
FAKE_GDBUS_NOTIFY_RC=1 FAKE_NS_RC=1 nr "$TMP/version.linux"; rc=$?
check "nr linux both fail 2nd: still rc 1" "1" "$rc"
check "nr linux both fail 2nd: warning rate-limited" "" "$(cat "$TMP/nr.err")"

# Linux, no tool at all
reset_state
nr "$TMP/version.linux" "$PATH_NONE"; rc=$?
check "nr linux no tool: rc 1" "1" "$rc"

# Linux, switch off
reset_state
: > "$GDBUS_LOG"
CLAUDE_MB_NOTIFY_TOAST=off nr "$TMP/version.linux"; rc=$?
check "nr linux switch off: rc 0" "0" "$rc"
check "nr linux switch off: nothing sent" "" "$(cat "$GDBUS_LOG")$(cat "$NS_LOG")"

# --- preflight (toast-preflight.sh, separate process per call) ----------------------
# WSL: the registry read runs detached in the background and writes its result to the state
# dir; the NEXT session reports it. The daily stamp is only set after a usable result, a failed
# probe leaves a short-lived marker (retry after an hour at the earliest).

# pf <version-file> [path]: run signal_preflight in a fresh shell, print its stdout
pf() {
    CLAUDE_MB_SIGNAL_PROC_VERSION="$1" PATH="${2:-$PATH_STUBS}" bash -c 'source "$1/toast-preflight.sh"; signal_preflight' _ "$SRC_DIR" 2>"$TMP/pf.err"
}
# wait_probe: wait (max ~10 s) until the detached probe has finished (its pending marker is gone)
wait_probe() {
    local i=0
    while [ -e "$CLAUDE_MB_SIGNAL_STATE_DIR/preflight-pending" ] && [ "$i" -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}
# pf_cycle <version-file>: session 1 launches the probe, the probe finishes, session 2 reports
pf_cycle() {
    pf "$1" >/dev/null
    wait_probe
    pf "$1"
}
ps_calls() { grep -c '^CALL' "$PS_LOG"; }
READONLY_VERBS='Set-Item|New-Item|Remove-Item|Clear-Item|Set-Property|Remove-Property|New-Property|reg +add|reg +delete'

# WSL: the first session is silent and does not wait for powershell; the next one reports
reset_state
t0=$(date +%s%N)
out="$(echo payload | FAKE_PS_SLEEP=2 FAKE_PS_OUT='T=0;G=1;A=1' pf "$TMP/version.wsl")"
t1=$(date +%s%N)
check "preflight wsl: first session is silent" "" "$out"
check "preflight wsl: first session does not wait for powershell" "1" "$([ $(( (t1 - t0) / 1000000 )) -lt 1000 ] && echo 1 || echo 0)"
wait_probe
check "preflight wsl: registry read made once" "1" "$(ps_calls)"
check "preflight wsl: probe stdin is /dev/null" "STDIN=/dev/null" "$(grep '^STDIN=' "$PS_LOG" | head -n1)"
check_contains "preflight wsl: probe uses -EncodedCommand" "<-EncodedCommand>" "$(cat "$PS_LOG")"
check "preflight wsl: probe has no -Command argv string" "0" "$(grep -c '<-Command>' "$PS_LOG")"
check_contains "preflight wsl: reads ToastEnabled" "ToastEnabled" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "preflight wsl: probe silences progress output" "ProgressPreference" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "preflight wsl: reads the per-app key" "WindowsPowerShell" "$(grep '^SCRIPT' "$PS_LOG")"
check "preflight wsl: command is read-only" "0" "$(grep -c -E "$READONLY_VERBS" "$PS_LOG")"
check "preflight wsl: no daily stamp before the result is reported" "no" "$(st_has preflight-checked)"
check "preflight wsl: no failure marker after a usable result" "no" "$(st_has preflight-failed)"
out="$(pf "$TMP/version.wsl")"
check_contains "preflight wsl: next session reports ToastEnabled=0" "ToastEnabled=0" "$out"
check "preflight wsl: report is one line" "1" "$(printf '%s\n' "$out" | wc -l)"
check "preflight wsl: stamp set after the usable result" "yes" "$(st_has preflight-checked)"
out="$(pf "$TMP/version.wsl")"
check "preflight wsl: reported only once" "" "$out"
check "preflight wsl: max once per day (no 2nd registry call)" "1" "$(ps_calls)"
touch -d '2 days ago' "$CLAUDE_MB_SIGNAL_STATE_DIR/preflight-checked"
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf_cycle "$TMP/version.wsl")"
check_contains "preflight wsl: next day it checks again" "ToastEnabled=0" "$out"
check "preflight wsl: next day made a 2nd registry call" "2" "$(ps_calls)"

# absent values are enabled: silent, but the stamp is set (a usable result)
reset_state
out="$(FAKE_PS_OUT='T=;G=;A=' pf_cycle "$TMP/version.wsl")"
check "preflight wsl: absent values are enabled (silent)" "" "$out"
check "preflight wsl: absent values still stamp the day" "yes" "$(st_has preflight-checked)"
out="$(pf "$TMP/version.wsl")"
check "preflight wsl: stamped day makes no new call" "1" "$(ps_calls)"

# each of the three switches is detected, as exactly one line; others on = silent
for spec in 'T=0;G=1;A=1|ToastEnabled=0' 'T=1;G=0;A=1|NOC_GLOBAL_SETTING_TOASTS_ENABLED=0' 'T=1;G=1;A=0|per-app'; do
    reset_state
    out="$(FAKE_PS_OUT="${spec%%|*}" pf_cycle "$TMP/version.wsl")"
    check_contains "preflight wsl: '${spec%%|*}' reported" "${spec##*|}" "$out"
    check "preflight wsl: '${spec%%|*}' is one line" "1" "$(printf '%s\n' "$out" | wc -l)"
done
check_contains "preflight wsl: names the settings page" "ms-settings:notifications" "$out"
check_contains "preflight wsl: tells the agent to tell the user" "Tell the user once" "$out"
check_contains "preflight wsl: user switches it on manually" "Never change the setting yourself" "$out"
check_contains "preflight wsl: open-settings only after the user agreed" "ONLY after the user said yes" "$out"
check_contains "preflight wsl: open-settings never on its own" "never on your own" "$out"
check_contains "preflight wsl: decline only when the user wants no hints" "wants no further hints" "$out"
reset_state
out="$(FAKE_PS_OUT='T=1;G=1;A=1' pf_cycle "$TMP/version.wsl")"
check "preflight wsl: all on is silent" "" "$out"

# unknown is not disabled: garbage output and a failing powershell stay silent, set no daily
# stamp, leave a short-lived failure marker (retry after an hour at the earliest) and are logged
reset_state
out="$(FAKE_PS_OUT='garbage' pf_cycle "$TMP/version.wsl")"
check "preflight wsl: unparsable result is silent" "" "$out"
check "preflight wsl: unparsable result sets no daily stamp" "no" "$(st_has preflight-checked)"
check "preflight wsl: unparsable result leaves a failure marker" "yes" "$(st_has preflight-failed)"
check_contains "preflight wsl: failure is logged" "no usable result" "$(cat "$CLAUDE_MB_SIGNAL_STATE_DIR/signal.log" 2>/dev/null)"
out="$(pf "$TMP/version.wsl")"
check "preflight wsl: no retry within the hour (silent)" "" "$out"
check "preflight wsl: no retry within the hour (no 2nd call)" "1" "$(ps_calls)"
touch -d '2 hours ago' "$CLAUDE_MB_SIGNAL_STATE_DIR/preflight-failed"
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf_cycle "$TMP/version.wsl")"
check_contains "preflight wsl: retry after the hour works" "ToastEnabled=0" "$out"
check "preflight wsl: retry made the 2nd call" "2" "$(ps_calls)"
check "preflight wsl: success clears the failure marker" "no" "$(st_has preflight-failed)"
reset_state
out="$(FAKE_PS_RC=9 pf_cycle "$TMP/version.wsl")"
check "preflight wsl: failing powershell is silent" "" "$out"
check "preflight wsl: failing powershell sets no daily stamp" "no" "$(st_has preflight-checked)"
check "preflight wsl: failing powershell leaves a failure marker" "yes" "$(st_has preflight-failed)"

# a hanging registry read is cut by the preflight timeout, never delays the session
reset_state
t0=$(date +%s%N)
out="$(FAKE_PS_SLEEP=30 FAKE_PS_OUT='T=0;G=0;A=0' CLAUDE_MB_SIGNAL_PREFLIGHT_TIMEOUT=1 pf "$TMP/version.wsl")"
t1=$(date +%s%N)
check "preflight wsl: hang does not delay the session" "1" "$([ $(( (t1 - t0) / 1000000 )) -lt 1000 ] && echo 1 || echo 0)"
check "preflight wsl: hang stays silent" "" "$out"
wait_probe
check "preflight wsl: hung probe leaves a failure marker" "yes" "$(st_has preflight-failed)"
check "preflight wsl: hung probe sets no daily stamp" "no" "$(st_has preflight-checked)"
check_contains "preflight wsl: hung probe is logged as killed" "exit 124" "$(cat "$CLAUDE_MB_SIGNAL_STATE_DIR/signal.log" 2>/dev/null)"

# a probe that is already running is not started twice; a stale pending marker is ignored
reset_state
signal_state_dir >/dev/null
touch "$CLAUDE_MB_SIGNAL_STATE_DIR/preflight-pending"
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf "$TMP/version.wsl")"
check "preflight wsl: running probe is not started twice" "0" "$(ps_calls)"
touch -d '10 minutes ago' "$CLAUDE_MB_SIGNAL_STATE_DIR/preflight-pending"
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf_cycle "$TMP/version.wsl")"
check_contains "preflight wsl: stale pending marker is ignored" "ToastEnabled=0" "$out"

# switch off: no check at all
reset_state
out="$(CLAUDE_MB_NOTIFY_TOAST=false FAKE_PS_OUT='T=0;G=0;A=0' pf_cycle "$TMP/version.wsl")"
check "preflight: switch off is silent" "" "$out"
check "preflight: switch off makes no powershell call" "" "$(cat "$PS_LOG")"
check "preflight: switch off leaves no stamp" "no" "$(st_has preflight-checked)"

# powershell.exe not resolvable on WSL: one context line, then quiet for the day
reset_state
: > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
out="$(pf "$TMP/version.wsl")"
check_contains "preflight wsl: unresolvable powershell gets a line" "powershell.exe could not be found" "$out"
check "preflight wsl: unresolvable line is one line" "1" "$(printf '%s\n' "$out" | wc -l)"
check_contains "preflight wsl: unresolvable line, decline only on the user's wish" "wants no further hints" "$out"
check "preflight wsl: unresolvable powershell sets no daily stamp" "no" "$(st_has preflight-checked)"
check "preflight wsl: unresolvable powershell leaves a failure marker" "yes" "$(st_has preflight-failed)"
out="$(pf "$TMP/version.wsl")"
check "preflight wsl: unresolvable line only once a day" "" "$out"
touch -d '2 hours ago' "$CLAUDE_MB_SIGNAL_STATE_DIR/preflight-failed"
out="$(pf "$TMP/version.wsl")"
check "preflight wsl: still unresolvable after the hour does not repeat the line" "" "$out"
check "preflight wsl: still unresolvable after the hour renews the failure marker" "yes" "$(st_has preflight-failed)"
write_mounts_c
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf_cycle "$TMP/version.wsl")"
check "preflight wsl: powershell found again, but no retry within the hour" "0" "$(ps_calls)"
touch -d '2 hours ago' "$CLAUDE_MB_SIGNAL_STATE_DIR/preflight-failed"
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf_cycle "$TMP/version.wsl")"
check_contains "preflight wsl: powershell found again, check works after the hour" "ToastEnabled=0" "$out"

# decline and reset
reset_state
FAKE_PS_OUT='T=0;G=1;A=1' pf "$TMP/version.wsl" >/dev/null
wait_probe
bash "$SRC_DIR/toast-preflight.sh" decline >/dev/null; rc=$?
check "decline: rc 0" "0" "$rc"
check "decline: state file written" "yes" "$(st_has preflight-declined)"
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf "$TMP/version.wsl")"
check "decline: no further nagging" "" "$out"
bash "$SRC_DIR/toast-preflight.sh" reset >/dev/null; rc=$?
check "reset: rc 0" "0" "$rc"
check "reset: decline cleared" "no" "$(st_has preflight-declined)"
check "reset: unreported result cleared" "no" "$(st_has preflight-result)"
out="$(FAKE_PS_OUT='T=0;G=1;A=1' pf_cycle "$TMP/version.wsl")"
check_contains "reset: hints come back" "ToastEnabled=0" "$out"
bash "$SRC_DIR/toast-preflight.sh" bogus 2>/dev/null; rc=$?
check "cli: unknown subcommand rc 2" "2" "$rc"

# open-settings goes through the stub (never a real settings window)
reset_state
CLAUDE_MB_SIGNAL_PROC_VERSION="$TMP/version.wsl" bash "$SRC_DIR/toast-preflight.sh" open-settings; rc=$?
check "open-settings: rc 0" "0" "$rc"
check_contains "open-settings: asks for the notification settings page" "ms-settings:notifications" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "open-settings: script goes through -EncodedCommand" "<-EncodedCommand>" "$(cat "$PS_LOG")"
check "open-settings: changes nothing" "0" "$(grep -c -E "$READONLY_VERBS" "$PS_LOG")"

# native Linux: only tool availability, never powershell (immediate, stamped)
reset_state
out="$(pf "$TMP/version.linux")"
check "preflight linux: gdbus present is silent" "" "$out"
check "preflight linux: powershell never called" "" "$(cat "$PS_LOG")"
reset_state
out="$(pf "$TMP/version.linux" "$PATH_NONE")"
check_contains "preflight linux: no tool gets a line" "Neither gdbus nor notify-send" "$out"
check "preflight linux: no-tool line is one line" "1" "$(printf '%s\n' "$out" | wc -l)"
check "preflight linux: powershell never called" "" "$(cat "$PS_LOG")"
out="$(pf "$TMP/version.linux" "$PATH_NONE")"
check "preflight linux: no-tool line only once a day" "" "$out"
reset_state
mv -f -- "$BIN/gdbus" "$TMP/gdbus.off"
out="$(pf "$TMP/version.linux")"
check "preflight linux: notify-send alone is enough" "" "$out"
mv -f -- "$TMP/gdbus.off" "$BIN/gdbus"

# --- session-start.sh integration (hooks are non-blocking, preflight line reaches stdout) ---

SS_SID="sigtoast-ss-$$"
SS_FIRST="/tmp/claude-mb-first-event-pending-session-$SS_SID-first"
ss() { # ss <version-file>; feeds a hook payload, prints stdout
    printf '{"session_id":"%s"}' "$SS_SID" | CLAUDE_MB_SIGNAL_PROC_VERSION="$1" CLAUDE_MB_KITTY_TAB=false \
        env -u TMUX -u TMUX_PANE bash "$SRC_DIR/session-start.sh" 2>"$TMP/ss.err"
}
reset_state
t0=$(date +%s%N)
out="$(FAKE_PS_SLEEP=3 FAKE_PS_OUT='T=0;G=1;A=1' ss "$TMP/version.wsl")"; rc=$?
t1=$(date +%s%N)
sleep 0.3
check "session-start wsl: rc 0" "0" "$rc"
check "session-start wsl: fast even with a slow powershell (hook timeout is 5 s)" "1" "$([ $(( (t1 - t0) / 1000000 )) -lt 2500 ] && echo 1 || echo 0)"
check "session-start wsl: first session has no preflight line yet" "" "$out"
check_contains "session-start wsl: RemoveGroup via the resolved powershell" "RemoveGroup" "$(grep '^SCRIPT' "$PS_LOG")"
check_contains "session-start wsl: RemoveGroup script silences progress output" "ProgressPreference" "$(grep '^SCRIPT' "$PS_LOG")"
wait_probe
out="$(ss "$TMP/version.wsl")"; rc=$?
check "session-start wsl: 2nd session rc 0" "0" "$rc"
check_contains "session-start wsl: 2nd session prints the preflight line" "ToastEnabled=0" "$out"
reset_state
out="$(CLAUDE_MB_NOTIFY_TOAST=false FAKE_PS_OUT='T=0;G=1;A=1' ss "$TMP/version.wsl")"; rc=$?
sleep 0.2
check "session-start switch off: rc 0" "0" "$rc"
check "session-start switch off: no stdout" "" "$out"
check "session-start switch off: no powershell call at all" "" "$(cat "$PS_LOG")"
reset_state
: > "$CLAUDE_MB_SIGNAL_PROC_MOUNTS"
out="$(ss "$TMP/version.wsl")"; rc=$?
check "session-start wsl, no powershell: rc 0" "0" "$rc"
check_contains "session-start wsl, no powershell: one context line" "powershell.exe could not be found" "$out"
write_mounts_c
rm -f -- "$SS_FIRST"

echo "test-toast-delivery: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

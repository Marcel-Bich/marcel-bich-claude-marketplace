#!/bin/bash
# Tests for credo_session_name.py - the one fallback order for every peer / session name
# credo shows:  caption -> kitty label -> tmux label -> short session id.
#
# Everything runs against a throwaway tree: a fake process table (module attribute
# PROC_ROOT), fake tmux and kitty binaries, a fake CODEX_HOME and a fake profile. No
# real session is touched, nothing is installed, no daemon is started.
#
# Covered:
#   - clean(): NFC, control and format characters removed, charset filter (letters,
#     digits, space . _ -), whitespace collapsed, capped, NFC again after filtering
#     (idempotent, decomposed jamo); is_caption() / caption_key(); confusables() /
#     confusable_warning() (Latin lookalikes, NFKC changes); open_own_file()
#   - claude_caption(): only nameSource "user" counts, truncated to 20 chars
#   - codex_caption(): newest session_index.jsonl row wins, unnamed thread -> none, only
#     the last 256 KiB are read, symlink / non-regular / foreign-owner file refused,
#     thread_name sanitized and capped
#   - pick(): caption > kitty > tmux > short id, blanks skipped, EVERY name capped at 20
#     (caption and kitty / tmux labels alike)
#   - tmux label through the process chain, and through the client pane of a
#     daemon-hosted session (which has no tmux of its own)
#   - tmux pane / client lists cached across snapshots (TTL), kitty time budget per snapshot
#   - kitty label: tab title of the window found through the process chain (also via
#     the tmux client of the session), signal prefixes stripped, failures -> none
#   - credo-peer-check.py rows: user caption, derived name ignored (tmux session wins),
#     short id as the last resort, Codex thread names (an unnamed Codex thread takes the
#     tmux session of the one Codex pane, never a guess among several), live sockets
#     without a descriptor named by the same order (kitty tab, tmux session, "pid N")
#   - credo-peer-lan.py roster: the same order for the name a machine announces
#
# Usage: bash test-credo-session-name.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/credo-peer-check.py"
DAEMON="$SCRIPT_DIR/credo-peer-lan.py"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi
if [ ! -f "$SCRIPT_DIR/credo_session_name.py" ]; then echo "FAIL: credo_session_name.py missing"; exit 1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csn.XXXXXX")"
PIDS=""
cleanup() {
    for p in $PIDS; do kill -KILL "$p" 2>/dev/null || true; done
    for p in $PIDS; do wait "$p" 2>/dev/null || true; done
    rm -rf -- "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { # name cond(0=pass)
    if [ "$2" = "0" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; fi
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# Unit tests of the module (fake process table, fake tmux / kitty)
# ---------------------------------------------------------------------------
mkdir -p "$TMP/unit/bin"
cat > "$TMP/unit/test_unit.py" <<'PYEOF'
import json, os, stat, sys
script_dir, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, script_dir)
import credo_session_name as names

passed, failed = 0, []
def expect(cond, msg):
    global passed
    if cond:
        passed += 1
    else:
        failed.append(msg)

# --- clean ---------------------------------------------------------------
expect(names.clean("  a\x00b\x1b[31mc\x7f\u202e d\u200bef  ", 50) == "ab31mc def", "clean strips control/format chars: %r" % names.clean("  a\x00b\x1b[31mc\x7f\u202e d\u200bef  ", 50))
# charset filter: only letters, digits, space, ".", "_", "-" survive
expect(names.clean('a(b)c!@#:"<x>/\\ y.z_w-v', 50) == "abcx y.z_w-v", "clean charset filter: %r" % names.clean('a(b)c!@#:"<x>/\\ y.z_w-v', 50))
expect(names.clean("Pr\u00fcfung \u00df", 50) == "Pr\u00fcfung \u00df", "clean keeps letters with umlauts")
expect(names.clean("Pru\u0308fung", 50) == "Pr\u00fcfung", "clean NFC-normalizes: %r" % names.clean("Pru\u0308fung", 50))
expect(names.clean("ship \U0001F680 it", 50) == "ship it", "clean drops emoji: %r" % names.clean("ship \U0001F680 it", 50))
expect(names.clean("x\u00b2\u2165", 50) == "x", "clean drops superscripts / letter-like numbers: %r" % names.clean("x\u00b2\u2165", 50))
expect(names.clean("  !!  ", 50) == "", "clean of only filtered chars is empty")
# is_caption: exactly what clean() keeps, 1..20 characters
expect(names.is_caption("alice") and names.is_caption("My Task 2.b_c-d"), "is_caption accepts clean names")
expect(not names.is_caption("x" * 21), "is_caption rejects > 20 chars")
expect(not names.is_caption("a(b)") and not names.is_caption(" a") and not names.is_caption("a  b"), "is_caption rejects unclean text")
expect(not names.is_caption("") and not names.is_caption(None) and not names.is_caption(5), "is_caption rejects empty / non-text")
expect(names.caption_key("Alice") == names.caption_key("aLiCe") and names.caption_key("a") != names.caption_key("b"), "caption_key folds case")
expect(names.clean("a\n\tb   c", 50) == "a b c", "clean collapses whitespace")
expect(names.clean("x" * 30, 20) == "x" * 20, "clean caps length")
expect(names.clean("ab cd", 3) == "ab", "clean trims the cut end")
expect(names.clean(None, 20) == "" and names.clean(5, 20) == "" and names.clean(["a"], 20) == "", "clean tolerates non-text")
# clean is idempotent: a filtered character between decomposed Hangul jamo must not
# leave a non-NFC result (NFC runs again after filtering)
jamo = "\u1100\u200b\u1161 x"
expect(names.clean(jamo, 20) == "\uac00 x", "clean re-composes jamo after filtering: %r" % names.clean(jamo, 20))
expect(names.clean(names.clean(jamo, 20), 20) == names.clean(jamo, 20), "clean is idempotent (jamo)")
expect(names.is_caption(names.clean(jamo, 20)), "clean(jamo) is a caption")
# confusables: Latin lookalikes from other scripts and NFKC changes are flagged
# (warning only, nothing is rejected); plain Latin, umlauts and CJK are not
expect(names.confusables("alice") == [] and names.confusables("Pr\u00fcfung \u00df") == [], "no confusables in Latin text")
expect(names.confusables("\u6771\u4eac task") == [], "CJK is not a Latin lookalike")
expect("U+0410" in " ".join(names.confusables("\u0410lice")), "Cyrillic A flagged: %r" % names.confusables("\u0410lice"))
expect("U+03BF" in " ".join(names.confusables("b\u03bfb")), "Greek omicron flagged: %r" % names.confusables("b\u03bfb"))
expect(any("NFKC" in c for c in names.confusables("\uff42ob")), "fullwidth letter flagged (NFKC): %r" % names.confusables("\uff42ob"))
expect(names.confusables(None) == [] and names.confusables("") == [], "confusables tolerates empty / non-text")
expect(names.confusable_warning("alice") == "", "no warning for a plain caption")
w = names.confusable_warning("\u0410lice")
expect("WARNING" in w and "U+0410" in w and "look" in w, "warning names the character: %r" % w)
expect(names.NAME_MAX == 20, "caption cap is 20")
expect(names.LABEL_MAX == 20, "kitty / tmux label cap is 20 as well: %r" % names.LABEL_MAX)

# --- sid_short (moved here, still reachable from credo-peer-lan) ----------------
expect(names.sid_short("a1b2c3d4-e5f6-4789-8abc-def012345678") == "a-e-4-8-d8", "sid_short")
expect(names.sid_short("plain") == "pn", "sid_short without dashes")
expect(names.sid_short(None) == "??", "sid_short tolerates None: %r" % names.sid_short(None))

# --- claude_caption ----------------------------------------------------------
expect(names.claude_caption({"name": "My Task", "nameSource": "user"}) == "My Task", "user name is the caption")
expect(names.claude_caption({"name": "x" * 40, "nameSource": "user"}) == "x" * 20, "caption truncated to 20")
expect(names.claude_caption({"name": "box-1-e5", "nameSource": "derived"}) is None, "derived never counts")
expect(names.claude_caption({"name": "box-1-e5"}) is None, "no nameSource never counts")
expect(names.claude_caption({"name": "m", "nameSource": "credo-peer-lan"}) is None, "mirror name never counts")
expect(names.claude_caption({"name": "", "nameSource": "user"}) is None, "empty user name -> none")
expect(names.claude_caption({"name": "   ", "nameSource": "user"}) is None, "blank user name -> none")
expect(names.claude_caption({"name": 5, "nameSource": "user"}) is None, "non-text name -> none")
expect(names.claude_caption("nope") is None and names.claude_caption(None) is None, "non-dict -> none")
expect(names.claude_caption({"name": "a\x1bb\nc", "nameSource": "user"}) == "ab c", "caption sanitized")

# --- codex_caption -------------------------------------------------------------
ch = os.path.join(tmp, "codex")
os.makedirs(ch)
idx = os.path.join(ch, "session_index.jsonl")
def write_idx(lines, path=idx, mode="w"):
    with open(path, mode) as fh:
        fh.write("".join(l + "\n" for l in lines))
write_idx([
    json.dumps({"id": "t-1", "thread_name": "old name", "updated_at": "x"}),
    json.dumps({"id": "t-2", "thread_name": "other"}),
    json.dumps({"id": "t-1", "thread_name": "new name"}),
    "not json at all",
    json.dumps(["not", "a", "dict"]),
    json.dumps({"id": "t-3", "thread_name": 7}),
    json.dumps({"id": "t-4", "thread_name": "ctl\x1bname\u202e " + "z" * 40, "extra": "ignored"}),
])
expect(names.codex_caption("t-1", ch) == "new name", "newest matching row wins: %r" % names.codex_caption("t-1", ch))
expect(names.codex_caption("t-2", ch) == "other", "other thread found")
expect(names.codex_caption("t-unnamed", ch) is None, "unnamed thread has no row -> none")
expect(names.codex_caption("t-3", ch) is None, "non-text thread_name -> none")
cap = names.codex_caption("t-4", ch)
expect(cap == ("ctlname " + "z" * 12), "thread_name sanitized and capped to 20: %r" % cap)
expect(names.codex_caption("", ch) is None and names.codex_caption(None, ch) is None, "empty id -> none")
expect(names.codex_caption("t-1", os.path.join(tmp, "nope")) is None, "missing index -> none")
# the newest row is the only one that counts, even when it clears the name
write_idx([json.dumps({"id": "t-5", "thread_name": "was named"}),
           json.dumps({"id": "t-5", "thread_name": ""})])
expect(names.codex_caption("t-5", ch) is None, "newest row with an empty name -> none")
# only the last 256 KiB are read
write_idx([json.dumps({"id": "t-old", "thread_name": "too old"})])
with open(idx, "a") as fh:
    for i in range(6000):
        fh.write(json.dumps({"id": "f-%d" % i, "thread_name": "filler %d" % i, "pad": "p" * 60}) + "\n")
    fh.write(json.dumps({"id": "t-new", "thread_name": "recent"}) + "\n")
expect(os.path.getsize(idx) > 300 * 1024, "fixture larger than the window")
expect(names.codex_caption("t-old", ch) is None, "row beyond the last 256 KiB is not read")
expect(names.codex_caption("t-new", ch) == "recent", "row inside the window is read")
# a symlink is refused (O_NOFOLLOW), also a symlink to a valid file
real = os.path.join(tmp, "real_index.jsonl")
write_idx([json.dumps({"id": "t-1", "thread_name": "via link"})], real)
ch2 = os.path.join(tmp, "codex2"); os.makedirs(ch2)
os.symlink(real, os.path.join(ch2, "session_index.jsonl"))
expect(names.codex_caption("t-1", ch2) is None, "symlinked index refused")
# not a regular file
ch3 = os.path.join(tmp, "codex3"); os.makedirs(os.path.join(ch3, "session_index.jsonl"))
expect(names.codex_caption("t-1", ch3) is None, "directory as index refused")
ch4 = os.path.join(tmp, "codex4"); os.makedirs(ch4)
os.mkfifo(os.path.join(ch4, "session_index.jsonl"))
expect(names.codex_caption("t-1", ch4) is None, "fifo as index refused (no hang)")
# owned by another user
write_idx([json.dumps({"id": "t-1", "thread_name": "mine"})], os.path.join(ch, "session_index.jsonl"))
expect(names.codex_caption("t-1", ch) == "mine", "own file read")
expect(names.codex_caption("t-1", ch, uid=os.geteuid() + 1) is None, "file of another uid refused")
# open_own_file: the shared safe-open (also used for the LAN trust file)
own = os.path.join(tmp, "own.json")
with open(own, "w") as fh:
    fh.write("{}")
os.chmod(own, 0o600)
fd = names.open_own_file(own, private=True)
expect(isinstance(fd, int), "open_own_file opens an own 0600 file")
os.close(fd)
os.chmod(own, 0o620)
try:
    names.open_own_file(own, private=True); ok_gw = False
except names.UnsafeFile:
    ok_gw = True
expect(ok_gw, "open_own_file(private) refuses a group-writable file")
fd = names.open_own_file(own)
expect(isinstance(fd, int), "open_own_file without private ignores the mode")
os.close(fd)
try:
    names.open_own_file(os.path.join(tmp, "absent.json")); ok_nf = False
except FileNotFoundError:
    ok_nf = True
expect(ok_nf, "open_own_file: a missing file raises FileNotFoundError")
# CODEX_HOME default
os.environ["CODEX_HOME"] = ch
expect(names.codex_caption("t-1") == "mine", "CODEX_HOME is the default home")
del os.environ["CODEX_HOME"]

# --- pick ----------------------------------------------------------------------
sid = "a1b2c3d4-e5f6-4789-8abc-def012345678"
expect(names.pick("Cap", "kit", "tm", sid) == "Cap", "caption first")
expect(names.pick(None, "kit", "tm", sid) == "kit", "kitty second")
expect(names.pick("", "  ", "tm", sid) == "tm", "blank values skipped, tmux third")
expect(names.pick(None, None, None, sid) == "a-e-4-8-d8", "short id last")
expect(names.pick("x" * 40, None, None, sid) == "x" * 20, "caption capped in pick")
expect(names.pick(None, None, "y" * 100, sid) == "y" * 20, "tmux label capped to 20")
expect(names.pick(None, "k" * 100, None, sid) == "k" * 20, "kitty label capped to 20")
expect(names.pick(None, "k\x1bk", None, sid) == "kk", "labels sanitized")

# --- fake process table ---------------------------------------------------------
proc = os.path.join(tmp, "proc")
def mkproc(pid, ppid, comm="bash", exe=None):
    d = os.path.join(proc, str(pid)); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "stat"), "w") as fh:
        fh.write("%d (%s) S %d 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n" % (pid, comm, ppid))
    with open(os.path.join(d, "comm"), "w") as fh:
        fh.write(comm + "\n")
    if exe:
        os.symlink(exe, os.path.join(d, "exe"))
names.PROC_ROOT = proc
# kitty(10) -> shell(11, kitty window) -> tmux client(12)
# tmux server(20) -> pane shell(21, pane pid) -> claude(22)
# kitty(10) -> shell(13, a plain window) -> claude(14)
# daemon-hosted: tmux server(20) -> pane shell(23) -> client(24) ... daemon(30) -> pty(31) -> agent(32)
mkproc(10, 1, "kitty"); mkproc(11, 10); mkproc(12, 11, "tmux: client")
mkproc(20, 1, "tmux: server"); mkproc(21, 20); mkproc(22, 21, "claude")
mkproc(13, 10); mkproc(14, 13, "claude")
mkproc(15, 10); mkproc(16, 15, "claude")
mkproc(23, 20); mkproc(24, 23, "claude")
mkproc(30, 1, "claude"); mkproc(31, 30, "claude"); mkproc(32, 31, "claude")
mkproc(40, 1, "x-terminal-emul", exe="/usr/bin/kitty"); mkproc(41, 40); mkproc(42, 41, "claude")

expect(names.ancestors(22) == [22, 21, 20], "ancestors stop below pid 1: %r" % names.ancestors(22))

# fake tmux
tmux = os.path.join(tmp, "bin", "tmux")
tcalls = os.path.join(tmp, "tmux.calls")
with open(tmux, "w") as fh:
    fh.write("""#!/bin/bash
echo "$*" >> "%s"
case "$*" in
  *list-panes*) printf 'disk\\t21\\nlab\\t23\\n' ;;
  *list-clients*) printf 'disk\\t12\\n' ;;
  *) exit 1 ;;
esac
""" % tcalls)
os.chmod(tmux, 0o755)
# fake kitty: `kitty @ --to unix:SOCK ls`
kitty = os.path.join(tmp, "bin", "kitty")
kcalls = os.path.join(tmp, "kitty.calls")
with open(kitty, "w") as fh:
    fh.write("""#!/bin/bash
echo "$*" >> "%s"
[ -n "$FAKE_KITTY_FAIL" ] && exit 1
cat <<'EOF'
[{"id": 1, "tabs": [
  {"id": 1, "title": "[AI...] shop-frontend", "windows": [{"id": 1, "pid": 11}]},
  {"id": 2, "title": "plain tab", "windows": [{"id": 2, "pid": 13}]},
  {"id": 3, "title": "[FIN] [ASK] other", "windows": [{"id": 3, "pid": 41}]},
  {"id": 4, "title": "", "windows": [{"id": 4, "pid": 99}]},
  {"id": 5, "title": "[AI...] a kitty tab title far beyond twenty", "windows": [{"id": 5, "pid": 15}]}
]}]
EOF
""" % kcalls)
os.chmod(kitty, 0o755)

def snap(**kw):
    kw.setdefault("tmux_bin", tmux)
    kw.setdefault("kitty_bin", kitty)
    kw.setdefault("kitty_socket", "unix:/fake/kitty.sock")
    kw.setdefault("kitty_ttl", 0)
    kw.setdefault("pane_ttl", 0)
    kw.setdefault("client_of", lambda pid: None)
    return names.Snapshot(**kw)

# --- tmux label --------------------------------------------------------------------
s = snap()
expect(s.tmux_label(22) == "disk", "tmux label through the process chain: %r" % s.tmux_label(22))
expect(s.tmux_label(21) == "disk", "the pane pid itself")
expect(s.tmux_label(14) is None, "no tmux for a plain kitty window")
expect(snap(tmux_bin=None).tmux_label(22) is None, "no tmux binary -> none")
expect(snap(tmux_bin="/nonexistent/tmux").tmux_label(22) is None, "missing tmux binary -> none")
# panes handed in by the caller (credo-peer-check already listed them)
s = snap(tmux_bin="/nonexistent/tmux", panes=[("handed", [21], "1700000000")])
expect(s.tmux_label(22) == "handed", "panes from the caller are used")
# daemon-hosted session: the agent chain (32,31,30) has no pane; its client TUI (24) has
s = snap(client_of=lambda pid: 24 if pid == 32 else None)
expect(s.tmux_label(32) == "lab", "daemon-hosted session resolves through its client pane: %r" % s.tmux_label(32))
s = snap(client_of=lambda pid: None)
expect(s.tmux_label(32) is None, "daemon-hosted without a resolvable client -> none (fail closed)")
calls = []
s = snap(client_of=lambda pid: calls.append(pid))
s.tmux_label(22)
expect(calls == [], "client lookup only when the own chain has no pane")

# --- tmux lists cached across snapshots (a roster tick builds a Snapshot every few seconds)
import time as _time
names._TMUX_CACHE.clear()
open(tcalls, "w").close()
def tcount(word):
    return sum(1 for ln in open(tcalls).read().splitlines() if word in ln)
a_ = snap(pane_ttl=30); a_.tmux_label(22)
b_ = snap(pane_ttl=30); b_.tmux_label(22)
expect(tcount("list-panes") == 1, "pane map reused across snapshots inside the TTL: %d calls" % tcount("list-panes"))
expect(b_.tmux_label(22) == "disk", "cached pane map still resolves")
a_.kitty_label(22, tmux_session="disk"); b_.kitty_label(22, tmux_session="disk")
expect(tcount("list-clients") == 1, "client list reused across snapshots inside the TTL: %d calls" % tcount("list-clients"))
c_ = snap(pane_ttl=0); c_.tmux_label(22)
expect(tcount("list-panes") == 2, "pane_ttl 0 never reuses the cache")
names._TMUX_CACHE.clear()
d_ = snap(pane_ttl=0.05); d_.tmux_label(22); _time.sleep(0.12)
e_ = snap(pane_ttl=0.05); e_.tmux_label(22)
expect(tcount("list-panes") == 4, "expired cache entry is refreshed: %d calls" % tcount("list-panes"))
# panes handed in by the caller bypass the cache and the tmux binary
open(tcalls, "w").close()
snap(pane_ttl=30, panes=[("handed", [21], "1")]).tmux_label(22)
expect(tcount("list-panes") == 0, "caller-supplied panes never call tmux")
# a different tmux binary does not share cache entries
names._TMUX_CACHE.clear()

# --- kitty label -------------------------------------------------------------------
open(kcalls, "w").close()
s = snap()
expect(s.kitty_label(14) == "plain tab", "kitty tab of the window found through the chain: %r" % s.kitty_label(14))
expect(s.kitty_label(42) == "other", "kitty found by exe name, [FIN] [ASK] prefixes stripped: %r" % s.kitty_label(42))
expect(s.kitty_label(32) is None, "no kitty above a daemon agent without client")
s = snap(client_of=lambda pid: 12 if pid == 32 else None)
expect(s.kitty_label(32) == "shop-frontend", "daemon-hosted session: kitty via the client chain, [AI...] stripped: %r" % s.kitty_label(32))
s = snap()
expect(s.kitty_label(22, tmux_session="disk") == "shop-frontend", "tmux session: kitty via the attached client: %r" % s.kitty_label(22, tmux_session="disk"))
expect(s.kitty_label(22) is None, "tmux pane without a session hint has no kitty ancestry")
expect(s.kitty_label(22, tmux_session="nope") is None, "session without clients -> none")
calls_txt = open(kcalls).read()
expect("--to unix:/fake/kitty.sock" in calls_txt and calls_txt.split().count("ls") >= 1, "kitty called with the socket: %r" % calls_txt)
expect(s.kitty_label(16) == "a kitty tab title fa", "kitty tab title capped to 20: %r" % s.kitty_label(16))
# one kitty call per snapshot, however many sessions ask
open(kcalls, "w").close()
s = snap(kitty_ttl=30)
s.kitty_label(14); s.kitty_label(42); s.kitty_label(14)
expect(len(open(kcalls).read().splitlines()) == 1, "kitty tabs cached inside one snapshot / ttl")
# failure modes
os.environ["FAKE_KITTY_FAIL"] = "1"
expect(snap().kitty_label(14) is None, "failing kitty -> none")
del os.environ["FAKE_KITTY_FAIL"]
expect(snap(kitty_bin="/nonexistent/kitty").kitty_label(14) is None, "missing kitty binary -> none")
os.environ.pop("KITTY_LISTEN_ON", None)
expect(snap(kitty_socket="", kitty_glob=[]).kitty_label(14) is None, "no socket found -> none")
expect(snap().kitty_label(99999) is None, "unknown pid -> none")

# several unresponsive kitty sockets must not add up: one total time budget per snapshot
import socket as _socket
sockdir = os.path.join(tmp, "socks"); os.makedirs(sockdir, exist_ok=True)
keep_ = []
for i_ in range(3):
    so_ = _socket.socket(_socket.AF_UNIX); so_.bind(os.path.join(sockdir, "ks%d" % i_)); keep_.append(so_)
slow = os.path.join(tmp, "bin", "kitty-slow")
with open(slow, "w") as fh:
    fh.write("#!/bin/bash\nexec sleep 5\n")
os.chmod(slow, 0o755)
os.environ.pop("KITTY_LISTEN_ON", None)
t0 = _time.monotonic()
res_ = snap(kitty_bin=slow, kitty_glob=[os.path.join(sockdir, "ks*")], kitty_budget=0.6).kitty_label(14)
spent = _time.monotonic() - t0
expect(res_ is None, "unresponsive kitty -> none")
expect(spent < 1.8, "kitty time capped by the budget (4 addresses x 5 s hang): %.2f s" % spent)

# the default client lookup (credo-self-restart.py daemon_link) knows nothing about a
# plain process or a pid that does not exist: no client, no label
names.PROC_ROOT = "/proc"
expect(names._daemon_client(os.getpid()) is None, "plain session has no daemon client")
expect(names._daemon_client(2 ** 22 + 12345) is None, "unknown pid has no daemon client")
names.PROC_ROOT = proc

# --- names from a descriptor ---------------------------------------------------------
s = snap(tmux_bin="/nonexistent/tmux", kitty_bin="/nonexistent/kitty")
d = {"pid": 22, "sessionId": sid, "name": "box-1-e5", "nameSource": "derived"}
expect(names.claude_name(d, s) == "a-e-4-8-d8", "derived name, nothing else -> short id")
s = snap()
expect(names.claude_name(d, s) == "shop-frontend", "kitty (via tmux client) before tmux: %r" % names.claude_name(d, s))
d["name"], d["nameSource"] = "My Task", "user"
expect(names.claude_name(d, s) == "My Task", "user caption before everything")
d2 = {"pid": 14, "sessionId": sid, "name": "x", "nameSource": "derived"}
expect(names.claude_name(d2, s) == "plain tab", "kitty only")
d3 = {"pid": 22, "sessionId": sid}
expect(names.claude_name(d3, snap(kitty_bin="/nonexistent/kitty")) == "disk", "tmux label when no kitty")
expect(names.claude_name({"sessionId": sid}, None) == "a-e-4-8-d8", "no pid, no snapshot -> short id")
expect(names.claude_name({"pid": 99999, "sessionId": sid}, snap(kitty_bin="/nonexistent/kitty"), tmux="given") == "given", "tmux label handed in by the caller is used")
expect(names.claude_name(None, None, sid=sid) == "a-e-4-8-d8", "no descriptor -> short id")

# codex names
os.environ["CODEX_HOME"] = ch
write_idx([json.dumps({"id": "cx-1", "thread_name": "Refactor parser"})])
expect(names.codex_name("cx-1", None) == "Refactor parser", "codex caption")
expect(names.codex_name("cx-2", None) == names.sid_short("cx-2"), "unnamed codex thread -> short id")
expect(names.codex_name("cx-2", s, tmux="lab") == "lab", "codex tmux label before the short id")
del os.environ["CODEX_HOME"]

print("UNIT passed=%d failed=%d" % (passed, len(failed)))
for f in failed:
    print("FAIL " + f)
sys.exit(1 if failed else 0)
PYEOF
UOUT="$("$PY" -I "$TMP/unit/test_unit.py" "$SCRIPT_DIR" "$TMP/unit" 2>&1)"; URC=$?
printf '%s\n' "$UOUT" | grep '^FAIL ' || true
ok "unit tests of credo_session_name (${UOUT##*$'\n'})" "$URC"
case "$UOUT" in *"UNIT passed="*) UN="$(printf '%s\n' "$UOUT" | sed -n 's/^UNIT passed=\([0-9]*\) failed=.*/\1/p')"; PASS=$((PASS + ${UN:-0})) ;; esac

# ---------------------------------------------------------------------------
# credo-peer-check.py rows
# ---------------------------------------------------------------------------
HOME_DIR="$TMP/home"
CFG="$HOME_DIR/.claude"
CODEX="$TMP/codex"
SOCK_RUN="$TMP/run/cc-socks"
mkdir -p "$CFG/sessions" "$CFG/credo" "$SOCK_RUN" "$CODEX/credo/peer-lan/sessions" "$TMP/bin"

sleep 600 & P_U=$!; PIDS="$PIDS $P_U"   # user caption, also in tmux "disk"
sleep 600 & P_D=$!; PIDS="$PIDS $P_D"   # derived name, in tmux "disk2"
sleep 600 & P_N=$!; PIDS="$PIDS $P_N"   # derived name, no tmux
sleep 600 & P_K=$!; PIDS="$PIDS $P_K"   # live socket without a descriptor, tmux "disk4" under a kitty tab
sleep 600 & P_Z=$!; PIDS="$PIDS $P_Z"   # live socket without a descriptor, nothing else known
# fake kitty: a process named kitty (copy of bash) holding the tmux client of "disk4"
cp "$(command -v bash)" "$TMP/bin/kitty"
"$TMP/bin/kitty" -c 'sleep 600 & echo $! > "$1"; wait' _ "$TMP/clientpid" & P_KITTY=$!; PIDS="$PIDS $P_KITTY"
for _ in $(seq 1 50); do [ -s "$TMP/clientpid" ] && break; sleep 0.1; done
P_CLIENT="$(cat "$TMP/clientpid" 2>/dev/null)"; PIDS="$PIDS $P_CLIENT"
# fake "codex" processes in tmux panes (copy of sleep, argv0 codex)
cp "$(command -v sleep)" "$TMP/bin/codex"
"$TMP/bin/codex" 600 & P_CX=$!; PIDS="$PIDS $P_CX"
"$TMP/bin/codex" 600 & P_CX2=$!; PIDS="$PIDS $P_CX2"
"$PY" - "$SOCK_RUN" "$P_U" "$P_D" "$P_N" "$P_K" "$P_Z" <<'PYEOF' &
import socket, sys, time
keep = []
for pid in sys.argv[2:]:
    s = socket.socket(socket.AF_UNIX); s.bind("%s/%s.sock" % (sys.argv[1], pid)); s.listen(1); keep.append(s)
time.sleep(600)
PYEOF
HOLDER=$!; PIDS="$PIDS $HOLDER"
for _ in $(seq 1 50); do [ -S "$SOCK_RUN/$P_N.sock" ] && break; sleep 0.1; done

desc() { # pid sid name nameSource
    "$PY" - "$CFG/sessions/$1.json" "$@" "$SOCK_RUN" <<'PYEOF'
import json, sys
path, pid, sid, name, src, run = sys.argv[1:7]
d = {"pid": int(pid), "sessionId": sid, "name": name, "messagingSocketPath": "%s/%s.sock" % (run, pid),
     "status": "idle", "updatedAt": 1700000000000, "kind": "interactive"}
if src != "-":
    d["nameSource"] = src
json.dump(d, open(path, "w"))
PYEOF
}
desc "$P_U" sid-user "My Long Caption That Is Very Long" user
desc "$P_D" sid-derived workstation-e5 derived
desc "$P_N" sid-nameless-box workstation-e6 derived

cat > "$TMP/bin/tmux" <<EOF
#!/bin/bash
case "\$*" in
  *list-panes*) printf '%s\t%s\n' disk $P_U disk2 $P_D disk4 $P_K cx-pane $P_CX ;;
  *list-sessions*) printf '%s\t%s\n' disk 1700000100 disk2 1700000200 disk4 1700000300 cx-pane 1700000400 ;;
  *list-clients*) printf '%s\t%s\n' disk4 $P_CLIENT ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/tmux"
# a second Codex pane: an unnamed Codex thread can no longer be tied to one tmux session
cat > "$TMP/bin/tmux2" <<EOF
#!/bin/bash
case "\$*" in
  *list-panes*) printf '%s\t%s\n' disk $P_U disk2 $P_D disk4 $P_K cx-pane $P_CX cx-pane2 $P_CX2 ;;
  *list-sessions*) printf '%s\t%s\n' disk 1700000100 disk2 1700000200 disk4 1700000300 cx-pane 1700000400 cx-pane2 1700000500 ;;
  *list-clients*) printf '%s\t%s\n' disk4 $P_CLIENT ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/tmux2"
# fake kitty remote control: the tab title of the window that holds the tmux client
cat > "$TMP/bin/kls" <<EOF
#!/bin/bash
cat <<'JSON'
[{"id": 1, "tabs": [{"id": 1, "title": "[AI...] tab-of-disk4", "windows": [{"id": 1, "pid": $P_CLIENT}]}]}]
JSON
EOF
chmod +x "$TMP/bin/kls"

# Codex relay sessions and the Codex session index (thread names)
"$PY" - "$CODEX" <<'PYEOF'
import json, os, sys
root = sys.argv[1]
sd = os.path.join(root, "credo", "peer-lan", "sessions")
for sid in ("thread-named", "thread-plain"):
    json.dump({"sessionId": sid, "name": "relay-derived-" + sid, "active": True, "status": "idle",
               "lastSeen": 1700000000}, open(os.path.join(sd, sid + ".json"), "w"))
with open(os.path.join(root, "session_index.jsonl"), "w") as fh:
    fh.write(json.dumps({"id": "thread-named", "thread_name": "old title"}) + "\n")
    fh.write(json.dumps({"id": "thread-named", "thread_name": "Codex Thread Title"}) + "\n")
PYEOF

run_check() {
    env -u XDG_RUNTIME_DIR HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CFG" CODEX_HOME="$CODEX" \
        CREDO_PEER_CHECK_SOCK_DIRS="$SOCK_RUN" CREDO_PEER_CHECK_TMUX="${TMUX_FAKE:-$TMP/bin/tmux}" \
        CREDO_KITTY_BIN="$TMP/bin/kls" CREDO_KITTY_SOCKET="unix:/fake/kitty.sock" \
        CREDO_PEER_CHECK_LAN_SCRIPT="" CREDO_PEER_CHECK_CODEX_PEER="" \
        CREDO_PEER_LAN_CONFIG="$TMP/none.json" \
        "$PY" "$CHECK" "$@"
}
J="$(run_check --json --no-lan-check 2>/dev/null)"
"$PY" - "$J" "$P_K" "$P_Z" <<'PYEOF'
import json, sys
rows = json.loads(sys.argv[1])["peers"]
def one(sid):
    r = [x for x in rows if x.get("session_id") == sid]
    return r[0] if r else None
errs = []
u = one("sid-user")
if not u or u["name"] != "My Long Caption That":
    errs.append("user caption (truncated to 20) expected, got %r" % (u and u["name"]))
d = one("sid-derived")
if not d or d["name"] != "disk2":
    errs.append("derived name must give way to the tmux session disk2, got %r" % (d and d["name"]))
n = one("sid-nameless-box")
if not n or n["name"] != "s-n-bx":
    errs.append("short session id expected, got %r" % (n and n["name"]))
if any(r["name"] in ("workstation-e5", "workstation-e6") for r in rows):
    errs.append("a derived name was shown")
cn = one("thread-named")
if not cn or cn["name"] != "Codex Thread Title":
    errs.append("codex thread caption expected, got %r" % (cn and cn["name"]))
cp = one("thread-plain")
if not cp or cp["name"] != "cx-pane":
    errs.append("unnamed codex thread must take the tmux session of the one Codex pane, got %r" % (cp and cp["name"]))
byname = {r["pid"]: r for r in rows if r.get("pid")}
k = byname.get(int(sys.argv[2]))
if not k or k["name"] != "tab-of-disk4":
    errs.append("live socket without descriptor: kitty tab title expected, got %r" % (k and k["name"]))
z = byname.get(int(sys.argv[3]))
if not z or z["name"] != "pid %s" % sys.argv[3]:
    errs.append("live socket without any label: pid N expected, got %r" % (z and z["name"]))
if errs:
    print("\n".join(errs)); sys.exit(1)
PYEOF
ok "peer-check rows: caption, tmux label instead of a derived name, short id, codex thread names, unregistered sockets" "$?"

# two Codex panes: an unnamed thread cannot be tied to either -> short id
J2="$(TMUX_FAKE="$TMP/bin/tmux2" run_check --json --no-lan-check 2>/dev/null)"
"$PY" - "$J2" <<'PYEOF'
import json, sys
rows = json.loads(sys.argv[1])["peers"]
cp = [r for r in rows if r.get("session_id") == "thread-plain"]
if not cp or cp[0]["name"] != "t-pn":
    print("ambiguous Codex panes must not label the thread, got %r" % (cp and cp[0]["name"])); sys.exit(1)
PYEOF
ok "peer-check rows: unnamed codex thread with two Codex panes keeps its short id" "$?"

# ---------------------------------------------------------------------------
# credo-peer-lan.py roster: the name a machine announces
# ---------------------------------------------------------------------------
mkdir -p "$TMP/lan/cfg/sessions" "$TMP/lan/bin"
sleep 600 & P_RU=$!; PIDS="$PIDS $P_RU"
sleep 600 & P_RD=$!; PIDS="$PIDS $P_RD"
sleep 600 & P_RN=$!; PIDS="$PIDS $P_RN"
cat > "$TMP/lan/bin/tmux" <<EOF
#!/bin/bash
case "\$*" in
  *list-panes*) printf '%s\t%s\n' disk $P_RD ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/lan/bin/tmux"
LAN_OUT="$("$PY" - "$DAEMON" "$TMP/lan" "$P_RU" "$P_RD" "$P_RN" "$TMP/lan/bin" 2>&1 <<'PYEOF'
import importlib.util, json, os, sys
daemon_path, tmp, pu, pd, pn, binpath = sys.argv[1:7]
os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(tmp, "cfg")
os.environ["HOME"] = tmp
os.environ["PATH"] = binpath + os.pathsep + os.environ["PATH"]
os.environ["CREDO_PEER_LAN_SOCKDIR"] = os.path.join(tmp, "sock")
spec = importlib.util.spec_from_file_location("credo_peer_lan", daemon_path)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
sd = os.path.join(tmp, "cfg", "sessions")
def put(pid, sid, name, src):
    d = {"pid": int(pid), "sessionId": sid, "name": name,
         "messagingSocketPath": "/x/%s.sock" % pid, "status": "idle"}
    if src:
        d["nameSource"] = src
    json.dump(d, open(os.path.join(sd, "%s.json" % pid), "w"))
put(pu, "sid-ru", "A Quite Long Caption Name Here", "user")
put(pd, "sid-rd", "workstation-e5", "derived")
put(pn, "sid-rn-box", "workstation-e6", "derived")
got = []
mod.send_to_peer = lambda h, p, t, payload, timeout=5.0: got.append(payload)
d = mod.Daemon({"peers": ["127.0.0.1:5"], "listen_port": 48610})
d.lan_state = mod.compute_lan_state({}, None, d.peers)
d.roster_tick()
fails = []
if not got:
    fails.append("no roster sent")
else:
    seen = {s["sessionId"]: s["name"] for s in got[0]["sessions"]}
    if seen.get("sid-ru") != "A Quite Long Caption":
        fails.append("roster caption (truncated to 20) wrong: %r" % seen.get("sid-ru"))
    if seen.get("sid-rd") != "disk":
        fails.append("roster must announce the tmux session, not the derived name: %r" % seen.get("sid-rd"))
    if seen.get("sid-rn-box") != "s-r-bx":
        fails.append("roster short id wrong: %r" % seen.get("sid-rn-box"))
if mod.sid_short("plain") != "pn":
    fails.append("credo-peer-lan no longer exposes sid_short")
print("LAN_FAIL " + " | ".join(fails) if fails else "LAN_OK")
PYEOF
)"
case "$LAN_OUT" in *LAN_OK*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL roster names: %s\n' "$LAN_OUT" ;; esac

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

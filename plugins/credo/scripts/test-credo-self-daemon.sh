#!/bin/bash
# Tests for the Claude Code background-daemon support of credo-self-compact.py,
# credo-self-reload.py and credo-self-restart.py (shared helpers daemon_link,
# pane_env, state_sids in credo-self-restart.py).
#
# NOTHING real is touched: the process table is a FAKE tree under a temp dir (the
# module attribute PROC_ROOT points at it), tmux pane lookups are a fake mapping,
# every config dir is a temp dir. No real process, pane or tmux server is addressed.
#
# Process shape of a daemon-hosted session (Claude Code 2.1.29x):
#   pane shell -> TUI `claude --resume <name>` (TMUX/TMUX_PANE)
#     -> `claude daemon run --origin transient --spawned-by {"pid": <tui>, ...}`
#       -> `claude bg-pty-host --bg-pty-host <sock> --session-id <new>
#           --fork-session --resume <old>.jsonl`
#         -> agent process (new session id, NO TMUX env) -> the helper script
#
# It checks:
#   - plain tmux session: unchanged (own pane, no daemon, only the own session id)
#   - daemon chain: the pane comes from the client TUI, ownership is verified via the
#     client, credo mode and compact-plus breadcrumb of the pre-fork id carry over
#   - reparented daemon: the --spawned-by link is followed only when valid
#   - spoofed --spawned-by (non-Claude pid, foreign uid, started after the daemon, a
#     pid other than the daemon's parent, malformed JSON, string / bool pid): rejected
#   - fail closed: two client TUIs on one daemon, the spawning TUI not attached, two
#     sessions in one daemon (pool spares excluded), pty socket not held by the daemon,
#     socket table unreadable (the unix socket table is a fake mapping)
#   - --bg-pty-host only counts at the subcommand position; retitled argv[0]
#     ("claude bg-pty-host" as one token, the live shape) is parsed
#   - worker re-check: agent gone or a second client appearing -> refused
#   - no tmux anywhere (plain and daemon): clear "not running inside tmux" error
#   - a fork the user started by hand (no daemon) and a --session-id mismatch do not
#     map state ids
#   - self-reload uses the client pane; self-restart refuses a daemon-hosted session
#
# Usage: bash test-credo-self-daemon.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "SKIP: python3 not found"; exit 0; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/csd.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

cat > "$TMP/unit.py" <<'PYEOF'
import argparse, importlib.util, json, os, shutil, sys

scripts, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(scripts, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


compact = load("csc", "credo-self-compact.py")
reload_ = load("csl", "credo-self-reload.py")
restart = load("csr_t", "credo-self-restart.py")
import credo_pane_guard as guard

UID = os.getuid()
PANES = {}
guard.pane_info = lambda pane, socket=None: (
    {"pane": pane, "pid": PANES[pane], "in_mode": False, "dead": False}
    if pane in PANES else None)
shutil.which = lambda name, *a, **k: "/usr/bin/" + name

res = []


def t(name, cond):
    res.append(name if cond else "FAIL " + name)


TABLE = {}  # fake unix socket table {inode: (bound path, peer inode)}
for mod in (compact.csr, reload_.csr, restart):
    mod.unix_table = lambda: None if TABLE is None else dict(TABLE)


def fake_tree(name, procs):
    """procs: {pid: (ppid, argv, env dict, start, uid[, socket inodes])} -> fake proc
    root (fd links "socket:[N]" for the socket inodes)."""
    root = os.path.join(tmp, name)
    for pid, spec in procs.items():
        ppid, argv, env, start, uid = spec[:5]
        d = os.path.join(root, str(pid))
        os.makedirs(os.path.join(d, "fd"))
        for n, ino in enumerate(spec[5] if len(spec) > 5 else ()):
            os.symlink("socket:[%d]" % ino, os.path.join(d, "fd", str(10 + n)))
        if "/claude/versions/" in argv[0]:
            os.symlink(argv[0], os.path.join(d, "exe"))
        with open(os.path.join(d, "cmdline"), "wb") as fh:
            fh.write(b"\0".join(a.encode() for a in argv) + b"\0")
        with open(os.path.join(d, "stat"), "w") as fh:
            fh.write("%d (%s) S %d %s %d\n" % (pid, os.path.basename(argv[0])[:15], ppid,
                                                " ".join(["0"] * 17), start))
        with open(os.path.join(d, "envi" + "ron"), "wb") as fh:
            fh.write(b"\0".join(("%s=%s" % kv).encode() for kv in env.items()) + b"\0")
        with open(os.path.join(d, "status"), "w") as fh:
            fh.write("Name:\tx\nUid:\t%d\t%d\t%d\t%d\n" % (uid, uid, uid, uid))
    for mod in (compact.csr, reload_.csr, restart):
        mod.PROC_ROOT = root
    return root


CFG = os.path.join(tmp, "cfg")
os.makedirs(os.path.join(CFG, "credo", "session-modes"))
os.makedirs(os.path.join(CFG, "credo", "rehydrate"))
OLD, NEW, PLAIN = "old-sid-1111", "new-sid-2222", "plain-sid-3333"
with open(os.path.join(CFG, "credo", "session-modes", OLD), "w") as fh:
    fh.write("autonomous\n")
with open(os.path.join(CFG, "credo", "rehydrate", OLD), "w") as fh:
    fh.write(".credo/process/handoffs/HANDOFF.md\n")
with open(os.path.join(CFG, "credo", "rehydrate", PLAIN), "w") as fh:
    fh.write(".credo/process/handoffs/HANDOFF.md\n")
os.environ.pop("CREDO_REHYDRATE_DIR", None)
os.environ.pop("CREDO_SESSION_MODES_DIR", None)

AENV = {"CLAUDE_CONFIG_DIR": CFG}
TENV = {"CLAUDE_CONFIG_DIR": CFG, "TMUX": "/tmp/fake-sock,1,0", "TMUX_PANE": "%7"}


DDIR = "/tmp/cc-daemon-1000/abcd1234"
PTY, CTRL = DDIR + "/pty/x1.sock", DDIR + "/control.sock"
VEXE = "/opt/fake/claude/versions/2.1.0"


def host_argv(sock, tail):
    # live shape: the helper retitles itself, argv[0] is the single token
    # "claude bg-pty-host", then the flags, then "--" and the agent's argv
    return ["claude bg-pty-host", "--bg-pty-host", sock, "200", "50", "--", VEXE] + tail


def daemon_tree(name, daemon_ppid=110, spawned='{"pid": 110, "kind": "tui"}', extra=None,
                tui_env=TENV, host_sid=NEW, table=None, daemon_fds=(1002, 2001),
                client_fds=(2002,)):
    global TABLE
    procs = {
        100: (1, ["bash"], {}, 10, UID),
        110: (100, ["claude", "--resume", "demo-session"], tui_env, 20, UID, client_fds),
        120: (daemon_ppid, ["claude", "daemon", "run", "--origin", "transient",
                            "--spawned-by", spawned], {}, 30, UID, daemon_fds),
        130: (120, host_argv(PTY, ["--session-id", host_sid, "--fork-session", "--resume",
                                   "/home/myuser/.claude/projects/p/%s.jsonl" % OLD]),
              {}, 40, UID, (1001,)),
        140: (130, [VEXE, "--session-id", NEW, "--fork-session", "--resume",
                    "/home/myuser/.claude/projects/p/%s.jsonl" % OLD], AENV, 50, UID),
        # a pre-started spare of the pool (no --session-id) never counts as a session
        135: (120, host_argv(DDIR + "/spare/s1.pty.sock",
                             ["--bg-spare", DDIR + "/spare/s1.claim.sock"]), {}, 45, UID),
    }
    procs.update(extra or {})
    fake_tree(name, procs)
    # host <-> daemon over the pty socket, client <-> daemon over control.sock
    TABLE = dict(table) if table is not None else {
        1001: (PTY, 1002), 1002: ("", 1001), 2001: (CTRL, 2002), 2002: ("", 2001)}
    PANES.clear()
    PANES["%7"] = 100


def cargs():
    return argparse.Namespace(delay=0, timeout=5, nudge_wait=5, max_nudges=1,
                              done_timeout=5, handoff=None, max_breadcrumb_age=10 ** 9)


def compact_gather(target, sid):
    os.environ["CREDO_SELF_COMPACT_TARGET_PID"] = str(target)
    os.environ["CREDO_SELF_COMPACT_SESSION_ID"] = sid
    return compact.gather(cargs())


# --- plain tmux session: unchanged ------------------------------------------------
fake_tree("plain", {200: (1, ["bash"], {}, 10, UID),
                    300: (200, ["claude"], dict(TENV, TMUX_PANE="%5"), 20, UID)})
PANES.clear()
PANES["%5"] = 200
t("plain: no daemon", restart.daemon_link(300) == {"daemon": False})
plan, errs = compact_gather(300, PLAIN)
t("plain compact: no errors (%s)" % errs, errs == [])
t("plain compact: own pane", plan.get("pane") == "%5" and plan.get("target_pid") == 300)
t("plain compact: only own state id", plan.get("state_sids") == [PLAIN])
t("plain compact: no daemon note", not plan.get("daemon"))
PANES["%5"] = 999  # pane of another process
plan, errs = compact_gather(300, PLAIN)
t("plain compact: foreign pane rejected", any("refusing" in e for e in errs))

# --- daemon chain: client TUI is the daemon's parent -------------------------------
daemon_tree("daemon")
link = restart.daemon_link(140)
t("daemon: detected, client is the TUI", link.get("daemon") and link.get("client") == 110
  and link.get("error") is None and link.get("daemon_pid") == 120)
t("daemon: fork source", link.get("fork") == (OLD, NEW))
t("daemon: state ids map the pre-fork id", restart.state_sids(NEW, link) == [NEW, OLD])
plan, errs = compact_gather(140, NEW)
t("daemon compact: no errors (%s)" % errs, errs == [])
t("daemon compact: client pane", plan.get("pane") == "%7")
t("daemon compact: ownership via the client", plan.get("target_pid") == 110
  and plan.get("agent_pid") == 140 and plan.get("socket") == "/tmp/fake-sock")
t("daemon compact: mode carried over", plan.get("credo_mode") == "autonomous")
t("daemon compact: breadcrumb carried over", plan.get("handoff")
  == ".credo/process/handoffs/HANDOFF.md")
t("daemon compact: markers keyed by the own id", plan["marker"].endswith(
    "self-compact-%s.json" % NEW))
t("daemon compact: plan names the daemon", "client TUI pid 110" in plan.get("daemon", ""))
PANES["%7"] = 999
plan, errs = compact_gather(140, NEW)
t("daemon compact: pane not in the client ancestry rejected",
  any("not this Claude process" in e for e in errs))

os.environ["CREDO_SELF_RELOAD_TARGET_PID"] = "140"
os.environ["CREDO_SELF_RELOAD_SESSION_ID"] = NEW
PANES["%7"] = 100
plan, errs = reload_.gather(argparse.Namespace(delay=0, timeout=5, update=False,
                                               nudge_wait=5, max_nudges=1))
t("daemon reload: no errors (%s)" % errs, errs == [])
t("daemon reload: client pane + mode", plan.get("pane") == "%7"
  and plan.get("target_pid") == 110 and plan.get("credo_mode") == "autonomous")

os.environ["CREDO_SELF_RESTART_TARGET_PID"] = "140"
os.environ["CREDO_SELF_RESTART_SESSION_ID"] = NEW
plan, errs = restart.gather(argparse.Namespace(reason="x", update=False, delay=0,
                                               method=None))
t("daemon restart: refused clearly (%s)" % errs,
  any("cannot stop and resume a daemon-hosted session" in e for e in errs))

# --- reparented daemon: --spawned-by is the only link ------------------------------
daemon_tree("reparented", daemon_ppid=1)
link = restart.daemon_link(140)
t("reparented: valid --spawned-by followed", link.get("client") == 110
  and link.get("error") is None)
plan, errs = compact_gather(140, NEW)
t("reparented compact: client pane (%s)" % errs, errs == [] and plan.get("pane") == "%7")

# --- spoofed --spawned-by -----------------------------------------------------------
SPOOFS = {
    "non-claude pid": ('{"pid": 500}', {500: (1, ["bash"], TENV, 5, UID)},
                       "not a Claude Code client"),
    "foreign uid": ('{"pid": 500}', {500: (1, ["claude"], TENV, 5, UID + 1)},
                    "another user"),
    "started after daemon": ('{"pid": 500}', {500: (1, ["claude"], TENV, 99, UID)},
                             "started after the daemon"),
    "daemon pid": ('{"pid": 500}', {500: (1, ["claude", "daemon", "run"], TENV, 5, UID)},
                   "not a Claude Code client"),
    "dead pid": ('{"pid": 501}', {}, "not running"),
    "malformed json": ("{pid: 110}", {}, "no usable --spawned-by"),
    "string pid": ('{"pid": "110"}', {}, "no usable --spawned-by"),
    "bool pid": ('{"pid": true}', {}, "no usable --spawned-by"),
    "not an object": ("[110]", {}, "no usable --spawned-by"),
}
for i, (label, (spawned, extra, want)) in enumerate(sorted(SPOOFS.items())):
    daemon_tree("spoof%d" % i, daemon_ppid=1, spawned=spawned, extra=extra)
    PANES["%8"] = 1
    link = restart.daemon_link(140)
    t("spoof %s: rejected (%s)" % (label, link.get("error")),
      link.get("client") is None and want in (link.get("error") or ""))
    plan, errs = compact_gather(140, NEW)
    t("spoof %s: compact refuses, no pane" % label, errs and not plan.get("pane"))
    t("spoof %s: no state mapping" % label, restart.state_sids(NEW, link) == [NEW])

daemon_tree("mismatch", spawned='{"pid": 500}',
            extra={500: (1, ["claude"], TENV, 5, UID)})
link = restart.daemon_link(140)
t("spoof: --spawned-by other than the daemon's parent rejected",
  link.get("client") is None and "--spawned-by names pid 500" in (link.get("error") or ""))

# --- one daemon, several clients or sessions: fail closed -------------------------
# a second TUI (own pane %9) attached to the same daemon's control socket: which pane
# shows this session cannot be proven -> refuse, nothing is typed into either pane
two = {1001: (PTY, 1002), 1002: ("", 1001), 2001: (CTRL, 2002), 2002: ("", 2001),
       2003: (CTRL, 2004), 2004: ("", 2003)}
daemon_tree("twoclients", table=two, daemon_fds=(1002, 2001, 2003),
            extra={600: (1, ["claude", "--resume", "other-session"],
                         dict(TENV, TMUX_PANE="%9"), 25, UID, (2004,))})
PANES["%9"] = 600
link = restart.daemon_link(140)
t("two clients one daemon: refused (%s)" % link.get("error"), link.get("client") is None
  and "2 clients are attached" in (link.get("error") or ""))
plan, errs = compact_gather(140, NEW)
t("two clients one daemon: compact refuses, no pane", errs and not plan.get("pane"))
t("two clients one daemon: no state mapping", restart.state_sids(NEW, link) == [NEW])
os.environ["CREDO_SELF_RELOAD_TARGET_PID"] = "140"
plan, errs = reload_.gather(argparse.Namespace(delay=0, timeout=5, update=False,
                                               nudge_wait=5, max_nudges=1))
t("two clients one daemon: reload refuses, no pane", errs and not plan.get("pane"))

# the second client is the one attached, the spawning TUI is not
daemon_tree("otherclient", table={1001: (PTY, 1002), 1002: ("", 1001),
                                  2003: (CTRL, 2004), 2004: ("", 2003)},
            daemon_fds=(1002, 2003), client_fds=(),
            extra={600: (1, ["claude"], dict(TENV, TMUX_PANE="%9"), 25, UID, (2004,))})
link = restart.daemon_link(140)
t("client not attached: refused (%s)" % link.get("error"), link.get("client") is None
  and "is not attached to the daemon's control socket" in (link.get("error") or ""))

# a second session (bg-pty-host with --session-id) in the same daemon
daemon_tree("twosessions", extra={136: (120, host_argv(DDIR + "/pty/x2.sock",
                                                       ["--session-id", "third-sid-5555"]),
                                        {}, 46, UID)})
link = restart.daemon_link(140)
t("two sessions one daemon: refused (%s)" % link.get("error"), link.get("client") is None
  and "hosts 2 sessions" in (link.get("error") or ""))

daemon_tree("ptynotdaemon", daemon_fds=(2001,))
link = restart.daemon_link(140)
t("pty socket not connected to the daemon: refused", link.get("client") is None
  and "not connected to this session's pty socket" in (link.get("error") or ""))

daemon_tree("notable")
TABLE = None
link = restart.daemon_link(140)
t("socket table unreadable: refused", link.get("client") is None
  and "not readable" in (link.get("error") or ""))

# --bg-pty-host counts only at the subcommand position of a bg-pty-host process
fake_tree("flagelsewhere", {200: (1, ["bash"], {}, 10, UID),
                            300: (200, ["claude", "--append-system-prompt", "--bg-pty-host"],
                                  dict(TENV, TMUX_PANE="%5"), 20, UID)})
t("--bg-pty-host elsewhere in argv: plain session", restart.daemon_link(300)
  == {"daemon": False})
t("retitled argv[0] parsed", restart.daemon_role(
    host_argv(PTY, []), 0) == "pty-host" and restart.pty_socket(host_argv(PTY, []), 0) == PTY)

# --- worker re-check before every keystroke ---------------------------------------
daemon_tree("recheck")
plan, errs = compact_gather(140, NEW)
chk = restart.session_owner_check(plan)
t("recheck: linked agent passes", chk("%7", None, 110, plan["target_start"]) is None)
with open(os.path.join(restart.PROC_ROOT, "140", "stat")) as fh:
    stat = fh.read()
with open(os.path.join(restart.PROC_ROOT, "140", "stat"), "w") as fh:
    fh.write(stat.replace(") S ", ") Z ", 1))
t("recheck: agent gone -> refused", "is gone" in (chk("%7", None, 110,
                                                    plan["target_start"]) or ""))
with open(os.path.join(restart.PROC_ROOT, "140", "stat"), "w") as fh:
    fh.write(stat)
TABLE[2003], TABLE[2004] = (CTRL, 2004), ("", 2003)
os.makedirs(os.path.join(restart.PROC_ROOT, "600", "fd"))
os.symlink("socket:[2004]", os.path.join(restart.PROC_ROOT, "600", "fd", "3"))
os.symlink("socket:[2003]", os.path.join(restart.PROC_ROOT, "120", "fd", "99"))
t("recheck: a second client appears -> refused", "clients are attached" in (
    chk("%7", None, 110, plan["target_start"]) or ""))

# --- no tmux anywhere -------------------------------------------------------------
fake_tree("notmux", {200: (1, ["bash"], {}, 10, UID), 300: (200, ["claude"], AENV, 20, UID)})
plan, errs = compact_gather(300, PLAIN)
t("no tmux plain: clear error", any(e.startswith("not running inside tmux (the Claude process")
                                    for e in errs))
daemon_tree("notmux-daemon", tui_env=AENV)
plan, errs = compact_gather(140, NEW)
t("no tmux daemon: clear error", any("client TUI of this daemon-hosted session" in e
                                     for e in errs))
t("no tmux daemon: agent TMUX never used", not plan.get("pane"))

# --- no state mapping for hand-made forks or a session id mismatch ----------------
fake_tree("userfork", {200: (1, ["bash"], {}, 10, UID),
                       300: (200, ["claude", "--fork-session", "--resume", OLD],
                             dict(TENV, TMUX_PANE="%5"), 20, UID)})
link = restart.daemon_link(300)
t("user fork: no daemon, no mapping", restart.state_sids(NEW, link) == [NEW])
daemon_tree("sidmismatch", host_sid="other-sid-4444")
t("session id mismatch: no mapping",
  restart.state_sids(NEW, restart.daemon_link(140)) == [NEW])

# --- bg-pty-host without a daemon in the chain ------------------------------------
fake_tree("hostonly", {130: (1, ["claude", "bg-pty-host", "--bg-pty-host", "/tmp/s"], {}, 40, UID),
                       140: (130, ["claude"], AENV, 50, UID)})
link = restart.daemon_link(140)
t("host without daemon: refused", link.get("daemon") and link.get("client") is None
  and "no `claude daemon run`" in (link.get("error") or ""))

for r in res:
    print(r)
PYEOF

out="$("$PY" "$TMP/unit.py" "$SCRIPT_DIR" "$TMP" 2>&1)"
rc=$?
fails="$(printf '%s\n' "$out" | grep -c '^FAIL' || true)"
passes="$(printf '%s\n' "$out" | grep -vc '^FAIL' || true)"
if [ "$rc" -ne 0 ] || [ "$fails" -ne 0 ]; then
    printf '%s\n' "$out" | grep -v '^[a-z]' | head -50
    printf '%s\n' "$out" | grep '^FAIL'
    echo "FAILED: $fails failure(s), rc $rc"
    exit 1
fi
echo "OK: $passes checks passed"

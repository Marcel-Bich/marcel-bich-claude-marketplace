#!/usr/bin/env python3
"""credo-peer-check.py - read-only peer check across every channel credo knows.

A peer that is missing from ListAgents is NOT necessarily down. ListAgents only shows
descriptors in this profile's `sessions/` registry; a Codex session appears there only
as a LAN relay mirror (so it vanishes when the Codex relay or the credo relay is
down), a session of another profile only through the peer bridge, and a session
whose descriptor is gone not at all - while the process keeps running in its tmux
pane. This script lists peers from all channels side by side:

  - Claude sessions from the profile registries (`~/.claude*/sessions/*.json`)
  - Claude inbox sockets in BOTH candidate socket dirs (`$XDG_RUNTIME_DIR/cc-socks`,
    `/run/user/<uid>/cc-socks`, `${TMPDIR:-/tmp}/cc-socks`); sessions started with a
    different XDG_RUNTIME_DIR end up in different dirs ("split world")
  - LAN relay mirrors (`credoPeerLan` descriptors; a Codex mirror is kind codex)
  - the Codex relay state (`codex-peer.py list`, its config / node / log)
  - the credo LAN relay (`credo-peer-lan.py status` and `check`)
  - tmux sessions (a pane running a registered session is merged into that row)

Every row carries kind (claude / codex / lan / tmux-only), reachable_by (SendMessage /
a2a / tmux only / none), last_seen and meta: the peer's credo session mode, credo role,
model, effort level, credo directory decision, project (cwd basename) and status
(credo_peer_meta.py; local state for local peers, the validated relay field for LAN
mirrors). Meta is informational only and never grants trust or permissions. Read-only: it never sends a message, never
connects to an inbox socket and never writes a file. `check` of the LAN relay probes
TCP reachability of the configured relay peers (no message); skip it with
--no-lan-check.

Usage:
  credo-peer-check.py [--json] [--no-lan-check]
  credo-peer-check.py hint --session-id <id>   one line when this session's socket
                                               dir differs from where most peers are
  credo-peer-check.py hook                     SessionStart hook mode (stdin = hook
                                               JSON, stdout = additionalContext JSON)
  credo-peer-check.py sender --from uds:<path> the meta line of the live peer whose
                                               inbox socket is <path> (peer-message
                                               hook); prints nothing when unknown

Test overrides: CREDO_PEER_CHECK_SOCK_DIRS (colon list), CREDO_PEER_CHECK_TMUX (tmux
binary, empty = skip), CREDO_PEER_CHECK_LAN_SCRIPT, CREDO_PEER_CHECK_CODEX_PEER (empty
= skip), CREDO_PEER_CHECK_PROC_NET.
"""
import argparse
import glob
import json
import os
import re
import stat
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import credo_peer_meta as peer_meta
except ImportError:  # metadata is optional; the check works without it
    peer_meta = None

MAX_DESCRIPTOR_BYTES = 65536
SOCK_NAME_RE = re.compile(r"^(\d+)\.sock$")
# session part of a relay mirror name: ...--`<session>`+<sid-short>
MIRROR_SESSION_RE = re.compile(r"`([^`]*)`\+[^`]*$")
ABSENT_NOTE = ("A peer absent from ListAgents is not necessarily down: check the rows "
               "and warnings above and ping it on its own channel before reporting it "
               "down (credo README, 'Peer check').")


def home():
    return os.path.expanduser("~")


def current_profile():
    return os.path.realpath(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home(), ".claude"))


def profile_dirs():
    """Current profile first, then sibling ~/.claude* profiles that own sessions/;
    deduplicated by real path (a symlinked profile counts once)."""
    out, seen = [], set()
    for p in [current_profile()] + sorted(glob.glob(os.path.join(home(), ".claude*"))):
        rp = os.path.realpath(p)
        sd = os.path.realpath(os.path.join(rp, "sessions"))
        if rp in seen or sd in {os.path.realpath(os.path.join(x, "sessions")) for x in out}:
            continue
        if os.path.isdir(os.path.join(rp, "sessions")):
            seen.add(rp)
            out.append(rp)
    return out


def sock_dirs():
    raw = os.environ.get("CREDO_PEER_CHECK_SOCK_DIRS")
    if raw is not None:
        cands = [d for d in raw.split(":") if d]
    else:
        cands = []
        xdg = os.environ.get("XDG_RUNTIME_DIR")
        if xdg:
            cands.append(os.path.join(xdg, "cc-socks"))
        cands.append("/run/user/%d/cc-socks" % os.getuid())
        tmp = os.environ.get("TMPDIR")
        if tmp:
            cands.append(os.path.join(tmp, "cc-socks"))
        cands.append("/tmp/cc-socks")
    out = []
    for d in cands:
        d = os.path.normpath(d)
        if d not in out:
            out.append(d)
    return out


def proc_start(pid):
    try:
        with open("/proc/%d/stat" % pid) as fh:
            data = fh.read()
        return data[data.rindex(")") + 2:].split()[19]
    except (OSError, ValueError, IndexError):
        return None


def pid_alive(pid, pstart=None):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    cur = proc_start(pid)
    if cur is None:
        return False
    return not pstart or str(pstart) == cur


def fmt_ts(sec):
    if not sec:
        return "-"
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(float(sec)))
    except (TypeError, ValueError, OverflowError):
        return "-"


def read_json(path, limit=MAX_DESCRIPTOR_BYTES):
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            return None
        with open(path) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def load_descriptors():
    """Alive descriptors per profile: list of (profile, descriptor)."""
    out = []
    for prof in profile_dirs():
        for path in sorted(glob.glob(os.path.join(prof, "sessions", "*.json"))):
            d = read_json(path)
            if not d:
                continue
            pid = d.get("pid")
            if pid_alive(pid, d.get("procStart")):
                out.append((prof, d))
    return out


def bound_unix_paths():
    """Paths of bound unix sockets from /proc/net/unix, or None when unreadable. A
    socket file left behind by a dead session is not listed there."""
    base = os.environ.get("CREDO_PEER_CHECK_PROC_NET") or "/proc/net"
    try:
        with open(os.path.join(base, "unix")) as fh:
            next(fh, None)
            return {f[7].rstrip("\n") for f in (ln.split(None, 7) for ln in fh)
                    if len(f) == 8 and f[7].startswith("/")}
    except OSError:
        return None


def proc_started_at(pid):
    """Epoch seconds the process started (boot time + starttime ticks), or None."""
    try:
        ticks = int(proc_start(pid))
        with open("/proc/stat") as fh:
            btime = next(int(ln.split()[1]) for ln in fh if ln.startswith("btime "))
        return btime + ticks / float(os.sysconf("SC_CLK_TCK"))
    except (TypeError, ValueError, OSError, StopIteration):
        return None


def socket_live(pid, path, mtime, bound):
    """A <pid>.sock counts only while it is really bound: listed in /proc/net/unix.
    Without /proc/net/unix: the pid is alive and did not start after the socket was
    created (a stale socket whose pid was reused by a newer process does not count)."""
    if bound is not None:
        return path in bound and pid_alive(pid)
    started = proc_started_at(pid)
    return started is not None and started <= mtime + 1


def live_sockets():
    """{dir: [(pid, path, mtime)]} for <pid>.sock sockets that are really bound."""
    res = {}
    bound = bound_unix_paths()
    for d in sock_dirs():
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            m = SOCK_NAME_RE.match(n)
            if not m:
                continue
            p = os.path.join(d, n)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if stat.S_ISSOCK(st.st_mode) and socket_live(int(m.group(1)), p, st.st_mtime, bound):
                res.setdefault(d, []).append((int(m.group(1)), p, st.st_mtime))
    return res


# --------------------------------------------------------------------------- procs

def proc_children():
    kids = {}
    for e in os.listdir("/proc"):
        if not e.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % e) as fh:
                data = fh.read()
            ppid = int(data[data.rindex(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            continue
        kids.setdefault(ppid, []).append(int(e))
    return kids


def descendants(pid, kids):
    out, stack = [], [pid]
    while stack and len(out) < 2000:
        p = stack.pop()
        out.append(p)
        stack.extend(kids.get(p, []))
    return out


def is_codex_proc(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            argv = [a.decode("utf-8", "replace") for a in fh.read().split(b"\0") if a]
    except OSError:
        return False
    if not argv or any("app-server" in a for a in argv):
        return False
    names = [os.path.basename(a) for a in argv[:2]]
    return "codex" in names


# --------------------------------------------------------------------------- tmux

def tmux_info():
    """[(session, [pane_pids], activity)] or [] when tmux is absent/not running."""
    binary = os.environ.get("CREDO_PEER_CHECK_TMUX")
    if binary is None:
        binary = "tmux"
    if not binary:
        return []

    def run(args):
        try:
            r = subprocess.run([binary] + args, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout if r.returncode == 0 else ""

    panes = {}
    for line in run(["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}"]).splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].isdigit():
            panes.setdefault(parts[0], []).append(int(parts[1]))
    out = []
    for line in run(["list-sessions", "-F", "#{session_name}\t#{session_activity}"]).splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            out.append((parts[0], panes.get(parts[0], []), parts[1]))
    return out


# --------------------------------------------------------------------------- tcp

def tcp_listening(port, host="127.0.0.1"):
    """True when something LISTENs on host:port (or on any address), from
    /proc/net/tcp{,6}. Read-only, no connection is made."""
    base = os.environ.get("CREDO_PEER_CHECK_PROC_NET") or "/proc/net"
    want = {"0100007F", "00000000"} if host in ("127.0.0.1", "localhost") else {"00000000"}
    want6 = {"00000000000000000000000000000000", "00000000000000000000000001000000"}
    for name, addrs in (("tcp", want), ("tcp6", want6)):
        try:
            with open(os.path.join(base, name)) as fh:
                next(fh, None)
                for line in fh:
                    f = line.split()
                    if len(f) < 4 or f[3] != "0A":
                        continue
                    ip, _, hport = f[1].partition(":")
                    if int(hport, 16) == port and ip in addrs:
                        return True
        except (OSError, ValueError):
            continue
    return False


def parse_peer(entry, default_port):
    if isinstance(entry, dict):
        host, port = entry.get("host"), entry.get("port") or default_port
    elif isinstance(entry, str):
        host, _, p = entry.rpartition(":") if entry.count(":") == 1 else (entry, "", "")
        port = int(p) if p.isdigit() else default_port
    else:
        return None, None
    return host, port


# --------------------------------------------------------------------------- codex

def codex_state_dir():
    return os.path.join(os.environ.get("CODEX_HOME") or os.path.join(home(), ".codex"),
                        "credo", "peer-lan")


def _version_key(path):
    v = path.split(os.sep)[-3]
    return [int(x) if x.isdigit() else x for x in re.split(r"[.+]", v)]


def codex_peer_script():
    s = os.environ.get("CREDO_PEER_CHECK_CODEX_PEER")
    if s is not None:
        return s or None
    root = os.environ.get("CODEX_HOME") or os.path.join(home(), ".codex")
    found = glob.glob(os.path.join(root, "plugins", "cache", "*", "credo", "*", "scripts", "codex-peer.py"))
    try:
        return sorted(found, key=_version_key)[-1] if found else None
    except TypeError:
        return sorted(found)[-1]


def codex_status():
    """Codex relay facts or None when no Codex relay state exists."""
    sd = codex_state_dir()
    if not os.path.isdir(sd):
        return None
    cfg = read_json(os.path.join(sd, "config.json")) or {}
    node = read_json(os.path.join(sd, "node.json")) or {}
    port = cfg.get("listen_port")
    st = {
        "state_dir": sd,
        "listen": "%s:%s" % (cfg.get("listen_host", "127.0.0.1"), port),
        "node_pid": node.get("pid"),
        "node_alive": pid_alive(node.get("pid")),
        "listening": isinstance(port, int) and tcp_listening(port, cfg.get("listen_host", "127.0.0.1")),
        "sessions": [],
        "source": "files",
        "log_tail": [],
    }
    script = codex_peer_script()
    if script and os.path.isfile(script):
        try:
            r = subprocess.run([sys.executable, script, "list"], capture_output=True,
                               text=True, timeout=15)
            data = json.loads(r.stdout) if r.returncode == 0 else None
            if isinstance(data, dict) and isinstance(data.get("localSessions"), list):
                st["sessions"] = [s for s in data["localSessions"] if isinstance(s, dict)]
                st["source"] = "codex-peer.py list"
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    if st["source"] == "files":
        for path in sorted(glob.glob(os.path.join(sd, "sessions", "*.json"))):
            d = read_json(path)
            if d and d.get("sessionId"):
                st["sessions"].append(d)
    try:
        with open(os.path.join(sd, "peer-lan.log"), "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 4096))
            lines = fh.read().decode("utf-8", "replace").splitlines()
        st["log_tail"] = [ln for ln in lines if ln.strip()][-3:]
    except OSError:
        pass
    return st


# --------------------------------------------------------------------------- lan

def lan_status(run_check):
    script = os.environ.get("CREDO_PEER_CHECK_LAN_SCRIPT") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "credo-peer-lan.py")
    cfg_path = os.environ.get("CREDO_PEER_LAN_CONFIG") or os.path.join(current_profile(), "credo", "peer-lan.json")
    cfg = read_json(cfg_path, 1 << 20)
    st = {"configured": cfg is not None, "running": None, "status": "", "check": [],
          "disabled": [], "loopback_down": []}
    if cfg is None:
        return st
    default_port = cfg.get("listen_port") or 0
    for entry in cfg.get("peers") or []:
        host, port = parse_peer(entry, default_port)
        if host in ("127.0.0.1", "localhost") and isinstance(port, int) and not tcp_listening(port):
            st["loopback_down"].append("%s:%d" % (host, port))

    def run(arg, timeout):
        try:
            r = subprocess.run([sys.executable, script, arg], capture_output=True,
                               text=True, timeout=timeout)
            return r.returncode, (r.stdout or "").strip()
        except (OSError, subprocess.SubprocessError) as exc:
            return None, "%s failed: %s" % (arg, exc)

    if os.path.isfile(script):
        rc, out = run("status", 10)
        st["running"] = rc == 0
        st["status"] = out.splitlines()[0] if out else ""
        if run_check:
            _, out = run("check", 60)
            st["check"] = out.splitlines()
            st["disabled"] = [ln.strip() for ln in st["check"] if "DISABLED" in ln]
    return st


# --------------------------------------------------------------------------- rows

def meta_for(d, prof):
    """Validated metadata of a descriptor: a LAN mirror carries the sender's relay
    field (credoPeerMeta, re-validated here), a local session is looked up in the
    credo state of its own profile first, then of the other profiles (a profile
    bridge mirror keeps the session id of its source)."""
    if peer_meta is None or not isinstance(d, dict):
        return {}
    if d.get("credoPeerLan") or d.get("credoPeerLanFrom"):
        meta = peer_meta.clean(d.get("credoPeerMeta"), ("mode", "role", "model", "effort",
                                                        "credo", "project"))
    else:
        profs = [prof] + [p for p in profile_dirs() if p != prof]
        meta = peer_meta.local_meta(d.get("sessionId"), profs, d.get("cwd"))
    if peer_meta.valid("status", d.get("status")):
        meta["status"] = d["status"]
    return meta


def meta_text(meta):
    return peer_meta.fmt(meta) if peer_meta is not None else "-"


def is_codex_mirror(d):
    return str(d.get("name") or "").startswith("`Codex`")


def collect(run_lan_check=True):
    cur = current_profile()
    descs = load_descriptors()
    socks = live_sockets()
    kids = proc_children()
    tmux = tmux_info()
    pane_tree = {}
    codex_tmux = set()
    for sess, panes, _act in tmux:
        for pp in panes:
            for p in descendants(pp, kids):
                pane_tree.setdefault(p, sess)
                if is_codex_proc(p):
                    codex_tmux.add(sess)
    rows, warnings = [], []
    seen_pids, seen_sids, matched_tmux = set(), set(), set()

    def add(**kw):
        kw.setdefault("tmux", None)
        kw.setdefault("meta", {})
        rows.append(kw)
        if kw.get("tmux"):
            matched_tmux.add(kw["tmux"])

    for prof, d in descs:
        pid, sid = d["pid"], d.get("sessionId")
        if pid in seen_pids or (sid and sid in seen_sids and prof != cur):
            continue
        last = max([v for v in (d.get("updatedAt"), d.get("statusUpdatedAt"))
                    if isinstance(v, (int, float)) and not isinstance(v, bool)] or [0]) / 1000.0
        if d.get("credoPeerLan") or d.get("credoPeerLanFrom"):
            codex = is_codex_mirror(d)
            # a local Codex mirror whose session part names a tmux session running Codex
            # is that tmux session (merged instead of listed twice)
            seg = MIRROR_SESSION_RE.search(str(d.get("name") or ""))
            tm = seg.group(1) if codex and seg and seg.group(1) in codex_tmux else None
            add(name=d.get("name") or sid, kind="codex" if codex else "lan",
                reachable_by="SendMessage", last_seen=fmt_ts(last), session_id=sid, pid=pid,
                tmux=tm, detail="LAN relay mirror from %s" % (d.get("credoPeerLanFrom") or "?"),
                meta=meta_for(d, prof))
        else:
            in_cur = prof == cur
            tm = pane_tree.get(pid)
            via = "SendMessage" if in_cur else ("tmux only" if tm else "none")
            detail = "socket %s" % os.path.dirname(d.get("messagingSocketPath") or "?")
            if d.get("credoPeerBridge"):
                detail += ", profile bridge mirror"
            if not in_cur:
                detail += ", other profile %s (not in this session's ListAgents)" % os.path.basename(prof)
            add(name=d.get("name") or "(unnamed)", kind="claude", reachable_by=via,
                last_seen=fmt_ts(last), session_id=sid, pid=pid, tmux=tm, detail=detail,
                status=d.get("status"), meta=meta_for(d, prof))
        seen_pids.add(pid)
        if sid:
            seen_sids.add(sid)

    for d, items in socks.items():
        for pid, path, mtime in items:
            if pid in seen_pids:
                continue
            tm = pane_tree.get(pid)
            add(name=tm or "pid %d" % pid, kind="claude",
                reachable_by="tmux only" if tm else "none", last_seen=fmt_ts(mtime),
                session_id=None, pid=pid, tmux=tm,
                detail="live socket %s without a registry descriptor (not in ListAgents)" % path)
            seen_pids.add(pid)

    cx = codex_status()
    if cx:
        for s in cx["sessions"]:
            sid = s.get("sessionId")
            if sid in seen_sids:
                continue
            if cx["node_alive"]:
                via = "a2a"
            else:
                via = "tmux only" if codex_tmux else "none"
            add(name=s.get("name") or sid, kind="codex", reachable_by=via,
                last_seen=fmt_ts(s.get("lastSeen")), session_id=sid, pid=None,
                detail="Codex relay session (%s, active=%s)" % (cx["source"], s.get("active")))
            seen_sids.add(sid)
        if not cx["node_alive"] or not cx["listening"]:
            why = []
            if not cx["node_alive"]:
                why.append("node pid %s not alive" % cx["node_pid"])
            if not cx["listening"]:
                why.append("%s not listening" % cx["listen"])
            msg = ("Codex relay not running (%s): Codex sessions are absent from ListAgents "
                   "but may still run - see the tmux rows." % ", ".join(why))
            if cx["log_tail"]:
                msg += " Last Codex relay log line: %s" % cx["log_tail"][-1]
            warnings.append(msg)

    for sess, _panes, act in tmux:
        if sess in matched_tmux:
            continue
        kind = "codex" if sess in codex_tmux else "tmux-only"
        add(name=sess, kind=kind, reachable_by="tmux only", last_seen=fmt_ts(act),
            session_id=None, pid=None, tmux=sess,
            detail="tmux session%s" % (" running Codex" if kind == "codex" else
                                       " without a known peer session"))

    live_dirs = {d: len(v) for d, v in socks.items() if v}
    split = len(live_dirs) >= 2
    if split:
        warnings.insert(0, (
            "split world detected. Live Claude peer sockets in %s. Sessions started with a "
            "different XDG_RUNTIME_DIR (e.g. set in one shell, unset in another after a "
            "WSL restart) land in different socket dirs. The fix is to start all sessions "
            "with the same XDG_RUNTIME_DIR (all set to the same dir, or all unset), then "
            "restart the odd ones." % ", ".join("%s (%d)" % kv for kv in sorted(live_dirs.items()))))

    lan = lan_status(run_lan_check)
    for line in lan["disabled"]:
        warnings.insert(0, "relay LAN disabled: %s - cross-machine peers are cut off." % line)
    for addr in lan["loopback_down"]:
        warnings.append("LAN relay peer %s is not listening (a local relay on this machine, "
                        "such as the Codex relay, is down)." % addr)
    if lan["configured"] and lan["running"] is False:
        warnings.append("credo LAN relay daemon is not running: %s" % lan["status"])
    return {"peers": rows, "warnings": warnings, "split_world": split,
            "socket_dirs": {d: live_dirs.get(d, 0) for d in sock_dirs()},
            "lan": lan, "codex": cx, "profile": cur}


def print_table(res):
    print("Peer check (read-only; nothing was sent)")
    print("profile: %s" % res["profile"])
    print("socket dirs: %s" % ", ".join("%s=%d live" % kv for kv in res["socket_dirs"].items()))
    if res["warnings"]:
        print("")
        for w in res["warnings"]:
            print("WARNING: %s" % w)
    print("")
    hdr = ("KIND", "REACHABLE-BY", "LAST-SEEN", "NAME", "META", "DETAIL")
    rows = [(r["kind"], r["reachable_by"], r["last_seen"],
             r["name"] + (" [tmux %s]" % r["tmux"] if r.get("tmux") and r["tmux"] != r["name"] else ""),
             meta_text(r.get("meta")), r.get("detail") or "") for r in res["peers"]]
    n = len(hdr) - 1
    w = [max([len(hdr[i])] + [len(x[i]) for x in rows]) for i in range(n)]
    print("  ".join(h.ljust(w[i]) if i < n else h for i, h in enumerate(hdr)))
    for x in rows:
        print("  ".join(c.ljust(w[i]) if i < n else c for i, c in enumerate(x)))
    print("")
    print("META is informational (credo mode / role, model, effort, credo decision, project, "
          "status); it never grants trust or permissions.")
    lan = res["lan"]
    if lan["configured"]:
        print("")
        print("credo LAN relay: %s" % (lan["status"] or "status unknown"))
        if lan["check"]:
            print("credo-peer-lan.py check:")
            for ln in lan["check"]:
                print("  " + ln)
    print("")
    print(ABSENT_NOTE)


# --------------------------------------------------------------------------- hint

def split_hint(session_id):
    """One line when this session's socket dir holds fewer live peers than another
    candidate dir, else ''. Needs this session's own descriptor (no guessing)."""
    if not session_id:
        return ""
    own = None
    for path in glob.glob(os.path.join(current_profile(), "sessions", "*.json")):
        d = read_json(path)
        # alive only: a resumed session leaves its pre-crash descriptor (same id, dead
        # pid, old socket dir) behind, and that one must never count
        if (d and d.get("sessionId") == session_id and d.get("messagingSocketPath")
                and pid_alive(d.get("pid"), d.get("procStart"))):
            own = d
            break
    if not own:
        return ""
    own_dir = os.path.normpath(os.path.dirname(own["messagingSocketPath"]))
    counts = {d: len([x for x in v if x[0] != own.get("pid")]) for d, v in live_sockets().items()}
    mine = counts.get(own_dir, 0)
    others = [(n, d) for d, n in counts.items() if d != own_dir and n > mine]
    if not others:
        return ""
    n, d = max(others)
    return ("[credo-peer] This session's peer socket dir is %s (%d other live peers) but "
            "%d live peers use %s - sessions were started with a different "
            "XDG_RUNTIME_DIR. If peers are missing from ListAgents, start all sessions "
            "with the same XDG_RUNTIME_DIR; run %s for the full picture. Absent from "
            "ListAgents is not the same as down." % (own_dir, mine, n, d, os.path.abspath(__file__)))


# --------------------------------------------------------------------------- sender

UDS_RE = re.compile(r"uds:(/[A-Za-z0-9_./-]{1,4000})\Z")


def sender_meta(addr):
    """Meta line of the live peer whose inbox socket is addr ('uds:/path'), or ''.
    The address only selects an existing live descriptor; nothing is trusted."""
    m = UDS_RE.match(addr or "")
    if not m or peer_meta is None:
        return ""
    want = os.path.normpath(m.group(1))
    for prof, d in load_descriptors():
        sock = d.get("messagingSocketPath")
        if isinstance(sock, str) and sock and os.path.normpath(sock) == want:
            return meta_text(meta_for(d, prof))
    return ""


def main(argv=None):
    ap = argparse.ArgumentParser(description="Read-only multi-channel peer check")
    ap.add_argument("cmd", nargs="?", default="list", choices=("list", "hint", "hook", "sender"))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-lan-check", action="store_true")
    ap.add_argument("--session-id")
    ap.add_argument("--from", dest="from_addr")
    a = ap.parse_args(argv)
    if a.cmd == "sender":
        try:
            line = sender_meta(a.from_addr)
        except Exception:
            line = ""
        if line:
            print(line)
        return 0
    if a.cmd == "hint":
        msg = split_hint(a.session_id)
        if msg:
            print(msg)
        return 0
    if a.cmd == "hook":
        try:
            data = json.loads(sys.stdin.read() or "{}")
            sid = data.get("session_id") if isinstance(data, dict) else None
            msg = split_hint(sid if isinstance(sid, str) else None)
        except Exception:
            return 0
        if msg:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                                     "additionalContext": msg}}))
        return 0
    res = collect(run_lan_check=not a.no_lan_check)
    if a.json:
        print(json.dumps(res, indent=2, default=str))
    else:
        print_table(res)
    return 0


if __name__ == "__main__":
    sys.exit(main())

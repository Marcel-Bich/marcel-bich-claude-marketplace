#!/usr/bin/env python3
"""credo-win-bridge.py - peer messaging between native Windows Claude Code sessions and
the WSL sessions of the same machine, in both directions (credo item #183).

Claude Code keeps one session registry per profile: <config>/sessions/<pid>.json. Under
WSL that registry holds Linux sessions with unix-socket inboxes; on Windows
(%USERPROFILE%\\.claude\\sessions) it holds sessions whose inbox is a named pipe
(\\\\.\\pipe\\LOCAL\\cc-msg-<32 hex>). The two registries never see each other, so
ListAgents / SendMessage cannot cross between them. This daemon mirrors each side into
the other, the same way the LAN relay (credo-peer-lan.py) mirrors remote machines.

WSL side (this script)
----------------------
- Every Windows session gets one HOLDER subprocess (a real live WSL process) that listens
  on a unix socket in the bridge's sock dir. Its pid, its /proc procStart and a pidDomain
  copied from a live local session go into a mirror descriptor in every local profile's
  sessions/ dir, marked with "credoWinBridge" (never "credoPeerLan" or
  "credoPeerBridge", so neither of those touches it). A Linux sender checks that the
  connected endpoint pid equals the descriptor pid, which the holder satisfies.
- What a WSL session writes into a holder socket is handed to the PowerShell half
  (credo-win-bridge.ps1, one long-running powershell.exe started from here over WSL
  interop, stdio protocol below). It reads the target session's own key file LOCALLY on
  Windows, writes the auth line the Windows inbox requires, then the message bytes.
- The other direction: the PowerShell half offers one named pipe per live WSL session
  (and per LAN-relay mirror, so LAN peers reach Windows sessions too), with a mirror
  descriptor and its OWN key file (random token) in %USERPROFILE%\\.claude\\sessions.
  It verifies and strips the auth line of every connection, then sends the message line
  here; the holder that represents the Windows SENDER writes it into the WSL target
  socket, so the receiving session sees a writer pid that is registered with the reply
  socket (a verified local peer).
- Reply addresses: the "from" address in a message (the frame's "from" field and the
  envelope's from= attribute) names the sender's own inbox, which the other side cannot
  reach. It is swapped for the sender's mirror address on the receiving side (holder
  socket under WSL, mirror pipe on Windows). Every other byte is forwarded unchanged.

SAFETY
  - Tokens never leave Windows: the WSL side never reads a Windows key file; the
    PowerShell half reads it and writes it only into the target pipe, never into a log,
    the stdio channel or a file. A leading auth line arriving from WSL is dropped.
  - The bridge only removes descriptors that carry its own "credoWinBridge" marker,
    sockets in its own sock dir and (Windows side) its own mirror files and holders.
  - Off switch: credo config `peer.win_bridge.enabled: false` (builtin, global and
    profile layers only - a repository cannot switch it) or CREDO_WIN_BRIDGE=0.
  - Security note: the WSL user gains send rights to the Windows sessions of the same
    Windows user (and the reverse). That is the same trust as the Windows user running
    wsl.exe; switch it off where that is not wanted.

stdio protocol with the PowerShell half (one JSON object per line, UTF-8):
  to PS:   {"op":"list","id":N}
           {"op":"send","id":N,"pid":P,"pipe":"<messagingSocketPath>","data":"<b64>"}
           {"op":"publish","sessions":[{"key":sid,"sessionId","name","status",...}]}
           {"op":"quit"}
  from PS: {"op":"ready","pid":P,"host":H,"user":U,"pidDomain":D}
           {"op":"list","id":N,"sessions":[<Windows descriptor fields>]}
           {"op":"sent","id":N,"ok":true|false,"err":"..."}
           {"op":"published","mirrors":[{"key":sid,"pipe":"\\\\.\\pipe\\LOCAL\\cc-msg-..."}]}
           {"op":"msg","key":sid,"data":"<b64 of the bytes after the auth line>"}
           {"op":"log","text":"..."}

Usage: credo-win-bridge.py ensure | daemon | stop | status | enabled
Python 3 stdlib only.
"""

import base64
import getpass
import hashlib
import hmac
import importlib.util
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

try:
    import fcntl
except ImportError:  # not on POSIX: the bridge only runs under WSL anyway
    fcntl = None

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import credo_profiles as profiles  # noqa: E402
import credo_session_name as session_name  # noqa: E402

MARK = "credoWinBridge"
LAN_MARK = "credoPeerLan"
BRIDGE_MARK = "credoPeerBridge"
# descriptor fields the LAN relay reads to publish a mirrored Windows session under its
# own Windows name (see credo-peer-lan.py _roster_sessions)
NAME_KEY = "credoWinName"
PROFILE_KEY = "credoWinProfile"
OWNER_KEY = "credoWinBridgeOwner"
SOCK_PREFIX = "wb-"
DEFAULT_INTERVAL = 5.0
CONFIG_RECHECK = 60.0
CONN_TIMEOUT = 5.0
MAX_MSG = 4 * 1024 * 1024
MAX_WIN_SESSIONS = 64
LOG_MAX = 2 * 1024 * 1024
PS_RESTART_MAX = 60.0
PS_SCRIPT = "credo-win-bridge.ps1"

# messagingSocketPath of a Windows session (same rule as Claude Code's own parser:
# \\.\pipe\[LOCAL\]<name>, either slash, "." or "?" after the two leading slashes)
PIPE_PATH_RE = re.compile(r"^[\\/]{2}[.?][\\/]pipe[\\/](?:(LOCAL)[\\/])?([^\\/]+)$", re.I)
CC_PIPE_RE = re.compile(r"^LOCAL\\cc-msg-[0-9a-f]{32}$", re.I)
TOKEN_RE = re.compile(r"^[0-9a-f]{32}$")
SID_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


def _read_version():
    override = os.environ.get("CREDO_WIN_BRIDGE_VERSION")
    if override:
        return override
    try:
        with open(os.path.join(HERE, "..", ".claude-plugin", "plugin.json")) as fh:
            v = json.load(fh).get("version")
        return v if isinstance(v, str) and v else "unknown"
    except Exception:
        return "unknown"


VERSION = _read_version()
_LAN = {}


def lan():
    """credo-peer-lan.py as a module (shared helpers: proc_start, descriptor_live,
    mirror_name, win_tool), loaded once and lazily."""
    if "m" not in _LAN:
        spec = importlib.util.spec_from_file_location(
            "credo_peer_lan_for_bridge", os.path.join(HERE, "credo-peer-lan.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _LAN["m"] = mod
    return _LAN["m"]


# ---------------------------------------------------------------------------
# paths, logging, switch
# ---------------------------------------------------------------------------
def state_dir():
    p = os.environ.get("CREDO_WIN_BRIDGE_STATE")
    if p:
        return p
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "credo", "win-bridge")


def sock_dir():
    return os.path.join(state_dir(), "sock")


def log_path():
    return os.path.join(state_dir(), "bridge.log")


def pidfile_path():
    return os.path.join(state_dir(), "bridge.pid")


def status_path():
    return os.path.join(state_dir(), "status.json")


def ensure_dirs():
    for d in (state_dir(), sock_dir()):
        os.makedirs(d, mode=0o700, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass


_LOG_LOCK = threading.Lock()


def log(msg):
    """One timestamped line in bridge.log (never a token: callers only pass names,
    pids, paths and error texts). Rotates at LOG_MAX into bridge.log.1."""
    line = "%s [%d] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), os.getpid(), msg)
    with _LOG_LOCK:
        try:
            p = log_path()
            try:
                if os.path.getsize(p) > LOG_MAX:
                    os.replace(p, p + ".1")
            except OSError:
                pass
            with open(p, "a") as fh:
                fh.write(line)
        except OSError:
            pass


OFF_WORDS = ("0", "false", "no", "off")
ON_WORDS = ("1", "true", "yes", "on")


def switch_value(env_value, config_value):
    """The on/off decision: the environment wins, then the config value, default on."""
    for v in (env_value, config_value):
        if v is None:
            continue
        t = str(v).strip().strip('"').strip("'").lower()
        if t in OFF_WORDS:
            return False
        if t in ON_WORDS:
            return True
    return True


def config_value():
    """peer.win_bridge.enabled from the credo config (builtin, global and profile layers
    only: CREDO_PROJECT=/dev/null, so a repository can never switch the bridge on or
    off), or None when unset or unreadable."""
    script = os.path.join(HERE, "credo-config.sh")
    if not os.path.exists(script):
        return None
    env = dict(os.environ, CREDO_PROJECT="/dev/null", CREDO_SKIP_ENSURE="1")
    try:
        r = subprocess.run(["bash", script, "get", "peer.win_bridge.enabled"], env=env,
                           capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    out = r.stdout.strip().splitlines()
    return out[-1] if out else None


def enabled():
    env = os.environ.get("CREDO_WIN_BRIDGE")
    if env is not None and env.strip():
        return switch_value(env, None)
    return switch_value(None, config_value())


def ps_command():
    """argv that starts the PowerShell half, or None when Windows interop is not usable.
    CREDO_WIN_BRIDGE_PS_CMD (a JSON argv list) replaces it - TEST-ONLY, used by the
    fake-PowerShell harness."""
    raw = os.environ.get("CREDO_WIN_BRIDGE_PS_CMD")
    if raw:
        try:
            argv = json.loads(raw)
        except ValueError:
            return None
        return argv if isinstance(argv, list) and argv else None
    m = lan()
    if not m.wsl_interop_host():
        return None
    ps = m.win_tool("powershell.exe")
    if not ps:
        return None
    try:
        win = subprocess.run(["wslpath", "-w", os.path.join(HERE, PS_SCRIPT)],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return None
    if not win:
        return None
    return [ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", win, "-Mode", "Bridge"]


# ---------------------------------------------------------------------------
# pure helpers (unit-tested)
# ---------------------------------------------------------------------------
def pipe_name(msp):
    """'LOCAL\\cc-msg-...' (the .NET pipe name) of a Windows messagingSocketPath, or None
    when it is not a pipe path."""
    if not isinstance(msp, str):
        return None
    m = PIPE_PATH_RE.match(msp)
    if not m or m.group(2) in (".", "..") or re.search(r"[. ]$", m.group(2)):
        return None
    if msp.startswith("\\\\?\\") and "/" in msp:
        return None
    return m.group(2) if m.group(1) is None else "LOCAL\\" + m.group(2)


def canonical_pipe_path(msp):
    """The form Claude Code hashes for key file names: \\\\.\\pipe\\ + the pipe name with
    ASCII A-Z lowercased."""
    name = pipe_name(msp)
    if name is None:
        return None
    return "\\\\.\\pipe\\" + re.sub(r"[A-Z]", lambda m: m.group(0).lower(), name)


def key_file_name(pid, msp):
    """<pid>.<sha256 hex of canonical_pipe_path>.key - the per-session key file a
    Windows sender looks up for a target pipe."""
    canon = canonical_pipe_path(msp)
    if canon is None:
        return None
    return "%d.%s.key" % (int(pid), hashlib.sha256(canon.encode("utf-8")).hexdigest())


def auth_line(token):
    """The line a Windows inbox requires before a message (JSON + newline)."""
    if not isinstance(token, str) or not TOKEN_RE.match(token):
        raise ValueError("invalid token")
    return ('{"type":"auth","token":"%s"}\n' % token).encode("ascii")


def token_equal(got, want):
    """Constant-time token comparison; False for anything that is not text."""
    if not isinstance(got, str) or not isinstance(want, str):
        return False
    return hmac.compare_digest(got.encode("utf-8"), want.encode("utf-8"))


def _auth_value(line):
    try:
        obj = json.loads(line.decode("utf-8"))
    except Exception:
        return None
    if isinstance(obj, dict) and obj.get("type") == "auth":
        tok = obj.get("token")
        return tok if isinstance(tok, str) else ""
    return None


def check_auth(data, token):
    """(ok, rest): data must start with an auth line whose token equals token
    (constant time); rest is everything after that line, byte for byte."""
    first, sep, rest = data.partition(b"\n")
    if not sep:
        return False, b""
    got = _auth_value(first.strip())
    if got is None or not token_equal(got, token):
        return False, b""
    return True, rest


def strip_auth(data):
    """data without a leading auth line (a token must never travel from one side to
    the other); other data is returned unchanged."""
    first, sep, rest = data.partition(b"\n")
    if sep and _auth_value(first.strip()) is not None:
        return rest
    return data


def json_inner(text):
    """text as it appears inside a JSON string (without the quotes)."""
    return json.dumps(text)[1:-1]


def frame_from(line):
    """The "from" address of one message line (without "uds:"), or None."""
    try:
        obj = json.loads(line.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(obj, dict):
        return None
    frm = obj.get("from")
    if isinstance(frm, str) and frm.startswith("uds:") and len(frm) > 4:
        return frm[4:]
    return None


def rewrite_address(line, old, new):
    """Swap the reply address uds:<old> for uds:<new> in one JSON message line: the
    frame's "from" field and the from= attribute of the envelope (both are JSON string
    contents, followed by a quote or an escaped quote). Every other byte stays."""
    if not old or not new or old == new:
        return line
    try:
        text = line.decode("utf-8")
    except UnicodeDecodeError:
        return line
    pat = re.compile(re.escape("uds:" + json_inner(old)) + r'(?=\\?")')
    out = pat.sub(lambda _m: "uds:" + json_inner(new), text)
    return out.encode("utf-8")


def rewrite_lines(data, lookup):
    """Apply rewrite_address to every line of data; lookup(old_address) returns the
    replacement address or None (no change)."""
    out = []
    for line in data.split(b"\n"):
        old = frame_from(line) if line.strip() else None
        new = lookup(old) if old else None
        out.append(rewrite_address(line, old, new) if new else line)
    return b"\n".join(out)


def parse_win_sessions(items):
    """The usable Windows sessions of a list reply: a dict with an int pid, a sessionId,
    a Claude Code pipe address, no mirror marker (ours or a native LAN relay's). Each
    sessionId once (the newest updatedAt wins), at most MAX_WIN_SESSIONS."""
    best = {}
    for d in items if isinstance(items, list) else []:
        if not isinstance(d, dict) or d.get(MARK) or d.get(LAN_MARK) or d.get(BRIDGE_MARK):
            continue
        pid, sid = d.get("pid"), d.get("sessionId")
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            continue
        if not isinstance(sid, str) or not SID_RE.match(sid):
            continue
        name = pipe_name(d.get("messagingSocketPath"))
        if name is None or not CC_PIPE_RE.match(name):
            continue
        cur = best.get(sid)
        if cur is None or _num(d.get("updatedAt")) > _num(cur.get("updatedAt")):
            best[sid] = d
    out = sorted(best.values(), key=lambda d: d["sessionId"])
    return out[:MAX_WIN_SESSIONS]


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def win_host(d):
    dom = d.get("pidDomain") if isinstance(d, dict) else None
    if isinstance(dom, str) and dom.startswith("win32:"):
        return session_name.clean(dom[6:], 40) or "windows"
    return "windows"


def win_mirror_name(win, user=""):
    """Display name of a Windows session inside WSL, LAN-relay convention:
    `Claude Code`--`Windows`--`<host>`--`<user>`--`.claude`--`<name>`+sid-short."""
    sid = win.get("sessionId", "")
    name = session_name.clean(win.get("name"), session_name.NAME_MAX) or session_name.sid_short(sid)
    return lan().mirror_name(["Claude Code", "Windows", win_host(win), user, ".claude"], name, sid)


def wsl_mirror_name(d, profile, display):
    """Display name of a WSL session on the Windows side. A LAN-relay mirror keeps its
    own (already qualified) name; a real session gets the LAN-relay convention."""
    if d.get(LAN_MARK):
        return str(d.get("name") or display)[:lan().MIRROR_NAME_MAX + 40]
    distro = os.environ.get("WSL_DISTRO_NAME") or "WSL"
    return lan().mirror_name(["Claude Code", "WSL", distro, getpass.getuser(), profile],
                             display, d.get("sessionId", ""))


def build_wsl_descriptor(win, holder_pid, pstart, template, sock, name, owner):
    """Mirror descriptor of a Windows session inside one WSL profile."""
    now = int(time.time() * 1000)
    return {
        "pid": holder_pid,
        "sessionId": win.get("sessionId"),
        "cwd": template.get("cwd", ""),
        "startedAt": now,
        "procStart": pstart,
        "version": template.get("version", win.get("version", "")),
        "peerProtocol": template.get("peerProtocol", 1),
        "peerFeatures": template.get("peerFeatures", []),
        "kind": "interactive",
        "entrypoint": template.get("entrypoint", "cli"),
        "pidDomain": template.get("pidDomain", ""),
        "messagingSocketPath": sock,
        "name": name,
        "nameSource": "credo-win-bridge",
        "nameSince": now,
        "updatedAt": now,
        "status": win.get("status", "idle") if isinstance(win.get("status"), str) else "idle",
        "statusUpdatedAt": now,
        MARK: True,
        NAME_KEY: session_name.clean(win.get("name"), session_name.NAME_MAX),
        PROFILE_KEY: "windows/.claude",
        OWNER_KEY: owner,
    }


def read_descriptors(sess_dir):
    """(path, dict) of every <digits>.json regular file in sess_dir that parses."""
    out = []
    try:
        names = os.listdir(sess_dir)
    except OSError:
        return out
    for n in sorted(names):
        if not n.endswith(".json") or not n[:-5].isdigit():
            continue
        p = os.path.join(sess_dir, n)
        if os.path.islink(p):
            continue
        try:
            with open(p) as fh:
                d = json.load(fh)
        except Exception:
            continue
        if isinstance(d, dict):
            out.append((p, d))
    return out


def publish_list(sess_dirs, live=None, snap=None):
    """The WSL sessions to offer on Windows: live descriptors with a unix inbox in any
    profile, never our own mirrors nor credo-peer-bridge copies; each sessionId once (a
    real session wins over a LAN-relay mirror of the same id). Entries carry the publish
    fields plus "sock" (the WSL inbox) and "profile"."""
    live = live or lan().descriptor_live
    chosen = {}
    for sess_dir in sess_dirs:
        prof = profiles.profile_name(os.path.dirname(sess_dir))
        for _p, d in read_descriptors(sess_dir):
            if d.get(MARK) or d.get(BRIDGE_MARK):
                continue
            sid, sock = d.get("sessionId"), d.get("messagingSocketPath")
            if not isinstance(sid, str) or not SID_RE.match(sid):
                continue
            if not isinstance(sock, str) or not sock.startswith("/"):
                continue
            if not live(d):
                continue
            cur = chosen.get(sid)
            if cur is not None and (not cur[0].get(LAN_MARK) or d.get(LAN_MARK)):
                continue
            chosen[sid] = (d, prof)
    out = []
    for sid in sorted(chosen):
        d, prof = chosen[sid]
        try:
            display = session_name.claude_name(d, snap)
        except Exception:
            display = session_name.sid_short(sid)
        out.append({
            "key": sid,
            "sessionId": sid,
            "name": wsl_mirror_name(d, prof, display),
            "status": d.get("status") if isinstance(d.get("status"), str) else "idle",
            "cwd": d.get("cwd") if isinstance(d.get("cwd"), str) else "",
            "version": d.get("version") if isinstance(d.get("version"), str) else "",
            "peerProtocol": d.get("peerProtocol") if isinstance(d.get("peerProtocol"), int) else 1,
            "peerFeatures": [f for f in d.get("peerFeatures") or [] if isinstance(f, str)][:32],
            "kind": "interactive",
            "entrypoint": d.get("entrypoint") if isinstance(d.get("entrypoint"), str) else "cli",
            "sock": sock_of(d),
            "profile": prof,
        })
    return out


def sock_of(d):
    return d.get("messagingSocketPath")


def template_for(sess_dir, live=None):
    """A live real local session of sess_dir (no mirror marker) to copy pidDomain,
    version and peer fields from; the newest one, or None."""
    live = live or lan().descriptor_live
    best = None
    for _p, d in read_descriptors(sess_dir):
        if d.get(MARK) or d.get(LAN_MARK) or d.get(BRIDGE_MARK) or not d.get("pidDomain"):
            continue
        if not live(d):
            continue
        if best is None or _num(d.get("updatedAt")) > _num(best.get("updatedAt")):
            best = d
    return best


def prune_own_descriptors(sess_dirs, keep_pids=()):
    """Remove every descriptor carrying our marker whose pid is not one of keep_pids.
    Files without the marker are never touched. Returns the removed paths."""
    removed = []
    for sess_dir in sess_dirs:
        for p, d in read_descriptors(sess_dir):
            if not d.get(MARK):
                continue
            if d.get("pid") in keep_pids:
                continue
            try:
                os.unlink(p)
                removed.append(p)
            except OSError:
                pass
    return removed


def prune_own_sockets(sdir, keep=()):
    """Remove wb-*.sock files in our own sock dir that are not in keep."""
    removed = []
    try:
        names = os.listdir(sdir)
    except OSError:
        return removed
    for n in names:
        if not (n.startswith(SOCK_PREFIX) and n.endswith(".sock")):
            continue
        p = os.path.join(sdir, n)
        if p in keep:
            continue
        try:
            os.unlink(p)
            removed.append(p)
        except OSError:
            pass
    return removed


def atomic_write_json(path, obj):
    tmp = "%s.credo-wb.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w") as fh:
            fh.write(json.dumps(obj))
        os.replace(tmp, path)
        return True
    except Exception as exc:
        log("write %s failed: %s" % (path, exc))
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def foreign_file(path):
    """True when path holds something that is not one of our descriptors (never
    overwrite it); False when it is absent or ours."""
    try:
        with open(path) as fh:
            d = json.load(fh)
    except FileNotFoundError:
        return False
    except Exception:
        return True
    return not (isinstance(d, dict) and d.get(MARK))


def encode(obj):
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")


def b64(data):
    return base64.b64encode(data).decode("ascii")


def unb64(text):
    try:
        return base64.b64decode(text.encode("ascii"), validate=True)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# holder: one per Windows session (a live local process for the descriptor)
# ---------------------------------------------------------------------------
def run_holder(sock_path):
    """Listen on sock_path for WSL senders; every connection is read to EOF (or
    CONN_TIMEOUT), closed, and its bytes go to the daemon as {"op":"in"}. Daemon
    commands on stdin: {"op":"write","target":path,"data":b64} writes into a WSL inbox
    from THIS process (so the receiver sees this holder's pid). Exits on stdin EOF or
    when the parent changes."""
    parent = os.getppid()
    out_lock = threading.Lock()

    def emit(obj):
        with out_lock:
            try:
                sys.stdout.buffer.write(encode(obj))
                sys.stdout.buffer.flush()
            except (OSError, ValueError):
                os._exit(0)

    try:
        os.unlink(sock_path)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)
    try:
        srv.bind(sock_path)
    finally:
        os.umask(old)
    srv.listen(16)
    srv.settimeout(2.0)
    stop = threading.Event()

    def serve(conn):
        buf = b""
        try:
            conn.settimeout(CONN_TIMEOUT)
            deadline = time.monotonic() + CONN_TIMEOUT
            while time.monotonic() < deadline:
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                buf += chunk
                if len(buf) > MAX_MSG:
                    buf = b""
                    break
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
        if buf.strip():
            emit({"op": "in", "data": b64(buf)})

    def commands():
        for raw in sys.stdin.buffer:
            try:
                cmd = json.loads(raw.decode("utf-8"))
            except Exception:
                continue
            if not isinstance(cmd, dict):
                continue
            if cmd.get("op") == "write":
                data = unb64(cmd.get("data") or "")
                ok, err = write_unix(cmd.get("target"), data)
                emit({"op": "wrote", "id": cmd.get("id"), "ok": ok, "err": err})
            elif cmd.get("op") == "quit":
                break
        stop.set()
        try:
            srv.close()
        except OSError:
            pass

    threading.Thread(target=commands, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    try:
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                if os.getppid() != parent:
                    break
                continue
            except OSError:
                break
            threading.Thread(target=serve, args=(conn,), daemon=True).start()
    finally:
        try:
            os.unlink(sock_path)
        except OSError:
            pass
    return 0


def write_unix(target, data):
    """Write data into a local unix inbox and half-close (what a Claude Code sender
    does). Returns (ok, error text)."""
    if not isinstance(target, str) or not target.startswith("/") or not data:
        return False, "bad target or empty data"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(CONN_TIMEOUT)
    try:
        s.connect(target)
        s.sendall(data if data.endswith(b"\n") else data + b"\n")
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        return True, ""
    except OSError as exc:
        return False, str(exc)
    finally:
        s.close()


class Holder(object):
    """Daemon-side handle of one holder subprocess."""

    def __init__(self, daemon, win, name):
        self.daemon = daemon
        self.sid = win["sessionId"]
        self.win = win
        self.name = name
        self.sock = os.path.join(sock_dir(), "%s%s.sock" % (SOCK_PREFIX, uuid.uuid4().hex[:12]))
        self.descs = {}
        self.lock = threading.Lock()
        self.proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "holder", "--sock", self.sock],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, close_fds=True)
        self.pid = self.proc.pid
        threading.Thread(target=self._reader, daemon=True).start()

    def wait_ready(self, timeout=2.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if os.path.exists(self.sock):
                return True
            if self.proc.poll() is not None:
                return False
            time.sleep(0.02)
        return False

    def alive(self):
        return self.proc.poll() is None

    def _reader(self):
        for raw in self.proc.stdout:
            try:
                ev = json.loads(raw.decode("utf-8"))
            except Exception:
                continue
            if not isinstance(ev, dict):
                continue
            if ev.get("op") == "in":
                data = unb64(ev.get("data") or "")
                if data:
                    self.daemon.to_windows(self, data)
            elif ev.get("op") == "wrote" and not ev.get("ok"):
                log("holder %d: write into a WSL inbox failed: %s" % (self.pid, ev.get("err")))

    def write(self, target, data):
        with self.lock:
            try:
                self.proc.stdin.write(encode({"op": "write", "target": target, "data": b64(data)}))
                self.proc.stdin.flush()
                return True
            except (OSError, ValueError):
                return False

    def stop(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=3)
        except Exception:
            try:
                self.proc.kill()
            except OSError:
                pass
        for p in list(self.descs.values()):
            if not foreign_file(p):
                try:
                    os.unlink(p)
                except OSError:
                    pass
        self.descs.clear()
        try:
            os.unlink(self.sock)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# daemon
# ---------------------------------------------------------------------------
class Daemon(object):
    def __init__(self, ps_argv, interval=DEFAULT_INTERVAL, sess_dirs_fn=None):
        self.ps_argv = ps_argv
        self.interval = interval
        self.sess_dirs_fn = sess_dirs_fn or profiles.sessions_dirs
        self.lock = threading.RLock()
        self.stop_ev = threading.Event()
        self.ps = None
        self.ps_lock = threading.Lock()
        self.ps_ready = False
        self.ps_backoff = 1.0
        self.ps_next_start = 0.0
        self.holders = {}          # Windows sessionId -> Holder
        self.published = {}        # WSL sessionId -> publish entry (with "sock")
        self.mirror_pipe = {}      # WSL sessionId -> Windows mirror pipe path
        self.next_id = 1
        self.user = ""
        self.last_list = 0.0
        self.last_config = time.monotonic()

    # -- PowerShell half ----------------------------------------------------
    def _start_ps(self):
        try:
            self.ps = subprocess.Popen(self.ps_argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=open(log_path(), "a"), close_fds=True)
        except OSError as exc:
            log("cannot start the PowerShell half: %s" % exc)
            self.ps = None
            return
        self.ps_ready = False
        log("PowerShell half started (pid %d)" % self.ps.pid)
        threading.Thread(target=self._ps_reader, args=(self.ps,), daemon=True).start()

    def send_ps(self, obj):
        with self.ps_lock:
            ps = self.ps
            if ps is None or ps.poll() is not None:
                return False
            try:
                ps.stdin.write(encode(obj))
                ps.stdin.flush()
                return True
            except (OSError, ValueError):
                return False

    def _ps_reader(self, ps):
        for raw in ps.stdout:
            try:
                ev = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                continue
            if isinstance(ev, dict):
                try:
                    self.on_ps_event(ev)
                except Exception as exc:
                    log("PowerShell event %r failed: %s" % (ev.get("op"), exc))
        log("PowerShell half ended (rc=%s)" % ps.poll())

    def on_ps_event(self, ev):
        op = ev.get("op")
        if op == "ready":
            self.ps_ready = True
            self.ps_backoff = 1.0
            self.user = session_name.clean(ev.get("user"), 40)
            log("PowerShell half ready (pid %s)" % ev.get("pid"))
            self.tick(force=True)
        elif op == "list":
            self.on_list(ev.get("sessions"))
        elif op == "published":
            self.on_published(ev.get("mirrors"))
        elif op == "msg":
            data = unb64(ev.get("data") or "")
            if data:
                self.to_wsl(ev.get("key"), data)
        elif op == "sent":
            if not ev.get("ok"):
                log("send to a Windows session failed: %s" % ev.get("err"))
        elif op == "log":
            log("ps: %s" % str(ev.get("text"))[:400])

    # -- Windows sessions mirrored into WSL ---------------------------------
    def on_list(self, items):
        wins = parse_win_sessions(items)
        want = dict((w["sessionId"], w) for w in wins)
        sess_dirs = self.sess_dirs_fn()
        with self.lock:
            for sid in list(self.holders):
                if sid not in want or not self.holders[sid].alive():
                    self._drop_holder(sid)
            for sid, win in want.items():
                h = self.holders.get(sid)
                name = win_mirror_name(win, self.user)
                if h is None:
                    self._add_holder(win, name, sess_dirs)
                else:
                    h.win = win
                    self._sync_descs(h, win, name, sess_dirs)
        self.write_status()

    def _add_holder(self, win, name, sess_dirs):
        try:
            h = Holder(self, win, name)
        except OSError as exc:
            log("cannot start a holder for %s: %s" % (name, exc))
            return
        if not h.wait_ready():
            log("holder for %s did not come up" % name)
            h.stop()
            return
        self.holders[win["sessionId"]] = h
        self._sync_descs(h, win, name, sess_dirs)
        log("windows session up: %s -> holder pid %d" % (name, h.pid))

    def _sync_descs(self, h, win, name, sess_dirs):
        try:
            pstart = lan().proc_start(h.pid)
        except Exception:
            return
        for sd in list(h.descs):
            if sd not in sess_dirs:
                p = h.descs.pop(sd)
                if not foreign_file(p):
                    try:
                        os.unlink(p)
                    except OSError:
                        pass
        for sd in sess_dirs:
            path = os.path.join(sd, "%d.json" % h.pid)
            if foreign_file(path):
                continue
            cur = None
            if sd in h.descs:
                try:
                    with open(path) as fh:
                        cur = json.load(fh)
                except Exception:
                    cur = None
            status = win.get("status") if isinstance(win.get("status"), str) else "idle"
            if cur is not None and cur.get("name") == name and cur.get("status") == status:
                continue
            # the profile's own live session, else any profile's (same machine and pid
            # namespace), so a profile without a running session still gets the mirror
            tpl = template_for(sd) or next(
                (t for t in (template_for(o) for o in sess_dirs if o != sd) if t), None)
            if tpl is None:
                continue
            d = build_wsl_descriptor(win, h.pid, pstart, tpl, h.sock, name, os.getpid())
            if cur is not None:
                d["startedAt"] = cur.get("startedAt", d["startedAt"])
            if atomic_write_json(path, d):
                h.descs[sd] = path

    def _drop_holder(self, sid):
        h = self.holders.pop(sid, None)
        if h is not None:
            h.stop()
            log("windows session gone: %s" % h.name)

    def holder_for_pipe(self, address):
        canon = canonical_pipe_path(address)
        if canon is None:
            return None
        with self.lock:
            for h in self.holders.values():
                if canonical_pipe_path(h.win.get("messagingSocketPath")) == canon:
                    return h
        return None

    # -- WSL sessions offered on Windows ------------------------------------
    def publish(self):
        try:
            snap = session_name.Snapshot()
        except Exception:
            snap = None
        entries = publish_list(self.sess_dirs_fn(), snap=snap)
        with self.lock:
            self.published = dict((e["sessionId"], e) for e in entries)
        wire = [dict((k, v) for k, v in e.items() if k not in ("sock", "profile")) for e in entries]
        self.send_ps({"op": "publish", "sessions": wire})

    def on_published(self, mirrors):
        out = {}
        for m in mirrors if isinstance(mirrors, list) else []:
            if not isinstance(m, dict):
                continue
            key, pipe = m.get("key"), m.get("pipe")
            name = pipe_name(pipe)
            if isinstance(key, str) and name and CC_PIPE_RE.match(name):
                out[key] = pipe
        with self.lock:
            self.mirror_pipe = out
        self.write_status()

    def mirror_for_sock(self, sock):
        with self.lock:
            for sid, e in self.published.items():
                if e.get("sock") == sock and sid in self.mirror_pipe:
                    return self.mirror_pipe[sid]
        return None

    # -- message paths --------------------------------------------------------
    def to_windows(self, holder, data):
        """Bytes a WSL session wrote into a holder: drop any auth line, swap the
        sender's WSL inbox for its Windows mirror pipe, send to the Windows session."""
        data = strip_auth(data)
        data = rewrite_lines(data, self.mirror_for_sock)
        if not data.strip():
            return
        win = holder.win
        rid = self._id()
        if not self.send_ps({"op": "send", "id": rid, "pid": win.get("pid"),
                             "pipe": win.get("messagingSocketPath"), "data": b64(data)}):
            log("message to %s dropped: the PowerShell half is not running" % holder.name)

    def to_wsl(self, key, data):
        """Bytes a Windows session wrote into the mirror pipe of WSL session `key`
        (auth line already checked and stripped on Windows): swap the sender's pipe for
        its holder socket and let that holder write it, so the receiver sees the
        sender's mirror process."""
        with self.lock:
            entry = self.published.get(key) if isinstance(key, str) else None
        if entry is None:
            log("message for unknown WSL session %r dropped" % key)
            return
        writer = [None]

        def lookup(addr):
            h = self.holder_for_pipe(addr)
            if h is None:
                return None
            writer[0] = h
            return h.sock

        data = rewrite_lines(data, lookup)
        target = entry["sock"]
        h = writer[0]
        if h is not None and h.alive() and h.write(target, data):
            return
        ok, err = write_unix(target, data)
        if not ok:
            log("message into %s failed: %s" % (entry.get("name"), err))

    def _id(self):
        with self.lock:
            self.next_id += 1
            return self.next_id

    # -- loop -----------------------------------------------------------------
    def tick(self, force=False):
        now = time.monotonic()
        if not force and now - self.last_list < self.interval:
            return
        self.last_list = now
        if not self.ps_ready:
            return
        self.send_ps({"op": "list", "id": self._id()})
        self.publish()

    def write_status(self):
        with self.lock:
            st = {
                "pid": os.getpid(),
                "version": VERSION,
                "ps_pid": self.ps.pid if self.ps is not None and self.ps.poll() is None else None,
                "windows_sessions": sorted(h.name for h in self.holders.values()),
                "published": len(self.mirror_pipe),
                "updated": int(time.time()),
            }
        atomic_write_json(status_path(), st)

    def run(self):
        sess_dirs = self.sess_dirs_fn()
        for p in prune_own_descriptors(sess_dirs):
            log("removed stale mirror %s" % p)
        prune_own_sockets(sock_dir())
        while not self.stop_ev.is_set():
            ps = self.ps
            if ps is None or ps.poll() is not None:
                with self.lock:
                    for sid in list(self.holders):
                        self._drop_holder(sid)
                    self.mirror_pipe = {}
                now = time.monotonic()
                if now >= self.ps_next_start:
                    self._start_ps()
                    self.ps_next_start = now + self.ps_backoff
                    self.ps_backoff = min(self.ps_backoff * 2, PS_RESTART_MAX)
            self.tick()
            if time.monotonic() - self.last_config > CONFIG_RECHECK:
                self.last_config = time.monotonic()
                if not enabled():
                    log("switched off in the credo config, stopping")
                    break
            self.stop_ev.wait(0.5)
        self.shutdown()

    def shutdown(self):
        with self.lock:
            for sid in list(self.holders):
                self._drop_holder(sid)
        ps = self.ps
        if ps is not None and ps.poll() is None:
            self.send_ps({"op": "quit"})
            try:
                ps.stdin.close()
            except Exception:
                pass
            try:
                ps.wait(timeout=8)
            except Exception:
                try:
                    ps.kill()
                except OSError:
                    pass
        prune_own_descriptors(self.sess_dirs_fn())
        prune_own_sockets(sock_dir())
        log("stopped")


# ---------------------------------------------------------------------------
# single instance + CLI
# ---------------------------------------------------------------------------
def read_pidfile():
    try:
        with open(pidfile_path()) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def daemon_alive(rec):
    """True when rec names a live credo-win-bridge daemon (pid alive, same procStart,
    command line is this script's daemon subcommand)."""
    if not isinstance(rec, dict) or not isinstance(rec.get("pid"), int):
        return False
    pid = rec["pid"]
    try:
        if lan().proc_start(pid) != rec.get("procStart"):
            return False
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            argv = fh.read().split(b"\0")
    except Exception:
        return False
    return any(a.endswith(b"credo-win-bridge.py") for a in argv) and b"daemon" in argv


def version_tuple(v):
    try:
        return tuple(int(x) for x in str(v).split("."))
    except ValueError:
        return None


def cmd_daemon():
    if fcntl is None:
        return 1
    ensure_dirs()
    lock_fh = open(os.path.join(state_dir(), "bridge.lock"), "a")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another bridge daemon is running, exiting")
        return 0
    if not enabled():
        log("switched off (peer.win_bridge.enabled / CREDO_WIN_BRIDGE), not starting")
        return 0
    argv = ps_command()
    if argv is None:
        log("Windows interop (powershell.exe) not available, not starting")
        return 0
    atomic_write_json(pidfile_path(), {"pid": os.getpid(), "procStart": lan().proc_start(os.getpid()),
                                       "version": VERSION})
    try:
        interval = float(os.environ.get("CREDO_WIN_BRIDGE_INTERVAL") or DEFAULT_INTERVAL)
    except ValueError:
        interval = DEFAULT_INTERVAL
    d = Daemon(argv, interval=max(0.2, interval))
    signal.signal(signal.SIGTERM, lambda *_: d.stop_ev.set())
    signal.signal(signal.SIGINT, lambda *_: d.stop_ev.set())
    log("daemon up (version %s)" % VERSION)
    try:
        d.run()
    finally:
        rec = read_pidfile()
        if rec and rec.get("pid") == os.getpid():
            try:
                os.unlink(pidfile_path())
            except OSError:
                pass
    return 0


def stop_daemon(rec, timeout=10.0):
    if not daemon_alive(rec):
        return False
    try:
        os.kill(rec["pid"], signal.SIGTERM)
    except OSError:
        return False
    end = time.monotonic() + timeout
    while time.monotonic() < end and daemon_alive(rec):
        time.sleep(0.1)
    return not daemon_alive(rec)


def cmd_ensure():
    """Start the daemon detached when it is switched on, interop works and none runs;
    replace an OLDER running one; stop a running one when switched off."""
    rec = read_pidfile()
    if not enabled():
        if stop_daemon(rec):
            print("stopped (switched off)")
        return 0
    if ps_command() is None:
        return 0
    if daemon_alive(rec):
        mine, theirs = version_tuple(VERSION), version_tuple(rec.get("version"))
        if mine is None or theirs is None or theirs >= mine:
            return 0
        stop_daemon(rec)
    ensure_dirs()
    with open(log_path(), "a") as out:
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "daemon"],
                         stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                         start_new_session=True, close_fds=True)
    return 0


def cmd_stop():
    rec = read_pidfile()
    if not daemon_alive(rec):
        print("not running")
        return 0
    print("stopped" if stop_daemon(rec) else "stop failed")
    return 0


def cmd_status():
    rec = read_pidfile()
    on = enabled()
    print("switch: %s" % ("on" if on else "off (peer.win_bridge.enabled / CREDO_WIN_BRIDGE)"))
    if not daemon_alive(rec):
        print("daemon: not running")
        return 0
    print("daemon: running (pid %d, version %s)" % (rec["pid"], rec.get("version")))
    try:
        with open(status_path()) as fh:
            st = json.load(fh)
    except Exception:
        st = {}
    wins = st.get("windows_sessions") or []
    print("windows sessions mirrored into WSL: %d" % len(wins))
    for n in wins:
        print("  %s" % n)
    print("WSL sessions offered on Windows: %s" % st.get("published", 0))
    print("log: %s" % log_path())
    return 0


def main(argv):
    if not argv:
        print(__doc__.split("\n\n")[0])
        print("usage: credo-win-bridge.py ensure | daemon | stop | status | enabled")
        return 2
    cmd = argv[0]
    if cmd == "holder":
        if len(argv) != 3 or argv[1] != "--sock":
            return 2
        return run_holder(argv[2])
    if cmd == "daemon":
        return cmd_daemon()
    if cmd == "ensure":
        return cmd_ensure()
    if cmd == "stop":
        return cmd_stop()
    if cmd == "status":
        return cmd_status()
    if cmd == "enabled":
        print("true" if enabled() else "false")
        return 0
    print("unknown command: %s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

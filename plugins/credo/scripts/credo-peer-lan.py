#!/usr/bin/env python3
"""credo-peer-lan.py - LAN relay so Claude Code peer sessions on different machines
in the same trusted network can see and message each other without the Anthropic
cloud (no Remote Control, no API).

It extends the same-machine peer model (see hooks/credo-peer-bridge.sh): Claude Code
enumerates local peers by reading session descriptor files under
"<CLAUDE_CONFIG_DIR>/sessions/<pid>.json" and resolves a peer name to its inbox unix
socket (messagingSocketPath). This daemon makes REMOTE sessions appear there too, so
ListAgents lists them and SendMessage reaches them, with replies routing back.

How a remote session is represented locally
--------------------------------------------
A remote session has no local process, so its pid is not alive and its descriptor
would be reaped by the discovery reader (which validates the pid is a live local
process, matching procStart = field 22 of /proc/<pid>/stat to resist pid reuse) and
by credo-peer-bridge.sh's prune. So for each remote session this daemon spawns one
lightweight local HOLDER subprocess that listens on a local PROXY unix socket. The
holder is a real live local process, so:
  - its pid is alive (kill -0 succeeds),
  - its /proc/<pid>/stat procStart is real,
and the mirrored descriptor uses the holder pid as both the <pid> filename and the
descriptor's pid/procStart fields, copies pidDomain from a real local session (so it
is treated as local), points messagingSocketPath at the proxy socket, keeps the
remote name suffixed with the machine ("name@machine"), and carries the marker key
"credoPeerLan" (NOT "credoPeerBridge", so the existing bridge never touches it).

When a local session writes into a proxy socket, the holder forwards the message as a
"deliver" over TCP to the owning remote daemon, which injects it into the real local
target socket there.

SAFETY
  - The injected envelope NEVER carries a from-mode attribute. Omitting it is the
    whole point: the receiving session applies its OWN built-in consent gate instead
    of us forging a trusted sender. The relay is mode-agnostic (name/body/reply only).
  - This daemon only ever removes session descriptors that carry its own
    "credoPeerLan" marker, and only proxy sockets / holders it created.
  - No-op when no config file exists, or when CREDO_PEER_LAN is set to off.

Transport: line-based JSON over TCP. A shared token is OPTIONAL. With a token, frames
are signed and verified with HMAC-SHA256 (reject on mismatch). Without one (the casual
default), the daemon runs token-less: it signs nothing and accepts unsigned frames, so
any device that can reach the port may message local sessions - still gated by each
receiving session's own consent prompt (we never forge a from-mode). Python 3 stdlib
only.
"""

import argparse
import errno
import hashlib
import hmac
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

MARK = "credoPeerLan"
MARK_FROM = "credoPeerLanFrom"
DEFAULT_PORT = 48610
DEFAULT_ROSTER_INTERVAL = 5.0
DEFAULT_MACHINE_TIMEOUT = 30.0
# upper bound on remote sessions materialized per machine, to cap subprocess and
# disk growth from a large or hostile roster (config key max_remotes_per_machine)
MAX_REMOTES_PER_MACHINE = 64
# upper bound on concurrent inbound TCP handler threads. Auth happens only after a
# full line is read, so without this cap an unauthenticated LAN client could open
# many connections and exhaust threads/memory (config key max_conn_threads).
MAX_CONN_THREADS = 64
# upper bound on concurrent holder proxy-connection worker threads, so one stuck
# local client cannot block other local writers and the pool cannot grow unbounded.
MAX_HOLDER_WORKERS = 16
# how long the holder server socket blocks on accept before re-checking its parent
HOLDER_ACCEPT_TIMEOUT = 2.0
# how long an accept loop waits to acquire its concurrency slot before shedding a
# connection, so the accept loop itself never blocks on a full pool
ACQUIRE_TIMEOUT = 0.5
ENVELOPE_RE = re.compile(
    r"<cross-session-message\b[^>]*>(.*)</cross-session-message>", re.S
)
FROM_NAME_RE = re.compile(r'from-name="([^"]*)"')


def log(msg):
    sys.stderr.write("[credo-peer-lan %d] %s\n" % (os.getpid(), msg))
    sys.stderr.flush()


def disabled():
    return str(os.environ.get("CREDO_PEER_LAN", "1")).lower() in (
        "0",
        "false",
        "no",
        "off",
    )


def config_path():
    p = os.environ.get("CREDO_PEER_LAN_CONFIG")
    if p:
        return p
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )
    return os.path.join(cfg, "credo", "peer-lan.json")


def sessions_dir():
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )
    return os.path.join(cfg, "sessions")


def sock_dir():
    p = os.environ.get("CREDO_PEER_LAN_SOCKDIR")
    if p:
        return p
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(
        os.path.expanduser("~"), ".claude"
    )
    return os.path.join(cfg, "credo", "peer-lan-sock")


def load_config():
    path = config_path()
    try:
        with open(path) as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        return None
    except Exception as exc:
        log("config %s unreadable: %s" % (path, exc))
        return None
    if not isinstance(cfg, dict):
        log("config %s is not a JSON object" % path)
        return None
    return cfg


# ---------------------------------------------------------------------------
# line transport (HMAC-signed when a token is configured, unsigned otherwise)
# ---------------------------------------------------------------------------
def sign(token, body_str):
    return hmac.new(
        token.encode("utf-8"), body_str.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def frame_for(token, payload):
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    if token:
        wire = {"mac": sign(token, body), "body": body}
    else:
        wire = {"body": body}
    return json.dumps(wire) + "\n"


def verify_line(token, line):
    """Return the payload dict for an acceptable line, else None.
    With a token the line MUST carry a matching HMAC (reject on mismatch or when
    unsigned). Token-less, an unsigned body is accepted as-is (any mac is ignored)."""
    try:
        wire = json.loads(line)
    except Exception:
        return None
    if not isinstance(wire, dict):
        return None
    body = wire.get("body")
    if not isinstance(body, str):
        return None
    if token:
        mac = wire.get("mac")
        if not isinstance(mac, str):
            return None
        if not hmac.compare_digest(sign(token, body), mac):
            return None
    try:
        payload = json.loads(body)
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def send_to_peer(host, port, token, payload, timeout=5.0):
    line = frame_for(token, payload).encode("utf-8")
    s = socket.create_connection((host, port), timeout=timeout)
    try:
        s.sendall(line)
        s.shutdown(socket.SHUT_WR)
    finally:
        s.close()


# ---------------------------------------------------------------------------
# descriptor / proc helpers
# ---------------------------------------------------------------------------
def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def proc_start(pid):
    """Field 22 (starttime) of /proc/<pid>/stat as a string, robust to a comm
    containing spaces or parentheses."""
    with open("/proc/%d/stat" % int(pid)) as fh:
        data = fh.read()
    rparen = data.rfind(")")
    if rparen < 0:
        raise ValueError("no comm close paren")
    rest = data[rparen + 2 :].split()
    # overall field 3 (state) is rest[0]; field 22 (starttime) is rest[19]
    return rest[19]


def read_local_sessions(sess_dir):
    """Real local session descriptors only (not our mirrors, not bridge mirrors),
    returning the parsed dicts that have a socket and a sessionId."""
    out = []
    try:
        names = os.listdir(sess_dir)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".json"):
            continue
        base = name[:-5]
        if not base.isdigit():
            continue
        path = os.path.join(sess_dir, name)
        if os.path.islink(path):
            continue
        try:
            with open(path) as fh:
                d = json.load(fh)
        except Exception:
            continue
        if not isinstance(d, dict):
            continue
        if d.get(MARK) or d.get("credoPeerBridge"):
            continue
        if d.get("sessionId") and d.get("messagingSocketPath"):
            out.append(d)
    return out


def resolve_socket(sess_dir, session_id):
    for d in read_local_sessions(sess_dir):
        if d.get("sessionId") == session_id:
            return d.get("messagingSocketPath")
    return None


def strip_uds(addr):
    if isinstance(addr, str) and addr.startswith("uds:"):
        return addr[4:]
    return addr


# ---------------------------------------------------------------------------
# envelope (NEVER includes from-mode)
# ---------------------------------------------------------------------------
def build_envelope(body, from_name, reply):
    attrs = []
    if reply:
        attrs.append('from="%s"' % reply)
    if from_name:
        safe = from_name.replace('"', "").replace("<", "").replace(">", "")
        attrs.append('from-name="%s"' % safe)
    head = "<cross-session-message" + "".join(" " + a for a in attrs) + ">"
    return head + "\n" + body + "\n</cross-session-message>"


def inject(target_socket, from_name, body, reply):
    """Write one cross-session-message frame into a local inbox unix socket.
    reply is a 'uds:<path>' address or None. No from-mode is ever set."""
    envelope = build_envelope(body, from_name, reply)
    frame = {
        "type": "user",
        "message": {"content": envelope},
        "uuid": str(uuid.uuid4()),
        "priority": "next",
    }
    if reply:
        frame["from"] = reply
    line = (json.dumps(frame) + "\n").encode("utf-8")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(target_socket)
        s.sendall(line)
        s.shutdown(socket.SHUT_WR)
    finally:
        s.close()


# ===========================================================================
# HOLDER subprocess: one per remote session. Listens on the proxy socket and
# forwards every frame a local session writes into it as a "deliver" to the
# owning remote daemon over TCP.
# ===========================================================================
def run_holder(args):
    cfg = load_config()
    if cfg is None:
        log("holder: no config, exiting")
        return 1
    token = cfg.get("token", "")
    this_machine = args.this_machine or cfg.get("this_machine", "")
    peer = None
    for p in cfg.get("peers", []):
        if isinstance(p, dict) and p.get("name") == args.peer_name:
            peer = p
            break
    if peer is None:
        log("holder: peer %r not in config, exiting" % args.peer_name)
        return 1
    host, port = peer.get("host"), int(peer.get("port", DEFAULT_PORT))
    sess_dir = sessions_dir()
    proxy = args.proxy
    parent = os.getppid()

    try:
        os.unlink(proxy)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(proxy)
    except OSError as exc:
        log("holder: cannot bind %s: %s" % (proxy, exc))
        return 1
    srv.listen(16)
    # wake accept() periodically so an orphaned holder (parent daemon SIGKILLed or
    # power-lost, so we got reparented to init) can notice and exit cleanly, rather
    # than lingering and blocking a new daemon from reaping its descriptor.
    srv.settimeout(HOLDER_ACCEPT_TIMEOUT)

    stop = {"v": False}

    def _sig(_signo, _frame):
        stop["v"] = True
        try:
            srv.close()
        except OSError:
            pass

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    log(
        "holder up: proxy=%s -> %s target=%s via %s:%s"
        % (proxy, args.peer_name, args.target_session, host, port)
    )

    # Each accepted proxy connection is handled in its own short-lived daemon worker
    # thread, bounded by this semaphore, so a local client that opens the proxy and
    # stalls cannot delay other local writers (no head-of-line block). The accept
    # loop keeps its periodic wakeup so an orphaned holder still self-exits.
    worker_sem = threading.Semaphore(MAX_HOLDER_WORKERS)

    def _serve(conn):
        try:
            try:
                conn.settimeout(5)
                buf = b""
                while True:
                    try:
                        chunk = conn.recv(65536)
                    except socket.timeout:
                        break
                    if not chunk:
                        break
                    buf += chunk
            finally:
                conn.close()
            for line in buf.splitlines():
                line = line.strip()
                if not line:
                    continue
                _forward(line, token, host, port, args, sess_dir)
        except Exception as exc:
            log("holder: worker error: %s" % exc)
        finally:
            worker_sem.release()

    workers = []
    try:
        while not stop["v"]:
            workers = [w for w in workers if w.is_alive()]
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                if os.getppid() != parent:
                    log("holder: parent gone, exiting")
                    break
                continue
            except OSError:
                break
            if not worker_sem.acquire(timeout=ACQUIRE_TIMEOUT):
                log(
                    "holder: worker cap reached (%d); dropping a proxy connection"
                    % MAX_HOLDER_WORKERS
                )
                try:
                    conn.close()
                except OSError:
                    pass
                continue
            try:
                t = threading.Thread(target=_serve, args=(conn,), daemon=True)
                t.start()
                workers.append(t)
            except Exception as exc:
                worker_sem.release()
                log("holder: could not start worker: %s" % exc)
                try:
                    conn.close()
                except OSError:
                    pass
    finally:
        try:
            os.unlink(proxy)
        except OSError:
            pass
        for w in workers:
            w.join(timeout=1.0)
    return 0


def _forward(line, token, host, port, args, sess_dir):
    try:
        frame = json.loads(line.decode("utf-8"))
    except Exception:
        log("holder: unparseable frame dropped")
        return
    content = ""
    if isinstance(frame, dict):
        msg = frame.get("message")
        if isinstance(msg, dict):
            content = msg.get("content") or ""
    m = ENVELOPE_RE.search(content)
    body = m.group(1).strip() if m else content
    nm = FROM_NAME_RE.search(content)
    from_name = nm.group(1) if nm else ""
    reply = frame.get("from") if isinstance(frame, dict) else None
    from_session = ""
    sock_path = strip_uds(reply)
    if sock_path:
        for d in read_local_sessions(sess_dir):
            if d.get("messagingSocketPath") == sock_path:
                from_session = d.get("sessionId", "")
                break
    payload = {
        "kind": "deliver",
        "target_sessionId": args.target_session,
        "from_sessionId": from_session,
        "from_name": from_name,
        "body": body,
    }
    try:
        send_to_peer(host, port, token, payload)
        log("holder: forwarded deliver to %s (%s:%s)" % (args.peer_name, host, port))
    except Exception as exc:
        log("holder: forward to %s:%s failed: %s" % (host, port, exc))


# ===========================================================================
# DAEMON
# ===========================================================================
class AlreadyRunning(Exception):
    """Raised when the listen port is already bound by another daemon instance.
    The listen port itself is the single-instance lock, so a second start exits
    cleanly (0) instead of crashing with a traceback."""


class Daemon(object):
    def __init__(self, cfg):
        self.cfg = cfg
        self.token = cfg.get("token", "")
        self.this_machine = cfg.get("this_machine", socket.gethostname())
        self.listen_host = cfg.get("listen_host", "127.0.0.1")
        self.listen_port = int(cfg.get("listen_port", DEFAULT_PORT))
        self.peers = [p for p in cfg.get("peers", []) if isinstance(p, dict)]
        # names of configured peers; a roster from a machine NOT in here cannot be
        # matched to a peer, so its holder would fail to start (see _on_roster warning)
        self.peer_names = set(
            p.get("name") for p in self.peers if p.get("name")
        )
        self.roster_interval = float(
            cfg.get("roster_interval", DEFAULT_ROSTER_INTERVAL)
        )
        self.machine_timeout = float(
            cfg.get("machine_timeout", DEFAULT_MACHINE_TIMEOUT)
        )
        self.max_remotes = int(
            cfg.get("max_remotes_per_machine", MAX_REMOTES_PER_MACHINE)
        )
        self.max_conn_threads = int(
            cfg.get("max_conn_threads", MAX_CONN_THREADS)
        )
        # bounds concurrent inbound handler threads; the accept loop sheds load
        # rather than blocking when the pool is full (pre-auth exhaustion guard)
        self.conn_sem = threading.Semaphore(self.max_conn_threads)
        self.sess_dir = sessions_dir()
        self.sock_dir = sock_dir()
        self.script = os.path.abspath(__file__)
        self.lock = threading.Lock()
        # key (machine, sessionId) -> dict(holder=Popen, proxy, descriptor, pid)
        self.remotes = {}
        self.machine_seen = {}  # machine -> last roster monotonic time
        self.unknown_warned = set()  # machines warned once (not a configured peer)
        self.stop = threading.Event()
        self.srv = None

    # -- lifecycle ----------------------------------------------------------
    def start(self):
        try:
            os.makedirs(self.sock_dir, exist_ok=True)
        except OSError as exc:
            log("cannot create sock dir %s: %s" % (self.sock_dir, exc))
        # Bind the listen port FIRST - it is the single-instance lock. If another
        # daemon already holds it the bind fails with EADDRINUSE; we exit cleanly (0)
        # WITHOUT running any descriptor/socket cleanup, so a running daemon is never
        # disturbed by a second accidental start.
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.srv.bind((self.listen_host, self.listen_port))
        except OSError as exc:
            if exc.errno == errno.EADDRINUSE:
                log(
                    "another daemon already listening on %s:%d, exiting"
                    % (self.listen_host, self.listen_port)
                )
                try:
                    self.srv.close()
                except OSError:
                    pass
                raise AlreadyRunning()
            raise
        self._cleanup_stale_descriptors()
        self._cleanup_stale_sockets()
        self.srv.listen(32)
        log(
            "listening on %s:%d as %r; peers=%s"
            % (
                self.listen_host,
                self.listen_port,
                self.this_machine,
                [p.get("name") for p in self.peers],
            )
        )
        if not self.token:
            log(
                "WARNING: running without a shared token - any device that can "
                "reach %s:%d may send messages to your sessions (protected only by "
                "the receiving session's consent gate); set \"token\" in the config "
                "to restrict to your own devices."
                % (self.listen_host, self.listen_port)
            )
        threading.Thread(target=self._accept_loop, daemon=True).start()
        threading.Thread(target=self._roster_loop, daemon=True).start()
        threading.Thread(target=self._janitor_loop, daemon=True).start()

    def shutdown(self):
        if self.stop.is_set():
            return
        self.stop.set()
        log("shutting down")
        try:
            if self.srv:
                self.srv.close()
        except OSError:
            pass
        with self.lock:
            keys = list(self.remotes.keys())
        for key in keys:
            self._remove_remote(key)

    # -- inbound TCP --------------------------------------------------------
    def _accept_loop(self):
        while not self.stop.is_set():
            try:
                conn, addr = self.srv.accept()
            except OSError:
                break
            # bound concurrency: try to grab a slot without blocking the accept loop.
            # If the pool is full, shed this (still unauthenticated) connection rather
            # than spawning an unbounded number of handler threads.
            if not self.conn_sem.acquire(timeout=ACQUIRE_TIMEOUT):
                log(
                    "connection cap reached (%d); dropping %s"
                    % (self.max_conn_threads, addr)
                )
                try:
                    conn.close()
                except OSError:
                    pass
                continue
            try:
                threading.Thread(
                    target=self._handle_conn_guarded, args=(conn, addr), daemon=True
                ).start()
            except Exception as exc:
                self.conn_sem.release()
                log("could not start handler thread for %s: %s" % (addr, exc))
                try:
                    conn.close()
                except OSError:
                    pass

    def _handle_conn_guarded(self, conn, addr):
        try:
            self._handle_conn(conn, addr)
        finally:
            self.conn_sem.release()

    def _handle_conn(self, conn, addr):
        try:
            conn.settimeout(10)
            buf = b""
            while b"\n" not in buf:
                try:
                    chunk = conn.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    break
                buf += chunk
                if len(buf) > 4 * 1024 * 1024:
                    log("oversize message from %s dropped" % (addr,))
                    return
        finally:
            conn.close()
        for line in buf.splitlines():
            line = line.strip()
            if not line:
                continue
            payload = verify_line(self.token, line.decode("utf-8", "replace"))
            if payload is None:
                log("rejected unauthenticated/garbled message from %s" % (addr,))
                continue
            self._dispatch(payload)

    def _dispatch(self, payload):
        kind = payload.get("kind")
        if kind == "roster":
            self._on_roster(payload)
        elif kind == "deliver":
            self._on_deliver(payload)
        else:
            log("unknown message kind %r" % kind)

    # -- deliver (inject into a real local session) -------------------------
    def _on_deliver(self, payload):
        target = payload.get("target_sessionId")
        target_socket = resolve_socket(self.sess_dir, target)
        if not target_socket:
            log("deliver: no local session %r, dropped" % target)
            return
        reply = self._reply_addr_for(payload.get("from_sessionId"))
        try:
            inject(target_socket, payload.get("from_name", ""), payload.get("body", ""), reply)
            log("deliver: injected into %s (from %r)" % (target, payload.get("from_name")))
        except Exception as exc:
            log("deliver: inject into %s failed: %s" % (target_socket, exc))

    def _reply_addr_for(self, from_session):
        """A local proxy socket that routes back to the remote sender, if we hold
        one. Replies written there are forwarded home by that holder."""
        if not from_session:
            return None
        with self.lock:
            for (machine, sid), rec in self.remotes.items():
                if sid == from_session:
                    return "uds:" + rec["proxy"]
        return None

    # -- roster -------------------------------------------------------------
    def _roster_loop(self):
        while not self.stop.wait(self.roster_interval):
            sessions = [
                {
                    "sessionId": d.get("sessionId"),
                    "name": d.get("name") or d.get("sessionId"),
                    "status": d.get("status", "idle"),
                }
                for d in read_local_sessions(self.sess_dir)
            ]
            payload = {
                "kind": "roster",
                "machine": self.this_machine,
                "sessions": sessions,
            }
            for peer in self.peers:
                host, port = peer.get("host"), int(peer.get("port", DEFAULT_PORT))
                if not host:
                    continue
                try:
                    send_to_peer(host, port, self.token, payload)
                except Exception as exc:
                    log("roster to %s (%s:%s) failed: %s" % (peer.get("name"), host, port, exc))

    def _on_roster(self, payload):
        machine = payload.get("machine")
        if not machine:
            return
        sessions = payload.get("sessions")
        if not isinstance(sessions, list):
            sessions = []
        now = time.monotonic()
        with self.lock:
            self.machine_seen[machine] = now
            # Misconfiguration signal: a roster from a machine that is not among our
            # configured peer names means no peers[].name equals that machine's
            # this_machine, so its holder cannot resolve the peer and the remote peer
            # silently never appears. Warn once per unknown machine (no per-interval
            # spam), at daemon level so it is visible in the main log, not only the
            # holder-level "peer X not in config" line.
            if machine not in self.peer_names and machine not in self.unknown_warned:
                self.unknown_warned.add(machine)
                log(
                    "roster from %r which is not among this daemon's configured peer "
                    "names %s; a remote session only materializes when a peers[].name "
                    "equals that machine's this_machine - check the config"
                    % (machine, sorted(self.peer_names))
                )
            present = {}
            for s in sessions:
                if not isinstance(s, dict):
                    continue  # tolerate a malformed/hostile roster entry
                sid = s.get("sessionId")
                if not sid:
                    continue
                if len(present) >= self.max_remotes:
                    log(
                        "roster from %s over cap %d; ignoring extra sessions"
                        % (machine, self.max_remotes)
                    )
                    break
                present[sid] = s
            # remove sessions that vanished from this machine's roster
            for (mkey, sid) in list(self.remotes.keys()):
                if mkey == machine and sid not in present:
                    self._remove_remote_locked((mkey, sid))
            # ensure a holder+descriptor for each present session
            template = self._template_descriptor_locked()
            for sid, s in present.items():
                key = (machine, sid)
                if key in self.remotes:
                    self._refresh_descriptor_locked(key, s)
                    continue
                if template is None:
                    continue  # no real local session to model yet; retry next tick
                self._create_remote_locked(key, s, template)

    # -- holder / descriptor lifecycle (must hold self.lock) ----------------
    def _template_descriptor_locked(self):
        best = None
        best_mtime = -1
        for d in read_local_sessions(self.sess_dir):
            if not d.get("pidDomain"):
                continue
            pid = d.get("pid")
            mtime = 0
            try:
                mtime = os.path.getmtime(
                    os.path.join(self.sess_dir, "%s.json" % pid)
                )
            except OSError:
                pass
            if mtime > best_mtime:
                best_mtime = mtime
                best = d
        return best

    def _foreign_descriptor(self, path):
        """True if path holds a descriptor that is NOT ours (missing our marker, or
        unparseable). Such a file must never be overwritten. Absent or marked-ours
        paths return False (safe to write)."""
        try:
            with open(path) as fh:
                d = json.load(fh)
        except FileNotFoundError:
            return False
        except Exception:
            return True  # garbled: do not assume it is ours
        if not isinstance(d, dict):
            return True
        return not d.get(MARK)

    def _create_remote_locked(self, key, sess, template):
        machine, sid = key
        name = (sess.get("name") or sid) + "@" + machine
        proxy = os.path.join(self.sock_dir, "pl-%s.sock" % uuid.uuid4().hex[:12])
        env = dict(os.environ)
        env["CREDO_PEER_LAN_CONFIG"] = config_path()
        proc = subprocess.Popen(
            [
                sys.executable,
                self.script,
                "holder",
                "--proxy",
                proxy,
                "--target-session",
                sid,
                "--peer-name",
                machine,
                "--this-machine",
                self.this_machine,
            ],
            env=env,
        )
        # wait briefly for the holder to bind its proxy socket
        for _ in range(40):
            if os.path.exists(proxy):
                break
            if proc.poll() is not None:
                log("holder for %s exited early (rc=%s)" % (name, proc.returncode))
                return
            time.sleep(0.05)
        desc_path = os.path.join(self.sess_dir, "%d.json" % proc.pid)
        if self._foreign_descriptor(desc_path):
            # pid reuse: a real local descriptor (one without our marker) already
            # occupies this pid path. Never clobber a file we do not own - kill the
            # holder we just spawned and skip this remote; the next roster retries.
            log(
                "remote %s skipped: holder pid %d collides with a real local descriptor"
                % (name, proc.pid)
            )
            if proc.poll() is None:
                try:
                    proc.terminate()
                    proc.wait(timeout=3)
                except Exception:
                    try:
                        proc.kill()
                    except OSError:
                        pass
            try:
                os.unlink(proxy)
            except OSError:
                pass
            return
        self._write_descriptor(desc_path, proc.pid, sid, name, machine, sess, template, proxy)
        self.remotes[key] = {
            "holder": proc,
            "proxy": proxy,
            "descriptor": desc_path,
            "pid": proc.pid,
        }
        log("remote up: %s -> holder pid %d, proxy %s" % (name, proc.pid, proxy))

    def _refresh_descriptor_locked(self, key, sess):
        rec = self.remotes.get(key)
        if not rec:
            return
        proc = rec["holder"]
        if proc.poll() is not None:
            # holder died: drop and let the next roster recreate it
            self._remove_remote_locked(key)
            return
        try:
            with open(rec["descriptor"]) as fh:
                d = json.load(fh)
        except Exception:
            return
        now_ms = int(time.time() * 1000)
        d["status"] = sess.get("status", d.get("status", "idle"))
        d["statusUpdatedAt"] = now_ms
        d["updatedAt"] = now_ms
        self._atomic_write(rec["descriptor"], d)

    def _write_descriptor(self, path, pid, sid, name, machine, sess, template, proxy):
        try:
            pstart = proc_start(pid)
        except Exception as exc:
            log("cannot read procStart for holder %d: %s" % (pid, exc))
            pstart = template.get("procStart", "")
        now_ms = int(time.time() * 1000)
        d = {
            "pid": pid,
            "sessionId": sid,
            "cwd": template.get("cwd", ""),
            "startedAt": now_ms,
            "procStart": pstart,
            "version": template.get("version", ""),
            "peerProtocol": template.get("peerProtocol", 1),
            "peerFeatures": template.get("peerFeatures", []),
            "kind": template.get("kind", "interactive"),
            "entrypoint": template.get("entrypoint", "cli"),
            "pidDomain": template.get("pidDomain", ""),
            "messagingSocketPath": proxy,
            "name": name,
            "nameSource": "credo-peer-lan",
            "nameSince": now_ms,
            "updatedAt": now_ms,
            "status": sess.get("status", "idle"),
            "statusUpdatedAt": now_ms,
            MARK: True,
            MARK_FROM: machine,
        }
        self._atomic_write(path, d)

    def _atomic_write(self, path, obj):
        tmp = "%s.credo-lan.%d.tmp" % (path, os.getpid())
        try:
            with open(tmp, "w") as fh:
                fh.write(json.dumps(obj))
            os.replace(tmp, path)
        except Exception as exc:
            log("descriptor write %s failed: %s" % (path, exc))
            try:
                os.unlink(tmp)
            except OSError:
                pass

    def _remove_remote(self, key):
        with self.lock:
            self._remove_remote_locked(key)

    def _remove_remote_locked(self, key):
        rec = self.remotes.pop(key, None)
        if not rec:
            return
        proc = rec.get("holder")
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass
            try:
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                except OSError:
                    pass
        for p in (rec.get("descriptor"), rec.get("proxy")):
            if p:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        log("remote removed: %s" % (key,))

    def _janitor_loop(self):
        while not self.stop.wait(self.roster_interval):
            now = time.monotonic()
            with self.lock:
                dead_machines = set()
                for machine, seen in self.machine_seen.items():
                    if now - seen > self.machine_timeout:
                        dead_machines.add(machine)
                for key in list(self.remotes.keys()):
                    machine, _sid = key
                    rec = self.remotes[key]
                    proc = rec.get("holder")
                    holder_dead = proc is not None and proc.poll() is not None
                    if machine in dead_machines or holder_dead:
                        self._remove_remote_locked(key)
                for machine in dead_machines:
                    self.machine_seen.pop(machine, None)

    def _cleanup_stale_descriptors(self):
        """Remove leftover credoPeerLan descriptors from a previous daemon run whose
        holder pid is no longer alive. Never touches anything without our marker."""
        try:
            names = os.listdir(self.sess_dir)
        except OSError:
            return
        for name in names:
            if not name.endswith(".json"):
                continue
            base = name[:-5]
            if not base.isdigit():
                continue
            path = os.path.join(self.sess_dir, name)
            if os.path.islink(path):
                continue
            try:
                with open(path) as fh:
                    d = json.load(fh)
            except Exception:
                continue
            if not isinstance(d, dict) or not d.get(MARK):
                continue
            if not pid_alive(base):
                try:
                    os.unlink(path)
                    log("pruned stale descriptor %s" % name)
                except OSError:
                    pass

    def _cleanup_stale_sockets(self):
        """Remove leftover proxy sockets in our sock dir that no live credoPeerLan
        descriptor points at (e.g. orphaned by a SIGKILLed previous daemon). Only
        touches our own 'pl-*.sock' naming, never anything we cannot attribute."""
        try:
            names = os.listdir(self.sock_dir)
        except OSError:
            return
        referenced = set()
        try:
            snames = os.listdir(self.sess_dir)
        except OSError:
            snames = []
        for sname in snames:
            if not sname.endswith(".json"):
                continue
            base = sname[:-5]
            if not base.isdigit():
                continue
            spath = os.path.join(self.sess_dir, sname)
            if os.path.islink(spath):
                continue
            try:
                with open(spath) as fh:
                    d = json.load(fh)
            except Exception:
                continue
            if not isinstance(d, dict) or not d.get(MARK):
                continue
            if not pid_alive(base):
                continue
            msp = d.get("messagingSocketPath")
            if msp:
                referenced.add(msp)
        for name in names:
            if not (name.startswith("pl-") and name.endswith(".sock")):
                continue
            path = os.path.join(self.sock_dir, name)
            if path in referenced:
                continue
            try:
                os.unlink(path)
                log("pruned stale proxy socket %s" % name)
            except OSError:
                pass


def run_daemon(_args):
    if disabled():
        log("disabled via CREDO_PEER_LAN; exiting")
        return 0
    cfg = load_config()
    if cfg is None:
        log("no config at %s; nothing to do (no-op)" % config_path())
        return 0
    daemon = Daemon(cfg)

    def _sig(_signo, _frame):
        daemon.shutdown()

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)
    try:
        daemon.start()
    except AlreadyRunning:
        return 0
    except Exception as exc:
        log("failed to start: %s" % exc)
        return 1
    try:
        while not daemon.stop.wait(1.0):
            pass
    finally:
        daemon.shutdown()
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="credo LAN peer relay")
    sub = parser.add_subparsers(dest="cmd")

    p_daemon = sub.add_parser("daemon", help="run the relay daemon (default)")
    p_daemon.set_defaults(func=run_daemon)

    p_holder = sub.add_parser("holder", help="internal: per-remote-session holder")
    p_holder.add_argument("--proxy", required=True)
    p_holder.add_argument("--target-session", required=True)
    p_holder.add_argument("--peer-name", required=True)
    p_holder.add_argument("--this-machine", default="")
    p_holder.set_defaults(func=run_holder)

    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        return run_daemon(args)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

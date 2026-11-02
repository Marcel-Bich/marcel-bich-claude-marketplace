"""credo_session_registry.py - one registry entry per Claude session, verified against the process tree.

A local connector (for example a remote-control app) must know which tmux pane belongs to
which agent session. This module keeps that mapping as small files and re-checks every entry
before it is trusted.

Layout (per profile: CLAUDE_CONFIG_DIR, else ~/.claude):
  <profile>/credo/session-registry/<session_id>.json   one file per session id, mode 0600

Entry keys (exactly these; no environment values, no secrets):
  session_id, harness ("claude"), name, host, pid, pid_start (/proc start time),
  mode (credo session mode or null), tmux (null or {socket, pane, session, owner_pid,
  owner_start}), updated (ISO time of the last change; a file is rewritten only on change).

Recording (hooks/credo-session-registry.sh): the session process is the first ancestor of
the hook whose session descriptor (<profile>/sessions/<pid>.json) names this session id and
carries the same start time. The pane is read from that process (or from the client TUI of
a background-daemon session) and kept only when the process tree confirms it: the pane's
process is the session process (or its client) or one of its ancestors, and no other Claude
process sits between them (credo-self-restart.py pane_owner_error / session_owner_check).

Verification (resolve, list): an entry is live only while its process keeps the recorded
start time, its descriptor still names the same session, and - when a pane is recorded - the
pane still exists on its server, is not dead and is still owned as at record time. Anything
else is stale, with the reason. A stale entry is never used for routing.

Pruning: SessionStart drops entries whose process is gone and whose file has not changed for
a day. Nothing else is ever deleted.

Reuse: process facts and the owner check from credo-self-restart.py, the pane lookup from
credo_pane_guard.py, the name fallback from credo_session_name.py, the mode from
credo_peer_meta.py, and the profile list and descriptor reader from credo-peer-check.py.
"""
import datetime
import glob
import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import credo_pane_guard as pane_guard  # noqa: E402
import credo_peer_meta as peer_meta  # noqa: E402
import credo_session_name as session_name  # noqa: E402


def _load(module_name, filename):
    """Import a credo script whose file name is not a Python identifier."""
    spec = importlib.util.spec_from_file_location(module_name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


restart = _load("credo_self_restart", "credo-self-restart.py")
peer_check = _load("credo_peer_check", "credo-peer-check.py")

REGISTRY_SUB = os.path.join("credo", "session-registry")
HARNESS = "claude"
PRUNE_AFTER = 24 * 3600
MAX_ENTRY_BYTES = 16384
PANE_RE = re.compile(r"%[0-9]{1,9}\Z")
NUM_RE = re.compile(r"[0-9]{1,20}\Z")


# --------------------------------------------------------------------------- profiles

def profile_dir():
    """The active profile: CLAUDE_CONFIG_DIR, else ~/.claude (real path)."""
    return os.path.realpath(os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"))


def profiles_to_read(all_profiles=False):
    """[active profile] or, with all_profiles, every profile peer-check knows (active first)."""
    if not all_profiles:
        return [profile_dir()]
    dirs = peer_check.profile_dirs()
    if profile_dir() not in dirs:
        dirs.insert(0, profile_dir())
    return dirs


def registry_dir(profile):
    return os.path.join(profile, REGISTRY_SUB)


def entry_path(profile, sid):
    return os.path.join(registry_dir(profile), sid + ".json")


def descriptor(profile, pid):
    """The Claude session descriptor of pid in this profile, or None."""
    return peer_check.read_json(os.path.join(profile, "sessions", "%d.json" % pid))


# --------------------------------------------------------------------------- files

def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def read_entry(path):
    """The entry dict of a regular, own, private file, else None (never follows a symlink)."""
    try:
        fd = session_name.open_own_file(path, private=True)
    except (OSError, session_name.UnsafeFile):
        return None
    chunks, total = [], 0
    try:
        while total <= MAX_ENTRY_BYTES:
            part = os.read(fd, MAX_ENTRY_BYTES + 1 - total)
            if not part:
                break
            chunks.append(part)
            total += len(part)
    except OSError:
        return None
    finally:
        os.close(fd)
    if total > MAX_ENTRY_BYTES:
        return None
    try:
        data = json.loads(b"".join(chunks).decode("utf-8"))
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def write_entry(path, data):
    """Atomic replace with mode 0600: a dot-file temp in the same directory, then rename."""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    tmp = os.path.join(directory, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(data, sort_keys=True) + "\n")
    os.replace(tmp, path)


def load_entries(profiles):
    """[(profile, session id from the file name, entry)] of every readable entry file."""
    out = []
    for prof in profiles:
        for path in sorted(glob.glob(os.path.join(registry_dir(prof), "*.json"))):
            entry = read_entry(path)
            if entry is not None:
                out.append((prof, os.path.basename(path)[:-len(".json")], entry))
    return out


# --------------------------------------------------------------------------- recording

def process_chain():
    """This process and its ancestors (the hook runs as a child of the session process)."""
    return restart.ancestors(os.getpid())


def find_agent(profile, sid, pids):
    """(pid, start, descriptor) of the first pid whose descriptor names sid with the same
    start time, else None."""
    for pid in pids:
        desc = descriptor(profile, pid)
        if not desc or desc.get("sessionId") != sid:
            continue
        start = restart.proc_start(pid)
        if not start:
            continue
        if desc.get("procStart") not in (None, "") and str(desc["procStart"]) != start:
            continue
        return pid, start, desc
    return None


def session_of_pane(pane, server):
    """tmux session name of a pane on the given server, cleaned for display, or ""."""
    try:
        res = subprocess.run(pane_guard.tmux_base(server) + ["display-message", "-p", "-t", pane,
                                                             "#{session_name}"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    if res.returncode != 0:
        return ""
    return session_name.clean(res.stdout, session_name.LABEL_MAX)


def pane_of(agent, start):
    """The tmux record of the session process, or None: no pane, a pane the process tree
    does not confirm, or a daemon link that fails closed."""
    link = restart.daemon_link(agent)
    if link.get("error"):
        return None
    env = restart.pane_env(agent, link, ["TMUX", "TMUX_PANE"]) or {}
    pane = env.get("TMUX_PANE", "")
    server = pane_guard.socket_from_tmux_env(env.get("TMUX", ""))
    if not PANE_RE.match(pane) or not server:
        return None
    owner = link.get("client") if link.get("daemon") else agent
    owner_start = restart.proc_start(owner) if owner else ""
    if not owner_start:
        return None
    check = restart.session_owner_check({"agent_pid": agent, "agent_start": start})
    if check(pane, server, owner, owner_start):
        return None
    return {"socket": server, "pane": pane, "session": session_of_pane(pane, server) or None,
            "owner_pid": owner, "owner_start": owner_start}


def display_name(desc, sid, tmux):
    """Caption, else tmux session, else short id (the shared credo name order, without kitty)."""
    label = tmux.get("session") if tmux else None
    return session_name.pick(session_name.claude_caption(desc), None, label, sid)


def build_entry(profile, sid, agent, start, desc):
    tmux = pane_of(agent, start)
    return {
        "session_id": sid,
        "name": display_name(desc, sid, tmux),
        "harness": HARNESS,
        "host": socket.gethostname(),
        "pid": agent,
        "pid_start": start,
        "mode": peer_meta.local_meta(sid, [profile]).get("mode"),
        "tmux": tmux,
    }


def record_session(profile, sid, pids):
    """Write or refresh the entry of session sid. True when the file changed. Nothing is
    written when no process of the chain is this session (fail closed)."""
    found = find_agent(profile, sid, pids)
    if found is None:
        return False
    agent, start, desc = found
    fresh = build_entry(profile, sid, agent, start, desc)
    path = entry_path(profile, sid)
    old = read_entry(path)
    if old is not None and {k: v for k, v in old.items() if k != "updated"} == fresh:
        return False
    fresh["updated"] = now_iso()
    write_entry(path, fresh)
    return True


def prune(profile, now=None):
    """Drop entries of gone processes that have not changed for PRUNE_AFTER seconds."""
    now = time.time() if now is None else now
    removed = []
    for path in sorted(glob.glob(os.path.join(registry_dir(profile), "*.json"))):
        entry = read_entry(path)
        if entry is None:
            continue
        pid = entry.get("pid")
        if isinstance(pid, int) and restart.alive(pid, str(entry.get("pid_start", ""))):
            continue
        try:
            age = now - os.lstat(path).st_mtime
        except OSError:
            continue
        if age >= PRUNE_AFTER:
            os.unlink(path)
            removed.append(path)
    return removed


# --------------------------------------------------------------------------- verification

def well_formed(file_sid, entry):
    """True when the entry has the shape record_session writes and names its own file."""
    if not isinstance(entry, dict) or entry.get("session_id") != file_sid:
        return False
    if not peer_meta.valid_sid(file_sid):
        return False
    pid, start = entry.get("pid"), entry.get("pid_start")
    if not (isinstance(pid, int) and not isinstance(pid, bool) and pid > 1):
        return False
    if not (isinstance(start, str) and NUM_RE.match(start)):
        return False
    tmux = entry.get("tmux")
    if tmux is None:
        return True
    if not isinstance(tmux, dict):
        return False
    return (isinstance(tmux.get("pane"), str) and PANE_RE.match(tmux["pane"]) is not None
            and isinstance(tmux.get("socket"), str) and tmux["socket"].startswith("/")
            and isinstance(tmux.get("owner_pid"), int)
            and isinstance(tmux.get("owner_start"), str) and NUM_RE.match(tmux["owner_start"]) is not None)


def verify(profile, file_sid, entry):
    """(status, reason) of an entry against the live process tree: "live" or "stale"."""
    if not well_formed(file_sid, entry):
        return "stale", "invalid entry"
    pid, start, sid = entry["pid"], entry["pid_start"], entry["session_id"]
    st = restart.read_stat(pid)
    if st is None or st[0] in ("Z", "X"):
        return "stale", "process %d is gone" % pid
    if not restart.alive(pid, start):
        return "stale", "pid %d was reused (start time differs)" % pid
    desc = descriptor(profile, pid)
    if desc is None:
        return "stale", "no session descriptor for pid %d" % pid
    if desc.get("sessionId") != sid:
        return "stale", "pid %d now runs another session" % pid
    tmux = entry.get("tmux")
    if not tmux:
        return "live", "no tmux pane recorded"
    info = pane_guard.pane_info(tmux["pane"], tmux["socket"])
    if info is None:
        return "stale", "tmux pane %s not found on its server" % tmux["pane"]
    if info["dead"]:
        return "stale", "tmux pane %s is dead" % tmux["pane"]
    check = restart.session_owner_check({"agent_pid": pid, "agent_start": start})
    error = check(tmux["pane"], tmux["socket"], tmux["owner_pid"], tmux["owner_start"])
    if error:
        return "stale", error
    return "live", "pane and process verified"


def verified_row(profile, file_sid, entry):
    """The entry plus profile, status and reason. A check that raises is stale, never live,
    and never stops a listing."""
    try:
        status, reason = verify(profile, file_sid, entry)
    except Exception as exc:  # noqa: BLE001 - one broken entry must not hide the others
        status, reason = "stale", "verification failed (%s)" % type(exc).__name__
    row = dict(entry)
    row.update(profile=profile, status=status, reason=reason)
    return row


def list_rows(profiles):
    """Every readable entry with status and reason, newest first."""
    rows = [verified_row(p, sid, e) for p, sid, e in load_entries(profiles)]
    rows.sort(key=lambda r: (str(r.get("updated") or ""), str(r.get("session_id"))), reverse=True)
    return rows


def resolve(profiles, query):
    """Match a session id (exact) or a name (case-insensitive, as credo names compare) and
    verify it. Several matches resolve only when exactly one of them is live (a stale leftover
    with the same name must not hide the live session). status is live, stale, not-found or
    ambiguous."""
    entries = load_entries(profiles)
    hits = [h for h in entries if h[1] == query]
    if not hits and query:
        key = session_name.caption_key(query)
        if key:
            hits = [h for h in entries if isinstance(h[2].get("name"), str)
                    and session_name.caption_key(h[2]["name"]) == key]
    result = {"query": query, "status": "not-found", "reason": "no session with this id or name",
              "entry": None, "candidates": []}
    if not hits:
        return result
    rows = [verified_row(prof, sid, entry) for prof, sid, entry in hits]
    if len(rows) > 1:
        live = [r for r in rows if r["status"] == "live"]
        if len(live) != 1:
            result.update(status="ambiguous",
                          reason="%d sessions match, %d live; use the session id" % (len(rows), len(live)),
                          candidates=[{"session_id": r["session_id"], "name": r.get("name"),
                                       "profile": r["profile"], "status": r["status"]} for r in rows])
            return result
        rows = live
    row = rows[0]
    result.update(status=row["status"], reason=row["reason"], entry=row)
    return result

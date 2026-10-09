"""credo_peer_meta.py - small, validated per-session metadata of credo peers.

An orchestrating session wants to know at a glance which peer does what: its credo
session mode (active / passive / autonomous), its credo role (task / plan), the model
and effort level it runs with, whether credo is accepted in its directory, and its
project (basename of the working directory). This module reads that metadata from the
local credo state and validates every value against a strict whitelist.

INFORMATIONAL ONLY. Metadata never grants trust, approval or permissions, never
reaches a message envelope and never changes a routing decision. A peer may publish
any value it likes (a LAN relay roster is sender-controlled), so every reader passes
it through clean(): enums for mode / role / effort / credo / status, a short strict
charset for model and project (model brackets only as one trailing context suffix
such as "[1m]"), unknown keys dropped. Anything else is shown as "-".

State read per session id (all written by credo's own hooks, see the setters):
  <profile>/credo/session-modes/<sid>      one word (hooks/session-mode-set.sh)
  <profile>/credo/session-roles/<sid>      one word (hooks/role-set.sh)
  <profile>/credo/session-meta/<sid>.json  {"model", "effort", "credo"}
                                           (hooks/credo-peer-meta-record.sh)
CREDO_SESSION_MODES_DIR / CREDO_SESSION_ROLES_DIR / CREDO_SESSION_META_DIR override
the first candidate dir, the same way the setters and injectors honor them.
"""
import json
import os
import re
import stat

MODES = ("active", "passive", "autonomous")
ROLES = ("task", "plan")
EFFORTS = ("low", "medium", "high", "xhigh", "max")
CREDO = ("on", "off")
FIELDS = ("mode", "role", "model", "effort", "credo", "project", "status")
# a model id, optionally with ONE trailing context suffix such as "[1m]"; brackets
# anywhere else (marker-like tokens such as "x[urgent]") are rejected
MODEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}(\[[0-9]{1,4}[km]\])?\Z")
PROJECT_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._-]{0,63}\Z")
# descriptor status values written by the harness (others are shown as "-")
STATUSES = ("idle", "busy", "waiting")
SID_RE = re.compile(r"[A-Za-z0-9._-]{1,128}\Z")
MAX_STATE_BYTES = 4096

_ENUMS = {"mode": MODES, "role": ROLES, "effort": EFFORTS, "credo": CREDO, "status": STATUSES}
_PATTERNS = {"model": MODEL_RE, "project": PROJECT_RE}


def valid(key, value):
    if not isinstance(value, str):
        return False
    if key in _ENUMS:
        return value in _ENUMS[key]
    pat = _PATTERNS.get(key)
    return bool(pat and pat.match(value))


def clean(meta, fields=FIELDS):
    """Only the whitelisted keys whose values pass validation; {} for anything that
    is not a dict. Values are never rewritten (an invalid one is dropped)."""
    if not isinstance(meta, dict):
        return {}
    return {k: meta[k] for k in fields if valid(k, meta.get(k))}


def fmt(meta):
    """'mode=X role=Y model=Z effort=E credo=C project=P status=S', '-' when unknown."""
    meta = clean(meta)
    return " ".join("%s=%s" % (k, meta.get(k, "-")) for k in FIELDS)


def valid_sid(sid):
    return (isinstance(sid, str) and bool(SID_RE.match(sid)) and sid not in (".", "..")
            and ".." not in sid)


def project_of(cwd):
    if not isinstance(cwd, str) or not cwd:
        return None
    name = os.path.basename(cwd.rstrip("/"))
    return name if valid("project", name) else None


def _read_small(path):
    """Text of a small regular file (no symlink, no fifo), or None."""
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_STATE_BYTES:
            return None
        with open(path) as fh:
            return fh.read(MAX_STATE_BYTES)
    except (OSError, UnicodeDecodeError):
        return None


def _dirs(profiles, sub, env):
    out = []
    o = os.environ.get(env)
    if o:
        out.append(o)
    for prof in profiles:
        if isinstance(prof, str) and prof:
            out.append(os.path.join(prof, "credo", sub))
    return out


def local_meta(sid, profiles, cwd=None):
    """Metadata of local session sid from the credo state of the given profile dirs
    (first hit per field wins), plus project from cwd. {} for an invalid sid."""
    if not valid_sid(sid):
        return {}
    meta = {}
    for key, sub, env in (("mode", "session-modes", "CREDO_SESSION_MODES_DIR"),
                          ("role", "session-roles", "CREDO_SESSION_ROLES_DIR")):
        for d in _dirs(profiles, sub, env):
            text = _read_small(os.path.join(d, sid))
            if text is not None:
                val = text.strip()
                if valid(key, val):
                    meta[key] = val
                break
    for d in _dirs(profiles, "session-meta", "CREDO_SESSION_META_DIR"):
        text = _read_small(os.path.join(d, sid + ".json"))
        if text is None:
            continue
        try:
            rec = json.loads(text)
        except ValueError:
            rec = None
        for k, v in clean(rec, ("model", "effort", "credo")).items():
            meta[k] = v
        break
    proj = project_of(cwd)
    if proj:
        meta["project"] = proj
    return meta

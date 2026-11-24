"""credo_cleanup_lib.py - shared code of the provenance ledger (credo-ledger.py, the hooks)
and the cleanup helper (credo-cleanup.py).

Idea: in doubt, report, never delete. Hooks record per session what each tool call created (a
PreToolUse time mark, then every entry born after it in the watched roots via statx birth time,
and a file or topmost new directory a Write/Edit call created). Subagents share the session id.
The ledger is a report: the helper deletes without a prompt only inside the session TMPDIR and
scratchpad (named by a session id bound to the caller's process tree), single files a successful
Write/Edit call of the session created in a temp dir (exact transcript match), and known
build-output dirs of a hydra worktree the session created; every delete re-checks
the whole tree (birth times, modification times, mounts, repositories, processes, idle time) and
refuses a hard denylist. No path or switch of this code comes from the environment (the home is
read from the password database); tests set OVERRIDES through their own shim.

Layout (all local, never versioned):
  state dir   ~/.local/state/credo/cleanup
    ledger/<session_id>.jsonl   append-only records and events (removed, moved)
    marks/<session_id>/<t0>_<tool_use_id>   time marks of running tool calls
    windows.log                 closed tool-call windows of all sessions (ambiguity check)
    jobs/                       background scan jobs
    cleanup.log                 every removal, refusal and failure
    stamps/                     once-per-day / once-per-hour markers
  keep dir    ~/.local/share/credo/keep  (keep-list.json inside)
  session tmp /tmp/credo-tmp-<uid> (private, 0700); one dir per session id (a UUID)

Everything here fails soft: callers catch exceptions; a hook never blocks on an error.

Native Windows (NT, a real CPython under Git Bash; stdlib + ctypes only). Same rules, Windows
facts: the home and the temp dirs come from the known-folder API (never from the environment);
the session tmp base is <LocalAppData>\\Temp\\credo-tmp, the scratchpads live in
<LocalAppData>\\Temp\\claude; birth time is the NTFS creation time (st_birthtime), device+inode
the volume serial + file id (os.lstat, never a cached DirEntry, whose ids are 0 there); "owned by
this user" is the owner SID of the object, "private" additionally a location inside the user's
LocalAppData (per-user ACL). Paths compare case-insensitively (normcase). Only local fixed
NTFS/ReFS volumes count; anything else (network share, UNC, removable, FAT) is report-only. A
junction, symlink or any other reparse point is never followed, never recursed into and never
deleted: a tree that holds one is report-only. There is no equally strong Windows equivalent of
the open-file and cwd check of other processes (/proc), so every delete that needs it (own-rm,
purge, sweep) is report-only on Windows; the delete itself works on handles opened without
following reparse points, pins every directory on the way (no FILE_SHARE_DELETE, so nothing can
be renamed or swapped meanwhile) and re-checks volume serial + file id before it marks an object
for deletion.
"""
import ctypes
import ctypes.util
import glob
import json
import ntpath
import os
import re
import stat
import subprocess
import sys
import time

# pwd is POSIX only; importing this file must never crash on a native Windows Python.
try:
    import pwd
except ImportError:
    pwd = None

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import credo_lock  # noqa: E402
import credo_platform  # noqa: E402

# Windows code paths; the nt-simulation tests flip this (with the ctypes helpers patched)
NT = credo_platform.IS_NT

# Claude Code session ids are UUIDs; nothing else is accepted, so an id can never name or escape
# a directory (no "..", no "/", no ordinary folder names)
SID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# Test-only configuration. Runtime code never reads paths or switches of the cleanup from the
# environment (an env prefix on a helper call must not widen what it may delete). The test suite
# fills this dict through a shim it generates in its own fixture dir; nothing else sets it.
OVERRIDES = {}


def ov(key, default=None):
    return OVERRIDES.get(key, default)


# --------------------------------------------------------------------------- paths


def home():
    """The user's home from the password database (not $HOME, which a command can prefix);
    on Windows from the known-folder API (not %USERPROFILE%)."""
    h = ov("home")
    if not h and NT:
        h = nt_known_folder("profile")
    if not h:
        try:
            h = pwd.getpwuid(os.getuid()).pw_dir
        except (KeyError, AttributeError):
            h = os.path.expanduser("~")
    return os.path.realpath(h)


def state_dir():
    return os.path.realpath(ov("state") or os.path.join(home(), ".local", "state", "credo", "cleanup"))


def keep_root():
    return os.path.realpath(ov("keep_root") or os.path.join(home(), ".local", "share", "credo", "keep"))


def keep_list_path():
    return os.path.join(keep_root(), "keep-list.json")


def tmp_base():
    """The session tmp base (absolute, NOT resolved: private_dir checks it is no symlink)."""
    if ov("tmp_base"):
        return os.path.abspath(ov("tmp_base"))
    if NT:
        return os.path.join(nt_temp_dir(), "credo-tmp")
    return os.path.abspath("/tmp/credo-tmp-%d" % os.getuid())


def scratch_base():
    if ov("scratch_base"):
        return os.path.abspath(ov("scratch_base"))
    if NT:
        return os.path.join(nt_temp_dir(), "claude")
    return os.path.abspath("/tmp/claude-%d" % os.getuid())


def session_tmp(sid):
    return os.path.join(tmp_base(), sid)


def valid_sid(sid):
    return bool(sid) and bool(SID_RE.match(sid))


def private_dir(path, mode_0700=True):
    """True when path (not resolved) is a real directory of this user, no symlink, and (with
    mode_0700) not accessible to anybody else. Windows: no reparse point, owner SID is this
    user, and with mode_0700 inside the user's LocalAppData (per-user ACL)."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if NT:
        if not stat.S_ISDIR(st.st_mode) or is_reparse(st) or stat.S_ISLNK(st.st_mode):
            return False
        if mode_0700 and not nt_private_location(path):
            return False
        if not nt_owner_is_me(path):
            return False
        return norm(os.path.realpath(path)) == norm(path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        return False
    if mode_0700 and stat.S_IMODE(st.st_mode) & 0o077:
        return False
    return os.path.realpath(path) == path


def ledger_path(sid):
    return os.path.join(state_dir(), "ledger", sid + ".jsonl")


def log_path():
    return os.path.join(state_dir(), "cleanup.log")


def ensure_dir(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=True)


def now():
    return time.time()


def iso(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts if ts is not None else now()))


def log(msg):
    try:
        ensure_dir(state_dir())
        with open(log_path(), "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (iso(), msg.replace("\n", " ")))
    except OSError:
        pass


# --------------------------------------------------------------------------- Windows facts

FA_SYSTEM = 0x4
FA_REPARSE_POINT = 0x400
FA_OFFLINE = 0x1000
FA_RECALL_ON_OPEN = 0x40000
FA_RECALL_ON_DATA_ACCESS = 0x400000
_NT_SPECIAL = FA_SYSTEM | FA_OFFLINE | FA_RECALL_ON_OPEN | FA_RECALL_ON_DATA_ACCESS
_SEPS = "\\/"

_KNOWN_FOLDERS = {  # FOLDERID_* GUIDs (KnownFolders.h)
    "profile": "5E6C858F-0E22-4760-9AFE-EA3317B67173",
    "local_appdata": "F1B32785-6FBA-4FCF-9D55-7B8E7F157091",
    "roaming_appdata": "3EB685DB-65F9-4CF6-A03A-E3EF65729F3D",
    "windows": "F38BF404-1D43-42F2-9305-67DE0B28FC23",
    "program_files": "905E63B6-C1BF-494E-B29C-65B732D3D21A",
    "program_files_x86": "7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E",
    "program_data": "62AB5D82-FDC1-4DC3-A9DD-070D1D495D97",
    "user_profiles": "0762D272-C50A-4BB0-A382-697DCD729B80",
}
_KF_CACHE = {}


def norm(p):
    """Comparison form of a path: Windows case-insensitive (normcase), POSIX unchanged."""
    if NT:
        return os.path.normcase(os.path.normpath(p))
    return p


def strip_sep(p):
    """p without trailing separators (a root keeps its own form)."""
    q = p.rstrip(_SEPS if NT else "/")
    return q or p


def same_path(a, b):
    return norm(a) == norm(b) if NT else a == b


def attrs(st):
    return getattr(st, "st_file_attributes", 0) or 0


def is_reparse(st):
    """A junction, symlink, mount point, cloud placeholder, AF_UNIX socket or any other
    reparse point (Windows attribute; a POSIX symlink is S_ISLNK, not this)."""
    return bool(attrs(st) & FA_REPARSE_POINT)


def link_like(path):
    """A symlink, or on Windows any reparse point (a junction is no symlink to islink)."""
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISLNK(st.st_mode) or (NT and is_reparse(st))


def lstat_entry(de):
    """lstat of a scandir entry. Windows: a fresh os.lstat, since a DirEntry's cached stat
    has st_dev = st_ino = 0 there."""
    if NT:
        return os.lstat(de.path)
    return de.stat(follow_symlinks=False)


def owned_by_me(path, st):
    if NT:
        return nt_owner_is_me(path)
    return st.st_uid == os.getuid()


def nt_known_folder(name):
    """Path of a Windows known folder (SHGetKnownFolderPath), independent of the environment.
    Raises OSError when unknown (callers fail closed)."""
    if ov("nt_folders") and name in ov("nt_folders"):
        return ov("nt_folders")[name]
    if name in _KF_CACHE:
        return _KF_CACHE[name]
    import uuid
    from ctypes import wintypes
    guid = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID(_KNOWN_FOLDERS[name]).bytes_le)
    shell32 = ctypes.WinDLL("shell32")
    ole32 = ctypes.WinDLL("ole32")
    shell32.SHGetKnownFolderPath.argtypes = (ctypes.c_void_p, wintypes.DWORD, wintypes.HANDLE,
                                             ctypes.POINTER(ctypes.c_wchar_p))
    shell32.SHGetKnownFolderPath.restype = ctypes.c_long
    ole32.CoTaskMemFree.argtypes = (ctypes.c_void_p,)
    out = ctypes.c_wchar_p()
    hr = shell32.SHGetKnownFolderPath(ctypes.byref(guid), 0, None, ctypes.byref(out))
    try:
        if hr != 0 or not out.value:
            raise OSError("known folder %s unavailable (0x%x)" % (name, hr & 0xFFFFFFFF))
        _KF_CACHE[name] = out.value
    finally:
        if out:
            ole32.CoTaskMemFree(out)
    return _KF_CACHE[name]


def nt_temp_dir():
    """<LocalAppData>\\Temp, the per-user temp dir (not %TEMP%, which a command can prefix)."""
    return os.path.join(nt_known_folder("local_appdata"), "Temp")


def nt_private_location(path):
    """Windows stand-in for mode 0700: below the user's LocalAppData, whose default ACL grants
    only this user, SYSTEM and administrators access."""
    try:
        la = nt_known_folder("local_appdata")
    except OSError:
        return False
    return is_under(path, la) and not same_path(path, la)


def nt_owner_is_me(path):
    """True when the owner SID of path (not followed) is this process's user SID, or the
    default owner SID of its access token (what this process itself would own). Any error ->
    False."""
    if ov("nt_owner_is_me") is not None:
        return bool(ov("nt_owner_is_me"))
    try:
        from ctypes import wintypes
        advapi = ctypes.WinDLL("advapi32", use_last_error=True)
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        advapi.GetNamedSecurityInfoW.argtypes = (
            wintypes.LPCWSTR, ctypes.c_int, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p))
        advapi.GetNamedSecurityInfoW.restype = wintypes.DWORD
        advapi.OpenProcessToken.argtypes = (wintypes.HANDLE, wintypes.DWORD,
                                            ctypes.POINTER(wintypes.HANDLE))
        advapi.GetTokenInformation.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                               wintypes.DWORD, ctypes.POINTER(wintypes.DWORD))
        advapi.EqualSid.argtypes = (ctypes.c_void_p, ctypes.c_void_p)
        advapi.IsValidSid.argtypes = (ctypes.c_void_p,)
        k32.GetCurrentProcess.restype = wintypes.HANDLE
        k32.CloseHandle.argtypes = (wintypes.HANDLE,)
        k32.LocalFree.argtypes = (ctypes.c_void_p,)
        owner, sd = ctypes.c_void_p(), ctypes.c_void_p()
        # SE_FILE_OBJECT = 1, OWNER_SECURITY_INFORMATION = 1; a reparse point is not followed
        # only when opened as such, so callers have already refused reparse points
        if advapi.GetNamedSecurityInfoW(path, 1, 1, ctypes.byref(owner), None, None, None,
                                        ctypes.byref(sd)) != 0:
            return False
        try:
            tok = wintypes.HANDLE()
            if not advapi.OpenProcessToken(k32.GetCurrentProcess(), 0x0008, ctypes.byref(tok)):
                return False
            try:
                if not owner.value or not advapi.IsValidSid(owner):
                    return False
                # TokenUser (1): this user; TokenOwner (4): the default owner of what this
                # process creates (an elevated admin process creates objects owned by the
                # Administrators group, as root on Linux owns what it creates)
                for cls in (1, 4):
                    need = wintypes.DWORD(0)
                    advapi.GetTokenInformation(tok, cls, None, 0, ctypes.byref(need))
                    buf = ctypes.create_string_buffer(max(need.value, 64))
                    if not advapi.GetTokenInformation(tok, cls, buf, len(buf), ctypes.byref(need)):
                        continue
                    sid = ctypes.c_void_p.from_buffer(buf).value  # first field: the PSID
                    if sid and advapi.EqualSid(owner, ctypes.c_void_p(sid)):
                        return True
                return False
            finally:
                k32.CloseHandle(tok)
        finally:
            k32.LocalFree(sd)
    except (OSError, AttributeError, ValueError):
        return False


def nt_volume_refusal(p):
    """Reason when p is not on a local fixed NTFS/ReFS volume (drive letter path), else None.
    Network shares, UNC and device paths, removable media and file systems without stable file
    ids (FAT, exFAT) are report-only on Windows."""
    if ov("nt_volume_ok") is not None:
        return None if ov("nt_volume_ok") else "not a local fixed NTFS/ReFS volume (test)"
    drive, _ = ntpath.splitdrive(os.path.abspath(p))
    if len(drive) != 2 or drive[1] != ":":
        return "not on a local drive letter (UNC, network or device path): report only on Windows"
    root = drive + "\\"
    try:
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.GetDriveTypeW.argtypes = (wintypes.LPCWSTR,)
        k32.GetVolumeInformationW.argtypes = (
            wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
            ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD), wintypes.LPWSTR,
            wintypes.DWORD)
        if k32.GetDriveTypeW(root) != 3:  # DRIVE_FIXED
            return "%s is no local fixed drive (network, removable or absent): report only" % drive
        fs = ctypes.create_unicode_buffer(64)
        if not k32.GetVolumeInformationW(root, None, 0, None, None, None, fs, 64):
            return "%s: volume information unreadable: report only" % drive
        if fs.value not in ("NTFS", "ReFS"):
            return "%s is %s, not NTFS/ReFS (no stable file ids): report only" % (drive, fs.value)
    except (OSError, AttributeError, ValueError):
        return "volume of %s unknown: report only" % drive
    return None


def nt_system_refusal(p):
    """Windows counterpart of SYSTEM_DENY: drive roots and their first level, the Windows,
    Program Files and ProgramData trees, and the per-user AppData / temp roots themselves."""
    drive, rest = ntpath.splitdrive(os.path.abspath(p))
    if len([c for c in rest.split(os.sep) if c]) <= 1:
        return "system or root-level path"
    for name in ("windows", "program_files", "program_files_x86", "program_data"):
        try:
            root = nt_known_folder(name)
        except (OSError, KeyError):
            continue
        if is_under(p, root) or is_under(root, p):
            return "system path (%s)" % root
    try:
        la = nt_known_folder("local_appdata")
        roots = [la, os.path.dirname(la), nt_known_folder("roaming_appdata"), nt_temp_dir()]
    except OSError:
        return "known folders unavailable: report only"
    for root in roots:
        if is_under(root, p):
            return "a per-user AppData or temp root, or one of its parents"
    return None


# --------------------------------------------------------------------------- statx

_STATX_BTIME = 0x800
_AT_FDCWD = -100
_AT_SYMLINK_NOFOLLOW = 0x100
_libc = None
_statx_ok = None


def _statx_fn():
    global _libc, _statx_ok
    if _statx_ok is None:
        _statx_ok = False
        if ov("no_btime"):
            return None
        try:
            _libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
            _libc.statx  # noqa: B018 - attribute lookup raises when glibc has no statx
            _statx_ok = True
        except (OSError, AttributeError):
            _statx_ok = False
    return _libc.statx if _statx_ok else None


def birth_of(st):
    """Birth time from a Windows stat result: st_birthtime (Python 3.12+), else st_ctime, which
    is the creation time on Windows before 3.12. None when unknown."""
    bt = getattr(st, "st_birthtime", None)
    if bt is None and NT:
        bt = st.st_ctime
    return bt if bt and bt > 0 else None


def birth_time(path, dir_fd=None):
    """Birth time of path (relative to dir_fd when given; no symlink follow) in seconds, or None
    when unknown. Windows: the NTFS creation time of the object itself (os.lstat)."""
    if NT:
        if ov("no_btime"):
            return None
        try:
            return birth_of(os.lstat(path))
        except OSError:
            return None
    fn = _statx_fn()
    if fn is None:
        return None
    buf = ctypes.create_string_buffer(256)
    rc = fn(_AT_FDCWD if dir_fd is None else dir_fd, os.fsencode(path), _AT_SYMLINK_NOFOLLOW,
            _STATX_BTIME, buf)
    if rc != 0:
        return None
    mask = int.from_bytes(buf.raw[0:4], "little")
    if not mask & _STATX_BTIME:
        return None
    sec = int.from_bytes(buf.raw[80:88], "little", signed=True)
    nsec = int.from_bytes(buf.raw[88:92], "little")
    if sec <= 0:
        return None
    return sec + nsec / 1e9


def kind_of(st):
    if NT and is_reparse(st) and not stat.S_ISLNK(st.st_mode):
        return "reparse"
    if stat.S_ISLNK(st.st_mode):
        return "link"
    if stat.S_ISDIR(st.st_mode):
        return "dir"
    if stat.S_ISREG(st.st_mode):
        return "file"
    return "other"


# --------------------------------------------------------------------------- ledger


class Locked:
    """Exclusive lock (credo_lock: flock / msvcrt) on <file>.lock for a with block."""

    def __init__(self, path):
        self.path = path + ".lock"
        self.fh = None

    def __enter__(self):
        ensure_dir(os.path.dirname(self.path))
        self.fh = open(self.path, "a")
        credo_lock.lock(self.fh)
        return self

    def __exit__(self, *exc):
        try:
            credo_lock.unlock(self.fh)
        finally:
            self.fh.close()


def append_ledger(sid, records):
    if not records:
        return
    path = ledger_path(sid)
    ensure_dir(os.path.dirname(path))
    with Locked(path):
        with open(path, "a", encoding="utf-8") as fh:
            for r in records:
                fh.write(json.dumps(r, sort_keys=True) + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def load_ledger(sid):
    """Replay the ledger: {path: entry} of the entries that are still owned (not removed)."""
    entries = {}
    path = ledger_path(sid)
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return entries
    with fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            ev = r.get("event", "record")
            p = r.get("path")
            if not isinstance(p, str):
                continue
            if ev == "record":
                old = entries.get(p)
                # keep the first record of a path while its inode is unchanged (evidence may grow)
                if old and old.get("ino") == r.get("ino") and old.get("dev") == r.get("dev"):
                    if old.get("evidence") == "window" and r.get("evidence") != "window":
                        old["evidence"] = r.get("evidence")
                    continue
                entries[p] = r
            elif ev == "removed":
                entries.pop(p, None)
            elif ev == "moved":
                old = entries.pop(p, None)
                to = r.get("to")
                if old is not None and isinstance(to, str):
                    new = dict(old)
                    new.update({"path": to, "dev": r.get("dev"), "ino": r.get("ino"), "kept": True})
                    entries[to] = new
    return entries


def make_record(path, st, tool, evidence, kind, agent_id=None, ambiguous=None, btime=None):
    r = {
        "event": "record",
        "path": path,
        "dev": st.st_dev,
        "ino": st.st_ino,
        "type": kind_of(st),
        "btime": round(btime, 3) if btime else None,
        "ctime": round(st.st_ctime, 3),
        "tool": tool,
        "evidence": evidence,
        "root_kind": kind,
        "ts": iso(),
    }
    if r["type"] == "file":
        r["size"] = st.st_size
    if agent_id:
        r["agent_id"] = agent_id
    if ambiguous:
        r["ambiguous"] = sorted(ambiguous)
    return r


# --------------------------------------------------------------------------- sessions


def trusted_config_dir():
    """$CLAUDE_CONFIG_DIR only when it is a real directory of this user directly in the
    password-database home, named .claude*, and no symlink; else None (ignored)."""
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if not cfg:
        return None
    p = os.path.abspath(os.path.expanduser(cfg))
    if os.path.dirname(p) != home() or not os.path.basename(p).startswith(".claude"):
        return None
    return p if private_dir(p, mode_0700=False) else None


def profile_dirs():
    """Profile dirs used to bind a session id and to find its transcripts: ~/.claude* of the
    password-database home (plus a trusted $CLAUDE_CONFIG_DIR, see trusted_config_dir)."""
    dirs = set()
    cfg = trusted_config_dir()
    if cfg:
        dirs.add(cfg)
    for d in glob.glob(os.path.join(glob.escape(home()), ".claude*")):
        if private_dir(d, mode_0700=False):  # a real dir, no symlink to somewhere else
            dirs.add(d)
    if ov("profiles") is not None:  # tests: only these
        dirs = {os.path.realpath(p) for p in ov("profiles")}
    return sorted(dirs)


def pid_alive(pid):
    if os.name == "nt":  # os.kill(pid, 0) would send CTRL_C_EVENT there
        return credo_platform.pid_alive(pid)
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (ValueError, TypeError, OSError):
        return False


def ancestor_pids():
    if NT:
        return set(credo_platform.ancestors(os.getpid()))
    pids, pid = [], os.getpid()
    for _ in range(64):
        pids.append(pid)
        try:
            with open("/proc/%d/stat" % pid, encoding="utf-8", errors="replace") as fh:
                pid = int(fh.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
        if pid <= 1:
            break
    return set(pids)


def sid_bound(sid):
    """(bound, reason): the session id belongs to the process tree of the caller - a live session
    descriptor (<profile>/sessions/<pid>.json) names it with a pid among the caller's ancestors.
    A live descriptor of that id with another pid (someone else's session) or no descriptor at
    all means not bound: the caller only gets reports."""
    mine = ancestor_pids()
    found_other = None
    for prof in profile_dirs():
        for f in glob.glob(os.path.join(glob.escape(prof), "sessions", "*.json")):
            try:
                with open(f, encoding="utf-8") as fh:
                    d = json.load(fh)
                pid = int(d.get("pid") or os.path.basename(f)[:-5])
            except (OSError, ValueError, TypeError):
                continue
            if d.get("sessionId") != sid:
                continue
            if NT and pid in mine and str(d.get("procStart") or "") != credo_platform.proc_start(pid):
                continue  # Windows reuses pids: the descriptor must carry this process's start
            if pid in mine:
                return True, None
            if pid_alive(pid):
                found_other = pid
    if found_other:
        return False, "session %s is alive in another process tree (pid %d)" % (sid, found_other)
    return False, "session id cannot be bound to the calling process tree"


def running_sessions():
    """Session ids with a live process descriptor (<profile>/sessions/<pid>.json)."""
    live = set()
    for prof in profile_dirs():
        for f in glob.glob(os.path.join(prof, "sessions", "*.json")):
            try:
                with open(f, encoding="utf-8") as fh:
                    d = json.load(fh)
            except (OSError, ValueError):
                continue
            sid = d.get("sessionId")
            pid = d.get("pid") or os.path.basename(f)[:-5]
            if sid and pid_alive(pid):
                live.add(sid)
    return live


# --------------------------------------------------------------------------- config


def local_config(timeout=3):
    """The cleanup block of the LOCAL config only (global + profile layer, never the project
    layer, which may be versioned). None when it cannot be read within timeout seconds: callers
    then skip what needs it (no TMPDIR export; own-rm refuses, since the keep list is unknown)."""
    script = os.path.join(HERE, "credo-config.sh")
    env = dict(os.environ)
    env["CREDO_PROJECT"] = os.path.join(state_dir(), "no-project-layer")
    env["CREDO_SKIP_ENSURE"] = "1"
    env.setdefault("CLAUDE_PLUGIN_ROOT", os.path.dirname(HERE))
    try:
        out = subprocess.run([credo_platform.bash_exe(), script, "get", "cleanup"], env=env, capture_output=True,
                             text=True, timeout=timeout)
        if out.returncode == 0:
            val = json.loads(out.stdout or "{}")
            return val if isinstance(val, dict) else {}
        if out.returncode == 3:  # key absent: defaults
            return {}
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None


# --------------------------------------------------------------------------- path rules


def is_under(path, root):
    if NT:
        a, b = strip_sep(norm(path)), strip_sep(norm(root))
        return a == b or a.startswith(b.rstrip(_SEPS) + os.sep)
    return path == root or path.startswith(root.rstrip("/") + "/")


def real_target(path):
    """Absolute path with the parent resolved and the last component kept (never follows a
    symlink at the target itself)."""
    ab = os.path.abspath(os.path.expanduser(path))
    parent, name = os.path.split(ab)
    if name in ("", ".", ".."):
        return None
    return os.path.join(os.path.realpath(parent), name)


def git_top(path):
    """(top, is_linked_worktree) of the nearest git work tree containing path, or (None, False)."""
    d = path if os.path.isdir(path) and not os.path.islink(path) else os.path.dirname(path)
    while True:
        g = os.path.join(d, ".git")
        if os.path.lexists(g):
            return d, os.path.isfile(g)
        nd = os.path.dirname(d)
        if nd == d:
            return None, False
        d = nd


def main_checkout_of(worktree):
    """Main checkout of a linked worktree (its .git is a file), else None."""
    try:
        with open(os.path.join(worktree, ".git"), encoding="utf-8") as fh:
            line = fh.readline().strip()
    except OSError:
        return None
    if not line.startswith("gitdir:"):
        return None
    gd = line[7:].strip()
    if not os.path.isabs(gd):
        gd = os.path.join(worktree, gd)
    gd = os.path.realpath(gd)
    # <common>/worktrees/<id>
    common = os.path.dirname(os.path.dirname(gd))
    if os.path.basename(common) == ".git":
        return os.path.dirname(common)
    return None


def claude_profile_roots():
    """Every Claude profile dir: ~/.claude* (also when it is a symlink, both forms) and
    $CLAUDE_CONFIG_DIR. Nothing below them is ever recorded or deleted by the cleanup."""
    roots = set()
    for base in {home(), os.path.expanduser("~")}:
        for prof in glob.glob(os.path.join(base, ".claude*")):
            roots.add(prof)
            roots.add(os.path.realpath(prof))
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    if cfg:
        roots.add(os.path.abspath(os.path.expanduser(cfg)))
        roots.add(os.path.realpath(os.path.expanduser(cfg)))
    return roots


def in_claude_profile(p):
    h = home()
    if NT:
        if is_under(p, h) and not same_path(p, h) and \
                norm(os.path.relpath(p, h)).split(os.sep)[0].startswith(".claude"):
            return True
        return any(is_under(p, r) for r in claude_profile_roots())
    if is_under(p, h) and p != h and os.path.relpath(p, h).split("/")[0].startswith(".claude"):
        return True
    return any(is_under(p, r) for r in claude_profile_roots())


_MOUNTS = None


def mount_points():
    """All mount points from /proc/self/mountinfo (same-device bind mounts included). Windows:
    none listed; volume mount points are reparse points, refused wherever they are met."""
    global _MOUNTS
    if NT:
        return set()
    if _MOUNTS is None:
        mounts = set()
        try:
            src = ov("mountinfo") or "/proc/self/mountinfo"
            with open(src, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) > 4:
                        mp = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), parts[4])
                        mounts.add(mp)
        except OSError:
            pass
        _MOUNTS = mounts
    return _MOUNTS


def fstab_mounts():
    """Mount points configured in /etc/fstab (field 2)."""
    out = set()
    if NT:
        return out
    try:
        with open(ov("fstab") or "/etc/fstab", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and not parts[0].startswith("#") and parts[1].startswith("/"):
                    out.add(re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), parts[1]))
    except OSError:
        pass
    return out


def on_unavailable_mount(p):
    """True when p lies under /mnt or /media, or under an fstab mount point that is not mounted
    right now: a missing path there may only be unreachable, not gone. Windows: a path that is
    not on a local fixed NTFS/ReFS drive (UNC, network, removable, absent drive)."""
    if NT:
        return nt_volume_refusal(p) is not None
    if is_under(p, "/mnt") or is_under(p, "/media"):
        return True
    mounted = mount_points()
    return any(m != "/" and is_under(p, m) and m not in mounted for m in fstab_mounts())


def mount_at_or_below(p):
    """A mount point at or below p, else None. Windows: p itself when it is a reparse point
    or a volume root (deeper reparse points are refused by the tree walks)."""
    if NT:
        try:
            if is_reparse(os.lstat(p)) or os.path.ismount(p):
                return p
        except OSError:
            pass
        return None
    for m in mount_points():
        if m != "/" and is_under(m, p):
            return m
    if os.path.isdir(p) and not os.path.islink(p) and os.path.ismount(p):
        return p
    return None


SYSTEM_DENY = ["/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/mnt", "/media",
               "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/usr", "/var", "/tmp",
               "/var/tmp", "/dev/shm", "/snap"]


def hard_refusal(p, cfg_keep_paths=()):
    """Reason string when p is on the hard denylist (whatever the ledger says), else None."""
    h = home()
    if NT:
        why = nt_volume_refusal(p) or nt_system_refusal(p)
        if why:
            return why
    elif p in SYSTEM_DENY:
        return "system or root-level path"
    if is_under(h, p):
        return "the home directory or one of its parents"
    if in_claude_profile(p):
        return "Claude profile data (~/.claude*/** and $CLAUDE_CONFIG_DIR, never deleted by the helper)"
    if is_under(p, state_dir()) or is_under(state_dir(), p):
        return "the provenance ledger itself"
    if p == keep_root() or p == keep_list_path() or is_under(keep_root(), p):
        return "the keep store or its parents"
    try:
        st = os.lstat(p)
    except OSError:
        st = None
    # a single file directly in a Windows temp dir (/mnt/c/tmp/<f>) is no mounted storage (#208)
    win_file = win_temp_root_of(p) is not None and (st is None or not stat.S_ISDIR(st.st_mode))
    for top in ("/mnt", "/media") if not NT else ():
        if is_under(p, top) and p.count("/") <= 4 and not win_file:
            return "mounted storage (depth <= 4)"
    if NT and st is not None and is_reparse(st):
        return "a junction, symlink or other reparse point (never followed or deleted on Windows)"
    if st is not None and stat.S_ISDIR(st.st_mode):
        m = mount_at_or_below(p)
        if m:
            return "a mount point at or below it (%s)" % m
    for k in cfg_keep_paths or ():
        if not isinstance(k, str) or not k.strip():
            continue
        kp = os.path.realpath(os.path.expanduser(k.strip()))
        if is_under(p, kp) or is_under(kp, p):
            return "on the owner's keep list (cleanup.keep_paths in the local config)"
    return None


def temp_roots():
    if NT:
        roots = [nt_temp_dir(), tmp_base()]
        return roots + [os.path.realpath(r) for r in ov("temp_roots", [])]
    roots = ["/tmp", "/var/tmp", "/dev/shm", tmp_base()]
    roots += [os.path.realpath(r) for r in ov("temp_roots", [])]
    return roots


def in_temp_root(p):
    """Below a temp root and not inside the home (a home under /tmp never counts as temp).
    Windows: the per-user temp dir lies inside the home by design; only the known-folder temp
    roots count there (never %TEMP%)."""
    if NT:
        return any(not same_path(p, r) and is_under(p, r) for r in temp_roots())
    if is_under(p, home()):
        return False
    return any(p != r and is_under(p, r) for r in temp_roots())


_WIN_TEMP_RE = re.compile(r"^/[A-Za-z]/(?:users/[^/]+/appdata/local/temp|users/public|tmp)(?=/)",
                          re.IGNORECASE)


def win_temp_root_of(p):
    """WSL only: the Windows temp-ish dir a /mnt/<drive>/... path lies strictly below, else None.
    Windows temp-ish = a user's %TEMP% (C:\\Users\\<name>\\AppData\\Local\\Temp), C:\\Users\\Public
    or C:\\tmp, on any drive letter (drvfs). Only a single Write-created file there may go (#208):
    drvfs has no birth time, so it is never a temp root for scans or directories."""
    if NT:
        return None
    root = strip_sep(ov("drvfs_root") or "/mnt")
    if not is_under(p, root) or same_path(p, root):
        return None
    m = _WIN_TEMP_RE.match(p[len(root):])
    if not m:
        return None
    top = root + m.group(0)
    return top if not same_path(p, top) else None


def _git_refusal(d, git_entry):
    """Reason when the repository marker git_entry (d/.git) forbids deleting d."""
    if not os.path.isdir(git_entry) or os.path.islink(git_entry):
        return "%s is a linked git worktree (use credo-worktree-cleanup.sh, never a plain delete)" % d
    if not in_temp_root(d):
        return "%s is a repository outside the temp roots (a likely result, never a plain delete)" % d
    wts = os.path.join(git_entry, "worktrees")
    if os.path.isdir(wts) and os.listdir(wts):
        return "%s is a repository with linked worktrees" % d
    return None


class TreeInfo:
    def __init__(self):
        self.newest = 0.0      # newest mtime/ctime of any inode
        self.special = None    # first socket / fifo / device found
        self.count = 0


SLACK = 2.0  # seconds of clock/rounding slack between a parent's and a child's birth


def foreign_inode(st, bt, since):
    """Reason when an inode cannot be this session's work: no birth time, born before the
    provenance start (pre-existing data moved in on the same file system), or a modification
    time older than its own birth (moved across file systems, extracted, copied with preserved
    times). None when it may be own."""
    if bt is None:
        return "birth time unknown"
    if since is None:
        return "no recorded provenance start"
    if bt < since - SLACK:
        return "older than the session's entry (pre-existing data moved in)"
    if st.st_mtime < bt - SLACK and not stat.S_ISLNK(st.st_mode):
        return "modification time older than its birth (moved across file systems or extracted)"
    return None


def inspect_tree(p, st, since, limit_s=30.0):
    """Walk p (no symlink follow) and return (reason, TreeInfo). reason is set when p or anything
    below it is foreign (see foreign_inode), a mount point, a linked worktree, a repository outside
    the temp roots or with linked worktrees, or when the walk did not finish in time (an
    incomplete walk proves nothing: refuse)."""
    info = TreeInfo()
    t_end = now() + limit_s
    m = mount_at_or_below(p) if stat.S_ISDIR(st.st_mode) else None
    if m:
        return "a mount point at or below it (%s)" % m, info
    stack = [(p, st)]
    while stack:
        if now() > t_end:
            return "tree too large to check in %.0fs (refused, nothing deleted)" % limit_s, info
        path, pst = stack.pop()
        info.count += 1
        info.newest = max(info.newest, pst.st_mtime, pst.st_ctime)
        if NT:
            why = nt_node_refusal(path, pst)
            if why:
                return why, info
            if attrs(pst) & _NT_SPECIAL:
                info.special = info.special or path
        if not (stat.S_ISDIR(pst.st_mode) or stat.S_ISREG(pst.st_mode) or stat.S_ISLNK(pst.st_mode)):
            info.special = info.special or path
        why = foreign_inode(pst, birth_time(path), since)
        if why:
            return "%s: %s" % (path, why), info
        if not stat.S_ISDIR(pst.st_mode):
            continue
        if pst.st_dev != st.st_dev:
            return "%s is another file system" % path, info
        g = os.path.join(path, ".git")
        if os.path.lexists(g):
            reason = _git_refusal(path, g)
            if reason:
                return reason, info
        try:
            it = list(os.scandir(path))
        except OSError as exc:
            return "%s cannot be read (%s)" % (path, exc.strerror or exc), info
        for de in it:
            try:
                cst = lstat_entry(de)
            except OSError as exc:
                return "%s cannot be read (%s)" % (de.path, exc.strerror or exc), info
            stack.append((de.path, cst))
    return None, info


def inspect_tree_structure(p, st, limit_s=30.0):
    """inspect_tree without the provenance (birth) checks: mounts, worktrees, repositories."""
    info = TreeInfo()
    if not stat.S_ISDIR(st.st_mode):
        return None, info
    m = mount_at_or_below(p)
    if m:
        return "a mount point at or below it (%s)" % m, info
    t_end = now() + limit_s
    stack = [p]
    while stack:
        if now() > t_end:
            return "tree too large to check in %.0fs (refused, nothing deleted)" % limit_s, info
        d = stack.pop()
        g = os.path.join(d, ".git")
        if os.path.lexists(g):
            reason = _git_refusal(d, g)
            if reason:
                return reason, info
        try:
            it = list(os.scandir(d))
        except OSError as exc:
            return "%s cannot be read (%s)" % (d, exc.strerror or exc), info
        for de in it:
            try:
                cst = lstat_entry(de)
            except OSError:
                return "%s cannot be read" % de.path, info
            if NT:
                why = nt_node_refusal(de.path, cst)
                if why:
                    return why, info
                if attrs(cst) & _NT_SPECIAL:
                    info.special = info.special or de.path
            info.newest = max(info.newest, cst.st_mtime, cst.st_ctime)
            if stat.S_ISDIR(cst.st_mode):
                if cst.st_dev != st.st_dev:
                    return "%s is another file system" % de.path, info
                if de.name != ".git":
                    stack.append(de.path)
            elif not (stat.S_ISREG(cst.st_mode) or stat.S_ISLNK(cst.st_mode)):
                info.special = info.special or de.path
    return None, info


def held_open(p, limit_s=5.0):
    """A pid whose cwd or an open file lies at or below p (from /proc; only readable processes),
    'unknown' when the scan did not finish, 'unsupported' on Windows (no /proc; no equally
    strong way to see other processes' cwd and open files there), else None."""
    if NT:
        return "unsupported"
    t_end = now() + limit_s
    try:
        pids = [n for n in os.listdir("/proc") if n.isdigit()]
    except OSError:
        return None
    me = str(os.getpid())
    for pid in pids:
        if pid == me:
            continue
        if now() > t_end:
            return "unknown"
        base = "/proc/" + pid
        links = [base + "/cwd"]
        try:
            links += [base + "/fd/" + f for f in os.listdir(base + "/fd")]
        except OSError:
            pass
        for ln in links:
            try:
                target = os.readlink(ln)
            except OSError:
                continue
            if target.endswith(" (deleted)"):
                target = target[:-10]
            if is_under(target, p):
                return pid
    return None


def git_tracked(p):
    """True when p (or anything below it) is tracked by git. False outside a work tree."""
    top, _ = git_top(p)
    if not top or p == top:
        return False
    rel = os.path.relpath(p, top)
    if NT:
        rel = rel.replace(os.sep, "/")
    try:
        out = subprocess.run(["git", "-C", top, "ls-files", "-z", "--", rel], capture_output=True,
                             timeout=20)
    except (OSError, subprocess.SubprocessError):
        return True  # unsure: treat as tracked (refuse)
    if out.returncode != 0:
        # only "not a git repository" proves nothing is tracked; any other error refuses
        return b"not a git repository" not in out.stderr.lower()
    return bool(out.stdout.strip(b"\0"))


def session_bound_roots(sid):
    """Directories bound to the session by their name: the session TMPDIR and the Claude Code
    scratchpad of this session id. Their children are owned; the roots themselves are not deleted
    by own-rm."""
    if not valid_sid(sid):
        return []
    roots = []
    if private_dir(tmp_base()) and private_dir(session_tmp(sid)):
        roots.append(session_tmp(sid))
    sb = scratch_base()
    if private_dir(sb, mode_0700=False):
        for pad in glob.glob(os.path.join(glob.escape(sb), "*", sid, "scratchpad")):
            if private_dir(pad, mode_0700=False):  # no symlink anywhere on the way (realpath == path)
                roots.append(pad)
    return roots


def same_birth(e, path):
    """False when the entry recorded a birth time and the path now has a different one (inode
    reuse: the path was deleted and something new got the same inode number)."""
    rec = e.get("btime")
    if rec is None:
        return True
    cur = birth_time(path)
    return cur is not None and abs(cur - rec) < 0.01


_TRANSCRIPTS = {}
WRITE_TOOL_NAMES = {"Write", "Edit", "MultiEdit", "NotebookEdit"}


def transcript_files(sid):
    files = []
    for prof in profile_dirs():
        base = os.path.join(glob.escape(prof), "projects", "*")
        files += glob.glob(os.path.join(base, sid + ".jsonl"))
        files += glob.glob(os.path.join(base, sid, "subagents", "*.jsonl"))
    return files


def _written_paths(f):
    """Paths of successful Write/Edit/MultiEdit/NotebookEdit tool calls in one transcript: a
    tool_use of such a name, plus its tool_result that is no error (is_error not true and no
    error text as toolUseResult). Read calls, rejected and failed writes do not count."""
    uses, ok = {}, set()
    try:
        fh = open(f, encoding="utf-8", errors="replace")
    except OSError:
        return set()
    with fh:
        for line in fh:
            if '"tool_use' not in line and '"tool_result' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            content = (d.get("message") or {}).get("content") if isinstance(d, dict) else None
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "tool_use" and c.get("name") in WRITE_TOOL_NAMES:
                    inp = c.get("input") or {}
                    fp = inp.get("file_path") or inp.get("notebook_path")
                    if isinstance(fp, str) and os.path.isabs(fp) and c.get("id"):
                        uses[c["id"]] = os.path.normpath(fp)
                elif c.get("type") == "tool_result" and c.get("tool_use_id"):
                    if c.get("is_error") is True or isinstance(d.get("toolUseResult"), str):
                        continue
                    ok.add(c["tool_use_id"])
    return {p for i, p in uses.items() if i in ok}


def transcript_wrote(sid, path):
    """True when a transcript of this session (main agent or subagent) holds a successful
    Write/Edit call for exactly this file path (no prefix match: a write to X/f says nothing
    about X)."""
    for f in transcript_files(sid):
        if f not in _TRANSCRIPTS:
            _TRANSCRIPTS[f] = _written_paths(f)
        paths = _TRANSCRIPTS[f]
        if NT:
            if any(same_path(q, path) or same_path(real_target(q) or q, path) for q in paths):
                return True
            continue
        if path in paths or any((real_target(q) or q) == path for q in paths):
            return True
    return False


def not_deletable_entry(p, e, sid=None):
    """Report-only reason for a ledger entry that may never be deleted without a prompt: only an
    entry the Write/Edit tool created, inside a temp root (not in the home, not in a worktrees
    dir) is deletable. What the birth-time scan of a Bash call found may have been created by the
    owner or another program during the call, so it is only reported."""
    if e.get("evidence") != "write":
        return ("report only: not a file the Write/Edit tool created (%s evidence); another "
                "process may have created it - the owner decides" % e.get("evidence"))
    if e.get("type") != "file":
        return "report only: a directory created as a side effect of a Write"
    if not in_temp_root(p) and not win_temp_root_of(p):
        return ("report only: outside the temp roots (home, worktrees dir or elsewhere; on the "
                "Windows side only %TEMP%, C:\\Users\\Public and C:\\tmp)")
    if sid is not None and not transcript_wrote(sid, p):
        return "report only: no successful Write/Edit call for exactly this file in this session's transcript"
    return None


def owned_entry(p, st, entries, sid):
    """(ok, entry_or_None, reason, since). p is a real target path, st its lstat. Own is only:
    something inside the session TMPDIR or scratchpad (since = the root's birth), or exactly one
    regular FILE the Write/Edit tool created (since = its own recorded birth). A directory that a
    Write created as a side effect, and everything that later lands in it, is never own."""
    for root in session_bound_roots(sid):
        if p != root and is_under(p, root):
            return True, None, "session-bound (%s)" % root, birth_time(root)
    e = entries.get(p)
    if e is None:
        return False, None, "not created by this session (not in its ledger)", None
    if e.get("dev") != st.st_dev or e.get("ino") != st.st_ino or not same_birth(e, p):
        return False, e, "replaced since it was recorded (dev/inode/birth differ)", None
    if not stat.S_ISREG(st.st_mode):
        return False, e, ("report only: only a single file the Write/Edit tool created is deletable "
                          "outside the session TMPDIR and scratchpad"), None
    why = not_deletable_entry(p, e, sid)
    if why:
        return False, e, why, None
    return True, e, "ledger entry", e.get("btime")


# --------------------------------------------------------------------------- delete


# getattr: O_DIRECTORY / O_NOFOLLOW do not exist on Windows; the module must still import there
_DIR_FLAGS = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
              | getattr(os, "O_CLOEXEC", 0))


def open_dir_nofollow(path):
    """fd of directory path, opened component by component without following any symlink."""
    fd = os.open("/", _DIR_FLAGS)
    try:
        for comp in [c for c in path.split("/") if c]:
            nfd = os.open(comp, _DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nfd
    except OSError:
        os.close(fd)
        raise
    return fd


def _rm_contents(fd, path, top_dev, since, errors):
    """Delete everything inside the open directory fd (path is only for messages and the mount
    check). Every inode is checked again right before its removal; a foreign one stays."""
    try:
        names = [de.name for de in os.scandir(fd)]
    except OSError as exc:
        errors.append("%s: %s" % (path, exc.strerror or exc))
        return
    for name in names:
        cpath = os.path.join(path, name)
        try:
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except OSError as exc:
            errors.append("%s: %s" % (cpath, exc.strerror or exc))
            continue
        if since is not False:
            why = foreign_inode(st, birth_time(name, dir_fd=fd), since)
            if why:
                errors.append("%s: %s, left alone" % (cpath, why))
                continue
        if stat.S_ISDIR(st.st_mode):
            if st.st_dev != top_dev or cpath in mount_points():
                errors.append("%s: other file system inside, left alone" % cpath)
                continue
            try:
                cfd = os.open(name, _DIR_FLAGS, dir_fd=fd)
            except OSError as exc:
                errors.append("%s: %s" % (cpath, exc.strerror or exc))
                continue
            try:
                cst = os.fstat(cfd)
                if (cst.st_dev, cst.st_ino) != (st.st_dev, st.st_ino):
                    errors.append("%s: changed during the delete, left alone" % cpath)
                    continue
                _rm_contents(cfd, cpath, top_dev, since, errors)
            finally:
                os.close(cfd)
            try:
                os.rmdir(name, dir_fd=fd)
            except OSError as exc:
                errors.append("%s: %s" % (cpath, exc.strerror or exc))
        else:
            try:
                os.unlink(name, dir_fd=fd)
            except OSError as exc:
                errors.append("%s: %s" % (cpath, exc.strerror or exc))


def delete_path(p, st, since=False):
    """Remove p, which must still be the inode st (dev+ino) that was checked. Works on file
    descriptors opened without following symlinks, so a path component swapped for a symlink
    after the check fails instead of redirecting the delete. since: the provenance start that
    every inode is checked against again right before its removal (False = no birth check,
    for owner-approved keep entries). Returns error strings (empty = removed). Windows: see
    delete_path_nt (handles, no reparse point is ever followed or deleted)."""
    if NT:
        return delete_path_nt(p, st, since)
    errors = []
    parent, name = os.path.split(p)
    try:
        pfd = open_dir_nofollow(parent)
    except OSError as exc:
        return ["%s: parent cannot be opened without following links (%s)" % (p, exc.strerror or exc)]
    try:
        try:
            cur = os.stat(name, dir_fd=pfd, follow_symlinks=False)
        except OSError as exc:
            return ["%s: %s" % (p, exc.strerror or exc)]
        if (cur.st_dev, cur.st_ino) != (st.st_dev, st.st_ino):
            return ["%s: replaced since the check, left alone" % p]
        if stat.S_ISDIR(cur.st_mode):
            try:
                fd = os.open(name, _DIR_FLAGS, dir_fd=pfd)
            except OSError as exc:
                return ["%s: %s" % (p, exc.strerror or exc)]
            try:
                fst = os.fstat(fd)
                if (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino):
                    return ["%s: replaced since the check, left alone" % p]
                _rm_contents(fd, p, st.st_dev, since, errors)
            finally:
                os.close(fd)
            if not errors:
                try:
                    os.rmdir(name, dir_fd=pfd)
                except OSError as exc:
                    errors.append("%s: %s" % (p, exc.strerror or exc))
        else:
            try:
                os.unlink(name, dir_fd=pfd)
            except OSError as exc:
                errors.append("%s: %s" % (p, exc.strerror or exc))
    finally:
        os.close(pfd)
    return errors


# --------------------------------------------------------------------------- Windows delete


def nt_node_refusal(path, st):
    """Windows: reason when one node of a tree forbids touching the tree, else None."""
    if is_reparse(st) or stat.S_ISLNK(st.st_mode):
        return ("%s is a junction, symlink or other reparse point (report only on Windows, never "
                "followed or deleted)" % path)
    if not st.st_ino:
        return "%s has no stable file id (report only on Windows)" % path
    return None


_NT_DELETE = 0x00010000
_NT_READ_ATTRIBUTES = 0x80
_NT_LIST_DIRECTORY = 0x1          # FILE_READ_DATA: makes the share mode count (pins the object)
_NT_SYNCHRONIZE = 0x00100000
_NT_SHARE_READ_WRITE = 0x1 | 0x2  # never FILE_SHARE_DELETE: nobody may rename or delete it
_NT_OPEN_EXISTING = 3
_NT_FLAGS = 0x02000000 | 0x00200000  # BACKUP_SEMANTICS (dirs) | OPEN_REPARSE_POINT (no follow)
_NT_DISPOSITION_EX = 21           # FileDispositionInfoEx
_NT_DISPOSITION = 4               # FileDispositionInfo
_NT_DISP_FLAGS = 0x1 | 0x2 | 0x10  # DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE


def _nt_k32():
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateFileW.restype = wintypes.HANDLE
    k32.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    k32.CloseHandle.argtypes = (wintypes.HANDLE,)
    k32.SetFileInformationByHandle.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                               wintypes.DWORD)
    return k32


def _nt_open(path, access):
    """CRT fd of a handle on path itself (a reparse point is opened, never followed), share mode
    read+write only. Raises OSError."""
    import msvcrt
    ab = os.path.abspath(path)
    drive, _ = ntpath.splitdrive(ab)
    if len(drive) != 2 or drive[1] != ":":
        raise OSError("not a drive letter path: %s" % path)
    k32 = _nt_k32()
    h = k32.CreateFileW("\\\\?\\" + ab, access, _NT_SHARE_READ_WRITE, None, _NT_OPEN_EXISTING,
                        _NT_FLAGS, None)
    if not h or h == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return msvcrt.open_osfhandle(h, os.O_RDONLY)
    except OSError:
        k32.CloseHandle(h)
        raise


def _nt_mark_delete(fd):
    """Delete the object behind fd (POSIX semantics: the name goes at once; a read-only
    attribute does not stop it). Falls back to the classic disposition. Raises OSError."""
    import msvcrt
    k32 = _nt_k32()
    h = msvcrt.get_osfhandle(fd)
    flags = ctypes.c_ulong(_NT_DISP_FLAGS)
    if k32.SetFileInformationByHandle(h, _NT_DISPOSITION_EX, ctypes.byref(flags), 4):
        return
    err = ctypes.get_last_error()
    if err in (1, 50, 87):  # not supported by this Windows / file system: classic disposition
        flag = ctypes.c_ubyte(1)
        if k32.SetFileInformationByHandle(h, _NT_DISPOSITION, ctypes.byref(flag), 1):
            return
        err = ctypes.get_last_error()
    raise ctypes.WinError(err)


def _nt_pin_dirs(parent):
    """fds that pin every directory from the drive root down to parent (no share delete, so
    none of them can be renamed, deleted or swapped for a junction while they are held). Each
    must be a real directory, no reparse point. Raises OSError."""
    ab = os.path.abspath(parent)
    drive, rest = ntpath.splitdrive(ab)
    cur = drive + os.sep
    fds = []
    try:
        for comp in [""] + [c for c in rest.split(os.sep) if c]:
            cur = os.path.join(cur, comp) if comp else cur
            fd = _nt_open(cur, _NT_LIST_DIRECTORY | _NT_READ_ATTRIBUTES | _NT_SYNCHRONIZE)
            fds.append(fd)
            fst = os.fstat(fd)
            if not stat.S_ISDIR(fst.st_mode) or (comp and is_reparse(fst)):
                raise OSError("%s is no plain directory (reparse point or file)" % cur)
    except OSError:
        for fd in fds:
            os.close(fd)
        raise
    return fds


def _nt_remove(path, expect, top_dev, since, errors):
    """Remove path, which must still be the object expect (volume serial + file id). Directories
    are emptied first while their handle pins them. Errors are appended; True when removed."""
    is_dir = stat.S_ISDIR(expect.st_mode)
    access = _NT_DELETE | _NT_READ_ATTRIBUTES | _NT_SYNCHRONIZE | (_NT_LIST_DIRECTORY if is_dir else 0)
    try:
        fd = _nt_open(path, access)
    except OSError as exc:
        errors.append("%s: %s" % (path, exc.strerror or exc))
        return False
    try:
        fst = os.fstat(fd)
        if (fst.st_dev, fst.st_ino) != (expect.st_dev, expect.st_ino) or not fst.st_ino:
            errors.append("%s: replaced since the check, left alone" % path)
            return False
        why = nt_node_refusal(path, fst)
        if why:
            errors.append(why + ", left alone")
            return False
        if since is not False:
            why = foreign_inode(fst, birth_of(fst), since)
            if why:
                errors.append("%s: %s, left alone" % (path, why))
                return False
        if is_dir:
            _nt_rm_contents(path, top_dev, since, errors)
        try:
            _nt_mark_delete(fd)
        except OSError as exc:
            errors.append("%s: %s" % (path, exc.strerror or exc))
            return False
        return True
    finally:
        os.close(fd)


def _nt_rm_contents(path, top_dev, since, errors):
    try:
        names = [de.name for de in os.scandir(path)]
    except OSError as exc:
        errors.append("%s: %s" % (path, exc.strerror or exc))
        return
    for name in names:
        cpath = os.path.join(path, name)
        try:
            cst = os.lstat(cpath)
        except OSError as exc:
            errors.append("%s: %s" % (cpath, exc.strerror or exc))
            continue
        why = nt_node_refusal(cpath, cst)
        if why:
            errors.append(why + ", left alone")
            continue
        if since is not False:
            why = foreign_inode(cst, birth_of(cst), since)
            if why:
                errors.append("%s: %s, left alone" % (cpath, why))
                continue
        if stat.S_ISDIR(cst.st_mode) and cst.st_dev != top_dev:
            errors.append("%s: other volume inside, left alone" % cpath)
            continue
        _nt_remove(cpath, cst, top_dev, since, errors)


def delete_path_nt(p, st, since=False):
    """Windows delete_path: pins every parent directory, opens p itself (never following a
    reparse point), checks it is still the inode st, empties a directory child by child with
    the same checks (each child re-checked on its own handle right before removal), then marks
    p for deletion. A reparse point anywhere is left alone. Returns error strings."""
    errors = []
    why = nt_node_refusal(p, st)
    if why:
        return [why]
    try:
        pins = _nt_pin_dirs(os.path.dirname(os.path.abspath(p)))
    except OSError as exc:
        return ["%s: parent cannot be pinned without following links (%s)" % (p, exc.strerror or exc)]
    try:
        sub = []
        removed = _nt_remove(p, st, st.st_dev, since, sub)
        errors += sub
        if not removed and not sub:
            errors.append("%s: not removed" % p)
    finally:
        for fd in pins:
            os.close(fd)
    return errors


def dir_size(path, limit_s=10.0):
    """Bytes below path (no symlink follow, same device), best effort within limit_s."""
    total = 0
    t_end = now() + limit_s
    stack = [path]
    try:
        top_dev = os.lstat(path).st_dev
    except OSError:
        return None
    while stack:
        if now() > t_end:
            return None
        d = stack.pop()
        try:
            for de in os.scandir(d):
                try:
                    st = lstat_entry(de)
                except OSError:
                    continue
                if NT and is_reparse(st):
                    continue  # never followed
                if stat.S_ISDIR(st.st_mode):
                    if st.st_dev == top_dev:
                        stack.append(de.path)
                else:
                    total += st.st_blocks * 512 if hasattr(st, "st_blocks") else st.st_size
        except OSError:
            continue
    return total


def detach(argv, logfile=None):
    """Start argv detached (own session, no stdin, output to logfile or /dev/null)."""
    out = open(logfile, "a") if logfile else subprocess.DEVNULL
    try:
        if NT:  # no setsid: a detached process without a console in its own group
            flags = 0x00000008 | 0x00000200 | 0x08000000  # DETACHED | NEW_GROUP | NO_WINDOW
            subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                             creationflags=flags, close_fds=True)
            return
        subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                         start_new_session=True, close_fds=True)
    finally:
        if logfile:
            out.close()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")

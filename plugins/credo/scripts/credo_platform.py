"""credo_platform.py - small portability helpers for the credo scripts (stdlib only).

bash_exe()      the bash to run credo's shell scripts with. A native Windows Python resolves a
                bare "bash" to System32\\bash.exe, the WSL launcher, not Git Bash; the hooks
                (hooks/credo-python-lib.sh) therefore export CREDO_BASH, the Windows path of
                the Git Bash that runs them. Elsewhere: "bash".
pid_alive(pid)  whether a process with this pid exists. os.kill(pid, 0) tests a pid on POSIX,
                but on Windows it sends CTRL_C_EVENT, so there OpenProcess and
                GetExitCodeProcess (ctypes) decide. Unknown -> False only when the pid is
                clearly gone; an access-denied process counts as alive.

Process identity on native Windows (ctypes only: kernel32, ntdll, shell32; no /proc there).
Every function returns an "unknown" value ("" / [] / 0 / None) instead of raising:
  proc_start(pid)    creation time as a FILETIME decimal string (100 ns ticks since 1601, UTC),
                     the same value Claude Code writes as "procStart" into its session
                     descriptor on Windows (GetProcessTimes); "" when unknown or exited
  proc_exe(pid)      full image path (QueryFullProcessImageNameW)
  proc_cmdline(pid)  argv list (NtQueryInformationProcess ProcessCommandLineInformation, split
                     by CommandLineToArgvW); [] when not readable (other users, protected)
  proc_table()       {pid: (ppid, exe name)} of all processes (CreateToolhelp32Snapshot)
  proc_ppid(pid)     parent pid, 0 when unknown. Windows reuses pids and never re-parents, so
                     the parent counts only when it was created before the child (both creation
                     times readable); otherwise the chain ends there (fail closed)
  ancestors(pid)     [pid, parent, grandparent, ...]
  proc_alive(pid, start)  alive and (when given) the same creation time
  filetime_to_epoch(ft)   FILETIME ticks -> epoch seconds (float), None when not a number
is_nt() is the one switch the callers branch on; the tests flip IS_NT to simulate Windows.
"""
import os

IS_NT = os.name == "nt"


def is_nt():
    return IS_NT


def bash_exe():
    v = os.environ.get("CREDO_BASH", "")
    if v and os.path.isfile(v):
        return v
    return "bash"


_STILL_ACTIVE = 259
_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
_ERROR_ACCESS_DENIED = 5
_EPOCH_DIFF_S = 11644473600
_STATUS_INFO_LENGTH_MISMATCH = 0xC0000004
_PROCESS_COMMAND_LINE_INFORMATION = 60
_TH32CS_SNAPPROCESS = 0x2

_API = {}


def _k32():
    """kernel32 with the prototypes used here (cached)."""
    if "k32" in _API:
        return _API["k32"]
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    k32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
    k32.CloseHandle.argtypes = (wintypes.HANDLE,)
    k32.GetProcessTimes.argtypes = (wintypes.HANDLE,) + (ctypes.POINTER(wintypes.FILETIME),) * 4
    k32.QueryFullProcessImageNameW.argtypes = (wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                               ctypes.POINTER(wintypes.DWORD))
    k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    k32.CreateToolhelp32Snapshot.argtypes = (wintypes.DWORD, wintypes.DWORD)
    k32.LocalFree.argtypes = (wintypes.HLOCAL,)
    _API["k32"] = k32
    return k32


def _pid_alive_nt(pid):
    import ctypes
    from ctypes import wintypes
    k32 = _k32()
    h = k32.OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        return ctypes.get_last_error() == _ERROR_ACCESS_DENIED
    try:
        code = wintypes.DWORD()
        if not k32.GetExitCodeProcess(h, ctypes.byref(code)):
            return True
        return code.value == _STILL_ACTIVE
    finally:
        k32.CloseHandle(h)


def pid_alive(pid):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if IS_NT:
        try:
            return _pid_alive_nt(pid)
        except (OSError, AttributeError, ValueError):
            return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


# --------------------------------------------------------------------------- Windows processes


class _Handle:
    """OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) for a with block; .h is None when the
    process cannot be opened (gone, access denied)."""

    def __init__(self, pid):
        self.pid = pid
        self.h = None

    def __enter__(self):
        try:
            pid = int(self.pid)
        except (TypeError, ValueError):
            return self
        if pid > 0:
            self.h = _k32().OpenProcess(_PROCESS_QUERY_LIMITED_INFORMATION, False, pid) or None
        return self

    def __exit__(self, *exc):
        if self.h:
            _k32().CloseHandle(self.h)


def _active(k32, h):
    import ctypes
    from ctypes import wintypes
    code = wintypes.DWORD()
    return bool(k32.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == _STILL_ACTIVE


def _proc_start_nt(pid):
    import ctypes
    from ctypes import wintypes
    k32 = _k32()
    with _Handle(pid) as ph:
        if not ph.h or not _active(k32, ph.h):
            return ""
        c, e, k, u = (wintypes.FILETIME() for _ in range(4))
        if not k32.GetProcessTimes(ph.h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(k),
                                   ctypes.byref(u)):
            return ""
        ft = (c.dwHighDateTime << 32) | c.dwLowDateTime
        return str(ft) if ft > 0 else ""


def proc_start(pid):
    try:
        return _proc_start_nt(pid)
    except (OSError, AttributeError, ValueError, ImportError):
        return ""


def _proc_exe_nt(pid):
    import ctypes
    from ctypes import wintypes
    k32 = _k32()
    with _Handle(pid) as ph:
        if not ph.h:
            return ""
        size = wintypes.DWORD(32768)
        buf = ctypes.create_unicode_buffer(size.value)
        if not k32.QueryFullProcessImageNameW(ph.h, 0, buf, ctypes.byref(size)):
            return ""
        return buf.value


def proc_exe(pid):
    try:
        return _proc_exe_nt(pid)
    except (OSError, AttributeError, ValueError, ImportError):
        return ""


def split_cmdline(cmd):
    """Windows command line -> argv (CommandLineToArgvW, the rules the C runtime uses)."""
    import ctypes
    from ctypes import wintypes
    if not cmd:
        return []
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    shell32.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
    shell32.CommandLineToArgvW.argtypes = (wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int))
    argc = ctypes.c_int(0)
    argv = shell32.CommandLineToArgvW(cmd, ctypes.byref(argc))
    if not argv:
        return []
    try:
        return [argv[i] for i in range(argc.value)]
    finally:
        _k32().LocalFree(ctypes.cast(argv, wintypes.HLOCAL))


def _proc_cmdline_nt(pid):
    import ctypes
    from ctypes import wintypes
    ntdll = ctypes.WinDLL("ntdll")
    ntdll.NtQueryInformationProcess.restype = ctypes.c_ulong
    ntdll.NtQueryInformationProcess.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                                wintypes.ULONG, ctypes.POINTER(wintypes.ULONG))

    class UnicodeString(ctypes.Structure):
        _fields_ = [("Length", wintypes.USHORT), ("MaximumLength", wintypes.USHORT),
                    ("Buffer", ctypes.c_void_p)]

    with _Handle(pid) as ph:
        if not ph.h:
            return []
        size = 4096
        for _ in range(4):
            buf = ctypes.create_string_buffer(size)
            ret = wintypes.ULONG(0)
            status = ntdll.NtQueryInformationProcess(ph.h, _PROCESS_COMMAND_LINE_INFORMATION, buf,
                                                     size, ctypes.byref(ret))
            if status == _STATUS_INFO_LENGTH_MISMATCH and ret.value > size:
                size = ret.value
                continue
            if status != 0:
                return []
            us = UnicodeString.from_buffer(buf)
            if not us.Buffer or not us.Length:
                return []
            return split_cmdline(ctypes.wstring_at(us.Buffer, us.Length // 2))
    return []


def proc_cmdline(pid):
    try:
        return _proc_cmdline_nt(pid)
    except (OSError, AttributeError, ValueError, ImportError):
        return []


def _proc_table_nt():
    import ctypes
    from ctypes import wintypes

    class ProcessEntry32W(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_void_p),
                    ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long),
                    ("dwFlags", wintypes.DWORD), ("szExeFile", ctypes.c_wchar * 260)]

    k32 = _k32()
    k32.Process32FirstW.argtypes = (wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W))
    k32.Process32NextW.argtypes = (wintypes.HANDLE, ctypes.POINTER(ProcessEntry32W))
    snap = k32.CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0)
    if not snap or snap == wintypes.HANDLE(-1).value:
        return None
    table = {}
    try:
        e = ProcessEntry32W()
        e.dwSize = ctypes.sizeof(ProcessEntry32W)
        ok = k32.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            table[int(e.th32ProcessID)] = (int(e.th32ParentProcessID), e.szExeFile)
            ok = k32.Process32NextW(snap, ctypes.byref(e))
    finally:
        k32.CloseHandle(snap)
    return table


def proc_table():
    """{pid: (ppid, exe name)}, or None when the snapshot fails."""
    try:
        return _proc_table_nt()
    except (OSError, AttributeError, ValueError, ImportError):
        return None


def proc_ppid(pid, table=None):
    if table is None:
        table = proc_table() or {}
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return 0
    ppid = (table.get(pid) or (0, ""))[0]
    if ppid <= 0 or ppid == pid:
        return 0
    child, parent = proc_start(pid), proc_start(ppid)
    if not child or not parent or int(parent) > int(child):
        return 0  # parent gone or its pid reused by a younger process: the chain ends here
    return ppid


def ancestors(pid, limit=64):
    """[pid, parent, grandparent, ...] (Windows: verified parents only, see proc_ppid)."""
    table = proc_table() or {}
    out = []
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return out
    while pid > 0 and pid not in out and len(out) < limit:
        out.append(pid)
        pid = proc_ppid(pid, table)
    return out


def proc_alive(pid, start=""):
    cur = proc_start(pid)
    if not cur:
        return False
    return not start or str(start) == cur


def filetime_to_epoch(ft):
    try:
        return int(ft) / 1e7 - _EPOCH_DIFF_S
    except (TypeError, ValueError):
        return None

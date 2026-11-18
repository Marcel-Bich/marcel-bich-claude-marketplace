"""credo_platform.py - small portability helpers for the credo scripts (stdlib only).

bash_exe()      the bash to run credo's shell scripts with. A native Windows Python resolves a
                bare "bash" to System32\\bash.exe, the WSL launcher, not Git Bash; the hooks
                (hooks/credo-python-lib.sh) therefore export CREDO_BASH, the Windows path of
                the Git Bash that runs them. Elsewhere: "bash".
pid_alive(pid)  whether a process with this pid exists. os.kill(pid, 0) tests a pid on POSIX,
                but on Windows it sends CTRL_C_EVENT, so there OpenProcess and
                GetExitCodeProcess (ctypes) decide. Unknown -> False only when the pid is
                clearly gone; an access-denied process counts as alive.
"""
import os


def bash_exe():
    v = os.environ.get("CREDO_BASH", "")
    if v and os.path.isfile(v):
        return v
    return "bash"


_STILL_ACTIVE = 259
_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
_ERROR_ACCESS_DENIED = 5


def _pid_alive_nt(pid):
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.OpenProcess.restype = wintypes.HANDLE
    k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    k32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
    k32.CloseHandle.argtypes = (wintypes.HANDLE,)
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
    if os.name == "nt":
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

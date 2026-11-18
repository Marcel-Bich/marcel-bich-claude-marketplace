"""credo_lock.py - one portable exclusive file lock for the credo scripts (stdlib only).

POSIX: fcntl.flock on the open file. Native Windows: msvcrt.locking of the first byte of the
file (a dedicated lock file, so the byte never holds data). Without either module the lock is
a no-op, as before on platforms without fcntl.

    lock(fh_or_fd, blocking=True)  -> True when held, False when blocking=False and busy
    unlock(fh_or_fd)
    Locked(path)                   -> with block holding the lock on <path> (opened "a")

No caller imports fcntl or msvcrt itself; importing this module never fails.
"""
import os
import time

try:
    import fcntl
except ImportError:
    fcntl = None
try:
    import msvcrt
except ImportError:
    msvcrt = None

AVAILABLE = fcntl is not None or msvcrt is not None


def _fd(f):
    return f if isinstance(f, int) else f.fileno()


def lock(f, blocking=True):
    """Take the exclusive lock on an open file or fd. blocking=False returns False at once
    when another process holds it."""
    fd = _fd(f)
    if fcntl is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except OSError:
            if blocking:
                raise
            return False
        return True
    if msvcrt is not None:
        os.lseek(fd, 0, os.SEEK_SET)
        while True:
            try:
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                return True
            except OSError:
                if not blocking:
                    return False
                time.sleep(0.05)
    return True


def unlock(f):
    fd = _fd(f)
    if fcntl is not None:
        fcntl.flock(fd, fcntl.LOCK_UN)
    elif msvcrt is not None:
        os.lseek(fd, 0, os.SEEK_SET)
        try:
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        except OSError:
            pass


class Locked:
    """Exclusive lock on <path> for the duration of a with block (the file is created)."""

    def __init__(self, path):
        self.path = path
        self.fh = None

    def __enter__(self):
        d = os.path.dirname(self.path)
        if d:
            os.makedirs(d, exist_ok=True)
        self.fh = open(self.path, "a")
        lock(self.fh)
        return self

    def __exit__(self, *_):
        try:
            unlock(self.fh)
        finally:
            self.fh.close()
        return False

---
bump: patch
---

### Fixed

- credo hooks no longer fail visibly on native Windows when `python3`/`python` is only the
  Microsoft Store alias stub or missing: every Python hook probes for a working Python 3
  (`python3`, then `python`, then `py -3`), and the three ledger entries run through the new
  launcher `hooks/credo-py.sh` instead of the `python3` shebang
- Without a working Python 3 each session shows ONE clear message `credo needs python3` with
  the install command for the platform, instead of the Store text or a missing-module error
- A native Windows Python (python.org `python`, the `py` launcher) works: no credo script
  imports `fcntl` at top level any more; the new portable lock `scripts/credo_lock.py`
  (flock on POSIX, `msvcrt.locking` on Windows) is used by the cleanup library, the self
  restart, the LAN relay trust list and the WSL bridge, so none of them crashes with
  `No module named 'fcntl'`. The provenance ledger and the cleanup helper still exit 0
  there (POSIX only for now), and the Python LAN relay is not offered there
- Helper scripts reached from hooks (`credo-config.sh` and others) find Python the same way
  when `python3` is not on PATH
- Item and code ids can be drawn on Git Bash: the counter lock falls back to an atomic
  `mkdir` lock when `flock` is missing (also macOS)
- The 5h budget guard finds the limit cache on native Windows (the `/tmp` glob is handed to
  the Windows Python in its Windows form)
- Hooks run credo's shell scripts with their own bash (`$BASH`), and the Python scripts use
  `CREDO_BASH` (Git Bash) instead of a bare `bash`, which on Windows is the WSL launcher
- Process liveness on native Windows: `os.kill(pid, 0)` (which sends CTRL_C_EVENT there) is
  replaced by OpenProcess/GetExitCodeProcess (`scripts/credo_platform.py`), and the peer
  bridge checks Windows pids with `tasklist`, so live mirror entries are not pruned
- No `os.geteuid()` crash on native Windows in the session-name and peer-check helpers

### Added

- `python3` is a documented requirement (marketplace and credo README), and `/credo:setup`
  Step 1b detects a missing Python or the Store stub and offers the install command (runs it
  only after the user's yes)

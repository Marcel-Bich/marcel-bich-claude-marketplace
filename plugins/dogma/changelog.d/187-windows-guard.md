---
bump: patch
---
### Fixed

- The delete guard no longer blocks every command on native Windows with "guard error (exit 49)". Under Git Bash `python3` can be the Microsoft Store alias stub, which exits 9009 (seen as 49); the guard took it for a Python and failed closed on its exit code. The guard and token protection now start each candidate (`python3`, then `python`) once and use it only when it reports a POSIX Python 3. The Store stub and a native Windows Python (whose path semantics the guard does not model) count as missing: harmless commands pass, destructive-looking commands are denied by the text fallback, and token protection runs its own text rules instead of skipping them.
- No dogma hook or band script starts a bare `bash` any more, which on Windows can resolve to `System32\bash.exe` (the WSL launcher). Scripts call the running bash by its path, the session-start hook uses `/bin/bash`, and on Windows the dogma band runs its scripts through Git Bash by its full path (nothing when Git Bash is missing).

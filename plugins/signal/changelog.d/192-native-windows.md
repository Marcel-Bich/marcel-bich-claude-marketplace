---
bump: minor
---
### Added

- Native Windows support (Claude Code native, hooks run by Git Bash / MSYS2): detected by `uname -s` `MINGW*` or `MSYS*`, toasts, sounds, the Action Center cleanup at session start and the toast preflight now use the same PowerShell path as WSL2. `powershell.exe` comes from `PATH`, else the cached path, else `%SystemRoot%` (via `cygpath -u`); MSYS argument conversion is switched off for the `powershell.exe` run.
- On native Windows a hook resolves the state dir and `powershell.exe` once per run and skips the tmux and kitty process lookups, so the hooks stay well inside their timeouts despite the slow process start there.
- README section "Windows limitations": kitty tab indicator, tmux label, user-set session name in the title and `flock` are not available on native Windows.

### Fixed

- Sound volume math no longer needs `bc` (now `awk` in the C locale): without `bc` the Windows sound fell back to a fixed volume and the Linux `paplay`, `pw-play` and `ffplay` sounds were skipped entirely. A volume that is not a plain non-negative number counts as off on Linux and as the default 0.05 on Windows.

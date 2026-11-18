---
bump: patch
---

### Fixed

- Every hook command quotes `${CLAUDE_PLUGIN_ROOT}`, so the hooks still run when the plugin root
  contains a space (for example a Windows profile like `C:\Users\First Last`)
- `credo-worktree-setup.sh` matches hydra's `worktree-setup.sh` on native Windows: native symlinks
  only (never a silent copy, never a junction), a skip with a Developer Mode hint when Windows refuses
  symlinks, relative targets without Python (`realpath --relative-to`), `${BASH:-bash}` for dogma's
  list, Windows `installPath` entries, and no silent exit when the newest dogma lacks `worktree-files.sh`
- The resource gate checks the CPU on native Windows through CIM `Win32_Processor.LoadPercentage`
  (the WSL host path) instead of the MSYS load average, which always reads 0.00
- `credo-worktree-cleanup.sh` fails closed on native Windows: the live-process check cannot see
  Windows processes, so merged worktrees are reported as an owner question and never removed
- self-restart, self-compact, self-reload, the periodic reminder, owner-type and runtime pane
  references refuse with one clear "needs tmux, not available on native Windows" line instead of
  failing deeper down (the reminder hooks stay silent)

### Added

- `/credo:setup` power-down detects native Windows: `powercfg /a` for the available states,
  `MSYS_NO_PATHCONV=1 shutdown.exe /h` (hibernate) or the standby command
- README section "Windows limitations"

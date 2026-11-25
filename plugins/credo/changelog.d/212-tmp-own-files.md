---
bump: patch
---

### Added

- New-file guard for shared temp dirs (#212): `credo-ledger.py pre` denies a Bash command whose
  literal write target (`>`, `>>`, `tee`, `cp`/`mv`/`install ... <target>`, `dd of=`) would be
  a NEW file directly in `/tmp` or `/var/tmp`. The reason names the literal session TMPDIR and
  the own-rm line. Existing files, `/dev/*`, deeper paths (session TMPDIR, scratchpad), non-temp
  paths and commands that call `mktemp` pass; it fails open and is off with
  `CREDO_TMP_GUARD=0` or the local config key `cleanup.tmp_guard: false`.
- `credo_write_targets.py`: the literal write targets of a Bash command, parsed with the bash
  lexer of the inline guard (which now also records redirect targets). Only absolute literal
  paths count; variables, globs, `~` and relative paths never do.

### Fixed

- `own-rm` (and the done-gate purge) now also remove a single file in a temp root that a Bash
  command of the session provably wrote (#212): a literal write target of the command that the
  pre hook saw missing (ledger flag `write_target`; `mv` targets never count), born during the
  call while no other credo session had a tool call open, dev+inode unchanged, and a transcript
  of the session (main agent or a subagent) holds a successful Bash call naming exactly that path
  as a write target; the 2-minute and open-file checks apply. Directories and everything else
  the Bash scan found stay report-only.
- The bash lexer of the inline guard no longer reads `<` / `>` inside `[[ ... ]]` (a string
  comparison) as a redirect, so `[[ a > /tmp/x ]]` is not denied by the new-file guard.

---
bump: minor
---

### Added

- In a credo autonomous run (keep-alive active, not paused) every dogma "ask" becomes a "deny" with the same
  reason plus a retry hint, so no unanswerable prompt stalls the run; interactive sessions, a paused autonomy and
  any unclear detection keep the ask, and an ask never becomes an allow. All ask sites go through one emitter
  (`scripts/lib-decision.sh`). `CLAUDE_MB_DOGMA_UNATTENDED_DENY=false` keeps every ask.

### Fixed

- A `>` or `>>` after a loop or group (`for ...; done > file`) into a literal path inside this session's own
  TMPDIR or scratchpad no longer asks as a truncation; another session's folder, a `$var` target or a link
  leading out keep the normal rules

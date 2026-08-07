<!--
credo per-repo special rules (free-form Markdown).

These are project-local GRANTS that widen credo's autonomy for THIS repo only. They are
loaded and honored at every session start and inside every subagent (credo `rules` skill),
and they travel with the repo (this file is versioned by default).

Precedence: safety floor > DOGMA-PERMISSIONS > this file > credo defaults. A grant can only
WIDEN latitude within the safety floor - it can never lower filesystem-protection or the
no-autonomous-installs rule.

Keep each grant specific and observable. Delete these comments once you add real rules.

Example:

## Grants (widen autonomy)
- Restarting any LOCAL service/stack is always allowed without asking (debug-only repo).

## Notes
- <anything a builder should know about this repo's credo behavior>
-->

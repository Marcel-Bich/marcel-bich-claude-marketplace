---
bump: patch
---

### Fixed

- The spawn brief check no longer warns on a full-check marker inside quotes ("...", '...' or backticks), e.g. a quoted commit message naming a feature; the project's own full-check commands still warn inside backticks
- "main-only" next to a marker counts like the existing main-agent exemption
- A report of a past run ("the full check was green", "full suite passed", "ran the full check") no longer warns; orders like "run the full suite" still do

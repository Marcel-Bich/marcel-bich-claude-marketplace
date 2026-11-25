---
bump: patch
---

### Fixed

- Autonomy is paused only by a real owner message. The hourly `[credo-reminder]` paused an
  autonomous run on every delivery because Claude Code shows the typed burst as a
  `<pasted_content ...>` paste with leading blank lines, which the prefix check missed; the
  `[credo-self-restart]` resume prompt paused it too. `credo-autonomy-clear.sh` now unwraps
  the paste and matches all credo prompts on the first non-empty line, and a self-reload or
  self-compact `.` stays exempt when a queued notification consumed the wake file first.

### Added

- Paused hint: while an owner message keeps an autonomous run paused and GO items are open,
  the Stop hook (`credo-autonomy-keepalive.sh`) still lets the turn end but shows the user one
  line per turn end that the agent may stop anytime and how to end the pause
  (`/credo:session-autonomous` or `credo-autonomy-on.sh --session <id>`). Fail open.
- Every later owner message during such a pause nudges the agent to re-arm autonomy itself
  once nothing needs alignment. The `paused` file records the cause (`user-message` vs. a
  deliberate `credo-autonomy-off.sh`), so a finished run never shows the hint.
- Tests: `test-credo-autonomy-paused-hint.sh`; pasted reminder, self-restart, queued `.` and
  pause-cause cases in `test-credo-autonomy-clear.sh`.

---
bump: patch
---

### Fixed

- Autonomous mode with the keep-alive paused: a new PreToolUse hook (`hooks/credo-paused-wake-guard.sh`) denies `ScheduleWakeup` while `credo/autonomy/<session>/paused` exists, and the per-prompt mode line now says "keep-alive PAUSED: no Ask tool, no wake-ups, react to messages only" instead of asking for wake-ups.

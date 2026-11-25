---
bump: minor
---

### Added

- SubagentStop hook `credo-subagent-bg-guard.py`: reads the subagent's own transcript and
  refuses the finish while background tasks it started (`run_in_background` Bash, commands
  moved to the background, Monitor, background Agent) are still running, with a list of
  them (id and short command) and "stop these first, then finish". At most twice per agent,
  then the finish goes through and is logged in `credo/logs/subagent-bg-guard.log`; fails
  open; `CREDO_SUBAGENT_BG_GUARD=0` turns it off (#215).
- `hooks/credo-notify-lib.sh` detects a repeat subagent notification: a prompt made only of
  harness `<task-notification>` blocks that all report a subagent whose task ids were
  already notified in an earlier prompt of the session.

### Changed

- Subagent rule (SubagentStart inject and orchestration brief): background jobs are allowed
  for parallel work, but every background task a subagent started is stopped (TaskStop /
  kill) before its final report; waiting on a queue or lock is a bounded foreground wait or
  a "blocked on X" report, never an endless poll loop. Replaces the former ban on
  background shells for subagents.
- On a repeat subagent notification the credo prompt injects shrink to the time line and
  one short mode line; role, attended reminder, skill nudge and plugin freshness stay silent
  and do not count the turn. The first notification of a task id, Monitor events, shell
  completions, owner prompts and peer messages keep the full bundle; the autonomy pause is
  unchanged.

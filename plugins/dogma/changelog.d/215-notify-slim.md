---
bump: minor
---

### Changed

- A prompt that only re-notifies an already finished subagent (only harness
  `<task-notification>` blocks that all report a subagent, every task id already notified
  earlier in the session) gets no dogma `UserPromptSubmit` inject at all (subagent
  suggestion, prompt reminder incl. the output convention, skill reminder, checklist
  tracking). The first notification of a task id, Monitor events, shell completions, owner
  prompts and peer messages keep every inject. New detector `scripts/lib-notify.sh` with its
  own per-session state in `dogma/notify-seen/`, no credo dependency (#215).

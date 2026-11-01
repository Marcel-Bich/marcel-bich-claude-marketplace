---
bump: patch
---

### Changed

- The periodic reminder is on by default. Active and passive mode get it every 10 turns, autonomous mode every 60 minutes (no config needed)
  Off switches: `reminder.enabled: false`, or per mode `reminder.<mode>.turns: 0` and `reminder.<mode>.minutes: 0`
- The first reminder of each session names these switches once
- `/credo:setup` asks once whether to keep, change or switch off the reminder and states its cost (one full turn per reminder)

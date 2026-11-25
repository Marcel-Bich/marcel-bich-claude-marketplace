---
bump: patch
---

### Added

- Linger proposal for the systemd user services of the LAN relay and the WSL bridge:
  `credo-peer-lan.py status`, `check` and the new `linger` subcommand show the linger
  state and, with `Linger=no`, propose `loginctl enable-linger <user>` with a short risk
  note (keeps running after logout, relay reachable while nobody is logged in, shared
  token and allow-list matter more, says when no shared token is set). credo never runs it.
- `credo-linger-hint.sh` SessionStart hook: the same proposal once per profile (stamp
  `credo/linger-hint.stamp`), silent afterwards and on any error.
- `/credo:setup` Step 12d offers linger; the owner decides and runs the command.

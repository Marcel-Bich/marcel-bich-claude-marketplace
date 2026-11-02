---
bump: patch
---

### Added

- Remote mirror hooks (`hooks/credo-remote-mirror.sh`, off by default): with `remote.mirror_command` set, the owner's real blockers are sent as one JSON event each to that command, in the background. These are Ask-box questions, permission dialogs, question codes of a reply, `Blocker:` lines, `[blocking]` test blocks and the reply to a `[remote chat <id>]` message. The hooks never block, answer or change a tool call.

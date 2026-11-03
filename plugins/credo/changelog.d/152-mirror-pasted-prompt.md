---
bump: patch
---

### Fixed

- Remote mirror: a remote chat prompt that arrives as a paste (credo-owner-type send) is wrapped by Claude Code as `<pasted_content id="...">`; the wrapper is stripped before the `[remote chat <id>]` check, so the reply is mirrored.

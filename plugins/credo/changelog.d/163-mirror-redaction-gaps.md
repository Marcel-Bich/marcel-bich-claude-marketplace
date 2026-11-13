---
bump: patch
---
### Fixed

- The remote mirror masks `NAME = value` (spaces around `=`) and PEM private key bodies; the BEGIN and END lines stay.
- A `Blocker:` line inside a fenced code block no longer starts a blocker event; before, its block ran on past the closing fence, and a real Blocker line with the same text was then skipped as a duplicate.
- The session legend says that the blocker text is the Blocker line plus the lines below it.
- The remote mirror no longer prints a shell error when no session-mode file exists.
- `test-credo-peer-check.sh` no longer fails 5 tests with a long TMPDIR. Its socket fixtures now live under /tmp, because AF_UNIX paths are limited to 107 bytes.

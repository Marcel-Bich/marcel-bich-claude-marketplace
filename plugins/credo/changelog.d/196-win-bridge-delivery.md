---
bump: patch
---

### Fixed

- WSL -> Windows peer bridge: a message is reported as sent only after the Windows half
  wrote it into the target session's pipe; a message that could not be delivered now
  resets the sender's connection (SendMessage reports a failure) instead of being
  silently dropped after a false success. Transient connect failures are retried briefly
- Bridge log names the cause when a Windows session's inbox denies access. A session
  running elevated (as administrator) cannot be written to by the non-elevated bridge,
  documented as a known limit
- Windows mirror descriptors of WSL sessions are updated again; every update failed with
  "the path is not of a legal form" because PowerShell passed an empty backup path to
  File.Replace

---
bump: patch
---

### Fixed

- Periodic reminder: a worker of an older credo version now really is replaced at the next prompt. The 0.84.31 check sat behind a "worker running" gate that was already true for the old worker, so the replacement never ran.

---
bump: patch
---

### Fixed

- Periodic reminder: a running worker of an older credo version is replaced at the next prompt. A plugin reload does not restart the detached worker, so it kept running the old delivery code after an update.

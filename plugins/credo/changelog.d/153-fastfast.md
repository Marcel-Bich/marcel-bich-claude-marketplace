---
bump: patch
---

### Added

- Shorthand `fastfast`: speed order anywhere in a message. Do it immediately and skip audits, full test suites, verify runs and detours (commit gate and hard safety rules stay); catch up the checks afterwards in the item. `deploy fastfast` deploys the current main to live/prod and the test instance through the project's deploy path.

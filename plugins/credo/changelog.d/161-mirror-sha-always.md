---
bump: patch
---

### Changed

- Remote mirror: every permission event now carries `sha256` of the full unmasked command (before only cut ones), and `masked: true` when the secret masking changed the summary, so a sink can bind a masked or cut command exactly.

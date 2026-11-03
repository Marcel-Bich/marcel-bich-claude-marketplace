---
bump: patch
---

### Changed

- fastfast never adds a builder slot: the builder cap (config or `.credo/RULES.md`), the same-files-never-parallel rule and the resource gate stay in force; a fastfast item only moves to the front of the build queue, waits for a free slot when all are taken, and its builders run only the relevant tests (full suite once at merge).

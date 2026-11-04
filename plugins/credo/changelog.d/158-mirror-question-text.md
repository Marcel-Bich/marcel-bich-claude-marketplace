---
bump: patch
---

### Changed

- Remote mirror: `question_codes` and `test_blocking` events carry the full block below the heading as `text` (redacted, at most 4000 characters, `cut: true` when shortened)
- Remote mirror: permission summaries are cut at 2000 characters (was 500); a cut summary carries `cut: true` and `sha256` of the full command

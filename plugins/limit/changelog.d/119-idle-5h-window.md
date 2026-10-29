---
bump: patch
---

### Fixed

- A limit window without usage (`resets_at` null, utilization 0) no longer shows `invalid_response` and hides the other API lines; the line shows its percent without a reset part, and the highscore view omits the "resets in" note

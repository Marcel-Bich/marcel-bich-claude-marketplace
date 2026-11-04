---
bump: patch
---

### Changed

- Remote mirror: a `blocker` event carries `text` with the Blocker line and the lines below it, up to the next heading, code heading or Blocker line (redacted, at most 4000 characters, `cut: true` when shortened). Its first line is unchanged.

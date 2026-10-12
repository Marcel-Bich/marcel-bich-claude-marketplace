---
bump: minor
---

### Added

- New DOGMA-PERMISSIONS.md setting `(§b4dk)` "Discard uncommitted changes" for `git restore`, `git reset --hard`, `git checkout` (paths, `.`, `-f`), `git switch --discard-changes` and `git stash drop|clear`. Default `[?]`, independent of the delete setting `(§0lgy)`; `git clean` stays under the delete setting.

### Changed

- The discard commands are no longer governed by the delete setting. A missing line for `(§b4dk)` in an existing DOGMA-PERMISSIONS.md counts as `[?]`, every other missing setting keeps its default.
- dogma shows an update notice at session start (until it is answered) that points to `/dogma:permissions` and `/dogma:sync`.

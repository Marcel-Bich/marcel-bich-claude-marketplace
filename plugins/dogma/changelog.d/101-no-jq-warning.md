---
bump: patch
---

### Added

- Session-start warning when `jq` is missing: dogma's protection hooks (delete guard, git permissions, dependency verification) are off without it, so the user is urged to install jq (`hooks/jq-missing-warn.sh`)

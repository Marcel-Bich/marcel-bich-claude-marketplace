---
bump: patch
---

### Added

- `scripts/git-scope.sh [dir]` prints the owner/repo scope (`<host>/<owner>/<repo>`) of the `origin` remote without showing the remote URL, so agents can tell repositories of different owners apart while `git remote -v` and `git remote get-url` stay blocked

### Changed

- The block message for remote URL output (`git remote -v`, `git remote show`, `git remote get-url`, `git config` on remote URLs, `git ls-remote --get-url`) names the absolute path of `git-scope.sh`

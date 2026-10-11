---
bump: patch
---

### Fixed

- `git-remote-safe.sh url` no longer prints userinfo (`user:token@`), query string or fragment of the remote URL; a URL whose userinfo cannot be told apart is refused
- `git-remote-safe.sh` reads the remote with git (origin, fallback: the first remote), so it works in worktrees; `host`, `owner`, `repo` and `owner-repo` come from `git-scope.sh`

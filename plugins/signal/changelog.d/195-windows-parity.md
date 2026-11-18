---
bump: patch
---

### Fixed

- Every hook command quotes `${CLAUDE_PLUGIN_ROOT}`, so the hooks still run when the plugin root
  contains a space (for example a Windows profile like `C:\Users\First Last`)

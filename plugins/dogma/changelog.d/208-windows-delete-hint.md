---
bump: patch
---

### Changed

- The "Windows delete or format command blocked" deny names the allowed route for own temp
  files: keep them in the session TMPDIR with the `wslpath -w` path for Windows tools, or remove a
  Write-created one with credo's `credo-cleanup.py own-rm /mnt/<drive>/<path>`; the block itself
  is unchanged

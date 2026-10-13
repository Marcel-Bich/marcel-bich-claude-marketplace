---
bump: minor
---

### Changed

- The delete guard denies only the resolved hard list (home first level, paths up to depth 3 outside the temp roots, mounted storage up to depth 4, Windows profile and system paths, mount points, whole repositories). Everything else in the delete domain, including targets that cannot be resolved for sure, follows the delete permission in DOGMA-PERMISSIONS.md.
- A plain literal variable assigned earlier in the same command (`R=/path; rm -- "$R/file"`) is resolved for the delete checks.

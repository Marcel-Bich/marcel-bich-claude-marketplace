---
bump: minor
---

### Changed

- The delete guard denies only the resolved hard list (home first level, paths up to depth 3 outside the temp roots, mounted storage up to depth 4, Windows profile and system paths, mount points, whole repositories). Everything else in the delete domain, including targets that cannot be resolved for sure, follows the delete permission in DOGMA-PERMISSIONS.md.
- A variable in a delete target is judged by every value it can have in the command (its environment value, or empty when unset, and every literal value assigned to it there): if one of them is on the hard list the target is denied, a single certain value that is not hard follows the delete permission.

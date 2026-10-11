---
bump: patch
---

### Fixed

- Deleting a file or folder deeper below a Windows drive or `/media` (for example `rm /mnt/d/data/proj/models/x.gguf` or `rm -r /mnt/d/data/proj/old`) is no longer refused by the delete floor; the normal file protection and the delete permission decide
- The delete floor below `/mnt` and `/media` still refuses the mount point, the drive and its first level, a Windows user profile root and its first level, Windows system, persistence and profile paths, declared mounts and network shares

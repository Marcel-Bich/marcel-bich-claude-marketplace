---
bump: patch
---

### Fixed

- Network shares and USB sticks below `/mnt` and `/media` no longer protect their whole subtree from deletes: like a Windows drive, the mount point and the levels down to depth 3 (for example `/mnt/nas/share` and `/media/usb/folder`) stay refused, deeper files are ordinary and the file protection and the delete permission decide
- A mount point below `/mnt` or `/media` stays refused at any depth; mounts below the home and declared mounts (`CLAUDE_MB_DOGMA_PROTECTED_MOUNTS`) keep their whole subtree protected

---
bump: patch
---

### Fixed

- `pair-reset` removes the peer's trust entries before the pairing; when a trust list cannot be read or an entry cannot be removed, the reset exits 1 and the pairing stays in place
- Keystore dirs and the holder relay socket are created without a process-wide `os.umask` change (the daemon no longer flips the umask while other threads run)

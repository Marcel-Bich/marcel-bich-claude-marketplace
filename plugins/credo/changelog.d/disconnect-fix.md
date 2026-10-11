---
bump: patch
---

### Fixed

- LAN relay `disconnect-all` removes only pairing records (`peer-<id>.json` with a 32 hex char peer id) from a keystore dir. Other `peer-*.json` files in that dir, such as `peer-lan.json` or `peer-lan-trust.json` when `keys_dir` points at a profile's `credo/` dir, are no longer deleted or counted as pairings
- The relay's periodic pairing copy sync had the same name match and no longer removes those files either
- When `disconnect-all` fails while clearing a profile, a relay that was running is still restarted, and the command exits non-zero
- A quote in the scheduled task name is escaped in the `--full` Windows uninstall command

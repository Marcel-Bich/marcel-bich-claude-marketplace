---
bump: minor
---

### Changed

- The LAN relay serves every Claude Code profile of the machine. The roster names the profile of each local session, every remote session is mirrored into each profile's `sessions/`, and a message reaches a session in any profile.
- Trusted peers are checked in the target session's own profile. A grant made in one profile never applies to a session in another profile.
- Duplicate caption detection covers all profiles of the sending machine.
- The pairing record is copied into the keystore of every profile of the machine. Trust is still granted per profile with `trust add` run in that profile, and `pair-reset` removes a pairing and the peer's trust from every profile.

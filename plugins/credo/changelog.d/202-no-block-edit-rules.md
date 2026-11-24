---
bump: patch
---

### Changed

- The NO-BLOCK COMMANDS subagent inject and the orchestration brief checklist name the prompt-free forms:
  multi-file edits with the Edit tool per file and a literal path instead of `sed -i` loops on `$var` targets,
  the Read tool instead of `cat` loops, no for-loops over files, redirects only into the session TMPDIR or
  scratchpad
- The session-autonomous skill notes that dogma now denies an unconfirmed git add/commit/push while autonomy
  is active, so the agent sends the showstopper ntfy itself and stops

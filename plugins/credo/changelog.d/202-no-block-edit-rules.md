---
bump: patch
---

### Changed

- The NO-BLOCK COMMANDS subagent inject and the orchestration brief checklist name the prompt-free forms:
  multi-file edits with the Edit tool per file and a literal path instead of `sed -i` loops on `$var` targets,
  the Read tool instead of `cat` loops, no for-loops over files, redirects only into the session TMPDIR or
  scratchpad

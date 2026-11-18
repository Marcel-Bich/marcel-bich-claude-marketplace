---
bump: patch
---

### Fixed

- Native Windows (Git Bash): local token counting works. A native `jq.exe` (e.g. from winget) writes CRLF line ends, and the stray `\r` broke offsets, pending flags, completeness and every number read back from jq; jq now runs with `-b` there (or its `\r` is stripped when the build has no `-b`). The local highscore line and the Est100% samples depend on this
- Native Windows: `--arg` values that look like paths are no longer rewritten by Git Bash into `C:/...` before jq sees them, so ledger lookups by transcript path and the pruning of deleted transcripts match the stored keys
- Native Windows: a `transcript_path` in Windows form (`C:\Users\...`) maps to the same ledger entry as its POSIX spelling, so it is not counted twice
- A `CLAUDE_CONFIG_DIR` with backslashes (`C:\Users\me\.claude-x`) keeps its profile name in every limit script; the combined-statusline setup writes it as `C:/...` into `statusLine.command`
- Plan detection, the work-repo hooks, the GLM statusline and the refresh-interval hook get the same jq fix on native Windows
- With jq 1.7 or newer, history entries and the highscore view show `0` / `9` again instead of the literal `0.0` / `9.0`

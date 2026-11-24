---
bump: minor
---

### Added

- Inline code guard `credo-inline-guard.sh` (PreToolUse on `Bash` and `*browser_run_code*`, subagent tool calls included): denies inline interpreter code (`python3 -c`, `node -e`, `perl -e`, `ruby -e`, `php -r`, `deno eval`, a heredoc, here-string or pipe into an interpreter) and inline Playwright `browser_run_code` code longer than `guards.inline_code_max` characters (default 1500, `0` = off, env `CREDO_INLINE_CODE_MAX` overrides). The reason names the alternative: Write a script file and run it in a separate call with a literal path, or pass `filename` to `browser_run_code`. Only the size counts; commands without interpreter code and heredocs into files are never hit; any error fails open
- Subagent inject and orchestration brief checklist carry a NO-BLOCK COMMANDS block: no long inline interpreter code, never write and run a file in one command, no `VAR=$(...); $VAR/script` calls, `./node_modules/.bin/<tool>` over `npx`, `browser_run_code` with `filename`

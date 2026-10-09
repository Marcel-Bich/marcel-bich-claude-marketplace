# limit

Live API usage in Claude Code statusline - colored progress bars, Git info, tokens, session metrics, device tracking, and more.

## Features

**API Usage Tracking**
- Real API data from Anthropic (same as `/usage`)
- Colored progress bars with signal colors (gray/green/yellow/orange/red)
- Multiple limits: 5-hour, 7-day, Sonnet, Extra Credits, plus further entries of the API's `limits[]` list (e.g. per-model `weekly_scoped` limits, shown as `7d <Model>`)
- Reset times for each limit (minute-precise); after a reset time has passed the bar shows `0.0% ... (reset)` instead of the previous window's value
- `[stale 12m]` marks API numbers older than `CLAUDE_MB_LIMIT_STALE_AFTER` seconds
- Averages from the local history: `[AvgPeak:X%]` average peak per completed window, `[Avg:Y%/h]` (5h) / `[Avg:Y%/d]` (7d) average consumption including idle time

**Highscore Tracking** (enabled by default, disable with `CLAUDE_MB_LIMIT_LOCAL=false`)
- Tracks highest token usage per plan (max20, max5, pro)
- Separate highscores for 5h and 7d windows
- Automatic plan detection from credentials
- `[Est100%:X]` on the device line: continuous estimate of the token count at 100 % API utilization (median of this device's tokens / (API% / 100) over samples at >= 20 % in the current window; `~` = value of the previous window). Per device: a lower bound when other devices use the same account at the same time

**Extended Features**
- CWD (Current Working Directory)
- Git: branch, worktree name, changes (+insertions, -deletions) with colors. The line is prefixed with `git: <parent>/<repo>` showing the resolved target repo. The target is resolved in this order: (1) the repo the MAIN agent last worked in - captured live from its Edit/Write and Bash `cd` / `git -C` calls via a PostToolUse hook (session-affine, subagents excluded), so the line follows the agent into whatever repo it touches even from a non-git hub directory; (2) the repo at the cwd; (3) the credo session-pin. Sources 1 and 3 are soft dependencies - without them, only cwd-based discovery is used
- Token metrics of the current session (main agent + its subagents, from the transcripts): Input (incl. cache writes), Output, Cached (cache reads), Total. Without a readable ledger the line is labelled `LastReq` and shows the last request from Claude Code's stdin
- Context usage with percentage of max and usable (before auto-compact)
- Session timing: Total duration, API time
- Model line: `<Model> | <Effort> | <style> | LifetimeTotal: ... | Device: ...` - the live session effort level (Low/Medium/High/XHigh/Max) is read from the statusline stdin `effort.level` and only shown for models that support reasoning effort
- Session ID display
- Session caption (from /rename, summary, or first user prompt)

**Agent Context Injection** (enabled by default, disable with `CLAUDE_MB_LIMIT_INJECT=false`)
- Lets the agent read its own context fill, limits and cost (it cannot see the statusline)
- Context fill, window size and limits from Claude Code's own data (1M beta detected automatically) - accurate even during autonomous runs
- Auto-runs a skill of your choice at configurable context-fill thresholds (you wire up which skill)

**Platform Support**
- Cross-platform: Linux, macOS, and WSL2

**Provider Support**
- Native Anthropic API: full feature set (above)
- z.ai / GLM Coding Plan (`ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`): auto-detected, shows GLM quota (5h / weekly tokens + monthly MCP) in the same bar/color style, plus context, git, session info and the agent context injection. Anthropic-only parts (OAuth usage endpoint, lifetime token/cost accounting) are skipped.
- Other custom `ANTHROPIC_BASE_URL` providers: rendered without provider limits (no quota endpoint known), everything else still works.
- Detection is automatic: if `ANTHROPIC_BASE_URL` is empty or points to `api.anthropic.com` the native path runs unchanged; any other base URL uses the provider statusline. When the `projects/` directory is shared between an Anthropic and a non-Anthropic profile, only native `claude-*` models are counted in the token accounting (foreign models like GLM are never counted as Anthropic usage).

## Commands

- `/limit:highscore` - Display highscores, Est100%, window tokens, per-model lifetime breakdown and averages

## Requirements

- `jq` - JSON processor (install: `sudo apt install jq`)

## Installation

```bash
claude plugin marketplace add Marcel-Bich/marcel-bich-claude-marketplace
claude plugin install limit@marcel-bich-claude-marketplace
```

After installation, add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/usage-statusline.sh",
    "refreshInterval": 20
  }
}
```

`refreshInterval` (seconds) makes Claude Code re-render the statusline on a timer, not
just on assistant messages. **It must be LARGER than how long your statusline takes to
render** - Claude Code cancels an in-flight render when the next tick fires, so a value
below the render time makes the statusline never appear. The default is 20 because the
ccstatusline-combined setup calls `npx` and can take several seconds; a plain, fast
statusline can safely go lower. Without it the statusline goes stale while the main session
is idle - for example during a long-running subagent - so the remaining budget you see
can be minutes out of date. With it the usage stays live even while a subagent works.
The statusline is token-free and reads a cache, and the token-owning refresh has its own
throttle (a floor plus a jittered 90-150s cadence, guarded by a lock), so a low interval
does NOT increase API calls. `setup-combined-statusline.sh` writes this field for you.

If you set the statusline up before this field existed AND the limit plugin is enabled, a
SessionStart hook detects the gap and adds `refreshInterval` for you (with a backup; a
restart then activates it). Set `CLAUDE_MB_LIMIT_AUTO_REFRESH_INTERVAL=0` to opt out, or to
a positive integer to choose the value. Plugin hooks do not run when the plugin is disabled,
so a statusline-only setup (plugin installed but disabled) is NOT auto-healed - add
`refreshInterval` manually as shown above.

**What updates live, and what counts subagents.** On each render the script recomputes its
self-sourced values: the 5h / 7d / weekly bars (account-wide API usage, so subagent
consumption IS included), session timing, git, and the JSONL-based lifetime token/cost
totals (main + subagents). These stay current on every `refreshInterval` tick, even while a
subagent runs. The values Claude Code passes on stdin behave differently: the session cost
(`total_cost_usd`) is session-wide and so does include subagent API calls, whereas the
context-window tokens and percentage reflect only the main conversation's most recent API
response - subagents have their own separate context windows and are not summed into it.
Measured behavior: the session cost updates live on each render while a subagent runs - it
does not wait for the subagent to return (the main context stays frozen meanwhile, since it
reflects only the main conversation). So the session cost, the account-wide 5h / 7d bars, and
the lifetime totals all track subagent consumption live; only the context-window
tokens/percentage stay main-only.

## Configuration

All features can be toggled via environment variables. Export them in your shell profile or set them before running Claude Code.

**Feature Toggles** (all default to `true` unless noted):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_MODEL` | true | Show current model with effort level, style and cost |
| `CLAUDE_MB_LIMIT_5H` | true | Show 5-hour limit |
| `CLAUDE_MB_LIMIT_7D` | true | Show 7-day limit |
| `CLAUDE_MB_LIMIT_SONNET` | true | Show Sonnet-specific limit |
| `CLAUDE_MB_LIMIT_EXTRA` | true | Show extra credits usage |
| `CLAUDE_MB_LIMIT_CWD` | true | Show current working directory |
| `CLAUDE_MB_LIMIT_GIT` | true | Show git branch, worktree, changes |
| `CLAUDE_MB_LIMIT_TOKENS` | true | Show token metrics |
| `CLAUDE_MB_LIMIT_CTX` | true | Show context usage |
| `CLAUDE_MB_LIMIT_SESSION` | true | Show session timing |
| `CLAUDE_MB_LIMIT_SESSION_ID` | true | Show session ID |
| `CLAUDE_MB_LIMIT_CAPTION` | true | Show session caption (from /rename, summary, or first prompt) |
| `CLAUDE_MB_LIMIT_PROFILE` | true | Show active profile name |
| `CLAUDE_MB_LIMIT_COLORS` | true | Enable colored output |
| `CLAUDE_MB_LIMIT_PROGRESS` | true | Show progress bars |
| `CLAUDE_MB_LIMIT_RESET` | true | Show reset times |
| `CLAUDE_MB_LIMIT_SEPARATORS` | true | Show visual separators |
| `CLAUDE_MB_LIMIT_OPUS` | true | Show Opus limit (future-ready) |

**Highscore Settings** (enabled by default):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_LOCAL` | true | Enable highscore tracking |
| `CLAUDE_MB_LIMIT_DEVICE_LABEL` | hostname | Custom device label for display |

**Other Settings**:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_REFRESH_CADENCE` | 150 | Base seconds between usage-API refreshes; plus 0-60s jitter, so 150-210s (avg ~180). Raise it if you hit usage-endpoint rate limits |
| `CLAUDE_MB_LIMIT_CACHE_AGE` | 120 | Seconds between global scans of the JSONL transcripts for the token ledger (no API calls; runs detached, never blocks the render) |
| `CLAUDE_MB_LIMIT_SESSION_SCAN` | 10 | Minimum seconds between scans of the current session transcript |
| `CLAUDE_MB_LIMIT_SESSION_SCAN_BYTES` | 2097152 | About this many bytes of the current session transcript are read per render (a single longer line is read whole); a larger backlog (e.g. right after an upgrade) is read over several renders and by the detached scan |
| `CLAUDE_MB_LIMIT_BG_SCAN_BUDGET` | 25 | Time budget (seconds) of one detached global scan; a first backfill continues on the next scans |
| `CLAUDE_MB_LIMIT_SCAN_BYTES` | 0 | Byte budget of one global scan (0 = only the time budget applies) |
| `CLAUDE_MB_LIMIT_STALE_AFTER` | 600 | Mark API numbers as `[stale ...]` when the usage cache is older than this |
| `CLAUDE_MB_LIMIT_SCOPED` | true | Show further limits from the API's `limits[]` list (e.g. `weekly_scoped`) |
| `CLAUDE_MB_LIMIT_EST_MIN_PCT` | 20 | Minimum API utilization for an Est100% sample |
| `CLAUDE_MB_LIMIT_EST_MAX_AGE` | 120 | Est100% samples only use API numbers younger than this many seconds |
| `CLAUDE_MB_LIMIT_DEFAULT_COLOR` | `\033[90m` | Default color (ANSI escape sequence) |
| `CLAUDE_MB_LIMIT_SHOW_ERRORS` | false | Show "limit: error" on failures |
| `CLAUDE_MB_LIMIT_AVERAGE` | true | Show `[AvgPeak:...]` / `[Avg:...]` averages |
| `CLAUDE_MB_LIMIT_DEBUG` | false | Enable debug logging to `/tmp/claude-mb-limit-debug_${PROFILE_NAME}.log` (`true`, `1`, `yes` or `on`; same flag for every script) |
| `CLAUDE_MB_LIMIT_HISTORY_ENABLED` | true | Enable history tracking for average display |
| `CLAUDE_MB_LIMIT_HISTORY_INTERVAL` | 600 | Minimum seconds between history writes (10 min) |
| `CLAUDE_MB_LIMIT_HISTORY_DAYS` | 28 | History retention in days |
| `CLAUDE_MB_LIMIT_PROGRESSBAR_MODE` | auto-compact | Progress bar mode. `auto-compact`: 100% = the auto-compact trigger point (a tacho); `full`: 100% = the full context window |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | (unset) | Exact auto-compact trigger point in tokens. Highest precedence; capped at the window size. No tilde |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | (unset) | Exact auto-compact trigger as a percentage (1-100) of the full window. No tilde |
| `CLAUDE_MB_LIMIT_AUTOCOMPACT_FALLBACK_PCT` | 83 | Conservative fallback percentage used only when the real trigger is unknown. Shown with a leading `~` (estimated) |

**Agent Context Injection** (lets the agent read its own usage and act on it):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MB_LIMIT_CTX_CACHE` | true | Statusline writes a per-session cache `/tmp/claude-mb-context-cache_${session_id}.json` (window size, limits, cost) |
| `CLAUDE_MB_LIMIT_INJECT` | true | Inject hook injects a short status line into the agent's context (UserPromptSubmit + PostToolUse) |
| `CLAUDE_MB_LIMIT_COMPACT_SKILL` | (unset) | The skill the agent should run when a threshold is reached, e.g. `/my-skill`. Empty = status only, no skill named |
| `CLAUDE_MB_LIMIT_INJECT_INTERVAL` | 120 | Minimum seconds between routine status injects (throttle) |
| `CLAUDE_MB_LIMIT_INJECT_DELTA` | 1 | Minimum change (pct points) in ctx/5h/weekly for a routine re-inject (delta-guard) - quiet phases inject nothing |
| `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS` | 80,92 | Comma-separated %% of the way to auto-compact at which the skill hint fires (any count, e.g. `33,66,92`) |
| `CLAUDE_MB_LIMIT_INJECT_MAX_AGE` | 300 | Ignore the cache (inject nothing) if older than this many seconds - avoids reporting stale numbers |

**Multi-Account Support:**

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Base directory for Claude config |

When using multiple accounts, set `CLAUDE_CONFIG_DIR` before starting Claude Code:

```bash
CLAUDE_CONFIG_DIR=~/.claude-work claude
```

Each profile gets separate state files (highscores, history, cache).

## Token Accounting

All local token numbers (session line, window tokens, highscores, Est100%,
LifetimeTotal) come from one ledger built from the Claude Code transcripts
(`projects/<project>/<session>.jsonl` and `.../<session>/subagents/agent-*.jsonl`):

- **One count per API message.** Claude Code writes one transcript line per
  content block (thinking, text, tool use) and repeats the message's usage on
  each; lines are deduplicated by `message.id` + `requestId` (last line wins).
  Known limit: the deduplication works per transcript file. The rare API
  message that appears in two files (e.g. a subagent sidechain and its parent
  transcript) is counted in both - about 1 % extra in observed transcripts.
- **One spelling per transcript.** Paths are canonicalized (duplicate slashes,
  `/./` and symlinked directories), so a transcript is never counted twice
  under two spellings, e.g. with a trailing slash in `CLAUDE_CONFIG_DIR`.
- **Work tokens** = input + output + cache writes. Cache reads (typically
  ~99 % of the raw volume) are tracked and shown separately, never added 1:1.
- **Windows from timestamps.** Window tokens are the sum of messages since the
  window start (`resets_at` - 5h / 7d), so there is no per-render delta and no
  baseline that a lost write could reset. A window reset is also detected when
  the utilization drops sharply with an unchanged `resets_at`, or when the
  reset time has passed.
- **Cost** per concrete model id (cache writes priced by TTL). Models without a
  known price are not guessed: the cost is shown as `$X+n/a`.
- State writes are atomic and locked, so parallel sessions cannot corrupt them;
  an unreadable state skips the local values for one render instead of showing 0.

**Ledger file:** `~/.claude/marcel-bich-claude-marketplace/limit/limit-ledger_${PROFILE_NAME}.json`.
After an upgrade it is backfilled from all existing transcripts in the
background (a few detached scans). Reading is linear in the transcript size
(a 34 MB transcript takes about 2 s) and always bounded: the render reads
about `CLAUDE_MB_LIMIT_SESSION_SCAN_BYTES` of the current transcript (a single
longer line is read whole), the detached scan stops at its time budget and
reads small transcripts in batches (thousands per run), and both resume from
the stored byte offsets. Entries of deleted transcripts are pruned; the
lifetime totals keep their tokens. Until the backfill is complete the window sums are too low, so no
Est100% samples are taken (`/limit:highscore` says so while it runs).

## Highscore Concept

Instead of complex calibration, we track the highest token usage ever measured on this device:

- **Highscores can only increase, never decrease** - Your record only gets broken by higher usage
- **Converges to real limit over time** - The more you work, the closer you get to the real API limit
- **Separate highscores per plan** - Switching plans (max20/max5/pro) uses the correct highscore for each
- **5h and 7d are independent records** - Each window has its own highscore

**Est100%:** a continuous estimate of where 100 % lies, in work tokens: the median of `window_tokens / (API% / 100)` over samples taken at >= 20 % utilization in the current window. It replaces the former LimitAt easter egg, which compared counts from different schemes and almost never refreshed.

Est100% is a per-device value and is therefore shown on the device line (`... [Highest:...] [Est100%:X] (device)`). The tokens come from this device's transcripts only - other devices keep their own `~/.claude` and cannot be read from here - while the API percentage is account-wide. With parallel use on other devices the estimate is a lower bound. Samples are skipped while the transcript backfill is incomplete (tokens missing, ratio too low) and while the API numbers are older than `CLAUDE_MB_LIMIT_EST_MAX_AGE` (old percentage, ratio too high).

Upgrading to the ledger-based accounting resets highscores once (the old values were measured in an inflated unit); the old state is kept as `.bak`.

**State file:** `~/.claude/marcel-bich-claude-marketplace/limit/limit-highscore-state_${PROFILE_NAME}.json`

## Agent Context Injection

The agent (Claude) cannot read the statusline - it is a separate process. This
feature gives the running agent its own resource usage so it can act on it (for
example run a securing or compacting skill before an auto-compact loses progress),
even during long autonomous runs where no user prompts arrive.

You decide what runs at the thresholds: set `CLAUDE_MB_LIMIT_COMPACT_SKILL` to the
skill you want auto-run (any skill, e.g. `/my-skill`). This plugin ships no skill of
its own - if the variable is unset, the agent just gets a "secure progress" hint
without a skill name. Set the threshold points with `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS`
(comma-separated, any number of values, e.g. `80,92` or `33,66,92`).

How it works:

- The **statusline** writes a small per-session cache `/tmp/claude-mb-context-cache_${session_id}.json`
  with the values Claude Code hands only to the statusline: the context fill
  percentage and window size (`context_window_size` is canonical - it reflects model
  switches AND the 1M beta mid-session automatically, no lookup table needed), plus
  the 5h / weekly limits and session cost. One file per session, so parallel sessions
  never overwrite each other.
- The **inject hook** (`scripts/inject-status.sh`, on `UserPromptSubmit` + `PostToolUse`)
  reads that cache and injects a short status line via `additionalContext` - visible
  to the agent, not flooding the user chat. It skips silently if the cache is missing
  or stale (`CLAUDE_MB_LIMIT_INJECT_MAX_AGE`), so it never reports outdated numbers.
- It is **throttled** (`CLAUDE_MB_LIMIT_INJECT_INTERVAL`) and **delta-guarded**
  (`CLAUDE_MB_LIMIT_INJECT_DELTA`): a routine status is injected only when enough time
  has passed AND ctx/5h/weekly actually moved, so quiet phases do not grow the context
  with unchanged lines. Each threshold in `CLAUDE_MB_LIMIT_INJECT_THRESHOLDS` fires once
  regardless and adds an action hint to run the skill from `CLAUDE_MB_LIMIT_COMPACT_SKILL`.
  Thresholds reset after a compact drops the fill.

Example injected line (with `CLAUDE_MB_LIMIT_COMPACT_SKILL=/my-skill`):

```
[limit] Context ~85% (170k/200k) | 5h 64% | Weekly 31% | $4.20
ACTION: Context at >= 80% of the way to auto-compact - run /my-skill now to secure progress before it triggers.
```

The percentage is the tacho: the fill relative to the auto-compact trigger point,
the same number the statusline progress bar shows. The token pair is `fill / trigger
point`. A leading `~` means the trigger point is an estimate (the conservative
fallback) rather than a value read from a setting or env override.

## Debug Scripts

The plugin includes debug scripts for troubleshooting:

- `debug-progress.sh` - Debug progress bar rendering

Run from the plugin scripts directory:

```bash
~/.claude/plugins/marketplaces/marcel-bich-claude-marketplace/plugins/limit/scripts/debug-progress.sh
```

## Documentation

For additional documentation, ccstatusline integration, and troubleshooting:

**[View Documentation on Wiki](https://github.com/Marcel-Bich/marcel-bich-claude-marketplace/wiki/Claude-Code-Limit-Plugin)**

## License

MIT - See [LICENSE](LICENSE) for full terms.

---

<details>
<summary>Keywords / Tags</summary>

Claude Code, Claude Code Plugin, Claude Code Extension, Claude Code Usage, Claude Code Limit, Claude Code Rate Limit, Claude Code API Usage, Claude Code Statusline, Claude Code Status Bar, Claude Code Progress Bar, Claude Code Utilization, Claude Code Quota, Claude Code Credits, Claude Code Tokens, Claude Code Cost, Claude Code Billing, Claude Code Subscription, Claude Code Max, Claude Code Pro, Claude Code 5h Limit, Claude Code 7d Limit, Claude Code Opus Limit, Claude Code Sonnet Limit, Claude Code Reset Time, Anthropic CLI, Anthropic Plugin, Anthropic Extension, Anthropic Claude, Anthropic AI, Anthropic API, Anthropic OAuth, Anthropic Usage, Anthropic Billing, Anthropic Limits, Anthropic Rate Limit, AI Agent Usage, AI Agent Limits, AI Agent Quota, AI Agent Cost, AI Code Assistant, AI Coding, AI Programming, AI Development, API Usage Tracking, API Rate Limit, API Quota, API Credits, Usage Display, Usage Monitor, Usage Tracker, Live Usage, Real-time Usage, statusline, Statusline, Status Bar, Progress Bar, Terminal Statusline, CLI Statusline, Colored Progress Bar, ANSI Colors, WSL, WSL2, Windows Subsystem Linux, Windows 10, Windows 11, Linux, macOS, Ubuntu, Debian, Cross Platform, ccstatusline, OAuth Token, Credentials, API Key, Cache, Rate Limiting, jq, curl, bash, Shell Script, Marcel Bich, marcel-bich-claude-marketplace, limit plugin, usage plugin, rate limit plugin, Git Worktree, Git Branch, Git Changes, Context Window, Session Tracking

</details>

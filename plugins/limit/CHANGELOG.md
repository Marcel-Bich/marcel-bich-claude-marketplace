Changelog of the limit plugin. Newest first. Months group releases; no day dates. Releases up to v2.35 are summarized by minor version.

# 2026-10

## v2

### v2.36

#### v2.36.0

##### Added

- One deduplicated token ledger (`scripts/usage-ledger.sh`) for main agent and subagents: transcript lines are counted once per API message (`message.id` + `requestId`, last line wins), read incrementally without consuming a partial trailing line, and summed into 5-minute buckets so window tokens come from timestamps
- `[Est100%:X]` on the 5h / 7d device lines: median of window tokens / (API% / 100) over samples at >= 20 % in the current window, falling back to the previous window (`~`). It is a per-device value (only this device's transcripts are readable, API% is account-wide) and a lower bound with parallel use on other devices; no samples are taken while the transcript backfill is incomplete or the API numbers are older than `CLAUDE_MB_LIMIT_EST_MAX_AGE` (default 120 s)
- `[AvgPeak:X%]` (average peak per completed window) and `[Avg:Y%/h]` / `[Avg:Y%/d]` (average consumption incl. idle time) from the history; history entries now record `resets_at`
- Further limits from the API's `limits[]` list (e.g. `weekly_scoped` per model) as their own lines (`CLAUDE_MB_LIMIT_SCOPED`)
- `[stale Xm]` when the usage cache is older than `CLAUDE_MB_LIMIT_STALE_AFTER` (default 600 s); after `resets_at` a limit shows `0.0% ... (reset)`
- `scripts/state-io.sh`: shared lock, atomic write, safe read, debug flag, half-up rounding and backoff helpers
- Fixture tests: `test-usage-ledger.sh` (duplicated message ids, split messages, partial lines, parallel scans, pricing), `test-local-tracking.sh` (reset detection incl. utilization drop with unchanged `resets_at`, parallel writers, Est100%, averages, backoff), `test-statusline-render.sh` (end-to-end render, parallel renders)

##### Changed

- Tokens line shows the session sums (main agent + its subagents) from the ledger: Input incl. cache writes, Output, Cached (cache reads); it falls back to `LastReq` (last request from stdin) when the ledger is unreadable
- Window tokens, highscores and LifetimeTotal count work tokens (input + output + cache writes); cache reads are tracked and shown separately
- LifetimeTotal and `/limit:highscore` price usage per concrete model id with cache writes by TTL; models without a known price show `$X+n/a` instead of Opus pricing
- Window resets are also detected on a sharp utilization drop (> 20 points or below half) with an unchanged `resets_at`, and when `resets_at` has passed
- All state read-modify-writes run under a lock with atomic writes; an unreadable state skips the local values for one render instead of counting from 0
- A 429 stores one `retry_at`; the statusline shows exactly that countdown and `refresh-usage.sh` does not call the API before it
- `CLAUDE_MB_LIMIT_DEBUG` accepts `true`/`1`/`yes`/`on` in every script
- `/limit:highscore` uses `CLAUDE_MB_LIMIT_DEVICE_LABEL` and shows Est100%, window tokens with cache reads and a per-model lifetime breakdown
- Transcript reading is linear in the bytes read (grep prefilter, one streaming jq pass, one awk pass for dedup and sums) and always bounded: the render reads about `CLAUDE_MB_LIMIT_SESSION_SCAN_BYTES` (default 2 MiB) of the current transcript per render (a single longer line is read whole), the global scan runs detached with a time budget (default 25 s, checked with millisecond resolution) (optional byte budget `CLAUDE_MB_LIMIT_SCAN_BYTES`), small transcripts are read in batches, and both resume from stored byte offsets with unfinished files marked pending, so a first backfill never blocks the statusline. The render-time scan is gated per transcript and writes nothing when the transcript did not grow; entries of deleted transcripts are pruned (lifetime totals stay; a transcript read or marked pending in the same run is never pruned). Transcript paths are canonicalized, so one file is never counted under two spellings. Known limit: deduplication is per file, so an API message present in two transcripts (e.g. a subagent sidechain and its parent) is counted in both (about 1 %)
- Fewer jq calls per render: highscore/window updates and the ledger summary each read their state in a single jq pass
- Highscore state schema 2: highscores and LimitAt values of the old counting scheme are discarded once (a `.bak` copy is kept)

##### Removed

- `[LimitAt:...]` and the `[Average:L%/A%]` display (both halves read the same field)
- The stdin delta accounting (`limit-usage-state_<profile>.json`, no longer written) with its false "session reset" path, and the separate main/subagent scanner states (`subagent-tokens.sh` is a compatibility wrapper now)

##### Fixed

- Token counts were ~2.3x too high because every content-block line of a message was counted
- Main-agent window tokens measured context growth and re-added the full context on almost every other turn
- Mid-window drops caused by empty reads of non-atomically written state files (subagent baseline reset)
- `test-local-tracking.sh` deleted and rewrote the real state file; it now runs in a temp profile

# 2026-09

## v2

### v2.35

#### Added

- Live session effort level in the model line

#### Removed

- `Style:` label

### v2.34

#### Changed

- Statusline git line follows the main agent's live work repo (session-scoped, subagents excluded)

### v2.33

#### Changed

- Statusline git line shows the resolved target repo, hub-aware via the credo project pin

# 2026-08

## v2

### v2.32

#### Changed

- Context fill is reported as distance to auto-compact

### v2.31

#### Added

- Configurable usage-API refresh cadence (`CLAUDE_MB_LIMIT_REFRESH_CADENCE`) to reduce rate limiting

### v2.30

#### Added

- SessionStart hook auto-heals a missing `statusLine.refreshInterval` (with settings backup)

#### Changed

- Default refresh interval raised to 20

### v2.29

#### Changed

- Statusline stays live during idle and subagent waits: refresh runs detached and renders from cache

### v2.28

#### Security

- OAuth token isolated in the refresh script; the statusline itself is token-free

### v2.27

#### Changed

- Injected time and limits are kept fresh

# 2026-06

## v2

### v2.26

#### Added

- z.ai/GLM provider support

### v2.25

#### Added

- Agent context-injection hook

# 2026-02

## v2

### v2.21

#### Added

- `CLAUDE_MB_LIMIT_PROFILE` toggle for profile display
- Session caption in the statusline

# 2026-01

## v2

### v2.20

#### Added

- Multi-account support via `CLAUDE_CONFIG_DIR`

### v2.19

#### Added

- Configurable progress bar mode for auto-compact

### v2.17

#### Added

- History tracking and average display

### v2.16

#### Changed

- Usage API requests use jitter and backoff

### v2.15

#### Changed

- Graceful degradation when the usage API is unavailable

### v2.14

#### Changed

- Tiered git fallback for slow 9p filesystems (WSL2)

### v2.13

#### Changed

- Script-based highscore command, SI units up to Yotta

### v2.9

#### Added

- Compact warning

### v2.5

#### Added

- Session progress bar and detailed context labels

### v2.4

#### Changed

- Compact labels and a combined model info line

### v2.3

#### Added

- Context line progress bar

### v2.2

#### Added

- JSONL-based lifetime tracking for the main agent

### v2.1

#### Changed

- Subagent cost is included in all lifetime displays

### v2.0

#### Added

- Current usage and reset times in the highscore command

#### Changed

- State files renamed with a `limit-` prefix (breaking), schema version reset mechanism

## v1

### v1.10

#### Added

- Subagent token tracking with cost calculation

### v1.9

#### Changed

- Highscore tracking enabled by default

### v1.8

#### Added

- Highscore tracking and `/limit:highscore` command
- Plan detection

### v1.7

#### Added

- Local usage tracking with reset-aware, token-based calibration
- Git worktree detection with colored git changes

### v1.6

#### Added

- Local device usage tracking

### v1.5

#### Added

- Git and model colors, line labels and model version display

### v1.4

#### Added

- Tokens, session and style/cost lines

### v1.3

#### Added

- Extended statusline features including git info

### v1.2

#### Added

- Active model display

### v1.1

#### Added

- Rate-limiting cache and ccstatusline integration

#### Changed

- Multiline output
- Environment variables and temp files use the `MB` prefix

### v1.0

#### Added

- limit plugin: live API usage in the statusline

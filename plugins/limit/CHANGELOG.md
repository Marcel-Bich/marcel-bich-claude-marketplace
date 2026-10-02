Changelog of the limit plugin. Newest first. Months group releases; no day dates. Releases up to v2.35 are summarized by minor version.

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

---
name: limit:highscore
description: limit - Display all highscores for all plans
model: haiku
---

<objective>
Display the current highscore state in a formatted view.
</objective>

<instructions>
1. Read the state file:
   ```bash
   cat ~/.claude/limit-highscore-state.json 2>/dev/null
   ```

2. If the file does not exist, inform the user:
   > No highscore data available yet.
   > Enable the highscore feature with: `export CLAUDE_MB_LIMIT_LOCAL=true`
   > Data will be collected during normal plugin usage.

3. If data exists, format the output as follows:

## Highscore Status

**Current Plan:** {plan}

### Highscores (all plans)

| Plan | 5h Highest | 7d Highest |
|------|-----------|-----------|
| max20 | {highscores.max20.5h formatted} | {highscores.max20.7d formatted} |
| max5 | {highscores.max5.5h formatted} | {highscores.max5.7d formatted} |
| pro | {highscores.pro.5h formatted} | {highscores.pro.7d formatted} |

Format numbers as: 5.2M (millions), 500.0K (thousands), 1.5B (billions)

### LimitAt Achievements

If `limits_at` values are non-null:

| Plan | 5h LimitAt | 7d LimitAt |
|------|-----------|-----------|
| {plan} | {limits_at.{plan}.5h or "-"} | {limits_at.{plan}.7d or "-"} |

If no LimitAt values exist: "No achievements unlocked yet."

### Current Window

- 5h: {window_tokens_5h formatted} Tokens
- 7d: {window_tokens_7d formatted} Tokens
- Device: {CLAUDE_MB_LIMIT_DEVICE_LABEL or hostname}

4. Briefly explain the concept at the end:

> **How does Highscore Tracking work?**
>
> Highscores can only increase, never decrease. The more you work,
> the higher your record gets. If you manage to reach the API limit
> (>95% utilization), you discover the real limit of your plan -
> like an achievement!
>
> Highscores are stored per plan so that a plan change
> (e.g., from Max20 to Pro) doesn't mix up the records.
</instructions>

---
name: limit:highscore
description: limit - Display all highscores for all plans
model: haiku
---

<objective>
Display the current highscore state in a formatted view, including subagent token tracking.
</objective>

<instructions>
1. Read the state files and hostname:
   ```bash
   cat ~/.claude/limit-highscore-state.json 2>/dev/null
   cat ~/.claude/marcel-bich-claude-marketplace/limit/state.json 2>/dev/null
   cat ~/.claude/marcel-bich-claude-marketplace/limit/subagent-state.json 2>/dev/null
   hostname
   ```

2. If the highscore state file does not exist, inform the user:
   > No highscore data available yet.
   > Highscore tracking is enabled by default (v1.9.0+).
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

Format numbers as: 5.2M (millions), 500.0k (thousands), 1.5B (billions)

### Current Window

- 5h: {window_tokens_5h formatted} Tokens
- 7d: {window_tokens_7d formatted} Tokens
- Device: {hostname from bash output}

> **Note:** These values show Main Agent tokens only.
> The statusline displays combined totals (Main + Subagents) in real-time.

### Lifetime Totals

**Main Agent** (from state.json):
- Tokens: {totals.input_tokens + totals.output_tokens formatted}
- Cost: ${totals.total_cost_usd formatted with 2 decimals}

**Subagents** (from subagent-state.json):
- Input Tokens: {total_input_tokens formatted}
- Output Tokens: {total_output_tokens formatted}
- Cache Read Tokens: {total_cache_read_tokens formatted}
- Subagent Total: {total_input_tokens + total_output_tokens + total_cache_read_tokens formatted}

**Combined Total:** {main_total + subagent_total formatted} Tokens

4. Briefly explain the concept at the end:

> **How does Highscore Tracking work?**
>
> Highscores can only increase, never decrease. The more you work,
> the higher your record gets.
>
> Highscores are stored per plan so that a plan change
> (e.g., from Max20 to Pro) doesn't mix up the records.
>
> Highscores include both Main Agent and Subagent tokens (v1.10.0+).
</instructions>

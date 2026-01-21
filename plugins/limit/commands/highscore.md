---
name: limit:highscore
description: limit - Display all highscores for all plans
model: haiku
---

<objective>
Display the current highscore state in a formatted view, including current usage limits, reset times, and subagent token tracking.
</objective>

<instructions>
1. Read the state files, fetch current API usage, and get hostname:
   ```bash
   cat ~/.claude/marcel-bich-claude-marketplace/limit/limit-highscore-state.json 2>/dev/null
   cat ~/.claude/marcel-bich-claude-marketplace/limit/limit-usage-state.json 2>/dev/null
   cat ~/.claude/marcel-bich-claude-marketplace/limit/limit-subagent-state.json 2>/dev/null
   cat /tmp/claude-mb-limit-cache.json 2>/dev/null
   hostname
   date +%s
   ```

2. If the highscore state file does not exist, inform the user:
   > No highscore data available yet.
   > Highscore tracking is enabled by default (v1.9.0+).
   > Data will be collected during normal plugin usage.

3. If data exists, format the output as follows:

## Highscore Status

---

### Combined Total (Main + Subagents)

Calculate and display prominently at the top:
- Main Agent tokens: `totals.input_tokens + totals.output_tokens` from limit-usage-state.json
- Main Agent cost: `totals.total_cost_usd` from limit-usage-state.json
- Subagent tokens: `total_tokens` from limit-subagent-state.json
- Subagent cost: `total_price` from limit-subagent-state.json
- Combined tokens: Main tokens + Subagent tokens
- Combined cost: Main cost + Subagent cost

**{combined_total formatted} Tokens** | ${combined_cost formatted with 2 decimals}

---

### Current Window (Main + Subagents)

Calculate combined window values:
- 5h Total = `window_tokens_5h` + `subagent_window_5h`
- 7d Total = `window_tokens_7d` + `subagent_window_7d`

Display:
- **5h:** {5h_total formatted} Tokens
- **7d:** {7d_total formatted} Tokens
- Device: {output of hostname command}

---

### Current Usage (from API)

Parse the API cache file (`/tmp/claude-mb-limit-cache.json`) if available. The file contains:
- `five_hour.utilization` - percentage used (0-100)
- `five_hour.resets_at` - ISO timestamp when the 5h window resets
- `seven_day.utilization` - percentage used (0-100)
- `seven_day.resets_at` - ISO timestamp when the 7d window resets

Display as:
- **5h:** {five_hour.utilization}% (resets in {time_until_reset})
- **7d:** {seven_day.utilization}% (resets in {time_until_reset})

**Calculate time until reset:**
- Parse `resets_at` timestamp and subtract current time (`date +%s`)
- Format as human-readable: "Xh Ym" for hours/minutes, "Xd Yh" for days/hours
- Example: "2h 15m", "3d 4h"

If API cache is not available or expired, show:
> API cache not available. Run a Claude session to populate usage data.

---

### Highscores

**Current Plan:** {plan}

Display the current plan's highscores prominently:
**Highscores ({plan})**
- 5h: {highscores[plan].5h formatted}
- 7d: {highscores[plan].7d formatted}

**Other Plans:**
List other plans in a compact format (skip the current plan):
- {other_plan}: 5h={5h formatted}, 7d={7d formatted}

Example output:
```
**Highscores (max20)**
- 5h: 1.8M
- 7d: 10.0M

**Other Plans:**
- max5: 5h=500.0k, 7d=5.0M
- pro: 5h=200.0k, 7d=2.0M
```

Format numbers as: 5.2M (millions), 500.0k (thousands), 1.5B (billions)

---

### Lifetime Breakdown

**Main Agent:**
- Tokens: {totals.input_tokens + totals.output_tokens formatted}
- Cost: ${totals.total_cost_usd formatted with 2 decimals}

**Subagents:**
- Tokens: {total_tokens formatted}
- Cost: ${total_price formatted with 2 decimals}

Per-model breakdown (if available):
- Haiku: {haiku tokens formatted}
- Sonnet: {sonnet tokens formatted}
- Opus: {opus tokens formatted}

---

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

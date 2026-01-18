---
name: highscore
description: Zeigt alle Highscores fuer alle Plaene
model: haiku
---

<objective>
Zeige den aktuellen Highscore-State schoen aufbereitet.
</objective>

<instructions>
1. Lies die State-Datei:
   ```bash
   cat ~/.claude/limit-highscore-state.json 2>/dev/null
   ```

2. Falls die Datei nicht existiert, teile dem User mit:
   > Noch keine Highscore-Daten vorhanden.
   > Aktiviere das Highscore-Feature mit: `export CLAUDE_MB_LIMIT_LOCAL=true`
   > Die Daten werden waehrend der normalen Plugin-Nutzung gesammelt.

3. Falls Daten vorhanden, formatiere die Ausgabe wie folgt:

## Highscore Status

**Aktueller Plan:** {plan}

### Highscores (alle Plaene)

| Plan | 5h Highest | 7d Highest |
|------|-----------|-----------|
| max20 | {highscores.max20.5h formatted} | {highscores.max20.7d formatted} |
| max5 | {highscores.max5.5h formatted} | {highscores.max5.7d formatted} |
| pro | {highscores.pro.5h formatted} | {highscores.pro.7d formatted} |

Formatiere Zahlen als: 5.2M (Millionen), 500.0K (Tausend), 1.5B (Milliarden)

### LimitAt Achievements

Falls `limits_at` Werte ungleich null vorhanden sind:

| Plan | 5h LimitAt | 7d LimitAt |
|------|-----------|-----------|
| {plan} | {limits_at.{plan}.5h oder "-"} | {limits_at.{plan}.7d oder "-"} |

Falls keine LimitAt-Werte vorhanden: "Noch keine Achievements freigeschaltet."

### Aktuelles Window

- 5h: {window_tokens_5h formatted} Tokens
- 7d: {window_tokens_7d formatted} Tokens
- Device: {CLAUDE_MB_LIMIT_DEVICE_LABEL oder hostname}

4. Erklaere kurz das Konzept am Ende:

> **Wie funktioniert Highscore-Tracking?**
>
> Highscores koennen nur steigen, nie sinken. Je mehr du arbeitest,
> desto hoeher wird dein Rekord. Wenn du es schaffst, das API-Limit
> zu erreichen (>95% Auslastung), entdeckst du das echte Limit deines
> Plans - quasi ein Achievement!
>
> Die Highscores sind pro Plan gespeichert, damit ein Planwechsel
> (z.B. von Max20 zu Pro) die Rekorde nicht durcheinander bringt.
</instructions>

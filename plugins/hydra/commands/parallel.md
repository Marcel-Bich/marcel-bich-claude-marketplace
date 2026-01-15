---
description: Startet mehrere Agents parallel in verschiedenen Worktrees
arguments:
  - name: tasks
    description: "Aufgaben im Format: worktree1:prompt1 | worktree2:prompt2"
    required: true
allowed-tools:
  - Bash
  - Task
  - Read
---

# Worktree Parallel

Du fuehrst den `/hydra:parallel` Command aus. Starte mehrere Agents gleichzeitig in verschiedenen Worktrees.

## Argumente

`$ARGUMENTS` wird als pipe-separierte Liste von Tasks geparst:

```
worktree1:prompt1 | worktree2:prompt2 | worktree3:prompt3
```

Beispiel:
```
/hydra:parallel feature-a:Implementiere Login | feature-b:Implementiere Logout | feature-c:Schreibe Tests
```

## Ablauf

### 1. Parse Aufgaben

Teile `$ARGUMENTS` bei `|` und parse jeden Teil:

```bash
# Beispiel-Parsing
echo "$ARGUMENTS" | tr '|' '\n' | while read task; do
  WORKTREE=$(echo "$task" | cut -d':' -f1 | xargs)
  PROMPT=$(echo "$task" | cut -d':' -f2- | xargs)
  echo "Worktree: $WORKTREE, Prompt: $PROMPT"
done
```

### 2. Validiere alle Worktrees

Fuer jeden Task:

```bash
git worktree list | grep -qE "$WORKTREE|hydra/$WORKTREE"
```

Falls ein Worktree fehlt, biete an ihn zu erstellen:

```
Folgende Worktrees existieren nicht:
  - feature-x
  - feature-y

Soll ich sie erstellen? (Branches werden von main abgezweigt)
```

Falls ja, erstelle fehlende Worktrees:

```bash
for WT in feature-x feature-y; do
  REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
  git worktree add -b "hydra/$WT" "../${REPO_NAME}-worktrees/$WT"
done
```

### 3. Starte alle Agents parallel

**WICHTIG:** Nutze einen einzigen Response mit mehreren Task-tool Aufrufen!

Fuer jeden Task, rufe Task tool auf mit:

```
subagent_type: general-purpose
run_in_background: true
prompt: [wie bei /hydra:spawn]
```

Alle Task-Aufrufe muessen in EINER Antwort sein fuer echte Parallelitaet.

### 4. Sammle Ergebnisse

Nach dem Start aller Agents:

```
Parallele Agents gestartet:

  Worktree      | Agent-ID        | Aufgabe
  --------------|-----------------|---------------------------
  feature-a     | agent-abc123    | Implementiere Login
  feature-b     | agent-def456    | Implementiere Logout
  feature-c     | agent-ghi789    | Schreibe Tests

Alle Agents laufen im Hintergrund.

Naechste Schritte:
  - /hydra:status             # Fortschritt aller Worktrees
  - TaskOutput agent-abc123      # Ergebnis eines Agents
  - /hydra:merge feature-a    # Wenn fertig: einzeln mergen
```

## Eingabe-Format Alternativen

Falls JSON bevorzugt:

```json
[
  {"worktree": "feature-a", "prompt": "Implementiere Login"},
  {"worktree": "feature-b", "prompt": "Implementiere Logout"}
]
```

Falls Zeilenumbrueche:

```
feature-a: Implementiere Login
feature-b: Implementiere Logout
feature-c: Schreibe Tests
```

Erkenne das Format automatisch und parse entsprechend.

## Hinweise

- Maximale Parallelitaet: ~3-5 Agents (System-Limit)
- Jeder Agent arbeitet isoliert
- Keine Git-Konflikte zwischen Agents
- Ergebnisse koennen in beliebiger Reihenfolge fertig werden

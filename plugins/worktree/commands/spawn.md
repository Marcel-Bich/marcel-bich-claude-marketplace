---
description: Startet einen Agent in einem existierenden Worktree
arguments:
  - name: worktree
    description: Name des Worktrees
    required: true
  - name: prompt
    description: Aufgabe fuer den Agent
    required: true
allowed-tools:
  - Bash
  - Task
  - Read
---

# Worktree Spawn

Du fuehrst den `/worktree:spawn` Command aus. Starte einen Agent in einem existierenden Worktree.

## Argumente

`$ARGUMENTS` wird geparst als:
- Erstes Wort: Worktree-Name
- Rest: Prompt fuer den Agent

Beispiel: `feature-a Implementiere das neue Feature`
- worktree: `feature-a`
- prompt: `Implementiere das neue Feature`

## Ablauf

### 1. Parse Argumente

```bash
# Erstes Wort = Worktree
WORKTREE_NAME=$(echo "$ARGUMENTS" | awk '{print $1}')

# Rest = Prompt
AGENT_PROMPT=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
```

Falls eines fehlt, zeige Hilfe:

```
Nutzung: /worktree:spawn {worktree} {prompt}

Beispiel:
  /worktree:spawn feature-a "Implementiere Login-Formular"
```

### 2. Pruefe ob Worktree existiert

```bash
git worktree list | grep -E "$WORKTREE_NAME|worktree/$WORKTREE_NAME"
```

Falls nicht gefunden:

```
Worktree '{name}' nicht gefunden.

Optionen:
1. Erstelle ihn zuerst: /worktree:create {name}
2. Zeige vorhandene: /worktree:list
```

### 3. Bestimme absoluten Pfad

```bash
WORKTREE_PATH=$(git worktree list --porcelain | grep -B1 "$WORKTREE_NAME" | grep "worktree " | head -1 | cut -d' ' -f2-)

# In absoluten Pfad umwandeln
WORKTREE_PATH=$(cd "$WORKTREE_PATH" && pwd)
```

### 4. Starte Agent mit Task tool

Nutze das Task tool mit folgenden Parametern:

```
subagent_type: general-purpose
run_in_background: true (optional, je nach Aufgabe)
prompt: [siehe unten]
```

**Agent-Prompt konstruieren:**

```
Du arbeitest in einem isolierten Git Worktree.

WICHTIG - Dein Arbeitsverzeichnis:
  {WORKTREE_PATH}

Alle Dateioperationen muessen relativ zu diesem Verzeichnis erfolgen.
Nutze absolute Pfade oder stelle sicher dass du im richtigen Verzeichnis bist.

Deine Aufgabe:
{AGENT_PROMPT}

Wenn du fertig bist:
1. Committe deine Aenderungen im Worktree
2. Zeige git status und git log -3
```

### 5. Ausgabe

Nach dem Start:

```
Agent gestartet in Worktree '{name}':

  Worktree-Pfad: {path}
  Aufgabe: {prompt}
  Agent-ID: {id falls background}

Naechste Schritte:
  - /worktree:status {name}    # Fortschritt pruefen
  - TaskOutput mit Agent-ID    # Ergebnis abrufen (falls background)
  - /worktree:merge {name}     # Wenn fertig: zurueckmergen
```

## Hinweise

- Der Agent arbeitet vollstaendig isoliert im Worktree
- Keine Konflikte mit anderen parallelen Agents
- Agent sollte am Ende committen
- Nutze `run_in_background: true` fuer lange Aufgaben

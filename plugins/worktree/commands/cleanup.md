---
description: Entfernt bereits gemergte Worktrees und deren Branches
arguments:
  - name: dry-run
    description: "Zeigt nur was entfernt werden wuerde (optional: --dry-run)"
    required: false
allowed-tools:
  - Bash
  - AskUserQuestion
---

# Worktree Cleanup

Du fuehrst den `/worktree:cleanup` Command aus. Entferne bereits gemergte Worktrees und deren Branches.

## Argumente

- `$ARGUMENTS`:
  - `--dry-run` oder `-n`: Zeigt nur was entfernt werden wuerde
  - Leer: Fuehrt Cleanup mit Bestaetigung durch

## Ablauf

### 1. Bestimme Modus

```bash
DRY_RUN=false
if [[ "$ARGUMENTS" == "--dry-run" || "$ARGUMENTS" == "-n" ]]; then
  DRY_RUN=true
fi
```

### 2. Sammle alle Worktrees

```bash
# Alle Worktrees ausser dem Haupt-Worktree
git worktree list | tail -n +2
```

### 3. Pruefe jeden Worktree auf Merge-Status

Fuer jeden Worktree:

```bash
# Branch des Worktrees
BRANCH=$(git worktree list --porcelain | grep -A2 "$WORKTREE_PATH" | grep "branch " | sed 's/branch refs\/heads\///')

# Ist der Branch in main/master gemerged?
MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

git branch --merged "$MAIN_BRANCH" | grep -q "$BRANCH"
if [[ $? -eq 0 ]]; then
  echo "GEMERGED: $WORKTREE_NAME ($BRANCH)"
else
  echo "NICHT GEMERGED: $WORKTREE_NAME ($BRANCH)"
fi
```

### 4. Zeige Cleanup-Kandidaten

```
Cleanup-Analyse:

GEMERGTE Worktrees (werden entfernt):
  - feature-a (worktree/feature-a) - 3 Commits, gemerged vor 2 Tagen
  - feature-b (worktree/feature-b) - 5 Commits, gemerged vor 1 Woche

NICHT GEMERGTE Worktrees (werden behalten):
  - feature-c (worktree/feature-c) - 2 Commits, noch offen
  - feature-d (worktree/feature-d) - 7 Commits, noch offen

{Falls dry-run}
--dry-run Modus: Keine Aenderungen vorgenommen.
Ohne --dry-run ausfuehren zum Aufraeumen.
```

### 5. Bestaetigung (falls nicht dry-run)

Falls nicht `--dry-run` und es gibt Kandidaten:

Nutze AskUserQuestion:

```
Sollen folgende Worktrees und Branches entfernt werden?

  - feature-a (worktree/feature-a)
  - feature-b (worktree/feature-b)

Optionen:
- Alle entfernen
- Einzeln bestaetigen
- Abbrechen
```

### 6. Cleanup durchfuehren

Fuer jeden bestaetigten Worktree:

```bash
# Worktree entfernen
git worktree remove "$WORKTREE_PATH"

# Branch entfernen
git branch -d "$BRANCH"
```

### 7. Ausgabe

```
Cleanup abgeschlossen:

Entfernt:
  - feature-a (Worktree + Branch)
  - feature-b (Worktree + Branch)

Behalten (nicht gemerged):
  - feature-c
  - feature-d

Gesamt: 2 Worktrees entfernt, 2 behalten
```

Falls keine Kandidaten:

```
Keine bereits gemergten Worktrees gefunden.

Aktive Worktrees:
  - feature-c (worktree/feature-c) - 2 Commits
  - feature-d (worktree/feature-d) - 7 Commits

Nutze /worktree:merge {name} um Worktrees zu mergen.
```

## Sicherheits-Features

- Nur vollstaendig gemergte Branches werden entfernt
- Kein Force-Delete (`git branch -d` statt `-D`)
- Bestaetigung vor Loeschung (ausser dry-run)
- Nicht-gemergte Worktrees bleiben immer erhalten

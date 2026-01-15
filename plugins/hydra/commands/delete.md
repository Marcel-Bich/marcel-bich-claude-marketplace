---
description: Entfernt einen Git Worktree sicher
arguments:
  - name: name
    description: Name des zu loeschenden Worktrees
    required: true
allowed-tools:
  - Bash
  - AskUserQuestion
---

# Worktree Delete

Du fuehrst den `/hydra:delete` Command aus. Entferne einen Git Worktree sicher mit Schutz vor Datenverlust.

## Argumente

- `$ARGUMENTS` - Name des zu loeschenden Worktrees (required)

## Ablauf

### 1. Pruefe ob Worktree existiert

```bash
git worktree list | grep -E "$ARGUMENTS|hydra/$ARGUMENTS"
```

Falls nicht gefunden:

```
Worktree '{name}' nicht gefunden.

Verfuegbare Worktrees:
{liste}

Tipp: Nutze /hydra:list fuer eine Uebersicht.
```

### 2. Bestimme Pfad und Branch

```bash
# Finde exakten Pfad
WORKTREE_PATH=$(git worktree list --porcelain | grep -A2 "worktree.*$ARGUMENTS" | grep "worktree " | cut -d' ' -f2-)

# Finde Branch
WORKTREE_BRANCH=$(git worktree list --porcelain | grep -A2 "worktree.*$ARGUMENTS" | grep "branch " | sed 's/branch refs\/heads\///')
```

### 3. Pruefe auf uncommitted changes

```bash
cd "$WORKTREE_PATH"
git status --porcelain
```

Falls uncommitted changes vorhanden, nutze AskUserQuestion:

```
WARNUNG: Worktree '{name}' hat ungespeicherte Aenderungen:

{git status output}

Diese Aenderungen gehen verloren!

Frage: Trotzdem loeschen?
Optionen:
- Ja, loeschen (Aenderungen verwerfen)
- Nein, abbrechen
```

### 4. Entferne Worktree

```bash
# Zurueck zum Hauptverzeichnis
cd "$(git worktree list | head -1 | awk '{print $1}')"

# Worktree entfernen
git worktree remove "$WORKTREE_PATH"
```

Falls locked:

```bash
# Mit --force falls locked
git worktree remove --force "$WORKTREE_PATH"
```

### 5. Optional: Branch loeschen

Frage ob der Branch auch geloescht werden soll:

```
Worktree entfernt.

Der Branch '{branch}' existiert noch.
Soll er auch geloescht werden?

Optionen:
- Ja, Branch loeschen (git branch -d {branch})
- Nein, Branch behalten
```

Falls ja:

```bash
git branch -d "$WORKTREE_BRANCH"
```

Falls Branch nicht gemerged:

```
Branch kann nicht geloescht werden - noch nicht gemerged.
Nutze 'git branch -D {branch}' zum erzwungenen Loeschen.
```

### 6. Ausgabe

Bei Erfolg:

```
Worktree geloescht:

  Pfad:   {path} (entfernt)
  Branch: {branch} (behalten/geloescht)

Verbleibende Worktrees: /hydra:list
```

## Sicherheits-Features

- Uncommitted changes werden IMMER angezeigt
- Bestaetigung erforderlich bei ungespeicherten Aenderungen
- Branch-Loeschung ist optional und separat
- Kein --force ohne explizite Zustimmung

---
description: Zeigt alle Git Worktrees des aktuellen Repositories
allowed-tools:
  - Bash
---

# Worktree List

Du fuehrst den `/hydra:list` Command aus. Zeige alle Git Worktrees des aktuellen Repositories.

## Ablauf

### 1. Pruefe Git-Repository

```bash
git rev-parse --git-dir 2>/dev/null || { echo "Fehler: Kein Git-Repository"; exit 1; }
```

### 2. Liste Worktrees

```bash
git worktree list
```

### 3. Formatiere Ausgabe

Parse den Output und zeige uebersichtlich:

```
Git Worktrees:

  Pfad                              Branch              Commit
  ----------------------------------------------------------------
  /home/user/project                main                a1b2c3d
  /home/user/project-worktrees/a    hydra/feature-a  d4e5f6g
  /home/user/project-worktrees/b    hydra/feature-b  h7i8j9k
```

### 4. Zusaetzliche Infos

Fuer jeden Worktree zeige optional:
- Lock-Status (falls locked)
- Prunable-Status (falls verwaist)

```bash
# Lock-Status pruefen
git worktree list --porcelain | grep -A3 "worktree"
```

### 5. Falls keine Worktrees

Falls nur der Hauptworktree existiert:

```
Nur der Haupt-Worktree existiert (main/master).

Erstelle einen neuen mit:
  /hydra:create {name}
```

## Ausgabe-Format

Kompakte Tabelle mit allen relevanten Infos auf einen Blick.

---
description: Zeigt detaillierten Status eines oder aller Worktrees
arguments:
  - name: name
    description: Spezifischer Worktree (optional, sonst alle)
    required: false
allowed-tools:
  - Bash
---

# Worktree Status

Du fuehrst den `/hydra:status` Command aus. Zeige detaillierten Status eines oder aller Worktrees.

## Argumente

- `$ARGUMENTS` - Optional: Name eines spezifischen Worktrees

## Ablauf

### 1. Hole Worktree-Liste

```bash
git worktree list --porcelain
```

### 2. Fuer jeden Worktree (oder nur angegebenen)

Wechsle in das Worktree-Verzeichnis und sammle Infos:

```bash
# Status
git -C {worktree-path} status --short

# Letzter Commit
git -C {worktree-path} log -1 --oneline

# Ahead/Behind zu main
git -C {worktree-path} rev-list --left-right --count main...HEAD 2>/dev/null
```

### 3. Formatiere Ausgabe

**Alle Worktrees:**

```
Worktree Status:

[main] /home/user/project
  Branch: main
  Status: clean
  Commit: a1b2c3d - Initial commit (2h ago)

[feature-a] /home/user/project-worktrees/feature-a
  Branch: hydra/feature-a
  Status: 2 modified, 1 untracked
  Commit: d4e5f6g - Add feature A (30m ago)
  Ahead: 3 commits | Behind: 0

[feature-b] /home/user/project-worktrees/feature-b
  Branch: hydra/feature-b
  Status: clean
  Commit: h7i8j9k - Implement B (1h ago)
  Ahead: 5 commits | Behind: 2
```

**Einzelner Worktree (detailliert):**

```
Worktree: feature-a
Path: /home/user/project-worktrees/feature-a
Branch: hydra/feature-a

Status:
  M  src/feature.ts
  M  tests/feature.test.ts
  ?? src/new-file.ts

Last Commit:
  d4e5f6g - Add feature A
  Author: User <user@example.com>
  Date: 30 minutes ago

Comparison to main:
  Ahead: 3 commits
  Behind: 0 commits
```

### 4. Fehlerbehandlung

Falls Worktree nicht gefunden:

```
Worktree '{name}' nicht gefunden.

Verfuegbare Worktrees:
  - main (Haupt)
  - feature-a
  - feature-b

Zeige alle mit: /hydra:list
```

## Hinweise

- Ohne Argument werden alle Worktrees gezeigt
- Mit Argument nur der spezifische (detaillierter)
- "Behind" zeigt ob main neue Commits hat die nicht im Worktree sind

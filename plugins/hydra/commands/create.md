---
description: Erstellt einen neuen Git Worktree fuer isolierte Arbeit
arguments:
  - name: name
    description: Name/Branch fuer den Worktree
    required: true
allowed-tools:
  - Bash
  - Read
---

# Worktree Create

Du fuehrst den `/hydra:create` Command aus. Erstelle einen neuen Git Worktree fuer isolierte Arbeit.

## Argumente

- `$ARGUMENTS` - Name fuer den Worktree (wird auch Branch-Name)

## Ablauf

### 1. Pruefe Voraussetzungen

```bash
# Git-Repo?
git rev-parse --git-dir 2>/dev/null || { echo "Fehler: Kein Git-Repository"; exit 1; }

# Repo-Name fuer Pfad
basename "$(git rev-parse --show-toplevel)"
```

### 2. Parameter vorbereiten

Falls `$ARGUMENTS` leer ist, frage nach dem Namen.

Bestimme:
- **Branch-Name**: `hydra/$ARGUMENTS` (oder nur `$ARGUMENTS` falls bereits Pfad-artig)
- **Worktree-Pfad**: `../{repo-name}-worktrees/$ARGUMENTS/`

### 3. Pruefe ob bereits existiert

```bash
# Worktree mit diesem Namen?
git worktree list | grep -q "$ARGUMENTS" && echo "Worktree existiert bereits"

# Branch existiert?
git show-ref --verify --quiet "refs/heads/hydra/$ARGUMENTS" && echo "Branch existiert"
```

Falls Worktree existiert: Zeige Pfad und beende mit Hinweis.

### 4. Erstelle Worktree

```bash
# Pfad bestimmen
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
WORKTREE_PATH="../${REPO_NAME}-worktrees/$ARGUMENTS"

# Verzeichnis erstellen falls noetig
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Worktree mit neuem Branch erstellen
git worktree add -b "hydra/$ARGUMENTS" "$WORKTREE_PATH"
```

### 5. Ausgabe

Bei Erfolg:

```
Worktree erstellt:

  Pfad:   {absoluter Pfad}
  Branch: hydra/{name}

Naechste Schritte:
  - cd {pfad}                        # Manuell wechseln
  - /hydra:spawn {name} "..."     # Agent dort starten
  - /hydra:status                 # Status pruefen
```

Bei Fehler:

```
Fehler beim Erstellen des Worktrees:

{git error message}

Moegliche Ursachen:
- Worktree existiert bereits
- Branch-Name bereits vergeben
- Keine Schreibrechte im Zielverzeichnis
```

## Hinweise

- Uncommitted changes im aktuellen Verzeichnis blockieren NICHT die Erstellung
- Der neue Worktree startet vom aktuellen HEAD
- Branch-Praefix `hydra/` hilft bei der Organisation

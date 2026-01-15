---
description: Merged einen Worktree-Branch zurueck in den aktuellen Branch
arguments:
  - name: worktree
    description: Name des Worktrees dessen Branch gemerged wird
    required: true
  - name: strategy
    description: "merge (default) oder rebase"
    required: false
allowed-tools:
  - Bash
  - AskUserQuestion
---

# Worktree Merge

Du fuehrst den `/worktree:merge` Command aus. Merge einen Worktree-Branch zurueck in den aktuellen Branch.

## Argumente

- `$ARGUMENTS` wird geparst als:
  - Erstes Wort: Worktree-Name
  - Zweites Wort (optional): Strategy (merge/rebase)

Beispiele:
- `/worktree:merge feature-a` - Merge mit Standard-Strategie
- `/worktree:merge feature-a rebase` - Rebase statt Merge

## Ablauf

### 1. Parse Argumente und validiere

```bash
WORKTREE_NAME=$(echo "$ARGUMENTS" | awk '{print $1}')
STRATEGY=$(echo "$ARGUMENTS" | awk '{print $2}')
STRATEGY=${STRATEGY:-merge}  # Default: merge

# Validiere Strategy
if [[ "$STRATEGY" != "merge" && "$STRATEGY" != "rebase" ]]; then
  echo "Unbekannte Strategie: $STRATEGY (erlaubt: merge, rebase)"
  exit 1
fi
```

### 2. Pruefe ob Worktree existiert

```bash
git worktree list | grep -qE "$WORKTREE_NAME|worktree/$WORKTREE_NAME" || {
  echo "Worktree '$WORKTREE_NAME' nicht gefunden"
  exit 1
}
```

### 3. Bestimme Branch-Namen

```bash
WORKTREE_BRANCH=$(git worktree list --porcelain | grep -A2 "$WORKTREE_NAME" | grep "branch " | sed 's/branch refs\/heads\///')
CURRENT_BRANCH=$(git branch --show-current)

echo "Merge: $WORKTREE_BRANCH -> $CURRENT_BRANCH"
```

### 4. Pruefe auf uncommitted changes

**Im aktuellen Verzeichnis (blockiert):**

```bash
if [[ -n $(git status --porcelain) ]]; then
  echo "FEHLER: Uncommitted changes im aktuellen Verzeichnis"
  echo "Committe oder stashe zuerst deine Aenderungen."
  git status --short
  exit 1
fi
```

**Im Worktree (Warnung):**

```bash
WORKTREE_PATH=$(git worktree list | grep "$WORKTREE_NAME" | awk '{print $1}')
if [[ -n $(git -C "$WORKTREE_PATH" status --porcelain) ]]; then
  echo "WARNUNG: Uncommitted changes im Worktree '$WORKTREE_NAME'"
  git -C "$WORKTREE_PATH" status --short
  # Frage ob fortfahren
fi
```

### 5. Zeige was gemerged wird

```bash
echo "Folgende Commits werden gemerged:"
git log --oneline "$CURRENT_BRANCH".."$WORKTREE_BRANCH"

echo ""
echo "Betroffene Dateien:"
git diff --stat "$CURRENT_BRANCH"..."$WORKTREE_BRANCH"
```

### 6. Fuehre Merge/Rebase aus

**Merge:**

```bash
git merge "$WORKTREE_BRANCH" -m "Merge worktree/$WORKTREE_NAME"
```

**Rebase:**

```bash
git rebase "$WORKTREE_BRANCH"
```

### 7. Konflikt-Handling

Falls Konflikte auftreten:

```
MERGE-KONFLIKT erkannt!

Betroffene Dateien:
{git status --short zeigt UU fuer conflicts}

Optionen:
1. Konflikte manuell loesen:
   - Bearbeite die markierten Dateien
   - git add {datei}
   - git commit (bei merge) oder git rebase --continue

2. Merge abbrechen:
   - git merge --abort (bei merge)
   - git rebase --abort (bei rebase)

3. Ihre Version behalten (ours):
   - git checkout --ours {datei}

4. Deren Version behalten (theirs):
   - git checkout --theirs {datei}
```

### 8. Erfolgreiche Ausgabe

```
Merge erfolgreich!

  Von: worktree/$WORKTREE_NAME
  Nach: $CURRENT_BRANCH
  Commits: X

Gemergte Dateien:
{diff --stat output}

Naechste Schritte:
  - /worktree:delete $WORKTREE_NAME  # Worktree aufraeumen
  - /worktree:cleanup                 # Alle gemergten aufraeumen
  - git push                          # Falls gewuenscht
```

## Sicherheits-Features

- Kein automatisches Force-Push
- Klare Anzeige was gemerged wird BEVOR es passiert
- Konflikt-Handling mit Abort-Option
- Uncommitted changes im Hauptverzeichnis blockieren

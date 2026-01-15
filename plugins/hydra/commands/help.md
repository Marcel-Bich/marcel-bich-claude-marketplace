---
description: Zeigt verfuegbare Worktree-Commands und erklaert das Konzept
allowed-tools:
  - Bash
---

# Worktree Plugin Hilfe

Du fuehrst den `/hydra:help` Command aus. Zeige dem Nutzer die verfuegbaren Commands und erklaere das Konzept von Git Worktrees.

## Was sind Git Worktrees?

Git Worktrees ermöglichen es, mehrere Branches gleichzeitig in verschiedenen Verzeichnissen ausgecheckt zu haben. Jeder Worktree hat:

- Eigenes Arbeitsverzeichnis
- Eigenen Index (Staging Area)
- Eigenen HEAD

Das bedeutet: Parallele Arbeit an verschiedenen Features ohne `git stash` oder Branch-Wechsel.

## Warum fuer Claude-Agents?

Wenn mehrere Agents parallel arbeiten sollen, braucht jeder sein eigenes Verzeichnis. Sonst:

- Git-Konflikte beim gleichzeitigen Commit
- Ueberschreiben von Aenderungen
- Chaos im Staging-Bereich

Mit Worktrees bekommt jeder Agent sein isoliertes Arbeitsverzeichnis.

## Verfuegbare Commands

Zeige die aktuell verfuegbaren Commands:

```bash
grep -A2 "^  [a-z]" "${CLAUDE_PLUGIN_ROOT:-$(dirname $(dirname $0))}/plugin.yaml" 2>/dev/null || echo "Konnte plugin.yaml nicht lesen"
```

## Typischer Workflow

```
1. /hydra:create feature-x     # Erstellt Worktree
2. /hydra:spawn feature-x "..."  # Agent arbeitet dort
3. /hydra:status               # Fortschritt pruefen
4. /hydra:merge feature-x      # Aenderungen integrieren
5. /hydra:cleanup              # Aufraeumen
```

## Weitere Informationen

- Git Worktree Dokumentation: `git worktree --help`
- Plugin-Wiki fuer ausfuehrliche Anleitung

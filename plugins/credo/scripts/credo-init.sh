#!/bin/bash
# credo-init - create the per-project .credo/ structure in the current repo.
#
# Idempotent: safe to re-run. Creates the .credo/ folder namespace, an empty
# id-counter, a project config stub, and adds the git-exclude lines so .credo/
# is never committed by default.
#
# Usage:
#   credo-init.sh                 operate on the current git repo (or cwd)
#   CREDO_DIR=/path credo-init.sh operate on an explicit .credo directory
#
# Exit codes: 0 on success, 1 on hard error.

set -euo pipefail

# --- locate the target .credo directory -------------------------------------
# Precedence: explicit CREDO_DIR > git toplevel/.credo > ./.credo
if [ -n "${CREDO_DIR:-}" ]; then
    CREDO_DIR="$CREDO_DIR"
elif REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    CREDO_DIR="$REPO_ROOT/.credo"
else
    CREDO_DIR="$(pwd)/.credo"
fi

# --- directory structure -----------------------------------------------------
DIRS=(
    "docs"
    "screenshots"
    "items/1_todo/1_clarify"
    "items/1_todo/2_go"
    "items/2_done"
    "items/3_verified"
    "items/4_archived"
    "items/parked/hold"
    "items/parked/future"
    "process/requirements"
    "process/handoffs/archive"
    "process/reports"
    "checklists"
)

for d in "${DIRS[@]}"; do
    mkdir -p "$CREDO_DIR/$d"
done

# --- id-counter (empty = 0; credo-id-next manages issuance) ------------------
if [ ! -f "$CREDO_DIR/id-counter" ]; then
    : > "$CREDO_DIR/id-counter"
fi

# --- project config stub (per-project overrides; empty = no override) --------
# Personal and universal defaults live in the global config
# (~/.claude/credo/config); this file only holds per-project overrides.
if [ ! -f "$CREDO_DIR/config" ]; then
    tmp="$CREDO_DIR/.config.tmp.$$"
    cat > "$tmp" <<'EOF'
# credo per-project config (YAML).
# Cascade precedence: builtin < global (~/.claude/credo/config) < this file.
# Add only project-specific overrides here. Leave empty to inherit everything.
EOF
    mv -f "$tmp" "$CREDO_DIR/config"
fi

# --- git-exclude lines (idempotent, no duplicates on re-run) -----------------
# .credo/ is intentionally kept out of git; agents version nothing by default.
if GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"; then
    EXCLUDE_FILE="$GIT_DIR/info/exclude"
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    [ -f "$EXCLUDE_FILE" ] || : > "$EXCLUDE_FILE"
    for line in ".credo/**" ".credo/screenshots/**"; do
        if ! grep -qxF "$line" "$EXCLUDE_FILE" 2>/dev/null; then
            printf '%s\n' "$line" >> "$EXCLUDE_FILE"
        fi
    done
else
    echo "credo-init: not a git repo, skipped git-exclude setup" >&2
fi

echo "credo-init: ready at $CREDO_DIR"

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
# Target resolution is delegated to `credo-config.sh resolve-project` so init and
# config agree. It is fail-safe: when the cwd is a launch hub or has no credo
# project and no explicit target was given, init creates NOTHING and exits 4.
#
# Exit codes: 0 on success, 1 on hard error, 4 needs explicit target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- locate the target .credo directory (shared resolver) -------------------
# Precedence (see credo-config.sh resolve-project): explicit CREDO_DIR > session
# pin (/credo:project) > cwd git-toplevel/.credo when it already exists and is not
# a hub. A new .credo is only ever created when an explicit target is given.
set +e
RESOLVED="$("$SCRIPT_DIR/credo-config.sh" resolve-project 2>/dev/null)"
RESOLVE_RC=$?
set -e
if [ "$RESOLVE_RC" -eq 4 ]; then
    TARGET_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    echo "credo-init: cwd '$TARGET_DIR' is a hub or has no credo project, and no explicit target was given. Set CREDO_DIR to the target repo, or pin it with /credo:project <path>, then retry." >&2
    exit 4
fi
if [ "$RESOLVE_RC" -ne 0 ] || [ -z "$RESOLVED" ]; then
    echo "credo-init: could not resolve a target .credo directory" >&2
    exit 1
fi
CREDO_DIR="$RESOLVED"

# --- task backend (fail-safe) ------------------------------------------------
# Resolved via credo-config.sh: env CREDO_TASK_BACKEND override (set + non-empty)
# > merged config task_backend (.credo/config cascade) > credo default. Any error
# falls back to credo. Chicken-and-egg is fine: when this runs before any project
# config exists, the resolver falls back to global/builtin (task_backend: credo) and
# the items tree is created (correct default). Only backend=gsd skips the item/
# subtree and id-counter, because with GSD as the task system the .credo/items/ model
# stands down and the base tree (docs, screenshots, process, checklists, config) is all
# that is needed.
BACKEND="$("$SCRIPT_DIR/credo-config.sh" backend 2>/dev/null || echo credo)"
[ -n "$BACKEND" ] || BACKEND="credo"

# --- directory structure -----------------------------------------------------
DIRS=(
    "docs"
    "screenshots"
    "process/requirements"
    "process/handoffs/archive"
    "process/reports"
    "checklists"
)
if [ "$BACKEND" != "gsd" ]; then
    DIRS+=(
        "items/1_todo/1_clarify"
        "items/1_todo/2_go"
        "items/2_done"
        "items/3_verified"
        "items/4_archived"
        "items/parked/hold"
        "items/parked/future"
    )
fi

for d in "${DIRS[@]}"; do
    mkdir -p "$CREDO_DIR/$d"
done

# --- id-counter (empty = 0; credo-id-next manages issuance) ------------------
# Only meaningful for the credo item model; skipped when GSD is the task backend.
if [ "$BACKEND" != "gsd" ] && [ ! -f "$CREDO_DIR/id-counter" ]; then
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

# --- git-exclude lines (managed block, toggle-safe + idempotent) -------------
# By default .credo/ is kept entirely out of git; agents version nothing.
# Opt-in (per project): set CREDO_VERSION_TRACKED=1 to version .credo/** in the repo
# EXCEPT the per-project config and the screenshots, which stay local always. Default
# (variable unset) = previous behaviour, all of .credo/** excluded.
#
# The credo entries live inside a marker-delimited managed block. Every run first
# removes any existing credo block (and legacy loose lines from earlier versions),
# then writes a fresh block for the current mode. This makes toggling default<->tracked
# actually take effect on re-run and stays idempotent. Foreign entries in
# .git/info/exclude are never touched.
CREDO_BLOCK_BEGIN="# >>> credo (managed - do not edit)"
CREDO_BLOCK_END="# <<< credo (managed)"
if [ "${CREDO_VERSION_TRACKED:-}" = "1" ]; then
    EXCLUDE_LINES=(".credo/config" ".credo/screenshots/")
else
    EXCLUDE_LINES=(".credo/**")
fi
if GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)"; then
    EXCLUDE_FILE="$GIT_DIR/info/exclude"
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    [ -f "$EXCLUDE_FILE" ] || : > "$EXCLUDE_FILE"

    tmp="$EXCLUDE_FILE.credo.tmp.$$"
    # Strip an existing credo managed block plus any legacy loose lines from earlier
    # versions, so old installs migrate cleanly. awk exits 0 even without a match.
    awk -v b="$CREDO_BLOCK_BEGIN" -v e="$CREDO_BLOCK_END" '
        $0 == b { inblock = 1; next }
        $0 == e { inblock = 0; next }
        inblock { next }
        $0 == ".credo/**"             { next }
        $0 == ".credo/screenshots/**" { next }
        $0 == ".credo/config"         { next }
        $0 == ".credo/config/"        { next }
        $0 == ".credo/screenshots/"   { next }
        { print }
    ' "$EXCLUDE_FILE" > "$tmp"

    # Append a fresh managed block for the current mode. awk guarantees the stripped
    # output ends with a newline, so the begin marker never fuses onto a foreign line.
    {
        printf '%s\n' "$CREDO_BLOCK_BEGIN"
        for line in "${EXCLUDE_LINES[@]}"; do
            printf '%s\n' "$line"
        done
        printf '%s\n' "$CREDO_BLOCK_END"
    } >> "$tmp"

    mv -f "$tmp" "$EXCLUDE_FILE"
else
    echo "credo-init: not a git repo, skipped git-exclude setup" >&2
fi

echo "credo-init: ready at $CREDO_DIR"

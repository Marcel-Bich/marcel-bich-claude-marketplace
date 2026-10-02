#!/bin/bash
# worktree-setup - bring excluded files (CLAUDE.md, CLAUDE/, GUIDES/,
# DOGMA-PERMISSIONS.md, .credo/, ...) into a fresh git worktree.
#
# A new worktree only contains versioned files, so an agent working there misses the
# project rules and the credo items. Run this right after `git worktree add`. It
# applies the worktree files list (kind + path) to the worktree:
#   link -> relative symlink to the path in the main checkout (default kind)
#   copy -> independent copy (for files that must differ per worktree, e.g. .env.local)
#
# The list comes from dogma's worktree-files.sh (the "Worktree files" list in the
# "### Hydra" subsection of DOGMA-PERMISSIONS.md) when dogma is installed, else from
# the built-in default: link CLAUDE.md, CLAUDE/, GUIDES/, DOGMA-PERMISSIONS.md, .credo/.
# credo ships the same logic as scripts/credo-worktree-setup.sh (its native fallback
# when hydra is not used); keep both in sync.
#
# Rules:
#   - a path missing in the main checkout is skipped silently
#   - a versioned file is skipped with a warning (it comes with the checkout)
#   - a directory without tracked files is linked/copied as a whole; a directory that
#     contains tracked files is recursed into and each untracked entry is handled
#     individually (tracked ones come with the checkout)
#   - entries that are a nested repo or worktree (contain .git) are skipped
#   - an existing path in the worktree (file, dir or symlink) is NEVER overwritten
#   - a linked directory that is ignored in the main checkout only via a "dir/" pattern
#     gets an anchored "/dir" line in the shared info/exclude (a "dir/" pattern does
#     not match a symlink); a linked path that is not ignored in the main checkout at
#     all gets a warning (it could be committed by accident in the worktree)
#
# Usage:
#   worktree-setup.sh <worktree-path> [main-checkout]
#     main-checkout defaults to the main worktree of the repository.
#
# Environment:
#   WORKTREE_FILES_SCRIPT  path to a worktree-files.sh to use instead of searching
#                          for dogma; "none" forces the built-in default list
#   CLAUDE_CONFIG_DIR      Claude config dir (default ~/.claude) for the dogma lookup
#
# Output: one line per action ("linked <path>", "copied <path>", "kept <path> (exists)",
# "skipped <path> (versioned)" for a listed path that is itself versioned), warnings on
# stderr, then "source=dogma|default" and "main=<main checkout path>" (the path to put
# into the builder brief: read-only lookups of anything missing in the worktree).
# Exit codes: 0 done, 1 bad arguments, 2 not a secondary worktree of a git repo.

set -euo pipefail

die() { echo "worktree-setup: $1" >&2; exit "${2:-1}"; }
warn() { echo "worktree-setup: $1" >&2; }

[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: worktree-setup.sh <worktree-path> [main-checkout]"
[ -d "$1" ] || die "no such dir: $1"
WT="$(cd "$1" && pwd -P)"

WT_TOP="$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" || die "not a git worktree: $WT" 2
[ "$(cd "$WT_TOP" && pwd -P)" = "$WT" ] || die "not the root of a worktree: $WT (root is $WT_TOP)" 2

if [ -n "${2:-}" ]; then
    [ -d "$2" ] || die "no such dir: $2"
    MAIN="$(cd "$2" && pwd -P)"
else
    MAIN="$(git -C "$WT" worktree list --porcelain | sed -n '1s/^worktree //p')"
    [ -n "$MAIN" ] && [ -d "$MAIN" ] || die "cannot determine the main checkout" 2
    MAIN="$(cd "$MAIN" && pwd -P)"
fi
[ "$MAIN" != "$WT" ] || die "the worktree is the main checkout itself - nothing to set up" 2

# --- the list -----------------------------------------------------------------
DEFAULT_LIST="link CLAUDE.md
link CLAUDE/
link GUIDES/
link DOGMA-PERMISSIONS.md
link .credo/"

# Newest installed version of a plugin that has <file>: installPath entries of
# installed_plugins.json plus the plugin cache, compared by version (sort -V).
find_plugin_file() { # plugin-name relative-file
    local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" d
    {
        python3 - "$cfg/plugins/installed_plugins.json" "$1" 2>/dev/null <<'PY' || true
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for key, entries in (data.get("plugins") or {}).items():
    if key.split("@")[0] == sys.argv[2]:
        for e in entries if isinstance(entries, list) else []:
            if isinstance(e, dict) and e.get("installPath"):
                print(e["installPath"])
PY
        for d in "$cfg"/plugins/cache/*/"$1"/*/; do
            [ -d "$d" ] && echo "${d%/}"
        done
    } | while IFS= read -r d; do
        [ -f "$d/$2" ] && printf '%s\t%s\n' "$(basename "$d")" "$d/$2"
    done | sort -V -k1,1 | tail -n1 | cut -f2
}

find_dogma_script() {
    if [ -n "${WORKTREE_FILES_SCRIPT:-}" ]; then
        [ "$WORKTREE_FILES_SCRIPT" = "none" ] || echo "$WORKTREE_FILES_SCRIPT"
        return 0
    fi
    find_plugin_file dogma scripts/worktree-files.sh
}

SOURCE="default"
LIST=""
DOGMA_SCRIPT="$(find_dogma_script)"
if [ -n "$DOGMA_SCRIPT" ] && [ -f "$DOGMA_SCRIPT" ]; then
    if LIST="$(bash "$DOGMA_SCRIPT" "$MAIN")" && [ -n "$LIST" ]; then
        SOURCE="dogma"
    else
        warn "dogma worktree-files.sh failed - using the built-in default list"
        LIST=""
    fi
fi
[ -n "$LIST" ] || LIST="$DEFAULT_LIST"

# --- helpers --------------------------------------------------------------------
EXCLUDE_MARK="# worktree setup: symlinked paths in linked worktrees"
is_tracked_file() { git -C "$MAIN" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; }
has_tracked_inside() { [ -n "$(git -C "$MAIN" ls-files -- "$1/" 2>/dev/null | head -n1)" ]; }

relpath() { # target-abs from-dir-abs
    python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2" 2>/dev/null || echo "$1"
}

# A directory pattern like "CLAUDE/" does not match a symlink, so a linked directory
# would show up as untracked in the worktree (and could be committed by accident).
# When the path is ignored in the main checkout, add the anchored pattern "/<rel>"
# (no trailing slash) to the shared info/exclude once - it ignores the same path in
# the main checkout, so nothing changes there. Otherwise only warn.
ensure_link_ignored() { # rel
    local rel="$1" exclude
    git -C "$WT" check-ignore -q -- "$rel" 2>/dev/null && return 0
    if git -C "$MAIN" check-ignore -q -- "$rel" 2>/dev/null; then
        exclude="$(git -C "$MAIN" rev-parse --git-common-dir)/info/exclude"
        case "$exclude" in /*) ;; *) exclude="$MAIN/$exclude" ;; esac
        mkdir -p "$(dirname "$exclude")"
        if ! grep -qxF -- "/$rel" "$exclude" 2>/dev/null; then
            grep -qxF -- "$EXCLUDE_MARK" "$exclude" 2>/dev/null || printf '%s\n' "$EXCLUDE_MARK" >> "$exclude"
            printf '/%s\n' "$rel" >> "$exclude"
        fi
        echo "excluded /$rel (symlink in worktrees)"
    else
        warn "$rel is untracked but not ignored - do not commit the link in the worktree"
    fi
}

apply_one() { # kind rel
    local kind="$1" rel="$2" src="$MAIN/$2" dst="$WT/$2"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        echo "kept $rel (exists)"
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    if [ "$kind" = "copy" ]; then
        cp -a -- "$src" "$dst"
        echo "copied $rel"
    else
        ln -s -- "$(relpath "$src" "$(cd "$(dirname "$dst")" && pwd -P)")" "$dst"
        echo "linked $rel"
        ensure_link_ignored "$rel"
    fi
}

handle() { # kind rel top(1|0)
    local kind="$1" rel="$2" top="$3" src="$MAIN/$2" child
    if [ ! -e "$src" ] && [ ! -L "$src" ]; then
        return 0
    fi
    if [ -d "$src" ] && [ ! -L "$src" ]; then
        if [ -e "$src/.git" ]; then
            warn "skipping $rel (nested repository or worktree)"
            return 0
        fi
        if ! has_tracked_inside "$rel"; then
            apply_one "$kind" "$rel"
            return 0
        fi
        while IFS= read -r -d '' child; do
            handle "$kind" "$rel/$(basename "$child")" 0
        done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 | sort -z)
        return 0
    fi
    if is_tracked_file "$rel"; then
        # inside a recursed directory tracked files are expected; only a listed
        # path that is itself versioned is reported
        if [ "$top" = "1" ]; then
            echo "skipped $rel (versioned)"
            warn "$rel is versioned - it comes with the checkout, not linked"
        fi
        return 0
    fi
    apply_one "$kind" "$rel"
}

while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind="${line%% *}"
    path="${line#* }"
    path="${path%/}"
    case "$kind" in link|copy) ;; *) warn "ignoring unknown kind: $kind"; continue ;; esac
    case "/$path/" in
        //|*/../*|/./) warn "ignoring invalid path: $path"; continue ;;
    esac
    case "$path" in /*) warn "ignoring absolute path: $path"; continue ;; esac
    handle "$kind" "$path" 1
done <<< "$LIST"

echo "source=$SOURCE"
echo "main=$MAIN"

#!/bin/bash
# Tests for credo-dogma-mode.sh and credo-worktree-flow.sh. Temp dirs only (removed on
# exit). Covers checkbox states, missing file/section/checkbox, the main-worktree
# fallback, and the hydra / ask / native flow decision.
# Usage: bash test-worktree-flow.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE_SH="$SCRIPT_DIR/credo-dogma-mode.sh"
FLOW_SH="$SCRIPT_DIR/credo-worktree-flow.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-wt-flow-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

perms() { # dir hydra-state cleanup-state
    mkdir -p "$1"
    cat > "$1/DOGMA-PERMISSIONS.md" <<EOF
# Dogma Permissions
<permissions>
## Git Permissions
- [x] May run \`git add\` autonomously

## Workflow Permissions

### Hydra

Parallel work (only if Hydra available, otherwise sequential):
- [$2] use Hydra for 2+ independent tasks

Worktree cleanup at item close ([x] = remove without asking, [?] = ask each time, [ ] = never):
- [$3] clean up merged worktrees automatically

### TDD
- [x] clean up merged worktrees automatically
</permissions>
EOF
}

CLEAN='clean up merged worktrees automatically'
HYD='use Hydra for 2\+ independent tasks'

perms "$TMP/a" x '?'
check "mode auto" auto "$("$MODE_SH" Hydra "$HYD" "$TMP/a")"
check "mode ask" ask "$("$MODE_SH" Hydra "$CLEAN" "$TMP/a")"
perms "$TMP/b" ' ' ' '
check "mode deny" deny "$("$MODE_SH" Hydra "$CLEAN" "$TMP/b")"
check "section scoped (TDD line ignored)" deny "$("$MODE_SH" Hydra "$CLEAN" "$TMP/b")"
check "missing checkbox" missing "$("$MODE_SH" Hydra 'no such checkbox' "$TMP/a")"
check "missing section" missing "$("$MODE_SH" Nope "$HYD" "$TMP/a")"
mkdir -p "$TMP/none"
if [ ! -f "$(dirname "$TMP")/DOGMA-PERMISSIONS.md" ]; then
    check "missing file" missing "$("$MODE_SH" Hydra "$HYD" "$TMP/none")"
fi
mkdir -p "$TMP/a/sub"
check "upward search" auto "$("$MODE_SH" Hydra "$HYD" "$TMP/a/sub")"
"$MODE_SH" Hydra >/dev/null 2>&1; check "bad args exit 1" 1 "$?"

# main-worktree fallback: the linked worktree has no DOGMA-PERMISSIONS.md
R="$TMP/repo"
mkdir -p "$R"
git -C "$R" init -q -b main
echo x > "$R/x"; git -C "$R" add x; git -C "$R" commit -q -m init
perms "$R" x x
echo DOGMA-PERMISSIONS.md >> "$R/.git/info/exclude"
git -C "$R" worktree add -q -b wt/a "$TMP/wt-a"
check "fallback to main worktree" auto "$("$MODE_SH" Hydra "$CLEAN" "$TMP/wt-a")"

# flow decision
FAKE_HYDRA="$TMP/hydra/9.9.9"
mkdir -p "$FAKE_HYDRA/commands" "$FAKE_HYDRA/scripts"
touch "$FAKE_HYDRA/commands/create.md" "$FAKE_HYDRA/scripts/worktree-setup.sh"
flow() { CREDO_HYDRA_DIR="$1" "$FLOW_SH" "$2" | sed -n 's/^flow=//p'; }
check "flow [x] + hydra" hydra "$(flow "$FAKE_HYDRA" "$TMP/a")"
check "flow [x] + no hydra" native "$(flow none "$TMP/a")"
perms "$TMP/c" '?' x
check "flow [?] + hydra" ask "$(flow "$FAKE_HYDRA" "$TMP/c")"
check "flow [ ] + hydra" native "$(flow "$FAKE_HYDRA" "$TMP/b")"
if [ ! -f "$(dirname "$TMP")/DOGMA-PERMISSIONS.md" ]; then
    check "flow missing file" native "$(flow "$FAKE_HYDRA" "$TMP/none")"
fi
check "flow setup = hydra script" "setup=$FAKE_HYDRA/scripts/worktree-setup.sh" "$(CREDO_HYDRA_DIR="$FAKE_HYDRA" "$FLOW_SH" "$TMP/a" | grep '^setup=')"
check "flow setup = credo script without hydra" "setup=$SCRIPT_DIR/credo-worktree-setup.sh" "$(CREDO_HYDRA_DIR=none "$FLOW_SH" "$TMP/a" | grep '^setup=')"
check "flow json" hydra "$(CREDO_HYDRA_DIR="$FAKE_HYDRA" "$FLOW_SH" --json "$TMP/a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["flow"])')"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

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

# hermetic: no session-folder file to inherit from, no credo pinned project
mkdir -p "$TMP/session"
export DOGMA_SESSION_DIR="$TMP/session" DOGMA_CREDO_CONFIG=none

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
    check "flow missing file" hydra "$(flow "$FAKE_HYDRA" "$TMP/none")"
fi
check "flow setup = hydra script" "setup=$FAKE_HYDRA/scripts/worktree-setup.sh" "$(CREDO_HYDRA_DIR="$FAKE_HYDRA" "$FLOW_SH" "$TMP/a" | grep '^setup=')"
check "flow setup = credo script without hydra" "setup=$SCRIPT_DIR/credo-worktree-setup.sh" "$(CREDO_HYDRA_DIR=none "$FLOW_SH" "$TMP/a" | grep '^setup=')"
check "flow json" hydra "$(CREDO_HYDRA_DIR="$FAKE_HYDRA" "$FLOW_SH" --json "$TMP/a" | python3 -c 'import json,sys; print(json.load(sys.stdin)["flow"])')"

# stable ids (§xw1i use Hydra, §36ch cleanup): id first, anywhere in <permissions>
mkdir -p "$TMP/ids"
cat > "$TMP/ids/DOGMA-PERMISSIONS.md" <<'EOF'
<permissions>
## Workflow Permissions

### Hydra
- [x] clean up merged worktrees automatically

### Parallelarbeit
- [ ] (§xw1i) Worktrees für parallele Aufgaben nutzen
- [?] (§36ch) Gemergte Worktrees beim Schließen aufräumen
</permissions>
EOF
check "id: reworded line in another subsection" deny "$("$MODE_SH" --id xw1i Hydra "$HYD" "$TMP/ids")"
check "id: id line wins over text line in ### Hydra" ask "$("$MODE_SH" --id 36ch Hydra "$CLEAN" "$TMP/ids")"
check "id: unknown id -> text fallback" auto "$("$MODE_SH" --id zzzz Hydra "$CLEAN" "$TMP/ids")"
check "id: old file without ids -> text fallback" auto "$("$MODE_SH" --id xw1i Hydra "$HYD" "$TMP/a")"
check "id: old file, missing checkbox stays missing" missing "$("$MODE_SH" --id zzzz Hydra 'no such checkbox' "$TMP/a")"
"$MODE_SH" --id XY12 Hydra "$HYD" "$TMP/a" >/dev/null 2>&1; check "id: bad id exit 1" 1 "$?"
"$MODE_SH" --id >/dev/null 2>&1; check "id: --id without value exit 1" 1 "$?"
check "flow by id [ ] reworded + hydra" native "$(flow "$FAKE_HYDRA" "$TMP/ids")"


# --- which file applies + inheritance from the session folder's file (§r3nx) ---
WS="$TMP/inh/workspace"
P="$TMP/inh/projects"
mkdir -p "$WS" "$P/app" "$P/off" "$P/nobox" "$P/old" "$P/nofile"
cat > "$WS/DOGMA-PERMISSIONS.md" <<'EOF'
<permissions>
## Workflow Permissions
### Hydra
- [x] (§xw1i) use Hydra for 2+ independent tasks
- [?] (§36ch) clean up merged worktrees automatically
</permissions>
EOF
cat > "$P/app/DOGMA-PERMISSIONS.md" <<'EOF'
<permissions>
## Inheritance
- [x] (§r3nx) inherit permissions

## Workflow Permissions
### Hydra
- [ ] (§xw1i) use Hydra for 2+ independent tasks
</permissions>
EOF
sed 's/- \[x\] (§r3nx)/- [ ] (§r3nx)/' "$P/app/DOGMA-PERMISSIONS.md" > "$P/off/DOGMA-PERMISSIONS.md"
grep -v 'r3nx\|## Inheritance' "$P/app/DOGMA-PERMISSIONS.md" > "$P/nobox/DOGMA-PERMISSIONS.md"
cat > "$P/old/DOGMA-PERMISSIONS.md" <<'EOF'
<permissions>
### Hydra
- [ ] use Hydra for 2+ independent tasks
</permissions>
EOF
in_ws() { (cd "$WS" && DOGMA_SESSION_DIR="$WS" "$MODE_SH" "$@"); }
check "inherit: own id wins" deny "$(in_ws --id xw1i Hydra "$HYD" "$P/app")"
check "inherit: missing id from session file" ask "$(in_ws --id 36ch Hydra "$CLEAN" "$P/app")"
check "inherit [ ]: missing stays missing" missing "$(in_ws --id 36ch Hydra "$CLEAN" "$P/off")"
check "inherit: missing checkbox = on" ask "$(in_ws --id 36ch Hydra "$CLEAN" "$P/nobox")"
check "inherit: old file text line wins" deny "$(in_ws --id xw1i Hydra "$HYD" "$P/old")"
check "inherit: old file missing setting inherited" ask "$(in_ws --id 36ch Hydra "$CLEAN" "$P/old")"
check "target without own file -> session file" auto "$(in_ws --id xw1i Hydra "$HYD" "$P/nofile")"
check "no target -> session file" auto "$(in_ws --id xw1i Hydra "$HYD")"
check "session dir is the target -> no inheritance" missing "$(cd "$P/app" && DOGMA_SESSION_DIR="$P/app" "$MODE_SH" --id 36ch Hydra "$CLEAN" "$P/app")"

# credo pinned project (fake pin in a temp CLAUDE_CONFIG_DIR): no target -> pinned project
mkdir -p "$TMP/inh/cfg/credo/session-projects"
printf '%s\n' "$P/app" > "$TMP/inh/cfg/credo/session-projects/test-sid"
pinned() { (unset CREDO_DIR; cd "$WS" && DOGMA_SESSION_DIR="$WS" DOGMA_CREDO_CONFIG= CLAUDE_CONFIG_DIR="$TMP/inh/cfg" CREDO_SESSION_ID=test-sid "$MODE_SH" "$@"); }
check "pinned: no target -> pinned project file" deny "$(pinned --id xw1i Hydra "$HYD")"
check "pinned: inherits from session file" ask "$(pinned --id 36ch Hydra "$CLEAN")"
check "pinned: explicit target wins" ask "$(pinned --id 36ch Hydra "$CLEAN" "$P/nobox")"
check "pinned: switched off -> session file" auto "$(cd "$WS" && DOGMA_SESSION_DIR="$WS" DOGMA_CREDO_CONFIG=none CLAUDE_CONFIG_DIR="$TMP/inh/cfg" CREDO_SESSION_ID=test-sid "$MODE_SH" --id xw1i Hydra "$HYD")"
check "flow: repo inherits [x] Hydra from the session file" hydra "$(cd "$WS" && DOGMA_SESSION_DIR="$WS" CREDO_HYDRA_DIR="$FAKE_HYDRA" "$FLOW_SH" "$P/nofile" | sed -n 's/^flow=//p')"


# --- session folder recorded by the SessionStart hook (cwd drift: cd <project> && ...) ---
REC="$TMP/inh/rec"
mkdir -p "$REC/credo/session-dirs" "$REC/dogma/session-dirs"
printf '%s\n' "$WS" > "$REC/credo/session-dirs/rec-sid"
printf '%s\n' "$TMP/inh/gone" > "$REC/credo/session-dirs/gone-sid"
printf '%s\n' "$WS" > "$REC/dogma/session-dirs/dogma-sid"
drift() { # cwd sid args... (no DOGMA_SESSION_DIR, cwd inside the project)
    local cwd="$1" sid="$2"
    shift 2
    (unset DOGMA_SESSION_DIR CREDO_SESSION_ID; cd "$cwd" && CLAUDE_CONFIG_DIR="$REC" CLAUDE_CODE_SESSION_ID="$sid" "$MODE_SH" "$@")
}
check "recorded: cd into target -> inherited from the session file" ask "$(drift "$P/app" rec-sid --id 36ch Hydra "$CLEAN" "$P/app")"
check "recorded: target without own file -> session file" auto "$(drift "$P/nofile" rec-sid --id xw1i Hydra "$HYD" "$P/nofile")"
check "recorded: no target -> cwd file still applies" deny "$(drift "$P/app" rec-sid --id xw1i Hydra "$HYD")"
check "recorded: no target -> cwd file inherits" ask "$(drift "$P/app" rec-sid --id 36ch Hydra "$CLEAN")"
check "recorded: dogma's record is read too" ask "$(drift "$P/app" dogma-sid --id 36ch Hydra "$CLEAN" "$P/app")"
check "recorded: no record -> \$PWD (old behaviour)" missing "$(drift "$P/app" other-sid --id 36ch Hydra "$CLEAN" "$P/app")"
check "recorded: removed dir -> \$PWD" missing "$(drift "$P/app" gone-sid --id 36ch Hydra "$CLEAN" "$P/app")"
check "recorded: explicit DOGMA_SESSION_DIR wins" missing "$(cd "$P/app" && CLAUDE_CONFIG_DIR="$REC" CLAUDE_CODE_SESSION_ID=rec-sid DOGMA_SESSION_DIR="$P/app" "$MODE_SH" --id 36ch Hydra "$CLEAN" "$P/app")"
check "recorded: CREDO_SESSION_ID picks the record" ask "$(unset DOGMA_SESSION_DIR; cd "$P/app" && CLAUDE_CONFIG_DIR="$REC" CLAUDE_CODE_SESSION_ID=other-sid CREDO_SESSION_ID=rec-sid "$MODE_SH" --id 36ch Hydra "$CLEAN" "$P/app")"

# --- the SessionStart hook that writes the record ---
HOOK="$SCRIPT_DIR/../hooks/credo-session-dir-record.sh"
HK="$TMP/hk"
rec_hook() { # session_id cwd source [project_dir]
    jq -cn --arg s "$1" --arg c "$2" --arg o "$3" '{session_id:$s, cwd:$c, source:$o, hook_event_name:"SessionStart"}' \
        | (unset CLAUDE_PROJECT_DIR; [ -z "${4:-}" ] || export CLAUDE_PROJECT_DIR="$4"; CLAUDE_CONFIG_DIR="$HK" bash "$HOOK")
}
rec_of() { cat "$HK/credo/session-dirs/$1" 2>/dev/null || echo none; }
check "hook: silent" "" "$(rec_hook h1 "$WS" startup)"
check "hook: startup records cwd" "$WS" "$(rec_of h1)"
rec_hook h1 "$P/app" compact >/dev/null
check "hook: compact keeps the recorded dir (cwd may have drifted)" "$WS" "$(rec_of h1)"
rec_hook h1 "$P/app" resume >/dev/null
check "hook: resume overwrites" "$P/app" "$(rec_of h1)"
rec_hook h2 "$P/app" clear >/dev/null
check "hook: clear writes when absent" "$P/app" "$(rec_of h2)"
rec_hook h2 "$P/old" compact "$WS" >/dev/null
check "hook: CLAUDE_PROJECT_DIR wins and always overwrites" "$WS" "$(rec_of h2)"
rec_hook h3 "$TMP/inh/gone" startup >/dev/null
check "hook: missing cwd -> no record" none "$(rec_of h3)"
rec_hook '../evil' "$WS" startup >/dev/null; check "hook: bad session id exit 0" 0 "$?"
check "hook: bad session id -> no record" none "$(cat "$HK/credo/evil" 2>/dev/null || echo none)"
mkdir -p "$HK/credo/session-dirs"
printf '%s\n' "$WS" > "$HK/credo/session-dirs/old-sid"
touch -d '40 days ago' "$HK/credo/session-dirs/old-sid"
rec_hook h4 "$WS" startup >/dev/null
check "hook: prunes records older than 30 days" none "$(rec_of old-sid)"
check "hook: end to end with credo-dogma-mode" ask "$(unset DOGMA_SESSION_DIR CREDO_SESSION_ID; cd "$P/app" && CLAUDE_CONFIG_DIR="$HK" CLAUDE_CODE_SESSION_ID=h4 "$MODE_SH" --id 36ch Hydra "$CLEAN" "$P/app")"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]

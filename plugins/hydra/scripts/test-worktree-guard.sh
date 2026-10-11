#!/bin/bash
# Tests for hooks/worktree-guard.sh and scripts/worktree-guard.py. Temp dirs only (removed
# on exit). Covers the Agent / Task isolation and EnterWorktree calls (with and without a
# path), git worktree add destinations (literal paths, cd, git -C, variables), comments,
# heredoc bodies and command position, the DOGMA-PERMISSIONS checkbox states, the main
# checkout fallback, the output format and the fail-open cases.
# Usage: bash test-worktree-guard.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/worktree-guard.sh"
HOOKS_JSON="$SCRIPT_DIR/../hooks/hooks.json"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hydra-wt-guard-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
SEC=$'\xc2\xa7' # section sign of the stable setting ids, as UTF-8 bytes

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

PROJ="$TMP/proj"
HYD="$TMP/proj-worktrees"
NOFILE="$TMP/nofile"
L_X="- [x] (${SEC}xw1i) use Hydra for 2+ independent tasks"
L_OFF="- [ ] (${SEC}xw1i) use Hydra for 2+ independent tasks"
L_ASK="- [?] (${SEC}xw1i) use Hydra for 2+ independent tasks"

# fixtures: a repo with one commit, a sub folder and a linked hydra worktree (set up with git
# directly, the hook is not involved); a second repo without any DOGMA-PERMISSIONS.md
git init -q "$PROJ"
mkdir -p "$PROJ/sub"
git -C "$PROJ" -c commit.gpgsign=false commit -q --allow-empty -m init
mkdir -p "$HYD"
git -C "$PROJ" worktree add -q -b hydra/w1 "$HYD/w1"
git init -q "$NOFILE"

write_perms() { # dir hydra-line (empty = no checkbox line)
    mkdir -p "$1"
    printf '%s\n' "# Dogma Permissions" "<permissions>" "## Git Permissions" \
        "- [x] May run \`git add\` autonomously" "" "### Hydra" "" \
        "Parallel work (only if Hydra available, otherwise sequential):" "$2" "" \
        "Worktree cleanup at item close:" "- [x] (${SEC}36ch) clean up merged worktrees automatically" \
        "</permissions>" > "$1/DOGMA-PERMISSIONS.md"
}

json_for() { # tool cwd command isolation (empty = omitted)
    python3 - "$@" <<'PY'
import json, sys
tool, cwd, command, isolation = sys.argv[1:5]
tin = {}
if command:
    tin["command"] = command
if isolation:
    tin["isolation"] = isolation
print(json.dumps({"hook_event_name": "PreToolUse", "session_id": "test", "cwd": cwd,
                  "tool_name": tool, "tool_input": tin}))
PY
}

run_hook() { printf '%s' "$1" | bash "$HOOK"; } # the wrapper, as Claude Code runs it
verdict() { # json -> deny | allow
    if run_hook "$1" | grep -q '"permissionDecision": "deny"'; then echo deny; else echo allow; fi
}
bash_v() { verdict "$(json_for Bash "$1" "$2" "")"; }     # cwd command
tool_v() { verdict "$(json_for "$1" "$2" "" "$3")"; }     # tool cwd isolation

# 1. Agent / Task isolation and EnterWorktree (checkbox [x])
write_perms "$PROJ" "$L_X"
check "agent isolation worktree denied" deny "$(tool_v Agent "$PROJ" worktree)"
check "task isolation worktree denied" deny "$(tool_v Task "$PROJ" worktree)"
check "agent without isolation allowed" allow "$(tool_v Agent "$PROJ" "")"
check "agent isolation none allowed" allow "$(tool_v Agent "$PROJ" none)"
check "EnterWorktree without path denied" deny "$(tool_v EnterWorktree "$PROJ" "")"
check "EnterWorktree name without path denied" deny \
    "$(verdict "{\"tool_name\":\"EnterWorktree\",\"cwd\":\"$PROJ\",\"tool_input\":{\"name\":\"new-one\"}}")"
check "EnterWorktree empty path denied" deny \
    "$(verdict "{\"tool_name\":\"EnterWorktree\",\"cwd\":\"$PROJ\",\"tool_input\":{\"path\":\"\"}}")"
check "EnterWorktree path allowed (existing worktree, creates nothing)" allow \
    "$(verdict "{\"tool_name\":\"EnterWorktree\",\"cwd\":\"$PROJ\",\"tool_input\":{\"path\":\"$HYD/w1\"}}")"
check "unrelated tool allowed" allow "$(tool_v Read "$PROJ" "")"

# 2. checkbox states and the file lookup (probe: agent isolation worktree)
write_perms "$PROJ" "$L_OFF"
check "checkbox [ ] allows" allow "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "$L_ASK"
check "checkbox [?] allows" allow "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "- [0] (${SEC}xw1i) use Hydra for 2+ independent tasks"
check "checkbox [0] allows" allow "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "- [a] (${SEC}xw1i) use Hydra for 2+ independent tasks"
check "checkbox [a] allows" allow "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "- [x] (${SEC}xw1i) use Hydra for 2+ independent tasks"
check "checkbox [x] denies" deny "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "- [x] use Hydra for 2+ independent tasks"
check "[x] by text in Hydra subsection denies" deny "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "- [ ] use Hydra for 2+ independent tasks"
check "[ ] by text in Hydra subsection allows" allow "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" ""
check "no checkbox line counts as on" deny "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "- [ ] (${SEC}xw1i) reworded line, the id still decides"
check "id line reworded still allows when off" allow "$(tool_v Agent "$PROJ" worktree)"
write_perms "$PROJ" "- [x] (${SEC}36ch) some other setting"
check "other id only counts as no checkbox (on)" deny "$(tool_v Agent "$PROJ" worktree)"
mkdir -p "$TMP/outside"
printf '%s\n' "<permissions>" "</permissions>" "$L_OFF" > "$TMP/outside/DOGMA-PERMISSIONS.md"
check "checkbox outside the permissions block counts as on" deny "$(tool_v Agent "$TMP/outside" worktree)"
check "no DOGMA-PERMISSIONS.md counts as on" deny "$(tool_v Agent "$NOFILE" worktree)"
write_perms "$PROJ" "$L_OFF"
check "linked worktree without own file uses the main checkout file" allow \
    "$(tool_v Agent "$HYD/w1" worktree)"
write_perms "$PROJ" "$L_X"
check "linked worktree uses the main checkout file (on)" deny "$(tool_v Agent "$HYD/w1" worktree)"

# 3. git worktree add destinations (checkbox [x], cwd = main checkout)
check "literal hydra path allowed" allow \
    "$(bash_v "$PROJ" 'git worktree add -b hydra/a ../proj-worktrees/a')"
check "nested hydra name allowed" allow \
    "$(bash_v "$PROJ" 'git worktree add -b hydra/a/b ../proj-worktrees/a/b')"
check "sibling folder denied" deny "$(bash_v "$PROJ" 'git worktree add ../other/x')"
check "absolute hydra path allowed" allow "$(bash_v "$PROJ" "git worktree add $HYD/abs")"
check "absolute path outside denied" deny \
    "$(bash_v "$PROJ" 'git worktree add /nonexistent-elsewhere/x')"
check "dot-dot escape denied" deny "$(bash_v "$PROJ" 'git worktree add ../proj-worktrees/../evil')"
check "dot-dot escape after a name denied" deny \
    "$(bash_v "$PROJ" 'git worktree add ../proj-worktrees/x/../../evil')"
check "the hydra folder itself denied" deny "$(bash_v "$PROJ" 'git worktree add ../proj-worktrees')"
check "force and detach flags allowed" allow \
    "$(bash_v "$PROJ" 'git worktree add -f --detach ../proj-worktrees/det HEAD')"
check "attached -b value allowed" allow \
    "$(bash_v "$PROJ" 'git worktree add -bhydra-att ../proj-worktrees/att')"
check "orphan with hydra path allowed" allow \
    "$(bash_v "$PROJ" 'git worktree add --orphan newb ../proj-worktrees/o')"
check "orphan with sibling path denied" deny \
    "$(bash_v "$PROJ" 'git worktree add --orphan newb ../other/o')"
check "no destination allowed" allow "$(bash_v "$PROJ" 'git worktree add -b hydra/x')"
check "redirects after the path allowed" allow \
    "$(bash_v "$PROJ" 'git worktree add ../proj-worktrees/r > /dev/null 2>&1')"
check "sibling after echo in a chain denied" deny \
    "$(bash_v "$PROJ" 'echo ok && git worktree add ../other/y')"
check "second worktree add in a chain denied" deny \
    "$(bash_v "$PROJ" 'git worktree add ../proj-worktrees/a; git worktree add ../other/z')"
check "chain of hydra paths allowed" allow \
    "$(bash_v "$PROJ" 'git worktree add ../proj-worktrees/a2 && git worktree add ../proj-worktrees/a3')"

# 4. variables, globs, cd, git -C, subshells, unparseable commands
check "shell variable destination denied" deny "$(bash_v "$PROJ" 'git worktree add "$WT"')"
check "glob destination denied" deny "$(bash_v "$PROJ" 'git worktree add ../proj-worktrees/*')"
check "variable in git -C denied" deny \
    "$(bash_v "$PROJ" 'git -C "$REPO" worktree add ../proj-worktrees/x')"
check "variable in cd denied" deny \
    "$(bash_v "$PROJ" 'cd "$WD" && git worktree add ../proj-worktrees/x')"
check "unbalanced quote denied" deny "$(bash_v "$PROJ" 'git worktree add "../x')"
check "cd into a repo subfolder resolves the real destination" deny \
    "$(bash_v "$TMP" 'cd proj/sub && git worktree add ../proj-worktrees/d')"
check "cd inside a subshell does not leak" allow \
    "$(bash_v "$TMP" '(cd proj/sub && true) && git worktree add ../proj-worktrees/g')"
check "cd to the repo root then hydra path allowed" allow \
    "$(bash_v "$TMP" 'cd proj && git worktree add ../proj-worktrees/k')"
check "git -C repo then hydra path allowed" allow \
    "$(bash_v "$TMP" 'git -C proj worktree add ../proj-worktrees/h')"
check "git -C subfolder resolves the real destination" deny \
    "$(bash_v "$TMP" 'git -C proj/sub worktree add ../proj-worktrees/h')"
check "inside a hydra worktree, hydra path allowed" allow \
    "$(bash_v "$HYD/w1" 'git worktree add ../../proj-worktrees/w2')"
check "inside a hydra worktree, sibling denied" deny \
    "$(bash_v "$HYD/w1" 'git worktree add ../../other/w3')"

# 5. other git and shell commands are not checked
check "git status allowed" allow "$(bash_v "$PROJ" 'git status')"
check "git worktree list allowed" allow "$(bash_v "$PROJ" 'git worktree list')"
check "git -C worktree list allowed" allow "$(bash_v "$TMP" "git -C $PROJ worktree list")"
check "git worktree remove allowed" allow "$(bash_v "$PROJ" "git worktree remove $HYD/w1")"
check "git worktree prune allowed" allow "$(bash_v "$PROJ" 'git worktree prune')"
check "quoted text mentioning worktree add allowed" allow \
    "$(bash_v "$PROJ" 'echo "git worktree add ../other/x"')"
check "grep for worktree allowed" allow "$(bash_v "$PROJ" 'grep -rn worktree plugins')"

# 5b. heredoc bodies, comments and command position (only `git` as a command counts)
check "heredoc body with git worktree add allowed" allow \
    "$(bash_v "$PROJ" $'cat > notes.md <<\'EOF\'\ngit worktree add ../other/x\nEOF')"
check "tab-stripped heredoc body allowed" allow \
    "$(bash_v "$PROJ" $'cat <<-EOF\n\tgit worktree add ../other/x\n\tEOF')"
check "commit message heredoc with apostrophe allowed" allow \
    "$(bash_v "$PROJ" $'git commit -F - <<\'EOF\'\nfix: don\'t drop git worktree add guard\nEOF')"
check "unbalanced quote in heredoc body allowed" allow \
    "$(bash_v "$PROJ" $'git commit -F - <<\'EOF\'\nit\'s done\nEOF')"
check "comment with git worktree add allowed" allow \
    "$(bash_v "$PROJ" '# example: git worktree add ../other/x')"
check "echo of git worktree add allowed" allow "$(bash_v "$PROJ" 'echo git worktree add ../other/x')"
check "git worktree add after heredoc denied" deny \
    "$(bash_v "$PROJ" $'cat > notes.md <<\'EOF\'\nbody\nEOF\ngit worktree add ../other/x')"
check "git worktree add after a comment line denied" deny \
    "$(bash_v "$PROJ" $'# note\ngit worktree add ../other/x')"
check "hash inside quotes is no comment" deny "$(bash_v "$PROJ" "echo '# x'; git worktree add ../other/x")"
check "hash inside a word is no comment" deny "$(bash_v "$PROJ" 'echo a#b; git worktree add ../other/x')"
check "quoted << is no heredoc" deny "$(bash_v "$PROJ" $'echo "<<EOF"\ngit worktree add ../other/x')"
check "env assignment before git denied" deny "$(bash_v "$PROJ" 'FOO=1 git worktree add ../other/x')"
check "wrapper word before git denied" deny "$(bash_v "$PROJ" 'env git worktree add ../other/x')"
check "pipe into git worktree add denied" deny "$(bash_v "$PROJ" 'echo x | git worktree add ../other/x')"
check "if-wrapped git worktree add denied" deny \
    "$(bash_v "$PROJ" 'if git worktree add ../other/x; then :; fi')"
check "unparseable text with git worktree add denied" deny \
    "$(bash_v "$PROJ" 'echo "oops" ; git worktree add ../other/x ; echo "unclosed')"
check "unparseable text without git worktree add allowed" allow \
    "$(bash_v "$PROJ" 'echo "unclosed worktree add')"

# 6. fail open and output format
check "invalid json allowed" allow "$(verdict 'not json')"
check "empty stdin allowed" allow "$(verdict '')"
check "json list allowed" allow "$(verdict '[]')"
check "bash without command allowed" allow "$(verdict '{"tool_name":"Bash","tool_input":{}}')"
check "non-string command allowed" allow "$(verdict '{"tool_name":"Bash","tool_input":{"command":123}}')"
run_hook 'not json' >/dev/null
check "exit 0 on invalid json" 0 "$?"
run_hook "$(json_for Agent "$PROJ" "" worktree)" >/dev/null
check "exit 0 on deny" 0 "$?"
check "allow prints nothing" 0 "$(run_hook "$(json_for Agent "$PROJ" "" "")" | wc -c | tr -d ' ')"
check "deny output is a PreToolUse deny with the flow hint" "PreToolUse deny True True" \
    "$(run_hook "$(json_for Agent "$PROJ" "" worktree)" | python3 -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
r = d["permissionDecisionReason"]
print(d["hookEventName"], d["permissionDecision"], "/hydra:create" in r, "worktree-setup.sh" in r)')"

# 7. wiring in hooks/hooks.json
check "hooks.json wires the guard for Agent, Task, EnterWorktree and Bash" ok \
    "$(python3 - "$HOOKS_JSON" <<'PY'
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
ok = any(set(g["matcher"].split("|")) >= {"Agent", "Task", "EnterWorktree", "Bash"}
         and any(h["command"].endswith("/hooks/worktree-guard.sh") for h in g["hooks"])
         for g in groups)
print("ok" if ok else "bad")
PY
)"

echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

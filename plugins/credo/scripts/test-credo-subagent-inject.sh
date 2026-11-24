#!/usr/bin/env bash
# Tests for hooks/credo-subagent-inject.sh: the injected rule block carries the
# no-delete rule for every full-block subagent, and the light block (Explore, Plan)
# stays light.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../hooks/credo-subagent-inject.sh"
SID="11111111-2222-3333-4444-555555555555"

pass=0
fail=0
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg"
export CLAUDE_PROJECT_DIR="$TMP/proj"
export CREDO_TASK_BACKEND=credo
mkdir -p "$CLAUDE_PROJECT_DIR"
cd "$TMP" || exit 1

check() { # name, want, got
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 (want $2, got $3)"
    fi
}

# ctx_of <agent_type>: the additionalContext the hook injects ("" when none)
ctx_of() {
    jq -n --arg t "$1" --arg s "$SID" '{session_id: $s, agent_type: $t, hook_event_name: "SubagentStart"}' \
        | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

# has <name> <phrase> <context>: the phrase occurs literally in the context
has() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        check "$1" yes yes
    else
        check "$1" yes no
    fi
}

NO_DELETE="Never run a delete (rm, rm -rf, find -delete, unlink) whose target path contains a shell variable"
VAR_FORMS='($X, ${X} or $(...))'
LITERAL_PATH="Write the literal path instead"
NEW_DIR="create a NEW literal scratch dir"
PROMPT_RISK="can raise a permission prompt that blocks the whole run"

# --- full block: general-purpose subagent carries the narrowed no-delete rule -------
gp_ctx="$(ctx_of general-purpose)"
has "general-purpose: variable-target delete rule present" "$NO_DELETE" "$gp_ctx"
has "general-purpose: variable forms named" "$VAR_FORMS" "$gp_ctx"
has "general-purpose: literal path instead" "$LITERAL_PATH" "$gp_ctx"
has "general-purpose: new scratch dir instead" "$NEW_DIR" "$gp_ctx"
has "general-purpose: unattended prompt risk named" "$PROMPT_RISK" "$gp_ctx"
has "general-purpose: security rule still present" "SECURITY (inherited, non-negotiable)" "$gp_ctx"
has "general-purpose: background shells forbidden" "run_in_background" "$gp_ctx"

# --- decisions: uncritical questions are decided per SOTA, needs_decision only owner-only
has "DECISIONS: uncritical questions decided by the subagent" "decide uncritical questions yourself" "$gp_ctx"
has "DECISIONS: self-deciding limited to GO or agent-owned items" "on a GO item or an agent-owned item (clarify_owner: agent), decide" "$gp_ctx"
has "DECISIONS: human-owned clarify questions go back" "Open questions of a human-owned clarify item (clarify_owner: human) always go back as needs_decision" "$gp_ctx"
has "DECISIONS: SOTA > best effort > note order" "the best possible solution (SOTA), else best effort, else note it for the owner" "$gp_ctx"
has "DECISIONS: per-repo grant honoured" "per-repo grant" "$gp_ctx"
has "DECISIONS: decision logged in the report" "Log each such decision with its reason in your report" "$gp_ctx"
has "DECISIONS: needs_decision only for owner-only decisions" "Return {status: needs_decision, question: ...} only for a genuine owner-only decision" "$gp_ctx"
for kind in "taste or preference" "money" "deleting user data" "installs" "safety" "infeasible"; do
    has "DECISIONS: owner-only case named: $kind" "$kind" "$gp_ctx"
done
case "$gp_ctx" in
    *"If you hit a blocking decision you cannot resolve, return"*) check "DECISIONS: old catch-all needs_decision line gone" no yes ;;
    *) check "DECISIONS: old catch-all needs_decision line gone" no no ;;
esac

# --- no-block commands: no long inline code, literal paths, local bins, filename -------
has "NO-BLOCK: block present" "NO-BLOCK COMMANDS:" "$gp_ctx"
has "NO-BLOCK: inline code forms named" "python -c, node -e, perl -e, ruby -e, bash -c, powershell -Command, a heredoc or pipe into an interpreter" "$gp_ctx"
has "NO-BLOCK: steering reason (error-prone, hooks)" "huge commands are error-prone and often stopped by hooks" "$gp_ctx"
has "NO-BLOCK: guard limit named" "guards.inline_code_max characters, default 1500" "$gp_ctx"
has "NO-BLOCK: splitting into smaller commands allowed" "split the work into several smaller commands (allowed)" "$gp_ctx"
has "NO-BLOCK: script into the session TMPDIR" "Write the script (.py/.sh/.ps1) to the session TMPDIR (\$TMPDIR, normally /tmp/credo-tmp-<uid>/<session id>/" "$gp_ctx"
has "NO-BLOCK: separate call with a literal path" "run it in a separate call with a literal path" "$gp_ctx"
has "NO-BLOCK: PowerShell script from WSL" "powershell.exe -File \"\$(wslpath -w <path>)\"" "$gp_ctx"
has "NO-BLOCK: own-rm with the literal helper path" "delete it with python3 $(cd "$HERE" && pwd)/credo-cleanup.py own-rm <literal path>" "$gp_ctx"
has "NO-BLOCK: own-rm also for subagent files" "also when a subagent wrote them" "$gp_ctx"
has "NO-BLOCK: never write and run in one command" "Never write and run a file in the same command" "$gp_ctx"
has "NO-BLOCK: no variable script paths" 'No VAR=$(...); $VAR/script calls - use literal paths' "$gp_ctx"
has "NO-BLOCK: Edit per file, no sed -i loop on \$var" 'Multi-file edits: the Edit tool per file with a literal path (or one literal sed per file), never for f in ...; do sed -i ... $f or any $var as a target path' "$gp_ctx"
has "NO-BLOCK: why (readable, passes dogma)" "more readable, reviewable, and it passes dogma without a prompt" "$gp_ctx"
has "NO-BLOCK: Read tool, no cat loops" "Read files with the Read tool (no cat loops to dump sources), no for-loops over files" "$gp_ctx"
has "NO-BLOCK: redirects only into TMPDIR or scratchpad" "redirect (> or >>) only into the session TMPDIR or scratchpad" "$gp_ctx"
has "NO-BLOCK: local bin over npx" "prefer ./node_modules/.bin/<tool> over npx" "$gp_ctx"
has "NO-BLOCK: Playwright filename parameter" "browser_run_code: put long code in a file and pass the filename parameter" "$gp_ctx"
case "$(ctx_of Explore)" in
    *"NO-BLOCK COMMANDS:"*) check "Explore: light block has no NO-BLOCK block" no yes ;;
    *) check "Explore: light block has no NO-BLOCK block" no no ;;
esac

# --- full block: unknown or empty agent_type gets the same rule ---------------------
empty_ctx="$(ctx_of "")"
has "empty agent_type: no-delete rule present" "$NO_DELETE" "$empty_ctx"

# --- light block: Explore and Plan keep only the time line --------------------------
explore_ctx="$(ctx_of Explore)"
case "$explore_ctx" in
    *"$NO_DELETE"*) check "Explore: light block has no full rule set" no yes ;;
    *) check "Explore: light block has no full rule set" no no ;;
esac
case "$explore_ctx" in
    *"[credo-now]"*) check "Explore: fresh time line kept" yes yes ;;
    *) check "Explore: fresh time line kept" yes no ;;
esac

# --- git: main checkout modifies files only, an own linked worktree may commit ------
has "GIT: main checkout modifies files only" "in the main checkout modify files only" "$gp_ctx"
has "GIT: own linked worktree exception" "OWN linked git worktree" "$gp_ctx"
has "GIT: worktree commits when the brief asks" "commit on your worktree branch when your brief asks for it" "$gp_ctx"
has "GIT: never push, merge or release" "Never push, merge or release" "$gp_ctx"
has "GIT: gitignored files never committed" ".gitignore-d files" "$gp_ctx"

# --- worktrees: .credo/ changes go to the main checkout path (#141) ----------------------
has "WORKTREE: .credo changes go to the main checkout path" "write every .credo/ change" "$gp_ctx"
has "WORKTREE: first path of git worktree list" "the first path of git worktree list" "$gp_ctx"
has "WORKTREE: never into the worktree copy" "never into the worktree copy" "$gp_ctx"

# --- claims: blocker and owner-decision claims are proposals ------------------------
has "CLAIMS: blocker claims are proposals" "your blocker and owner-decision claims are proposals" "$gp_ctx"
has "CLAIMS: the main agent verifies the cited source" "the main agent verifies them (reads the cited source)" "$gp_ctx"
has "CLAIMS: cite file:line or command output" "Cite the file:line or command output" "$gp_ctx"

# --- RULES.md first: only where the project carries .credo/RULES.md ----------------
RULES_LINE="PROJECT RULES: this repo has .credo/RULES.md. Read it first"
RULES_OVERRIDE="Its rules override these credo defaults"
case "$gp_ctx" in
    *"$RULES_LINE"*) rules_absent=no ;;
    *) rules_absent=yes ;;
esac
check "no .credo/RULES.md: no RULES-first line" yes "$rules_absent"
mkdir -p "$CLAUDE_PROJECT_DIR/.credo"
printf '# per-repo rules\n' > "$CLAUDE_PROJECT_DIR/.credo/RULES.md"
rules_ctx="$(ctx_of general-purpose)"
has "RULES.md in the project dir: RULES-first line" "$RULES_LINE" "$rules_ctx"
has "RULES.md: overrides the credo defaults" "$RULES_OVERRIDE" "$rules_ctx"
has "RULES.md: safety rules are never lowered" "never lower the safety rules above" "$rules_ctx"
case "$rules_ctx" in
    *"$RULES_LINE"*) rules_before_security=yes ;;
    *) rules_before_security=no ;;
esac
check "RULES.md line sits before the SECURITY block" yes "$rules_before_security"
case "$(ctx_of Explore)" in
    *"$RULES_LINE"*) check "Explore: light block has no RULES-first line" no yes ;;
    *) check "Explore: light block has no RULES-first line" no no ;;
esac

# a RULES.md in the hook input cwd counts too (the project dir has none here)
mkdir -p "$TMP/cwdrepo/.credo" "$TMP/emptyproj"
printf '# per-repo rules\n' > "$TMP/cwdrepo/.credo/RULES.md"
cwd_ctx="$(jq -n --arg c "$TMP/cwdrepo" --arg s "$SID" \
    '{session_id: $s, agent_type: "general-purpose", cwd: $c, hook_event_name: "SubagentStart"}' \
    | CLAUDE_PROJECT_DIR="$TMP/emptyproj" bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
has "RULES.md in the hook input cwd: RULES-first line" "$RULES_LINE" "$cwd_ctx"

# --- output shape: SubagentStart JSON, no chat output -------------------------------
raw="$(jq -n --arg s "$SID" '{session_id: $s, agent_type: "general-purpose", hook_event_name: "SubagentStart"}' \
    | bash "$HOOK" 2>/dev/null)"
check "output event name is SubagentStart" SubagentStart \
    "$(printf '%s' "$raw" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
check "output is suppressed from the chat" true \
    "$(printf '%s' "$raw" | jq -r '.suppressOutput' 2>/dev/null)"

# --- session pin: the task backend comes from the session's pinned repo -----------
# Backend gsd drops the credo item clause; credo keeps it. The pin is found only
# through the session_id from the hook's stdin (no CREDO_SESSION_ID in the env).
PIN_DIR="$TMP/pins"
PIN_REPO="$TMP/pinrepo"
mkdir -p "$PIN_DIR" "$PIN_REPO/.credo"
printf 'task_backend: gsd\n' > "$PIN_REPO/.credo/config"
printf '%s\n' "$PIN_REPO" > "$PIN_DIR/$SID"
item_ctx() { # pin dir -> the injected context for a general-purpose subagent
    jq -n --arg s "$SID" '{session_id: $s, agent_type: "general-purpose", hook_event_name: "SubagentStart"}' \
        | env -u CREDO_TASK_BACKEND -u CREDO_PROJECT -u CREDO_DIR CREDO_SESSION_PROJECTS_DIR="$1" bash "$HOOK" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
case "$(item_ctx "$TMP/nopins")" in *"Record and gate work as a credo item"*) unpinned_item=yes ;; *) unpinned_item=no ;; esac
check "no pin: credo backend keeps the item clause" yes "$unpinned_item"
case "$(item_ctx "$PIN_DIR")" in *"Record and gate work as a credo item"*) pinned_item=yes ;; *) pinned_item=no ;; esac
check "pinned gsd backend: item clause dropped" no "$pinned_item"

echo "passed: $pass failed: $fail"
[ "$fail" -eq 0 ]

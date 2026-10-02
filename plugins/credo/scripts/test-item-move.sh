#!/bin/bash
# Tests for credo-item-move.sh: the GO gate by clarify owner (clarify_owner),
# the owner flip on entry into 2_go, and that the other targets stay unaffected.
# Builds a throwaway credo project in a temp dir (removed on exit).
# Usage: bash test-item-move.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-item-move.sh"
SWEEP="$SCRIPT_DIR/credo-unblock-sweep.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-item-move-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
contains() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}
lacks() { # name needle haystack
    case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n  in:         %s\n' "$1" "$2" "$3" ;; *) PASS=$((PASS + 1)) ;; esac
}

export CREDO_DIR="$TMP/.credo"
I="$CREDO_DIR/items"
mkdir -p "$I/1_todo/1_clarify" "$I/1_todo/2_go" "$I/1_todo/3_blocked" "$I/2_done" "$I/parked/hold"
unset CREDO_VERIFIED_USER_AUTHORIZED

item() { # id folder frontmatter-extra history-lines
    printf -- "---\nid: %s\ntitle: Item %s\ncreated: 2026-01-01\ntype: feature\nui: false\n$3---\n\n## Requirement (verbatim)\n\n> do it\n\n## History\n\n- created (clarify) 2026-01-01\n$4" \
        "$1" "$1" > "$I/$2/$1-item-$1.md"
}
where() { # id -> folder relative to items/
    local f; f="$(find "$I" -type f -name "$1-*.md" | head -n1)"
    f="${f#"$I"/}"; printf '%s' "${f%/*}"
}
file_of() { find "$I" -type f -name "$1-*.md" | head -n1; }
owner_of() { awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f' "$(file_of "$1")" | sed -n 's/^clarify_owner:[[:space:]]*//p' | head -n1; }
last_history() { grep -E '^- ' "$(file_of "$1")" | tail -n1; }

# 1. human-owned (field missing) clarify -> go without any GO line: refused, unchanged
item 1 1_todo/1_clarify '' ''
out="$("$SUT" 1 go 2>&1)"; rc=$?
check "missing owner, no GO: exit" 1 "$rc"
check "missing owner, no GO: stays" "1_todo/1_clarify" "$(where 1)"
contains "missing owner, no GO: message names the owner" "human-owned" "$out"
contains "missing owner, no GO: message names the fix" "--user-authorized" "$out"

# 2. explicit human owner with only an agent GO line: refused
item 2 1_todo/1_clarify 'clarify_owner: human\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, default is clear)\n'
out="$("$SUT" 2 go 2>&1)"; rc=$?
check "human owner, agent GO: exit" 1 "$rc"
check "human owner, agent GO: stays" "1_todo/1_clarify" "$(where 2)"

# 3. human owner with a user GO quote: moved, owner flips to agent, origin kept in History
item 3 1_todo/1_clarify 'clarify_owner: human\n' '- -> go 2026-01-02 (GO: "yes build it", chat)\n'
out="$("$SUT" 3 go 2>&1)"; rc=$?
check "human owner, user GO: exit" 0 "$rc"
check "human owner, user GO: moved" "1_todo/2_go" "$(where 3)"
check "human owner, user GO: owner flipped" "agent" "$(owner_of 3)"
contains "human owner, user GO: origin noted" "created by user" "$(cat "$(file_of 3)")"
contains "human owner, user GO: last History line targets go" "- -> go " "$(last_history 3)"
check "human owner, user GO: exactly one clarify_owner line" "1" "$(grep -c '^clarify_owner:' "$(file_of 3)")"

# 4. missing owner + --user-authorized and no GO line: moved (G1 warning still printed)
item 4 1_todo/1_clarify '' ''
out="$("$SUT" 4 go --user-authorized 2>&1)"; rc=$?
check "user-authorized go: exit" 0 "$rc"
check "user-authorized go: moved" "1_todo/2_go" "$(where 4)"
check "user-authorized go: owner flipped" "agent" "$(owner_of 4)"
contains "user-authorized go: G1 warning" "WARNING" "$out"

# 5. the verified env opt-in does NOT authorize a GO
item 5 1_todo/1_clarify '' ''
out="$(CREDO_VERIFIED_USER_AUTHORIZED=1 "$SUT" 5 go 2>&1)"; rc=$?
check "verified env is not a GO: exit" 1 "$rc"
check "verified env is not a GO: stays" "1_todo/1_clarify" "$(where 5)"

# 6. agent-owned clarify item with an agent SOTA GO line: moved, owner stays agent
item 6 1_todo/1_clarify 'clarify_owner: agent\nparent: 3\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, standard approach, no user taste involved)\n'
out="$("$SUT" 6 go 2>&1)"; rc=$?
check "agent owner, agent GO: exit" 0 "$rc"
check "agent owner, agent GO: moved" "1_todo/2_go" "$(where 6)"
check "agent owner, agent GO: owner" "agent" "$(owner_of 6)"
lacks "agent owner, agent GO: no human origin line" "created by user" "$(cat "$(file_of 6)")"
contains "agent owner, agent GO: parent kept" "parent: 3" "$(cat "$(file_of 6)")"

# 7. agent-owned clarify item without any GO line: refused (the decision must be logged)
item 7 1_todo/1_clarify 'clarify_owner: agent\nparent: 3\n' ''
out="$("$SUT" 7 go 2>&1)"; rc=$?
check "agent owner, no GO: exit" 1 "$rc"
check "agent owner, no GO: stays" "1_todo/1_clarify" "$(where 7)"
contains "agent owner, no GO: message" "(GO: agent per SOTA rule" "$out"

# 8. a GO line only inside an HTML comment (template example) does not count
item 8 1_todo/1_clarify '' '<!--\n## History\n- -> go 2026-07-04 (GO: the user, chat 2026-07-04)\n-->\n'
out="$("$SUT" 8 go 2>&1)"; rc=$?
check "GO only in comment: exit" 1 "$rc"
check "GO only in comment: stays" "1_todo/1_clarify" "$(where 8)"

# 9. a GO quote outside the History section does not count
printf -- "---\nid: 9\ntitle: t\ncreated: 2026-01-01\ntype: feature\nui: false\n---\n\n## Requirement (verbatim)\n\n> say (GO: yes) later\n\n## History\n\n- created (clarify) 2026-01-01\n" > "$I/1_todo/1_clarify/9-item-9.md"
out="$("$SUT" 9 go 2>&1)"; rc=$?
check "GO outside History: exit" 1 "$rc"

# 10. unknown owner value is treated as human (fail-safe)
item 10 1_todo/1_clarify 'clarify_owner: robot\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 10 go 2>&1)"; rc=$?
check "unknown owner = human: exit" 1 "$rc"

# 11. detour via parked/hold does not bypass the gate
item 11 1_todo/1_clarify '' ''
"$SUT" 11 hold >/dev/null 2>&1; rc=$?
check "clarify -> hold unaffected: exit" 0 "$rc"
out="$("$SUT" 11 go 2>&1)"; rc=$?
check "hold -> go human, no GO: exit" 1 "$rc"
check "hold -> go human, no GO: stays" "parked/hold" "$(where 11)"

# 12. detour via 3_blocked --unblock-to go + auto-unblock sweep does not bypass the gate
item 12 2_done '' '- -> go 2026-01-02 (GO: "ok", chat)\n- -> done 2026-01-03 (audit passed)\n'
item 13 1_todo/1_clarify 'blocked_by: [12]\n' ''
"$SUT" 13 blocked --unblock-to go >/dev/null 2>&1; rc=$?
check "human clarify -> blocked: exit" 0 "$rc"
CREDO_DIR="$CREDO_DIR" "$SWEEP" "$CREDO_DIR" >/dev/null 2>&1
check "sweep cannot GO a human item" "1_todo/3_blocked" "$(where 13)"

# 13. legacy GO'd item (no owner field, user GO line) returns from 3_blocked via the sweep
item 14 1_todo/3_blocked 'blocked_by: [12]\nunblock_to: go\n' '- -> go 2026-01-02 (GO: "build it", chat)\n- -> blocked 2026-01-02 (needs #12)\n'
CREDO_DIR="$CREDO_DIR" "$SWEEP" "$CREDO_DIR" >/dev/null 2>&1
check "legacy GO'd item unblocks" "1_todo/2_go" "$(where 14)"
check "legacy GO'd item owner flipped" "agent" "$(owner_of 14)"
contains "legacy GO'd item: sweep line is last" "auto-unblock" "$(last_history 14)"

# 14. an item already agent-owned (was in go) goes back to clarify for an agent-internal
# re-clarify (--keep-owner) and returns with an agent GO
"$SUT" 3 clarify --keep-owner >/dev/null 2>&1
check "keep-owner re-clarify: owner stays agent" "agent" "$(owner_of 3)"
printf -- '- -> clarify 2026-01-04 (follow-up question)\n- -> go 2026-01-04 (GO: agent per SOTA rule, safer default)\n' >> "$(file_of 3)"
out="$("$SUT" 3 go 2>&1)"; rc=$?
check "agent-owned re-GO: exit" 0 "$rc"
check "agent-owned re-GO: one origin line only" "1" "$(grep -c 'created by user' "$(file_of 3)")"

# 15. other targets ignore the owner gate
item 15 1_todo/1_clarify '' ''
"$SUT" 15 hold >/dev/null 2>&1; rc=$?
check "non-go target unaffected" 0 "$rc"

# 16. item without frontmatter clarify_owner and without History section, user-authorized
printf -- "---\nid: 16\ntitle: t\ncreated: 2026-01-01\ntype: chore\nui: false\n---\n\nbody\n" > "$I/1_todo/1_clarify/16-item-16.md"
out="$("$SUT" 16 go --user-authorized 2>&1)"; rc=$?
check "no History section: exit" 0 "$rc"
check "no History section: owner flipped" "agent" "$(owner_of 16)"
contains "no History section: History created" "## History" "$(cat "$(file_of 16)")"

# --- slicing bypass: agent-owned children of a not yet GO'd parent -----------------
# 17. human parent still in 1_clarify: an agent GO of its child is refused
item 20 1_todo/1_clarify '' ''
item 21 1_todo/1_clarify 'clarify_owner: agent\nparent: 20\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, slice)\n'
out="$("$SUT" 21 go 2>&1)"; rc=$?
check "child of clarify parent, agent GO: exit" 1 "$rc"
check "child of clarify parent, agent GO: stays" "1_todo/1_clarify" "$(where 21)"
contains "child of clarify parent: message names the parent" "parent #20" "$out"

# 18. parent parked on hold: still refused
"$SUT" 20 hold >/dev/null 2>&1
out="$("$SUT" 21 go 2>&1)"; rc=$?
check "child of parked parent, agent GO: exit" 1 "$rc"

# 19. the user GO'd the child itself: allowed even while the parent is not GO'd
item 22 1_todo/1_clarify 'clarify_owner: agent\nparent: 20\n' '- -> go 2026-01-02 (GO: "build this slice", chat)\n'
out="$("$SUT" 22 go 2>&1)"; rc=$?
check "child with user GO, parent parked: exit" 0 "$rc"

# 20. parent GO'd (in 2_go): the agent GO of the child is allowed
printf -- '- -> go 2026-01-03 (GO: "go", chat)\n' >> "$(file_of 20)"
"$SUT" 20 go >/dev/null 2>&1
check "parent GO'd: in go" "1_todo/2_go" "$(where 20)"
out="$("$SUT" 21 go 2>&1)"; rc=$?
check "child of GO'd parent, agent GO: exit" 0 "$rc"
check "child of GO'd parent, agent GO: moved" "1_todo/2_go" "$(where 21)"

# 21. parent in 3_blocked WITH a GO: allowed; parent in 3_blocked from clarify (no GO): refused
item 23 1_todo/3_blocked 'blocked_by: [12]\nunblock_to: go\n' '- -> go 2026-01-02 (GO: "yes", chat)\n'
item 24 1_todo/1_clarify 'clarify_owner: agent\nparent: 23\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 24 go 2>&1)"; rc=$?
check "child of blocked GO'd parent: exit" 0 "$rc"
item 25 1_todo/3_blocked 'blocked_by: [12]\nunblock_to: clarify\n' ''
item 26 1_todo/1_clarify 'clarify_owner: agent\nparent: 25\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 26 go 2>&1)"; rc=$?
check "child of blocked un-GO'd parent: exit" 1 "$rc"

# 22. parent delivered (2_done): allowed; parent missing or archived: refused
item 27 1_todo/1_clarify 'clarify_owner: agent\nparent: 12\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 27 go 2>&1)"; rc=$?
check "child of done parent: exit" 0 "$rc"
item 28 1_todo/1_clarify 'clarify_owner: agent\nparent: 999\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 28 go 2>&1)"; rc=$?
check "child of missing parent: exit" 1 "$rc"
item 29 1_todo/1_clarify '' ''
"$SUT" 29 archived >/dev/null 2>&1
item 30 1_todo/1_clarify 'clarify_owner: agent\nparent: 29\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 30 go 2>&1)"; rc=$?
check "child of archived parent: exit" 1 "$rc"

# --- hand-edit bypass: clarify_owner: agent without a provable origin --------------
# 23. hand-set agent owner, no parent, no "created by agent", no flip line: treated as human
item 31 1_todo/1_clarify 'clarify_owner: agent\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 31 go 2>&1)"; rc=$?
check "hand-edited agent owner: exit" 1 "$rc"
check "hand-edited agent owner: stays" "1_todo/1_clarify" "$(where 31)"
contains "hand-edited agent owner: message" "treated as human" "$out"

# 24. agent item created as such ("created by agent" in History): allowed
printf -- "---\nid: 32\ntitle: t\ncreated: 2026-01-01\ntype: chore\nui: false\nclarify_owner: agent\n---\n\n## History\n\n- created by agent (clarify) 2026-01-01 (build question)\n- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n" > "$I/1_todo/1_clarify/32-item-32.md"
out="$("$SUT" 32 go 2>&1)"; rc=$?
check "created by agent: exit" 0 "$rc"

# 25. "created by agent" only inside an HTML comment does not count
item 33 1_todo/1_clarify 'clarify_owner: agent\n' '<!--\n- created by agent (clarify) 2026-01-01\n-->\n- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
out="$("$SUT" 33 go 2>&1)"; rc=$?
check "created by agent in comment only: exit" 1 "$rc"

# --- entry into 1_clarify resets the owner to human --------------------------------
# 26. a GO'd item sent back (no --keep-owner) becomes human, logged; a hand-edit back to
# agent does not resurrect the earlier flip
item 34 1_todo/1_clarify '' '- -> go 2026-01-02 (GO: "ok", chat)\n'
"$SUT" 34 go >/dev/null 2>&1
check "reset: GO'd item agent" "agent" "$(owner_of 34)"
out="$("$SUT" 34 clarify 2>&1)"; rc=$?
check "reset: send back exit" 0 "$rc"
check "reset: owner human" "human" "$(owner_of 34)"
contains "reset: logged in History" "clarify_owner agent -> human" "$(cat "$(file_of 34)")"
contains "reset: printed" "clarify_owner" "$out"
sed -i 's/^clarify_owner: human/clarify_owner: agent/' "$(file_of 34)"
printf -- '- -> go 2026-01-05 (GO: agent per SOTA rule, sneaky)\n' >> "$(file_of 34)"
out="$("$SUT" 34 go 2>&1)"; rc=$?
check "reset then hand-edit: exit" 1 "$rc"
check "reset then hand-edit: stays" "1_todo/1_clarify" "$(where 34)"

# 26b. without a hand edit: the user GO given before the send-back does not carry over
item 37 1_todo/1_clarify '' '- -> go 2026-01-02 (GO: "ok", chat)\n'
"$SUT" 37 go >/dev/null 2>&1
"$SUT" 37 clarify >/dev/null 2>&1
out="$("$SUT" 37 go 2>&1)"; rc=$?
check "old user GO after send-back: exit" 1 "$rc"
printf -- '- -> go 2026-01-06 (GO: "decided, go", chat)\n' >> "$(file_of 37)"
out="$("$SUT" 37 go 2>&1)"; rc=$?
check "new user GO after send-back: exit" 0 "$rc"

# 26c. a child the user GO'd while its parent was undecided keeps its agent origin
contains "child user GO: origin names the parent" "origin: created by agent, parent #20" "$(cat "$(file_of 22)")"

# 27. done -> clarify (bug found) also resets to human
item 35 1_todo/1_clarify 'clarify_owner: agent\nparent: 12\n' '- -> go 2026-01-02 (GO: agent per SOTA rule, x)\n'
"$SUT" 35 go >/dev/null 2>&1
"$SUT" 35 done >/dev/null 2>&1
"$SUT" 35 clarify >/dev/null 2>&1
check "done -> clarify: owner human" "human" "$(owner_of 35)"

# 28. --keep-owner only applies to target clarify
out="$("$SUT" 35 hold --keep-owner 2>&1)"; rc=$?
check "keep-owner on non-clarify target: exit" 1 "$rc"
check "keep-owner on non-clarify target: stays" "1_todo/1_clarify" "$(where 35)"

# --- unblock sweep ----------------------------------------------------------------
# 29. all blockers done but the GO gate refuses (item 13 from case 12): visible in pass 2
out="$(CREDO_DIR="$CREDO_DIR" "$SWEEP" "$CREDO_DIR" 2>&1)"
contains "sweep: refused GO surfaced" "#13 all blockers done, GO gate refused:" "$out"
contains "sweep: reason shown" "human-owned" "$out"

# 30. auto-unblock back to clarify keeps the owner (not a send-back)
item 36 1_todo/3_blocked 'clarify_owner: agent\nparent: 12\nblocked_by: [12]\nunblock_to: clarify\n' ''
CREDO_DIR="$CREDO_DIR" "$SWEEP" "$CREDO_DIR" >/dev/null 2>&1
check "sweep -> clarify: moved" "1_todo/1_clarify" "$(where 36)"
check "sweep -> clarify: owner kept" "agent" "$(owner_of 36)"

printf 'passed: %s, failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# Tests for the unattended ask -> deny switch (lib-decision.sh, used by file-protection.sh and
# git-permissions.sh) and for the session-dir exemption of redirect truncations (delete-guard.py
# session_truncate).
#
# SAFETY: the hooks only ANALYSE command text; no test command is ever executed. Every path lives in a
# fresh mktemp directory with a fake HOME, a fake credo autonomy dir and fake session dir bases inside it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

T="$(mktemp -d)"
case "$T" in /tmp/?*) ;; *) echo "refusing: mktemp gave $T"; exit 1 ;; esac
trap 'rm -rf -- "$T"' EXIT
T="$(cd "$T" && pwd -P)"
FH="$T/home/u"                      # fake HOME (not a temp root for the guard)
PROJ="$FH/proj"                     # a project folder with [?] for deletes and git add
AUTO="$T/autonomy"                  # CREDO_AUTONOMY_DIR
SID="sess-1"
mkdir -p "$PROJ/test" "$PROJ/src" "$AUTO"
printf '<permissions>\n- [?] (§0lgy) May delete files\n- [?] (§6gpt) git add\n- [x] (§2w1t) git commit\n- [ ] (§bww9) git push\n</permissions>\n' \
    > "$PROJ/DOGMA-PERMISSIONS.md"

# fake session bases: <TB>/<sid> is the credo session TMPDIR, <SB>/<project>/<sid>/scratchpad the scratchpad
TB="$T/credo-tmp"
SB="$T/claude"
mkdir -p "$TB/$SID" "$TB/sess-2" "$SB/-home-u-proj/$SID/scratchpad" "$SB/-home-u-proj/sess-2/scratchpad" "$T/elsewhere"
ln -s "$T/elsewhere" "$SB/-home-u-proj/$SID/scratchpad/escape"   # a link inside the scratchpad leading out
ln -s "$FH/.bashrc" "$SB/-home-u-proj/$SID/scratchpad/rc.txt"   # a file link leading into the home

PASS=0
FAIL=0

# autonomy <state> for SID: off | active | paused | broken (active is a directory, not a file)
autonomy() {
    rm -rf -- "${AUTO:?}/$SID"
    case "$1" in
        active) mkdir -p "$AUTO/$SID" && : > "$AUTO/$SID/active" ;;
        paused) mkdir -p "$AUTO/$SID" && : > "$AUTO/$SID/active" && : > "$AUTO/$SID/paused" ;;
        broken) mkdir -p "$AUTO/$SID/active" "$AUTO/$SID/paused" ;;
    esac
}

# hook <script> <command> [session id] -> raw hook output; extra env via the caller (OFF=...)
hook() {
    local input
    input="$(jq -n --arg c "$2" --arg d "$PROJ" --arg s "${3-$SID}" \
        'if $s == "" then {tool_name: "Bash", tool_input: {command: $c}, cwd: $d}
         else {tool_name: "Bash", tool_input: {command: $c}, cwd: $d, session_id: $s} end')"
    (cd "$PROJ" && printf '%s' "$input" | HOME="$FH" CLAUDE_MB_DOGMA_ENABLED=true CLAUDE_MB_DOGMA_FILE_PROTECTION=true \
        CLAUDE_MB_DOGMA_GIT_PERMISSIONS=true CLAUDE_MB_DOGMA_UNATTENDED_DENY="${OFF:-true}" DOGMA_CREDO_CONFIG=none \
        DOGMA_SESSION_DIR="$PROJ" CREDO_AUTONOMY_DIR="$AUTO" DOGMA_SESSION_TMP_BASE="$TB" DOGMA_SESSION_SCRATCH_BASE="$SB" \
        bash "$HERE/$1" 2>/dev/null)
}
decision() {
    case "$1" in *'"deny"'*) echo deny ;; *'"ask"'*) echo ask ;; *) echo allow ;; esac
}
expect() { # want script command [session id]
    local got
    got="$(decision "$(hook "$2" "$3" "${4-$SID}")")"
    if [ "$got" = "$1" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL want %s got %s: %s %s (sid %s)\n' "$1" "$got" "$2" "$3" "${4-$SID}"; fi
}
expect_text() { # label haystack needle
    case "$2" in *"$3"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s: missing "%s" in %s\n' "$1" "$3" "$2" ;; esac
}

REPRO='for f in a b; do sed -i "s#x#y#" test/$f.test.ts; done'
FP=file-protection.sh
GP=git-permissions.sh

# --- interactive (no autonomy state): the ask stays
autonomy off
expect ask  $FP "$REPRO"
expect ask  $FP "rm -f $PROJ/src/old.txt"
expect ask  $GP "git add src/a.ts"
expect allow $GP "git commit -m x"
expect deny $GP "git push"

# --- autonomy active: every ask becomes a deny with the reason and the retry hint, nothing becomes an allow
autonomy active
expect deny $FP "$REPRO"
expect deny $FP "rm -f $PROJ/src/old.txt"
expect deny $GP "git add src/a.ts"
expect allow $GP "git commit -m x"
expect deny $GP "git push"
OUT="$(hook $FP "$REPRO")"
expect_text "repro reason kept" "$OUT" 'in-place edit test/$f.test.ts requires confirmation'
expect_text "repro variable hint" "$OUT" "retry with the literal path"
expect_text "repro unattended hint" "$OUT" "[unattended] No human can answer"
expect_text "repro edit per file" "$OUT" "the Edit or Write tool per file"
expect_no_text() { # label haystack needle
    case "$2" in *"$3"*) FAIL=$((FAIL + 1)); printf 'FAIL %s: unexpected "%s" in %s\n' "$1" "$3" "$2" ;; *) PASS=$((PASS + 1)) ;; esac
}
expect_no_text "repro: no git showstopper hint" "$OUT" "showstopper"
# git asks get their own hint: an unconfirmed commit/push is a showstopper per credo (ntfy + stop)
OUT="$(hook $GP "git add src/a.ts")"
expect_text "git add reason kept" "$OUT" "git add requires confirmation"
expect_text "git add showstopper hint" "$OUT" "[unattended] git add needs the owner's OK here (DOGMA [?]); per credo this is a showstopper in an autonomous run: warn the owner via ntfy (credo-ntfy-send.sh) and stop instead of building on unsaved work."
expect_no_text "git add: no note-and-go-on hint" "$OUT" "go on with other work"
printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL deny output is no valid JSON: $OUT"; }
# an indirect form names its op as well
OUT="$(hook $GP "eval 'git add src/a.ts'")"
expect_text "indirect git add showstopper hint" "$OUT" "git add needs the owner's OK here"
OUT="$(hook $FP "rm -f $PROJ/src/old.txt")"
expect_text "delete keeps the general hint" "$OUT" "go on with other work"
expect_no_text "delete: no git showstopper hint" "$OUT" "showstopper"
# a subagent of the run carries the same session id; another session's id is not affected
expect ask  $FP "$REPRO" "sess-2"
# no session id or an unsafe one: detection unsure, the ask stays
expect ask  $FP "$REPRO" ""
expect ask  $FP "$REPRO" "../$SID"

# --- off switch
OFF=false expect ask $FP "$REPRO"
OFF=false expect ask $GP "git add src/a.ts"
OFF=no expect ask $FP "$REPRO"

# --- paused autonomy keeps the ask
autonomy paused
expect ask $FP "$REPRO"
expect ask $GP "git add src/a.ts"

# --- detection error (state that is not the expected files) keeps the ask
autonomy broken
expect ask $FP "$REPRO"
autonomy off

# --- redirect truncation after a compound command (third peer report): exempt only inside this
# session's own TMPDIR or scratchpad, literal paths only, no link leading out
PAD="$SB/-home-u-proj/$SID/scratchpad"
expect allow $FP "cd src && for f in a.ts b.tsx; do echo \"=== \$f\"; cat -n \$f; done > $PAD/src2.txt"
expect allow $FP "for f in a b; do cat \$f; done >> $PAD/all.txt"
expect allow $FP "for f in a b; do cat \$f; done > $TB/$SID/out.txt"
expect allow $FP "{ cat a; cat b; } > $PAD/both.txt"
expect ask   $FP "for f in a b; do cat \$f; done > $SB/-home-u-proj/sess-2/scratchpad/src2.txt"
expect ask   $FP "for f in a b; do cat \$f; done > $TB/sess-2/out.txt"
expect ask   $FP "for f in a b; do cat \$f; done > $PAD/src2.txt" "sess-2"
expect ask   $FP "for f in a b; do cat \$f; done > $PAD/src2.txt" ""
expect ask   $FP "for f in a b; do cat \$f; done > \$OUT/src2.txt"
expect ask   $FP "for f in a b; do cat \$f; done > $PAD/escape/src2.txt"
expect deny  $FP "for f in a b; do cat \$f; done > $PAD/rc.txt"   # the link leads to ~/.bashrc: hard
expect ask   $FP "for f in a b; do cat \$f; done > $PAD/../../sess-2/scratchpad/x.txt"
expect ask   $FP "for f in a b; do cat \$f; done > $PAD/missing/x.txt"
expect ask   $FP "for f in a b; do cat \$f; done > $PROJ/src/out.txt"
# with autonomy active a remaining ask of this kind becomes a deny
autonomy active
expect deny  $FP "for f in a b; do cat \$f; done > \$OUT/src2.txt"
expect allow $FP "cd src && for f in a.ts b.tsx; do echo \"=== \$f\"; cat -n \$f; done > $PAD/src2.txt"
autonomy off

echo "test-unattended-deny: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

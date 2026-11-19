#!/bin/bash
# Tests for credo-handoff-rules.py: the check of the handoff's "## Rules (temporary)" lines
# (source and until present, owner source with quote and date or "agent decision", expired
# until-dates, placeholder untils, rule-like lines in legacy sections outside the section,
# RULES.md headings listed for the compare), the exit codes, the rehydrate text for the
# SessionStart hook and the read-only guarantee. Fixtures live in a temp dir (removed on
# exit); the clock is pinned with --today, the fixture dates are invented.
# Usage: bash test-credo-handoff-rules.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/credo-handoff-rules.py"
PY="$(command -v python3 || command -v python)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-handoff-rules-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
has() { # name needle haystack
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$1" "$2" "$3" ;; esac
}
lacks() { # name needle haystack
    case "$3" in *"$2"*) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  unexpected: %s\n' "$1" "$2" ;; *) PASS=$((PASS + 1)) ;; esac
}
run() { "$PY" "$SUT" "$@" --today 2021-06-01; }

mkdir -p "$TMP/.credo/process/handoffs"
H="$TMP/.credo/process/handoffs/HANDOFF.md"
R="$TMP/.credo/RULES.md"
cat > "$R" <<'EOF'
# credo per-repo rules

## R1 - Run the quick checks only

Owner (verbatim): "fixture"

## R2 - Decide uncritical questions yourself
EOF

# --- a clean handoff ---------------------------------------------------------------
cat > "$H" <<'EOF'
# Handoff

## Done
- item 1 built

## Rules (temporary)
- Build only acme-task first | source: owner "acme-task first, rest later" (2021-05-30) | until: acme-task is done
- At most 3 subagents | source: agent decision | until: 2021-06-02
- Keep the stage branch frozen | source: owner "freeze stage" (2021-05-31 14:00) |
  until: the release is out
EOF
out="$(run check "$H" "$R")"; rc=$?
check "clean: exit" 0 "$rc"
lacks "clean: no flag" "FLAG" "$out"
has "clean: RULES.md headings to compare" "R1 - Run the quick checks only; R2 - Decide uncritical questions yourself" "$out"

# --- bad lines -----------------------------------------------------------------------
cat > "$H" <<'EOF'
# Handoff

## Rules (temporary)
- No source at all | until: acme-task is done
- No until at all | source: agent decision
- Placeholder until | source: agent decision | until: none
- Expired | source: agent decision | until: 2021-05-31
- Owner without date | source: owner "do it" | until: tomorrow
- Owner label only | source: owner | until: the release is out
- Fine | source: agent decision | until: 2021-06-01

```
## Standing rules
- inside a code fence, ignored
```

## Standing rules (from earlier sessions)
- At most 2 subagents

## Next
- build item 2
EOF
before="$(cksum "$H" "$R")"
out="$(run check "$H" "$R")"; rc=$?
check "bad: exit" 1 "$rc"
check "read-only" "$before" "$(cksum "$H" "$R")"
has "bad: missing source" "line 4: no source:" "$out"
has "bad: missing until" "line 5: no until:" "$out"
has "bad: placeholder until" "line 6: no until:" "$out"
has "bad: expired" "line 7: expired (until 2021-05-31)" "$out"
has "bad: owner without date" "line 8: source is neither" "$out"
has "bad: owner label only" "line 9: source is neither" "$out"
lacks "bad: until today is not expired" "line 10:" "$out"
has "bad: legacy section flagged" "line 17: section \"Standing rules (from earlier sessions)\"" "$out"
lacks "bad: fenced lines ignored" "line 1[34]" "$out"
lacks "bad: Next section not flagged" "\"Next\"" "$out"
check "bad: flag count" 7 "$(printf '%s\n' "$out" | grep -c '^FLAG ')"

# --- no rules section, no RULES.md ---------------------------------------------------
printf '# Handoff\n\n## Done\n- x\n' > "$H"
out="$(run check "$H")"; rc=$?
check "none: exit" 0 "$rc"
has "none: note" "NOTE no \"## Rules (temporary)\" section" "$out"
lacks "none: no compare without RULES.md" "COMPARE" "$out"

# --- usage and unreadable file ---------------------------------------------------------
"$PY" "$SUT" check >/dev/null 2>&1; check "usage: exit" 2 "$?"
"$PY" "$SUT" check "$TMP/missing.md" >/dev/null 2>&1; check "missing file: exit" 2 "$?"

# --- rehydrate text --------------------------------------------------------------------
printf '## Rules (temporary)\n- No until | source: agent decision\n' > "$H"
out="$(run rehydrate "$H" "$R")"; rc=$?
check "rehydrate: exit" 0 "$rc"
has "rehydrate: precedence" "the owner's current words > owner rules in the handoff" "$out"
has "rehydrate: RULES.md wins on conflict" "let RULES.md win over the conflicting handoff rule" "$out"
has "rehydrate: report aloud" "report them aloud to the owner now" "$out"
has "rehydrate: flag line" "FLAG line 2: no until:" "$out"
out="$(run rehydrate "$TMP/missing.md")"; rc=$?
check "rehydrate missing handoff: exit" 0 "$rc"
has "rehydrate missing handoff: still the precedence" "Precedence:" "$out"
check "text = rehydrate prefix" "[credo] Handoff rules: $("$PY" "$SUT" text)" "$out"

printf 'passed: %s, failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

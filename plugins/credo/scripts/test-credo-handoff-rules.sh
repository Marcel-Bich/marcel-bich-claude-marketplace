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

# --- audit fixes: quotes and pipes in owner quotes, open-ended untils, sub-bullets,
# subheadings, legacy headings, ~~~ fences, invalid dates -----------------------------
cat > "$H" <<'EOF'
# Handoff

## Rules (temporary)
- Quote with quotes | source: owner "use "fast" mode, not | slow" (2021-05-30) | until: acme-task is done
- Open 1 | source: agent decision | until: further notice
- Open 2 | source: agent decision | until: bis auf Weiteres
- Open 3 | source: agent decision | until: dauerhaft
- Open 4 | source: agent decision | until: never
- Bad date | source: agent decision | until: 2021-13-40
- Bad owner date | source: owner "x" (2021-02-30) | until: box-1 is up
- Parent rule | source: agent decision | until: box-1 is up
  - a sub-bullet without fields is a detail, not a rule

### Build order
- Sub rule without until | source: agent decision

~~~
## Standing rules
- inside a tilde fence, ignored
~~~

## Work on rules skill
- not a rule collection

## Regeln
- Alte Absprache

## Next
- build item 2
EOF
out="$(run check "$H")"; rc=$?
check "audit: exit" 1 "$rc"
lacks "audit: quotes and pipes in an owner quote pass" "line 4:" "$out"
has "audit: further notice" "line 5: no real expiry (until further notice): belongs in RULES.md" "$out"
has "audit: bis auf Weiteres" "line 6: no real expiry" "$out"
has "audit: dauerhaft" "line 7: no real expiry" "$out"
has "audit: never" "line 8: no real expiry" "$out"
has "audit: invalid until date" "line 9: until date 2021-13-40 is not a valid date" "$out"
has "audit: invalid source date" "line 10: source date 2021-02-30 is not a valid date" "$out"
lacks "audit: sub-bullet is no rule" "line 12:" "$out"
lacks "audit: parent with sub-bullet passes" "line 11:" "$out"
has "audit: subheading stays in the section" "line 15: no until:" "$out"
lacks "audit: tilde fence ignored" "line 18" "$out"
lacks "audit: no false legacy hit" "Work on rules skill" "$out"
has "audit: German legacy heading" "section \"Regeln\"" "$out"
check "audit: flag count" 8 "$(printf '%s\n' "$out" | grep -c '^FLAG ')"
"$PY" "$SUT" check "$H" --today >/dev/null 2>&1; check "audit: --today without value" 2 "$?"
"$PY" "$SUT" check "$H" --today 2021-02-30 >/dev/null 2>&1; check "audit: --today invalid" 2 "$?"

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
has "rehydrate: valid owner rule beats RULES.md" "a valid owner rule from the handoff (owner quote with date, until not yet reached) beats RULES.md while it lasts" "$out"
has "rehydrate: RULES.md beats agent and invalid rules" "RULES.md wins over agent decisions and over invalid handoff rules (missing or invalid source or until, expired)" "$out"
lacks "rehydrate: old conflict wording gone" "until the owner settles it" "$out"
has "rehydrate: report aloud" "report them aloud to the owner now" "$out"
has "rehydrate: flag line" "FLAG line 2: no until:" "$out"
out="$(run rehydrate "$TMP/missing.md")"; rc=$?
check "rehydrate missing handoff: exit" 0 "$rc"
has "rehydrate missing handoff: still the precedence" "Precedence:" "$out"
check "text = rehydrate prefix" "[credo] Handoff rules: $("$PY" "$SUT" text)" "$out"

printf 'passed: %s, failed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

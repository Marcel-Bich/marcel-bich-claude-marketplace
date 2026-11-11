#!/bin/bash
# Tests for the "??" (medium) and "?" (short) explain shorthands and for the rule that text
# written right before an Ask call stays visible (credo item 127) and the suffix rule (credo
# item 133). Covers the SessionStart legend, templates/shorthands.json, the explain skill and
# command, the active and passive session skills, the band hint list, the docs and the
# changelog fragment. The model reads the shorthands from the legend and the skill text (no
# script parses chat messages), so these are text checks. Temp config dir only.
# Usage: bash test-credo-explain-shorthands.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/credo-session-start.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/credo-explain-sh.XXXXXX")" || exit 1
trap 'case "$TMP" in "${TMPDIR:-/tmp}"/credo-explain-sh.??????) rm -rf -- "$TMP" ;; esac' EXIT

PASS=0
FAIL=0
has() { # name needle text
    case "$3" in *"$2"*) PASS=$((PASS + 1)) ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n' "$1" "$2" ;; esac
}
in_file() { # name needle file
    if grep -qF -- "$2" "$3" 2>/dev/null; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$1" "$2" "${3#"$REPO_DIR"/}"; fi
}

# --- SessionStart legend (emitted in every state) ---------------------------
export CLAUDE_CONFIG_DIR="$TMP/cfg" CREDO_GLOBAL="$TMP/global.yaml" CREDO_PROFILE="$TMP/none-profile" \
    CREDO_PROJECT="$TMP/none-project" CREDO_SKIP_ENSURE=1 CREDO_TMUX_HINT=false
mkdir -p "$CLAUDE_CONFIG_DIR"
: > "$CREDO_GLOBAL"
LEGEND="$(printf '{"session_id":"%s","source":"startup","cwd":"%s"}' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeee0127" "$TMP" \
    | (cd "$TMP" && bash "$HOOK" 2>/dev/null) | jq -r '.hookSpecificOutput.additionalContext // ""')"
has "legend: emitted" "USER SHORTHANDS" "$LEGEND"
has "legend: ??? alone or at the end of a message" '"???" (alone, or at the end of any message' "$LEGEND"
has "legend: ?? defined" '"??" (alone, or at the end of any message' "$LEGEND"
has "legend: ?? is medium, about 66 percent" 'medium depth: the four labeled parts, each short, about 66 percent of the "???" length' "$LEGEND"
has "legend: ? defined" '"?" (alone, or at the end of any message' "$LEGEND"
has "legend: ? is two or three bullets, about 33 percent" 'two or three bullets, about 33 percent of the "???" length' "$LEGEND"
has "legend: markers inside a message" 'each "?", "??" or "???" applies to the part right before it' "$LEGEND"
has "legend: the longest ending wins" 'The longest ending wins ("???" before "??" before "?")' "$LEGEND"
has "legend: normal question ending with ? gets the short format" 'A normal question ending with "?" (e.g. "is xyz so bad?") gets the "?" depth and format' "$LEGEND"
has "legend: clean structure at every level" 'never crammed into a single line' "$LEGEND"
has "legend: text before Ask stays visible (buffer)" 'first write that text, then make one separate Bash call whose ENTIRE command is `echo ok`' "$LEGEND"
has "legend: Ask buffer reason" 'hides the text behind the Ask dialog' "$LEGEND"

# --- templates/shorthands.json (band cheatsheet) ----------------------------
SH="$PLUGIN_DIR/templates/shorthands.json"
for k in '???' '??' '?'; do
    if jq -e --arg k "$k" 'any(.[]; .key == $k and (.meaning | length) > 0)' "$SH" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); printf 'FAIL shorthands.json: key %s missing\n' "$k"
    fi
done

# --- explain skill and command ----------------------------------------------
EXPLAIN="$PLUGIN_DIR/skills/explain/SKILL.md"
in_file "explain skill: ?? level" '"??" (medium' "$EXPLAIN"
in_file "explain skill: ? level" '"?" (short' "$EXPLAIN"
in_file "explain skill: medium length" 'about 66 percent' "$EXPLAIN"
in_file "explain skill: short length" 'about 33 percent' "$EXPLAIN"
in_file "explain skill: short is bullets" 'two or three bullets' "$EXPLAIN"
in_file "explain skill: suffix at the end of any message" 'at the end of any message' "$EXPLAIN"
in_file "explain skill: markers inside a message" 'applies to the part right before it' "$EXPLAIN"
in_file "explain skill: normal question ending with ? gets the short format" 'A normal question ending with `?`' "$EXPLAIN"
in_file "explain skill: clean structure rule" 'never crammed' "$EXPLAIN"
in_file "explain command: level argument" 'name: level' "$PLUGIN_DIR/commands/explain.md"
in_file "explain command: medium and short levels" 'medium' "$PLUGIN_DIR/commands/explain.md"

# --- session skills: text before an Ask call -------------------------------
for s in session-active session-passive; do
    in_file "$s: buffer rule" 'whose ENTIRE command is `echo ok`' "$PLUGIN_DIR/skills/$s/SKILL.md"
    in_file "$s: buffer reason" 'hides the text behind the Ask dialog' "$PLUGIN_DIR/skills/$s/SKILL.md"
done

# --- band hint list, docs, changelog fragment -------------------------------
in_file "band: hint lists ?? and ?" "GENERAL_SHORTHANDS = ['???', '??', '?', 'cm', 'ph']" "$PLUGIN_DIR/hooks/band.tsx"
in_file "README: ?? row" '| `??` |' "$PLUGIN_DIR/README.md"
in_file "README: ? row" '| `?` |' "$PLUGIN_DIR/README.md"
in_file "credo guide: ?? bullet" '- `??` -' "$PLUGIN_DIR/docs/credo-guide.md"
in_file "credo guide: ? bullet" '- `?` -' "$PLUGIN_DIR/docs/credo-guide.md"
in_file "psalm: ?? topic line" '`??` - ' "$PLUGIN_DIR/commands/psalm.md"
in_file "psalm: ? topic line" '`?` - ' "$PLUGIN_DIR/commands/psalm.md"
in_file "changelog: released shorthand entry" 'applies to the part right before it' "$PLUGIN_DIR/CHANGELOG.md"

# Ask rules survive a cut session-start context (credo item #178): they lead the context and
# come back on every prompt in the modes that may ask
has "session start: the context starts with the Ask rules" '[credo-ask]' "$(printf '%s' "$LEGEND" | head -c 11)"
has "session start: Ask rules name echo ok" 'whose ENTIRE command is `echo ok`' "$(printf '%s' "$LEGEND" | head -c 600)"
has "session start: Ask rules name the question code" 'credo-code-next.sh Q' "$(printf '%s' "$LEGEND" | head -c 600)"
INJ="$PLUGIN_DIR/hooks/session-mode-inject.sh"
mkdir -p "$TMP/modes"
none_ctx="$(printf '{"session_id":"s-none"}' | CREDO_SESSION_MODES_DIR="$TMP/modes" bash "$INJ" | jq -r '.hookSpecificOutput.additionalContext // ""')"
has "prompt, no mode: Ask rules" '[credo-ask]' "$none_ctx"
printf 'active\n' > "$TMP/modes/s-act"
act_ctx="$(printf '{"session_id":"s-act"}' | CREDO_SESSION_MODES_DIR="$TMP/modes" bash "$INJ" | jq -r '.hookSpecificOutput.additionalContext // ""')"
has "prompt, active: Ask rules" '[credo-ask]' "$act_ctx"
printf 'passive\n' > "$TMP/modes/s-pas"
pas_ctx="$(printf '{"session_id":"s-pas"}' | CREDO_SESSION_MODES_DIR="$TMP/modes" bash "$INJ" | jq -r '.hookSpecificOutput.additionalContext // ""')"
has "prompt, passive: Ask rules" '[credo-ask]' "$pas_ctx"
printf 'autonomous\n' > "$TMP/modes/s-aut"
aut_ctx="$(printf '{"session_id":"s-aut"}' | CREDO_SESSION_MODES_DIR="$TMP/modes" CLAUDE_CONFIG_DIR="$TMP/cfg" bash "$INJ" | jq -r '.hookSpecificOutput.additionalContext // ""')"
if printf '%s' "$aut_ctx" | grep -qF '[credo-ask]'; then FAIL=$((FAIL + 1)); echo "FAIL prompt, autonomous: no Ask rules (it never asks)"; else PASS=$((PASS + 1)); fi

echo "explain shorthands: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

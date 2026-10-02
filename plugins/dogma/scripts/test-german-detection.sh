#!/bin/bash
# Test script for lib-german.sh and the German-only language rules in
# write-edit-reminder.sh (German file -> "Keep it in German") and
# post-write-validate.sh (ASCII umlauts like "fuer" in German text).
# German rules must fire on German text only and stay silent for other languages.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-german.sh
. "$SCRIPT_DIR/lib-german.sh"

TESTS_PASSED=0
TESTS_FAILED=0

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dogma-test-german-XXXXXX")"
cleanup() {
    rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "FAIL: $1"; }

expect_german() {
    if is_german_text "$2"; then pass; else fail "$1 (expected German)"; fi
}
expect_not_german() {
    if is_german_text "$2"; then fail "$1 (expected not German)"; else pass; fi
}

# --- lib-german.sh ---
DE='Diese Funktion ist nicht fertig, aber sie wird noch erweitert und kann auch mehr.'
DE_ASCII='Das ist fuer den Benutzer und wird ueber die API geladen.'
EN='This function is not finished yet, but it will be extended and can do more.'
FR='Cette fonction est presque terminée, mais elle sera étendue et pourra faire plus.'
ES='Esta función no está terminada, pero se ampliará y podrá hacer más cosas.'
NL='Deze functie is nog niet klaar, maar die wordt later uitgebreid en kan meer.'
PT='Os dados das tabelas e das listas estão prontos para uso.'
EN_QUOTE='The German word "und" means "and"; the rest of this text is English.'

expect_german 'German prose' "$DE"
expect_german 'German prose with ASCII umlauts' "$DE_ASCII"
expect_not_german 'English prose' "$EN"
expect_not_german 'French prose' "$FR"
expect_not_german 'Spanish prose' "$ES"
expect_not_german 'Dutch prose' "$NL"
expect_not_german 'Portuguese prose (das)' "$PT"
expect_not_german 'English with one German quote' "$EN_QUOTE"
expect_not_german 'empty text' ''
expect_not_german 'substring only (dieser inside a word)' 'undocumented derived disturbance'

# English skill text that quotes German trigger examples (quotes may span lines)
EN_DE_QUOTES='description: Use when the user assigns this role to you, in any language, for
  example "you are (now) the plan agent", "act as the plan agent", or German "du bist (jetzt) der
  plan/clarify agent", "übernimm das Klären / die clarify-items", "wechsel in die plan
  rolle". Do NOT use for general talk about roles, or questions like "what does the plan agent do".
  It writes a persistent default role for this session and is cleared with the clear command.'
# English doc with a German code span and a German fenced code block
EN_DE_CODE='This hook prints a note for the file. The message text is `Das ist nicht fertig und wird noch gebaut`.
```bash
# Das ist ein Kommentar, der nicht übersetzt wird und auch so bleibt
echo "Hier ist das Ergebnis"
```
The rest of this file is English and it should stay that way for the reader.'
# German prose that quotes English and uses English loanwords
DE_EN_QUOTES='Der Hook prüft die Datei und meldet "This file is in English" nur dann, wenn das Commit-Log
nicht leer ist. Das Feature ist noch nicht fertig, aber es wird bald im Release enthalten sein.'
# Bilingual document (German half, English half)
BILINGUAL='# Beitragen / Contributing

## Deutsch

Mit der Einreichung von Inhalten an dieses Repository räumen Sie dem Projektinhaber eine Lizenz ein.
Pull Requests sind willkommen, werden jedoch nicht automatisch zusammengeführt. Der Projektinhaber
ist nicht verpflichtet, Einreichungen zu prüfen oder darauf zu antworten.

## English

By submitting any content to this repository you grant the project owner a license.
Pull requests are welcome, but they are not merged automatically. The owner is not obliged
to review submissions or to respond to them, and this is not a judgement of their quality.'

expect_not_german 'English with multi-line German quotes (role-plan style)' "$EN_DE_QUOTES"
expect_not_german 'English with German code span and code block' "$EN_DE_CODE"
expect_german 'German prose quoting English' "$DE_EN_QUOTES"
expect_not_german 'bilingual doc is not German' "$BILINGUAL"
lang="$(detect_text_language "$BILINGUAL")"
[ "$lang" = "mixed" ] && pass || fail "bilingual doc detected as '$lang' (expected mixed)"
lang="$(detect_text_language "$EN")"
[ "$lang" = "en" ] && pass || fail "English prose detected as '$lang' (expected en)"
lang="$(detect_text_language "$DE")"
[ "$lang" = "de" ] && pass || fail "German prose detected as '$lang' (expected de)"

# --- write-edit-reminder.sh: language note ---
WORK="$TEST_TMP_DIR/repo"
mkdir -p "$WORK/CLAUDE"
echo "# rules" > "$WORK/CLAUDE/CLAUDE.language.md"

reminder_for() {
    local file="$1"
    (cd "$WORK" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$file" \
        | CLAUDE_MB_DOGMA_ENABLED=true CLAUDE_MB_DOGMA_WRITE_EDIT_REMINDER=true bash "$SCRIPT_DIR/write-edit-reminder.sh")
}

printf '%s\n%s\n' "$DE" "In der Datei ist es so." > "$WORK/de.md"
printf '%s\n' "$EN" > "$WORK/en.md"
printf '%s\n' "$FR" > "$WORK/fr.md"

out="$(reminder_for "$WORK/de.md")"
case "$out" in *"Keep it in German"*) pass ;; *) fail "reminder: German file not detected" ;; esac
case "$out" in *"Keep it in English"*) fail "reminder: German file reported as English" ;; *) pass ;; esac

out="$(reminder_for "$WORK/en.md")"
case "$out" in *"Keep it in German"*) fail "reminder: English file reported as German" ;; *) pass ;; esac
case "$out" in *"Keep it in English"*) pass ;; *) fail "reminder: English file not detected" ;; esac

out="$(reminder_for "$WORK/fr.md")"
case "$out" in *"Keep it in German"*) fail "reminder: French file reported as German" ;; *) pass ;; esac

printf '%s\n' "$EN_DE_QUOTES" > "$WORK/en-quotes.md"
printf '%s\n' "$BILINGUAL" > "$WORK/bilingual.md"
printf '%s\n' "$DE_EN_QUOTES" > "$WORK/de-quotes.md"

out="$(reminder_for "$WORK/en-quotes.md")"
case "$out" in *"Keep it in German"*) fail "reminder: English file with German quotes reported as German" ;; *) pass ;; esac
case "$out" in *"Keep it in English"*) pass ;; *) fail "reminder: English file with German quotes not detected as English" ;; esac

out="$(reminder_for "$WORK/bilingual.md")"
case "$out" in *"Keep it in German"*|*"Keep it in English"*) fail "reminder: bilingual file got a single-language note" ;; *) pass ;; esac

out="$(reminder_for "$WORK/de-quotes.md")"
case "$out" in *"Keep it in German"*) pass ;; *) fail "reminder: German file quoting English not detected" ;; esac

# --- post-write-validate.sh: ASCII umlaut check ---
validate() {
    local file="$1" tool="$2" text="$3"
    local key="content"
    [ "$tool" = "Edit" ] && key="new_string"
    jq -n --arg t "$tool" --arg f "$file" --arg k "$key" --arg c "$text" \
        '{tool_name:$t, tool_input:({file_path:$f} + {($k):$c})}' \
        | CLAUDE_MB_DOGMA_ENABLED=true CLAUDE_MB_DOGMA_POST_WRITE_VALIDATE=true bash "$SCRIPT_DIR/post-write-validate.sh"
}

out="$(validate "$WORK/new-de.md" Write "$DE_ASCII")"
case "$out" in *"ASCII instead of umlauts"*) pass ;; *) fail "validate: German text with fuer not flagged" ;; esac

out="$(validate "$WORK/new-en.md" Write 'The rule rejects fuer and koennen in German text; this file is English.')"
case "$out" in *"ASCII instead of umlauts"*) fail "validate: English doc quoting fuer was flagged" ;; *) pass ;; esac

out="$(validate "$WORK/new-fr.md" Write "$FR")"
case "$out" in *"ASCII instead of umlauts"*) fail "validate: French text flagged" ;; *) pass ;; esac

# short Edit snippet in a German file: language comes from the file on disk
out="$(validate "$WORK/de.md" Edit 'Hinweis fuer alle')"
case "$out" in *"ASCII instead of umlauts"*) pass ;; *) fail "validate: Edit snippet in German file not flagged" ;; esac

# same snippet in an English file stays silent
out="$(validate "$WORK/en.md" Edit 'see fuer')"
case "$out" in *"ASCII instead of umlauts"*) fail "validate: Edit snippet in English file flagged" ;; *) pass ;; esac

# English doc quoting a German sentence with "fuer" is not flagged
out="$(validate "$WORK/new-en2.md" Write "$EN_DE_QUOTES
The old hook rejected \"Das ist fuer den Benutzer und wird noch geladen\" in this text.")"
case "$out" in *"ASCII instead of umlauts"*) fail "validate: English doc quoting German fuer sentence was flagged" ;; *) pass ;; esac

echo ""
echo "passed: $TESTS_PASSED, failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]

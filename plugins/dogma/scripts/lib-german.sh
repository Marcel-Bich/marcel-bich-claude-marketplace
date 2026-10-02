#!/bin/bash
# Dogma: shared German-text detection for the language hooks.
#
# German-specific rules (umlaut checks, "keep it in German") must only fire on German
# text and do nothing for any other language. This is a conservative heuristic, not a
# real language identifier:
#
# 1. Quoted and code material is removed first: fenced code blocks, `code spans`,
#    "double", 'single' and typographic quotes. An English doc that quotes German
#    examples is judged by its own prose, not by the quotes.
# 2. German and English function words are counted as whole words. The German list
#    leaves out words that are common in English or other languages (die, was, will,
#    man, also, in, mit, wie, als); the English list leaves out words that are also
#    German (in, was, will, an, so).
# 3. A language counts as present when its function words make up a meaningful share
#    of all words (LANG_MIN_SHARE percent; for German also GERMAN_MIN_HITS distinct
#    words). When both are present, one must dominate by LANG_DOMINANCE times,
#    otherwise the text is "mixed" (bilingual) and callers give no language note.
#
# Usage: source this file, then
#   detect_text_language "$TEXT"   -> prints de | en | mixed | none
#   is_german_text "$TEXT"         -> exit 0 only when the result is de

GERMAN_MIN_HITS=3
LANG_MIN_SHARE=8
LANG_DOMINANCE=3
GERMAN_WORDS='der|das|und|ist|nicht|eine|einen|wird|werden|haben|auch|nach|oder|durch|noch|keine|kein|muss|sind|aber|wenn|dass|denn|sich|auf|ein|zu|nur|hier|jetzt|schon|immer|fuer|für|ueber|über|koennen|können|muessen|müssen|wurde|wuerde|würde|bitte|diese|dieser|dieses'
ENGLISH_WORDS='the|and|is|to|of|that|for|it|with|on|this|you|have|are|be|but|from|can|not|or|by|at|which|if|when|should|must|only|there|they|would|does|been|has'

# Remove fenced code blocks, code spans and quoted strings (bounded length, so a
# stray quote cannot swallow the whole text).
_lang_strip_quoted() {
    printf '%s\n' "$1" \
        | awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next } !fence { print }' \
        | tr '\n' ' ' \
        | sed -E \
            -e 's/`[^`]{0,300}`/ /g' \
            -e 's/"[^"]{0,300}"/ /g' \
            -e 's/„[^“”]{0,300}[“”]/ /g' \
            -e 's/“[^”]{0,300}”/ /g' \
            -e 's/«[^»]{0,300}»/ /g' \
            -e "s/(^|[^[:alnum:]])'[^']{0,300}'/\\1 /g"
}

_lang_count() {
    # $1 = text, $2 = word regex; prints "<total> <distinct>"
    printf '%s' "$1" | grep -oiwE "$2" 2>/dev/null | tr '[:upper:]' '[:lower:]' \
        | awk '{ n++; seen[$0] = 1 } END { d = 0; for (k in seen) d++; print n + 0, d }'
}

detect_text_language() {
    local text words g gd e ed g_ok=false e_ok=false
    [ -z "$1" ] && { echo none; return; }
    text="$(_lang_strip_quoted "$1")"
    words=$(printf '%s' "$text" | tr -s '[:space:]' '\n' | grep -c '[[:alpha:]]')
    [ "${words:-0}" -eq 0 ] && { echo none; return; }
    read -r g gd < <(_lang_count "$text" "$GERMAN_WORDS")
    read -r e ed < <(_lang_count "$text" "$ENGLISH_WORDS")
    if [ "$gd" -ge "$GERMAN_MIN_HITS" ] && [ $((g * 100)) -ge $((words * LANG_MIN_SHARE)) ]; then
        g_ok=true
    fi
    if [ "$ed" -ge 2 ] && [ $((e * 100)) -ge $((words * LANG_MIN_SHARE)) ]; then
        e_ok=true
    fi
    if $g_ok && $e_ok; then
        if [ "$g" -ge $((e * LANG_DOMINANCE)) ]; then echo de
        elif [ "$e" -ge $((g * LANG_DOMINANCE)) ]; then echo en
        else echo mixed
        fi
    elif $g_ok; then
        echo de
    elif $e_ok; then
        echo en
    else
        echo none
    fi
}

is_german_text() {
    [ "$(detect_text_language "$1")" = "de" ]
}

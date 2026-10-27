#!/usr/bin/env bash
# Tests for hooks/letters.ts (open test/question footer parsing of credo's band).
# Needs bun (runs the TypeScript directly); skipped when it is missing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v bun >/dev/null 2>&1; then
    echo "SKIP: bun not installed"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/t.ts" <<EOF
import { parseLetters } from '$HERE/../hooks/letters'

let pass = 0
let fail = 0
const eq = (name: string, got: unknown, want: unknown) => {
  if (JSON.stringify(got) === JSON.stringify(want)) pass++
  else {
    fail++
    console.log('FAIL ' + name + '\n  want: ' + JSON.stringify(want) + '\n  got:  ' + JSON.stringify(got))
  }
}
const t = (s: string) => parseLetters(s).tests
const q = (s: string) => parseLetters(s).questions

eq('english footer', parseLetters('done.\n\n**Open for testing: C, D** · **Open questions: Y**'),
  { tests: ['C', 'D'], questions: ['Y'], vetos: [] })
eq('german footer', parseLetters('**Offen zum Testen:** B'), { tests: ['B'], questions: [], vetos: [] })
eq('hyphen codes + dash separator', parseLetters('Offen zum Testen: Task-I, Task-K - Offene Fragen: keine'),
  { tests: ['Task-I', 'Task-K'], questions: [], vetos: [] })
eq('lowercase and space separated', t('Open for testing: Qb-2 h2 IJ3'), ['Qb-2', 'h2', 'IJ3'])
eq('none / keine / dash', parseLetters('Open for testing: none · Open questions: -'), { tests: [], questions: [], vetos: [] })
eq('item refs in list', q('**Open questions: #177, #113, Y**'), ['#177', '#113', 'Y'])
eq('item refs in prose', q('Offene Fragen: Restliche Hinweise in owner-questions.md (#177, #113, #101, #190, #61, #53)'),
  ['#177', '#113', '#101', '#190', '#61', '#53'])
eq('backticked refs', q('Open questions: \`#12\`, \`#7\`'), ['#12', '#7'])
eq('prose keeps uppercase letter codes', t('Offen zum Testen: B (Band-Test) und C'), ['B', 'C'])
eq('prose without codes', q('Offene Fragen: keine weiteren offenen Punkte'), [])
eq('cct refs', t('Open for testing: §cct_2, D'), ['§cct_2', 'D'])
eq('last footer wins', t('Open for testing: A\n\nlater...\n\n**Open for testing: E**'), ['E'])
eq('dedupe', q('Open questions: #5, #5, Y'), ['#5', 'Y'])
eq('open tests label variant', t('**Offene Tests: #218, B**'), ['#218', 'B'])
eq('open tests label variant (english)', t('**Open tests: #218, B**'), ['#218', 'B'])
// language-neutral emoji footer (canonical)
eq('emoji footer', parseLetters('done.\n\n**🧪: C, D** · **❓: Y, #177**'),
  { tests: ['C', 'D'], questions: ['Y', '#177'], vetos: [] })
eq('emoji footer without bold', parseLetters('🧪: B2, C · ❓: Z'), { tests: ['B2', 'C'], questions: ['Z'], vetos: [] })
eq('emoji with variation selector', parseLetters('**🧪\uFE0F: C** · **❓\uFE0F: Y**'), { tests: ['C'], questions: ['Y'], vetos: [] })
eq('emoji space before colon', parseLetters('**🧪 : C** · **❓ : Y**'), { tests: ['C'], questions: ['Y'], vetos: [] })
eq('emoji bold closed before colon', parseLetters('**🧪**: C · **❓**: Y'), { tests: ['C'], questions: ['Y'], vetos: [] })
eq('emoji bold closed after colon', parseLetters('**🧪:** C · **❓:** Y'), { tests: ['C'], questions: ['Y'], vetos: [] })
eq('emoji tests only', parseLetters('**🧪: E**'), { tests: ['E'], questions: [], vetos: [] })
eq('emoji questions only, last line, trailing newline', parseLetters('x\n**❓: P, S, T**\n'), { tests: [], questions: ['P', 'S', 'T'], vetos: [] })
eq('emoji headings are not a footer', parseLetters('### 🧪 B) Band test\n1. open it\n### ❓ Y) Which rank: A or B?'),
  { tests: [], questions: [], vetos: [] })
eq('emoji footer after headings', parseLetters('### 🧪 B) Band: x\n### ❓ Y) Rank: Q?\n\n**🧪: B** · **❓: Y**'),
  { tests: ['B'], questions: ['Y'], vetos: [] })
eq('emoji footer in a russian reply', parseLetters('Готово. Проверьте, пожалуйста.\n\n**🧪: C** · **❓: Y**'),
  { tests: ['C'], questions: ['Y'], vetos: [] })
eq('emoji footer wins over earlier legacy label', t('Open for testing: A\n\n**🧪: E**'), ['E'])
eq('legacy label wins over earlier emoji footer', t('🧪: A\n\nOffen zum Testen: E'), ['E'])
eq('emoji none', parseLetters('🧪: - · ❓: none'), { tests: [], questions: [], vetos: [] })
eq('emoji footer with cct ref and hyphen code', t('**🧪: §cct_2, Task-I**'), ['§cct_2', 'Task-I'])
eq('emoji fullwidth colon (CJK input)', parseLetters('**🧪：C** · **❓：Y**'), { tests: ['C'], questions: ['Y'], vetos: [] })
eq('emoji no spaces', t('🧪:C,D'), ['C', 'D'])
eq('emoji inside a quote line with CRLF', parseLetters('a\r\n> **🧪: C** · **❓: Y**\r\n'), { tests: ['C'], questions: ['Y'], vetos: [] })
eq('no footer', parseLetters('just an answer'), { tests: [], questions: [], vetos: [] })
// typed codes (T / Q / V counters) and the veto marker (U+270B)
eq('veto footer alone', parseLetters('**✋: V2, V5**'), { tests: [], questions: [], vetos: ['V2', 'V5'] })
eq('typed footer mixed with legacy letters', parseLetters('**🧪: C, T3** · **❓: Y, Q4, #177** · **✋: V2, V5**'),
  { tests: ['C', 'T3'], questions: ['Y', 'Q4', '#177'], vetos: ['V2', 'V5'] })
eq('canonical typed footer from the legend', parseLetters('**🧪: T3** · **❓: Q4, #177** · **✋: V2, V5**'),
  { tests: ['T3'], questions: ['Q4', '#177'], vetos: ['V2', 'V5'] })
eq('legacy word label with new veto footer', parseLetters('Open for testing: DX, EF · **✋: V1**'),
  { tests: ['DX', 'EF'], questions: [], vetos: ['V1'] })
eq('multi-digit typed codes', parseLetters('**🧪: T12, T103** · **❓: Q3** · **✋: V20**'),
  { tests: ['T12', 'T103'], questions: ['Q3'], vetos: ['V20'] })
eq('large counter is kept', parseLetters('**✋: V1234**'), { tests: [], questions: [], vetos: ['V1234'] })
eq('veto footer with variation selector', parseLetters('**✋️: V2**'), { tests: [], questions: [], vetos: ['V2'] })
eq('veto footer none', parseLetters('**✋: none**'), { tests: [], questions: [], vetos: [] })
eq('veto footer dedupe', parseLetters('**✋: V2, V2**').vetos, ['V2'])
eq('last veto footer wins', parseLetters('**✋: V1**\n\nlater\n\n**✋: V4**').vetos, ['V4'])
eq('german veto heading is not a footer', parseLetters('### ✋✋ V2) Veto möglich: Kept the old fixture ✋✋'),
  { tests: [], questions: [], vetos: [] })
eq('english veto heading is not a footer', parseLetters('### ✋✋ V2) Veto possible: Renamed the file ✋✋\n1. open it'),
  { tests: [], questions: [], vetos: [] })
eq('veto heading plus footer', parseLetters('### ✋✋ V2) Veto possible: Renamed the file ✋✋\n\nDone.\n\n**✋: V2**'),
  { tests: [], questions: [], vetos: ['V2'] })
eq('typed test codes in prose keep only codes', t('Offen zum Testen: T12 und T13 laufen noch'), ['T12', 'T13'])

console.log('passed: ' + pass + ', failed: ' + fail)
process.exit(fail ? 1 : 0)
EOF
bun "$TMP/t.ts"

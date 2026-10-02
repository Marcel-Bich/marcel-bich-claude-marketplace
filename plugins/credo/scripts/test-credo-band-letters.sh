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
  { tests: ['C', 'D'], questions: ['Y'] })
eq('german footer', parseLetters('**Offen zum Testen:** B'), { tests: ['B'], questions: [] })
eq('hyphen codes + dash separator', parseLetters('Offen zum Testen: Task-I, Task-K - Offene Fragen: keine'),
  { tests: ['Task-I', 'Task-K'], questions: [] })
eq('lowercase and space separated', t('Open for testing: Qb-2 h2 IJ3'), ['Qb-2', 'h2', 'IJ3'])
eq('none / keine / dash', parseLetters('Open for testing: none · Open questions: -'), { tests: [], questions: [] })
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
  { tests: ['C', 'D'], questions: ['Y', '#177'] })
eq('emoji footer without bold', parseLetters('🧪: B2, C · ❓: Z'), { tests: ['B2', 'C'], questions: ['Z'] })
eq('emoji with variation selector', parseLetters('**🧪\uFE0F: C** · **❓\uFE0F: Y**'), { tests: ['C'], questions: ['Y'] })
eq('emoji space before colon', parseLetters('**🧪 : C** · **❓ : Y**'), { tests: ['C'], questions: ['Y'] })
eq('emoji bold closed before colon', parseLetters('**🧪**: C · **❓**: Y'), { tests: ['C'], questions: ['Y'] })
eq('emoji bold closed after colon', parseLetters('**🧪:** C · **❓:** Y'), { tests: ['C'], questions: ['Y'] })
eq('emoji tests only', parseLetters('**🧪: E**'), { tests: ['E'], questions: [] })
eq('emoji questions only, last line, trailing newline', parseLetters('x\n**❓: P, S, T**\n'), { tests: [], questions: ['P', 'S', 'T'] })
eq('emoji headings are not a footer', parseLetters('### 🧪 B) Band test\n1. open it\n### ❓ Y) Which rank: A or B?'),
  { tests: [], questions: [] })
eq('emoji footer after headings', parseLetters('### 🧪 B) Band: x\n### ❓ Y) Rank: Q?\n\n**🧪: B** · **❓: Y**'),
  { tests: ['B'], questions: ['Y'] })
eq('emoji footer in a russian reply', parseLetters('Готово. Проверьте, пожалуйста.\n\n**🧪: C** · **❓: Y**'),
  { tests: ['C'], questions: ['Y'] })
eq('emoji footer wins over earlier legacy label', t('Open for testing: A\n\n**🧪: E**'), ['E'])
eq('legacy label wins over earlier emoji footer', t('🧪: A\n\nOffen zum Testen: E'), ['E'])
eq('emoji none', parseLetters('🧪: - · ❓: none'), { tests: [], questions: [] })
eq('emoji footer with cct ref and hyphen code', t('**🧪: §cct_2, Task-I**'), ['§cct_2', 'Task-I'])
eq('emoji fullwidth colon (CJK input)', parseLetters('**🧪：C** · **❓：Y**'), { tests: ['C'], questions: ['Y'] })
eq('emoji no spaces', t('🧪:C,D'), ['C', 'D'])
eq('emoji inside a quote line with CRLF', parseLetters('a\r\n> **🧪: C** · **❓: Y**\r\n'), { tests: ['C'], questions: ['Y'] })
eq('no footer', parseLetters('just an answer'), { tests: [], questions: [] })

console.log('passed: ' + pass + ', failed: ' + fail)
process.exit(fail ? 1 : 0)
EOF
bun "$TMP/t.ts"

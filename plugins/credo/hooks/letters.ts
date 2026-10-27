// Pure parser for the open-codes footer of an answer (credo verify convention).
// Canonical form is language-neutral, so the band works in any conversation language:
// "**<T>: T3, B** · **<Q>: Q4, #177** · **<V>: V2**" with <T> = U+1F9EA (tests),
// <Q> = U+2753 or U+2754 (questions) and <V> = U+270B (vetos). Bold optional, U+FE0F
// optional, space before the colon allowed. Legacy word labels are still read for older answers: English
// "Open for testing:" / "Open tests:" / "Open questions:" and German "Offen zum Testen:" /
// "Offene Tests:" / "Offene Fragen:". Vetos have no word labels (they are new, and a
// prose "Veto possible:" line must not count as a footer). No engine imports, so it can
// be checked on its own (scripts/test-credo-band-letters.sh).
//
// Defensive: a footer is often not the clean letter list the convention asks for.
// A pure code list keeps every code (letters like B, h2, Task-I, item refs #N,
// harness refs §cct_N). Prose ("Remaining notes in x.md (#177, #113)") keeps only
// item/harness refs and uppercase letter codes, so plain words never show up.

import type { CredoLetters } from '../types'

// emoji label first (canonical), then the legacy word labels
const TEST_LABELS = '\\u{1F9EA}\\uFE0F?|Open for testing|Open tests|Offen zum Testen|Offene Tests'
const QUESTION_LABELS = '[\\u{2753}\\u{2754}]\\uFE0F?|Open questions|Offene Fragen'
const VETO_LABELS = '\\u{270B}\\uFE0F?'

// a code in a pure list: #N, §cct_N, letter codes (T12, Q3, V20, legacy B, h2, IJ3) or hyphen codes (Task-I, Qb-2).
// Typed counters are monotonic, so the digits are not capped.
const LIST_CODE = /^(?:#\d+|§cct_\d+|[A-Za-z]{1,3}\d*|[A-Za-z]+-[A-Za-z0-9]{1,3})$/
// what survives inside prose: refs and uppercase letter codes only
const PROSE_CODE = /^(?:#\d+|§cct_\d+|[A-Z]{1,2}\d*|[A-Z][A-Za-z]*-[A-Za-z0-9]{1,3})$/
const NONE = /^(?:none|keine|-+|n\/a)$/i

// text after the LAST "<label>:" up to the end of the footer part. The label must be
// followed by a colon (bold may close before it), so a heading like "### <T> B) x"
// never counts as a footer. A fullwidth colon (CJK input) counts as a colon.
function segment(answer: string, labels: string): string | null {
  const re = new RegExp(`(?:${labels})(?:\\*\\*)?\\s*[:：]\\s*(?:\\*\\*)?([^\\n]*)`, 'giu')
  let last: string | null = null
  for (const m of answer.matchAll(re)) last = m[1]
  if (last === null) return null
  return last.split(/\*\*|·|\|| - /)[0]
}

function codes(seg: string | null): string[] {
  if (!seg) return []
  const tokens = seg
    .split(/[,;\s()[\]]+/)
    .map(x => x.replace(/^[*`'"]+|[*`'".:!?]+$/g, ''))
    .filter(x => x && !NONE.test(x))
  const pure = tokens.every(x => LIST_CODE.test(x))
  const kept = pure ? tokens : tokens.filter(x => PROSE_CODE.test(x))
  return [...new Set(kept)]
}

export function parseLetters(answer: string): CredoLetters {
  return {
    tests: codes(segment(answer, TEST_LABELS)),
    questions: codes(segment(answer, QUESTION_LABELS)),
    vetos: codes(segment(answer, VETO_LABELS)),
  }
}

#!/usr/bin/env bash
# Tests for restartToast in hooks/self-restart-marker.ts: ONE static toast per pending
# self-restart that stays until the restart (no per-second toasts).
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
import { restartToast } from '$HERE/../hooks/self-restart-marker'

let pass = 0
let fail = 0
const ok = (name: string, cond: boolean, info: unknown = '') => {
  if (cond) pass++
  else {
    fail++
    console.log('FAIL ' + name + ' ' + JSON.stringify(info))
  }
}

const now = new Date(2026, 9, 9, 9, 30, 0).getTime()
const at = now + 5 * 60 * 1000
const m = { sessionId: 's1', status: 'pending', reason: 'update', scheduledMs: at }

const t = restartToast(m, 's1', now)
ok('pending -> toast', t !== null, t)
ok('names the clock time, no countdown', !!t && t.text.includes('09:35:00') && !/in \d+:\d\d/.test(t.text), t)
ok('reason and cancel hint', !!t && t.text.includes('reason: update') && t.text.includes('credo-self-restart.py cancel'), t)
ok('stays past the restart', !!t && t.timeoutMs >= 5 * 60 * 1000 + 60 * 1000, t)
const later = restartToast(m, 's1', now + 1000)
ok('same key a second later (no new toast)', !!t && !!later && t.key === later.key, [t, later])
ok('new schedule -> new key', !!t && restartToast({ ...m, scheduledMs: at + 60000 }, 's1', now)!.key !== t.key)
ok('other session -> none', restartToast(m, 's2', now) === null)
ok('cancelled -> none', restartToast({ ...m, status: 'cancelled' }, 's1', now) === null)
const s = restartToast({ ...m, status: 'stopping' }, 's1', now)
ok('stopping -> toast says now', !!s && s.text.includes('now') && !s.text.includes('cancel'), s)
ok('no schedule -> pending text', (restartToast({ ...m, scheduledMs: null }, 's1', now)?.text ?? '').includes('pending'))

console.log('passed: ' + pass + ', failed: ' + fail)
process.exit(fail ? 1 : 0)
EOF
bun "$TMP/t.ts"

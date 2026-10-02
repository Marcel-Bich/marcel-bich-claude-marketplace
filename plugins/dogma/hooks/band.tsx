// dogma band: an optional Claude Code mod that shows the restricting
// DOGMA-PERMISSIONS.md entries above the prompt (below credo's band, when
// that is installed) and flashes the last dogma block. It only READS state
// through scripts/permissions-summary.sh and renders it; dogma's hooks stay
// the only enforcer and work the same without this band.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'

import type { DogmaBlock, DogmaGone, DogmaSummary } from '../types'

// credo's band preset, read without depending on credo: dogma declares only
// this one value of credo's state here (not in its own contract). Without
// credo installed nothing ever writes it, the read answers the default 0
// ('all') and the dogma band always shows.
declare module 'claude-code' {
  interface PluginState {
    credo: { preset: number }
  }
}

const HEAD = '◆ dogma'
const GAP = 2
const HEAD_GAP = 2

const summary = atom({ plugin: 'dogma', key: 'summary' } as const, null)
const moved = atom({ plugin: 'dogma', key: 'moved' } as const, [])
const fresh = atom({ plugin: 'dogma', key: 'fresh' } as const, [])
const gone = atom({ plugin: 'dogma', key: 'gone' } as const, [])
const blink = atom({ plugin: 'dogma', key: 'blink' } as const, false)
const block = atom({ plugin: 'dogma', key: 'block' } as const, null)
// credo's preset stage 3 ("open only") hides the dogma band
const credoPreset = atom({ plugin: 'credo', key: 'preset' } as const, 0)
const HIDDEN_AT_STAGE = 3
const PRESET_COUNT = 4

const HIGHLIGHT = '#d946ef'
const NEW_COLOR = 'whiteBright'
const HIGHLIGHT_MS = 6000
const BLINK_MS = 500
const BLOCK_MS = 15000
const BLOCK_BLINK_MS = 6000
const REFRESH_MS = 10000
const NOTICE_TOAST_MS = 12000
// no dogma toast is shorter than this (the toast default is 4 s)
const TOAST_MIN_MS = 6000

type Piece = { width: number; node: RenderChildren; gap?: number }

// greedy line packing: each piece stays whole, a line never exceeds columns
function pack(pieces: Piece[], columns: number, gap: number): Piece[][] {
  let line: Piece[] = []
  const lines: Piece[][] = [line]
  let used = 0
  for (const p of pieces) {
    const need = (line.length ? (p.gap ?? gap) : 0) + p.width
    if (line.length && used + need > columns) {
      line = [p]
      lines.push(line)
      used = p.width
    } else {
      line.push(p)
      used += need
    }
  }
  return lines
}

// summary of the session's cwd; exit 4 (no DOGMA-PERMISSIONS.md) or any failure hides the band
async function refresh($: EngineInterface) {
  // exit 4 (no DOGMA-PERMISSIONS.md) hides the band; any other failure (a timeout
  // under load) keeps the last known value and logs the reason to the debug log
  let next: DogmaSummary | null = null
  try {
    const r = await $.process.run([`${$.plugin.root}/scripts/permissions-summary.sh`, '--json'], { timeoutMs: 5000 })
    if (r.exitCode !== 0 && r.exitCode !== 4) {
      $.ui.log(`dogma band: permissions-summary.sh exit ${r.exitCode}: ${r.stderr.trim()}`, { to: 'debug' })
      return
    }
    next = r.exitCode === 0 ? JSON.parse(r.stdout) : null
  } catch (err) {
    $.ui.log(`dogma band: permissions-summary.sh failed: ${String(err)}`, { to: 'debug' })
    return
  }
  const prev = await read($, summary)
  await update($, summary, () => next)
  if (prev === null || next === null) return

  // exact per-entry diff: kind switch = moved, newly restricted = fresh, dropped = gone
  const kindOf = (s: DogmaSummary, label: string) =>
    s.deny.includes(label) ? 'deny' : s.ask.includes(label) ? 'ask' : null
  const before = [...prev.deny, ...prev.ask]
  const after = [...next.deny, ...next.ask]
  const movedNow = after.filter(l => before.includes(l) && kindOf(prev, l) !== kindOf(next, l))
  const freshNow = after.filter(l => !before.includes(l))
  const goneNow: DogmaGone[] = before
    .filter(l => !after.includes(l))
    .map(l => ({ kind: kindOf(prev, l) === 'deny' ? 'deny' : 'ask', label: l }))
  if (!movedNow.length && !freshNow.length && !goneNow.length) return

  await update($, moved, () => movedNow)
  await update($, fresh, () => freshNow)
  await update($, gone, () => goneNow)
  for (let t = 0; t < HIGHLIGHT_MS; t += BLINK_MS) {
    await update($, blink, v => !v)
    await $.clock.sleep(BLINK_MS)
  }
  await update($, blink, () => false)
  await update($, moved, () => [])
  await update($, fresh, () => [])
  await update($, gone, () => [])
}

// one toast at session start when update notices are pending for this repo, plugin
// notices and dogma source broadcasts together; Claude asks about them (SessionStart
// hook notices-inject.sh), this only hints.
// exit 4 = none pending; any other failure only goes to the debug log
async function noticeToast($: EngineInterface) {
  try {
    const r = await $.process.run([`${$.plugin.root}/scripts/notices-pending.sh`, '--json'], { timeoutMs: 5000 })
    if (r.exitCode === 4) return
    if (r.exitCode !== 0) {
      $.ui.log(`dogma band: notices-pending.sh exit ${r.exitCode}: ${r.stderr.trim()}`, { to: 'debug' })
      return
    }
    const n = (JSON.parse(r.stdout) as { notices?: unknown[] }).notices?.length ?? 0
    if (n > 0) $.ui.toast(`dogma: ${n} update notice${n === 1 ? '' : 's'} - Claude will ask you`, { timeoutMs: NOTICE_TOAST_MS })
  } catch (err) {
    $.ui.log(`dogma band: notices-pending.sh failed: ${String(err)}`, { to: 'debug' })
  }
}

// show the last dogma block for a few seconds, blinking, plus a toast
async function showBlock($: EngineInterface, b: DogmaBlock) {
  $.ui.toast(`dogma blocked ${b.tool}: ${b.reason}`, { timeoutMs: TOAST_MIN_MS })
  // stamped, so the render hides it after BLOCK_MS even if this timer never finishes
  // (plugin reload mid-sleep) and a stale stored block never sticks
  const at = await $.clock.now()
  await update($, block, () => ({ ...b, at }))
  // blink for the first BLOCK_BLINK_MS, then stay steady red until BLOCK_MS
  for (let t = 0; t < BLOCK_BLINK_MS; t += BLINK_MS) {
    await update($, blink, v => !v)
    await $.clock.sleep(BLINK_MS)
  }
  await update($, blink, () => false)
  await $.clock.sleep(BLOCK_MS - BLOCK_BLINK_MS)
  await update($, block, () => null)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await update($, block, () => null)
    await refresh($)
    $.clock.every(REFRESH_MS, () => void refresh($))
    void noticeToast($)
    return started
  })

  // any tool may have edited DOGMA-PERMISSIONS.md
  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    void refresh($)
    // a dogma PreToolUse deny reaches us as a refused or errored result whose
    // text carries "BLOCKED" / "BLOCKED by dogma"; dogma decided, we only show it.
    // A successful tool output that merely contains the word is ignored.
    const text =
      typeof result.deny === 'string' ? result.deny : result.isError === true && typeof result.text === 'string' ? result.text : ''
    const m = text.match(/BLOCKED(?: by dogma)?:\s*(.+)/)
    if (m?.[1]) void showBlock($, { tool: String(e.tool), reason: m[1].split(/(?<=\.)\s/)[0] ?? m[1] })
    return result
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    void refresh($)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    const s = await read($, summary)
    if (e.props.hasSurvey || s === null) return below
    if ((await read($, credoPreset)) % PRESET_COUNT === HIDDEN_AT_STAGE) return below

    const { Box, Text } = $.ui.resolve(e)
    const restricted = s.ask.length + s.deny.length > 0
    const isOn = await read($, blink)
    const movedNow = isOn ? await read($, moved) : []
    const freshNow = isOn ? await read($, fresh) : []
    const goneNow = await read($, gone)
    const tint = (label: string, color: string) =>
      movedNow.includes(label) ? HIGHLIGHT : freshNow.includes(label) ? NEW_COLOR : color

    const headColor = s.deny.length ? 'red' : restricted ? 'yellow' : 'green'
    const pad = (text: string, width: number) => text + ' '.repeat(Math.max(0, width - text.length))

    // one block per kind: the kind label in a fixed column, its entries packed
    // beside it, continuation lines flush with the first entry
    const KIND = 4
    const room = e.props.bodyColumns - HEAD.length - HEAD_GAP - KIND - HEAD_GAP - 1
    const blocks: [string, string[], string][] = [
      ['deny', s.deny, 'red'],
      ['ask', s.ask, 'yellow'],
    ]
    const rows: RenderChildren[] = []
    for (const [kind, labels, color] of blocks) {
      // removed entries stay visible, dim and struck through, for the highlight window
      const dropped = goneNow.filter(g => g.kind === kind).map(g => g.label)
      if (!labels.length && !dropped.length) continue
      const pieces: Piece[] = [
        ...labels.map(label => ({
          width: label.length,
          node: (
            <Box key={`${kind}-${label}`}>
              <Text bold color={tint(label, color)}>{label}</Text>
            </Box>
          ),
        })),
        ...dropped.map(label => ({
          width: label.length,
          node: (
            <Box key={`${kind}-gone-${label}`}>
              <Text dimColor strikethrough>{label}</Text>
            </Box>
          ),
        })),
      ]
      pack(pieces, room, GAP).forEach((line, li) => {
        rows.push(
          <Box key={`${kind}${li}`} columnGap={HEAD_GAP}>
            {rows.length === 0 ? <Text bold color={headColor}>{HEAD}</Text> : <Text>{pad('', HEAD.length)}</Text>}
            <Text dimColor>{pad(li === 0 ? kind : '', KIND)}</Text>
            <Box>{line.flatMap((p, i) => (i ? [<Text key={`gap${i}`}>{' '.repeat(p.gap ?? GAP)}</Text>, p.node] : [p.node]))}</Box>
          </Box>,
        )
      })
    }
    if (!rows.length) {
      rows.push(
        <Box key="auto" columnGap={HEAD_GAP}>
          <Text bold color={headColor}>{HEAD}</Text>
          <Text dimColor>all auto</Text>
        </Box>,
      )
    }
    const last = await read($, block)
    if (last && typeof last.at === 'number' && (await $.clock.now()) - last.at < BLOCK_MS) {
      rows.push(
        <Box key="block" columnGap={HEAD_GAP}>
          <Text bold color={isOn ? HIGHLIGHT : 'red'}>⛔ blocked</Text>
          <Text>
            <Text bold>{last.tool}</Text>
            <Text dimColor>: {last.reason}</Text>
          </Text>
        </Box>,
      )
    }
    const mine = <Box flexDirection="column">{rows}</Box>

    // dogma below another band (credo)
    return (
      <Box flexDirection="column">
        {below}
        {mine}
      </Box>
    )
  })
}

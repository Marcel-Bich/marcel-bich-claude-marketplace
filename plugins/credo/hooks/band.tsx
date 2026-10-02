// credo band: an optional Claude Code mod that shows credo's state above the
// prompt. It only READS state through credo's core scripts and renders it; the
// core works the same without it (and in harnesses without mods).
//
// Lines: item counts per status, session mode/role + open test/question letters
// + controls, and (only while this session runs autonomously) the 5h figure,
// the next ladder rung and the next wake. One pane shows items or the
// shorthand cheatsheet; the prompt hint lists the shorthands the band hides.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'

import type { CredoCounts, CredoItemList, CredoLetters, CredoSession, CredoShorthand } from '../types'

const HIGHLIGHT = '#d946ef'
const NEW_COLOR = 'whiteBright'
const HIGHLIGHT_MS = 6000
const BLINK_MS = 500
const REFRESH_MS = 10000
const RUN_TIMEOUT_MS = 5000

const counts = atom({ plugin: 'credo', key: 'counts' } as const, null)
const isExpanded = atom({ plugin: 'credo', key: 'isExpanded' } as const, false)
const changed = atom({ plugin: 'credo', key: 'changed' } as const, [])
const created = atom({ plugin: 'credo', key: 'created' } as const, [])
const blink = atom({ plugin: 'credo', key: 'blink' } as const, false)
const session = atom({ plugin: 'credo', key: 'session' } as const, { mode: null, role: null, paused: false })
// blink phase of the mode/role tag when an autonomous run gets paused or re-armed
const sessionBlink = atom({ plugin: 'credo', key: 'sessionBlink' } as const, false)
const letters = atom({ plugin: 'credo', key: 'letters' } as const, { tests: [], questions: [] })
const auto = atom({ plugin: 'credo', key: 'auto' } as const, { running: false, wake: null, five: null, ladder: [] })
const itemList = atom({ plugin: 'credo', key: 'itemList' } as const, null)
const shorthands = atom({ plugin: 'credo', key: 'shorthands' } as const, [])

// e rotates these presets, each hiding a bit more. The dogma band reads this
// value ({ plugin: 'credo', key: 'preset' }) and hides itself at 'open only'.
const preset = atom({ plugin: 'credo', key: 'preset' } as const, 0)
const PRESETS = [
  { name: 'all', groups: [0, 1, 2], dogma: true },
  { name: 'no parked', groups: [0, 1], dogma: true },
  { name: 'open + dogma', groups: [0], dogma: true },
  { name: 'open only', groups: [0], dogma: false },
]
const presetOf = (v: number) => PRESETS[v % PRESETS.length] ?? PRESETS[0]!

type Key = keyof CredoCounts | 'parked'
type Status = { key: Key; short: string; name: string; color: string }

// groups split by color: open work, finished, parked
const GROUPS: Status[][] = [
  [
    { key: 'clarify', short: 'cf', name: 'Clarify', color: 'yellow' },
    { key: 'go', short: 'go', name: 'Go', color: 'yellow' },
    { key: 'blocked', short: 'bk', name: 'Blocked', color: 'red' },
  ],
  [
    { key: 'done', short: 'dd', name: 'Done', color: 'green' },
    { key: 'verified', short: 'vf', name: 'Verified', color: 'green' },
  ],
  [
    { key: 'parked', short: 'pk', name: 'Parked', color: 'gray' },
    { key: 'archived', short: 'ar', name: 'Archived', color: 'gray' },
  ],
]
const ALL = GROUPS.flat()

// item pane sections, in display order, keyed like credo-item-list.sh
const PANE_STATUSES = [
  { key: 'clarify', name: 'Clarify', short: 'cf', color: 'yellow' },
  { key: 'go', name: 'Go', short: 'go', color: 'yellow' },
  { key: 'blocked', name: 'Blocked', short: 'bk', color: 'red' },
  { key: 'done', name: 'Done', short: 'dd', color: 'green' },
  { key: 'verified', name: 'Verified', short: 'vf', color: 'green' },
  { key: 'hold', name: 'Hold', short: 'pk', color: 'gray' },
  { key: 'future', name: 'Future', short: 'pk future', color: 'gray' },
  { key: 'archived', name: 'Archived', short: 'ar', color: 'gray' },
]
const PER_STATUS = 15

// shorthands the prompt hint always lists (the band never shows them)
const GENERAL_SHORTHANDS = ['???', 'cm', 'ph']
// without an item system: cf / dd / vf still work on their own (clarify round,
// done, verified/verify); only the #N item moves (go bk pk ar) need items
const ITEMLESS_SHORTHANDS = ['cf', 'dd', 'vf', ...GENERAL_SHORTHANDS]

// one pane for both views, so at most one is ever open
const PANE = 'credo-panel'
const panelView = atom({ plugin: 'credo', key: 'panelView' } as const, 'items')

const HEAD = '◆ credo'
const GAP = 4
const HEAD_GAP = 2
const SAME_COLOR_GAP = 2

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

function value(c: CredoCounts, key: Key) {
  return key === 'parked' ? c.hold + c.future : c[key]
}

// runs one of credo's core scripts with this session's id (session pin, autonomy)
async function runScript($: EngineInterface, args: string[]) {
  const sid = await $.session.id()
  return $.process.run([`${$.plugin.root}/scripts/${args[0]}`, ...args.slice(1)], {
    env: { CREDO_SESSION_ID: sid },
    timeoutMs: RUN_TIMEOUT_MS,
  })
}

// counts; exit 4 (no credo project) hides the band. Any other failure (a
// timeout under load, e.g. around a compact) keeps the last known value instead
// of blanking the band, and logs the reason to the debug log.
async function refresh($: EngineInterface) {
  let next: CredoCounts | null = null
  try {
    const r = await runScript($, ['credo-item-counts.sh', '--json'])
    if (r.exitCode !== 0 && r.exitCode !== 4) {
      $.ui.log(`credo band: credo-item-counts.sh exit ${r.exitCode}: ${r.stderr.trim()}`, { to: 'debug' })
      return
    }
    next = r.exitCode === 0 ? JSON.parse(r.stdout) : null
  } catch (err) {
    $.ui.log(`credo band: credo-item-counts.sh failed: ${String(err)}`, { to: 'debug' })
    return
  }
  const prev = await read($, counts)
  await update($, counts, () => next)
  if (prev === null || next === null) return

  const diff = ALL.filter(s => value(prev, s.key) !== value(next, s.key))
  if (diff.length === 0) return
  // nothing went down -> the increases are new items (white); otherwise moves (fuchsia)
  const isNew = diff.every(s => value(next, s.key) > value(prev, s.key))
  const text = diff.map(s => `${s.short} ${value(prev, s.key)}→${value(next, s.key)}`).join(' · ')
  $.ui.toast(`credo: ${isNew ? 'new ' : ''}${text}`)
  if (isNew) await update($, created, () => diff.map(s => s.key))
  else await update($, changed, () => diff.map(s => s.key))
  // blink: alternate highlight and normal color every BLINK_MS
  for (let t = 0; t < HIGHLIGHT_MS; t += BLINK_MS) {
    await update($, blink, v => !v)
    await $.clock.sleep(BLINK_MS)
  }
  await update($, blink, () => false)
  await update($, changed, () => [])
  await update($, created, () => [])
}

// paused or re-armed: the mode/role tag blinks like an item move, plus a toast
async function flashSession($: EngineInterface, paused: boolean) {
  $.ui.toast(paused ? 'credo: autonomous run paused' : 'credo: autonomous run re-armed')
  for (let t = 0; t < HIGHLIGHT_MS; t += BLINK_MS) {
    await update($, sessionBlink, v => !v)
    await $.clock.sleep(BLINK_MS)
  }
  await update($, sessionBlink, () => false)
}

// mode, role and autonomy from credo-session-status.sh; while autonomy runs,
// also the 5h figure (credo-budget-read.sh) and the ladder rungs (credo-config.sh)
async function refreshStatus($: EngineInterface) {
  let status: {
    mode: string | null
    role: string | null
    autonomy: { running: boolean; paused: boolean; wake_scheduled: number | null }
  }
  try {
    const r = await runScript($, ['credo-session-status.sh', '--json'])
    if (r.exitCode !== 0) throw new Error(`exit ${r.exitCode}: ${r.stderr.trim()}`)
    status = JSON.parse(r.stdout)
  } catch (err) {
    // keep the last known mode/role/autonomy rather than blanking the line
    $.ui.log(`credo band: credo-session-status.sh failed: ${String(err)}`, { to: 'debug' })
    return
  }
  // credo sets the paused flag for every active/passive session too; it only
  // matters while the mode is autonomous (a user message paused the run)
  const paused = status.mode === 'autonomous' && status.autonomy.paused === true
  const prev = await read($, session)
  const nextSession: CredoSession = { mode: status.mode, role: status.role, paused }
  await update($, session, () => nextSession)
  if ((prev.paused ?? false) !== paused) void flashSession($, paused)

  if (!status.autonomy.running) {
    await update($, auto, () => ({ running: false, wake: null, five: null, ladder: [] }))
    return
  }
  let five: number | null = null
  let ladder: number[] = []
  try {
    const b = await runScript($, ['credo-budget-read.sh', '--json'])
    if (b.exitCode === 0) five = JSON.parse(b.stdout).five_hour.utilization
    const l = await runScript($, ['credo-config.sh', 'get', 'budget.autonomous_5h.main_ladder'])
    if (l.exitCode === 0) ladder = l.stdout.split('\n').map(Number).filter(n => n > 0)
  } catch {
    // keep what we have
  }
  const wake = status.autonomy.wake_scheduled
  await update($, auto, () => ({ running: true, wake, five, ladder }))
}

// newest items per status from credo-item-list.sh, for the item pane
async function refreshItems($: EngineInterface) {
  let next: CredoItemList | null = null
  try {
    const r = await runScript($, ['credo-item-list.sh', '--json', '--per', String(PER_STATUS)])
    next = r.exitCode === 0 ? JSON.parse(r.stdout) : null
  } catch {
    next = null
  }
  await update($, itemList, () => next)
}

// shorthand legend for the cheatsheet and the hint (templates/shorthands.json)
async function loadShorthands($: EngineInterface) {
  let next: CredoShorthand[] = []
  try {
    next = JSON.parse(await $.fs.read(`${$.plugin.root}/templates/shorthands.json`))
  } catch {
    next = []
  }
  await update($, shorthands, () => next)
}

async function refreshAll($: EngineInterface) {
  void refresh($)
  void refreshStatus($)
  if ((await $.ui.panes()).some(p => p.id === PANE)) void refreshItems($)
}

async function openPanel($: EngineInterface, view: 'items' | 'help') {
  await update($, panelView, () => view)
  if (view === 'items') await refreshItems($)
  await $.ui.open({ id: PANE, title: 'credo' })
}

// "Open for testing: N, S" / "Open questions: Y"; a dash or nothing means none
function parseLetters(answer: string): CredoLetters {
  const grab = (label: string) => {
    const m = answer.match(new RegExp(`${label}:\\s*([A-Z0-9, ]+)`))
    return m?.[1] ? m[1].split(',').map(x => x.trim()).filter(Boolean) : []
  }
  return { tests: grab('Open for testing'), questions: grab('Open questions') }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({ name: 'credo-items', description: 'Show credo items per status in a pane' })
    await loadShorthands($)
    await refresh($)
    await refreshStatus($)
    $.clock.every(REFRESH_MS, () => void refreshAll($))
    return started
  })

  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    if (e.tool === 'Bash') void refreshAll($)
    return result
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    void refreshAll($)
    // the main loop's answer ends with the open letters (credo verify convention)
    if (e.agentId === undefined && e.answer) {
      const parsed = parseLetters(e.answer)
      await update($, letters, () => parsed)
    }
    return next(e)
  })

  // under the prompt: only the shorthands the band does not already show
  // (statuses hidden by the preset, plus the general ones)
  on('ui.render', { component: 'PromptHint' }, async ($, e, next) => {
    const hasItems = (await read($, counts)) !== null
    // no item system: only while credo runs in this session
    if (!hasItems && (await read($, session)).mode === null) return next(e)
    const current = presetOf(await read($, preset))
    const hidden = GROUPS.filter((_, gi) => !current.groups.includes(gi))
      .flat()
      .map(s => s.short)
    // the band's long-form toggle (l) also spells out a one-word meaning here
    const long = await read($, isExpanded)
    const legend = await read($, shorthands)
    const word = (k: string) => legend.find(s => s.key === k || s.key === `#N ${k}`)?.word ?? '?'
    const keys = hasItems ? [...hidden, ...GENERAL_SHORTHANDS] : ITEMLESS_SHORTHANDS
    const tail = `Shortcuts: ${keys.map(k => (long ? `${k}(${word(k)})` : k)).join(' ')}`
    return next({ ...e, props: { ...e.props, tail } })
  })

  // /credo-items opens the item pane too
  on('command.run', { command: 'credo-items' }, async $ => {
    await openPanel($, 'items')
    return { text: 'credo items pane opened.' }
  })

  // the shared pane: item titles per status (newest first) or the cheatsheet
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    if ((await read($, panelView)) === 'help') {
      // without an item system the #N item shorthands do not apply
      const hasItems = (await read($, counts)) !== null
      const legend = (await read($, shorthands)).filter(s => hasItems || !s.key.startsWith('#N '))
      const width = Math.max(0, ...legend.map(s => s.key.length))
      return (
        <Box flexDirection="column">
          {legend.map(s => (
            <Box key={s.key}>
              <Text bold color="cyan">{s.key.padEnd(width + 2)}</Text>
              <Text wrap="truncate-end">{s.meaning}</Text>
            </Box>
          ))}
        </Box>
      )
    }
    const list = await read($, itemList)
    if (list === null) return <Text dimColor>No credo project for this session.</Text>
    const sections: RenderChildren[] = []
    for (const s of PANE_STATUSES) {
      const st = list.statuses.find(x => x.key === s.key)
      const total = st?.total ?? 0
      const shown = (st?.items ?? []).map(i => `#${i.id} ${i.title}`)
      sections.push(
        <Box key={s.key} flexDirection="column" marginBottom={1}>
          <Text bold color={s.color}>
            {s.name}({s.short}): {total}
          </Text>
          {shown.map(t => (
            <Text key={t} wrap="truncate-end">  {t}</Text>
          ))}
          {total > shown.length ? <Text dimColor>  … {total - shown.length} more</Text> : null}
        </Box>,
      )
    }
    return <Box flexDirection="column">{sections}</Box>
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const below = await next(e)
    const c = await read($, counts)
    if (e.props.hasSurvey) return below
    // without a credo project (no item system) the counts and the item controls
    // are left out; mode/role, open letters and autonomy are session state and
    // still show, as long as there is any
    const hasItems = c !== null

    const long = await read($, isExpanded)
    // highlighted only in the "on" phase of the blink
    const isOn = await read($, blink)
    const moved = isOn ? await read($, changed) : []
    const fresh = isOn ? await read($, created) : []
    const { Box, Button, Text } = $.ui.resolve(e)

    const color = (s: Status, n: number) =>
      moved.includes(s.key)
        ? HIGHLIGHT
        : fresh.includes(s.key)
          ? NEW_COLOR
          : s.key === 'blocked' && n > 0
            ? 'red'
            : s.color

    // one cell per status, statusline style: short "go: 1245", long "Go(go): 1245"
    const chipWidth = (s: Status) => {
      const n = c === null ? 1 : String(value(c, s.key)).length
      return long ? s.name.length + s.short.length + 4 + n : s.short.length + 2 + n
    }

    const current = presetOf(await read($, preset))
    const shown = GROUPS.filter((_, gi) => current.groups.includes(gi)).flat()

    const chip = (s: Status) => {
      const n = c === null ? 0 : value(c, s.key)
      const isZero = n === 0 && !moved.includes(s.key) && !fresh.includes(s.key)
      return (
        <Box key={s.key}>
          {long ? (
            <Text>
              <Text color={isZero ? undefined : color(s, n)} dimColor={isZero}>{s.name}</Text>
              <Text dimColor>({s.short}): </Text>
            </Text>
          ) : (
            <Text dimColor>{s.short}: </Text>
          )}
          <Text bold={!isZero} dimColor={isZero} color={isZero ? undefined : color(s, n)}>{n}</Text>
        </Box>
      )
    }

    // 2 spaces within a color group (cf go, dd vf, pk ar), 4 where the color changes
    const pieces: Piece[] = (hasItems ? shown : []).map((s, i) => ({
      width: chipWidth(s),
      node: chip(s),
      gap: i > 0 && shown[i - 1]?.color === s.color ? SAME_COLOR_GAP : GAP,
    }))
    // second line: session mode/role, open letters, then the controls
    const meta: Piece[] = []

    // third line, only while this session runs autonomously: 5h now, the next ladder rung, next wake
    const autoLine: Piece[] = []
    const a = await read($, auto)
    if (a.running) {
      const nextRung = a.five === null ? null : a.ladder.find(r => r > (a.five ?? 0)) ?? null
      const hard = a.ladder[3] ?? null
      const danger = a.five !== null && hard !== null && a.five >= hard
      const wakeAt = a.wake ? new Date(a.wake * 1000).toTimeString().slice(0, 5) : null
      const parts = [
        a.five === null ? '5h ?' : `5h ${a.five}%${nextRung === null ? '' : `→${nextRung}`}`,
        wakeAt ? `wake ${wakeAt}` : '',
      ].filter(Boolean)
      const text = parts.join('  ')
      autoLine.push({
        width: 7 + text.length,
        node: (
          <Text key="auto">
            <Text bold color="magenta">⟳ auto </Text>
            <Text color={danger ? 'red' : 'magenta'}>{text}</Text>
          </Text>
        ),
      })
    }
    const ses = await read($, session)
    const modeTag = ses.mode && ses.paused ? `${ses.mode} paused` : ses.mode
    const tags = [modeTag, ses.role].filter((x): x is string => x !== null).join('/')
    const sesColor = (await read($, sessionBlink)) ? HIGHLIGHT : 'cyan'
    if (tags) meta.push({ width: tags.length, node: <Text key="ses" color={sesColor}>{tags}</Text> })

    // open test and question letters, so nothing waiting on the user gets lost
    const open = await read($, letters)
    if (open.tests.length) {
      const text = open.tests.join(' ')
      meta.push({ width: 3 + text.length, node: <Text key="tests"><Text>🧪 </Text><Text bold color="blue">{text}</Text></Text> })
    }
    if (open.questions.length) {
      const text = open.questions.join(' ')
      meta.push({ width: 3 + text.length, node: <Text key="questions"><Text>❓ </Text><Text bold color="blue">{text}</Text></Text> })
    }

    if (!hasItems && meta.length === 0 && autoLine.length === 0) return below

    if (hasItems)
      meta.push({
        width: 10,
        node: <Button key="items" hotkey="i" plain dimColor label="☰ items" onPress={() => openPanel($, 'items')} />,
      })
    meta.push({
      width: 9,
      node: <Button key="help" hotkey="h" plain dimColor label="? help" onPress={() => openPanel($, 'help')} />,
    })
    if (hasItems)
      meta.push({
        width: 4,
        node: <Button key="form" hotkey="l" plain dimColor label="⇆" onPress={() => update($, isExpanded, v => !v)} />,
      })
    if (hasItems)
      meta.push({
        width: 4 + current.name.length,
        node: (
          <Button
            key="preset"
            hotkey="e"
            plain
            dimColor
            label={`◐ ${current.name}`}
            onPress={() => update($, preset, v => (v + 1) % PRESETS.length)}
          />
        ),
      })

    // wrap by hand against the band's real width, so the band knows its height;
    // the counts first (head on the first line), then the meta line, both indented alike
    const room = e.props.bodyColumns - HEAD.length - HEAD_GAP - 1
    const lines = [...(pieces.length ? pack(pieces, room, GAP) : []), ...pack(meta, room, GAP), ...(autoLine.length ? pack(autoLine, room, GAP) : [])]
    const mine = (
      <Box flexDirection="column">
        {lines.map((line, li) => (
          <Box key={`l${li}`} columnGap={HEAD_GAP}>
            {li === 0 ? <Text bold color="cyan">{HEAD}</Text> : <Text>{' '.repeat(HEAD.length)}</Text>}
            <Box>{line.flatMap((p, i) => (i ? [<Text key={`gap${i}`}>{' '.repeat(p.gap ?? GAP)}</Text>, p.node] : [p.node]))}</Box>
          </Box>
        ))}
      </Box>
    )

    // credo on top; another band (dogma) below
    return (
      <Box flexDirection="column">
        {mine}
        {below}
      </Box>
    )
  })
}

// Pure helpers for the self-restart notice of credo's band (band.tsx): parse
// the marker written by scripts/credo-self-restart.py, decide whether this
// session shows the notice, and format the countdown. No engine imports, so
// they can be checked on their own.
//
// Marker: ${CLAUDE_CONFIG_DIR:-~/.claude}/credo/self-restart.json with
// session_id, started, reason, status (pending | cancelled | stopping |
// updating | relaunched | failed: ...), scheduled (ISO 8601 with offset), ...

import type { CredoRestart } from '../types'

export type RestartMarker = {
  sessionId: string
  status: string
  reason: string
  scheduledMs: number | null
}

// statuses during which this session is still waiting to be stopped
const VISIBLE = ['pending', 'stopping']

export function parseMarker(text: string): RestartMarker | null {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  if (raw === null || typeof raw !== 'object') return null
  const m = raw as Record<string, unknown>
  if (typeof m.session_id !== 'string' || typeof m.status !== 'string') return null
  const parsed = typeof m.scheduled === 'string' ? Date.parse(m.scheduled) : NaN
  return {
    sessionId: m.session_id,
    status: m.status,
    reason: typeof m.reason === 'string' ? m.reason : '',
    scheduledMs: Number.isFinite(parsed) ? parsed : null,
  }
}

// shown only for this session and only while the restart is still ahead
export function isVisible(marker: RestartMarker | null, sessionId: string): boolean {
  return marker !== null && sessionId !== '' && marker.sessionId === sessionId && VISIBLE.includes(marker.status)
}

// remaining time as m:ss (h:mm:ss from one hour); null without a schedule
export function formatCountdown(scheduledMs: number | null, nowMs: number): string | null {
  if (scheduledMs === null) return null
  const total = Math.max(0, Math.ceil((scheduledMs - nowMs) / 1000))
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = String(total % 60).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`
}

// the notice for this session, or null when nothing is to be shown
export function restartNotice(marker: RestartMarker | null, sessionId: string, nowMs: number): CredoRestart | null {
  if (!isVisible(marker, sessionId) || marker === null) return null
  const when =
    marker.status === 'stopping' ? 'now' : (() => {
      const left = formatCountdown(marker.scheduledMs, nowMs)
      return left === null ? 'pending' : `in ${left}`
    })()
  const reason = marker.reason ? ` (reason: ${marker.reason})` : ''
  const cancel = marker.status === 'pending' ? ' - cancel: credo-self-restart.py cancel' : ''
  return { text: `credo self-restart ${when}${reason}${cancel}` }
}

// how long the toast outlives the scheduled stop: covers the stop, the update and
// the relaunch; the old TUI goes away with the restart anyway
const TOAST_GRACE_MS = 2 * 60 * 1000

export type RestartToast = { key: string; text: string; timeoutMs: number }

// ONE static toast per pending restart (no countdown, so it never needs refreshing):
// the band shows it once per key and lets it stand until the restart
export function restartToast(marker: RestartMarker | null, sessionId: string, nowMs: number): RestartToast | null {
  if (!isVisible(marker, sessionId) || marker === null) return null
  const pad = (n: number) => String(n).padStart(2, '0')
  const at = marker.scheduledMs === null ? null : new Date(marker.scheduledMs)
  const when =
    marker.status === 'stopping' ? 'now'
      : at === null ? 'pending'
        : `at ${pad(at.getHours())}:${pad(at.getMinutes())}:${pad(at.getSeconds())}`
  const reason = marker.reason ? ` (reason: ${marker.reason})` : ''
  const cancel = marker.status === 'pending' ? ' - cancel: credo-self-restart.py cancel' : ''
  const left = marker.scheduledMs === null ? 0 : Math.max(0, marker.scheduledMs - nowMs)
  return {
    key: `${marker.sessionId}|${marker.scheduledMs ?? ''}|${marker.reason}`,
    text: `credo self-restart ${when}${reason}${cancel}`,
    timeoutMs: left + TOAST_GRACE_MS,
  }
}

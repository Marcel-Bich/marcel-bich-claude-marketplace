// State contract of credo's optional Claude Code band (hooks/band.tsx).
// Every value is a read-only mirror of what credo's core scripts print; the
// band keeps no state of its own beyond view toggles and highlights.

/** scripts/credo-item-counts.sh --json (credo_dir omitted) */
export type CredoCounts = {
  clarify: number
  go: number
  blocked: number
  done: number
  verified: number
  archived: number
  hold: number
  future: number
}

/** mode and role from scripts/credo-session-status.sh --json; paused only while mode is autonomous */
export type CredoSession = { mode: string | null; role: string | null; paused: boolean }

/** open test / question letters parsed from the last main-loop answer */
export type CredoLetters = { tests: string[]; questions: string[] }

/** autonomy of this session plus the 5h figure and the ladder rungs */
export type CredoAuto = { running: boolean; wake: number | null; five: number | null; ladder: number[] }

/** scripts/credo-item-list.sh --json */
export type CredoItemList = {
  credo_dir: string
  statuses: { key: string; folder: string; total: number; items: { id: string; title: string }[] }[]
}

/** this session's pending self-restart (scripts/credo-self-restart.py marker), as shown by the band and the toast */
export type CredoRestart = { text: string }

/** one entry of templates/shorthands.json */
export type CredoShorthand = { key: string; word: string; meaning: string }

declare module 'claude-code' {
  interface PluginState {
    credo: {
      counts: CredoCounts | null
      isExpanded: boolean
      changed: string[]
      created: string[]
      blink: boolean
      preset: number
      session: CredoSession
      sessionBlink: boolean
      letters: CredoLetters
      panelView: string
      auto: CredoAuto
      itemList: CredoItemList | null
      shorthands: CredoShorthand[]
      restart: CredoRestart | null
      restartBlink: boolean
    }
  }
}

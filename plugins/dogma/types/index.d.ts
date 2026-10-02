// State contract of dogma's optional Claude Code band (hooks/band.tsx).
// Every value is a read-only mirror of what scripts/permissions-summary.sh
// prints, plus short-lived highlights; dogma's hooks stay the only enforcer.

/** scripts/permissions-summary.sh --json */
export type DogmaSummary = { file: string; ask: string[]; deny: string[] }

/** an entry that left the summary, shown struck through for a few seconds */
export type DogmaGone = { kind: 'deny' | 'ask'; label: string }

/** the last dogma PreToolUse block, shown for a few seconds */
export type DogmaBlock = { tool: string; reason: string }

declare module 'claude-code' {
  interface PluginState {
    dogma: {
      summary: DogmaSummary | null
      moved: string[]
      fresh: string[]
      gone: DogmaGone[]
      blink: boolean
      block: DogmaBlock | null
    }
  }
}

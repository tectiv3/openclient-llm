import { appendFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

// Diagnostic file logging. Enable with PI_RC_DEBUG=1 (writes to
// ~/.pi/agent/rc-debug.log) or PI_RC_DEBUG_FILE=<path>. Off by default.
function debugLogPath(): string | null {
  const file = process.env.PI_RC_DEBUG_FILE?.trim()
  if (file) return file
  if (process.env.PI_RC_DEBUG?.trim()) return join(homedir(), '.pi', 'agent', 'rc-debug.log')
  return null
}

function safeJson(value: unknown): string {
  try {
    return JSON.stringify(value) ?? String(value)
  } catch {
    return String(value)
  }
}

export function dbgLog(...parts: unknown[]): void {
  const path = debugLogPath()
  if (!path) return
  const line = parts
        .map(part => (typeof part === 'string' ? part : safeJson(part)))
        .join(' ')
  try {
    appendFileSync(path, `[${new Date().toISOString()}] ${line}\n`)
  } catch {
    // Diagnostics must never break the server
  }
}

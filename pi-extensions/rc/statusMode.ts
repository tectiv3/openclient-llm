import { readRawConfig } from './apns'

// Footer-status presentation mode, configured by an optional `"status"` key in
// ~/.pi/agent/rc-push.json. Display-only: nothing else in rc reads it.
export type StatusMode = 'full' | 'quiet'

export const QUIET_ANCHOR_STATUS = '🐙'
export const QUIET_SIBLING_STATUS = '🐚'

export type StatusParts = {
    isAnchor: boolean
    host: string
    port: number
    code: string
    clientsText: string
    pushText: string
    lastPush?: string
}

export function statusModeFromConfig(raw: Record<string, unknown>): StatusMode {
    const value = raw.status
    if (typeof value !== 'string') return 'full'
    return value.trim().toLowerCase() === 'quiet' ? 'quiet' : 'full'
}

// Resolved per refresh, not cached at /rc start: a refresh happens only on a
// status-changing event, and reading a small JSON file there is free — the same
// trade-off resolveApnsConfig() documents. A config edit therefore takes effect
// on the next status change without /rc off+on.
export function readStatusMode(): StatusMode {
    return statusModeFromConfig(readRawConfig())
}

export function statusText(mode: StatusMode, parts: StatusParts): string {
    if (mode === 'quiet') return parts.isAnchor ? QUIET_ANCHOR_STATUS : QUIET_SIBLING_STATUS
    const lastPush = parts.lastPush ? ` · ${parts.lastPush}` : ''
    return `rc: ws://${parts.host}:${parts.port} code ${parts.code} · ${parts.clientsText} · ${parts.pushText}${lastPush}`
}

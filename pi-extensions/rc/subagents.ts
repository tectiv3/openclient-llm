// Subagent attach (spec: docs/plans/2026-09-13-rc-subagent-attach-stop-ux.md,
// Feature B). Pure module — all I/O (file listing/reading, pid liveness) is
// injected so it is unit-testable without a pi process; the index.ts wiring
// passes the real fs/process probes.
// READ-ONLY by contract: nothing here unlinks or writes files — the subagent
// extension manages its own artifacts.

import { pruneBufferForSnapshot, tailClassification, type BufferBlock } from './turnBuffer'

// Structural twin of the subagent extension's SubagentMeta (pi-extensions
// repo) — the fields rc needs, optional where torn/older metas may lack them.
export type SubagentStatus = 'succeeded' | 'failed' | 'aborted'

export interface SubagentMeta {
    agent: string
    task: string
    model?: string
    thinkingLevel?: string
    startedAt: string
    promptHash?: string
    parentSessionId?: string
    // The spawning `subagent` tool call id (absent for non-tool spawns such as
    // /subagents resume) — lets the phone open a run from its transcript step.
    toolCallId?: string
    resumedCount?: number
    status?: SubagentStatus
    stopReason?: string
    exitCode?: number
    sessionHeaderId?: string
}

export interface ScannedSubagent {
    id: string
    meta: SubagentMeta
}

export const SUBAGENT_TERMINAL_STATUSES: Set<string> = new Set<string>([
    'succeeded',
    'failed',
    'aborted',
])

export interface ScanOptions {
    dir: string
    sessionId: string
    listFiles: (dir: string) => string[]
    readFile: (path: string) => string
    isAlive: (pid: number) => boolean
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null
}

function stringFrom(value: unknown): string | undefined {
    return typeof value === 'string' && value.length > 0 ? value : undefined
}

// Validation is permissive on purpose (a torn mid-rewrite meta must not kill
// the scan) but requires the fields every consumer displays. Returns a fresh
// object so callers never see the raw parsed JSON. Exported: the settle poll
// in index.ts re-parses a run's meta each tick.
export function parseSubagentMeta(value: unknown): SubagentMeta | null {
    if (!isObject(value)) return null
    const agent = stringFrom(value.agent)
    const task = value.task
    const startedAt = stringFrom(value.startedAt)
    if (agent === undefined || typeof task !== 'string' || startedAt === undefined) return null
    return {
        agent,
        task,
        model: stringFrom(value.model),
        thinkingLevel: stringFrom(value.thinkingLevel),
        startedAt,
        promptHash: stringFrom(value.promptHash),
        parentSessionId: stringFrom(value.parentSessionId),
        toolCallId: stringFrom(value.toolCallId),
        resumedCount: typeof value.resumedCount === 'number' ? value.resumedCount : undefined,
        status:
            typeof value.status === 'string' ? (value.status as SubagentStatus) : undefined,
        stopReason: stringFrom(value.stopReason),
        exitCode: typeof value.exitCode === 'number' ? value.exitCode : undefined,
        sessionHeaderId: stringFrom(value.sessionHeaderId),
    }
}

function readPid(readFile: (path: string) => string, path: string): number | undefined {
    let content: string
    try {
        content = readFile(path)
    } catch {
        return undefined
    }
    const pid = Number.parseInt(content.trim(), 10)
    return Number.isNaN(pid) || pid <= 0 ? undefined : pid
}

// LIVE runs of one session: meta readable + scoped to that session + pidfile
// present and its process alive + status not terminal. Runs WITHOUT a
// parentSessionId are hidden, matching the /subagents manager. Newest first
// (the extension lists by startedAt desc).
export function scanLiveSubagents(opts: ScanOptions): ScannedSubagent[] {
    let files: string[]
    try {
        files = opts.listFiles(opts.dir)
    } catch {
        return []
    }
    const listed = new Set(files)
    const runs: ScannedSubagent[] = []
    for (const file of files) {
        if (!file.endsWith('.meta')) continue
        const id = file.slice(0, -'.meta'.length)
        let meta: SubagentMeta | null
        try {
            meta = parseSubagentMeta(JSON.parse(opts.readFile(`${opts.dir}/${file}`)))
        } catch {
            continue // torn/unreadable meta — same skip as the extension
        }
        if (meta === null) continue
        if (stringFrom(meta.parentSessionId) !== opts.sessionId) continue
        if (!listed.has(`${id}.pid`)) continue
        const pid = readPid(opts.readFile.bind(opts), `${opts.dir}/${id}.pid`)
        if (pid === undefined || !opts.isAlive(pid)) continue
        const status = typeof meta.status === 'string' ? meta.status : undefined
        if (status !== undefined && SUBAGENT_TERMINAL_STATUSES.has(status)) continue
        runs.push({ id, meta })
    }
    runs.sort((a, b) => (b.meta.startedAt ?? b.id).localeCompare(a.meta.startedAt ?? a.id))
    return runs
}

export type AttachCandidate =
    | { ok: true; run: ScannedSubagent }
    | { ok: false; code: 'not_found' | 'ambiguous'; message: string }

function formatLiveLine(run: ScannedSubagent): string {
    const taskPreview =
        run.meta.task.length > 60 ? `${run.meta.task.slice(0, 60)}…` : run.meta.task
    return `- ${run.id.slice(0, 8)} — agent: ${run.meta.agent}, task: ${taskPreview}`
}

// subagentId: exact, else unique prefix against the live list (decision #8).
// toolCallId: exact match ONLY — a toolCallId prefix must never resolve.
// When both are provided, subagentId wins (and its failure does NOT fall
// back to toolCallId).
export function resolveAttachCandidate(
    live: readonly ScannedSubagent[],
    subagentId?: string,
    toolCallId?: string
): AttachCandidate {
    if (subagentId) {
        const exact = live.find(run => run.id === subagentId)
        if (exact) return { ok: true, run: exact }
        const matches = live.filter(run => run.id.startsWith(subagentId))
        if (matches.length === 1) return { ok: true, run: matches[0] }
        if (matches.length > 1) {
            return {
                ok: false,
                code: 'ambiguous',
                message: [
                    `Ambiguous subagent id "${subagentId}" matches ${matches.length} live subagents:`,
                    ...matches.map(formatLiveLine),
                    'Use more characters or the full id.',
                ].join('\n'),
            }
        }
        return {
            ok: false,
            code: 'not_found',
            message:
                live.length === 0
                    ? `No live subagent matches "${subagentId}". No live subagent runs in this session.`
                    : [
                          `No live subagent matches "${subagentId}". Live subagents:`,
                          ...live.map(formatLiveLine),
                      ].join('\n'),
        }
    }
    if (toolCallId) {
        const match = live.find(run => run.meta.toolCallId === toolCallId)
        if (match) return { ok: true, run: match }
        return {
            ok: false,
            code: 'not_found',
            message: `No live subagent matches toolCallId "${toolCallId}".`,
        }
    }
    return { ok: false, code: 'not_found', message: 'No subagent id or toolCallId provided.' }
}

// Bus payload shape (verified): {subagentId, agent, event} where `event` is
// the raw pi RPC frame — the event name IS event.type (there is no `name`
// field on the bus). Returns the frame's name/payload; null when malformed.
export function mapBusEvent(
    busPayload: unknown
): { name: string; payload: Record<string, unknown> } | null {
    if (!isObject(busPayload)) return null
    const event = busPayload.event
    if (!isObject(event)) return null
    const name = event.type
    if (typeof name !== 'string' || name.length === 0) return null
    const { type: _type, ...rest } = event
    return { name, payload: rest }
}

// Forward-to-clients whitelist (spec Feature B): everything else is consumed
// for internal state only.
export const SUBAGENT_EVENT_WHITELIST: Set<string> = new Set<string>([
    'message_start',
    'message_update',
    'tool_execution_start',
    'tool_execution_update',
    'tool_execution_end',
    'turn_end',
    'agent_start',
    'agent_settled',
])

export interface SettleInput {
    metaPresent: boolean
    metaStatus?: SubagentStatus
    metaStopReason?: string
    pidAlive: boolean
    lastObservedStopReason?: string
    deadlineExceeded: boolean
}

export interface SettleResult {
    status: SubagentStatus
    stopReason?: string
    extend: boolean
}

// Keyed on META, never the pidfile (m1: the extension removes .pid
// unconditionally FIRST on every exit, so the pidfile is not a classifier).
// `extend` tells the poll loop to keep waiting (pid still alive — a slow
// clean shutdown must not misreport failed); the deadline is the hard stop.
export function classifySettle(input: SettleInput): SettleResult {
    const stopReason =
        stringFrom(input.metaStopReason) ?? stringFrom(input.lastObservedStopReason)
    const result = (status: SubagentStatus, extend: boolean): SettleResult => ({
        status,
        ...(stopReason !== undefined ? { stopReason } : {}),
        extend,
    })
    if (!input.metaPresent) return result('succeeded', false)
    if (input.metaStatus !== undefined) return result(input.metaStatus, false)
    if (input.deadlineExceeded) return result('failed', false)
    if (input.pidAlive) return result('failed', true)
    return result('failed', false)
}

export interface SubagentSnapshot {
    history: unknown[]
    buffer: BufferBlock[]
}

// history elements are mapHistoryEntry-shaped (the index.ts wiring parses the
// child's .jsonl). The buffer is pruned by the Feature A function with the
// LAST jsonl message as branch tail. Missing/unreadable jsonl → the wiring
// passes no last entry: nothing committed is known, so nothing can be pruned
// and there is no history to show.
export function buildSubagentSnapshot(input: {
    history: readonly unknown[]
    buffer: readonly BufferBlock[]
    lastJsonlMessage?: unknown
}): SubagentSnapshot {
    if (input.lastJsonlMessage === undefined) {
        return { history: [], buffer: [...input.buffer] }
    }
    return {
        history: [...input.history],
        buffer: pruneBufferForSnapshot(
            input.buffer,
            tailClassification(input.lastJsonlMessage)
        ),
    }
}

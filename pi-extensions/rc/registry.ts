import { randomBytes, randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, watch, writeFileSync } from 'node:fs'
import * as net from 'node:net'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { dbgLog } from './debug'

// Liveness probe timeout: a dead port should surface quickly enough that the
// phone's list does not show a session for long after its process is gone.
const PROBE_TIMEOUT_MS = 500
// Registry change debounce: coalesces bursts (a status change plus its
// watch + poll triggers) into one callback per ~window.
const WATCH_DEBOUNCE_MS = 250
// Default poll interval: watch is only a latency accelerator, so polling
// alone must keep the list alive when the file disappears or watch errors.
const POLL_DEFAULT_MS = 5000

export type RcModelRef = {
    provider: string
    id: string
}

export type RcSessionEntry = {
    id: string
    port: number
    pid: number
    host: string
    token: string
    isAnchor: boolean
    sessionId: string
    cwd: string
    name: string
    model: RcModelRef
    isStreaming: boolean
    hasQuestion: boolean
    compacting: boolean
    lastActivity: string
}

export type RcRegistry = {
    sessions: RcSessionEntry[]
}

export function registryPath(): string {
    // Test seam (mirrors PI_RC_AUTH_FILE / PI_RC_APNS_CONFIG): lets the
    // harness point child processes at an isolated file so real sessions
    // never leak into a test run.
    const fromEnv = process.env.PI_RC_REGISTRY?.trim()
    if (fromEnv) return fromEnv
    return join(homedir(), '.pi', 'agent', 'rc-registry.json')
}

type FileRead =
    | { status: 'missing' }
    | { status: 'unreadable' }
    | { status: 'content'; content: string }

// missing (fresh state) and unreadable (treated as corrupt) are distinct
// states on purpose: a writer must never merge into an empty read, or it
// would clobber every other entry on the machine.
function readFile(path: string): FileRead {
    try {
        return { status: 'content', content: readFileSync(path, 'utf8') }
    } catch (error) {
        return (error as NodeJS.ErrnoException).code === 'ENOENT'
            ? { status: 'missing' }
            : { status: 'unreadable' }
    }
}

// null (not an empty registry) is "corrupt or unreadable": callers MUST
// treat it as "abort this write, retry on the next change".
export function readRegistry(): RcRegistry | null {
    const read = readFile(registryPath())
    if (read.status === 'missing') return { sessions: [] }
    if (read.status === 'unreadable') return null
    return parseRegistry(read.content)
}

function parseRegistry(raw: string): RcRegistry | null {
    try {
        const parsed: unknown = JSON.parse(raw)
        if (typeof parsed !== 'object' || parsed === null) return null
        const sessions = (parsed as { sessions?: unknown }).sessions
        if (!Array.isArray(sessions)) return null
        return { sessions: sessions as RcSessionEntry[] }
    } catch {
        return null
    }
}

// The merge-on-write primitive: fresh read → mutate → diff → atomic write.
// The read happens here (after any debounce flush, never at trigger time) so
// a writer can never carry another writer's status from an old snapshot.
export function writeRegistry(
    mutate: (registry: RcRegistry) => RcRegistry
): 'written' | 'unchanged' | 'aborted_corrupt' {
    const path = registryPath()
    const read = readFile(path)
    let current: RcRegistry
    if (read.status === 'missing') {
        // File missing: fresh state, not corruption.
        current = { sessions: [] }
    } else if (read.status === 'unreadable') {
        // Corrupt file: abort without touching it. The pending value is
        // retained by the caller and retried on the next change.
        dbgLog('registry write aborted: file present but unparseable')
        return 'aborted_corrupt'
    } else {
        current = parseRegistry(read.content)
        if (current === null) {
            dbgLog('registry write aborted: file present but unparseable')
            return 'aborted_corrupt'
        }
    }
    const next = mutate(current)
    const serialized = `${JSON.stringify(next, null, 2)}\n`
    if (read.status === 'content' && read.content === serialized) {
        // Diff before rename: an anchor prune whose view already matches the
        // file must not rename, or the write would re-trigger its own
        // fs.watch in a loop.
        return 'unchanged'
    }
    const dir = dirname(path)
    if (dir !== '.' && !existsSync(dir)) mkdirSync(dir, { recursive: true })
    const tempFile = `${path}.${process.pid}.${Date.now()}.tmp`
    writeFileSync(tempFile, serialized, { encoding: 'utf8', mode: 0o600 })
    renameSync(tempFile, path)
    return 'written'
}

export function upsertEntry(entry: RcSessionEntry): ReturnType<typeof writeRegistry> {
    return writeRegistry(registry => {
        const index = registry.sessions.findIndex(session => session.id === entry.id)
        if (index === -1) return { sessions: [...registry.sessions, entry] }
        // Keyed by id, not index: a prune in between may have shifted rows.
        const sessions = [...registry.sessions]
        sessions[index] = entry
        return { sessions }
    })
}

export function removeEntry(id: string): ReturnType<typeof writeRegistry> {
    return writeRegistry(registry => ({
        sessions: registry.sessions.filter(session => session.id !== id),
    }))
}

function isProcessAlive(pid: number): boolean {
    try {
        process.kill(pid, 0)
    } catch (error) {
        // EPERM means the process exists (we just cannot signal it) — alive.
        if ((error as NodeJS.ErrnoException).code === 'ESRCH') return false
    }
    return true
}

export function probePort(port: number): Promise<boolean> {
    // Probes always target loopback — never the entry's `host` — because
    // sibling servers are loopback-only. The anchor's own entry must never
    // be probe-pruned by the anchor: it binds the tailnet interface, not
    // loopback, so a loopback probe of it would refuse, and it self-excludes
    // in pruneStaleEntries instead.
    return new Promise(resolve => {
        const socket = net
            .connect({ port, host: '127.0.0.1', timeout: PROBE_TIMEOUT_MS })
            .once('connect', () => {
                socket.destroy()
                resolve(true)
            })
            .once('error', () => {
                socket.destroy()
                resolve(false)
            })
            .once('timeout', () => {
                socket.destroy()
                resolve(false)
            })
    })
}

export async function pruneStaleEntries(
    selfEntryId?: string
): Promise<'written' | 'unchanged' | 'aborted_corrupt'> {
    const registry = readRegistry()
    if (registry === null) {
        dbgLog('registry prune aborted: file present but unparseable')
        return 'aborted_corrupt'
    }
    const alive: RcSessionEntry[] = []
    for (const entry of registry.sessions) {
        // Self-exclusion: the caller's own entry is kept unconditionally — no
        // probe, no kill(0). The anchor's listener is owned by this same
        // process (if the process runs, the listener runs), and a loopback
        // probe would be actively wrong for it: the anchor binds the tailnet
        // interface, not loopback, so its own port refuses the probe.
        if (entry.id === selfEntryId) {
            alive.push(entry)
            continue
        }
        // The TCP probe is authoritative (it also covers pid reuse after a
        // restart: a live pid with a dead port is pruned); kill(pid, 0) is
        // advisory only and can never veto a failed probe.
        const probeOk = await probePort(entry.port)
        const pidOk = isProcessAlive(entry.pid)
        if (!probeOk) {
            dbgLog(
                `registry pruned stale entry ${entry.id} (pid ${entry.pid}, port ${entry.port})`
            )
            if (pidOk) dbgLog('  note: pid reported alive — kill(0) is advisory only')
            continue
        }
        alive.push(entry)
    }
    if (alive.length === registry.sessions.length) return 'unchanged'
    // The dead set is computed from the probe pass; at write time, drop by
    // id from the FRESH read so an entry registered between the probe pass
    // and the rename survives (a full replace would clobber it). Entry ids
    // are unique, so the set is a stable key across the two reads.
    const deadIds = new Set<string>(registry.sessions.map(session => session.id))
    for (const entry of alive) deadIds.delete(entry.id)
    return writeRegistry(current => ({
        sessions: current.sessions.filter(session => !deadIds.has(session.id)),
    }))
}

export function watchRegistry(
    callback: (registry: RcRegistry) => void,
    opts?: { pollMs?: number }
): { stop(): void } {
    // Watch is a latency accelerator, not the liveness path: polling alone
    // must keep delivering updates if the file disappears or watch errors.
    // Callbacks are debounced trailing so a burst (write + poll) coalesces
    // into one. The callback always receives a freshly-read registry, never
    // a value read at watch setup time.
    const pollMs = opts?.pollMs ?? POLL_DEFAULT_MS
    let debounce: NodeJS.Timeout | null = null
    // Corrupt file: deliver the last good value (empty if none yet) rather
    // than an empty registry — an empty read must never look like "all
    // sessions gone".
    let lastGood: RcRegistry = { sessions: [] }
    let stopped = false

    const schedule = () => {
        if (debounce) clearTimeout(debounce)
        debounce = setTimeout(() => {
            debounce = null
            if (stopped) return
            const registry = readRegistry()
            if (registry !== null) lastGood = registry
            try {
                callback(lastGood)
            } catch (error) {
                // The callback is anchor-owned broadcast code; a throw must
                // not take down the poll loop.
                dbgLog('registry watch callback failed:', errorMessage(error))
            }
        }, WATCH_DEBOUNCE_MS)
    }

    const poll = setInterval(schedule, pollMs)

    let watcher: ReturnType<typeof watch> | null = null
    try {
        // A file that is created after setup is still caught by polling;
        // watch errors (ENOENT on some platforms) only mean we wait for the
        // next poll — not a failure.
        watcher = watch(registryPath(), () => schedule())
        watcher.on('error', () => {
            watcher?.close()
            watcher = null
        })
    } catch {
        watcher = null
    }

    return {
        stop() {
            stopped = true
            if (debounce) {
                clearTimeout(debounce)
                debounce = null
            }
            clearInterval(poll)
            watcher?.close()
            watcher = null
        },
    }
}

export function generateEntryToken(): string {
    return randomBytes(32).toString('hex')
}

export function newEntryId(): string {
    return randomUUID()
}

function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error)
}

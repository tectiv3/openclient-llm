import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import * as net from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pruneStaleEntries, upsertEntry, type RcSessionEntry } from '../registry'

// The PI_RC_REGISTRY seam is read lazily inside registryPath() on every call,
// so no module reload (vi.resetModules) is needed: a fresh tmp dir per test is
// enough. The real ~/.pi/agent/rc-registry.json is never touched.
let tmpDir: string
let registryFile: string
let debugFile: string
const savedRegistryEnv = process.env.PI_RC_REGISTRY
const savedDebugFileEnv = process.env.PI_RC_DEBUG_FILE
const servers: net.Server[] = []

function makeEntry(id: string, overrides: Partial<RcSessionEntry> = {}): RcSessionEntry {
    return {
        id,
        port: 47801,
        pid: process.pid,
        host: '127.0.0.1',
        token: `token-${id}`,
        isAnchor: false,
        sessionId: '11111111-1111-4111-8111-111111111111',
        cwd: `/tmp/proj-${id}`,
        name: id,
        model: { provider: 'anthropic', id: 'claude-opus' },
        isStreaming: false,
        hasQuestion: false,
        compacting: false,
        lastActivity: new Date(0).toISOString(),
        ...overrides,
    }
}

type RcRegistryLike = { sessions: RcSessionEntry[] }

function readRegistryFile(): RcRegistryLike {
    return JSON.parse(readFileSync(registryFile, 'utf8'))
}

function readSessionIds(): string[] {
    return readRegistryFile().sessions.map(session => session.id)
}

function readRaw(): string {
    return readFileSync(registryFile, 'utf8')
}

// A port that nothing is listening on right now: bind a throwaway server on
// port 0, take its port, then close it.
function freePort(): Promise<number> {
    return new Promise((resolve, reject) => {
        const server = net.createServer()
        server.once('error', reject)
        server.listen(0, '127.0.0.1', () => {
            const port = (server.address() as net.AddressInfo).port
            server.close(() => resolve(port))
        })
    })
}

// A server that stays listening for the duration of the test.
function listenServer(): Promise<{ server: net.Server; port: number }> {
    return new Promise((resolve, reject) => {
        const server = net.createServer()
        server.once('error', reject)
        server.listen(0, '127.0.0.1', () => {
            resolve({ server, port: (server.address() as net.AddressInfo).port })
        })
    })
}

function closeServer(server: net.Server): Promise<void> {
    return new Promise(resolve => server.close(() => resolve()))
}

beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'rc-registry-test-'))
    registryFile = join(tmpDir, 'rc-registry.json')
    debugFile = join(tmpDir, 'debug.log')
    process.env.PI_RC_REGISTRY = registryFile
    // Capture the "write aborted" log lines so the recovery tests can assert on them.
    process.env.PI_RC_DEBUG_FILE = debugFile
})

afterEach(async () => {
    await Promise.all(servers.splice(0).map(closeServer))
    rmSync(tmpDir, { recursive: true, force: true })
    process.env.PI_RC_REGISTRY = savedRegistryEnv
    process.env.PI_RC_DEBUG_FILE = savedDebugFileEnv
})

describe('merge-on-write (concurrent-writer freshness)', () => {
    it('each entry keeps its own latest status when writers interleave', () => {
        const a1 = makeEntry('A', { name: 'A-v1', isStreaming: true, lastActivity: 't1' })
        const b1 = makeEntry('B', { name: 'B-v1' })
        const a2 = makeEntry('A', { name: 'A-v2', isStreaming: false, lastActivity: 't2' })

        expect(upsertEntry(a1)).toBe('written')
        expect(upsertEntry(b1)).toBe('written')
        // A's second write must merge on a FRESH read: B's row survives, and A's
        // row must be v2 — not v1 carried over from A's pre-B snapshot.
        expect(upsertEntry(a2)).toBe('written')

        const sessions = readRegistryFile().sessions
        const a = sessions.find(session => session.id === 'A')
        const b = sessions.find(session => session.id === 'B')
        // Assert values, not mere existence: existence alone also passes the
        // naive stale-clobber bug.
        expect(a?.name).toBe('A-v2')
        expect(a?.isStreaming).toBe(false)
        expect(a?.lastActivity).toBe('t2')
        expect(b?.name).toBe('B-v1')
        expect(readSessionIds()).toEqual(['A', 'B'])
    })
})

describe('prune: diff-before-rename', () => {
    it('nothing dead: file content and mtime are unchanged', async () => {
        const { server, port } = await listenServer()
        servers.push(server)
        expect(upsertEntry(makeEntry('live', { port }))).toBe('written')
        const before = readRaw()
        const beforeMtime = statSync(registryFile).mtimeMs

        expect(await pruneStaleEntries()).toBe('unchanged')

        expect(readRaw()).toBe(before)
        expect(statSync(registryFile).mtimeMs).toBe(beforeMtime)
    })

    it('a dead entry: file changed and entry gone', async () => {
        const deadPort = await freePort()
        const { server, port } = await listenServer()
        servers.push(server)
        expect(upsertEntry(makeEntry('dead', { port: deadPort }))).toBe('written')
        expect(upsertEntry(makeEntry('live', { port }))).toBe('written')
        const before = readRaw()

        expect(await pruneStaleEntries()).toBe('written')

        expect(readRaw()).not.toBe(before)
        expect(readSessionIds()).toEqual(['live'])
    })
})

describe('prune: TCP probe is authoritative (reused-pid case)', () => {
    it('alive pid but dead port: entry is pruned (kill(0) never vetoes)', async () => {
        const deadPort = await freePort()
        // process.pid is alive on this machine; nothing listens on deadPort.
        expect(upsertEntry(makeEntry('reused', { pid: process.pid, port: deadPort }))).toBe(
            'written'
        )

        expect(await pruneStaleEntries()).toBe('written')
        expect(readSessionIds()).toEqual([])
    })

    it('alive pid and live loopback port: entry is NOT pruned', async () => {
        const { server, port } = await listenServer()
        servers.push(server)
        expect(upsertEntry(makeEntry('live', { pid: process.pid, port }))).toBe('written')

        expect(await pruneStaleEntries()).toBe('unchanged')
        expect(readSessionIds()).toEqual(['live'])
    })
})

describe('prune: anchor self-exclusion', () => {
    it('own entry on a non-loopback port is kept, dead sibling is pruned', async () => {
        // The anchor binds its port to the tailnet interface IP, not
        // loopback, so a loopback probe of the anchor's own port refuses
        // (ECONNREFUSED) while the listener is perfectly healthy. The
        // anchor must self-exclude its own entry instead of probing it.
        // (Regression: the anchor used to prune itself out of the list.)
        const highPort = 30000 + Math.floor(Math.random() * 30000) // nothing listens here
        const deadPort = await freePort()
        expect(
            upsertEntry(
                makeEntry('anchor', { port: highPort, isAnchor: true, host: '100.84.61.59' })
            )
        ).toBe('written')
        expect(upsertEntry(makeEntry('dead', { port: deadPort }))).toBe('written')

        expect(await pruneStaleEntries('anchor')).toBe('written')
        expect(readSessionIds()).toEqual(['anchor'])
    })
})

describe('corrupt-file recovery', () => {
    it('invalid JSON: status write and prune abort, file bytes intact, logged', async () => {
        const corrupt = '{"sessions": [ this is not valid JSON'
        writeFileSync(registryFile, corrupt, 'utf8')

        expect(upsertEntry(makeEntry('A'))).toBe('aborted_corrupt')
        expect(readRaw()).toBe(corrupt) // original corrupt bytes intact
        expect(await pruneStaleEntries()).toBe('aborted_corrupt')
        expect(readRaw()).toBe(corrupt) // never merged into an empty read

        const log = readFileSync(debugFile, 'utf8')
        expect(log).toContain('registry write aborted: file present but unparseable')
        expect(log).toContain('registry prune aborted: file present but unparseable')
    })

    it('valid JSON but wrong shape: also treated as corrupt, write aborted', () => {
        const malformed = '"just a string"'
        writeFileSync(registryFile, malformed, 'utf8')

        expect(upsertEntry(makeEntry('A'))).toBe('aborted_corrupt')
        expect(readRaw()).toBe(malformed)
    })
})

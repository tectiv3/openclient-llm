import { describe, expect, it } from 'vitest'
import {
    buildSubagentSnapshot,
    mapBusEvent,
    resolveAttachCandidate,
    scanLiveSubagents,
    SUBAGENT_EVENT_WHITELIST,
    classifySettle,
    type ScanOptions,
    type ScannedSubagent,
    type SubagentMeta,
} from '../subagents'
import { type BufferBlock } from '../turnBuffer'

// Spec (docs/plans/2026-09-13-rc-subagent-attach-stop-ux.md, Feature B) test
// matrix: dir-scan scoping/liveness/terminal filters; id resolution
// (exact/unique-prefix/ambiguity/toolCallId exact-only/precedence); bus event
// mapping; settle classification (meta-keyed, deadline vs pid-alive);
// snapshot pruning reuse. All I/O via injected fakes — no pi process, no fs.

type FileMap = Record<string, string>

function scanOpts(
    files: FileMap,
    sessionId = 'session-1',
    alivePids: Set<number> = new Set<number>()
): ScanOptions {
    return {
        dir: '/fake/subagents',
        sessionId,
        listFiles: dir => {
            expect(dir).toBe('/fake/subagents')
            return Object.keys(files)
        },
        readFile: path => {
            const name = path.slice(path.lastIndexOf('/') + 1)
            const content = files[name]
            if (content === undefined) throw new Error(`ENOENT: ${path}`)
            return content
        },
        isAlive: pid => alivePids.has(pid),
    }
}

function metaFile(overrides: Partial<SubagentMeta> = {}): SubagentMeta {
    return {
        agent: 'researcher',
        task: 'research the topic',
        startedAt: '2026-09-13T10:00:00.000Z',
        parentSessionId: 'session-1',
        ...overrides,
    }
}

function files(
    metas: Record<string, SubagentMeta | string>,
    pids: Record<string, number> = {}
): FileMap {
    const out: FileMap = {}
    for (const [id, value] of Object.entries(metas)) {
        out[`${id}.meta`] = typeof value === 'string' ? value : JSON.stringify(value)
    }
    for (const [id, pid] of Object.entries(pids)) {
        out[`${id}.pid`] = String(pid)
    }
    return out
}

describe('scanLiveSubagents', () => {
    it('keeps a live run of the session', () => {
        const opts = scanOpts(
            files({ a: metaFile({ toolCallId: 'tc1' }) }, { a: 4242 }),
            'session-1',
            new Set([4242])
        )
        const runs = scanLiveSubagents(opts)
        expect(runs).toHaveLength(1)
        expect(runs[0].id).toBe('a')
        expect(runs[0].meta.toolCallId).toBe('tc1')
    })

    it('hides runs of other sessions', () => {
        const opts = scanOpts(
            files(
                {
                    other: metaFile({ parentSessionId: 'session-2' }),
                },
                { other: 1 }
            ),
            'session-1',
            new Set([1])
        )
        expect(scanLiveSubagents(opts)).toEqual([])
    })

    it('hides runs without a parentSessionId', () => {
        const opts = scanOpts(
            files({ a: metaFile({ parentSessionId: undefined }) }, { a: 1 }),
            'session-1',
            new Set([1])
        )
        expect(scanLiveSubagents(opts)).toEqual([])
    })

    it('hides runs whose pid is dead or whose pidfile is missing/unparseable', () => {
        expect(
            scanLiveSubagents(
                scanOpts(files({ a: metaFile() }, { a: 1 }), 'session-1', new Set<number>())
            )
        ).toEqual([]) // pid not alive
        expect(scanLiveSubagents(scanOpts(files({ a: metaFile() })))).toEqual([]) // no pidfile
        const bad = files({ a: metaFile() }, {})
        bad['a.pid'] = 'not-a-number'
        expect(scanLiveSubagents(scanOpts(bad))).toEqual([])
    })

    it('hides terminal-status metas (all three)', () => {
        for (const status of ['succeeded', 'failed', 'aborted'] as const) {
            const opts = scanOpts(
                files({ a: metaFile({ status }) }, { a: 1 }),
                'session-1',
                new Set([1])
            )
            expect(scanLiveSubagents(opts), status).toEqual([])
        }
    })

    it('skips torn or non-object meta JSON without throwing', () => {
        const opts = scanOpts(
            files(
                {
                    torn: '{"agent": "researcher", "task":',
                    notObject: '[1, 2, 3]',
                    noAgent: JSON.stringify({
                        task: 'x',
                        startedAt: '2026-09-13T10:00:00.000Z',
                    }),
                },
                { torn: 1, notObject: 2, noAgent: 3 }
            ),
            'session-1',
            new Set([1, 2, 3])
        )
        expect(scanLiveSubagents(opts)).toEqual([])
    })

    it('ignores non-meta files', () => {
        const out = files({ a: metaFile() }, { a: 1 })
        out['a.jsonl'] = '{"type":"message"}'
        expect(scanLiveSubagents(scanOpts(out, 'session-1', new Set([1])))).toHaveLength(1)
    })

    it('returns [] when listFiles throws', () => {
        const opts: ScanOptions = {
            dir: '/fake/subagents',
            sessionId: 'session-1',
            listFiles: () => {
                throw new Error('ENOENT')
            },
            readFile: () => '',
            isAlive: () => true,
        }
        expect(scanLiveSubagents(opts)).toEqual([])
    })

    it('sorts newest first by startedAt', () => {
        const opts = scanOpts(
            files(
                {
                    old: metaFile({ startedAt: '2026-09-13T09:00:00.000Z' }),
                    new: metaFile({ startedAt: '2026-09-13T11:00:00.000Z' }),
                    mid: metaFile({ startedAt: '2026-09-13T10:00:00.000Z' }),
                },
                { old: 1, new: 2, mid: 3 }
            ),
            'session-1',
            new Set([1, 2, 3])
        )
        expect(scanLiveSubagents(opts).map(r => r.id)).toEqual(['new', 'mid', 'old'])
    })
})

describe('resolveAttachCandidate', () => {
    const runA: ScannedSubagent = {
        id: 'aaaaaaaa-1111',
        meta: metaFile({ toolCallId: 'tc-a' }),
    }
    const runB: ScannedSubagent = {
        id: 'bbbbbbbb-2222',
        meta: metaFile({ toolCallId: 'tc-b' }),
    }

    it('resolves an exact id', () => {
        expect(resolveAttachCandidate([runA], runA.id).ok).toBe(true)
    })

    it('resolves a unique prefix', () => {
        const result = resolveAttachCandidate([runA, runB], 'bbbb')
        expect(result).toEqual({ ok: true, run: runB })
    })

    it('reports ambiguity with candidate lines', () => {
        const both: ScannedSubagent[] = [
            { id: 'shared-aaa-1', meta: metaFile() },
            { id: 'shared-bbb-2', meta: metaFile() },
        ]
        const result = resolveAttachCandidate(both, 'shared')
        expect(result.ok).toBe(false)
        if (result.ok === false) {
            expect(result.code).toBe('ambiguous')
            expect(result.message).toContain('Ambiguous subagent id "shared"')
            expect(result.message).toContain('shared-a')
            expect(result.message).toContain('shared-b')
            expect(result.message).toContain('Use more characters or the full id.')
        }
    })

    it('reports not_found and lists live runs when one exists', () => {
        const result = resolveAttachCandidate([runA], 'nope')
        expect(result.ok).toBe(false)
        if (result.ok === false) {
            expect(result.code).toBe('not_found')
            expect(result.message).toContain('No live subagent matches "nope"')
            expect(result.message).toContain('aaaaaaaa')
        }
    })

    it('reports not_found differently when no runs are live', () => {
        const result = resolveAttachCandidate([], 'nope')
        expect(result.ok).toBe(false)
        if (result.ok === false) {
            expect(result.code).toBe('not_found')
            expect(result.message).toContain('No live subagent runs in this session')
        }
    })

    it('resolves a toolCallId by exact match only', () => {
        expect(resolveAttachCandidate([runA, runB], undefined, 'tc-b')).toEqual({
            ok: true,
            run: runB,
        })
        // A toolCallId that is a prefix of another must NOT match.
        const result = resolveAttachCandidate(
            [{ id: 'cccccccc-3333', meta: metaFile({ toolCallId: 'tc-b-long' }) }],
            undefined,
            'tc-b'
        )
        expect(result.ok).toBe(false)
        if (result.ok === false) expect(result.code).toBe('not_found')
    })

    it('subagentId wins when both are provided, and its failure does not fall back', () => {
        // Both point at runs → the subagentId run wins.
        expect(resolveAttachCandidate([runA, runB], 'aaaaaaaa-1111', 'tc-b')).toEqual({
            ok: true,
            run: runA,
        })
        // subagentId unknown → not_found even though the toolCallId would match.
        const result = resolveAttachCandidate([runA], 'nope', 'tc-a')
        expect(result.ok).toBe(false)
        if (result.ok === false) expect(result.code).toBe('not_found')
    })

    it('treats empty strings as not provided', () => {
        expect(resolveAttachCandidate([runA], '', undefined).ok).toBe(false)
        expect(resolveAttachCandidate([runA]).ok).toBe(false)
    })
})

describe('mapBusEvent', () => {
    it('maps name from event.type and strips type from the payload', () => {
        const result = mapBusEvent({
            subagentId: 'r1',
            agent: 'researcher',
            event: { type: 'message_start', message: { role: 'user' } },
        })
        expect(result).toEqual({
            name: 'message_start',
            payload: { message: { role: 'user' } },
        })
    })

    it('returns null for malformed payloads', () => {
        expect(mapBusEvent(null)).toBeNull()
        expect(mapBusEvent('x')).toBeNull()
        expect(mapBusEvent({ subagentId: 'r1', event: null })).toBeNull()
        expect(mapBusEvent({ subagentId: 'r1', event: { message: {} } })).toBeNull()
        expect(mapBusEvent({ subagentId: 'r1', event: { type: '' } })).toBeNull()
        expect(mapBusEvent({ subagentId: 'r1', event: { type: 42 } })).toBeNull()
    })
})

describe('SUBAGENT_EVENT_WHITELIST', () => {
    it('is exactly the spec whitelist', () => {
        expect([...SUBAGENT_EVENT_WHITELIST].sort()).toEqual(
            [
                'agent_settled',
                'agent_start',
                'message_start',
                'message_update',
                'tool_execution_end',
                'tool_execution_start',
                'tool_execution_update',
                'turn_end',
            ].sort()
        )
    })
})

describe('classifySettle', () => {
    const base = {
        metaPresent: true,
        pidAlive: false,
        deadlineExceeded: false,
    }

    it('meta gone → succeeded (only success deletes it)', () => {
        expect(classifySettle({ ...base, metaPresent: false })).toEqual({
            status: 'succeeded',
            extend: false,
        })
    })

    it('meta status wins when present', () => {
        expect(
            classifySettle({ ...base, metaStatus: 'aborted', metaStopReason: 'user' })
        ).toEqual({ status: 'aborted', stopReason: 'user', extend: false })
        expect(classifySettle({ ...base, metaStatus: 'failed' })).toEqual({
            status: 'failed',
            extend: false,
        })
    })

    it('pid alive without status → failed + extend (slow clean shutdown)', () => {
        expect(classifySettle({ ...base, pidAlive: true })).toEqual({
            status: 'failed',
            extend: true,
        })
    })

    it('pid dead without status → failed, no extend (abnormal death)', () => {
        expect(classifySettle({ ...base })).toEqual({ status: 'failed', extend: false })
    })

    it('deadline exhausted ends the loop even with the pid alive', () => {
        expect(classifySettle({ ...base, pidAlive: true, deadlineExceeded: true })).toEqual({
            status: 'failed',
            extend: false,
        })
        expect(classifySettle({ ...base, deadlineExceeded: true })).toEqual({
            status: 'failed',
            extend: false,
        })
    })

    it('stopReason falls back meta → last observed → omitted', () => {
        expect(
            classifySettle({
                ...base,
                metaStatus: 'failed',
                metaStopReason: 'from-meta',
                lastObservedStopReason: 'from-bus',
            })
        ).toEqual({ status: 'failed', stopReason: 'from-meta', extend: false })
        expect(
            classifySettle({
                ...base,
                metaPresent: false,
                lastObservedStopReason: 'stop',
            })
        ).toEqual({ status: 'succeeded', stopReason: 'stop', extend: false })
    })
})

// Buffer/history fixtures — same shapes as turnBuffer.test.ts.
const text = (value: string): BufferBlock => ({ type: 'text', text: value })
const thinking = (value: string): BufferBlock => ({ type: 'thinking', text: value })
const carrier = (toolCallId: string, toolName = 'bash', output?: string): BufferBlock => ({
    type: 'toolUse',
    toolCallId,
    toolName,
    args: {},
    ...(output !== undefined ? { output } : {}),
})
const assistantEntry = (toolCalls: { id: string; name: string }[]): unknown => ({
    type: 'message',
    message: {
        role: 'assistant',
        content: [
            { type: 'thinking', thinking: 'plan' },
            { type: 'text', text: 'let me look' },
            ...toolCalls.map(call => ({
                type: 'toolCall',
                id: call.id,
                name: call.name,
                arguments: {},
            })),
        ],
    },
})
const toolResultEntry = (toolCallId: string): unknown => ({
    type: 'message',
    message: {
        role: 'toolResult',
        toolCallId,
        toolName: 'bash',
        content: 'done',
        isError: false,
    },
})
const userEntry = (): unknown => ({
    type: 'message',
    message: { role: 'user', content: [{ type: 'text', text: 'hi' }] },
})

describe('buildSubagentSnapshot', () => {
    it('prunes a committed assistant tail (text/thinking dropped, carriers kept)', () => {
        const history = [userEntry(), assistantEntry([{ id: 't1', name: 'read' }])]
        const buffer = [text('let me look'), thinking('plan'), carrier('t1', 'read')]
        const result = buildSubagentSnapshot({ history, buffer, lastJsonlMessage: history[1] })
        expect(result.history).toEqual(history)
        expect(result.buffer).toEqual([carrier('t1', 'read')])
    })

    it('prunes a committed toolResult tail (completed carrier dropped, live kept)', () => {
        const tail = toolResultEntry('t1')
        const buffer = [text('done'), carrier('t1', 'bash', 'out'), carrier('t2', 'read')]
        const result = buildSubagentSnapshot({
            history: [tail],
            buffer,
            lastJsonlMessage: tail,
        })
        expect(result.buffer).toEqual([carrier('t2', 'read')])
    })

    it('keeps the full buffer on an uncommitted (user) tail', () => {
        const buffer = [text('partial'), carrier('t1', 'bash')]
        const result = buildSubagentSnapshot({
            history: [userEntry()],
            buffer,
            lastJsonlMessage: userEntry(),
        })
        expect(result.buffer).toEqual(buffer)
    })

    it('keeps the full buffer when the last entry is not a message', () => {
        const buffer = [text('partial')]
        const result = buildSubagentSnapshot({
            history: [],
            buffer,
            lastJsonlMessage: { type: 'session', id: 's1' },
        })
        expect(result.buffer).toEqual(buffer)
    })

    it('missing jsonl → empty history, full unpruned buffer', () => {
        const buffer = [text('partial'), carrier('t1', 'bash')]
        expect(buildSubagentSnapshot({ history: [], buffer })).toEqual({
            history: [],
            buffer: [text('partial'), carrier('t1', 'bash')],
        })
    })

    it('empty buffer stays empty', () => {
        const result = buildSubagentSnapshot({
            history: [],
            buffer: [],
            lastJsonlMessage: assistantEntry([{ id: 't1', name: 'read' }]),
        })
        expect(result).toEqual({ history: [], buffer: [] })
    })

    it('returns new arrays (no aliasing of the inputs)', () => {
        const history = [userEntry()]
        const buffer = [text('x')]
        const result = buildSubagentSnapshot({
            history,
            buffer,
            lastJsonlMessage: userEntry(),
        })
        expect(result.history).not.toBe(history)
        expect(result.buffer).not.toBe(buffer)
    })
})

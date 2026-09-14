import { describe, expect, it } from 'vitest'
import {
    pruneBufferForSnapshot,
    tailClassification,
    type BufferBlock,
    type TailClassification,
} from '../turnBuffer'

// Spec (docs/plans/2026-09-13-rc-subagent-attach-stop-ux.md, Feature A) test
// matrix: assistant-tail drop/keep; arg-junk placeholder dropped in every
// committed-tail case; empty buffer; toolResult tail (completed carrier
// dropped, different live carrier kept, mixed buffer); uncommitted tail
// kept as-is. In-memory fixtures only — no pi process, no LLM.

const assistantTail = (ids: string[]): TailClassification => ({
    kind: 'assistant',
    toolCallIds: ids,
})
const toolResultTail = (id: string): TailClassification => ({
    kind: 'toolResult',
    toolCallId: id,
})
const uncommittedTail: TailClassification = { kind: 'uncommitted' }

const text = (value: string): BufferBlock => ({ type: 'text', text: value })
const thinking = (value: string): BufferBlock => ({ type: 'thinking', text: value })
const carrier = (toolCallId: string, toolName = 'bash', output?: string): BufferBlock => ({
    type: 'toolUse',
    toolCallId,
    toolName,
    args: {},
    ...(output !== undefined ? { output } : {}),
})
// The arg-junk placeholder: toolcall_delta chunks land in `output` with an
// empty toolCallId and the literal name 'tool' until tool_execution_start
// replaces the slot in place.
const argJunk = (): BufferBlock => ({
    type: 'toolUse',
    toolCallId: '',
    toolName: 'tool',
    args: {},
    output: '{",path"',
})

// Real branch-entry shapes (spec: "Verified real entry shapes").
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

describe('tailClassification', () => {
    it('classifies a committed assistant message by its tool-call part ids', () => {
        expect(tailClassification(assistantEntry([{ id: 'a1', name: 'bash' }]))).toEqual({
            kind: 'assistant',
            toolCallIds: ['a1'],
        })
        expect(
            tailClassification(
                assistantEntry([
                    { id: 'a1', name: 'bash' },
                    { id: 'a2', name: 'read' },
                ])
            )
        ).toEqual({ kind: 'assistant', toolCallIds: ['a1', 'a2'] })
    })

    it('classifies a toolResult entry and captures its toolCallId', () => {
        expect(tailClassification(toolResultEntry('t1'))).toEqual({
            kind: 'toolResult',
            toolCallId: 't1',
        })
    })

    it('classifies user/compaction/nothing as uncommitted', () => {
        expect(
            tailClassification({
                type: 'message',
                message: { role: 'user', content: 'hi' },
            })
        ).toEqual(uncommittedTail)
        expect(tailClassification({ type: 'compaction', summary: 'x' })).toEqual(
            uncommittedTail
        )
        expect(tailClassification(undefined)).toEqual(uncommittedTail)
    })
})

describe('pruneBufferForSnapshot, assistant tail', () => {
    const tail = assistantTail(['t1'])

    it('drops text/thinking (duplicated in the branch) and keeps the in-flight carrier', () => {
        expect(
            pruneBufferForSnapshot(
                [text('let me look'), thinking('plan'), carrier('t1', 'bash', 'partial')],
                tail
            )
        ).toEqual([carrier('t1', 'bash', 'partial')])
    })

    it('drops a carrier whose id is not in the committed tail', () => {
        expect(
            pruneBufferForSnapshot(
                [text('x'), carrier('t1'), carrier('t-other', 'bash')],
                tail
            )
        ).toEqual([carrier('t1')])
    })

    it('keeps all carriers of a multi-tool assistant tail', () => {
        expect(
            pruneBufferForSnapshot(
                [text('x'), carrier('a1', 'bash'), carrier('a2', 'read')],
                assistantTail(['a1', 'a2'])
            )
        ).toEqual([carrier('a1', 'bash'), carrier('a2', 'read')])
    })

    it('drops the arg-junk placeholder (toolCallId "", toolName "tool", output set)', () => {
        expect(pruneBufferForSnapshot([text('x'), argJunk(), carrier('t1')], tail)).toEqual([
            carrier('t1'),
        ])
    })
})

describe('pruneBufferForSnapshot, toolResult tail (between-tools window)', () => {
    it('drops text and the completed carrier of the tail toolCallId', () => {
        expect(
            pruneBufferForSnapshot(
                [text('A committed'), carrier('t1', 'bash', 'finished output')],
                toolResultTail('t1')
            )
        ).toEqual([])
    })

    it('keeps a DIFFERENT live carrier (parallel tool still in flight)', () => {
        expect(
            pruneBufferForSnapshot(
                [text('A committed'), carrier('t2', 'bash')],
                toolResultTail('t1')
            )
        ).toEqual([carrier('t2', 'bash')])
    })

    it('drops text + completed carrier, keeps the live carrier (mixed buffer)', () => {
        expect(
            pruneBufferForSnapshot(
                [
                    text('A committed'),
                    carrier('t1', 'bash', 'done'),
                    carrier('t2', 'bash', 'partial'),
                ],
                toolResultTail('t1')
            )
        ).toEqual([carrier('t2', 'bash', 'partial')])
    })

    it('drops the arg-junk placeholder too', () => {
        expect(
            pruneBufferForSnapshot(
                [text('x'), argJunk(), carrier('t2', 'bash')],
                toolResultTail('t1')
            )
        ).toEqual([carrier('t2', 'bash')])
    })
})

describe('pruneBufferForSnapshot, uncommitted tail', () => {
    it('keeps the buffer as-is (genuinely uncommitted content, incl. the placeholder)', () => {
        const buffer = [text('live'), thinking('hmm'), argJunk(), carrier('t9', 'bash')]
        expect(pruneBufferForSnapshot(buffer, uncommittedTail)).toEqual(buffer)
    })
})

describe('edge cases', () => {
    it('empty buffer stays empty in every case', () => {
        expect(pruneBufferForSnapshot([], assistantTail(['t1']))).toEqual([])
        expect(pruneBufferForSnapshot([], toolResultTail('t1'))).toEqual([])
        expect(pruneBufferForSnapshot([], uncommittedTail)).toEqual([])
    })

    it('assistant tail with no committed tool ids drops all carriers (incl. junk)', () => {
        expect(
            pruneBufferForSnapshot(
                [text('x'), argJunk(), carrier('t1', 'bash')],
                assistantTail([])
            )
        ).toEqual([])
    })
})

import { describe, expect, it } from 'vitest'
import {
    TOOL_OUTPUT_PREVIEW_BYTES,
    capPreviewBytes,
    flattenToString,
    trimForwardedPayload,
} from '../wirePayloads'

// Spec (docs/plans/2026-10-25-rc-wire-streaming-fix.md, decisions D2–D8) test
// matrix: subagent-sized tool results dropped, cumulative partials stripped,
// user vs assistant vs toolResult message_start, tool output capping, turn_end
// stopReason/content survival, unknown names untouched. In-memory fixtures
// only — no pi process, no LLM.

const HUGE = 'x'.repeat(2 * 1024 * 1024)
const SUBAGENT_SIZED_DETAILS = { results: 'y'.repeat(20 * 1024 * 1024) }

const hugeAssistantMessage = () => ({
    role: 'assistant',
    content: [{ type: 'text', text: HUGE }],
    api: 'openai',
    provider: 'test',
    model: 'test-model',
    usage: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 3, cost: {} },
    stopReason: 'stop',
    timestamp: 1,
})

const assistantEvent = (event: Record<string, unknown>) => ({
    ...event,
    partial: hugeAssistantMessage(),
})

describe('message_update (D2)', () => {
    it('forwards only the stripped assistantMessageEvent for every variant', () => {
        const variants: [Record<string, unknown>, Record<string, unknown>][] = [
            [{ type: 'start' }, { type: 'start' }],
            [
                { type: 'text_start', contentIndex: 0 },
                { type: 'text_start', contentIndex: 0 },
            ],
            [
                { type: 'text_delta', contentIndex: 0, delta: 'hi' },
                { type: 'text_delta', contentIndex: 0, delta: 'hi' },
            ],
            [
                { type: 'text_end', contentIndex: 0, content: 'hi there' },
                { type: 'text_end', contentIndex: 0, content: 'hi there' },
            ],
            [
                { type: 'thinking_start', contentIndex: 1 },
                { type: 'thinking_start', contentIndex: 1 },
            ],
            [
                { type: 'thinking_delta', contentIndex: 1, delta: 'plan' },
                { type: 'thinking_delta', contentIndex: 1, delta: 'plan' },
            ],
            [
                { type: 'thinking_end', contentIndex: 1, content: 'plan' },
                { type: 'thinking_end', contentIndex: 1, content: 'plan' },
            ],
            [
                { type: 'toolcall_start', contentIndex: 2 },
                { type: 'toolcall_start', contentIndex: 2 },
            ],
            [
                { type: 'toolcall_delta', contentIndex: 2, delta: '{"path"' },
                { type: 'toolcall_delta', contentIndex: 2, delta: '{"path"' },
            ],
            // toolCall (args) is dropped — the client never reads it.
            [
                {
                    type: 'toolcall_end',
                    contentIndex: 2,
                    toolCall: { id: 'tc1', name: 'read' },
                },
                { type: 'toolcall_end', contentIndex: 2 },
            ],
            [
                { type: 'done', reason: 'stop', message: hugeAssistantMessage() },
                { type: 'done', reason: 'stop' },
            ],
            [
                { type: 'error', reason: 'error', error: hugeAssistantMessage() },
                { type: 'error', reason: 'error' },
            ],
        ]
        for (const [raw, expected] of variants) {
            expect(
                trimForwardedPayload('message_update', {
                    assistantMessageEvent: assistantEvent(raw),
                })
            ).toEqual({ assistantMessageEvent: expected })
        }
    })

    it('produces a small frame from a huge cumulative partial', () => {
        const raw = {
            message: hugeAssistantMessage(),
            assistantMessageEvent: assistantEvent({
                type: 'text_delta',
                contentIndex: 0,
                delta: 'hi',
            }),
        }
        const frame = trimForwardedPayload('message_update', raw)
        expect(frame).toEqual({
            assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'hi' },
        })
        expect(JSON.stringify(frame).length).toBeLessThan(1024)
    })

    it('emits an empty body for a malformed event instead of leaking it', () => {
        expect(
            trimForwardedPayload('message_update', { message: hugeAssistantMessage() })
        ).toEqual({ assistantMessageEvent: {} })
    })
})

describe('message_start (D4)', () => {
    const timestamp = 1

    it('keeps user content (text only) so the client can match its echo', () => {
        expect(
            trimForwardedPayload('message_start', {
                message: { role: 'user', content: 'hello', timestamp },
            })
        ).toEqual({ message: { role: 'user', content: 'hello' } })
        expect(
            trimForwardedPayload('message_start', {
                message: {
                    role: 'user',
                    content: [
                        { type: 'text', text: 'look at this' },
                        { type: 'image', data: HUGE, mimeType: 'image/png' },
                    ],
                    timestamp,
                },
            })
        ).toEqual({
            message: { role: 'user', content: [{ type: 'text', text: 'look at this' }] },
        })
    })

    it('drops content for assistant starts', () => {
        expect(
            trimForwardedPayload('message_start', { message: hugeAssistantMessage() })
        ).toEqual({ message: { role: 'assistant' } })
    })

    it('drops content and details for toolResult starts', () => {
        expect(
            trimForwardedPayload('message_start', {
                message: {
                    role: 'toolResult',
                    toolCallId: 'tc1',
                    toolName: 'subagent',
                    content: [{ type: 'text', text: HUGE }],
                    details: SUBAGENT_SIZED_DETAILS,
                    isError: false,
                    timestamp,
                },
            })
        ).toEqual({ message: { role: 'toolResult' } })
    })
})

describe('tool_execution_end (D6)', () => {
    it('drops args and the subagent-sized result, keeps identity + error flag', () => {
        const frame = trimForwardedPayload('tool_execution_end', {
            toolCallId: 'tc1',
            toolName: 'subagent',
            args: { agent: 'explore', prompt: HUGE },
            result: {
                content: [{ type: 'text', text: HUGE }],
                details: SUBAGENT_SIZED_DETAILS,
            },
            isError: false,
        })
        expect(frame).toEqual({ toolCallId: 'tc1', toolName: 'subagent', isError: false })
        expect(JSON.stringify(frame).length).toBeLessThan(256)
    })
})

describe('tool_execution_update (D5)', () => {
    it('flattens partialResult and caps it to the preview size', () => {
        const frame = trimForwardedPayload('tool_execution_update', {
            toolCallId: 'tc1',
            toolName: 'bash',
            args: { command: 'ls' },
            partialResult: HUGE,
        })
        expect(frame.toolCallId).toBe('tc1')
        expect(frame.toolName).toBe('bash')
        expect(frame.args).toEqual({ command: 'ls' })
        expect(typeof frame.partialResult).toBe('string')
        expect((frame.partialResult as string).length).toBe(TOOL_OUTPUT_PREVIEW_BYTES)
        expect(frame.partialResult as string).toBe('x'.repeat(TOOL_OUTPUT_PREVIEW_BYTES))
    })

    it('caps by UTF-8 bytes, never splitting a code point', () => {
        const frame = trimForwardedPayload('tool_execution_update', {
            toolCallId: 'tc1',
            toolName: 'bash',
            partialResult: '€'.repeat(30_000), // 90 000 bytes
        })
        const capped = frame.partialResult as string
        expect(capped.length).toBe(Math.floor(TOOL_OUTPUT_PREVIEW_BYTES / 3))
        expect(capped).toBe('€'.repeat(21_845))
    })

    it('flattens object partial results like the server buffer does', () => {
        expect(
            trimForwardedPayload('tool_execution_update', {
                toolCallId: 'tc1',
                toolName: 'bash',
                partialResult: { content: 'line1\nline2' },
            }).partialResult
        ).toBe('line1\nline2')
    })

    it('flattens pi content-part partials and never inlines image base64', () => {
        const frame = trimForwardedPayload('tool_execution_update', {
            toolCallId: 'tc1',
            toolName: 'bash',
            partialResult: {
                content: [{ type: 'text', text: 'abc' }],
                details: undefined,
            },
        })
        expect(frame.partialResult).toBe('abc')

        const imageBase64 = 'A'.repeat(4 * 1024 * 1024)
        const imageOnly = trimForwardedPayload('tool_execution_update', {
            toolCallId: 'tc2',
            toolName: 'read',
            partialResult: {
                content: [{ type: 'image', data: imageBase64, mimeType: 'image/png' }],
                details: undefined,
            },
        })
        expect(imageOnly).toEqual({ toolCallId: 'tc2', toolName: 'read' })
        expect('partialResult' in imageOnly).toBe(false)
        expect(JSON.stringify(imageOnly)).not.toContain(imageBase64)
    })

    it('omits partialResult when the update has none and never forwards result', () => {
        expect(
            trimForwardedPayload('tool_execution_update', {
                toolCallId: 'tc1',
                toolName: 'bash',
                args: {},
                result: { details: SUBAGENT_SIZED_DETAILS },
            })
        ).toEqual({ toolCallId: 'tc1', toolName: 'bash', args: {} })
    })
})

describe('turn_end (D3)', () => {
    it('keeps stopReason and text/thinking content, drops toolResults and context', () => {
        const frame = trimForwardedPayload('turn_end', {
            turnIndex: 3,
            message: {
                role: 'assistant',
                content: [
                    { type: 'thinking', thinking: 'plan', thinkingSignature: 'sig' },
                    { type: 'text', text: 'final answer', textSignature: 'sig2' },
                    { type: 'toolCall', id: 'tc1', name: 'subagent', arguments: {} },
                ],
                stopReason: 'stop',
                usage: {},
                model: 'test-model',
                timestamp: 1,
            },
            toolResults: [
                {
                    role: 'toolResult',
                    toolCallId: 'tc1',
                    toolName: 'subagent',
                    content: [{ type: 'text', text: HUGE }],
                    details: SUBAGENT_SIZED_DETAILS,
                    isError: false,
                },
            ],
            context: { llmMessages: [{ role: 'user', content: HUGE }] },
            entries: [],
            messageEntryId: 'e1',
            toolResultEntryIds: ['e2'],
        })
        expect(frame).toEqual({
            turnIndex: 3,
            message: {
                role: 'assistant',
                stopReason: 'stop',
                content: [
                    { type: 'thinking', text: 'plan' },
                    { type: 'text', text: 'final answer' },
                ],
            },
        })
        // The node harness reads exactly this path.
        expect((frame.message as Record<string, unknown>).stopReason).toBe('stop')
        expect(JSON.stringify(frame).length).toBeLessThan(1024)
    })

    it('omits a non-string stopReason but still forwards content', () => {
        expect(
            trimForwardedPayload('turn_end', {
                turnIndex: 0,
                message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] },
            })
        ).toEqual({
            turnIndex: 0,
            message: { role: 'assistant', content: [{ type: 'text', text: 'ok' }] },
        })
    })
})

describe('capPreviewBytes', () => {
    it('returns short strings untouched and truncates long ASCII prefixes', () => {
        expect(capPreviewBytes('short')).toBe('short')
        const capped = capPreviewBytes('a'.repeat(TOOL_OUTPUT_PREVIEW_BYTES + 10))
        expect(capped.length).toBe(TOOL_OUTPUT_PREVIEW_BYTES)
    })
})

describe('flattenToString', () => {
    it('matches the server buffer flattening rules', () => {
        expect(flattenToString('x')).toBe('x')
        expect(flattenToString(['a', { text: 'b' }])).toBe('ab')
        expect(flattenToString({ content: 'c' })).toBe('c')
        expect(flattenToString({ output: 'd' })).toBe('d')
        expect(flattenToString({ other: 1 })).toBe('{"other":1}')
        expect(flattenToString(undefined)).toBeUndefined()
    })

    it('concatenates the text parts of a pi content array', () => {
        expect(
            flattenToString({
                content: [
                    { type: 'text', text: 'hello ' },
                    { type: 'text', text: 'world' },
                ],
            })
        ).toBe('hello world')
        expect(flattenToString({ content: ['a', { text: 'b' }, { content: 'c' }] })).toBe(
            'abc'
        )
    })

    it('skips image parts instead of JSON-stringifying their base64', () => {
        const imageBase64 = 'A'.repeat(4 * 1024 * 1024)
        const flattened = flattenToString({
            content: [
                { type: 'image', data: imageBase64, mimeType: 'image/png' },
                { type: 'text', text: 'caption' },
            ],
        })
        expect(flattened).toBe('caption')
        expect(flattened).not.toContain(imageBase64)
        expect(flattenToString({ content: [{ type: 'image', data: imageBase64 }] })).toBe('')
    })
})

describe('unknown event names', () => {
    it('passes the payload through unchanged by identity', () => {
        const payload = { reason: 'startup', something: HUGE }
        expect(trimForwardedPayload('session_start', payload)).toBe(payload)
        expect(trimForwardedPayload('agent_start', { turnIndex: 0 })).toEqual({ turnIndex: 0 })
        expect(trimForwardedPayload('tool_execution_start', { args: { a: 1 } })).toEqual({
            args: { a: 1 },
        })
    })
})

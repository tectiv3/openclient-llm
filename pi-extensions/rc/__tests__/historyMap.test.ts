import { describe, expect, it } from 'vitest'
import { mapHistoryEntry } from '../historyMap'

// Branch-entry -> wire-item mapping, in-memory fixtures only — no pi process,
// no server. context_edit shapes mirror pi 0.87.0's session-manager.d.ts
// (`replacement: { content: ... } | null`); raw history keeps the original
// message entry alongside the edit.

describe('mapHistoryEntry, context_edit', () => {
    it('maps an omission edit (replacement null) to omitted true', () => {
        expect(
            mapHistoryEntry({ type: 'context_edit', targetId: 'm-1', replacement: null })
        ).toEqual([{ role: 'contextEdit', targetId: 'm-1', omitted: true }])
    })

    it('maps a replacement edit to omitted false, without the content', () => {
        const item = mapHistoryEntry({
            type: 'context_edit',
            targetId: 'm-2',
            replacement: { content: [{ type: 'text', text: 'rewritten' }] },
        })
        expect(item).toEqual([{ role: 'contextEdit', targetId: 'm-2', omitted: false }])
        expect(JSON.stringify(item)).not.toContain('rewritten')
    })

    it('degrades garbage entries to safe values (empty targetId, omitted true)', () => {
        expect(mapHistoryEntry(null)).toEqual([])
        expect(mapHistoryEntry('nope')).toEqual([])
        expect(mapHistoryEntry({ type: 'context_edit' })).toEqual([
            { role: 'contextEdit', targetId: '', omitted: true },
        ])
        expect(
            mapHistoryEntry({ type: 'context_edit', targetId: 42, replacement: 'junk' })
        ).toEqual([{ role: 'contextEdit', targetId: '', omitted: false }])
    })
})

describe('mapHistoryEntry, existing roles unaffected', () => {
    it('still maps user, assistant, toolResult and compaction entries', () => {
        expect(
            mapHistoryEntry({ type: 'message', message: { role: 'user', content: 'hi' } })
        ).toEqual([{ role: 'user', text: 'hi' }])
        expect(
            mapHistoryEntry({
                type: 'message',
                message: {
                    role: 'assistant',
                    content: [{ type: 'text', text: 'hello' }],
                },
            })
        ).toEqual([{ role: 'assistant', content: [{ type: 'text', text: 'hello' }] }])
        expect(
            mapHistoryEntry({
                type: 'message',
                message: {
                    role: 'toolResult',
                    toolCallId: 't1',
                    toolName: 'bash',
                    content: 'done',
                    isError: true,
                },
            })
        ).toEqual([
            {
                role: 'toolResult',
                toolName: 'bash',
                toolCallId: 't1',
                output: 'done',
                isError: true,
            },
        ])
        expect(mapHistoryEntry({ type: 'compaction', summary: 'condensed' })).toEqual([
            { role: 'compaction', summary: 'condensed' },
        ])
    })

    it('still drops non-message entry types it does not know', () => {
        expect(mapHistoryEntry({ type: 'label', label: 'x' })).toEqual([])
        expect(
            mapHistoryEntry({ type: 'message', message: { role: 'system', text: 'x' } })
        ).toEqual([])
    })
})

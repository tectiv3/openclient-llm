// Reconnect dedupe (spec: docs/plans/2026-09-13-rc-subagent-attach-stop-ux.md,
// Feature A "server prune"). Pure module — deliberately no imports from
// index.ts so it is unit-testable without the server (same pattern as
// apns.ts/registry.ts).

// Structural twin of index.ts's ContentBlock (index.ts keeps its own copy;
// the two must stay in sync so the prune call type-checks in both directions).
export type BufferBlock =
    | { type: 'text'; text: string; textSignature?: string }
    | { type: 'thinking'; text: string; thinkingSignature?: string }
    | {
          type: 'toolUse'
          toolCallId: string
          toolName: string
          args: Record<string, unknown>
          output?: string
      }

// ONE pi branch entry, classified for the snapshot prune. 'uncommitted' means
// the tail is not a committed assistant message (user/compaction/etc) — the
// buffer is then a genuinely uncommitted tail and stays as-is.
export type TailClassification =
    | { kind: 'assistant'; toolCallIds: string[] }
    | { kind: 'toolResult'; toolCallId: string }
    | { kind: 'uncommitted' }

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null
}

function stringFrom(value: unknown): string | undefined {
    return typeof value === 'string' && value.length > 0 ? value : undefined
}

// Minimal parse of ONE branch entry (not index.ts's contentBlocks — keeps the
// module boundary clean; the id extraction is ~10 lines).
export function tailClassification(lastBranchEntry: unknown): TailClassification {
    if (!isObject(lastBranchEntry) || lastBranchEntry.type !== 'message')
        return { kind: 'uncommitted' }
    const message = lastBranchEntry.message
    if (!isObject(message)) return { kind: 'uncommitted' }
    const role = stringFrom(message.role)
    if (role === 'assistant') {
        const ids: string[] = []
        const content = Array.isArray(message.content) ? message.content : []
        for (const part of content) {
            if (!isObject(part)) continue
            const partType = stringFrom(part.type)
            if (partType !== 'toolUse' && partType !== 'tool_use' && partType !== 'toolCall')
                continue
            const id = stringFrom(part.toolCallId) ?? stringFrom(part.id)
            if (id !== undefined) ids.push(id)
        }
        return { kind: 'assistant', toolCallIds: ids }
    }
    if (role === 'toolResult' || role === 'tool_result' || role === 'tool')
        return { kind: 'toolResult', toolCallId: stringFrom(message.toolCallId) ?? '' }
    return { kind: 'uncommitted' }
}

// Snapshot prune (spec "Fix — server prune"). Relies on the invariant that
// the buffer's content belongs to AT MOST ONE assistant message: its
// text/thinking deltas plus that message's tool-call carriers.
export function pruneBufferForSnapshot(
    buffer: readonly BufferBlock[],
    tail: TailClassification
): BufferBlock[] {
    if (tail.kind === 'uncommitted') return [...buffer]
    if (tail.kind === 'assistant') {
        const committed = new Set(tail.toolCallIds)
        return buffer.filter(
            block =>
                block.type === 'toolUse' &&
                block.toolCallId !== '' &&
                committed.has(block.toolCallId)
        )
    }
    return buffer.filter(
        block =>
            block.type === 'toolUse' &&
            block.toolCallId !== '' &&
            block.toolCallId !== tail.toolCallId
    )
}

// Phone-history replay mapping (pi branch entries -> wire items), extracted
// from index.ts so it is unit-testable without the server (same pattern as
// turnBuffer.ts/subagents.ts).

export type JsonObject = Record<string, unknown>

export type ContentBlock =
    | { type: 'text'; text: string; textSignature?: string }
    | { type: 'thinking'; text: string; thinkingSignature?: string }
    | {
          type: 'toolUse'
          toolCallId: string
          toolName: string
          args: JsonObject
          output?: string
      }

function isObject(value: unknown): value is JsonObject {
    return typeof value === 'object' && value !== null
}

function stringFrom(value: unknown): string | undefined {
    return typeof value === 'string' && value.length > 0 ? value : undefined
}

export function mapHistoryEntry(entry: unknown): JsonObject[] {
    if (!isObject(entry)) return []
    if (entry.type === 'compaction')
        return [{ role: 'compaction', summary: stringFrom(entry.summary) ?? '' }]
    if (entry.type === 'context_edit')
        return [
            {
                role: 'contextEdit',
                targetId: stringFrom(entry.targetId) ?? '',
                // replacement == null omits the target from model context; any
                // other value replaces its content (content stays off the wire).
                omitted: entry.replacement == null,
            },
        ]
    if (entry.type !== 'message') return []
    const message = entry.message
    if (!isObject(message)) return []
    const role = stringFrom(message.role) ?? stringFrom(message.type)
    if (role === 'user') return [{ role: 'user', text: textFromMessage(message) }]
    if (role === 'assistant') return [{ role: 'assistant', content: contentBlocks(message) }]
    if (role === 'toolResult' || role === 'tool_result' || role === 'tool') {
        return [
            {
                role: 'toolResult',
                toolName: stringFrom(message.toolName) ?? stringFrom(message.name) ?? 'tool',
                toolCallId: stringFrom(message.toolCallId) ?? stringFrom(message.id) ?? '',
                output: textFromMessage(message),
                ...(message.isError === true ? { isError: true } : {}),
            },
        ]
    }
    return []
}

function contentBlocks(message: JsonObject): ContentBlock[] {
    const content = Array.isArray(message.content)
        ? message.content
        : Array.isArray(message.parts)
          ? message.parts
          : []
    const blocks = content.flatMap(part => contentBlock(part))
    if (blocks.length > 0) return blocks
    const text = textFromMessage(message)
    return text.length > 0 ? [{ type: 'text', text }] : []
}

function contentBlock(part: unknown): ContentBlock[] {
    if (typeof part === 'string') return [{ type: 'text', text: part }]
    if (!isObject(part)) return []
    const type = stringFrom(part.type) ?? 'text'
    if (type === 'text') {
        return [
            {
                type: 'text',
                text: stringFrom(part.text) ?? stringFrom(part.content) ?? '',
                ...(stringFrom(part.textSignature)
                    ? { textSignature: stringFrom(part.textSignature) }
                    : {}),
            },
        ]
    }
    if (type === 'thinking') {
        return [
            {
                type: 'thinking',
                text:
                    stringFrom(part.thinking) ??
                    stringFrom(part.text) ??
                    stringFrom(part.content) ??
                    '',
                ...(stringFrom(part.thinkingSignature)
                    ? { thinkingSignature: stringFrom(part.thinkingSignature) }
                    : {}),
            },
        ]
    }
    if (type === 'toolUse' || type === 'tool_use' || type === 'toolCall') {
        return [
            {
                type: 'toolUse',
                toolCallId: stringFrom(part.toolCallId) ?? stringFrom(part.id) ?? '',
                toolName: stringFrom(part.toolName) ?? stringFrom(part.name) ?? 'tool',
                args: isObject(part.arguments)
                    ? part.arguments
                    : isObject(part.args)
                      ? part.args
                      : isObject(part.input)
                        ? part.input
                        : {},
            },
        ]
    }
    return []
}

export function textFromMessage(message: JsonObject): string {
    if (typeof message.text === 'string') return message.text
    if (typeof message.content === 'string') return message.content
    if (Array.isArray(message.content)) {
        return message.content
            .map(part => {
                if (typeof part === 'string') return part
                if (isObject(part))
                    return stringFrom(part.text) ?? stringFrom(part.content) ?? ''
                return ''
            })
            .join('')
    }
    return ''
}

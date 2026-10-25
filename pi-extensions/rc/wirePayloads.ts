// Wire payload trimming (spec: docs/plans/2026-10-25-rc-wire-streaming-fix.md,
// decisions D2–D8). Pure module — deliberately no imports so it is
// unit-testable without pi or the server (same pattern as turnBuffer.ts).
//
// The phone's WebSocket task used to die on frames above 1 MiB, and pi's raw
// payloads routinely exceed that (subagent `details.results` alone is 17–51 MB
// per call). Everything forwarded to a client goes through
// trimForwardedPayload() so the main-event path and the subagent bus path can
// never drift.

/** Cap for cumulative tool output: first 64 KiB of UTF-8 bytes. */
export const TOOL_OUTPUT_PREVIEW_BYTES = 64 * 1024

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null
}

function stringFrom(value: unknown): string | undefined {
    return typeof value === 'string' && value.length > 0 ? value : undefined
}

// pi tool payloads are `{content: [{type:'text', text} | {type:'image', ...}], details}`
// (tool_execution_update.partialResult, tool_execution_end.result). Only the
// text parts are preview material; an image part's base64 is megabytes the
// client never renders from this frame, so walking the parts (instead of
// JSON-stringifying) is what keeps those frames small.
function flattenContentParts(parts: unknown[]): string {
    let text = ''
    for (const part of parts) {
        if (typeof part === 'string') {
            text += part
            continue
        }
        if (!isObject(part)) continue
        if (part.type !== undefined && part.type !== 'text') continue
        text += stringFrom(part.text) ?? stringFrom(part.content) ?? ''
    }
    return text
}

// Same flattening as the server's tool-output buffer (index.ts previously
// owned the only copy): strings pass through, arrays concatenate, objects
// prefer their text-ish field and fall back to JSON. A `content` array is
// never JSON-stringified — an image-only content array flattens to '' so the
// caller can omit the field entirely.
export function flattenToString(value: unknown): string | undefined {
    if (typeof value === 'string') return value
    if (Array.isArray(value)) return value.map(item => flattenToString(item) ?? '').join('')
    if (!isObject(value)) return undefined
    if (Array.isArray(value.content)) return flattenContentParts(value.content)
    return (
        stringFrom(value.content) ??
        stringFrom(value.text) ??
        stringFrom(value.output) ??
        JSON.stringify(value)
    )
}

function utf8Length(codePoint: number): number {
    if (codePoint < 0x80) return 1
    if (codePoint < 0x800) return 2
    if (codePoint < 0x10000) return 3
    return 4
}

// Byte-aware prefix cap. Iterating code points instead of encoding the whole
// string keeps the per-update cost proportional to the cap, not to the
// ever-growing cumulative partial result.
export function capPreviewBytes(text: string, maxBytes = TOOL_OUTPUT_PREVIEW_BYTES): string {
    let bytes = 0
    let end = 0
    for (const char of text) {
        const size = utf8Length(char.codePointAt(0) ?? 0)
        if (bytes + size > maxBytes) return text.slice(0, end)
        bytes += size
        end += char.length
    }
    return text
}

// D3/D4 content extraction: only text/thinking survive, normalized to the
// wire's canonical block shape ({type, text}) that history replay and the
// streaming buffer already use.
function textAndThinkingContent(content: unknown): Record<string, unknown>[] {
    const parts =
        typeof content === 'string' ? [content] : Array.isArray(content) ? content : []
    const blocks: Record<string, unknown>[] = []
    for (const part of parts) {
        if (typeof part === 'string') {
            blocks.push({ type: 'text', text: part })
            continue
        }
        if (!isObject(part)) continue
        if (part.type === 'text') {
            blocks.push({
                type: 'text',
                text: stringFrom(part.text) ?? stringFrom(part.content) ?? '',
            })
        } else if (part.type === 'thinking') {
            blocks.push({
                type: 'thinking',
                text: stringFrom(part.thinking) ?? stringFrom(part.text) ?? '',
            })
        }
    }
    return blocks
}

// User text only: message_start is how the client learns the prompt text it
// already echoed locally, and image blocks are base64 payloads the client
// never reads from this frame (history replay carries text only as well).
function userTextContent(content: unknown): string | Record<string, unknown>[] | undefined {
    if (typeof content === 'string') return content
    if (!Array.isArray(content)) return undefined
    const blocks: Record<string, unknown>[] = []
    for (const part of content) {
        if (typeof part === 'string') {
            blocks.push({ type: 'text', text: part })
        } else if (isObject(part) && part.type === 'text') {
            blocks.push({
                type: 'text',
                text: stringFrom(part.text) ?? stringFrom(part.content) ?? '',
            })
        }
    }
    return blocks
}

// pi's AssistantMessageEvent carries `partial` (the cumulative message) on
// every variant; `done`/`error` carry the whole message too. Only the delta
// itself is forwarded — mirrors pi's own toJsonEvent for json/rpc modes.
function trimAssistantMessageEvent(event: unknown): Record<string, unknown> {
    if (!isObject(event)) return {}
    const type = stringFrom(event.type)
    if (type === undefined) return {}
    if (type === 'done' || type === 'error') {
        const reason = stringFrom(event.reason)
        return reason !== undefined ? { type, reason } : { type }
    }
    const trimmed: Record<string, unknown> = { type }
    if (typeof event.contentIndex === 'number') trimmed.contentIndex = event.contentIndex
    if (type === 'text_delta' || type === 'thinking_delta' || type === 'toolcall_delta') {
        if (typeof event.delta === 'string') trimmed.delta = event.delta
    } else if (type === 'text_end' || type === 'thinking_end') {
        if (typeof event.content === 'string') trimmed.content = event.content
    }
    return trimmed
}

function trimStartMessage(message: unknown): Record<string, unknown> {
    if (!isObject(message)) return {}
    const role = stringFrom(message.role)
    if (role === undefined) return {}
    if (role !== 'user') return { role }
    const content = userTextContent(message.content)
    return content !== undefined ? { role, content } : { role }
}

// D3: the authoritative final content for the delta-assembled bubble, plus the
// stopReason the harness/abort gate reads. Tool-use blocks are dropped (the
// client already has carriers from tool_execution_start).
function trimTurnEndMessage(message: unknown): Record<string, unknown> {
    if (!isObject(message)) return {}
    const trimmed: Record<string, unknown> = {}
    const role = stringFrom(message.role)
    if (role !== undefined) trimmed.role = role
    if (typeof message.stopReason === 'string') trimmed.stopReason = message.stopReason
    trimmed.content = textAndThinkingContent(message.content)
    return trimmed
}

/**
 * Turns one raw pi event payload into the frame body sent to the phone.
 * `name` is the event name; `payload` is the event minus its `type` field.
 * Unknown names pass through unchanged (session_start, agent_start, …).
 */
export function trimForwardedPayload(
    name: string,
    payload: Record<string, unknown>
): Record<string, unknown> {
    switch (name) {
        case 'message_update':
            return {
                assistantMessageEvent: trimAssistantMessageEvent(
                    payload.assistantMessageEvent
                ),
            }
        case 'message_start':
            return { message: trimStartMessage(payload.message) }
        case 'tool_execution_update': {
            const trimmed: Record<string, unknown> = {}
            if (payload.toolCallId !== undefined) trimmed.toolCallId = payload.toolCallId
            if (payload.toolName !== undefined) trimmed.toolName = payload.toolName
            if (payload.args !== undefined) trimmed.args = payload.args
            const output = flattenToString(payload.partialResult)
            // Empty flattened text (e.g. an image-only partial) carries nothing
            // the client can render, so the field is omitted rather than sent.
            if (output) trimmed.partialResult = capPreviewBytes(output)
            return trimmed
        }
        case 'tool_execution_end': {
            const trimmed: Record<string, unknown> = {}
            if (payload.toolCallId !== undefined) trimmed.toolCallId = payload.toolCallId
            if (payload.toolName !== undefined) trimmed.toolName = payload.toolName
            if (typeof payload.isError === 'boolean') trimmed.isError = payload.isError
            return trimmed
        }
        case 'turn_end': {
            const trimmed: Record<string, unknown> = {}
            if (typeof payload.turnIndex === 'number') trimmed.turnIndex = payload.turnIndex
            trimmed.message = trimTurnEndMessage(payload.message)
            return trimmed
        }
        default:
            return payload
    }
}

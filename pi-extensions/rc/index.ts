import { createHash, randomBytes, randomInt } from 'node:crypto'
import { existsSync, mkdirSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createServer, type IncomingMessage, type Server } from 'node:http'
import { execFileSync } from 'node:child_process'
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent'
import { dbgLog } from './debug'
import { runPushSetup } from './push-setup'
import {
    FINISHED_COLLAPSE_ID,
    QUESTION_COLLAPSE_ID,
    finishedPayload,
    questionPayload,
    resolveApnsConfig,
    sendApnsPush,
    type PushOutcome,
} from './apns'

const RC_KEY = Symbol.for('pi-rc')
const PORT = 47800
const VERSION = 1
const STALE_CHECK_MS = 10_000
const STALE_MS = 90_000
const MAX_FRAME_BYTES = 1024 * 1024
const MAX_BUFFER_BYTES = 2 * 1024 * 1024
const RATE_LIMIT_FAILURES = 5
const RATE_LIMIT_LOCK_MS = 60_000
const RATE_LIMIT_EXPIRE_MS = 5 * 60_000
const STATUS_KEY = 'pi-rc'
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

type JsonObject = Record<string, unknown>
type ContentBlock =
    | { type: 'text'; text: string; textSignature?: string }
    | { type: 'thinking'; text: string; thinkingSignature?: string }
    | {
          type: 'toolUse'
          toolCallId: string
          toolName: string
          args: JsonObject
          output?: string
      }

type RemoteQuestionAnswer = { value: string; wasCustom: boolean; index?: number }
type RemoteQuestionnaireAnswer = {
    id: string
    value: string
    label: string
    wasCustom: boolean
    index?: number
}
type PendingAsk = {
    id: string
    kind: 'question' | 'questionnaire'
    message: JsonObject
    resolve: (result: RemoteQuestionAnswer | RemoteQuestionnaireAnswer[] | null) => void
}

type RateLimitEntry = {
    failures: number
    lockedUntil: number
    lastSeen: number
}

type Binding = {
    pi: ExtensionAPI
    ctx: ExtensionContext
}

type RcSocket = {
    destroyed: boolean
    remoteAddress?: string
    write(data: string | Uint8Array): boolean
    end(): void
    destroy(): void
    on(event: 'data', listener: (chunk: Buffer) => void): RcSocket
    on(event: string, listener: (...args: unknown[]) => void): RcSocket
}

type RcClient = {
    socket: RcSocket
    buffer: Buffer
    authenticated: boolean
    ip: string
    lastMessageAt: number
}

type RcSingleton = {
    server: Server | null
    clients: Set<RcClient>
    binding: Binding | null
    host: string | null
    port: number
    code: string | null
    heartbeat: ReturnType<typeof setInterval> | null
    rateLimits: Map<string, RateLimitEntry>
    pushToken: string | null
    isStreaming: boolean
    currentTurnBuffer: ContentBlock[]
    pendingAsk: PendingAsk | null
    quitAuthWritten: boolean
    processHooksRegistered: boolean
    handleUpgrade(req: IncomingMessage, socket: RcSocket, head: Buffer): void
    handleSocketData(client: RcClient, chunk: Buffer): void
    bind(pi: ExtensionAPI, ctx: ExtensionContext): void
    start(ctx: ExtensionContext): Promise<void>
    stop(reason: string, detail?: string): Promise<void>
    broadcast(message: JsonObject): void
    refreshStatus(): void
    hasConnectedClients(): boolean
    isServing(): boolean
    ask(opts: {
        kind: 'question' | 'questionnaire'
        params: JsonObject
    }): Promise<RemoteQuestionAnswer | RemoteQuestionnaireAnswer | null>
}

function singleton(): RcSingleton {
    const globalRecord = globalThis as unknown as Record<symbol, RcSingleton | undefined>
    if (globalRecord[RC_KEY]) return globalRecord[RC_KEY]

    const state: RcSingleton = {
        server: null,
        clients: new Set<RcClient>(),
        binding: null,
        host: null,
        port: PORT,
        code: null,
        heartbeat: null,
        rateLimits: new Map<string, RateLimitEntry>(),
        pushToken: null,
        isStreaming: false,
        currentTurnBuffer: [],
        pendingAsk: null,
        quitAuthWritten: false,
        processHooksRegistered: false,
        handleUpgrade(req, socket, head) {
            handleUpgrade(this, req, socket, head)
        },
        handleSocketData(client, chunk) {
            handleSocketData(this, client, chunk)
        },
        refreshStatus() {
            refreshStatus(this)
        },
        bind(pi, ctx) {
            this.binding = { pi, ctx }
        },
        async start(ctx) {
            if (this.server) return
            const server = createServer((_req, res) => {
                res.writeHead(404)
                res.end()
            })
            server.on('upgrade', (req, socket, head) =>
                this.handleUpgrade(req, socket as RcSocket, head)
            )
            try {
                this.host = resolveBindHost()
                this.code = randomInt(0, 1_000_000).toString().padStart(6, '0')
                await listen(server, PORT, this.host)
            } catch (error) {
                server.close()
                this.host = null
                this.code = null
                if (isListenError(error, 'EADDRINUSE')) {
                    ctx.ui.notify(
                        'port 47800 busy — another pi session is serving; toggle /rc there first',
                        'warning'
                    )
                    writeStoppedAuth('port_busy', 'port 47800 busy')
                    return
                }
                const message = error instanceof Error ? error.message : String(error)
                dbgLog('server start failed:', message)
                ctx.ui.notify(`rc failed to start: ${message}`, 'error')
                writeStoppedAuth('start_failed', message)
                return
            }
            this.server = server
            this.quitAuthWritten = false
            this.heartbeat = setInterval(() => closeStaleClients(this), STALE_CHECK_MS)
            const status = `rc: ws://${this.host}:${PORT} code ${this.code}`
            dbgLog('server started:', status)
            ctx.ui.notify(status, 'info')
            refreshStatus(this)
            writeRunningAuth(this.host, PORT, this.code)
        },
        async stop(reason, detail) {
            dbgLog('server stopped:', reason, detail ?? '')
            if (this.pendingAsk) {
                dbgLog('ask cancelled:', this.pendingAsk.id)
                this.broadcast({
                    type: 'question_resolved',
                    id: this.pendingAsk.id,
                    by: 'cancelled',
                })
                this.pendingAsk.resolve(null)
                this.pendingAsk = null
            }
            if (this.heartbeat) clearInterval(this.heartbeat)
            this.heartbeat = null
            const closeCode = reason === 'quit' ? 1001 : undefined
            for (const client of Array.from(this.clients)) closeClient(this, client, closeCode)
            if (this.server) await closeServer(this.server)
            this.server = null
            this.host = null
            this.code = null
            this.isStreaming = false
            this.currentTurnBuffer = []
            safeSetStatus(this.binding?.ctx, undefined)
            if (reason === 'quit') writeQuitStoppedAuth(this, detail)
            else writeStoppedAuth(reason, detail)
        },
        broadcast(message) {
            for (const client of Array.from(this.clients)) {
                if (!client.authenticated) continue
                if (!writeJson(client, message)) closeClient(this, client)
            }
        },
        hasConnectedClients() {
            return connectedClientCount(this) > 0
        },
        isServing() {
            return this.server !== null
        },
        async ask(opts) {
            if (!this.server || !this.hasConnectedClients()) return null
            if (this.pendingAsk) {
                dbgLog('ask cancelled (superseded):', this.pendingAsk.id)
                this.broadcast({
                    type: 'question_resolved',
                    id: this.pendingAsk.id,
                    by: 'cancelled',
                })
                this.pendingAsk.resolve(null)
                this.pendingAsk = null
            }
            const id = randomBytes(4).toString('hex')
            const message: JsonObject = {
                type: opts.kind,
                sessionId: sessionId(this),
                id,
                kind: opts.kind,
                params: opts.params,
            }
            const pending: PendingAsk = { id, kind: opts.kind, message, resolve: () => {} }
            this.pendingAsk = pending
            dbgLog('ask created:', id, opts.kind)
            this.broadcast(message)
            fireQuestionPush(this)
            return new Promise<RemoteQuestionAnswer | RemoteQuestionnaireAnswer[] | null>(
                resolve => {
                    pending.resolve = result => {
                        if (this.pendingAsk === pending) this.pendingAsk = null
                        resolve(result)
                    }
                }
            )
        },
    }
    registerProcessExitHandler(state)
    globalRecord[RC_KEY] = state
    return state
}

function handleUpgrade(
    state: RcSingleton,
    req: IncomingMessage,
    socket: RcSocket,
    head: Buffer
): void {
    const key = String(req.headers['sec-websocket-key'] ?? '')
    const upgrade = String(req.headers.upgrade ?? '').toLowerCase()
    const connection = String(req.headers.connection ?? '').toLowerCase()
    const version = String(req.headers['sec-websocket-version'] ?? '')
    const keyBytes = Buffer.from(key, 'base64')
    if (
        req.method !== 'GET' ||
        upgrade !== 'websocket' ||
        !connection
            .split(',')
            .map(part => part.trim())
            .includes('upgrade') ||
        version !== '13' ||
        keyBytes.length !== 16
    ) {
        socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n')
        socket.destroy()
        return
    }
    const accept = createHash('sha1')
        .update(key + WS_GUID)
        .digest('base64')
    socket.write(
        [
            'HTTP/1.1 101 Switching Protocols',
            'Upgrade: websocket',
            'Connection: Upgrade',
            `Sec-WebSocket-Accept: ${accept}`,
            '',
            '',
        ].join('\r\n')
    )
    const client: RcClient = {
        socket,
        buffer: Buffer.alloc(0),
        authenticated: false,
        ip: normalizeIp(req.socket.remoteAddress ?? socket.remoteAddress ?? 'unknown'),
        lastMessageAt: Date.now(),
    }
    state.clients.add(client)
    dbgLog('connection opened:', client.ip)
    socket.on('data', chunk => state.handleSocketData(client, chunk))
    socket.on('close', () => {
        state.clients.delete(client)
        dbgLog('connection closed:', client.ip)
    })
    socket.on('end', () => state.clients.delete(client))
    socket.on('error', () => closeClient(state, client))
    if (head.length > 0) state.handleSocketData(client, head)
}

function handleSocketData(state: RcSingleton, client: RcClient, chunk: Buffer): void {
    client.lastMessageAt = Date.now()
    if (client.buffer.length + chunk.length > MAX_BUFFER_BYTES) {
        sendErrorAndClose(state, client, 'invalid_message')
        return
    }
    client.buffer = Buffer.concat([client.buffer, chunk])
    try {
        for (;;) {
            const parsed = readFrame(client.buffer)
            if (!parsed) return
            client.buffer = client.buffer.subarray(parsed.bytesRead)
            if (parsed.opcode === 0x8) {
                closeClient(state, client)
                return
            }
            if (parsed.opcode === 0x9) {
                writeFrame(client.socket, Buffer.alloc(0), 0xa)
                continue
            }
            if (parsed.opcode !== 0x1) {
                sendErrorAndClose(state, client, 'invalid_message')
                return
            }
            let message: unknown
            try {
                message = JSON.parse(parsed.payload.toString('utf8'))
            } catch {
                sendErrorAndClose(state, client, 'invalid_message')
                return
            }
            dbgLog('recv from', client.ip, message)
            handleClientMessage(state, client, message)
        }
    } catch {
        sendErrorAndClose(state, client, 'invalid_message')
    }
}

function readFrame(
    buffer: Buffer
): { opcode: number; payload: Buffer; bytesRead: number } | null {
    if (buffer.length < 2) return null
    const first = buffer[0]
    const second = buffer[1]
    const fin = (first & 0x80) !== 0
    const opcode = first & 0x0f
    const masked = (second & 0x80) !== 0
    let length = second & 0x7f
    let offset = 2
    if (!fin || !masked) throw new Error('unsupported websocket frame')
    if (length === 126) {
        if (buffer.length < offset + 2) return null
        length = buffer.readUInt16BE(offset)
        offset += 2
    } else if (length === 127) {
        if (buffer.length < offset + 8) return null
        const bigLength = buffer.readBigUInt64BE(offset)
        if (bigLength > BigInt(Number.MAX_SAFE_INTEGER))
            throw new Error('websocket frame too large')
        length = Number(bigLength)
        offset += 8
    }
    if (length > MAX_FRAME_BYTES) throw new Error('websocket frame too large')
    if (buffer.length < offset + 4 + length) return null
    const mask = buffer.subarray(offset, offset + 4)
    offset += 4
    const payload = Buffer.from(buffer.subarray(offset, offset + length))
    for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4]
    return { opcode, payload, bytesRead: offset + length }
}

function writeJson(client: RcClient, message: JsonObject): boolean {
    dbgLog('send to', client.ip, message)
    try {
        writeFrame(client.socket, Buffer.from(JSON.stringify(message), 'utf8'), 0x1)
        return true
    } catch {
        return false
    }
}

function writeFrame(socket: RcSocket, payload: Buffer, opcode: number): void {
    const headerLength = payload.length < 126 ? 2 : payload.length <= 0xffff ? 4 : 10
    const header = Buffer.alloc(headerLength)
    header[0] = 0x80 | opcode
    if (payload.length < 126) {
        header[1] = payload.length
    } else if (payload.length <= 0xffff) {
        header[1] = 126
        header.writeUInt16BE(payload.length, 2)
    } else {
        header[1] = 127
        header.writeBigUInt64BE(BigInt(payload.length), 2)
    }
    socket.write(Buffer.concat([header, payload]))
}

function closeClient(state: RcSingleton, client: RcClient, code?: number): void {
    state.clients.delete(client)
    refreshStatus(state)
    if (!client.socket.destroyed) {
        try {
            writeFrame(client.socket, closeFramePayload(code), 0x8)
            client.socket.end()
        } catch {
            client.socket.destroy()
        }
    }
}

function closeFramePayload(code?: number): Buffer {
    if (code === undefined) return Buffer.alloc(0)
    const payload = Buffer.alloc(2)
    payload.writeUInt16BE(code, 0)
    return payload
}

function sendErrorAndClose(
    state: RcSingleton,
    client: RcClient,
    code: string,
    message?: string
): void {
    writeJson(client, { type: 'error', code, ...(message ? { message } : {}) })
    setTimeout(() => closeClient(state, client), 10)
}

function handleClientMessage(state: RcSingleton, client: RcClient, message: unknown): void {
    if (!isObject(message) || typeof message.type !== 'string') {
        sendErrorAndClose(state, client, 'invalid_message')
        return
    }
    if (!client.authenticated) {
        if (message.type !== 'hello') {
            sendErrorAndClose(state, client, 'invalid_message')
            return
        }
        handleHello(state, client, message)
        return
    }
    switch (message.type) {
        case 'prompt':
            handlePrompt(state, client, message)
            break
        case 'steer':
            handleSteer(state, client, message)
            break
        case 'abort':
            if (!state.binding?.ctx.isIdle()) state.binding?.ctx.abort()
            break
        case 'get_state':
            writeJson(client, buildState(state))
            break
        case 'get_history':
            writeJson(
                client,
                buildHistory(
                    state,
                    typeof message.cursor === 'string' ? message.cursor : undefined
                )
            )
            break
        case 'ping':
            writeJson(client, { type: 'pong' })
            break
        case 'answer':
            handleAnswer(state, client, message)
            break
        case 'answer_questionnaire':
            handleAnswerQuestionnaire(state, client, message)
            break
        case 'push_token':
            handlePushToken(state, client, message)
            break
        default:
            writeJson(client, { type: 'error', code: 'invalid_message' })
    }
}

function handleHello(state: RcSingleton, client: RcClient, message: JsonObject): void {
    cleanupRateLimits(state)
    if (message.version !== VERSION) {
        sendErrorAndClose(state, client, 'version_mismatch')
        return
    }
    const limit = state.rateLimits.get(client.ip)
    if (limit && limit.lockedUntil > Date.now()) {
        sendErrorAndClose(state, client, 'rate_limited')
        return
    }
    const code = typeof message.code === 'string' ? message.code : ''
    if (!/^[0-9]{6}$/.test(code) || code !== state.code) {
        recordFailedHello(state, client.ip)
        const failed = state.rateLimits.get(client.ip)
        sendErrorAndClose(
            state,
            client,
            failed && failed.lockedUntil > Date.now() ? 'rate_limited' : 'bad_code'
        )
        return
    }
    state.rateLimits.delete(client.ip)
    client.authenticated = true
    refreshStatus(state)
    writeJson(client, { type: 'hello_ok', version: VERSION })
    writeSessionSnapshot(client, state)
    if (state.pendingAsk) writeJson(client, state.pendingAsk.message)
}

function handleAnswer(state: RcSingleton, client: RcClient, message: JsonObject): void {
    const pending = state.pendingAsk
    if (!pending || pending.kind !== 'question' || pending.id !== message.id) {
        writeJson(client, { type: 'error', code: 'unknown_question' })
        return
    }
    const value = message.value
    const wasCustom = message.wasCustom
    const index = message.index
    if (typeof value !== 'string' || typeof wasCustom !== 'boolean') {
        writeJson(client, { type: 'error', code: 'invalid_message' })
        return
    }
    pending.resolve({ value, wasCustom, ...(typeof index === 'number' ? { index } : {}) })
    dbgLog('ask resolved by client:', pending.id)
    state.broadcast({ type: 'question_resolved', id: pending.id, by: 'client', value })
}

function isRemoteQuestionnaireAnswer(value: unknown): value is RemoteQuestionnaireAnswer {
    if (!isObject(value)) return false
    const id = value.id
    const answerValue = value.value
    const label = value.label
    const wasCustom = value.wasCustom
    const index = value.index
    return (
        typeof id === 'string' &&
        typeof answerValue === 'string' &&
        typeof label === 'string' &&
        typeof wasCustom === 'boolean' &&
        (typeof index === 'number' || index === undefined)
    )
}

function handleAnswerQuestionnaire(state: RcSingleton, client: RcClient, message: JsonObject): void {
    const pending = state.pendingAsk
    if (!pending || pending.kind !== 'questionnaire' || pending.id !== message.id) {
        writeJson(client, { type: 'error', code: 'unknown_question' })
        return
    }
    const raw = message.answers
    if (!Array.isArray(raw)) {
        writeJson(client, { type: 'error', code: 'invalid_message' })
        return
    }
    const answers: RemoteQuestionnaireAnswer[] = []
    for (const item of raw) {
        if (!isRemoteQuestionnaireAnswer(item)) {
            writeJson(client, { type: 'error', code: 'invalid_message' })
            return
        }
        answers.push(item)
    }
    pending.resolve(answers)
    dbgLog('ask resolved by client:', pending.id)
    state.broadcast({ type: 'question_resolved', id: pending.id, by: 'client' })
}

// APNs device tokens are 64 hex chars. Anything else is ignored silently:
// no error frame, no close, no state change (spec: wire protocol, push_token).
function handlePushToken(state: RcSingleton, client: RcClient, message: JsonObject): void {
    const token = message.token
    if (typeof token !== 'string' || !/^[0-9a-f]{64}$/i.test(token)) {
        dbgLog('push_token ignored (invalid):', client.ip)
        return
    }
    state.pushToken = token
    refreshStatus(state)
    dbgLog('push_token registered:', client.ip)
}

function fireFinishedPush(state: RcSingleton): void {
    const token = state.pushToken
    if (!token) return
    void sendApnsPush(token, FINISHED_COLLAPSE_ID, finishedPayload(sessionId(state)))
        .then(outcome => handlePushOutcome(state, outcome, 'finished', token))
        .catch(error => dbgLog('apns finished push failed:', errorMessage(error)))
}

function fireQuestionPush(state: RcSingleton): void {
    const token = state.pushToken
    if (!token) return
    void sendApnsPush(token, QUESTION_COLLAPSE_ID, questionPayload(sessionId(state)))
        .then(outcome => handlePushOutcome(state, outcome, 'question', token))
        .catch(error => dbgLog('apns question push failed:', errorMessage(error)))
}

function handlePushOutcome(state: RcSingleton, outcome: PushOutcome, label: string, token: string): void {
    // Only clear the token if it is still the one APNs rejected: a newer
    // registration that landed while this send was in flight must survive.
    if (outcome.ok === 'dropped' && state.pushToken === token) {
        state.pushToken = null
        refreshStatus(state)
        dbgLog(
            'push_token dropped (token invalid per APNs):',
            label,
            'status',
            outcome.status,
            'reason',
            outcome.reason ?? '-'
        )
        return
    }
    if (outcome.ok === 'dropped') {
        dbgLog('push_token drop ignored (token already replaced):', label)
        return
    }
    dbgLog('apns push outcome:', label, outcome)
}

function writeSessionSnapshot(client: RcClient, state: RcSingleton): void {
    writeJson(client, buildState(state))
    writeJson(client, buildHistory(state))
    if (hasStreamingBuffer(state)) writeJson(client, streamingBuffer(state))
}

function broadcastSessionSnapshot(state: RcSingleton): void {
    state.broadcast(buildState(state))
    state.broadcast(buildHistory(state))
    if (hasStreamingBuffer(state)) state.broadcast(streamingBuffer(state))
}

function hasStreamingBuffer(state: RcSingleton): boolean {
    const isStreaming = state.binding?.ctx ? !state.binding.ctx.isIdle() : state.isStreaming
    return isStreaming && state.currentTurnBuffer.length > 0
}

function streamingBuffer(state: RcSingleton): JsonObject {
    return {
        type: 'streaming_buffer',
        sessionId: sessionId(state),
        content: state.currentTurnBuffer,
    }
}

function handlePrompt(state: RcSingleton, client: RcClient, message: JsonObject): void {
    if (typeof message.text !== 'string') {
        writeJson(client, { type: 'error', code: 'invalid_message' })
        return
    }
    const binding = state.binding
    if (!binding) {
        writeJson(client, {
            type: 'error',
            code: 'invalid_message',
            message: 'no active pi session',
        })
        return
    }
    if (!binding.ctx.isIdle()) {
        writeJson(client, { type: 'error', code: 'not_idle' })
        return
    }
    try {
        binding.pi.sendUserMessage(message.text)
    } catch (error) {
        writeJson(client, { type: 'error', code: 'send_failed', message: errorMessage(error) })
    }
}

function handleSteer(state: RcSingleton, client: RcClient, message: JsonObject): void {
    if (typeof message.text !== 'string') {
        writeJson(client, { type: 'error', code: 'invalid_message' })
        return
    }
    const binding = state.binding
    if (!binding) {
        writeJson(client, {
            type: 'error',
            code: 'invalid_message',
            message: 'no active pi session',
        })
        return
    }
    try {
        if (binding.ctx.isIdle()) binding.pi.sendUserMessage(message.text)
        else binding.pi.sendUserMessage(message.text, { deliverAs: 'steer' })
    } catch (error) {
        writeJson(client, { type: 'error', code: 'send_failed', message: errorMessage(error) })
    }
}

function buildState(state: RcSingleton): JsonObject {
    const ctx = state.binding?.ctx
    const model = ctx?.model as JsonObject | undefined
    const provider =
        stringFrom(model?.provider) ??
        stringFrom(model?.providerId) ??
        stringFrom(model?.providerName) ??
        'unknown'
    const id =
        stringFrom(model?.id) ??
        stringFrom(model?.model) ??
        stringFrom(model?.name) ??
        'unknown'
    const usage = ctx?.getContextUsage()
    return {
        type: 'state',
        sessionId: sessionId(state),
        cwd: ctx?.cwd ?? process.cwd(),
        ...(sessionName(state) ? { sessionName: sessionName(state) } : {}),
        model: { provider, id },
        ...(ctx?.thinkingLevel ? { thinkingLevel: ctx.thinkingLevel } : {}),
        isStreaming: ctx ? !ctx.isIdle() : state.isStreaming,
        ...(usage && usage.tokens !== null && usage.contextWindow !== null && usage.percent !== null
            ? { contextUsage: { tokens: usage.tokens, contextWindow: usage.contextWindow, percent: usage.percent } }
            : {}),
    }
}

function buildHistory(state: RcSingleton, cursor?: string): JsonObject {
    const entries = safeArray(state.binding?.ctx.sessionManager.getBranch())
    const messages = entries.flatMap(entry => mapHistoryEntry(entry))
    const parsedCursor =
        cursor && /^\d+$/.test(cursor) ? Number.parseInt(cursor, 10) : undefined
    const end =
        parsedCursor !== undefined && Number.isFinite(parsedCursor)
            ? parsedCursor
            : messages.length
    const start = Math.max(0, end - 200)
    return {
        type: 'history',
        sessionId: sessionId(state),
        messages: messages.slice(start, end),
        ...(start > 0 ? { cursor: String(start) } : {}),
    }
}

function mapHistoryEntry(entry: unknown): JsonObject[] {
    if (!isObject(entry)) return []
    if (entry.type === 'compaction')
        return [{ role: 'compaction', summary: stringFrom(entry.summary) ?? '' }]
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

function textFromMessage(message: JsonObject): string {
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

function registerEventHandlers(pi: ExtensionAPI, state: RcSingleton): void {
    const forward = (name: string, event: unknown, ctx: ExtensionContext) => {
        state.bind(pi, ctx)
        trackEvent(state, name, event)
        if (!state.server) return
        state.broadcast({
            ...eventPayload(event),
            type: 'event',
            sessionId: sessionId(state),
            name,
        })
        if (name === 'session_start') broadcastSessionSnapshot(state)
    }
    pi.on('session_start', (event, ctx) => forward('session_start', event, ctx))
    pi.on('session_shutdown', async (event, ctx) => {
        state.bind(pi, ctx)
        if (event.reason === 'quit') await state.stop('quit', 'pi shutdown')
    })
    pi.on('agent_start', (event, ctx) => forward('agent_start', event, ctx))
    pi.on('agent_settled', (event, ctx) => forward('agent_settled', event, ctx))
    pi.on('turn_end', (event, ctx) => forward('turn_end', event, ctx))
    pi.on('message_start', (event, ctx) => forward('message_start', event, ctx))
    pi.on('message_update', (event, ctx) => forward('message_update', event, ctx))
    pi.on('tool_execution_start', (event, ctx) => forward('tool_execution_start', event, ctx))
    pi.on('tool_execution_update', (event, ctx) =>
        forward('tool_execution_update', event, ctx)
    )
    pi.on('tool_execution_end', (event, ctx) =>
        forward('tool_execution_end', event, ctx)
    )
}

function trackEvent(state: RcSingleton, name: string, event: unknown): void {
    if (name === 'agent_start') state.isStreaming = true
    if (name === 'agent_settled') {
        state.isStreaming = false
        // Fires on every settled turn by design; the constant collapse id
        // dedupes at APNs, so the latest settle is the one delivered.
        fireFinishedPush(state)
    }
    if (
        name === 'message_start' &&
        isObject(event) &&
        isObject(event.message) &&
        event.message.role === 'assistant'
    ) {
        state.currentTurnBuffer = []
    }
    if (name === 'message_update' && isObject(event))
        appendAssistantDelta(state, event.assistantMessageEvent)
    if (name === 'tool_execution_start' && isObject(event)) {
        state.currentTurnBuffer.push({
            type: 'toolUse',
            toolCallId: stringFrom(event.toolCallId) ?? '',
            toolName: stringFrom(event.toolName) ?? 'tool',
            args: isObject(event.args) ? event.args : {},
        })
    }
    if (name === 'tool_execution_update' && isObject(event)) updateToolOutput(state, event)
    if (name === 'tool_execution_end' && isObject(event)) updateToolOutput(state, event)
    if (name === 'turn_end') state.currentTurnBuffer = []
}

function appendAssistantDelta(state: RcSingleton, assistantEvent: unknown): void {
    if (!isObject(assistantEvent)) return
    const type = stringFrom(assistantEvent.type)
    const delta = stringFrom(assistantEvent.delta) ?? stringFrom(assistantEvent.text) ?? ''
    const index =
        typeof assistantEvent.contentIndex === 'number'
            ? assistantEvent.contentIndex
            : state.currentTurnBuffer.length
    if (type === 'text_delta' || type === 'thinking_delta') {
        const blockType = type === 'thinking_delta' ? 'thinking' : 'text'
        let block = state.currentTurnBuffer[index]
        if (!block || block.type !== blockType) {
            block = { type: blockType, text: '' } as ContentBlock
            state.currentTurnBuffer[index] = block
        }
        if (block.type !== 'toolUse') block.text += delta
    } else if (type === 'toolcall_delta') {
        let block = state.currentTurnBuffer[index]
        if (!block || block.type !== 'toolUse') {
            block = { type: 'toolUse', toolCallId: '', toolName: 'tool', args: {} }
            state.currentTurnBuffer[index] = block
        }
        if (block.type === 'toolUse' && delta.length > 0)
            block.output = `${block.output ?? ''}${delta}`
    }
    state.currentTurnBuffer = state.currentTurnBuffer.filter(Boolean)
}

function updateToolOutput(state: RcSingleton, event: JsonObject): void {
    const toolCallId = stringFrom(event.toolCallId)
    const block = [...state.currentTurnBuffer]
        .reverse()
        .find(
            item => item.type === 'toolUse' && (!toolCallId || item.toolCallId === toolCallId)
        )
    if (!block || block.type !== 'toolUse') return
    block.output =
        stringFromDeep(event.partialResult) ?? stringFromDeep(event.result) ?? block.output
}

function eventPayload(event: unknown): JsonObject {
    if (!isObject(event)) return {}
    const { type: _type, ...rest } = event
    return rest
}

function sessionId(state: RcSingleton): string {
    return (state.binding?.ctx.sessionManager as { getSessionId?: () => string })?.getSessionId?.()
      ?? 'unknown'
}

function sessionName(state: RcSingleton): string | undefined {
    const managerName = state.binding?.ctx.sessionManager.getSessionName?.()
    return managerName ?? undefined
}

const TAILSCALE_BINS = ['tailscale', '/Applications/Tailscale.app/Contents/MacOS/Tailscale']

function tailscaleIp4(bin: string): string | null {
    const output = execFileSync(bin, ['ip', '-4'], { encoding: 'utf8' })
    return (
        output
            .split('\n')
            .map(line => line.trim())
            .find(Boolean) ?? null
    )
}

function resolveBindHost(): string {
    const override = process.env.PI_RC_BIND?.trim()
    if (override) return override
    let lastError: unknown = null
    for (const bin of TAILSCALE_BINS) {
        try {
            const host = tailscaleIp4(bin)
            if (host) return host
            lastError = new Error(`${bin} ip -4 returned no IPv4 address`)
        } catch (error) {
            lastError = error
        }
    }
    const detail = lastError instanceof Error ? lastError.message : String(lastError)
    throw new Error(
        `could not determine tailnet IP: ${detail} (is Tailscale running? set PI_RC_BIND to override)`
    )
}

function writeRunningAuth(host: string, port: number, code: string): void {
    writeAuth({ status: 'running', host, port, code, ts: Date.now() })
}

function writeStoppedAuth(reason: string, detail?: string): void {
    writeAuth({ status: 'stopped', reason, ...(detail ? { detail } : {}), ts: Date.now() })
}

function writeAuth(payload: JsonObject): void {
    const file = authFilePath()
    if (!file) return
    const dir = dirname(file)
    if (dir !== '.' && !existsSync(dir)) mkdirSync(dir, { recursive: true })
    const tempFile = `${file}.${process.pid}.${Date.now()}.tmp`
    writeFileSync(tempFile, `${JSON.stringify(payload)}\n`, { encoding: 'utf8', mode: 0o600 })
    renameSync(tempFile, file)
}


// Test seam only: written solely when a harness sets PI_RC_AUTH_FILE.
// Production never touches the filesystem for RC state (TUI shows it via notify).
function authFilePath(): string | null {
    const file = process.env.PI_RC_AUTH_FILE?.trim()
    return file ? file : null
}

function writeQuitStoppedAuth(state: RcSingleton, detail?: string): void {
    if (state.quitAuthWritten) return
    state.quitAuthWritten = true
    writeStoppedAuth('quit', detail)
}

function connectedClientCount(state: RcSingleton): number {
    let count = 0
    for (const client of state.clients) {
        if (client.authenticated && !client.socket.destroyed) count += 1
    }
    return count
}

function safeSetStatus(ctx: ExtensionContext | undefined, text: string | undefined): void {
    const setStatus = ctx?.ui?.setStatus
    if (typeof setStatus !== 'function') return
    try {
        setStatus.call(ctx.ui, STATUS_KEY, text)
    } catch {
        // Status support varies by harness mode; rc operation should not depend on it.
    }
}

function pushStatusText(state: RcSingleton): string {
    if (!resolveApnsConfig()) return 'push: not configured'
    return state.pushToken ? 'push ok' : 'push: no token'
}

function refreshStatus(state: RcSingleton): void {
    if (!state.server || !state.host || !state.code) return
    const clients = connectedClientCount(state)
    const clientsText = clients === 0 ? 'no clients' : `${clients} client${clients === 1 ? '' : 's'}`
    safeSetStatus(
        state.binding?.ctx,
        `rc: ws://${state.host}:${state.port} code ${state.code} · ${clientsText} · ${pushStatusText(state)}`
    )
}

function registerProcessExitHandler(state: RcSingleton): void {
    if (state.processHooksRegistered) return
    state.processHooksRegistered = true
    process.once('exit', () => {
        if (state.server || state.code) writeQuitStoppedAuth(state)
    })
}

function listen(server: Server, port: number, host: string): Promise<void> {
    return new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(port, host, () => {
            server.off('error', reject)
            resolve()
        })
    })
}

function closeServer(server: Server): Promise<void> {
    return new Promise(resolve => server.close(() => resolve()))
}

function closeStaleClients(state: RcSingleton): void {
    const now = Date.now()
    for (const client of Array.from(state.clients)) {
        if (now - client.lastMessageAt > STALE_MS) {
            dbgLog('stale client closed:', client.ip)
            closeClient(state, client)
        }
    }
}

function cleanupRateLimits(state: RcSingleton): void {
    const now = Date.now()
    for (const [ip, entry] of state.rateLimits) {
        if (now - entry.lastSeen > RATE_LIMIT_EXPIRE_MS) state.rateLimits.delete(ip)
    }
}

function recordFailedHello(state: RcSingleton, ip: string): void {
    const now = Date.now()
    const entry = state.rateLimits.get(ip) ?? { failures: 0, lockedUntil: 0, lastSeen: now }
    entry.failures += 1
    entry.lastSeen = now
    if (entry.failures >= RATE_LIMIT_FAILURES) entry.lockedUntil = now + RATE_LIMIT_LOCK_MS
    state.rateLimits.set(ip, entry)
}

function normalizeIp(ip: string): string {
    return ip.startsWith('::ffff:') ? ip.slice(7) : ip
}

function isListenError(error: unknown, code: string): boolean {
    return isObject(error) && error.code === code
}

function isObject(value: unknown): value is JsonObject {
    return typeof value === 'object' && value !== null
}

function stringFrom(value: unknown): string | undefined {
    return typeof value === 'string' && value.length > 0 ? value : undefined
}

function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error)
}

function stringFromDeep(value: unknown): string | undefined {
    if (typeof value === 'string') return value
    if (Array.isArray(value)) return value.map(item => stringFromDeep(item) ?? '').join('')
    if (!isObject(value)) return undefined
    return (
        stringFrom(value.content) ??
        stringFrom(value.text) ??
        stringFrom(value.output) ??
        JSON.stringify(value)
    )
}

function safeArray(value: unknown): unknown[] {
    return Array.isArray(value) ? value : []
}

export default function rc(pi: ExtensionAPI): void {
    const state = singleton()
    state.handleUpgrade = (req, socket, head) => handleUpgrade(state, req, socket, head)
    state.handleSocketData = (client, chunk) => handleSocketData(state, client, chunk)
    state.refreshStatus = () => refreshStatus(state)
    registerEventHandlers(pi, state)
    pi.registerCommand('rc', {
        description: 'Toggle remote-control WebSocket server (subcommand: push-setup)',
        getArgumentCompletions: (argumentPrefix: string) =>
            argumentPrefix === '' || 'push-setup'.startsWith(argumentPrefix)
                ? [
                      {
                          value: 'push-setup',
                          label: 'push-setup',
                          description: 'Configure APNs push delivery for the rc app',
                      },
                  ]
                : null,
        handler: async (args, ctx) => {
            dbgLog('command /rc invoked')
            state.bind(pi, ctx)
            if (args.trim() === 'push-setup') {
                dbgLog('command /rc push-setup invoked')
                await runPushSetup(state, ctx.ui, sessionId(state))
                return
            }
            if (state.server) {
                await state.stop('toggled_off', 'manual /rc toggle off')
                ctx.ui.notify('rc stopped', 'info')
                return
            }
            await state.start(ctx)
        },
    })
}

import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto'
import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    renameSync,
    writeFileSync,
} from 'node:fs'
import { networkInterfaces } from 'node:os'
import { dirname, join } from 'node:path'
import { createServer, type IncomingMessage, type Server } from 'node:http'
import {
    getAgentDir,
    type ExtensionAPI,
    type ExtensionCommandContext,
    type ExtensionContext,
} from '@earendil-works/pi-coding-agent'
import { Text } from '@earendil-works/pi-tui'
import { Type } from 'typebox'
import { dbgLog } from './debug'
import {
    generateEntryToken,
    newEntryId,
    probePort,
    pruneStaleEntries,
    readRegistry,
    removeEntry,
    upsertEntry,
    watchRegistry,
    type RcModelRef,
    type RcSessionEntry,
} from './registry'
import { runPushSetup } from './push-setup'
import { finishedBody, questionBody } from './title'
import {
    finishedCollapseId,
    finishedPayload,
    questionCollapseId,
    questionPayload,
    readStoredDeviceToken,
    resolveApnsConfig,
    saveDeviceToken,
    sendApnsPush,
    type PushOutcome,
} from './apns'
import { pruneBufferForSnapshot, tailClassification } from './turnBuffer'
import {
    SUBAGENT_EVENT_WHITELIST,
    buildSubagentSnapshot,
    classifySettle,
    mapBusEvent,
    parseSubagentMeta,
    resolveAttachCandidate,
    scanLiveSubagents,
    type ScannedSubagent,
} from './subagents'

const RC_KEY = Symbol.for('pi-rc')
const PORT = 47800
const SIBLING_PORT_START = 47801
const SIBLING_PORT_END = 47899
const REGISTRY_DEBOUNCE_MS = 250
const VERSION = 1
const STALE_CHECK_MS = 10_000
const STALE_MS = 90_000
const MAX_FRAME_BYTES = 1024 * 1024
const MAX_BUFFER_BYTES = 2 * 1024 * 1024
const RATE_LIMIT_FAILURES = 5
const RATE_LIMIT_LOCK_MS = 60_000
const RATE_LIMIT_EXPIRE_MS = 5 * 60_000
// Select deadline: from the proxy open attempt to the sibling's hello_ok
// (spec: rc-multi-session-spec.md §Wire protocol — select ack semantics).
const SELECT_TIMEOUT_MS = 10_000
// Proxy keepalive cadence: the sibling's STALE_MS is 90 s, so a 30 s ping
// leaves a 3x margin before an idle-but-selected proxy stale-closes.
const PROXY_KEEPALIVE_MS = 30_000
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

type RemoteAnswer = {
    id: string
    value: string
    label: string
    wasCustom: boolean
    index?: number
}
type PendingAsk = {
    id: string
    kind: 'ask_user_question'
    message: JsonObject
    resolve: (result: RemoteAnswer[] | 'dismissed' | null) => void
}

type RateLimitEntry = {
    failures: number
    lockedUntil: number
    lastSeen: number
}

// In-flight compaction mirror (spec: rc-compaction-visibility-spec.md D1):
// present on state frames only while a compaction is running; a reconnecting
// client sees the banner state in the connect burst for free.
type CompactingInfo = {
    reason: 'manual' | 'threshold' | 'overflow'
    willRetry?: boolean
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

// Proxy connection (anchor only): a live anchor→sibling WebSocket standing in
// for the phone client, opened lazily on select_session (spec:
// rc-multi-session-spec.md §Proxy connection lifecycle). authRetried is false
// while the hello is using the first token read for this open attempt; a
// bad_code then arms a registry-change retry (spec: keep the selection pending,
// re-read the entry at probe time, retry once).
type RcProxy = {
    id: string
    ws: WebSocket
    helloDone: boolean
    authRetried: boolean
    openTimer: ReturnType<typeof setTimeout> | null
    keepalive: ReturnType<typeof setInterval> | null
}

type RcClient = {
    socket: RcSocket
    buffer: Buffer
    authenticated: boolean
    ip: string
    lastMessageAt: number
    // Per-connection selection (anchor only; spec: rc-multi-session-spec.md
    // §Wire protocol — "one selected session at a time" per phone connection).
    // null = default: the anchor's own session view.
    selectedId: string | null
    // Feature B: the subagent run this connection is attached to (null =
    // none). ONE attach per client — a new attach_subagent implicitly detaches
    // the previous one; cleared on session-selection change, client close, and
    // run settle.
    attachedSubagentId: string | null
    proxy: RcProxy | null
    // Select whose proxy hello failed with bad_code: the selection stays
    // pending and reopens (with a fresh registry token read) on the NEXT
    // registry change. One retry; the second failure is terminal
    // (session_not_found) — a retry loop is forbidden (spec).
    pendingProxyAuth: string | null
    // The select-deadline timer for the FIRST open attempt of the current
    // selection (spec: the 10 s window runs from the select, not from each
    // retry). Null when no selection is in flight.
    selectDeadlineAt: ReturnType<typeof setTimeout> | null
}

type RcSingleton = {
    server: Server | null
    clients: Set<RcClient>
    binding: Binding | null
    host: string | null
    port: number
    isAnchor: boolean
    code: string | null
    entryId: string | null
    entryToken: string | null
    heartbeat: ReturnType<typeof setInterval> | null
    watcher: { stop(): void } | null
    lastBroadcastSessions: string | null
    rateLimits: Map<string, RateLimitEntry>
    lastPush: string | null
    lastStopReason: string | null
    isStreaming: boolean
    currentTurnBuffer: ContentBlock[]
    // Feature B: per-run in-flight state, lazily keyed by subagentId from the
    // FIRST observed bus event (M2: attach mid-run is the normal case; the
    // in-flight turn is uncommitted and absent from the child's .jsonl, so it
    // must be tracked independently of attach state).
    subagentRunState: Map<string, { buffer: ContentBlock[]; lastStopReason: string | null }>
    pendingAsk: PendingAsk | null
    pendingSteers: string[]
    compacting: CompactingInfo | null
    commandCtx: ExtensionCommandContext | null
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
    askAvailable(): boolean
    ask(opts: {
        kind: 'ask_user_question'
        params: JsonObject
        signal?: AbortSignal
    }): Promise<RemoteAnswer[] | 'dismissed' | null>
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
        isAnchor: false,
        code: null,
        entryId: null,
        entryToken: null,
        heartbeat: null,
        watcher: null,
        lastBroadcastSessions: null,
        rateLimits: new Map<string, RateLimitEntry>(),
        lastPush: null,
        lastStopReason: null,
        isStreaming: false,
        currentTurnBuffer: [],
        subagentRunState: new Map(),
        pendingAsk: null,
        pendingSteers: [],
        compacting: null,
        commandCtx: null,
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
            this.code = randomInt(0, 1_000_000).toString().padStart(6, '0')
            this.isAnchor = true
            this.port = PORT
            try {
                this.host = resolveBindHost()
                await listen(server, PORT, this.host)
            } catch (error) {
                if (isListenError(error, 'EADDRINUSE')) {
                    // 47800 is owned by the anchor. The sibling role is the
                    // normal multi-session case (spec: rc-multi-session-spec.md
                    // §Roles), not an error: bind loopback-only on the first
                    // free port in the sibling range.
                    this.isAnchor = false
                    let siblingPort: number | null = null
                    let siblingError: unknown = null
                    for (let port = SIBLING_PORT_START; port <= SIBLING_PORT_END; port++) {
                        try {
                            await listen(server, port, '127.0.0.1')
                            siblingPort = port
                            break
                        } catch (innerError) {
                            if (!isListenError(innerError, 'EADDRINUSE')) {
                                siblingError = innerError
                                break
                            }
                        }
                    }
                    if (siblingError !== null) {
                        server.close()
                        this.host = null
                        this.code = null
                        const message =
                            siblingError instanceof Error
                                ? siblingError.message
                                : String(siblingError)
                        dbgLog('server start failed:', message)
                        ctx.ui.notify(`rc failed to start: ${message}`, 'error')
                        writeStoppedAuth('start_failed', message)
                        return
                    }
                    if (siblingPort === null) {
                        // Pathological exhaustion: degrade to no server (the
                        // process keeps running, unregistered).
                        server.close()
                        this.host = null
                        this.code = null
                        dbgLog('server start failed: sibling port range exhausted')
                        ctx.ui.notify(
                            'rc not serving: ports 47800-47899 are all busy on this machine',
                            'warning'
                        )
                        writeStoppedAuth('port_busy', `ports ${PORT}-${SIBLING_PORT_END} busy`)
                        return
                    }
                    this.host = '127.0.0.1'
                    this.port = siblingPort
                } else {
                    server.close()
                    this.host = null
                    this.code = null
                    const message = error instanceof Error ? error.message : String(error)
                    dbgLog('server start failed:', message)
                    ctx.ui.notify(`rc failed to start: ${message}`, 'error')
                    writeStoppedAuth('start_failed', message)
                    return
                }
            }
            this.server = server
            this.quitAuthWritten = false
            this.heartbeat = setInterval(() => closeStaleClients(this), STALE_CHECK_MS)
            // Anchor-only: the list of every session on this box is the
            // anchor's to prune and broadcast (spec: rc-multi-session-spec.md
            // §Registry). Siblings keep their loopback server but take no
            // part in the list.
            if (this.isAnchor) startSessionsWatcher(this)
            const status = `rc: ws://${this.host}:${this.port} code ${this.code}`
            dbgLog('server started:', status)
            ctx.ui.notify(
                this.isAnchor
                    ? status
                    : `${status} (sibling — another session on this machine serves the phone on port ${PORT})`,
                'info'
            )
            refreshStatus(this)
            writeRunningAuth(this.host, this.port, this.code)
            registerRcEntry(this)
        },
        async stop(reason, detail) {
            dbgLog('server stopped:', reason, detail ?? '')
            cancelPendingAsk(this)
            if (this.heartbeat) clearInterval(this.heartbeat)
            this.heartbeat = null
            stopSessionsWatcher(this)
            const closeCode = reason === 'quit' ? 1001 : undefined
            for (const client of Array.from(this.clients)) closeClient(this, client, closeCode)
            if (this.server) await closeServer(this.server)
            this.server = null
            this.host = null
            this.code = null
            this.isStreaming = false
            this.currentTurnBuffer = []
            // pendingSteers is intentionally NOT reset here: toggling /rc off
            // does not clear pi's in-memory steering queue, so a toggle-on
            // snapshot must still report it. Process death is the real reset.
            unregisterRcEntry(this)
            safeSetStatus(this.binding?.ctx, undefined)
            if (reason === 'quit') writeQuitStoppedAuth(this, detail)
            else writeStoppedAuth(reason, detail)
        },
        broadcast(message) {
            // Suppression rule (spec: rc-multi-session-spec.md §Wire protocol,
            // "Anchor's own frames while a sibling is selected"): broadcast is
            // the anchor's OWN-session channel — state/history/event/question/
            // question_resolved/streaming_buffer/error all flow through it and
            // must not reach a client that has a non-anchor entry selected,
            // or the phone's session-agnostic handlers would rebind/overlay the
            // sibling view. Protocol frames (hello_ok, sessions, error codes,
            // session_gone) are per-client writeJson calls and never land
            // here, so they are never suppressed. A client whose selection is
            // null (default) or the anchor entry itself sees everything.
            const type = message.type
            if (
                this.isAnchor &&
                (type === 'state' ||
                    type === 'history' ||
                    type === 'event' ||
                    type === 'question' ||
                    type === 'question_resolved' ||
                    type === 'streaming_buffer' ||
                    type === 'error')
            ) {
                for (const client of Array.from(this.clients)) {
                    if (!client.authenticated) continue
                    if (client.selectedId !== null && client.selectedId !== this.entryId)
                        continue
                    if (!writeJson(client, message)) closeClient(this, client)
                }
                return
            }
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
        askAvailable() {
            return this.server !== null && (this.hasConnectedClients() || canPush())
        },
        async ask(opts) {
            if (!this.askAvailable()) return null
            cancelPendingAsk(this)
            const id = randomBytes(4).toString('hex')
            // Frame type is always 'question' for every ask: the old
            // 'questionnaire' frame type disappeared with the two-kind protocol.
            const message: JsonObject = {
                type: 'question',
                sessionId: sessionId(this),
                id,
                kind: opts.kind,
                params: opts.params,
            }
            const pending: PendingAsk = { id, kind: opts.kind, message, resolve: () => {} }
            this.pendingAsk = pending
            dbgLog('ask created:', id, opts.kind)
            notifyRcStatus(this)
            this.broadcast(message)
            fireQuestionPush(this)
            const askPromise = new Promise<RemoteAnswer[] | 'dismissed' | null>(resolve => {
                pending.resolve = result => {
                    if (this.pendingAsk === pending) {
                        this.pendingAsk = null
                        notifyRcStatus(this)
                    }
                    resolve(result)
                }
            })
            if (opts.signal) {
                // Identity guard: an abort that lands after this pending ask
                // already resolved (client answered first) or was superseded
                // must not cancel the NEW pending ask it no longer is.
                const onAbort = () => {
                    if (this.pendingAsk === pending) cancelPendingAsk(this)
                }
                if (opts.signal.aborted) onAbort()
                else opts.signal.addEventListener('abort', onAbort, { once: true })
            }
            return askPromise
        },
    }
    registerProcessExitHandler(state)
    globalRecord[RC_KEY] = state
    return state
}

// Cancels the in-flight ask (toggle-off, pi exit, supersede, abort signal):
// tells the clients it is gone and resolves the waiting caller. The default
// null preserves the legacy callers' semantics (esc-hatch fallthrough to the
// local prompt, supersede, toggle-off); the wire abort passes 'dismissed' so
// the ask tool reports the cancellation instead of falling back locally.
function cancelPendingAsk(
    state: RcSingleton,
    result: RemoteAnswer[] | 'dismissed' | null = null
): void {
    if (!state.pendingAsk) return
    dbgLog('ask cancelled:', state.pendingAsk.id)
    state.broadcast({
        type: 'question_resolved',
        id: state.pendingAsk.id,
        by: 'cancelled',
    })
    state.pendingAsk.resolve(result)
    state.pendingAsk = null
    notifyRcStatus(state)
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
        selectedId: null,
        attachedSubagentId: null,
        proxy: null,
        pendingProxyAuth: null,
        selectDeadlineAt: null,
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
    // Phone disconnect closes its proxies (spec: rc-multi-session-spec.md §Proxy
    // connection lifecycle). Must run BEFORE clients.delete so the cleanup can
    // still find the client.
    if (state.isAnchor && client.proxy !== null) closeProxyForClient(state, client)
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
        case 'steer':
        case 'abort':
        case 'answer':
        case 'get_state':
        case 'get_history':
        case 'command': {
            // Proxy transparency (spec: rc-multi-session-spec.md §Wire
            // protocol): while the phone has a non-anchor entry selected, its
            // session frames go VERBATIM to that sibling over the proxy —
            // prompt, steer, abort, answer, get_state, get_history, command
            // (all four command names). The sibling runs its own handlers and
            // the responses come back through the sibling→phone forward list.
            if (
                state.isAnchor &&
                client.selectedId !== null &&
                client.selectedId !== state.entryId
            ) {
                sendToProxy(client, message)
                break
            }
            // No active non-anchor selection: fall through to the anchor's
            // own handling of the same frame below.
            switch (message.type) {
                case 'prompt':
                    handlePrompt(state, client, message)
                    return
                case 'steer':
                    handleSteer(state, client, message)
                    return
                case 'abort':
                    // A pending ask owns the run: the ask tool cannot observe
                    // the agent-loop abort signal, so resolving the ask is the
                    // only way the tool returns. 'dismissed' (not null) makes
                    // the tool report the cancellation instead of falling
                    // through to the local TUI prompt, which would hold the
                    // run hostage on an unattended terminal. Owner decision:
                    // dismiss = cancel the question AND abort the run.
                    if (state.pendingAsk) cancelPendingAsk(state, 'dismissed')
                    if (!state.binding?.ctx.isIdle()) state.binding?.ctx.abort()
                    return
                case 'answer':
                    handleAnswer(state, client, message)
                    return
                case 'get_state':
                    writeJson(client, buildState(state))
                    return
                case 'get_history':
                    writeJson(
                        client,
                        buildHistory(
                            state,
                            typeof message.cursor === 'string' ? message.cursor : undefined
                        )
                    )
                    return
                case 'command':
                    void handleCommand(state, client, message)
                    return
            }
            return
        }
        case 'ping':
            // The phone's keepalive stays with the anchor (never forwarded):
            // the anchor answers it and keeps the proxy alive with its OWN
            // 30 s pings (spec: rc-multi-session-spec.md §Proxy connection
            // lifecycle).
            writeJson(client, { type: 'pong' })
            break
        case 'push_token':
            handlePushToken(state, client, message)
            break
        case 'select_session':
            // Anchor-only by construction: the phone only ever connects to the
            // anchor (port 47800); a sibling's loopback server is unreachable
            // off-box, so this case cannot fire on a sibling (task contract).
            selectSession(state, client, stringFrom(message.id) ?? '')
            break
        case 'get_subagents':
        case 'attach_subagent':
        case 'detach_subagent': {
            // Feature B: anchor-only by construction, like select_session. A
            // NEW phone may reach an OLD rc (extensions load at pi start):
            // those requests land here only because the phone checks the
            // hello_ok capability first; pre-gate restarts answer
            // invalid_message, which the Swift side treats as "no support".
            if (message.type === 'get_subagents') sendSubagentsToClient(state, client)
            else if (message.type === 'attach_subagent')
                handleAttachSubagent(state, client, message)
            else handleDetachSubagent(state, client, message)
            break
        }
        default:
            writeJson(client, { type: 'error', code: 'invalid_message' })
    }
}

// Timing-safe comparison of a presented token against the one currently in
// rc-push.json — read fresh per hello (never cached): a process started
// before the phone paired must auto-authenticate once the token lands (N1).
// Length checked first because timingSafeEqual throws on unequal lengths.
function helloTokenMatches(presented: string): boolean {
    const registered = readStoredDeviceToken()
    if (registered === null || presented.length !== registered.length) return false
    // Tokens are stored lowercase (write-point normalization); lowercase the
    // presented side too so casing differences never fail auto-auth.
    return timingSafeEqual(Buffer.from(presented.toLowerCase()), Buffer.from(registered))
}

function handleHello(state: RcSingleton, client: RcClient, message: JsonObject): void {
    cleanupRateLimits(state)
    if (message.version !== VERSION) {
        sendErrorAndClose(state, client, 'version_mismatch')
        return
    }
    // Loopback clients are never rate-limited: the limiter exists for tailnet
    // strangers, and the only loopback client is the anchor proxy (a failed
    // proxy hello would otherwise lock out all proxy connects to this
    // process for RATE_LIMIT_LOCK_MS).
    const loopback = client.ip === '127.0.0.1' || client.ip === '::1'
    if (!loopback) {
        const limit = state.rateLimits.get(client.ip)
        if (limit && limit.lockedUntil > Date.now()) {
            sendErrorAndClose(state, client, 'rate_limited')
            return
        }
    }
    const code = typeof message.code === 'string' ? message.code : ''
    const token = typeof message.token === 'string' ? message.token : ''
    // A client presenting the currently registered push token authenticates
    // without a fresh code: the code is re-randomized every pi session, so
    // without this every session would force re-pairing of an already-paired
    // device. First-time pairing (no token registered yet) still requires
    // the code; a stale code plus a matching token is the auto-auth path.
    // The entry token is the third credential: it lets the anchor's proxy
    // connect to this process (spec: rc-multi-session-spec.md §Registry).
    const codeOk = /^[0-9]{6}$/.test(code) && code === state.code
    const tokenOk = helloTokenMatches(token)
    const entryTokenOk = entryTokenMatches(state, token)
    if (!codeOk && !tokenOk && !entryTokenOk) {
        if (!loopback) recordFailedHello(state, client.ip)
        const failed = state.rateLimits.get(client.ip)
        sendErrorAndClose(
            state,
            client,
            failed && failed.lockedUntil > Date.now() ? 'rate_limited' : 'bad_code'
        )
        return
    }
    if (!loopback) state.rateLimits.delete(client.ip)
    client.authenticated = true
    refreshStatus(state)
    writeJson(client, { type: 'hello_ok', version: VERSION, features: ['subagents'] })
    // The phone builds its picker from this; a fresh connect (or the anchor
    // proxy's connect, whose reader ignores it) must not wait for a registry
    // change to see the list.
    if (state.isAnchor) sendSessions(client)
    writeSessionSnapshot(client, state)
    // Feature B: the attach picker is part of the connect snapshot burst —
    // the phone's session view must not wait for a lifecycle event to see
    // live runs (and an empty list still means "clear stale state").
    sendSubagentsToClient(state, client)
    if (state.pendingAsk) writeJson(client, state.pendingAsk.message)
}

// Same timing-safe pattern as helloTokenMatches, against the registry entry
// token (32-byte hex, generated at registration; never lowercased — the
// presented side is hex and the comparison is byte-for-byte).
function entryTokenMatches(state: RcSingleton, presented: string): boolean {
    const registered = state.entryToken
    if (registered === null || presented.length !== registered.length) return false
    return timingSafeEqual(Buffer.from(presented), Buffer.from(registered))
}

function handleAnswer(state: RcSingleton, client: RcClient, message: JsonObject): void {
    const pending = state.pendingAsk
    if (!pending || pending.kind !== 'ask_user_question' || pending.id !== message.id) {
        writeJson(client, { type: 'error', code: 'unknown_question' })
        return
    }
    const raw = message.answers
    if (!Array.isArray(raw)) {
        writeJson(client, { type: 'error', code: 'invalid_message' })
        return
    }
    const answers: RemoteAnswer[] = []
    for (const item of raw) {
        if (!isRemoteAnswer(item)) {
            writeJson(client, { type: 'error', code: 'invalid_message' })
            return
        }
        answers.push(item)
    }
    pending.resolve(answers)
    dbgLog('ask resolved by client:', pending.id)
    // For a single-question ask the resolution broadcast carries that answer's
    // value — the Swift transcript rendering depends on it; multi-question
    // asks omit it (the full answer set lives in the tool result).
    const questionCount = pendingQuestionCount(pending)
    state.broadcast({
        type: 'question_resolved',
        id: pending.id,
        by: 'client',
        ...(questionCount === 1 ? { value: answers[0].value } : {}),
    })
}

function isRemoteAnswer(value: unknown): value is RemoteAnswer {
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

function pendingQuestionCount(pending: PendingAsk): number {
    const params = pending.message.params
    return isObject(params) ? safeArray(params.questions).length : 0
}

// APNs device tokens are 64 hex chars. Anything else is ignored silently:
// no error frame, no close, no state change (spec: wire protocol, push_token).
function handlePushToken(state: RcSingleton, client: RcClient, message: JsonObject): void {
    let token = message.token
    if (typeof token !== 'string' || !/^[0-9a-f]{64}$/i.test(token)) {
        dbgLog('push_token ignored (invalid):', client.ip)
        return
    }
    // Normalize at the single write point so the stored token is always
    // lowercase (readStoredDeviceToken lowercases on read as well, and
    // helloTokenMatches lowercases the presented side before comparing).
    token = token.toLowerCase()
    // The file (rc-push.json) is the single source of truth: every process on
    // the box resolves the token from it at use time, so this registration
    // reaches siblings that started before the phone paired (N1).
    saveDeviceToken(token)
    refreshStatus(state)
    dbgLog('push_token registered:', client.ip)
}

// INV1: pushes only in interactive modes. Subagent children run json/print mode
// and would otherwise fire a push per settled turn, and the opened APNs session
// would pin the event loop and hang the child (the B1 hang).
function pushAllowed(state: RcSingleton): boolean {
    const mode = state.binding?.ctx?.mode
    return mode === 'tui' || mode === 'rpc'
}

function fireFinishedPush(state: RcSingleton): void {
    if (!pushAllowed(state)) return
    // Pushes follow the /rc toggle: finished pings are only useful while the
    // remote-control session is live, matching the question-push gate (ask
    // requires a serving server via askAvailable).
    if (!state.isServing()) return
    // Resolved from rc-push.json at push time (N1): a sibling started before
    // the phone paired must push once the token file exists.
    const token = readStoredDeviceToken()
    if (!token) return
    void sendApnsPush(
        token,
        finishedCollapseId(sessionId(state)),
        finishedPayload(sessionId(state), finishedBody(state))
    )
        .then(outcome => handlePushOutcome(state, outcome, 'finished', token))
        .catch(error => dbgLog('apns finished push failed:', errorMessage(error)))
}

// The first question's prompt — the question push body per the 2026-09-07
// decision. Returns undefined when no text can be extracted; questionBody
// then falls back to the fixed string.
function pendingAskText(pending: PendingAsk | null): string | undefined {
    if (!pending) return undefined
    const params = pending.message.params
    if (!isObject(params)) return undefined
    const first = safeArray(params.questions)[0]
    if (isObject(first) && typeof first.prompt === 'string') return first.prompt
    return undefined
}

function fireQuestionPush(state: RcSingleton): void {
    if (!pushAllowed(state)) return
    // Resolved from rc-push.json at push time (N1), mirroring fireFinishedPush.
    const token = readStoredDeviceToken()
    if (!token) return
    // Capture the ask's identity BEFORE any await: if it is answered,
    // cancelled, or superseded while the body resolves (LLM shortening can
    // take up to the timeout), the push is dropped — a "has a question"
    // alert for a dead question would be wrong.
    const pending = state.pendingAsk
    void questionBody(pendingAskText(pending))
        .then(body => {
            if (state.pendingAsk !== pending) return
            return sendApnsPush(
                token,
                questionCollapseId(sessionId(state)),
                questionPayload(sessionId(state), body)
            ).then(outcome => handlePushOutcome(state, outcome, 'question', token))
        })
        .catch(error => dbgLog('apns question push failed:', errorMessage(error)))
}

function handlePushOutcome(
    state: RcSingleton,
    outcome: PushOutcome,
    label: string,
    token: string
): void {
    // Only clear the token if the file still holds the one APNs rejected:
    // a newer registration that landed while this send was in flight must
    // survive (re-read at outcome time, not the pre-send value).
    if (outcome.ok === 'dropped' && readStoredDeviceToken() === token) {
        saveDeviceToken(null)
        recordPushOutcome(state, outcome)
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
        recordPushOutcome(state, outcome)
        return
    }
    dbgLog('apns push outcome:', label, outcome)
    recordPushOutcome(state, outcome)
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
    // Reconnect dedupe (spec Feature A): the committed turn's text/thinking
    // and finished tool carriers are already in the branch history, so the
    // snapshot buffer is pruned to what the client genuinely lacks. This
    // frame builder is the single choke point of both snapshot emitters, so
    // no other prune hook is needed.
    const branch = safeArray(state.binding?.ctx.sessionManager.getBranch())
    const tail = tailClassification(branch[branch.length - 1])
    return {
        type: 'streaming_buffer',
        sessionId: sessionId(state),
        content: pruneBufferForSnapshot(state.currentTurnBuffer, tail),
    }
}

function handlePrompt(state: RcSingleton, client: RcClient, message: JsonObject): void {
    if (typeof message.text !== 'string') {
        writeJson(client, { type: 'error', code: 'invalid_message' })
        return
    }
    const binding = state.binding
    if (!binding) {
        writeJson(client, { type: 'error', code: 'not_ready' })
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
        writeJson(client, { type: 'error', code: 'not_ready' })
        return
    }
    try {
        if (binding.ctx.isIdle()) {
            // Idle: sent as a plain prompt and persisted immediately — nothing to track.
            binding.pi.sendUserMessage(message.text)
        } else {
            // Queued in pi's in-memory steering queue: invisible to the session
            // branch until the agent loop delivers it, so mirror it in
            // pendingSteers (removed on delivery in trackEvent, surfaced as the
            // optional `pending` field on history frames).
            binding.pi.sendUserMessage(message.text, { deliverAs: 'steer' })
            state.pendingSteers.push(message.text)
        }
    } catch (error) {
        writeJson(client, { type: 'error', code: 'send_failed', message: errorMessage(error) })
    }
}

// ── Remote commands (spec: rc-commands-spec.md) ─────────────────────

let commandInFlight = false

async function handleCommand(
    state: RcSingleton,
    client: RcClient,
    message: JsonObject
): Promise<void> {
    const command = stringFrom(message.command as string)
    if (!command) {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }
    const binding = state.binding
    if (!binding) {
        writeJson(client, { type: 'error', code: 'not_ready' })
        return
    }
    if (commandInFlight) {
        writeJson(client, { type: 'error', code: 'not_ready' })
        return
    }
    try {
        switch (command) {
            case 'new':
                await handleCommandNew(state, client)
                break
            case 'set_model':
                await handleCommandSetModel(state, client, binding, message)
                break
            case 'compact':
                // A second ctx.compact would queue a second summarization pass on the
                // same branch — reject while the compacting window is open. A genuine
                // failure still surfaces via the session_compact_failed broadcast.
                if (state.compacting) {
                    writeJson(client, {
                        type: 'error',
                        code: 'command_failed',
                        message: 'compact already in progress',
                    })
                    break
                }
                handleCommandCompact(binding, message)
                break
            case 'name':
                handleCommandName(binding, client, message)
                break
            default:
                writeJson(client, { type: 'error', code: 'unknown_command' })
        }
    } catch (error) {
        const msg = errorMessage(error)
        // Pin: text-match on pi 0.85.1's ExtensionRunner.invalidate() message
        // ("...ctx is stale after..."); no error type is exposed, so the word
        // 'stale' is the only seam — if pi rewords it, this silently falls to
        // command_failed below. Group-14 command_new_stale_after_rpc_replacement
        // pins the mapped code.
        if (msg.includes('stale')) {
            writeJson(client, {
                type: 'error',
                code: 'stale_session',
                message: 'Session replaced outside rc — run /rc in the terminal to recover',
            })
        } else {
            writeJson(client, {
                type: 'error',
                code: 'command_failed',
                message: msg.slice(0, 200),
            })
        }
    }
}

async function handleCommandNew(state: RcSingleton, client: RcClient): Promise<void> {
    const cmdCtx = state.commandCtx
    if (!cmdCtx || typeof cmdCtx.newSession !== 'function') {
        writeJson(client, {
            type: 'error',
            code: 'stale_session',
            message: 'Session replaced outside rc — run /rc in the terminal to recover',
        })
        return
    }
    commandInFlight = true
    try {
        const result = await cmdCtx.newSession({
            withSession: fresh => {
                state.commandCtx = fresh
            },
        })
        if (isObject(result) && result.cancelled === true) {
            writeJson(client, {
                type: 'error',
                code: 'command_failed',
                message: 'New session cancelled before it could run',
            })
        }
    } finally {
        commandInFlight = false
    }
}

async function handleCommandSetModel(
    state: RcSingleton,
    client: RcClient,
    binding: Binding,
    message: JsonObject
): Promise<void> {
    const provider = stringFrom(message.provider as string)
    const modelId = stringFrom(message.modelId as string)
    if (!provider || !modelId) {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }
    const model = binding.ctx.modelRegistry?.find?.(provider, modelId)
    if (!model) {
        writeJson(client, { type: 'error', code: 'model_not_found' })
        return
    }
    const ok = await binding.pi.setModel(model)
    if (!ok) {
        writeJson(client, { type: 'error', code: 'model_not_set' })
    }
}

function handleCommandCompact(binding: Binding, message: JsonObject): void {
    const raw = message.instructions
    const instructions = typeof raw === 'string' ? raw.trim() : undefined
    binding.ctx.compact(instructions ? { customInstructions: instructions } : undefined)
}

function handleCommandName(binding: Binding, client: RcClient, message: JsonObject): void {
    const raw = message.name
    if (typeof raw !== 'string') {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }
    const trimmed = raw.trim()
    if (trimmed.length === 0) {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }
    binding.pi.setSessionName(trimmed)
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
    const scopedModels = safeArray(ctx?.scopedModels)
    const catalogModels =
        scopedModels.length > 0
            ? scopedModels
            : safeArray(ctx?.modelRegistry?.getAvailable?.())
    const models = catalogModels.filter(isObject).map(m => {
        // Scoped entries are nested ({model, thinkingLevel?}); the unscoped
        // catalog is flat ModelInfo — un-nest so both shapes map correctly.
        const inner = isObject(m.model) ? m.model : m
        return {
            provider:
                stringFrom(inner.provider) ??
                stringFrom(inner.providerId) ??
                stringFrom(inner.providerName) ??
                'unknown',
            id:
                stringFrom(inner.id) ??
                stringFrom(inner.model) ??
                stringFrom(inner.name) ??
                'unknown',
        }
    })
    return {
        type: 'state',
        sessionId: sessionId(state),
        cwd: ctx?.cwd ?? process.cwd(),
        ...(sessionName(state) ? { sessionName: sessionName(state) } : {}),
        model: { provider, id },
        ...(ctx?.thinkingLevel ? { thinkingLevel: ctx.thinkingLevel } : {}),
        isStreaming: ctx ? !ctx.isIdle() : state.isStreaming,
        ...(state.compacting ? { compacting: state.compacting } : {}),
        ...(usage &&
        usage.tokens !== null &&
        usage.contextWindow !== null &&
        usage.percent !== null
            ? {
                  contextUsage: {
                      tokens: usage.tokens,
                      contextWindow: usage.contextWindow,
                      percent: usage.percent,
                  },
              }
            : {}),
        ...(models.length > 0 ? { models } : {}),
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
        // Queued-but-undelivered steers are not in the branch yet; the optional
        // field (absent when empty) keeps them visible to (re)connecting clients
        // without a protocol version bump.
        ...(state.pendingSteers.length > 0 ? { pending: [...state.pendingSteers] } : {}),
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
    pi.on('session_start', (event, ctx) => {
        // New session = new agent = empty steering queue AND no compaction
        // (the old session is disposed, aborting anything in flight). Clear
        // BEFORE the forwarded session_start triggers broadcastSessionSnapshot,
        // which must not carry stale entries from the old session.
        state.pendingSteers.length = 0
        state.compacting = null
        // Feature B: an in-process /new changes the anchor session — attaches
        // and per-run in-flight state belong to the old session and die with
        // it (the run's files survive on disk, just out of scope).
        for (const client of state.clients) client.attachedSubagentId = null
        state.subagentRunState.clear()
        forward('session_start', event, ctx)
        // forward() rebinds to the new ctx; this (debounced) is what updates
        // the entry's sessionId/name/cwd/model after an in-process /new.
        notifyRcStatus(state)
        // The new session has no live runs yet — clear the phones' pickers.
        broadcastSubagents(state)
    })
    pi.on('session_shutdown', async (event, ctx) => {
        state.compacting = null
        if (event.reason === 'quit') {
            state.bind(pi, ctx)
            await state.stop('quit', 'pi shutdown')
        } else {
            // Non-quit (new/resume/fork): the old ctx is about to be
            // invalidated; null the binding so handlers return not_ready
            // instead of dereferencing a stale ctx. The entry survives the
            // replacement (process-level), so schedule a flush here: the
            // follow-up session_start (immediate in the /new flow) coalesces
            // into the same debounce and the flush carries the NEW sessionId.
            notifyRcStatus(state)
            state.binding = null
        }
    })
    pi.on('agent_start', (event, ctx) => forward('agent_start', event, ctx))
    pi.on('agent_settled', (event, ctx) => {
        // Reconcile against pi's live queue before forwarding the settle. An
        // aborted run with a queued steer auto-continues and drains the queue
        // BEFORE this settle, so a non-empty queue here means a residual steer
        // (arrived after the post-run check), a TUI clearQueue, or follow-ups —
        // clear exactly when pi reports nothing pending, keep the list when it
        // does (delivered steers were already removed on their message_start).
        if (!ctx.hasPendingMessages()) state.pendingSteers.length = 0
        forward('agent_settled', event, ctx)
    })
    pi.on('turn_end', (event, ctx) => {
        forward('turn_end', event, ctx)
        notifyRcStatus(state)
    })
    pi.on('message_start', (event, ctx) => forward('message_start', event, ctx))
    pi.on('message_update', (event, ctx) => forward('message_update', event, ctx))
    // Not forwarded: message_end would widen the frozen wire protocol; it is
    // tracked only for the abort gate (turn_end is already forwarded).
    pi.on('message_end', (event, ctx) => {
        state.bind(pi, ctx)
        trackEvent(state, 'message_end', event)
    })
    pi.on('tool_execution_start', (event, ctx) => forward('tool_execution_start', event, ctx))
    pi.on('tool_execution_update', (event, ctx) =>
        forward('tool_execution_update', event, ctx)
    )
    pi.on('tool_execution_end', (event, ctx) => forward('tool_execution_end', event, ctx))
    // Compaction visibility (spec: rc-compaction-visibility-spec.md D2). The
    // snapshot (state + history) is re-broadcast on finish because the
    // compaction entry changes the branch; before_compact only needs the
    // state broadcast (clients already have the history).
    pi.on('session_before_compact', (event, ctx) => {
        state.bind(pi, ctx)
        if (!isObject(event)) return
        state.compacting = {
            reason:
                event.reason === 'threshold' || event.reason === 'overflow'
                    ? event.reason
                    : 'manual',
            ...(typeof event.willRetry === 'boolean' ? { willRetry: event.willRetry } : {}),
        }
        dbgLog('compaction started:', state.compacting.reason)
        notifyRcStatus(state)
        state.broadcast(buildState(state))
    })
    pi.on('session_compact', (event, ctx) => {
        state.bind(pi, ctx)
        dbgLog('compaction finished:', isObject(event) ? event.reason : 'unknown')
        state.compacting = null
        notifyRcStatus(state)
        broadcastSessionSnapshot(state)
    })
    pi.on('session_compact_failed', (event, ctx) => {
        state.bind(pi, ctx)
        const aborted = isObject(event) && event.aborted === true
        const message =
            isObject(event) &&
            typeof event.errorMessage === 'string' &&
            event.errorMessage.length > 0
                ? event.errorMessage
                : 'compaction failed'
        dbgLog('compaction failed:', aborted ? 'aborted (user Stop)' : message)
        state.compacting = null
        notifyRcStatus(state)
        broadcastSessionSnapshot(state)
        // D3: an aborted compaction was the user's own Stop — the banner
        // clearing above is the feedback, no error frame. A genuine failure
        // additionally surfaces as an error frame for the phone toast.
        if (!aborted) state.broadcast({ type: 'error', code: 'compaction_failed', message })
    })
    pi.on('model_select', (_event, ctx) => {
        state.bind(pi, ctx)
        notifyRcStatus(state)
        state.broadcast(buildState(state))
    })
    pi.on('session_info_changed', (_event, ctx) => {
        state.bind(pi, ctx)
        notifyRcStatus(state)
        state.broadcast(buildState(state))
    })
    // Feature B: the subagent extension emits 'subagent:event' for EVERY
    // child stdout event on the cross-extension bus (payload {subagentId,
    // agent, event}, event name = event.type). The subscription is idempotent
    // across pi re-bindings (the rc(pi) registration itself runs once per pi
    // instance, but the guard keeps a re-registration from double-forwarding).
    subscribeSubagentBus(pi, state)
}

let subagentBusSubscribed = false

function subscribeSubagentBus(pi: ExtensionAPI, state: RcSingleton): void {
    if (subagentBusSubscribed) return
    subagentBusSubscribed = true
    pi.events.on('subagent:event', data => {
        handleSubagentBusEvent(state, data)
    })
}

function trackEvent(state: RcSingleton, name: string, event: unknown): void {
    if (name === 'agent_start') {
        state.isStreaming = true
        state.lastStopReason = null
        notifyRcStatus(state)
    }
    if (name === 'agent_settled') {
        state.isStreaming = false
        notifyRcStatus(state)
        // Aborted runs settle too, but the user cancelled — no "finished" ping.
        if (state.lastStopReason === 'aborted') return
        // Fires on every settled turn by design; the constant collapse id
        // dedupes at APNs, so the latest settle is the one delivered.
        fireFinishedPush(state)
    }
    if (
        isObject(event) &&
        isObject(event.message) &&
        typeof event.message.stopReason === 'string'
    ) {
        if (name === 'turn_end' || name === 'message_end')
            state.lastStopReason = event.message.stopReason
    }
    if (
        name === 'message_start' &&
        isObject(event) &&
        isObject(event.message) &&
        event.message.role === 'assistant'
    ) {
        state.currentTurnBuffer = []
    }
    if (
        name === 'message_start' &&
        isObject(event) &&
        isObject(event.message) &&
        event.message.role === 'user'
    ) {
        // message_start is the steer-delivery signal: the steer has left pi's
        // queue (it lands in the branch on the paired message_end). Remove only
        // the FIRST match so duplicate steer texts stay consistent.
        const text = textFromMessage(event.message)
        const index = state.pendingSteers.indexOf(text)
        if (index !== -1) state.pendingSteers.splice(index, 1)
    }
    if (name === 'message_update' && isObject(event))
        appendAssistantDelta(state.currentTurnBuffer, event.assistantMessageEvent)
    if (name === 'tool_execution_start' && isObject(event)) {
        state.currentTurnBuffer.push({
            type: 'toolUse',
            toolCallId: stringFrom(event.toolCallId) ?? '',
            toolName: stringFrom(event.toolName) ?? 'tool',
            args: isObject(event.args) ? event.args : {},
        })
    }
    if (name === 'tool_execution_update' && isObject(event))
        updateToolOutput(state.currentTurnBuffer, event)
    if (name === 'tool_execution_end' && isObject(event))
        updateToolOutput(state.currentTurnBuffer, event)
    if (name === 'turn_end') state.currentTurnBuffer = []
}

// Buffer parameterized (not state-bound): the main session passes
// state.currentTurnBuffer; Feature B passes one per subagent run, so both
// share the exact same delta/tool-output semantics.
function appendAssistantDelta(buffer: ContentBlock[], assistantEvent: unknown): void {
    if (!isObject(assistantEvent)) return
    const type = stringFrom(assistantEvent.type)
    const delta = stringFrom(assistantEvent.delta) ?? stringFrom(assistantEvent.text) ?? ''
    const index =
        typeof assistantEvent.contentIndex === 'number'
            ? assistantEvent.contentIndex
            : buffer.length
    if (type === 'text_delta' || type === 'thinking_delta') {
        const blockType = type === 'thinking_delta' ? 'thinking' : 'text'
        let block = buffer[index]
        if (!block || block.type !== blockType) {
            block = { type: blockType, text: '' } as ContentBlock
            buffer[index] = block
        }
        if (block.type !== 'toolUse') block.text += delta
    } else if (type === 'toolcall_delta') {
        let block = buffer[index]
        if (!block || block.type !== 'toolUse') {
            block = { type: 'toolUse', toolCallId: '', toolName: 'tool', args: {} }
            buffer[index] = block
        }
        if (block.type === 'toolUse' && delta.length > 0)
            block.output = `${block.output ?? ''}${delta}`
    }
    for (let i = buffer.length - 1; i >= 0; i--) if (!buffer[i]) buffer.splice(i, 1)
}

function updateToolOutput(buffer: ContentBlock[], event: JsonObject): void {
    const toolCallId = stringFrom(event.toolCallId)
    const block = [...buffer]
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
    return (
        (
            state.binding?.ctx.sessionManager as { getSessionId?: () => string }
        )?.getSessionId?.() ?? 'unknown'
    )
}

function sessionName(state: RcSingleton): string | undefined {
    const managerName = state.binding?.ctx.sessionManager.getSessionName?.()
    return managerName ?? undefined
}

function resolveBindHost(): string {
    const override = process.env.PI_RC_BIND?.trim()
    if (override) return override
    const candidates: { name: string; address: string }[] = []
    for (const [name, infos] of Object.entries(networkInterfaces())) {
        if (!infos) continue
        for (const info of infos) {
            if (info.family !== 'IPv4') continue
            // Tailscale assigns addresses from the CGNAT range 100.64.0.0/10.
            const [first, second] = info.address.split('.').map(Number)
            if (first === 100 && second >= 64 && second <= 127) {
                candidates.push({ name, address: info.address })
            }
        }
    }
    const match = candidates.find(c => c.name.startsWith('utun')) ?? candidates[0]
    if (match) return match.address
    throw new Error(
        'could not determine tailnet IP: no IPv4 address in 100.64.0.0/10 found on any interface (is Tailscale running? set PI_RC_BIND to override)'
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

// Push sendability for ask() routing. A registered token alone is not enough:
// with unresolved credentials the question push would silently no-op and the
// ask would block forever, so the local fallback must stay. Token and creds
// are resolved from their files per call (the phone can pair, or /rc push-setup
// can rewrite creds, while the server is serving), so readiness is never
// cached at startup.
function canPush(): boolean {
    return readStoredDeviceToken() !== null && resolveApnsConfig() !== null
}

function pushStatusText(): string {
    if (!resolveApnsConfig()) return 'push: not configured'
    return readStoredDeviceToken() ? 'push ok' : 'push: no token'
}

function pushOutcomeText(outcome: PushOutcome): string {
    if (outcome.ok === 'sent')
        return `apns ${outcome.status}${outcome.reason ? ` ${outcome.reason}` : ''}`
    if (outcome.ok === 'disabled') return `apns disabled: ${outcome.reason}`
    if (outcome.ok === 'dropped')
        return `apns ${outcome.status}${outcome.reason ? ` ${outcome.reason}` : ''} (token dropped)`
    const detail =
        outcome.detail.length > 48 ? `${outcome.detail.slice(0, 48)}…` : outcome.detail
    return `apns error: ${detail}`
}

function recordPushOutcome(state: RcSingleton, outcome: PushOutcome): void {
    state.lastPush = pushOutcomeText(outcome)
    refreshStatus(state)
}

function buildRcInspectReport(state: RcSingleton): string {
    const mode = state.binding?.ctx?.mode ?? 'unbound'
    const lines: string[] = [`rc status (live singleton, pid ${process.pid})`]
    lines.push(`mode: ${mode}`)
    if (state.server && state.host && state.code) {
        const clients = connectedClientCount(state)
        // The pairing code is human-only knowledge (typed on the phone
        // keypad): the full secret must never land in LLM context, where a
        // prompt-injected agent with network access could read host:port:code
        // and pair a rogue client. Agents can check status without it.
        const maskedCode = `•••${state.code.slice(-2)}`
        lines.push(`serving: ws://${state.host}:${state.port} code ${maskedCode}`)
        lines.push(`role: ${state.isAnchor ? 'anchor' : 'sibling (loopback)'}`)
        lines.push(`registry entry: ${state.entryId ?? 'none'}`)
        lines.push(`clients: ${clients === 0 ? 'none' : String(clients)}`)
    } else {
        lines.push('serving: no')
    }
    lines.push(`push: ${pushStatusText()}`)
    lines.push(`last apns: ${state.lastPush ?? 'none'}`)
    lines.push(`pending question: ${state.pendingAsk ? 'yes' : 'no'}`)
    lines.push(
        'note: rc-auth.json is a test-harness seam (written only when PI_RC_AUTH_FILE is set) — never read it for live status'
    )
    return lines.join('\n')
}

function refreshStatus(state: RcSingleton): void {
    if (!state.server || !state.host || !state.code) return
    const clients = connectedClientCount(state)
    const clientsText =
        clients === 0 ? 'no clients' : `${clients} client${clients === 1 ? '' : 's'}`
    const lastPush = state.lastPush ? ` · ${state.lastPush}` : ''
    safeSetStatus(
        state.binding?.ctx,
        `rc: ws://${state.host}:${state.port} code ${state.code} · ${clientsText} · ${pushStatusText()}${lastPush}`
    )
}

function registerProcessExitHandler(state: RcSingleton): void {
    if (state.processHooksRegistered) return
    state.processHooksRegistered = true
    process.once('exit', () => {
        if (state.server || state.code) writeQuitStoppedAuth(state)
        // Covers any path that exits without /rc disable (stop() already
        // removed the entry, so this is a no-op then); entryId null (never
        // enabled) is also a no-op.
        if (state.entryId !== null) removeEntry(state.entryId)
    })
}

// ── Registry entry lifecycle (spec: rc-multi-session-spec.md) ───────────────

// Rebuilds the full registry entry from live singleton state. Called on
// registration and from every status-change point through notifyRcStatus.
function currentRcEntry(state: RcSingleton): RcSessionEntry | null {
    const id = state.entryId
    const token = state.entryToken
    if (id === null || token === null) return null
    const ctx = state.binding?.ctx
    // Same field resolution as buildState's model mapping, so the registry
    // never disagrees with the wire state frame.
    const modelRef = ctx?.model as JsonObject | undefined
    const model: RcModelRef = {
        provider:
            stringFrom(modelRef?.provider) ??
            stringFrom(modelRef?.providerId) ??
            stringFrom(modelRef?.providerName) ??
            'unknown',
        id:
            stringFrom(modelRef?.id) ??
            stringFrom(modelRef?.model) ??
            stringFrom(modelRef?.name) ??
            'unknown',
    }
    const cwd = stringFrom(ctx?.cwd) ?? process.cwd()
    const name =
        sessionName(state) ??
        cwd
            .split('/')
            .filter(part => part.length > 0)
            .pop() ??
        cwd
    const pending = state.pendingAsk
    return {
        id,
        port: state.port,
        pid: process.pid,
        host: state.host ?? '127.0.0.1',
        token,
        isAnchor: state.isAnchor,
        sessionId: sessionId(state),
        cwd,
        name,
        model,
        isStreaming: state.isStreaming,
        // Spec invariant: the badge tracks the CURRENT session only. A stale
        // ask left over from a replaced session (pre-existing wart, frozen
        // Decision 7) must not light the badge.
        hasQuestion: pending !== null && pending.message.sessionId === sessionId(state),
        compacting: state.compacting !== null,
        lastActivity: new Date().toISOString(),
    }
}

// Creates this process's registry entry (both roles) and keeps the entry id
// and its proxy-auth token on the singleton.
function registerRcEntry(state: RcSingleton): void {
    if (state.entryId !== null) return
    state.entryId = newEntryId()
    state.entryToken = generateEntryToken()
    dbgLog('registry entry registered:', state.entryId, `port ${state.port}`)
    const entry = currentRcEntry(state)
    if (entry !== null) void upsertEntry(entry)
}

// Removes the entry and drops the proxy token. Idempotent (disable + exit both
// run this, and the exit hook also runs after a failed start that never
// registered).
function unregisterRcEntry(state: RcSingleton): void {
    if (state.entryId === null) return
    dbgLog('registry entry removed:', state.entryId)
    void removeEntry(state.entryId)
    state.entryId = null
    state.entryToken = null
}

let rcStatusDebounce: ReturnType<typeof setTimeout> | null = null

// The single status-sync path: coalesces bursts of state changes (a
// session_start snapshot, streaming flips, ask set/clear, ...) into one
// debounced registry write. The entry is rebuilt from live state at FLUSH
// time, never captured here — the merge-on-write rule in registry.ts relies
// on fresh reads happening after the debounce.
function notifyRcStatus(state: RcSingleton): void {
    if (state.entryId === null) return
    if (rcStatusDebounce) clearTimeout(rcStatusDebounce)
    rcStatusDebounce = setTimeout(() => {
        rcStatusDebounce = null
        const entry = currentRcEntry(state)
        if (entry === null) return
        void upsertEntry(entry)
    }, REGISTRY_DEBOUNCE_MS)
}

// ── Sessions list broadcast (anchor only; spec: rc-multi-session-spec.md) ─

// The phone-visible projection of a registry entry. Mapped field-by-field so
// the internal fields (port, pid, host, token) never reach the wire.
type RcSessionInfo = {
    id: string
    sessionId: string
    cwd: string
    name: string
    model: RcModelRef
    isStreaming: boolean
    hasQuestion: boolean
    compacting: boolean
    lastActivity: string
    isAnchor: boolean
}

function buildSessionsList(): RcSessionInfo[] {
    const registry = readRegistry()
    if (registry === null) return []
    return (
        registry.sessions
            .map(entry => ({
                id: entry.id,
                sessionId: entry.sessionId,
                cwd: entry.cwd,
                name: entry.name,
                model: entry.model,
                isStreaming: entry.isStreaming,
                hasQuestion: entry.hasQuestion,
                compacting: entry.compacting,
                lastActivity: entry.lastActivity,
                isAnchor: entry.isAnchor,
            }))
            // ISO-8601 UTC strings: lexicographic order is time order. Newest first.
            .sort((a, b) =>
                a.lastActivity === b.lastActivity
                    ? 0
                    : a.lastActivity < b.lastActivity
                      ? 1
                      : -1
            )
    )
}

// Sends the current list to one client without touching change detection.
// The per-client hello delivery and the anchor's broadcast path share the
// builder so the two can never disagree on the wire shape.
function sendSessions(client: RcClient): void {
    writeJson(client, { type: 'sessions', sessions: buildSessionsList() })
}

// Single-flight for the async callback: a prune pass probes every entry
// (up to ~500 ms per dead port), and the next watch/poll tick must not start
// a second pass before the first broadcast is decided.
let sessionsChangeInFlight = false

function onSessionsChange(state: RcSingleton): void {
    if (sessionsChangeInFlight) return
    sessionsChangeInFlight = true
    void (async () => {
        try {
            // Prune first (write-only-if-changed, so a no-op prune cannot
            // re-trigger this callback), then read the registry the prune
            // may have rewritten. The anchor self-excludes: its listener is
            // this process's own, bound to the tailnet interface (not
            // loopback), so a loopback probe of it would refuse.
            await pruneStaleEntries(state.entryId ?? undefined)
            // A failed proxy hello arms a retry on the NEXT registry change:
            // the sibling may have re-registered with a new token, and the
            // entry must be re-read at probe time, not at failure time
            // (spec: rc-multi-session-spec.md §Proxy connection lifecycle).
            retryPendingProxies(state)
            const list = buildSessionsList()
            const serialized = JSON.stringify(list)
            if (serialized === state.lastBroadcastSessions) return
            state.lastBroadcastSessions = serialized
            state.broadcast({ type: 'sessions', sessions: list })
        } catch (error) {
            dbgLog('sessions broadcast failed:', errorMessage(error))
        } finally {
            sessionsChangeInFlight = false
        }
    })()
}

function startSessionsWatcher(state: RcSingleton): void {
    // A restart must not skip the first change: reset the diff baseline so
    // the next callback re-broadcasts even an unchanged list.
    state.lastBroadcastSessions = null
    if (state.watcher) state.watcher.stop()
    state.watcher = watchRegistry(() => onSessionsChange(state))
}

function stopSessionsWatcher(state: RcSingleton): void {
    if (state.watcher) {
        state.watcher.stop()
        state.watcher = null
    }
    state.lastBroadcastSessions = null
}

// ── select_session + proxy (anchor only; spec: rc-multi-session-spec.md) ───────────
//
// The anchor brokers every local pi session to one phone connection
// (Decision 2). Selection is PER PHONE CONNECTION (RcClient.selectedId);
// a non-anchor selection holds a live WebSocket to that sibling
// (RcClient.proxy) through which the phone's session frames go verbatim and
// the sibling's frames are forwarded back. The proxy authenticates with the
// entry token read from the registry at open time — never from cache, the
// sibling may have re-registered with a new token.

// Sibling→phone forward list. sessionId rides on the frames, so no
// retagging. ping/pong are deliberately absent: the proxy keepalive is
// invisible to the phone (the proxy reader swallows pongs). session_done is
// forwarded because the phone's handleStateInfo rebinds on any state frame
// (the sibling's replacement session IS the new view).
const SIBLING_FORWARD_TYPES = new Set([
    'state',
    'history',
    'event',
    'question',
    'question_resolved',
    'streaming_buffer',
    'error',
    'session_done',
])

function clearProxyTimers(proxy: RcProxy): void {
    if (proxy.openTimer) clearTimeout(proxy.openTimer)
    if (proxy.keepalive) clearInterval(proxy.keepalive)
    proxy.openTimer = null
    proxy.keepalive = null
}

// Detaches and closes the proxy the client currently holds (re-select,
// phone disconnect, terminal failure). The sibling is not told WHY — a
// plain close is enough; its ask()/status logic is unaffected by a proxy
// client going away.
function closeProxyForClient(state: RcSingleton, client: RcClient): void {
    const proxy = client.proxy
    client.proxy = null
    client.pendingProxyAuth = null
    if (proxy === null) return
    clearProxyTimers(proxy)
    proxy.ws.onopen = null
    proxy.ws.onmessage = null
    proxy.ws.onerror = null
    proxy.ws.onclose = null
    try {
        if (proxy.ws.readyState === 0 || proxy.ws.readyState === 1) {
            proxy.ws.close(1000, 'client_deselect')
        }
    } catch (error) {
        dbgLog('proxy close failed:', errorMessage(error))
    }
}

// Phone→sibling: verbatim JSON over the proxy. A throw must never propagate
// into the phone's frame path — the send is best-effort on an OPEN socket.
function sendToProxy(client: RcClient, message: JsonObject): void {
    const proxy = client.proxy
    if (proxy === null) return
    try {
        if (proxy.ws.readyState === 1) proxy.ws.send(JSON.stringify(message))
    } catch (error) {
        dbgLog('proxy send failed:', errorMessage(error))
    }
}

// Phone-facing selection failure. `id` rides on the frame so the phone can
// clear `selectedId` exactly when the missing entry is the one it was
// viewing (spec: "session_not_found with id == selectedId clears
// selectedId").
function failSessionNotFound(client: RcClient, id: string): void {
    writeJson(client, { type: 'error', code: 'session_not_found', id })
}

// The select deadline: 10 s from the FIRST open attempt to the sibling's
// hello_ok (spec: §Wire protocol — select ack semantics). Keyed on the entry
// id, not the proxy object: a bad_code closes the proxy socket (client.proxy
// goes null) while the selection stays PENDING, and the deadline must outlive
// that window. A re-select or a terminal failure clears the matching
// markers, which disarms the timer when it eventually fires.
function failSelectTimeout(state: RcSingleton, client: RcClient, id: string): void {
    const stillPending =
        client.proxy !== null ? client.proxy.id === id : client.pendingProxyAuth === id
    if (!stillPending) return
    dbgLog('select timeout:', id, 'for', client.ip)
    client.selectedId = null
    client.pendingProxyAuth = null
    if (client.selectDeadlineAt) {
        clearTimeout(client.selectDeadlineAt)
        client.selectDeadlineAt = null
    }
    closeProxyForClient(state, client)
    failSessionNotFound(client, id)
    triggerSessionsRefresh(state)
}

// The one-shot auth retry (spec: "retry ONCE when the registry next
// changes… if it fails again, session_not_found + clear"). Consumes the
// pending marker BEFORE re-opening so a failing retry is terminal, not
// re-armed.
function retryPendingProxies(state: RcSingleton): void {
    for (const client of Array.from(state.clients)) {
        if (!client.authenticated) continue
        const id = client.pendingProxyAuth
        if (id === null) continue
        client.pendingProxyAuth = null
        openProxy(state, client, id, true)
    }
}

// Sibling→phone: exactly the forward list, verbatim; everything else
// (hello_ok, sessions, pong — and anything else a future sibling might send)
// is dropped. The frames already carry the sibling's sessionId, so the
// phone's sessionId guards adopt the view; no retagging.
function forwardToClient(state: RcSingleton, client: RcClient, message: JsonObject): void {
    if (!SIBLING_FORWARD_TYPES.has(message.type)) return
    if (!writeJson(client, message)) closeClient(state, client)
}

// Opens (or re-opens) the proxy for `id` on `client`. The entry is read
// FRESH at open time — the token must be the one the sibling currently
// answers, and a re-registration may have landed between the phone's select
// and now (spec: "re-read the entry at probe time, not at failure time").
// `retrying` marks the single registry-change re-attempt after a bad_code;
// a second bad_code is terminal.
function openProxy(state: RcSingleton, client: RcClient, id: string, retrying: boolean): void {
    const registry = readRegistry()
    if (registry === null) {
        // Corrupt registry: do NOT report the session as gone — an empty or
        // unparseable read must never look like "all sessions gone" (the
        // watch module's own invariant). Arm the retry slot so the next
        // registry change re-opens; the open timer bounds the wait.
        dbgLog('proxy open aborted: registry unparseable for', id)
        client.pendingProxyAuth = id
        return
    }
    const entry = registry.sessions.find(candidate => candidate.id === id)
    if (entry === undefined) {
        // The registry change that triggered a retry may have removed the
        // entry (sibling deregistered): terminal, nothing left to select.
        client.selectedId = null
        client.pendingProxyAuth = null
        if (client.selectDeadlineAt) {
            clearTimeout(client.selectDeadlineAt)
            client.selectDeadlineAt = null
        }
        failSessionNotFound(client, id)
        return
    }
    // Close any existing proxy for this client (re-select, or a retry
    // replacing a half-dead socket) before opening the fresh one. (This does
    // NOT clear the select deadline: it is selection-scoped, not
    // proxy-scoped, and a retry must not get a fresh 10 s.)
    closeProxyForClient(state, client)
    const ws = new globalThis.WebSocket(`ws://127.0.0.1:${entry.port}`)
    // Selection-scoped deadline: the first attempt starts the 10 s timer
    // (spec: from the select, not from each retry); a retry reuses the
    // still-pending one, so the total wait is bounded by one window.
    let openTimer: ReturnType<typeof setTimeout> | null
    if (retrying) {
        openTimer = client.selectDeadlineAt
    } else {
        if (client.selectDeadlineAt) clearTimeout(client.selectDeadlineAt)
        openTimer = setTimeout(
            () => failSelectTimeout(state, client, entry.id),
            SELECT_TIMEOUT_MS
        )
        client.selectDeadlineAt = openTimer
    }
    const proxy: RcProxy = {
        id: entry.id,
        ws,
        helloDone: false,
        authRetried: retrying,
        openTimer,
        keepalive: null,
    }
    client.proxy = proxy
    ws.onopen = () => {
        if (client.proxy !== proxy) return
        // The hello is the ONLY frame the anchor sends before hello_ok. The
        // entry token (read above, at open time) is the credential — the
        // sibling's handleHello accepts it as a third credential alongside
        // the 6-digit code and the push token. VERSION rides along so a
        // future protocol split fails loud, not silent.
        try {
            ws.send(JSON.stringify({ type: 'hello', version: VERSION, token: entry.token }))
        } catch (error) {
            dbgLog('proxy hello send failed:', errorMessage(error))
        }
    }
    ws.onmessage = event => {
        if (client.proxy !== proxy) return
        let message: unknown
        try {
            message = JSON.parse(String(event.data))
        } catch {
            return
        }
        if (!isObject(message) || typeof message.type !== 'string') return
        if (message.type === 'hello_ok') {
            // Selection confirmed: the sibling's snapshot burst (state +
            // history + streaming_buffer, sent by the sibling's own
            // handleHello immediately after this frame) IS the ack (spec:
            // no separate ack frame) and arrives over this socket as the
            // next frames — forwarded below, which re-bonds the phone to the
            // sibling's view. Mark selected FIRST so that forwarding is
            // enabled for them. Stop the select deadline and start the
            // keepalive that keeps the sibling's 90 s stale-close from
            // firing on an idle-but-selected proxy (the phone's own pings
            // stop at the anchor and never reach the sibling).
            proxy.helloDone = true
            const deadline = proxy.openTimer
            if (deadline) clearTimeout(deadline)
            proxy.openTimer = null
            if (client.selectDeadlineAt === deadline) client.selectDeadlineAt = null
            client.selectedId = proxy.id
            // Feature B: the attach is scoped to the client's effective
            // session — a sibling selection invalidates it (the run's events
            // no longer belong to the viewed session).
            client.attachedSubagentId = null
            client.pendingProxyAuth = null
            proxy.keepalive = setInterval(() => {
                try {
                    if (proxy.ws.readyState === 1)
                        proxy.ws.send(JSON.stringify({ type: 'ping' }))
                } catch (error) {
                    dbgLog('proxy keepalive failed:', errorMessage(error))
                }
            }, PROXY_KEEPALIVE_MS)
            return
        }
        if (message.type === 'pong') {
            // The proxy reader swallows pongs: never forwarded, never
            // toasted (spec: the proxy keepalive is invisible to the phone).
            return
        }
        if (message.type === 'error' && message.code === 'bad_code') {
            // Auth failure: NOT a retry loop. The first failure keeps the
            // selection PENDING and arms the one-shot registry-change retry
            // (the sibling may re-register with a new token); this proxy's
            // 10 s timer still bounds the wait. A failure on the retry is
            // terminal: session_not_found + clear.
            if (!proxy.authRetried) {
                // First failure: keep the FIRST attempt's deadline running
                // (it bounds how long the pending selection waits for the
                // registry change that may carry a fresh token) and arm the
                // one-shot retry.
                proxy.authRetried = true
                client.pendingProxyAuth = proxy.id
            } else {
                // The retry failed too: terminal (spec: no retry loop).
                client.selectedId = null
                client.pendingProxyAuth = null
                if (client.selectDeadlineAt) {
                    clearTimeout(client.selectDeadlineAt)
                    client.selectDeadlineAt = null
                }
                closeProxyForClient(state, client)
                failSessionNotFound(client, proxy.id)
                triggerSessionsRefresh(state)
            }
            return
        }
        if (client.selectedId === null) {
            // A session frame before hello_ok (out-of-order delivery): drop
            // it — the phone has not re-bonded to this view yet and the
            // snapshot burst carries the current state.
            return
        }
        forwardToClient(state, client, message)
    }
    ws.onclose = () => {
        if (client.proxy !== proxy) return
        client.proxy = null
        if (!proxy.helloDone) {
            // A connect that never hellos: the bad_code path re-armed the
            // retry, or the sibling wedged — either way there is no
            // selection to lose (selectedId is still null), so no frame to
            // the phone. Do NOT report session_gone. The select deadline
            // KEEPS RUNNING (it is the bound on the pending selection) and
            // no keepalive exists yet, so nothing is cleared here.
            return
        }
        // Sibling died mid-selection (spec: §Proxy connection lifecycle):
        // tell the phone, clear its selection, and refresh the list so the
        // picker drops the dead row. The select deadline was already cleared
        // by hello_ok, so there is nothing selection-scoped left to clean.
        clearProxyTimers(proxy)
        client.selectedId = null
        client.pendingProxyAuth = null
        writeJson(client, { type: 'session_gone', id: proxy.id })
        triggerSessionsRefresh(state)
    }
}

// The phone-facing entry point (case 'select_session'). Runs the validation
// ladder from the spec: (a) id not in a FRESH registry read → immediate
// session_not_found (no probe, no open); (b) id == the anchor's own entry →
// in-process switch (close any proxy, mark selected, re-send the anchor's
// snapshot to THIS client only); (c) a live sibling → open the proxy (dead
// port → synchronous prune + session_not_found, no 10 s wait).
function selectSession(state: RcSingleton, client: RcClient, id: string): void {
    if (!state.isAnchor) return
    const registry = readRegistry()
    if (registry === null) {
        dbgLog('select_session aborted: registry unparseable')
        return
    }
    const entry = registry.sessions.find(candidate => candidate.id === id)
    if (entry === undefined) {
        failSessionNotFound(client, id)
        return
    }
    // (b) the anchor's own session: a pure in-process switch, no proxy.
    if (entry.id === state.entryId) {
        closeProxyForClient(state, client)
        client.selectedId = entry.id
        client.pendingProxyAuth = null
        // Targeted at THIS client only (the spec's "re-send the anchor's own
        // snapshot to that client") — a broadcast would leak the switch to
        // every phone.
        writeSessionSnapshot(client, state)
        if (state.pendingAsk) writeJson(client, state.pendingAsk.message)
        return
    }
    // (c) a sibling: TCP-probe 127.0.0.1:port first (the 500 ms check in
    // registry.ts; loopback, never the entry's host). Dead → prune
    // synchronously and reply session_not_found — no 10 s wait (spec).
    void (async () => {
        const alive = await probePort(entry.port)
        if (!alive) {
            const result = removeEntry(entry.id)
            dbgLog('select_session pruned dead entry:', entry.id, result)
            failSessionNotFound(client, id)
            triggerSessionsRefresh(state)
            return
        }
        openProxy(state, client, id, false)
    })().catch(error => {
        dbgLog('select_session probe failed:', errorMessage(error))
        failSessionNotFound(client, id)
    })
}

// Re-broadcasts the sessions list after a selection outcome that changed the
// registry out-of-band (a synchronous prune on a dead select, a session_gone
// whose pruner rewrite has not re-triggered the watcher yet). Shares the
// watcher's diff baseline so an unchanged list is never re-sent; the
// watch/poll cycle remains the liveness path, this is only a latency cut.
function triggerSessionsRefresh(state: RcSingleton): void {
    const list = buildSessionsList()
    const serialized = JSON.stringify(list)
    if (serialized === state.lastBroadcastSessions) return
    state.lastBroadcastSessions = serialized
    state.broadcast({ type: 'sessions', sessions: list })
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

// ── Feature B: subagent attach (spec: 2026-09-13-rc-subagent-attach-stop-ux.md) ─
// The subagent extension writes its per-run files into getAgentDir()/subagents
// (verified: the pi-extensions repo's getSubagentsDir) — the GLOBAL agent
// directory, not per-session. The parentSessionId filter inside
// scanLiveSubagents is what scopes a scan to one session.
function subagentsDir(): string {
    return join(getAgentDir(), 'subagents')
}

function fsListSubagentFiles(dir: string): string[] {
    try {
        return readdirSync(dir)
    } catch {
        return []
    }
}

function fsReadSubagentFile(path: string): string {
    return readFileSync(path, 'utf8')
}

// kill(pid, 0) probes across processes (a child run is a separate pi process,
// same user). EPERM = "alive but not ours" — alive either way.
function isSubagentPidAlive(pid: number): boolean {
    try {
        process.kill(pid, 0)
        return true
    } catch (error) {
        return isObject(error) && error.code === 'EPERM'
    }
}

// The RECEIVING client's effective session (M3 fix: "current session"
// without the per-connection qualifier leaked the anchor's runs to a phone
// viewing a sibling). A sibling-selected client's runs still live in the
// same global directory, keyed by the sibling's sessionId from the registry.
function effectiveSessionId(state: RcSingleton, client: RcClient): string | null {
    if (client.selectedId === null || client.selectedId === state.entryId)
        return sessionId(state)
    const registry = readRegistry()
    if (registry === null) return null
    const entry = registry.sessions.find(candidate => candidate.id === client.selectedId)
    return entry?.sessionId ?? null
}

function scanEffectiveSubagents(
    state: RcSingleton,
    client: RcClient
): ScannedSubagent[] | null {
    const sessionId = effectiveSessionId(state, client)
    if (sessionId === null) return null
    return scanLiveSubagents({
        dir: subagentsDir(),
        sessionId,
        listFiles: fsListSubagentFiles,
        readFile: fsReadSubagentFile,
        isAlive: isSubagentPidAlive,
    })
}

function toSubagentsFrame(run: ScannedSubagent): JsonObject {
    return {
        id: run.id,
        agent: run.meta.agent,
        task: run.meta.task,
        startedAt: run.meta.startedAt,
        ...(run.meta.toolCallId !== undefined ? { toolCallId: run.meta.toolCallId } : {}),
        ...(run.meta.model !== undefined ? { model: run.meta.model } : {}),
    }
}

// Always an array — empty when no live runs (or the session cannot be
// resolved): the Swift client CLEARS liveSubagents from this frame, so an
// omitted/absent frame would leak stale state.
function sendSubagentsToClient(state: RcSingleton, client: RcClient): void {
    const runs = scanEffectiveSubagents(state, client)
    writeJson(client, { type: 'subagents', subagents: (runs ?? []).map(toSubagentsFrame) })
}

function broadcastSubagents(state: RcSingleton): void {
    for (const client of state.clients) sendSubagentsToClient(state, client)
}

// Per-run in-flight state, lazily created from the first observed bus event
// (M2: attach mid-run is the normal case — the in-flight turn is uncommitted
// and absent from the child's .jsonl, so it must be tracked regardless of
// attach state).
function subagentRunState(
    state: RcSingleton,
    subagentId: string
): { buffer: ContentBlock[]; lastStopReason: string | null } {
    let run = state.subagentRunState.get(subagentId)
    if (run === undefined) {
        run = { buffer: [], lastStopReason: null }
        state.subagentRunState.set(subagentId, run)
    }
    return run
}

// One whitelisted child bus event → per-run buffer update + forward to the
// attached clients. Everything else is consumed for internal state only
// (message_end → lastStopReason; agent_* → lifecycle). Mirrors trackEvent's
// main-session buffer semantics on a per-run buffer instead.
function handleSubagentBusEvent(state: RcSingleton, busPayload: unknown): void {
    const subagentId = isObject(busPayload) ? stringFrom(busPayload.subagentId) : undefined
    const mapped = mapBusEvent(busPayload)
    if (subagentId === undefined || mapped === null) return
    const name = mapped.name
    const payload = mapped.payload
    const run = subagentRunState(state, subagentId)
    if (
        name === 'message_start' &&
        isObject(payload.message) &&
        payload.message.role === 'assistant'
    ) {
        run.buffer = []
    }
    if (name === 'message_update')
        appendAssistantDelta(run.buffer, payload.assistantMessageEvent)
    if (name === 'tool_execution_start') {
        run.buffer.push({
            type: 'toolUse',
            toolCallId: stringFrom(payload.toolCallId) ?? '',
            toolName: stringFrom(payload.toolName) ?? 'tool',
            args: isObject(payload.args) ? payload.args : {},
        })
    }
    if (name === 'tool_execution_update' || name === 'tool_execution_end')
        updateToolOutput(run.buffer, payload)
    if (name === 'turn_end') run.buffer = []
    if (
        (name === 'message_end' || name === 'turn_end') &&
        isObject(payload.message) &&
        typeof payload.message.stopReason === 'string'
    ) {
        run.lastStopReason = payload.message.stopReason
    }
    if (name === 'agent_start') broadcastSubagents(state)
    if (name === 'agent_settled') startSubagentSettlePoll(state, subagentId)
    if (!SUBAGENT_EVENT_WHITELIST.has(name)) return
    const frame: JsonObject = { type: 'subagent_event', subagentId, name, ...payload }
    for (const client of state.clients) {
        if (client.attachedSubagentId === subagentId) writeJson(client, frame)
    }
}

function readSubagentMeta(
    dir: string,
    subagentId: string
): {
    present: boolean
    meta: unknown
} {
    try {
        const meta = JSON.parse(fsReadSubagentFile(join(dir, `${subagentId}.meta`)))
        return { present: true, meta }
    } catch {
        return { present: false, meta: null }
    }
}

function readSubagentPid(dir: string, subagentId: string): number | undefined {
    try {
        const pid = Number.parseInt(
            fsReadSubagentFile(join(dir, `${subagentId}.pid`)).trim(),
            10
        )
        return Number.isNaN(pid) || pid <= 0 ? undefined : pid
    } catch {
        return undefined
    }
}

// Settle lifecycle (spec): on a run's agent_settled, poll the TERMINAL FILE
// STATE — keyed on META, never the pidfile (m1: the extension removes .pid
// unconditionally first on every exit, so the pidfile is not a classifier).
// 50 ms poll, 2 s deadline; classifySettle's `extend` keeps the loop alive
// while the pid is still shutting down, and the deadline is the hard stop.
const SETTLE_DEADLINE_MS = 2000
const SETTLE_POLL_MS = 50

// Settle pollers per run — a second agent_settled for the same run (a resumed
// run settles again) must not start a second poller while one is running.
const settlePollers = new Map<string, ReturnType<typeof setInterval>>()

function startSubagentSettlePoll(state: RcSingleton, subagentId: string): void {
    if (settlePollers.has(subagentId)) return
    const startedAt = Date.now()
    const timer = setInterval(() => {
        const dir = subagentsDir()
        const { present, meta } = readSubagentMeta(dir, subagentId)
        const parsedMeta = parseSubagentMeta(meta)
        const pid = readSubagentPid(dir, subagentId)
        const result = classifySettle({
            metaPresent: present,
            metaStatus: parsedMeta?.status,
            metaStopReason: parsedMeta?.stopReason,
            pidAlive: pid !== undefined && isSubagentPidAlive(pid),
            lastObservedStopReason: state.subagentRunState.get(subagentId)?.lastStopReason,
            deadlineExceeded: Date.now() - startedAt > SETTLE_DEADLINE_MS,
        })
        if (result.extend) {
            // Slow clean shutdown: the pid is still alive with no terminal
            // status — keep polling until the status lands, the meta is
            // deleted, or the deadline passes (classifySettle stops
            // extending once deadlineExceeded, so the loop always ends).
            return
        }
        clearInterval(timer)
        settlePollers.delete(subagentId)
        state.subagentRunState.delete(subagentId)
        const frame: JsonObject = {
            type: 'subagent_settled',
            subagentId,
            status: result.status,
            ...(result.stopReason !== undefined ? { stopReason: result.stopReason } : {}),
        }
        state.broadcast(frame)
        broadcastSubagents(state)
    }, SETTLE_POLL_MS)
    timer.unref?.()
    settlePollers.set(subagentId, timer)
}

function buildSubagentHistory(
    dir: string,
    subagentId: string
): {
    history: unknown[]
    lastEntry: unknown
} {
    // The child's .jsonl IS a pi session file — the same entry shapes the
    // main session's branch has, so mapHistoryEntry renders it unmodified.
    const path = join(dir, `${subagentId}.jsonl`)
    let raw: string
    try {
        raw = fsReadSubagentFile(path)
    } catch {
        return { history: [], lastEntry: undefined }
    }
    const lines = raw.split('\n').filter(line => line.length > 0)
    const entries: unknown[] = []
    for (const line of lines) {
        try {
            entries.push(JSON.parse(line))
        } catch {
            // torn tail line (the child writes as it runs) — skip
        }
    }
    const messages = entries
        .filter(entry => isObject(entry) && entry.type === 'message')
        .map(entry => entry as JsonObject)
        .flatMap(entry => mapHistoryEntry(entry))
    return { history: messages, lastEntry: entries[entries.length - 1] ?? undefined }
}

function sendSubagentSnapshot(
    state: RcSingleton,
    client: RcClient,
    run: ScannedSubagent
): void {
    const dir = subagentsDir()
    const { history, lastEntry } = buildSubagentHistory(dir, run.id)
    const runState = state.subagentRunState.get(run.id)
    const snapshot = buildSubagentSnapshot({
        history,
        buffer: runState?.buffer ?? [],
        ...(lastEntry !== undefined ? { lastJsonlMessage: lastEntry } : {}),
    })
    writeJson(client, {
        type: 'subagent_snapshot',
        subagentId: run.id,
        agent: run.meta.agent,
        task: run.meta.task,
        startedAt: run.meta.startedAt,
        running: true,
        history: snapshot.history,
        ...(snapshot.buffer.length > 0 ? { buffer: snapshot.buffer } : {}),
    })
}

function handleAttachSubagent(
    state: RcSingleton,
    client: RcClient,
    message: JsonObject
): void {
    const runs = scanEffectiveSubagents(state, client)
    if (runs === null) {
        writeJson(client, {
            type: 'error',
            code: 'subagent_not_found',
            message: 'No session to attach to.',
        })
        return
    }
    const candidate = resolveAttachCandidate(
        runs,
        stringFrom(message.subagentId),
        stringFrom(message.toolCallId)
    )
    if (candidate.ok === false) {
        writeJson(client, {
            type: 'error',
            code: 'subagent_not_found',
            message: candidate.message,
        })
        return
    }
    // ONE attach per client: this assignment IS the implicit detach of the
    // previous attach (spec wire protocol).
    client.attachedSubagentId = candidate.run.id
    sendSubagentSnapshot(state, client, candidate.run)
}

function handleDetachSubagent(
    state: RcSingleton,
    client: RcClient,
    message: JsonObject
): void {
    const subagentId = stringFrom(message.subagentId)
    if (subagentId === undefined) {
        writeJson(client, { type: 'error', code: 'invalid_message' })
        return
    }
    if (client.attachedSubagentId === subagentId) client.attachedSubagentId = null
}

export default function rc(pi: ExtensionAPI): void {
    const state = singleton()
    state.handleUpgrade = (req, socket, head) => handleUpgrade(state, req, socket, head)
    state.handleSocketData = (client, chunk) => handleSocketData(state, client, chunk)
    state.refreshStatus = () => refreshStatus(state)
    registerEventHandlers(pi, state)
    pi.registerCommand('rc', {
        description: 'Toggle remote-control WebSocket server (subcommand: push-setup)',
        getArgumentCompletions: (argumentPrefix: string) => {
            const subs = [
                {
                    value: 'push-setup',
                    label: 'push-setup',
                    description: 'Configure APNs push delivery for the rc app',
                },
            ]
            return subs.filter(sub => sub.value.startsWith(argumentPrefix))
        },
        handler: async (args, ctx) => {
            dbgLog('command /rc invoked')
            state.bind(pi, ctx)
            state.commandCtx = ctx
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
    pi.registerTool({
        name: 'rc_inspect',
        label: 'RC Inspect',
        description: [
            'Live status of the rc remote-control singleton in this pi process: serving (host/port/code),',
            'client count, push readiness, last APNs outcome, pending question. Read-only.',
            'Do not read rc-auth.json for rc status — it is a test-harness seam.',
        ].join(' '),
        parameters: Type.Object({}),
        async execute(_toolCallId, _params) {
            return {
                content: [{ type: 'text', text: buildRcInspectReport(state) }],
                details: undefined,
            }
        },
        renderCall(_args, theme) {
            return new Text(theme.fg('toolTitle', theme.bold('rc_inspect ')), 0, 0)
        },
        renderResult(result, _options, _theme, _context) {
            const text = result.content[0]
            return new Text(text?.type === 'text' ? text.text : '(no output)', 0, 0)
        },
    })
}

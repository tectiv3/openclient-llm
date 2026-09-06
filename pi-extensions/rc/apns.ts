import { createPrivateKey, sign, type KeyObject } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import * as http2 from 'node:http2'
import { homedir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { dbgLog } from './debug'

const DEFAULT_HOST = 'api.push.apple.com:443'
const DEFAULT_TOPIC = 'com.kinchaku.openclient-llm'
const JWT_TTL_SECONDS = 300
const SEND_TIMEOUT_MS = 15_000

export const FINISHED_COLLAPSE_ID = 'rc-finished'
export const QUESTION_COLLAPSE_ID = 'rc-question'
export const TEST_COLLAPSE_ID = 'rc-test'

type JsonObject = Record<string, unknown>

export type ApnsSources = {
    teamId: 'env' | 'file' | 'missing'
    keyId: 'env' | 'file' | 'missing'
    keyFile: 'env' | 'file' | 'missing'
}

export type ApnsConfig = {
    teamId: string
    keyId: string
    keyFile: string
    topic: string
    host: string
    port: number
    sources: ApnsSources
}

export type PushOutcome =
    | { ok: 'sent'; status: number; reason?: string }
    | { ok: 'disabled'; reason: string }
    | { ok: 'no_token' }
    | { ok: 'dropped'; status: number; reason?: string }
    | { ok: 'error'; detail: string }

export type KeyValidation = { ok: true; key: KeyObject } | { ok: false; reason: string }

export function apnsConfigPath(): string {
    return join(homedir(), '.pi', 'agent', 'rc-push.json')
}

function expandHomePath(path: string): string {
    if (path === '~') return homedir()
    if (path.startsWith('~/')) return join(homedir(), path.slice(2))
    return path
}

function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : String(error)
}

function envValue(name: string): string | undefined {
    const value = process.env[name]?.trim()
    return value ? value : undefined
}

function readRawConfig(): JsonObject {
    try {
        const parsed: unknown = JSON.parse(readFileSync(apnsConfigPath(), 'utf8'))
        if (typeof parsed !== 'object' || parsed === null) return {}
        return parsed as JsonObject
    } catch {
        return {}
    }
}

function writeRawConfig(obj: JsonObject): void {
    const path = apnsConfigPath()
    const dir = dirname(path)
    if (dir !== '.' && !existsSync(dir)) mkdirSync(dir, { recursive: true })
    const tempFile = `${path}.${process.pid}.${Date.now()}.tmp`
    writeFileSync(tempFile, `${JSON.stringify(obj, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 })
    renameSync(tempFile, path)
}

function readConfigFile(): { teamId?: string; keyId?: string; keyFile?: string } {
    const raw = readRawConfig()
    const out: { teamId?: string; keyId?: string; keyFile?: string } = {}
    for (const field of ['teamId', 'keyId', 'keyFile'] as const) {
        const value = raw[field]
        if (typeof value === 'string' && value.length > 0) out[field] = value
    }
    return out
}

export function readStoredDeviceToken(): string | null {
    const value = readRawConfig().token
    if (typeof value === 'string' && /^[0-9a-f]{64}$/i.test(value)) return value.toLowerCase()
    return null
}

export function saveDeviceToken(token: string | null): void {
    const raw = readRawConfig()
    if (token === null) delete raw.token
    else raw.token = token
    writeRawConfig(raw)
}

// Resolved on every use rather than cached: /rc push-setup can rewrite the
// config file while the process is running, and pushes are rare enough that
// reading a small JSON file is free.
export function resolveApnsConfig(): ApnsConfig | null {
    const file = readConfigFile()
    const pick = (envName: string, field: 'teamId' | 'keyId' | 'keyFile') => {
        const fromEnv = envValue(envName)
        if (fromEnv) return { value: fromEnv, source: 'env' as const }
        if (file[field]) return { value: file[field] as string, source: 'file' as const }
        return { value: undefined, source: 'missing' as const }
    }
    const teamId = pick('PI_RC_APNS_TEAM_ID', 'teamId')
    const keyId = pick('PI_RC_APNS_KEY_ID', 'keyId')
    const keyFile = pick('PI_RC_APNS_KEY_FILE', 'keyFile')
    if (!teamId.value || !keyId.value || !keyFile.value) return null
    const hostSpec = envValue('PI_RC_APNS_HOST') ?? DEFAULT_HOST
    const [host, portPart] = hostSpec.split(':')
    const port = portPart ? Number.parseInt(portPart, 10) : 443
    if (!host || !Number.isInteger(port) || port <= 0) return null
    return {
        teamId: teamId.value,
        keyId: keyId.value,
        keyFile: keyFile.value,
        topic: envValue('PI_RC_APNS_TOPIC') ?? DEFAULT_TOPIC,
        host,
        port,
        sources: { teamId: teamId.source, keyId: keyId.source, keyFile: keyFile.source },
    }
}

export function describeSources(config: ApnsConfig): string {
    return `teamId=${config.sources.teamId}, keyId=${config.sources.keyId}, keyFile=${config.sources.keyFile}`
}

export function missingConfigFields(): string {
    const config = resolveApnsConfig()
    if (config) return ''
    const file = readConfigFile()
    const missing: string[] = []
    for (const [envName, field] of [
        ['PI_RC_APNS_TEAM_ID', 'teamId'],
        ['PI_RC_APNS_KEY_ID', 'keyId'],
        ['PI_RC_APNS_KEY_FILE', 'keyFile'],
    ] as const) {
        if (!envValue(envName) && !file[field]) missing.push(field)
    }
    if (missing.length > 0) return `missing ${missing.join(', ')}`
    return `invalid PI_RC_APNS_HOST`
}

export function writeApnsConfig(teamId: string, keyId: string, keyFile: string): void {
    // Merge, not replace: a saved device token survives a push-setup rewrite.
    writeRawConfig({ ...readRawConfig(), teamId, keyId, keyFile })
}

export function loadApnsKey(keyFile: string): KeyValidation {
    const expanded = expandHomePath(keyFile)
    let pem: string
    try {
        pem = readFileSync(expanded, 'utf8')
    } catch (error) {
        return { ok: false, reason: `key file not readable: ${errorMessage(error)}` }
    }
    let key: KeyObject
    try {
        key = createPrivateKey({ key: pem, format: 'pem', type: 'pkcs8' })
    } catch (error) {
        return { ok: false, reason: `not a valid PKCS#8 PEM key: ${errorMessage(error)}` }
    }
    if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
        return { ok: false, reason: 'key is not a P-256 EC key' }
    }
    // Same ES256/IEEE-P1363 trap as the JWT path: Node's default DER encoding
    // would pass a naive parse but APNs rejects it, so verify the exact
    // encoding used at send time.
    try {
        const testSignature = sign('sha256', Buffer.from('pi-rc apns key check'), {
            key,
            dsaEncoding: 'ieee-p1363',
        })
        if (testSignature.length !== 64) {
            return { ok: false, reason: `ES256 test signature is ${testSignature.length} bytes, expected 64` }
        }
    } catch (error) {
        return { ok: false, reason: `ES256 test signature failed: ${errorMessage(error)}` }
    }
    return { ok: true, key }
}

function base64Url(input: Buffer | string): string {
    const buffer = typeof input === 'string' ? Buffer.from(input, 'utf8') : input
    return buffer.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function signJwt(config: ApnsConfig, key: KeyObject): string {
    const now = Math.floor(Date.now() / 1000)
    const header = base64Url(JSON.stringify({ alg: 'ES256', kid: config.keyId }))
    const claims = base64Url(
        JSON.stringify({
            iss: config.teamId,
            sub: config.keyId,
            aud: 'apns',
            iat: now,
            exp: now + JWT_TTL_SECONDS,
        })
    )
    const signature = sign('sha256', Buffer.from(`${header}.${claims}`), {
        key,
        // MANDATORY: Node's default for EC keys is DER (~71 bytes), which
        // APNs rejects; ES256 requires the raw R||S (64 bytes) IEEE P-1363 form.
        dsaEncoding: 'ieee-p1363',
    })
    return `${header}.${claims}.${base64Url(signature)}`
}

// APNs requires HTTP/2 over TLS: the h2 session rides a tls.connect socket
// instead of the default plaintext connect. One session is cached per
// authority; any error drops it and the next send recreates it.
let session: http2.Http2Session | null = null
let sessionAuthority: string | null = null

function getSession(config: ApnsConfig): http2.Http2Session {
    const authority = `${config.host}:${config.port}`
    if (session && sessionAuthority === authority && !session.destroyed) return session
    // Node performs the TLS handshake itself: h2 ALPN, SNI, and the standard
    // CA store (the test harness injects NODE_EXTRA_CA_CERTS for its fake
    // endpoint). A custom createConnection socket fails with "Protocol error"
    // on Node 24, so no createConnection.
    const newSession = http2.connect(new URL(`https://${authority}`))
    const drop = () => {
        if (session === newSession) {
            session = null
            sessionAuthority = null
        }
        try {
            newSession.destroy()
        } catch {
            // already gone
        }
    }
    newSession.once('error', drop)
    newSession.once('close', drop)
    session = newSession
    sessionAuthority = authority
    return newSession
}

export function closeApns(): void {
    if (session) {
        try {
            session.destroy()
        } catch {
            // already gone
        }
        session = null
        sessionAuthority = null
    }
}

export function finishedPayload(sessionId: string): JsonObject {
    return {
        aps: {
            alert: { title: 'Agent finished', body: 'Agent finished' },
            sound: 'default',
            'thread-id': sessionId,
        },
    }
}

export function questionPayload(sessionId: string): JsonObject {
    return {
        aps: {
            alert: { title: 'Agent has a question', body: 'Agent has a question — answer needed' },
            sound: 'default',
            'thread-id': sessionId,
            timeSensitive: true,
        },
    }
}

export function testPayload(sessionId: string): JsonObject {
    return {
        aps: {
            alert: { title: 'RC push test', body: 'RC push test' },
            sound: 'default',
            'thread-id': sessionId,
        },
    }
}

// Payloads are fixed server-side strings only — never agent or user text —
// so a verbose or compromised agent cannot place session content on a
// lock screen.
export async function sendApnsPush(
    token: string,
    collapseId: string,
    payload: JsonObject,
    sessionId?: string
): Promise<PushOutcome> {
    const config = resolveApnsConfig()
    if (!config) {
        const reason = missingConfigFields()
        dbgLog('apns push skipped: disabled (', reason, ')')
        return { ok: 'disabled', reason }
    }
    const keyValidation = loadApnsKey(config.keyFile)
    if (!keyValidation.ok) {
        dbgLog('apns push skipped: disabled (', keyValidation.reason, ')')
        return { ok: 'disabled', reason: keyValidation.reason }
    }
    let result: { status: number; reason?: string }
    try {
        result = await postToApns(config, keyValidation.key, token, collapseId, payload, sessionId)
    } catch (error) {
        const detail = errorMessage(error)
        dbgLog('apns push failed:', detail)
        return { ok: 'error', detail }
    }
    if (result.status === 410 || result.reason === 'BadDeviceToken') {
        dbgLog('apns push: device token invalid (status', result.status, 'reason', result.reason ?? '-', '— token dropped')
        return { ok: 'dropped', status: result.status, reason: result.reason }
    }
    dbgLog('apns push sent: status', result.status, 'reason', result.reason ?? '-', 'collapseId', collapseId)
    return { ok: 'sent', status: result.status, reason: result.reason }
}

function postToApns(
    config: ApnsConfig,
    key: KeyObject,
    token: string,
    collapseId: string,
    payload: JsonObject,
    sessionId?: string
): Promise<{ status: number; reason?: string }> {
    const authority = `${config.host}:${config.port}`
    const body = Buffer.from(JSON.stringify(payload), 'utf8')
    const h2 = getSession(config)
    return new Promise((resolve, reject) => {
        let settled = false
        const finish = (value: { status: number; reason?: string }, error?: Error) => {
            if (settled) return
            settled = true
            clearTimeout(timeout)
            if (error) reject(error)
            else resolve(value)
        }
        const timeout = setTimeout(() => {
            finish(undefined, new Error(`apns request timed out after ${SEND_TIMEOUT_MS}ms (${authority})`))
            closeApns()
        }, SEND_TIMEOUT_MS)
        // No session-level 'error' listener here: the cached session is
        // shared across sends, so one listener per send would leak. Request
        // errors (including session death) surface on the request itself.
        h2.request({
            ':method': 'POST',
            ':path': `/3/device/${token}`,
            ':scheme': 'https',
            ':authority': authority,
            authorization: `Bearer ${signJwt(config, key)}`,
            'apns-topic': config.topic,
            'apns-priority': '5',
            'apns-timestamp': String(Math.floor(Date.now() / 1000)),
            'apns-collapse-id': collapseId,
            'content-type': 'application/json',
            'content-length': String(body.length),
        })
            .on('error', error => finish(undefined, error))
            .on('response', headers => {
                const status = Number(headers[':status'] ?? 0)
                const reason = typeof headers['apns-reason'] === 'string' ? headers['apns-reason'] : undefined
                finish({ status, ...(reason ? { reason } : {}) })
            })
            .end(body)
    })
}

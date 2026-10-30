import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { saveDeviceToken, writeApnsConfig } from '../apns'
import {
    QUIET_ANCHOR_STATUS,
    QUIET_SIBLING_STATUS,
    readStatusMode,
    statusModeFromConfig,
    statusText,
    type StatusParts,
} from '../statusMode'

const FULL_PARTS: StatusParts = {
    isAnchor: true,
    host: '100.64.0.7',
    port: 47800,
    code: '123456',
    clientsText: '2 clients',
    pushText: 'push ok',
    lastPush: 'apns 200',
}

const TOKEN = 'a'.repeat(64)

let dir: string
let configPath: string
let previousConfigPath: string | undefined

beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'rc-status-mode-'))
    configPath = join(dir, 'rc-push.json')
    previousConfigPath = process.env.PI_RC_APNS_CONFIG
    process.env.PI_RC_APNS_CONFIG = configPath
})

afterEach(() => {
    if (previousConfigPath === undefined) delete process.env.PI_RC_APNS_CONFIG
    else process.env.PI_RC_APNS_CONFIG = previousConfigPath
    rmSync(dir, { recursive: true, force: true })
})

describe('statusText', () => {
    it('quiet + anchor is one emoji, nothing else', () => {
        expect(statusText('quiet', { ...FULL_PARTS, isAnchor: true })).toBe('🐙')
        expect(statusText('quiet', { ...FULL_PARTS, isAnchor: true })).toBe(
            QUIET_ANCHOR_STATUS
        )
    })

    it('quiet + sibling is one emoji, nothing else', () => {
        expect(statusText('quiet', { ...FULL_PARTS, isAnchor: false })).toBe('🐚')
        expect(statusText('quiet', { ...FULL_PARTS, isAnchor: false })).toBe(
            QUIET_SIBLING_STATUS
        )
    })

    it('quiet mode ignores every other field', () => {
        expect(
            statusText('quiet', {
                isAnchor: false,
                host: '',
                port: 0,
                code: '',
                clientsText: 'no clients',
                pushText: 'push: not configured',
            })
        ).toBe('🐚')
    })

    it('full mode reproduces the pre-quiet string byte for byte', () => {
        expect(statusText('full', FULL_PARTS)).toBe(
            'rc: ws://100.64.0.7:47800 code 123456 · 2 clients · push ok · apns 200'
        )
    })

    it('full mode omits the lastPush segment when there is none', () => {
        expect(statusText('full', { ...FULL_PARTS, lastPush: undefined })).toBe(
            'rc: ws://100.64.0.7:47800 code 123456 · 2 clients · push ok'
        )
    })
})

describe('statusModeFromConfig', () => {
    it('accepts the exact value', () => {
        expect(statusModeFromConfig({ status: 'quiet' })).toBe('quiet')
    })

    it('tolerates case and surrounding whitespace', () => {
        expect(statusModeFromConfig({ status: 'QUIET' })).toBe('quiet')
        expect(statusModeFromConfig({ status: 'Quiet' })).toBe('quiet')
        expect(statusModeFromConfig({ status: '  quiet  ' })).toBe('quiet')
    })

    it('treats any other value or type as full', () => {
        expect(statusModeFromConfig({ status: 'loud' })).toBe('full')
        expect(statusModeFromConfig({ status: '' })).toBe('full')
        expect(statusModeFromConfig({ status: 1 })).toBe('full')
        expect(statusModeFromConfig({ status: null })).toBe('full')
        expect(statusModeFromConfig({ status: ['quiet'] })).toBe('full')
        expect(statusModeFromConfig({})).toBe('full')
    })
})

describe('readStatusMode (rc-push.json)', () => {
    it('missing file → full', () => {
        expect(readStatusMode()).toBe('full')
    })

    it('invalid JSON → full', () => {
        writeFileSync(configPath, '{ not json', 'utf8')
        expect(readStatusMode()).toBe('full')
    })

    it('"status": "  quiet  " → quiet', () => {
        writeFileSync(configPath, JSON.stringify({ status: '  quiet  ' }), 'utf8')
        expect(readStatusMode()).toBe('quiet')
    })

    it('"status": "loud" → full', () => {
        writeFileSync(configPath, JSON.stringify({ status: 'loud' }), 'utf8')
        expect(readStatusMode()).toBe('full')
    })

    it('non-string status → full', () => {
        writeFileSync(configPath, JSON.stringify({ status: { mode: 'quiet' } }), 'utf8')
        expect(readStatusMode()).toBe('full')
    })

    it('"status": "quiet" → quiet', () => {
        writeFileSync(configPath, JSON.stringify({ status: 'quiet' }), 'utf8')
        expect(readStatusMode()).toBe('quiet')
    })
})

describe('status key survives config merges', () => {
    it('saveDeviceToken preserves an unrelated status key', () => {
        writeFileSync(configPath, JSON.stringify({ status: 'quiet' }), 'utf8')

        saveDeviceToken(TOKEN)

        const raw = JSON.parse(readFileSync(configPath, 'utf8'))
        expect(raw.status).toBe('quiet')
        expect(raw.token).toBe(TOKEN)
        expect(readStatusMode()).toBe('quiet')
    })

    it('writeApnsConfig preserves status and the saved token', () => {
        writeFileSync(configPath, JSON.stringify({ status: 'quiet' }), 'utf8')
        saveDeviceToken(TOKEN)

        writeApnsConfig(
            'TEAM123456',
            'KEY1234567',
            '/tmp/AuthKey_KEY1234567.p8',
            'host.example:443'
        )

        const raw = JSON.parse(readFileSync(configPath, 'utf8'))
        expect(raw.status).toBe('quiet')
        expect(raw.token).toBe(TOKEN)
        expect(raw.teamId).toBe('TEAM123456')
        expect(readStatusMode()).toBe('quiet')
    })
})

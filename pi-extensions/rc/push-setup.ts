import type { ExtensionContext } from '@earendil-works/pi-coding-agent'
import { basename, resolve } from 'node:path'
import {
    apnsConfigPath,
    describeSources,
    loadApnsKey,
    resolveApnsConfig,
    writeApnsConfig,
} from './apns'
import { dbgLog } from './debug'

// Structural type mirrors the question extension's RcRemote: rc is
// referenced by shape only, never imported.
interface RcRemoteLike {
    isServing(): boolean
    hasConnectedClients(): boolean
    refreshStatus(): void
    ask(opts: { kind: 'question'; params: unknown }): Promise<{
        value: string
        wasCustom: boolean
        index?: number
    } | null>
}

const ID_PATTERN = /^[A-Za-z0-9]{10}$/

async function promptValue(
    remote: RcRemoteLike,
    ui: ExtensionContext['ui'],
    title: string
): Promise<string | null> {
    if (remote.isServing() && remote.hasConnectedClients()) {
        const answer = await remote.ask({
            kind: 'question',
            params: { question: title, options: [], allowOther: true },
        })
        if (!answer) return null
        const value = answer.value.trim()
        return value.length > 0 ? value : null
    }
    const value = await ui.input(title)
    if (value === undefined) return null
    const trimmed = value.trim()
    return trimmed.length > 0 ? trimmed : null
}

export async function runPushSetup(
    remote: RcRemoteLike,
    ui: ExtensionContext['ui'],
    sessionId: string
): Promise<void> {
    remote.refreshStatus()
    const config = resolveApnsConfig()
    if (config) {
        ui.notify(
            `apns push already configured (${describeSources(config)}); re-entry rewrites ${apnsConfigPath()}`,
            'info'
        )
    }
    const teamId = await promptValidated(remote, ui, 'APNs Team ID (10 alphanumeric characters)', value =>
        ID_PATTERN.test(value) ? null : 'must be exactly 10 alphanumeric characters'
    )
    if (teamId === null) return cancelled(ui)
    const keyId = await promptValidated(remote, ui, 'APNs Key ID (10 alphanumeric characters)', value =>
        ID_PATTERN.test(value) ? null : 'must be exactly 10 alphanumeric characters'
    )
    if (keyId === null) return cancelled(ui)
    let keyFile: string
    for (;;) {
        const raw = await promptValue(remote, ui, 'File path to the .p8 private key (never its contents)')
        if (raw === null) return cancelled(ui)
        const validation = loadApnsKey(raw)
        if (validation.ok) {
            keyFile = resolve(expandHome(raw))
            break
        }
        ui.notify(`key file invalid: ${validation.reason} — try again`, 'warning')
    }

    const base = basename(keyFile)
    const match = base.match(/^AuthKey_([A-Za-z0-9]+)\.p8$/)
    if (match && match[1] !== keyId) {
        const proceed = await promptConfirm(
            remote,
            ui,
            `key file ${base} encodes key ID ${match[1]}, not ${keyId} — use it anyway?`
        )
        if (!proceed) {
            ui.notify('apns push setup cancelled (key id mismatch)', 'info')
            return
        }
    }

    try {
        writeApnsConfig(teamId, keyId, keyFile)
    } catch (error) {
        const detail = error instanceof Error ? error.message : String(error)
        ui.notify(`apns push setup failed: could not write ${apnsConfigPath()}: ${detail}`, 'error')
        dbgLog('push-setup: config write failed:', detail)
        return
    }
    ui.notify(
        `apns push configured: teamId ${teamId}, keyId ${keyId}, keyFile ${keyFile} → ${apnsConfigPath()}`,
        'info'
    )
    remote.refreshStatus()
    dbgLog('push-setup: wrote config, teamId', teamId, 'keyId', keyId, 'keyFile', keyFile, 'sessionId', sessionId)
}

async function promptValidated(
    remote: RcRemoteLike,
    ui: ExtensionContext['ui'],
    title: string,
    validate: (value: string) => string | null
): Promise<string | null> {
    for (;;) {
        const raw = await promptValue(remote, ui, title)
        if (raw === null) return null
        const problem = validate(raw)
        if (problem === null) return raw
        ui.notify(`${title.split(' (')[0]}: ${problem} — try again`, 'warning')
    }
}

async function promptConfirm(
    remote: RcRemoteLike,
    ui: ExtensionContext['ui'],
    message: string
): Promise<boolean> {
    if (remote.isServing() && remote.hasConnectedClients()) {
        const answer = await remote.ask({
            kind: 'question',
            params: {
                question: message,
                options: [
                    { label: 'Yes, continue', value: 'yes' },
                    { label: 'No, cancel', value: 'cancel' },
                ],
                allowOther: true,
            },
        })
        if (!answer) return false
        const value = answer.wasCustom ? answer.value.trim().toLowerCase() : answer.value
        return value === 'yes' || value === 'yes, continue'
    }
    return ui.confirm(message, message)
}

function cancelled(ui: ExtensionContext['ui']): void {
    ui.notify(
        'apns push setup cancelled. /rc push-setup expects: APNs Team ID, APNs Key ID, and the file path to the .p8 key (Apple → Keys → "Apple Push Notifications" key). Nothing was written.',
        'info'
    )
    dbgLog('push-setup: cancelled')
}

function expandHome(path: string): string {
    if (path === '~') return process.env.HOME ?? path
    if (path.startsWith('~/')) return `${process.env.HOME ?? ''}${path.slice(1)}`
    return path
}

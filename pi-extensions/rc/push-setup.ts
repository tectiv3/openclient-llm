import type { ExtensionContext } from '@earendil-works/pi-coding-agent'
import { basename, resolve } from 'node:path'
import {
    apnsConfigPath,
    describeSources,
    expandHomePath,
    loadApnsKey,
    resolveApnsConfig,
    writeApnsConfig,
} from './apns'

// apns.ts's DEFAULT_HOST includes a port; the prompt shows the bare host.
const DEFAULT_HOST_DISPLAY = 'api.sandbox.push.apple.com:443'
import { dbgLog } from './debug'

// Structural type for the rc singleton passed in by the /rc command handler.
// Like the question extension's RcRemote, it is a shape check only (rc is
// referenced via globalThis, never imported), but the shapes are deliberately
// independent: push-setup also needs refreshStatus and its ask params differ.
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
    state: RcRemoteLike,
    ui: ExtensionContext['ui'],
    title: string
): Promise<string | null> {
    if (state.isServing() && state.hasConnectedClients()) {
        const answer = await state.ask({
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
    state: RcRemoteLike,
    ui: ExtensionContext['ui'],
    sessionId: string
): Promise<void> {
    state.refreshStatus()
    const config = resolveApnsConfig()
    if (config) {
        ui.notify(
            `apns push already configured (${describeSources(config)}); re-entry rewrites ${apnsConfigPath()}`,
            'info'
        )
    }
    const teamId = await promptValidated(
        state,
        ui,
        'APNs Team ID (10 alphanumeric characters)',
        value => (ID_PATTERN.test(value) ? null : 'must be exactly 10 alphanumeric characters')
    )
    if (teamId === null) return cancelled(ui)
    const keyId = await promptValidated(
        state,
        ui,
        'APNs Key ID (10 alphanumeric characters)',
        value => (ID_PATTERN.test(value) ? null : 'must be exactly 10 alphanumeric characters')
    )
    if (keyId === null) return cancelled(ui)
    let keyFile: string
    for (;;) {
        const raw = await promptValue(
            state,
            ui,
            'File path to the .p8 private key (never its contents)'
        )
        if (raw === null) return cancelled(ui)
        const validation = loadApnsKey(raw)
        if (validation.ok) {
            keyFile = resolve(expandHomePath(raw))
            break
        }
        ui.notify(`key file invalid: ${validation.reason} — try again`, 'warning')
    }

    const base = basename(keyFile)
    const match = base.match(/^AuthKey_([A-Za-z0-9]+)\.p8$/)
    if (match && match[1] !== keyId) {
        const proceed = await promptConfirm(
            state,
            ui,
            `key file ${base} encodes key ID ${match[1]}, not ${keyId} — use it anyway?`
        )
        if (!proceed) {
            ui.notify('apns push setup cancelled (key id mismatch)', 'info')
            return
        }
    }

    const host = await promptHost(state, ui)
    if (host === null) return cancelled(ui)

    try {
        writeApnsConfig(teamId, keyId, keyFile, host)
    } catch (error) {
        const detail = error instanceof Error ? error.message : String(error)
        ui.notify(
            `apns push setup failed: could not write ${apnsConfigPath()}: ${detail}`,
            'error'
        )
        dbgLog('push-setup: config write failed:', detail)
        return
    }
    ui.notify(
        `apns push configured: teamId ${teamId}, keyId ${keyId}, keyFile ${keyFile}, host ${host} → ${apnsConfigPath()}`,
        'info'
    )
    state.refreshStatus()
    dbgLog(
        'push-setup: wrote config, teamId',
        teamId,
        'keyId',
        keyId,
        'keyFile',
        keyFile,
        'sessionId',
        sessionId
    )
}

async function promptValidated(
    state: RcRemoteLike,
    ui: ExtensionContext['ui'],
    title: string,
    validate: (value: string) => string | null
): Promise<string | null> {
    for (;;) {
        const raw = await promptValue(state, ui, title)
        if (raw === null) return null
        const problem = validate(raw)
        if (problem === null) return raw
        ui.notify(`${title.split(' (')[0]}: ${problem} — try again`, 'warning')
    }
}

const HOST_PATTERN = /^[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?$/i

async function promptHost(
    state: RcRemoteLike,
    ui: ExtensionContext['ui']
): Promise<string | null> {
    // Empty answer takes the default host — the common case, so the prompt is
    // skippable instead of a forced re-entry of a long hostname.
    for (;;) {
        const raw = await promptValue(
            state,
            ui,
            `APNs host:port (default ${DEFAULT_HOST_DISPLAY}, empty = default; sandbox is required for development builds)`
        )
        if (raw === null) return null
        if (raw === '') return DEFAULT_HOST_DISPLAY
        if (!HOST_PATTERN.test(raw)) {
            ui.notify(
                'host must look like api.sandbox.push.apple.com or host:port — try again',
                'warning'
            )
            continue
        }
        return raw
    }
}

async function promptConfirm(
    state: RcRemoteLike,
    ui: ExtensionContext['ui'],
    message: string
): Promise<boolean> {
    if (state.isServing() && state.hasConnectedClients()) {
        const answer = await state.ask({
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
        'apns push setup cancelled. /rc push-setup expects: APNs Team ID, APNs Key ID, the file path to the .p8 key (Apple → Keys → "Apple Push Notifications" key), and optionally the APNs host. Nothing was written.',
        'info'
    )
    dbgLog('push-setup: cancelled')
}

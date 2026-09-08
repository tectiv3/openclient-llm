/**
 * Subagent Tool - Delegate tasks to specialized agents
 *
 * Spawns a separate `pi` process for each subagent invocation,
 * giving it an isolated context window.
 *
 * Supports three modes:
 *   - Single: { agent: "name", task: "..." }
 *   - Parallel: { tasks: [{ agent: "name", task: "..." }, ...] }
 *   - Chain: { chain: [{ agent: "name", task: "... {previous} ..." }, ...] }
 *
 * Runs children in RPC mode: stdout streams structured events while stdin
 * accepts JSON-line commands (initial task, steer, abort).
 */

import { spawn, type ChildProcess } from 'node:child_process'
import { createHash } from 'node:crypto'
import { EventEmitter } from 'node:events'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import type { Writable } from 'node:stream'
import type { AgentToolResult, ThinkingLevel } from '@earendil-works/pi-agent-core'
import type { Message } from '@earendil-works/pi-ai'
import { StringEnum, uuidv7 } from '@earendil-works/pi-ai'
import {
    CONFIG_DIR_NAME,
    type EventBus,
    type ExtensionAPI,
    type ExtensionContext,
    getAgentDir,
    getMarkdownTheme,
    withFileMutationQueue,
} from '@earendil-works/pi-coding-agent'
import {
    type Component,
    Container,
    Key,
    Markdown,
    matchesKey,
    Spacer,
    Text,
} from '@earendil-works/pi-tui'
import { Type } from 'typebox'
import { type AgentConfig, type AgentScope, discoverAgents } from './agents.ts'

const MAX_PARALLEL_TASKS = 8
const MAX_CONCURRENCY = 4
// A child turn is stdio-silent until the model emits its first token. Local
// LLM providers can take >120s to reach that token on a large context or a
// contended server, so the default is generous rather than "fast kill". Tune
// via PI_SUBAGENT_STALL_TIMEOUT_MS (ms).
const STALL_TIMEOUT_MS = Number(process.env.PI_SUBAGENT_STALL_TIMEOUT_MS ?? 300_000)
const STALL_CHECK_INTERVAL_MS = 10_000
const COLLAPSED_ITEM_COUNT = 10
const PER_TASK_OUTPUT_CAP = 50 * 1024
const SUBAGENTS_DIR_MODE = 0o700
const INSPECT_DEFAULT_LIMIT = 20
const INSPECT_TASK_PREVIEW_CHARS = 200
const INSPECT_ENTRY_PREVIEW_CHARS = 100
const INSPECT_FINAL_OUTPUT_CAP = 2000
const LIST_ID_SHORT_CHARS = 8
const LIST_TASK_PREVIEW_CHARS = 60

// /subagents attach live-view sizing and preview caps. The reserved-rows
// constant leaves room for the dock around the custom component (status,
// editor chrome, footer, margin) so the view never starves the parent
// transcript.
const ATTACH_TASK_PREVIEW_CHARS = 60
const ATTACH_THINKING_PREVIEW_CHARS = 200
const ATTACH_TOOL_OUTPUT_PREVIEW_CHARS = 200
const ATTACH_RESERVED_TERMINAL_ROWS = 6
const ATTACH_MIN_VIEWPORT_LINES = 3

// Registry of live subagent children, keyed by subagent id. Populated on
// spawn, consumed by /subagents attach (live view + ring-buffer replay).
const RING_BUFFER_MAX_EVENTS = 500

type SubagentStreamEvent = { type: string; [key: string]: unknown }

interface ActiveSubagent {
    id: string
    agent: string
    task: string
    proc: ChildProcess
    stdin: Writable
    eventEmitter: EventEmitter
    settled: boolean
    events: SubagentStreamEvent[]
    // Steer handle for a new LLM turn; wired at spawn so the attach view can
    // reach it later (the field also justifies keeping the closure unexported).
    steer?: (message: string) => void
}

const activeSubagents = new Map<string, ActiveSubagent>()

// Global cross-extension bus, handed over by the extension host in the
// default export; processLine runs in child callbacks that can only reach it
// through module scope.
let eventBus: EventBus | undefined

function registerActiveSubagent(entry: ActiveSubagent): void {
    activeSubagents.set(entry.id, entry)
}

function unregisterActiveSubagent(id: string): void {
    activeSubagents.delete(id)
}

// Ring-buffer push: cap retained events so long-running children cannot grow
// memory unboundedly while still keeping recent history for late-attach replay.
function pushSubagentEvent(entry: ActiveSubagent, event: SubagentStreamEvent): void {
    entry.events.push(event)
    if (entry.events.length > RING_BUFFER_MAX_EVENTS) {
        entry.events.splice(0, entry.events.length - RING_BUFFER_MAX_EVENTS)
    }
}

// Zombie prevention: the parent must not leave orphaned children behind when
// it exits, so SIGTERM every live subagent. Only a best-effort signal is
// possible here — the event loop stops once 'exit' handlers return, so no
// SIGKILL escalation sweep can follow.
process.on('exit', () => {
    for (const entry of activeSubagents.values()) {
        try {
            entry.proc.kill('SIGTERM')
        } catch {
            /* already dead */
        }
    }
})

// File-only diagnostics, opt-in via the same gate as rc/debug.ts (PI_RC_DEBUG=1
// or PI_RC_DEBUG_FILE → ~/.pi/agent/rc-debug.log). console.* output lands in
// the TUI, so even lifecycle-only logging must not use it.
function subagentDebugLog(msg: string): void {
    const fromEnv = process.env.PI_RC_DEBUG_FILE?.trim()
    const target =
        fromEnv ||
        (process.env.PI_RC_DEBUG?.trim()
            ? path.join(os.homedir(), '.pi', 'agent', 'rc-debug.log')
            : null)
    if (!target) return
    try {
        fs.appendFileSync(target, `[${new Date().toISOString()}] ${msg}\n`)
    } catch {
        // Diagnostics must never break a run
    }
}

function formatTokens(count: number): string {
    if (count < 1000) return count.toString()
    if (count < 10000) return `${(count / 1000).toFixed(1)}k`
    if (count < 1000000) return `${Math.round(count / 1000)}k`
    return `${(count / 1000000).toFixed(1)}M`
}

function formatUsageStats(
    usage: {
        input: number
        output: number
        cacheRead: number
        cacheWrite: number
        cost: number
        contextTokens?: number
        turns?: number
    },
    model?: string
): string {
    const parts: string[] = []
    if (usage.turns) parts.push(`${usage.turns} turn${usage.turns > 1 ? 's' : ''}`)
    if (usage.input) parts.push(`↑${formatTokens(usage.input)}`)
    if (usage.output) parts.push(`↓${formatTokens(usage.output)}`)
    if (usage.cacheRead) parts.push(`R${formatTokens(usage.cacheRead)}`)
    if (usage.cacheWrite) parts.push(`W${formatTokens(usage.cacheWrite)}`)
    if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`)
    if (usage.contextTokens && usage.contextTokens > 0) {
        parts.push(`ctx:${formatTokens(usage.contextTokens)}`)
    }
    if (model) parts.push(model)
    return parts.join(' ')
}

function previewText(text: string, maxChars: number): string {
    const collapsed = text.replace(/\s+/g, ' ').trim()
    return collapsed.length > maxChars ? `${collapsed.slice(0, maxChars)}...` : collapsed
}

function formatToolCall(
    toolName: string,
    args: Record<string, unknown>,
    themeFg: (color: any, text: string) => string
): string {
    const shortenPath = (p: string) => {
        const home = os.homedir()
        return p.startsWith(home) ? `~${p.slice(home.length)}` : p
    }

    switch (toolName) {
        case 'bash': {
            const command = (args.command as string) || '...'
            const preview = command.length > 60 ? `${command.slice(0, 60)}...` : command
            return themeFg('muted', '$ ') + themeFg('toolOutput', preview)
        }
        case 'read': {
            const rawPath = (args.file_path || args.path || '...') as string
            const filePath = shortenPath(rawPath)
            const offset = args.offset as number | undefined
            const limit = args.limit as number | undefined
            let text = themeFg('accent', filePath)
            if (offset !== undefined || limit !== undefined) {
                const startLine = offset ?? 1
                const endLine = limit !== undefined ? startLine + limit - 1 : ''
                text += themeFg('warning', `:${startLine}${endLine ? `-${endLine}` : ''}`)
            }
            return themeFg('muted', 'read ') + text
        }
        case 'write': {
            const rawPath = (args.file_path || args.path || '...') as string
            const filePath = shortenPath(rawPath)
            const content = (args.content || '') as string
            const lines = content.split('\n').length
            let text = themeFg('muted', 'write ') + themeFg('accent', filePath)
            if (lines > 1) text += themeFg('dim', ` (${lines} lines)`)
            return text
        }
        case 'edit': {
            const rawPath = (args.file_path || args.path || '...') as string
            return themeFg('muted', 'edit ') + themeFg('accent', shortenPath(rawPath))
        }
        case 'ls': {
            const rawPath = (args.path || '.') as string
            return themeFg('muted', 'ls ') + themeFg('accent', shortenPath(rawPath))
        }
        case 'find': {
            const pattern = (args.pattern || '*') as string
            const rawPath = (args.path || '.') as string
            return (
                themeFg('muted', 'find ') +
                themeFg('accent', pattern) +
                themeFg('dim', ` in ${shortenPath(rawPath)}`)
            )
        }
        case 'grep': {
            const pattern = (args.pattern || '') as string
            const rawPath = (args.path || '.') as string
            return (
                themeFg('muted', 'grep ') +
                themeFg('accent', `/${pattern}/`) +
                themeFg('dim', ` in ${shortenPath(rawPath)}`)
            )
        }
        default: {
            const argsStr = JSON.stringify(args)
            const preview = argsStr.length > 50 ? `${argsStr.slice(0, 50)}...` : argsStr
            return themeFg('accent', toolName) + themeFg('dim', ` ${preview}`)
        }
    }
}

interface UsageStats {
    input: number
    output: number
    cacheRead: number
    cacheWrite: number
    cost: number
    contextTokens: number
    turns: number
}

interface SingleResult {
    agent: string
    agentSource: 'user' | 'project' | 'unknown'
    task: string
    subagentId: string
    sessionPath: string
    exitCode: number
    messages: Message[]
    stderr: string
    usage: UsageStats
    model?: string
    stopReason?: string
    aborted?: boolean
    resumeNote?: string
    errorMessage?: string
    step?: number
}

interface SubagentDetails {
    mode: 'single' | 'parallel' | 'chain'
    agentScope: AgentScope
    projectAgentsDir: string | null
    results: SingleResult[]
}

interface SubagentMeta {
    agent: string
    task: string
    model?: string
    thinkingLevel?: ThinkingLevel
    startedAt: string
    promptHash: string
    resumedCount?: number
    status?: 'succeeded' | 'failed' | 'aborted'
    stopReason?: string
    exitCode?: number
    sessionHeaderId?: string
}

interface ResumeTarget {
    id: string
    meta: SubagentMeta
}

function getFinalOutput(messages: Message[]): string {
    for (let i = messages.length - 1; i >= 0; i--) {
        const msg = messages[i]
        if (msg.role === 'assistant') {
            for (const part of msg.content) {
                if (part.type === 'text') return part.text
            }
        }
    }
    return ''
}

function isFailedResult(result: SingleResult): boolean {
    return (
        result.aborted === true ||
        result.exitCode !== 0 ||
        result.stopReason === 'error' ||
        result.stopReason === 'aborted'
    )
}

function getResultOutput(result: SingleResult): string {
    if (isFailedResult(result)) {
        return (
            result.errorMessage ||
            result.stderr ||
            getFinalOutput(result.messages) ||
            '(no output)'
        )
    }
    return getFinalOutput(result.messages) || '(no output)'
}

function sessionArtifactsPersisted(result: SingleResult): boolean {
    if (!result.subagentId) return false
    const { session, meta } = getSubagentFilePaths(result.subagentId)
    return fs.existsSync(session) || fs.existsSync(meta)
}

function formatResumeHint(result: SingleResult): string | null {
    // Resume is only meaningful when spawn artifacts exist; pre-spawn failures
    // (e.g. unknown agent) leave nothing to inspect or resume.
    if (!sessionArtifactsPersisted(result)) return null
    return [
        `Subagent ID: ${result.subagentId}`,
        `Inspect with subagent_inspect; continue with subagent ` +
            `{agent: "${result.agent}", task: "<continuation instruction>", resume: "${result.subagentId}"}.`,
    ].join('\n')
}

function formatFailureReport(result: SingleResult): string {
    const outcome = result.aborted
        ? 'aborted'
        : `failed${result.stopReason && result.stopReason !== 'end' ? ` (${result.stopReason})` : ''}`
    const lines: string[] = [`Agent "${result.agent}" ${outcome}.`]
    const diagnostic = result.errorMessage || result.stderr.trim()
    if (diagnostic) lines.push(diagnostic)
    const partialOutput = getFinalOutput(result.messages)
    if (partialOutput) lines.push(`Partial output:\n${partialOutput}`)
    else if (result.aborted) lines.push('No partial output was persisted before interruption.')
    const hint = formatResumeHint(result)
    if (hint) lines.push(hint)
    return lines.join('\n\n')
}

function truncateParallelOutput(output: string): string {
    const byteLength = Buffer.byteLength(output, 'utf8')
    if (byteLength <= PER_TASK_OUTPUT_CAP) return output

    let truncated = output.slice(0, PER_TASK_OUTPUT_CAP)
    while (Buffer.byteLength(truncated, 'utf8') > PER_TASK_OUTPUT_CAP) {
        truncated = truncated.slice(0, -1)
    }
    return `${truncated}\n\n[Output truncated: ${byteLength - Buffer.byteLength(truncated, 'utf8')} bytes omitted. Full output preserved in tool details.]`
}

type DisplayItem =
    | { type: 'text'; text: string }
    | { type: 'toolCall'; name: string; args: Record<string, any> }

function getDisplayItems(messages: Message[]): DisplayItem[] {
    const items: DisplayItem[] = []
    for (const msg of messages) {
        if (msg.role === 'assistant') {
            for (const part of msg.content) {
                if (part.type === 'text') items.push({ type: 'text', text: part.text })
                else if (part.type === 'toolCall')
                    items.push({ type: 'toolCall', name: part.name, args: part.arguments })
            }
        }
    }
    return items
}

async function mapWithConcurrencyLimit<TIn, TOut>(
    items: TIn[],
    concurrency: number,
    fn: (item: TIn, index: number) => Promise<TOut>
): Promise<TOut[]> {
    if (items.length === 0) return []
    const limit = Math.max(1, Math.min(concurrency, items.length))
    const results: TOut[] = new Array(items.length)
    let nextIndex = 0
    const workers = new Array(limit).fill(null).map(async () => {
        while (true) {
            const current = nextIndex++
            if (current >= items.length) return
            results[current] = await fn(items[current], current)
        }
    })
    await Promise.all(workers)
    return results
}

async function writePromptToTempFile(
    agentName: string,
    prompt: string
): Promise<{ dir: string; filePath: string }> {
    const tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'pi-subagent-'))
    const safeName = agentName.replace(/[^\w.-]+/g, '_')
    const filePath = path.join(tmpDir, `prompt-${safeName}.md`)
    await withFileMutationQueue(filePath, async () => {
        await fs.promises.writeFile(filePath, prompt, { encoding: 'utf-8', mode: 0o600 })
    })
    return { dir: tmpDir, filePath }
}

function getSubagentsDir(): string {
    return path.join(getAgentDir(), 'subagents')
}

function getSubagentFilePaths(subagentId: string): {
    session: string
    pid: string
    meta: string
} {
    return {
        session: path.join(getSubagentsDir(), `${subagentId}.jsonl`),
        pid: path.join(getSubagentsDir(), `${subagentId}.pid`),
        meta: path.join(getSubagentsDir(), `${subagentId}.meta`),
    }
}

function ensureSubagentsDir(): void {
    try {
        fs.mkdirSync(getSubagentsDir(), { recursive: true, mode: SUBAGENTS_DIR_MODE })
        // mkdir's mode is masked by the process umask; enforce the private mode explicitly.
        fs.chmodSync(getSubagentsDir(), SUBAGENTS_DIR_MODE)
    } catch {
        /* persistence setup failures must not crash the delegation; the child run surfaces them */
    }
}

function writeSubagentMetaFile(metaPath: string, meta: SubagentMeta): void {
    try {
        fs.writeFileSync(metaPath, JSON.stringify(meta, null, '\t'), {
            encoding: 'utf-8',
            mode: 0o600,
        })
    } catch {
        /* ignore */
    }
}

function readSessionHeaderId(sessionPath: string): string | undefined {
    try {
        const firstLine = fs.readFileSync(sessionPath, 'utf-8').split('\n', 1)[0]
        const entry = JSON.parse(firstLine)
        if (entry?.type === 'session' && typeof entry.id === 'string') return entry.id
    } catch {
        /* missing session file, torn first line, or unparsable header */
    }
    return undefined
}

function removeSubagentFile(filePath: string): void {
    try {
        fs.rmSync(filePath, { force: true })
    } catch {
        /* ignore */
    }
}

function isProcessAlive(pid: number): boolean {
    try {
        process.kill(pid, 0)
        return true
    } catch (error) {
        // ESRCH means the pid is gone; EPERM means the process exists but is owned by another user.
        return (error as NodeJS.ErrnoException).code === 'EPERM'
    }
}

interface PersistedSubagentEntry {
    id: string
    meta?: SubagentMeta
}

function listPersistedSubagents(): PersistedSubagentEntry[] {
    const dir = getSubagentsDir()
    let metaFiles: string[]
    try {
        metaFiles = fs.readdirSync(dir).filter(file => file.endsWith('.meta'))
    } catch {
        return []
    }
    return metaFiles
        .map(file => {
            const id = file.slice(0, -'.meta'.length)
            try {
                return {
                    id,
                    meta: JSON.parse(
                        fs.readFileSync(path.join(dir, file), 'utf-8')
                    ) as SubagentMeta,
                }
            } catch {
                return { id }
            }
        })
        .sort((a, b) => a.id.localeCompare(b.id))
}

function formatPersistedSubagentsList(entries: PersistedSubagentEntry[]): string[] {
    return entries.map(entry => {
        if (!entry.meta) return `- ${entry.id} — (meta sidecar unreadable)`
        return `- ${entry.id} — agent: ${entry.meta.agent}, status: ${
            entry.meta.status ?? 'unknown'
        }, task: ${previewText(entry.meta.task, LIST_TASK_PREVIEW_CHARS)}`
    })
}

function formatAvailableSubagentsError(resumeId: string): string {
    const entries = listPersistedSubagents()
    if (entries.length === 0) {
        return (
            `No subagent found with id "${resumeId}" (completed runs are cleaned up). ` +
            `No persisted subagent sessions are available in ${getSubagentsDir()}.`
        )
    }
    return [
        `No subagent found with id "${resumeId}" (completed runs are cleaned up). Available subagents:`,
        ...formatPersistedSubagentsList(entries),
    ].join('\n')
}

function formatSessionFileSize(sessionPath: string): string {
    try {
        const bytes = fs.statSync(sessionPath).size
        if (bytes < 1024) return `${bytes} B`
        if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} kB`
        return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
    } catch {
        // pi creates the session file at the first message_end, so runs interrupted
        // before that point have no file yet.
        return 'no file yet'
    }
}

function buildSubagentsListReport(): string {
    // Successful runs are cleaned up, so every persisted entry is running, interrupted, or failed.
    // Missing-meta entries fall back to the uuidv7 id, which embeds a creation timestamp.
    const entries = [...listPersistedSubagents()].sort((a, b) =>
        (b.meta?.startedAt ?? b.id).localeCompare(a.meta?.startedAt ?? a.id)
    )
    if (entries.length === 0) return 'No persisted subagent sessions.'

    const dir = getSubagentsDir()
    const lines = entries.map(entry => {
        const status = formatSubagentStatus(deriveSubagentRunStatus(entry.id, entry.meta))
        const agent = entry.meta?.agent ?? 'unknown'
        const task = entry.meta
            ? previewText(entry.meta.task, LIST_TASK_PREVIEW_CHARS)
            : '(meta sidecar unreadable)'
        const size = formatSessionFileSize(getSubagentFilePaths(entry.id).session)
        return `- ${entry.id.slice(0, LIST_ID_SHORT_CHARS)} — agent: ${agent}, status: ${status}, size: ${size}, task: ${task}`
    })
    return [
        ...lines,
        `${entries.length} persisted subagent session${entries.length === 1 ? '' : 's'} in ${dir}`,
        `inspect: subagent_inspect <id>; resume: subagent {agent, task, resume}; delete: rm ${dir}/<id>.*`,
    ].join('\n')
}

function formatRunningSubagentsList(entries: ActiveSubagent[]): string[] {
    return entries.map(
        entry =>
            `- ${entry.id.slice(0, LIST_ID_SHORT_CHARS)} — agent: ${entry.agent}, task: ${previewText(
                entry.task,
                LIST_TASK_PREVIEW_CHARS
            )}`
    )
}

function resolveAttachTarget(id?: string): ActiveSubagent | string {
    // Settled children are on their way out of the registry (proc 'close'
    // removes them); attaching would auto-detach instantly, so they are not
    // offered as targets.
    const running = [...activeSubagents.values()].filter(entry => !entry.settled)

    if (id) {
        const exact = running.find(entry => entry.id === id)
        if (exact) return exact
        const matches = running.filter(entry => entry.id.startsWith(id))
        if (matches.length === 1) return matches[0]
        if (matches.length > 1) {
            return [
                `Ambiguous subagent id "${id}" matches ${matches.length} running subagents:`,
                ...formatRunningSubagentsList(matches),
                'Use more characters or the full id.',
            ].join('\n')
        }
        if (running.length === 0) {
            return `No running subagent matches "${id}". Start one with the subagent tool first.`
        }
        return [
            `No running subagent matches "${id}". Running subagents:`,
            ...formatRunningSubagentsList(running),
        ].join('\n')
    }

    if (running.length === 0) {
        return (
            'No running subagents. Delegate a task with the subagent tool and run ' +
            '/subagents attach while it is still running.'
        )
    }
    if (running.length === 1) return running[0]
    return [
        `${running.length} subagents are running:`,
        ...formatRunningSubagentsList(running),
        'Attach with: /subagents attach <id>',
    ].join('\n')
}

// Transcript items for the attach view. Only *_end events render: the ring
// buffer also keeps message_update frames, but streaming those would rebuild
// the view per token — the completed message_end supersedes them.
function buildAttachItems(
    events: SubagentStreamEvent[],
    themeFg: (color: any, text: string) => string
): Component[] {
    const items: Component[] = []

    const pushToolResult = (msg: Message) => {
        for (const part of msg.content) {
            if (part.type === 'text' && part.text.trim()) {
                items.push(
                    new Text(
                        themeFg(
                            'toolOutput',
                            previewText(part.text, ATTACH_TOOL_OUTPUT_PREVIEW_CHARS)
                        ),
                        0,
                        0
                    )
                )
                return
            }
        }
    }

    for (const event of events) {
        if (event.type !== 'message_end' && event.type !== 'tool_result_end') continue
        const msg = event.message as Message | undefined
        if (!msg) continue
        if (msg.role === 'toolResult') {
            pushToolResult(msg)
        } else if (msg.role === 'assistant') {
            for (const part of msg.content) {
                if (part.type === 'text' && part.text.trim()) {
                    items.push(new Markdown(part.text, 0, 0, getMarkdownTheme()))
                } else if (part.type === 'thinking' && part.thinking.trim()) {
                    items.push(
                        new Text(
                            themeFg(
                                'dim',
                                previewText(part.thinking, ATTACH_THINKING_PREVIEW_CHARS)
                            ),
                            0,
                            0
                        )
                    )
                } else if (part.type === 'toolCall') {
                    items.push(
                        new Text(
                            themeFg('muted', '→ ') +
                                formatToolCall(part.name, part.arguments, themeFg),
                            0,
                            0
                        )
                    )
                }
            }
        }
    }
    return items
}

async function attachToSubagent(ctx: ExtensionContext, entry: ActiveSubagent): Promise<void> {
    const shortId = entry.id.slice(0, LIST_ID_SHORT_CHARS)

    await ctx.ui.custom<void>((tui, theme, _keybindings, done) => {
        let finished = false
        let followEnd = true
        let scrollTop = 0
        let cachedWidth = -1
        let cachedLines: string[] | undefined

        // The custom component lives in the editor dock, outside the layout
        // engine's reach — a nested ScrollView cannot scroll there (no
        // bounded viewport, no scroll translation; verified against
        // pi-tui's layout walk). Scrolling is manual: render every
        // transcript line, slice a window, and clamp the total height so the
        // dock never starves the parent transcript.
        const maxViewportLines = () =>
            Math.max(
                ATTACH_MIN_VIEWPORT_LINES,
                tui.terminal.rows - ATTACH_RESERVED_TERMINAL_ROWS
            )

        function rebuild(width: number): string[] {
            if (cachedLines && cachedWidth === width) return cachedLines
            const items = buildAttachItems(entry.events, theme.fg.bind(theme))
            const lines: string[] = []
            for (let i = 0; i < items.length; i++) {
                if (i > 0) lines.push('')
                lines.push(...items[i].render(width))
            }
            cachedLines = lines
            cachedWidth = width
            return lines
        }

        function finish(): void {
            if (finished) return
            finished = true
            entry.eventEmitter.off('event', onEvent)
            entry.proc.removeListener('close', finish)
            done()
        }

        function onEvent(event: SubagentStreamEvent): void {
            if (event.type === 'agent_settled') {
                finish()
                return
            }
            cachedLines = undefined
            tui.requestRender()
        }

        entry.eventEmitter.on('event', onEvent)
        // Safety net: the child can die without an agent_settled frame
        // (watchdog kill, crash) — detach instead of showing a frozen view.
        entry.proc.once('close', finish)

        function render(width: number): string[] {
            const lines = rebuild(width)
            const viewportHeight = Math.min(lines.length, maxViewportLines())
            const maxScrollTop = Math.max(0, lines.length - viewportHeight)
            // followEnd pins the window to the newest output; scrolling up
            // suspends the pin until the user jumps back with End.
            scrollTop = followEnd ? maxScrollTop : Math.min(scrollTop, maxScrollTop)

            const header = [
                theme.fg('toolTitle', theme.bold('attach ')) +
                    theme.fg('accent', entry.agent) +
                    theme.fg('muted', ` ${shortId}`),
                theme.fg('dim', previewText(entry.task, ATTACH_TASK_PREVIEW_CHARS)),
                followEnd
                    ? theme.fg('dim', 'Esc detach · live')
                    : theme.fg('dim', `↑${scrollTop} above · End → live · Esc detach`),
            ]
            return [...header, '', ...lines.slice(scrollTop, scrollTop + viewportHeight)]
        }

        function handleInput(data: string): void {
            if (matchesKey(data, Key.escape)) {
                finish()
                return
            }
            if (!cachedLines) return
            const viewportHeight = Math.min(cachedLines.length, maxViewportLines())
            const maxScrollTop = Math.max(0, cachedLines.length - viewportHeight)
            if (matchesKey(data, Key.up)) {
                scrollTop = Math.max(0, scrollTop - 1)
                followEnd = false
            } else if (matchesKey(data, Key.down)) {
                scrollTop = Math.min(maxScrollTop, scrollTop + 1)
                followEnd = scrollTop >= maxScrollTop
            } else if (matchesKey(data, Key.pageUp)) {
                scrollTop = Math.max(0, scrollTop - viewportHeight)
                followEnd = false
            } else if (matchesKey(data, Key.pageDown)) {
                scrollTop = Math.min(maxScrollTop, scrollTop + viewportHeight)
                followEnd = scrollTop >= maxScrollTop
            } else if (matchesKey(data, Key.home)) {
                scrollTop = 0
                followEnd = false
            } else if (matchesKey(data, Key.end)) {
                followEnd = true
            } else {
                return
            }
            tui.requestRender()
        }

        return {
            render,
            invalidate: () => {
                cachedLines = undefined
            },
            handleInput,
            dispose: () => finish(),
        }
    })

    // custom() resolving means finish() ran (Esc, settled, or proc close)
    // and the parent editor is restored — a notify is safe here.
    ctx.ui.notify(`Detached from subagent ${shortId}.`, 'info')
}

function resolveResumeTarget(
    resumeId: string,
    agentName: string,
    agents: AgentConfig[]
): ResumeTarget | string {
    const {
        session: sessionPath,
        pid: pidPath,
        meta: metaPath,
    } = getSubagentFilePaths(resumeId)

    if (!fs.existsSync(sessionPath)) return formatAvailableSubagentsError(resumeId)

    if (fs.existsSync(pidPath)) {
        const pid = Number.parseInt(fs.readFileSync(pidPath, 'utf-8').trim(), 10)
        if (pid > 0 && isProcessAlive(pid)) {
            return (
                `Subagent "${resumeId}" is still running (pid ${pid}). ` +
                'Wait for it to finish or inspect it with subagent_inspect instead of resuming.'
            )
        }
        // Stale pidfile: the parent died before cleanup. Unlock and treat the run as interrupted.
        removeSubagentFile(pidPath)
    }

    let meta: SubagentMeta
    try {
        meta = JSON.parse(fs.readFileSync(metaPath, 'utf-8')) as SubagentMeta
    } catch {
        return `Cannot resume "${resumeId}": its meta sidecar is missing or unreadable. Start a fresh delegation instead.`
    }

    if (meta.agent !== agentName) {
        return (
            `Cannot resume "${resumeId}" with agent "${agentName}": the original run used agent "${meta.agent}". ` +
            'Resuming under a different agent changes the system prompt and toolset; use the original agent.'
        )
    }

    const agent = agents.find(a => a.name === agentName)
    const currentPromptHash = agent
        ? createHash('sha256').update(agent.systemPrompt).digest('hex')
        : undefined
    if (!agent || currentPromptHash !== meta.promptHash) {
        return `Cannot resume "${resumeId}": the "${agentName}" agent definition changed since the original run; start a fresh delegation instead.`
    }

    return { id: resumeId, meta }
}

type InspectTarget = { id: string } | { error: string }

function resolveInspectTarget(requestedId: string): InspectTarget {
    // An exact id is honored even when its meta sidecar is missing (jsonl-only runs).
    const { session, pid, meta } = getSubagentFilePaths(requestedId)
    if (fs.existsSync(session) || fs.existsSync(pid) || fs.existsSync(meta))
        return { id: requestedId }

    const matches = listPersistedSubagents().filter(entry => entry.id.startsWith(requestedId))
    if (matches.length === 1) return { id: matches[0].id }
    if (matches.length > 1) {
        return {
            error: [
                `Ambiguous subagent id "${requestedId}" matches ${matches.length} persisted runs:`,
                ...formatPersistedSubagentsList(matches),
            ].join('\n'),
        }
    }
    return {
        error:
            formatAvailableSubagentsError(requestedId) +
            '\n' +
            'A bare id with no artifacts is indistinguishable from a successfully completed run ' +
            "(artifacts are deleted on success); its output is in the parent session's tool result.",
    }
}

function readSubagentPid(pidPath: string): number | undefined {
    try {
        const pid = Number.parseInt(fs.readFileSync(pidPath, 'utf-8').trim(), 10)
        return Number.isNaN(pid) || pid <= 0 ? undefined : pid
    } catch {
        return undefined
    }
}

interface SubagentRunStatus {
    status: string
    runningPid?: number
}

function deriveSubagentRunStatus(
    subagentId: string,
    meta: SubagentMeta | undefined
): SubagentRunStatus {
    const { pid: pidPath } = getSubagentFilePaths(subagentId)
    const pid = readSubagentPid(pidPath)
    if (pid !== undefined && isProcessAlive(pid)) return { status: 'running', runningPid: pid }
    // Stale pidfile (parent crashed before cleanup): unlock so the run stays resumable.
    if (pid !== undefined) removeSubagentFile(pidPath)
    return { status: meta?.status ?? 'unknown' }
}

function formatSubagentStatus(runStatus: SubagentRunStatus): string {
    return runStatus.runningPid !== undefined
        ? `${runStatus.status} (pid ${runStatus.runningPid})`
        : runStatus.status
}

function parseSubagentTranscript(sessionPath: string): Message[] {
    let content: string
    try {
        content = fs.readFileSync(sessionPath, 'utf-8')
    } catch {
        return []
    }
    const messages: Message[] = []
    for (const line of content.split('\n')) {
        if (!line.trim()) continue
        let entry: any
        try {
            entry = JSON.parse(line)
        } catch {
            // Torn lines (child killed mid-append) and unknown/future entry types
            // (session, model_change, thinking_level_change, compaction, ...) are skipped.
            continue
        }
        if (entry?.type === 'message' && entry.message) messages.push(entry.message as Message)
    }
    return messages
}

function computeTranscriptUsage(messages: Message[]): {
    usage: UsageStats
    model: string | undefined
} {
    const usage: UsageStats = {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        cost: 0,
        contextTokens: 0,
        turns: 0,
    }
    let model: string | undefined
    for (const msg of messages) {
        if (msg.role !== 'assistant') continue
        usage.turns++
        // Mirrors runSingleAgent's stdout accounting so inspect totals match live results.
        if (msg.usage) {
            usage.input += msg.usage.input || 0
            usage.output += msg.usage.output || 0
            usage.cacheRead += msg.usage.cacheRead || 0
            usage.cacheWrite += msg.usage.cacheWrite || 0
            usage.cost += msg.usage.cost?.total || 0
            usage.contextTokens = msg.usage.totalTokens || 0
        }
        if (!model && msg.model) model = msg.model
    }
    return { usage, model }
}

// formatToolCall renders with theme colors for the TUI; model-facing tool-result text must stay plain.
function plainThemeFg(_color: any, text: string): string {
    return text
}

function buildSubagentInspectReport(subagentId: string, limit: number): string {
    const { session: sessionPath, meta: metaPath } = getSubagentFilePaths(subagentId)

    let meta: SubagentMeta | undefined
    try {
        meta = JSON.parse(fs.readFileSync(metaPath, 'utf-8')) as SubagentMeta
    } catch {
        /* absent or unreadable sidecar */
    }

    const runStatus = deriveSubagentRunStatus(subagentId, meta)
    const status = runStatus.status

    const lines: string[] = [`Subagent: ${subagentId}`]
    lines.push(`Status: ${formatSubagentStatus(runStatus)}`)
    if (meta) {
        lines.push(`Agent: ${meta.agent}`)
        lines.push(`Task: ${previewText(meta.task, INSPECT_TASK_PREVIEW_CHARS)}`)
        if (meta.model) lines.push(`Model: ${meta.model}`)
        lines.push(`Started: ${meta.startedAt}`)
        if ((meta.resumedCount ?? 0) > 0) {
            lines.push(
                `Resumed: ${meta.resumedCount} time${meta.resumedCount === 1 ? '' : 's'}`
            )
        }
        if (status === 'failed' || status === 'aborted') {
            if (meta.stopReason) lines.push(`Stop reason: ${meta.stopReason}`)
            if (meta.exitCode !== undefined) lines.push(`Exit code: ${meta.exitCode}`)
        }
    } else {
        lines.push('Meta: missing (agent, task, and model unknown)')
    }

    const messages = parseSubagentTranscript(sessionPath)
    if (messages.length === 0) {
        // pi creates the session file at the first message_end, so runs interrupted
        // before that point have nothing to tail.
        lines.push('No transcript persisted yet.')
        return lines.join('\n')
    }

    const { usage, model } = computeTranscriptUsage(messages)
    const usageStr = formatUsageStats(usage, model ?? meta?.model)
    if (usageStr) lines.push(`Usage: ${usageStr}`)

    const items = getDisplayItems(messages)
    const tail = items.slice(-limit)
    lines.push(`--- Transcript: last ${tail.length} of ${items.length} entries ---`)
    for (const item of tail) {
        if (item.type === 'text') {
            const preview = item.text.replace(/\s+/g, ' ').trim()
            lines.push(
                preview.length > INSPECT_ENTRY_PREVIEW_CHARS
                    ? `${preview.slice(0, INSPECT_ENTRY_PREVIEW_CHARS)}...`
                    : preview
            )
        } else {
            lines.push(formatToolCall(item.name, item.args, plainThemeFg))
        }
    }

    const finalOutput = getFinalOutput(messages)
    if (finalOutput) {
        lines.push('--- Final output ---')
        lines.push(
            finalOutput.length > INSPECT_FINAL_OUTPUT_CAP
                ? `${finalOutput.slice(0, INSPECT_FINAL_OUTPUT_CAP)}...`
                : finalOutput
        )
    }

    if ((status === 'failed' || status === 'aborted') && meta) {
        lines.push(
            `Resume with subagent {agent: "${meta.agent}", task: "<continuation instruction>", resume: "${subagentId}"}.`
        )
    }

    return lines.join('\n')
}

function getPiInvocation(args: string[]): { command: string; args: string[] } {
    const currentScript = process.argv[1]
    const isBunVirtualScript = currentScript?.startsWith('/$bunfs/root/')
    if (currentScript && !isBunVirtualScript && fs.existsSync(currentScript)) {
        return { command: process.execPath, args: [currentScript, ...args] }
    }

    const execName = path.basename(process.execPath).toLowerCase()
    const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName)
    if (!isGenericRuntime) {
        return { command: process.execPath, args }
    }

    return { command: 'pi', args }
}

type OnUpdateCallback = (partial: AgentToolResult<SubagentDetails>) => void

interface DispatchDefaults {
    model?: string
    thinkingLevel?: ThinkingLevel
}

async function runSingleAgent(
    defaultCwd: string,
    dispatchDefaults: DispatchDefaults,
    agents: AgentConfig[],
    agentName: string,
    task: string,
    cwd: string | undefined,
    step: number | undefined,
    signal: AbortSignal | undefined,
    onUpdate: OnUpdateCallback | undefined,
    makeDetails: (results: SingleResult[]) => SubagentDetails,
    resume?: ResumeTarget
): Promise<SingleResult> {
    const subagentId = resume?.id ?? uuidv7()
    const {
        session: sessionPath,
        pid: pidPath,
        meta: metaPath,
    } = getSubagentFilePaths(subagentId)
    const agent = agents.find(a => a.name === agentName)

    if (!agent) {
        const available = agents.map(a => `"${a.name}"`).join(', ') || 'none'
        return {
            agent: agentName,
            agentSource: 'unknown',
            task,
            subagentId,
            sessionPath,
            exitCode: 1,
            messages: [],
            stderr: `Unknown agent: "${agentName}". Available agents: ${available}.`,
            usage: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                cost: 0,
                contextTokens: 0,
                turns: 0,
            },
            step,
        }
    }

    const args: string[] = ['--mode', 'rpc', '--session', sessionPath]
    // Resumes re-pass the recorded model/thinking because they reflect the original run;
    // continuity matters more than the current dispatch defaults.
    let model: string | undefined
    let thinkingLevel: ThinkingLevel | undefined
    let resumeNote: string | undefined
    if (resume) {
        model = resume.meta.model
        thinkingLevel = resume.meta.thinkingLevel
        if (!model) {
            model = dispatchDefaults.model
            resumeNote = model
                ? `Resumed with the current dispatch model (${model}); the original run recorded none.`
                : 'Resumed without a recorded model; the child used its own default model.'
        }
    } else {
        model = agent.model ?? dispatchDefaults.model
        // Only agents without a pinned model inherit the dispatch thinking level.
        if (!agent.model) thinkingLevel = dispatchDefaults.thinkingLevel
    }
    if (model) args.push('--model', model)
    if (thinkingLevel) args.push('--thinking', thinkingLevel)
    if (agent.tools && agent.tools.length > 0) args.push('--tools', agent.tools.join(','))

    let tmpPromptDir: string | null = null
    let tmpPromptPath: string | null = null

    const currentResult: SingleResult = {
        agent: agentName,
        agentSource: agent.source,
        task,
        subagentId,
        sessionPath,
        exitCode: 0,
        messages: [],
        stderr: '',
        usage: {
            input: 0,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            cost: 0,
            contextTokens: 0,
            turns: 0,
        },
        model,
        step,
        resumeNote,
    }

    const emitUpdate = () => {
        if (onUpdate) {
            onUpdate({
                content: [
                    {
                        type: 'text',
                        text: getFinalOutput(currentResult.messages) || '(running...)',
                    },
                ],
                details: makeDetails([currentResult]),
            })
        }
    }

    try {
        if (agent.systemPrompt.trim()) {
            const tmp = await writePromptToTempFile(agent.name, agent.systemPrompt)
            tmpPromptDir = tmp.dir
            tmpPromptPath = tmp.filePath
            args.push('--append-system-prompt', tmpPromptPath)
        }

        let wasAborted = false

        ensureSubagentsDir()
        const spawnMeta: SubagentMeta = {
            agent: agentName,
            task,
            model,
            thinkingLevel,
            startedAt: new Date().toISOString(),
            promptHash: createHash('sha256').update(agent.systemPrompt).digest('hex'),
            resumedCount: resume ? (resume.meta.resumedCount ?? 0) + 1 : undefined,
        }
        writeSubagentMetaFile(metaPath, spawnMeta)

        const tag = subagentId.slice(0, 8)
        const debug = (msg: string) => subagentDebugLog(`[subagent:${tag}] ${msg}`)

        const exitCode = await new Promise<number>(resolve => {
            const invocation = getPiInvocation(args)
            debug(`spawn: ${invocation.command} ${invocation.args.join(' ')}`)
            const proc = spawn(invocation.command, invocation.args, {
                cwd: cwd ?? defaultCwd,
                shell: false,
                stdio: ['pipe', 'pipe', 'pipe'],
            })
            debug(`pid: ${proc.pid ?? 'none'}`)
            if (proc.pid !== undefined) {
                try {
                    fs.writeFileSync(pidPath, `${proc.pid}\n`, {
                        encoding: 'utf-8',
                        mode: 0o600,
                    })
                } catch {
                    /* ignore */
                }
            }
            let buffer = ''
            let resolved = false
            let lastActivityTime = Date.now()
            let eventCount = 0
            let lastEventType = ''
            let stdinClosed = false

            const safeResolve = (code: number, source: string) => {
                if (resolved) {
                    debug(`safeResolve (${source}): already resolved, ignoring code=${code}`)
                    return
                }
                resolved = true
                debug(
                    `safeResolve (${source}): code=${code}, events=${eventCount}, last=${lastEventType}`
                )
                clearInterval(stallWatchdog)
                resolve(code)
            }

            const drainBuffer = () => {
                try {
                    if (buffer.trim()) processLine(buffer)
                } catch {
                    /* final-line parse must not prevent resolve */
                }
                buffer = ''
            }

            // rpc-mode children take newline-terminated JSON commands on stdin.
            // Writes return false when the kernel buffer is full — Node still
            // queues them, so a false return is logged, not treated as failure
            // (steers are small/rare).
            const writeChildStdin = (command: Record<string, unknown>) => {
                try {
                    const ok = proc.stdin.write(`${JSON.stringify(command)}\n`)
                    if (ok === false)
                        debug(`stdin backpressure after ${String(command.type)} write`)
                } catch (err) {
                    debug(
                        `stdin write failed (${String(command.type)}): ${
                            err instanceof Error ? err.message : String(err)
                        }`
                    )
                }
            }

            // Auto-responder for extension UI dialogs raised inside the child:
            // children run headless, so confirm/select/input/editor requests
            // hang forever without a reply. Reply with conservative defaults
            // (deny confirms, cancel the rest) instead of hanging — forwarding
            // dialogs to the attached user is future work (spec §5).
            const handleExtensionUiRequest = (event: any) => {
                const method = String(event.method ?? '')
                const id = event.id
                switch (method) {
                    case 'confirm':
                        // Deny — never auto-approve destructive operations.
                        writeChildStdin({
                            type: 'extension_ui_response',
                            id,
                            confirmed: false,
                        })
                        debug('extension_ui: confirm → denied')
                        break
                    case 'select': {
                        const options = Array.isArray(event.options) ? event.options : []
                        if (options.length > 0) {
                            writeChildStdin({
                                type: 'extension_ui_response',
                                id,
                                value: options[0],
                            })
                            debug(`extension_ui: select → first of ${options.length} options`)
                        } else {
                            writeChildStdin({
                                type: 'extension_ui_response',
                                id,
                                cancelled: true,
                            })
                            debug('extension_ui: select → cancelled (no options)')
                        }
                        break
                    }
                    case 'input':
                    case 'editor':
                        // rpc mode awaits a reply for these (pendingExtensionRequests);
                        // cancelling prevents an indefinite hang.
                        writeChildStdin({ type: 'extension_ui_response', id, cancelled: true })
                        debug(`extension_ui: ${method} → cancelled`)
                        break
                    case 'notify':
                    case 'setStatus':
                    case 'setWidget':
                    case 'setTitle':
                    case 'set_editor_text':
                        // Fire-and-forget methods — rpc mode expects no reply.
                        debug(`extension_ui: ${method} → fire-and-forget`)
                        break
                    default:
                        debug(`extension_ui: unknown method "${method}" → no reply`)
                }
            }

            // A steer starts a new LLM turn that can be legitimately silent
            // for longer than the stall timeout during prefill; resetting the
            // activity timer keeps the watchdog from killing a healthy child.
            const steerFn = (message: string) => {
                writeChildStdin({ type: 'steer', message })
                lastActivityTime = Date.now()
            }

            // rpc mode ignores positional CLI args, so the task travels as the
            // first stdin prompt.
            writeChildStdin({ type: 'prompt', message: `Task: ${task}` })

            const entry: ActiveSubagent = {
                id: subagentId,
                agent: agentName,
                task,
                proc,
                stdin: proc.stdin,
                eventEmitter: new EventEmitter(),
                settled: false,
                events: [],
                steer: steerFn,
            }
            registerActiveSubagent(entry)

            const processLine = (line: string) => {
                if (!line.trim()) return
                let event: any
                try {
                    event = JSON.parse(line)
                } catch {
                    return
                }
                lastActivityTime = Date.now()
                const type = event.type ?? 'unknown'

                // rpc-mode-only frames (verified against
                // packages/coding-agent/src/modes/rpc/rpc-mode.ts). They sit
                // after the watchdog reset so a frame flood counts as genuine
                // stdout activity, but before eventCount so command acks and
                // control frames stay out of transcript accounting.
                if (type === 'response') return // command ack, not a transcript event
                if (type === 'extension_error') {
                    debug(
                        `extension_error: ${String(event.extensionPath ?? '?')} ${String(event.error ?? '')}`
                    )
                    return
                }
                if (type === 'extension_ui_request') {
                    handleExtensionUiRequest(event)
                    return
                }

                eventCount++
                lastEventType = type

                // Forward before the dispatch chain so events that also hit
                // message_end / tool_result_end are forwarded too. Everything
                // non-control is transcript, including high-frequency
                // *_update frames the attach view streams; the ring-buffer
                // cap bounds memory.
                pushSubagentEvent(entry, event)
                entry.eventEmitter.emit('event', event)
                eventBus?.emit('subagent:event', { subagentId, agent: agentName, event })

                if (type === 'agent_settled') {
                    // Normal lifecycle end, never an error. Closing stdin makes
                    // the rpc child exit via its stdin-'end' → shutdown() path;
                    // guarded so the first frame is the only close attempt.
                    entry.settled = true
                    if (!stdinClosed) {
                        stdinClosed = true
                        try {
                            proc.stdin.end()
                        } catch {
                            /* stream already destroyed */
                        }
                        debug('agent_settled: stdin closed for clean child shutdown')
                    }
                } else if (event.type === 'message_end' && event.message) {
                    const msg = event.message as Message
                    currentResult.messages.push(msg)
                    debug(`message_end: role=${msg.role} stopReason=${msg.stopReason ?? '-'}`)

                    if (msg.role === 'assistant') {
                        currentResult.usage.turns++
                        const usage = msg.usage
                        if (usage) {
                            currentResult.usage.input += usage.input || 0
                            currentResult.usage.output += usage.output || 0
                            currentResult.usage.cacheRead += usage.cacheRead || 0
                            currentResult.usage.cacheWrite += usage.cacheWrite || 0
                            currentResult.usage.cost += usage.cost?.total || 0
                            currentResult.usage.contextTokens = usage.totalTokens || 0
                        }
                        if (!currentResult.model && msg.model) currentResult.model = msg.model
                        if (msg.stopReason) currentResult.stopReason = msg.stopReason
                        if (msg.errorMessage) currentResult.errorMessage = msg.errorMessage
                    }
                    emitUpdate()
                } else if (event.type === 'tool_result_end' && event.message) {
                    currentResult.messages.push(event.message as Message)
                    debug(`tool_result_end`)
                    emitUpdate()
                } else if (
                    type !== 'unknown' &&
                    type !== 'message_update' &&
                    type !== 'tool_execution_update'
                ) {
                    // Per-event logging is for low-rate lifecycle events only:
                    // message_update / tool_execution_update fire per streaming
                    // chunk and would spam the parent TUI. The activity tracking
                    // above still records them for the stall diagnostic.
                    debug(`event: ${type}`)
                }
            }

            proc.stdout.on('data', data => {
                lastActivityTime = Date.now()
                buffer += data.toString()
                const lines = buffer.split('\n')
                buffer = lines.pop() || ''
                for (const line of lines) processLine(line)
            })

            proc.stderr.on('data', data => {
                lastActivityTime = Date.now()
                currentResult.stderr += data.toString()
            })

            proc.on('close', (code, killSignal) => {
                debug(`close: code=${code} signal=${killSignal ?? '-'}`)
                // 'close' fires after 'exit' and also after 'error' (spawn
                // failures emit 'error' then 'close'), so this single
                // unregister point covers every exit path.
                unregisterActiveSubagent(subagentId)
                drainBuffer()
                safeResolve(killSignal ? 1 : (code ?? 0), 'close')
            })

            // `close` waits for stdio streams to end, which hangs when a
            // grandchild (e.g. a backgrounded bash tool) inherited the pipe.
            // Fall back to resolving shortly after the process itself exits.
            proc.on('exit', (code, killSignal) => {
                debug(`exit: code=${code} signal=${killSignal ?? '-'}`)
                const exitValue = killSignal ? 1 : (code ?? 0)
                const fallback = setTimeout(() => {
                    // The timer fires even when close already resolved; without
                    // this check every run logged a false "close did not fire".
                    if (resolved) return
                    debug('exit fallback: close did not fire in 3s, destroying streams')
                    proc.stdout?.destroy()
                    proc.stderr?.destroy()
                    drainBuffer()
                    safeResolve(exitValue, 'exit-fallback')
                }, 3000)
                fallback.unref()
            })

            proc.on('error', err => {
                debug(`error: ${err.message}`)
                safeResolve(1, 'error')
            })

            // Watchdog: kill the child if stdout+stderr go silent for too long.
            // Legitimate long operations (bash tools) still produce stderr
            // progress; true silence means the child is stuck.
            const stallWatchdog = setInterval(() => {
                const silentMs = Date.now() - lastActivityTime
                if (silentMs >= STALL_TIMEOUT_MS) {
                    debug(
                        `stall watchdog: no activity for ${Math.round(silentMs / 1000)}s, ` +
                            `events=${eventCount}, last=${lastEventType}, killing child`
                    )
                    clearInterval(stallWatchdog)
                    proc.kill('SIGTERM')
                    setTimeout(() => {
                        try {
                            if (!proc.killed) proc.kill('SIGKILL')
                        } catch {
                            /* ignore */
                        }
                    }, 5000)
                }
            }, STALL_CHECK_INTERVAL_MS)
            stallWatchdog.unref()

            if (signal) {
                const killProc = () => {
                    wasAborted = true
                    debug('abort signal received, killing child')
                    proc.kill('SIGTERM')
                    setTimeout(() => {
                        if (!proc.killed) proc.kill('SIGKILL')
                    }, 5000)
                }
                if (signal.aborted) killProc()
                else signal.addEventListener('abort', killProc, { once: true })
            }
        })
        debug(`promise resolved: exitCode=${exitCode}`)

        currentResult.exitCode = exitCode
        if (wasAborted) {
            currentResult.aborted = true
            currentResult.stopReason = 'aborted'
        }

        const status = wasAborted
            ? 'aborted'
            : isFailedResult(currentResult)
              ? 'failed'
              : 'succeeded'
        removeSubagentFile(pidPath)
        if (status === 'succeeded') {
            removeSubagentFile(sessionPath)
            removeSubagentFile(metaPath)
        } else {
            writeSubagentMetaFile(metaPath, {
                ...spawnMeta,
                status,
                stopReason: currentResult.stopReason,
                exitCode,
                sessionHeaderId: readSessionHeaderId(sessionPath),
            })
        }

        debug(`returning: status=${status} stopReason=${currentResult.stopReason ?? '-'}`)
        return currentResult
    } finally {
        if (tmpPromptPath)
            try {
                fs.unlinkSync(tmpPromptPath)
            } catch {
                /* ignore */
            }
        if (tmpPromptDir)
            try {
                fs.rmdirSync(tmpPromptDir)
            } catch {
                /* ignore */
            }
    }
}

const TaskItem = Type.Object({
    agent: Type.String({ description: 'Name of the agent to invoke' }),
    task: Type.String({ description: 'Task to delegate to the agent' }),
    cwd: Type.Optional(
        Type.String({ description: 'Working directory for the agent process' })
    ),
})

const ChainItem = Type.Object({
    agent: Type.String({ description: 'Name of the agent to invoke' }),
    task: Type.String({
        description: 'Task with optional {previous} placeholder for prior output',
    }),
    cwd: Type.Optional(
        Type.String({ description: 'Working directory for the agent process' })
    ),
})

const AgentScopeSchema = StringEnum(['user', 'project', 'both'] as const, {
    description:
        'Which agent directories to use. Default: "user". Use "both" to include project-local agents.',
    default: 'user',
})

const SubagentParams = Type.Object({
    agent: Type.Optional(
        Type.String({ description: 'Name of the agent to invoke (for single mode)' })
    ),
    task: Type.Optional(Type.String({ description: 'Task to delegate (for single mode)' })),
    resume: Type.Optional(
        Type.String({
            description: 'Id of a persisted subagent run to resume (single mode only)',
        })
    ),
    tasks: Type.Optional(
        Type.Array(TaskItem, { description: 'Array of {agent, task} for parallel execution' })
    ),
    chain: Type.Optional(
        Type.Array(ChainItem, {
            description: 'Array of {agent, task} for sequential execution',
        })
    ),
    agentScope: Type.Optional(AgentScopeSchema),
    confirmProjectAgents: Type.Optional(
        Type.Boolean({
            description: 'Prompt before running project-local agents. Default: true.',
            default: true,
        })
    ),
    cwd: Type.Optional(
        Type.String({ description: 'Working directory for the agent process (single mode)' })
    ),
})

const SubagentInspectParams = Type.Object({
    id: Type.String({ description: 'Subagent id (exact filename id or unique prefix)' }),
    limit: Type.Optional(
        Type.Number({
            description: 'Number of transcript entries to show from the end',
            minimum: 1,
        })
    ),
})

export default function (pi: ExtensionAPI) {
    eventBus = pi.events

    pi.registerTool({
        name: 'subagent',
        label: 'Subagent',
        description: [
            'Delegate tasks to specialized subagents with isolated context.',
            'Modes: single (agent + task), parallel (tasks array), chain (sequential with {previous} placeholder).',
            'Resume: in single mode pass resume: <subagentId> to continue a persisted interrupted/failed run ' +
                '(agent must match the original run).',
            `Default agent scope is "user" (from ${path.join(getAgentDir(), 'agents')}).`,
            `To enable project-local agents in ${CONFIG_DIR_NAME}/agents, set agentScope: "both" (or "project").`,
        ].join(' '),
        parameters: SubagentParams,

        async execute(_toolCallId, params, signal, onUpdate, ctx) {
            const agentScope: AgentScope = params.agentScope ?? 'user'
            const dispatchDefaults: DispatchDefaults = {
                model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined,
                thinkingLevel: ctx.thinkingLevel,
            }
            const discovery = discoverAgents(ctx.cwd, agentScope)
            const agents = discovery.agents
            const confirmProjectAgents = params.confirmProjectAgents ?? true

            const hasChain = (params.chain?.length ?? 0) > 0
            const hasTasks = (params.tasks?.length ?? 0) > 0
            const hasSingle = Boolean(params.agent && params.task)
            const modeCount = Number(hasChain) + Number(hasTasks) + Number(hasSingle)

            const makeDetails =
                (mode: 'single' | 'parallel' | 'chain') =>
                (results: SingleResult[]): SubagentDetails => ({
                    mode,
                    agentScope,
                    projectAgentsDir: discovery.projectAgentsDir,
                    results,
                })

            if (modeCount !== 1) {
                const available =
                    agents.map(a => `${a.name} (${a.source})`).join(', ') || 'none'
                return {
                    content: [
                        {
                            type: 'text',
                            text: `Invalid parameters. Provide exactly one mode.\nAvailable agents: ${available}`,
                        },
                    ],
                    details: makeDetails('single')([]),
                }
            }

            if (params.resume && (hasChain || hasTasks)) {
                return {
                    content: [
                        {
                            type: 'text',
                            text:
                                'Invalid parameters: "resume" is single-mode only ({agent, task, resume}). ' +
                                'Remove "resume" or restructure as a single delegation.',
                        },
                    ],
                    details: makeDetails('single')([]),
                }
            }

            if (
                (agentScope === 'project' || agentScope === 'both') &&
                confirmProjectAgents &&
                ctx.hasUI &&
                !ctx.isProjectTrusted()
            ) {
                const requestedAgentNames = new Set<string>()
                if (params.chain)
                    for (const step of params.chain) requestedAgentNames.add(step.agent)
                if (params.tasks)
                    for (const t of params.tasks) requestedAgentNames.add(t.agent)
                if (params.agent) requestedAgentNames.add(params.agent)

                const projectAgentsRequested = Array.from(requestedAgentNames)
                    .map(name => agents.find(a => a.name === name))
                    .filter((a): a is AgentConfig => a?.source === 'project')

                if (projectAgentsRequested.length > 0) {
                    const names = projectAgentsRequested.map(a => a.name).join(', ')
                    const dir = discovery.projectAgentsDir ?? '(unknown)'
                    const ok = await ctx.ui.confirm(
                        'Run project-local agents?',
                        `Agents: ${names}\nSource: ${dir}\n\nProject agents are repo-controlled. Only continue for trusted repositories.`
                    )
                    if (!ok)
                        return {
                            content: [
                                {
                                    type: 'text',
                                    text: 'Canceled: project-local agents not approved.',
                                },
                            ],
                            details: makeDetails(
                                hasChain ? 'chain' : hasTasks ? 'parallel' : 'single'
                            )([]),
                        }
                }
            }

            if (params.chain && params.chain.length > 0) {
                const results: SingleResult[] = []
                let previousOutput = ''

                for (let i = 0; i < params.chain.length; i++) {
                    const step = params.chain[i]
                    const taskWithContext = step.task.replace(/\{previous\}/g, previousOutput)

                    // Create update callback that includes all previous results
                    const chainUpdate: OnUpdateCallback | undefined = onUpdate
                        ? partial => {
                              // Combine completed results with current streaming result
                              const currentResult = partial.details?.results[0]
                              if (currentResult) {
                                  const allResults = [...results, currentResult]
                                  onUpdate({
                                      content: partial.content,
                                      details: makeDetails('chain')(allResults),
                                  })
                              }
                          }
                        : undefined

                    const result = await runSingleAgent(
                        ctx.cwd,
                        dispatchDefaults,
                        agents,
                        step.agent,
                        taskWithContext,
                        step.cwd,
                        i + 1,
                        signal,
                        chainUpdate,
                        makeDetails('chain')
                    )
                    results.push(result)

                    const isError = isFailedResult(result)
                    if (isError) {
                        return {
                            content: [
                                {
                                    type: 'text',
                                    text: `Chain stopped at step ${i + 1} (${step.agent}):\n\n${formatFailureReport(result)}`,
                                },
                            ],
                            details: makeDetails('chain')(results),
                            isError: true,
                        }
                    }
                    previousOutput = getFinalOutput(result.messages)
                }
                return {
                    content: [
                        {
                            type: 'text',
                            text:
                                getFinalOutput(results[results.length - 1].messages) ||
                                '(no output)',
                        },
                    ],
                    details: makeDetails('chain')(results),
                }
            }

            if (params.tasks && params.tasks.length > 0) {
                if (params.tasks.length > MAX_PARALLEL_TASKS)
                    return {
                        content: [
                            {
                                type: 'text',
                                text: `Too many parallel tasks (${params.tasks.length}). Max is ${MAX_PARALLEL_TASKS}.`,
                            },
                        ],
                        details: makeDetails('parallel')([]),
                    }

                // Track all results for streaming updates
                const allResults: SingleResult[] = new Array(params.tasks.length)

                // Initialize placeholder results
                for (let i = 0; i < params.tasks.length; i++) {
                    allResults[i] = {
                        agent: params.tasks[i].agent,
                        agentSource: 'unknown',
                        task: params.tasks[i].task,
                        subagentId: '',
                        sessionPath: '',
                        exitCode: -1, // -1 = still running
                        messages: [],
                        stderr: '',
                        usage: {
                            input: 0,
                            output: 0,
                            cacheRead: 0,
                            cacheWrite: 0,
                            cost: 0,
                            contextTokens: 0,
                            turns: 0,
                        },
                    }
                }

                const emitParallelUpdate = () => {
                    if (onUpdate) {
                        const running = allResults.filter(r => r.exitCode === -1).length
                        const done = allResults.filter(r => r.exitCode !== -1).length
                        onUpdate({
                            content: [
                                {
                                    type: 'text',
                                    text: `Parallel: ${done}/${allResults.length} done, ${running} running...`,
                                },
                            ],
                            details: makeDetails('parallel')([...allResults]),
                        })
                    }
                }

                const results = await mapWithConcurrencyLimit(
                    params.tasks,
                    MAX_CONCURRENCY,
                    async (t, index) => {
                        const result = await runSingleAgent(
                            ctx.cwd,
                            dispatchDefaults,
                            agents,
                            t.agent,
                            t.task,
                            t.cwd,
                            undefined,
                            signal,
                            // Per-task update callback
                            partial => {
                                if (partial.details?.results[0]) {
                                    allResults[index] = partial.details.results[0]
                                    emitParallelUpdate()
                                }
                            },
                            makeDetails('parallel')
                        )
                        allResults[index] = result
                        emitParallelUpdate()
                        return result
                    }
                )

                const successCount = results.filter(r => !isFailedResult(r)).length
                const abortedCount = results.filter(r => r.aborted === true).length
                const headerText =
                    `Parallel: ${successCount}/${results.length} succeeded` +
                    (abortedCount > 0 ? `, ${abortedCount} aborted` : '')
                const summaries = results.map(r => {
                    const output = truncateParallelOutput(getResultOutput(r))
                    const status = r.aborted
                        ? 'aborted'
                        : isFailedResult(r)
                          ? `failed${r.stopReason && r.stopReason !== 'end' ? ` (${r.stopReason})` : ''}`
                          : 'completed'
                    const hint = isFailedResult(r) ? formatResumeHint(r) : null
                    return `### [${r.agent}] ${status}\n\n${output}${hint ? `\n\n${hint}` : ''}`
                })
                return {
                    content: [
                        {
                            type: 'text',
                            text: `${headerText}\n\n${summaries.join('\n\n---\n\n')}`,
                        },
                    ],
                    details: makeDetails('parallel')(results),
                }
            }

            if (params.agent && params.task) {
                let resume: ResumeTarget | undefined
                if (params.resume) {
                    const resolved = resolveResumeTarget(params.resume, params.agent, agents)
                    if (typeof resolved === 'string') {
                        return {
                            content: [{ type: 'text', text: resolved }],
                            details: makeDetails('single')([]),
                            isError: true,
                        }
                    }
                    resume = resolved
                }
                const result = await runSingleAgent(
                    ctx.cwd,
                    dispatchDefaults,
                    agents,
                    params.agent,
                    params.task,
                    params.cwd,
                    undefined,
                    signal,
                    onUpdate,
                    makeDetails('single'),
                    resume
                )
                const isError = isFailedResult(result)
                if (isError) {
                    return {
                        content: [{ type: 'text', text: formatFailureReport(result) }],
                        details: makeDetails('single')([result]),
                        isError: true,
                    }
                }
                const finalOutput = getFinalOutput(result.messages) || '(no output)'
                return {
                    content: [
                        {
                            type: 'text',
                            text: result.resumeNote
                                ? `${finalOutput}\n\n${result.resumeNote}`
                                : finalOutput,
                        },
                    ],
                    details: makeDetails('single')([result]),
                }
            }

            const available = agents.map(a => `${a.name} (${a.source})`).join(', ') || 'none'
            return {
                content: [
                    {
                        type: 'text',
                        text: `Invalid parameters. Available agents: ${available}`,
                    },
                ],
                details: makeDetails('single')([]),
            }
        },

        renderCall(args, theme, _context) {
            const scope: AgentScope = args.agentScope ?? 'user'
            if (args.chain && args.chain.length > 0) {
                let text =
                    theme.fg('toolTitle', theme.bold('subagent ')) +
                    theme.fg('accent', `chain (${args.chain.length} steps)`) +
                    theme.fg('muted', ` [${scope}]`)
                for (let i = 0; i < Math.min(args.chain.length, 3); i++) {
                    const step = args.chain[i]
                    // Clean up {previous} placeholder for display
                    const cleanTask = step.task.replace(/\{previous\}/g, '').trim()
                    const preview =
                        cleanTask.length > 40 ? `${cleanTask.slice(0, 40)}...` : cleanTask
                    text +=
                        '\n  ' +
                        theme.fg('muted', `${i + 1}.`) +
                        ' ' +
                        theme.fg('accent', step.agent) +
                        theme.fg('dim', ` ${preview}`)
                }
                if (args.chain.length > 3)
                    text += `\n  ${theme.fg('muted', `... +${args.chain.length - 3} more`)}`
                return new Text(text, 0, 0)
            }
            if (args.tasks && args.tasks.length > 0) {
                let text =
                    theme.fg('toolTitle', theme.bold('subagent ')) +
                    theme.fg('accent', `parallel (${args.tasks.length} tasks)`) +
                    theme.fg('muted', ` [${scope}]`)
                for (const t of args.tasks.slice(0, 3)) {
                    const preview = t.task.length > 40 ? `${t.task.slice(0, 40)}...` : t.task
                    text += `\n  ${theme.fg('accent', t.agent)}${theme.fg('dim', ` ${preview}`)}`
                }
                if (args.tasks.length > 3)
                    text += `\n  ${theme.fg('muted', `... +${args.tasks.length - 3} more`)}`
                return new Text(text, 0, 0)
            }
            const agentName = args.agent || '...'
            const preview = args.task
                ? args.task.length > 60
                    ? `${args.task.slice(0, 60)}...`
                    : args.task
                : '...'
            let text =
                theme.fg('toolTitle', theme.bold('subagent ')) +
                theme.fg('accent', agentName) +
                theme.fg('muted', ` [${scope}]`)
            text += `\n  ${theme.fg('dim', preview)}`
            return new Text(text, 0, 0)
        },

        renderResult(result, { expanded }, theme, _context) {
            const details = result.details as SubagentDetails | undefined
            if (!details || details.results.length === 0) {
                const text = result.content[0]
                return new Text(text?.type === 'text' ? text.text : '(no output)', 0, 0)
            }

            const mdTheme = getMarkdownTheme()

            const renderDisplayItems = (items: DisplayItem[], limit?: number) => {
                const toShow = limit ? items.slice(-limit) : items
                const skipped = limit && items.length > limit ? items.length - limit : 0
                let text = ''
                if (skipped > 0) text += theme.fg('muted', `... ${skipped} earlier items\n`)
                for (const item of toShow) {
                    if (item.type === 'text') {
                        const preview = expanded
                            ? item.text
                            : item.text.split('\n').slice(0, 3).join('\n')
                        text += `${theme.fg('toolOutput', preview)}\n`
                    } else {
                        text += `${theme.fg('muted', '→ ') + formatToolCall(item.name, item.args, theme.fg.bind(theme))}\n`
                    }
                }
                return text.trimEnd()
            }

            if (details.mode === 'single' && details.results.length === 1) {
                const r = details.results[0]
                const isError = isFailedResult(r)
                const icon = isError ? theme.fg('error', '✗') : theme.fg('success', '✓')
                const displayItems = getDisplayItems(r.messages)
                const finalOutput = getFinalOutput(r.messages)

                if (expanded) {
                    const container = new Container()
                    let header = `${icon} ${theme.fg('toolTitle', theme.bold(r.agent))}${theme.fg('muted', ` (${r.agentSource})`)}`
                    if (isError && r.stopReason)
                        header += ` ${theme.fg('error', `[${r.stopReason}]`)}`
                    container.addChild(new Text(header, 0, 0))
                    if (isError && r.errorMessage)
                        container.addChild(
                            new Text(theme.fg('error', `Error: ${r.errorMessage}`), 0, 0)
                        )
                    container.addChild(new Spacer(1))
                    container.addChild(new Text(theme.fg('muted', '─── Task ───'), 0, 0))
                    container.addChild(new Text(theme.fg('dim', r.task), 0, 0))
                    container.addChild(new Spacer(1))
                    container.addChild(new Text(theme.fg('muted', '─── Output ───'), 0, 0))
                    if (displayItems.length === 0 && !finalOutput) {
                        container.addChild(new Text(theme.fg('muted', '(no output)'), 0, 0))
                    } else {
                        for (const item of displayItems) {
                            if (item.type === 'toolCall')
                                container.addChild(
                                    new Text(
                                        theme.fg('muted', '→ ') +
                                            formatToolCall(
                                                item.name,
                                                item.args,
                                                theme.fg.bind(theme)
                                            ),
                                        0,
                                        0
                                    )
                                )
                        }
                        if (finalOutput) {
                            container.addChild(new Spacer(1))
                            container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme))
                        }
                    }
                    const usageStr = formatUsageStats(r.usage, r.model)
                    if (usageStr) {
                        container.addChild(new Spacer(1))
                        container.addChild(new Text(theme.fg('dim', usageStr), 0, 0))
                    }
                    return container
                }

                let text = `${icon} ${theme.fg('toolTitle', theme.bold(r.agent))}${theme.fg('muted', ` (${r.agentSource})`)}`
                if (isError && r.stopReason)
                    text += ` ${theme.fg('error', `[${r.stopReason}]`)}`
                if (isError && r.errorMessage)
                    text += `\n${theme.fg('error', `Error: ${r.errorMessage}`)}`
                else if (displayItems.length === 0)
                    text += `\n${theme.fg('muted', '(no output)')}`
                else {
                    text += `\n${renderDisplayItems(displayItems, COLLAPSED_ITEM_COUNT)}`
                    if (displayItems.length > COLLAPSED_ITEM_COUNT)
                        text += `\n${theme.fg('muted', '(Ctrl+O to expand)')}`
                }
                const usageStr = formatUsageStats(r.usage, r.model)
                if (usageStr) text += `\n${theme.fg('dim', usageStr)}`
                return new Text(text, 0, 0)
            }

            const aggregateUsage = (results: SingleResult[]) => {
                const total = {
                    input: 0,
                    output: 0,
                    cacheRead: 0,
                    cacheWrite: 0,
                    cost: 0,
                    turns: 0,
                }
                for (const r of results) {
                    total.input += r.usage.input
                    total.output += r.usage.output
                    total.cacheRead += r.usage.cacheRead
                    total.cacheWrite += r.usage.cacheWrite
                    total.cost += r.usage.cost
                    total.turns += r.usage.turns
                }
                return total
            }

            if (details.mode === 'chain') {
                const successCount = details.results.filter(r => r.exitCode === 0).length
                const icon =
                    successCount === details.results.length
                        ? theme.fg('success', '✓')
                        : theme.fg('error', '✗')

                if (expanded) {
                    const container = new Container()
                    container.addChild(
                        new Text(
                            icon +
                                ' ' +
                                theme.fg('toolTitle', theme.bold('chain ')) +
                                theme.fg(
                                    'accent',
                                    `${successCount}/${details.results.length} steps`
                                ),
                            0,
                            0
                        )
                    )

                    for (const r of details.results) {
                        const rIcon =
                            r.exitCode === 0
                                ? theme.fg('success', '✓')
                                : theme.fg('error', '✗')
                        const displayItems = getDisplayItems(r.messages)
                        const finalOutput = getFinalOutput(r.messages)

                        container.addChild(new Spacer(1))
                        container.addChild(
                            new Text(
                                `${theme.fg('muted', `─── Step ${r.step}: `) + theme.fg('accent', r.agent)} ${rIcon}`,
                                0,
                                0
                            )
                        )
                        container.addChild(
                            new Text(
                                theme.fg('muted', 'Task: ') + theme.fg('dim', r.task),
                                0,
                                0
                            )
                        )

                        // Show tool calls
                        for (const item of displayItems) {
                            if (item.type === 'toolCall') {
                                container.addChild(
                                    new Text(
                                        theme.fg('muted', '→ ') +
                                            formatToolCall(
                                                item.name,
                                                item.args,
                                                theme.fg.bind(theme)
                                            ),
                                        0,
                                        0
                                    )
                                )
                            }
                        }

                        // Show final output as markdown
                        if (finalOutput) {
                            container.addChild(new Spacer(1))
                            container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme))
                        }

                        const stepUsage = formatUsageStats(r.usage, r.model)
                        if (stepUsage)
                            container.addChild(new Text(theme.fg('dim', stepUsage), 0, 0))
                    }

                    const usageStr = formatUsageStats(aggregateUsage(details.results))
                    if (usageStr) {
                        container.addChild(new Spacer(1))
                        container.addChild(
                            new Text(theme.fg('dim', `Total: ${usageStr}`), 0, 0)
                        )
                    }
                    return container
                }

                // Collapsed view
                let text =
                    icon +
                    ' ' +
                    theme.fg('toolTitle', theme.bold('chain ')) +
                    theme.fg('accent', `${successCount}/${details.results.length} steps`)
                for (const r of details.results) {
                    const rIcon =
                        r.exitCode === 0 ? theme.fg('success', '✓') : theme.fg('error', '✗')
                    const displayItems = getDisplayItems(r.messages)
                    text += `\n\n${theme.fg('muted', `─── Step ${r.step}: `)}${theme.fg('accent', r.agent)} ${rIcon}`
                    if (displayItems.length === 0)
                        text += `\n${theme.fg('muted', '(no output)')}`
                    else text += `\n${renderDisplayItems(displayItems, 5)}`
                }
                const usageStr = formatUsageStats(aggregateUsage(details.results))
                if (usageStr) text += `\n\n${theme.fg('dim', `Total: ${usageStr}`)}`
                text += `\n${theme.fg('muted', '(Ctrl+O to expand)')}`
                return new Text(text, 0, 0)
            }

            if (details.mode === 'parallel') {
                const running = details.results.filter(r => r.exitCode === -1).length
                const successCount = details.results.filter(
                    r => r.exitCode !== -1 && !isFailedResult(r)
                ).length
                const failCount = details.results.filter(
                    r => r.exitCode !== -1 && isFailedResult(r)
                ).length
                const isRunning = running > 0
                const icon = isRunning
                    ? theme.fg('warning', '⏳')
                    : failCount > 0
                      ? theme.fg('warning', '◐')
                      : theme.fg('success', '✓')
                const status = isRunning
                    ? `${successCount + failCount}/${details.results.length} done, ${running} running`
                    : `${successCount}/${details.results.length} tasks`

                if (expanded && !isRunning) {
                    const container = new Container()
                    container.addChild(
                        new Text(
                            `${icon} ${theme.fg('toolTitle', theme.bold('parallel '))}${theme.fg('accent', status)}`,
                            0,
                            0
                        )
                    )

                    for (const r of details.results) {
                        const rIcon = isFailedResult(r)
                            ? theme.fg('error', '✗')
                            : theme.fg('success', '✓')
                        const displayItems = getDisplayItems(r.messages)
                        const finalOutput = getFinalOutput(r.messages)

                        container.addChild(new Spacer(1))
                        container.addChild(
                            new Text(
                                `${theme.fg('muted', '─── ') + theme.fg('accent', r.agent)} ${rIcon}`,
                                0,
                                0
                            )
                        )
                        container.addChild(
                            new Text(
                                theme.fg('muted', 'Task: ') + theme.fg('dim', r.task),
                                0,
                                0
                            )
                        )

                        // Show tool calls
                        for (const item of displayItems) {
                            if (item.type === 'toolCall') {
                                container.addChild(
                                    new Text(
                                        theme.fg('muted', '→ ') +
                                            formatToolCall(
                                                item.name,
                                                item.args,
                                                theme.fg.bind(theme)
                                            ),
                                        0,
                                        0
                                    )
                                )
                            }
                        }

                        // Show final output as markdown
                        if (finalOutput) {
                            container.addChild(new Spacer(1))
                            container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme))
                        }

                        const taskUsage = formatUsageStats(r.usage, r.model)
                        if (taskUsage)
                            container.addChild(new Text(theme.fg('dim', taskUsage), 0, 0))
                    }

                    const usageStr = formatUsageStats(aggregateUsage(details.results))
                    if (usageStr) {
                        container.addChild(new Spacer(1))
                        container.addChild(
                            new Text(theme.fg('dim', `Total: ${usageStr}`), 0, 0)
                        )
                    }
                    return container
                }

                // Collapsed view (or still running)
                let text = `${icon} ${theme.fg('toolTitle', theme.bold('parallel '))}${theme.fg('accent', status)}`
                for (const r of details.results) {
                    const rIcon =
                        r.exitCode === -1
                            ? theme.fg('warning', '⏳')
                            : isFailedResult(r)
                              ? theme.fg('error', '✗')
                              : theme.fg('success', '✓')
                    const displayItems = getDisplayItems(r.messages)
                    text += `\n\n${theme.fg('muted', '─── ')}${theme.fg('accent', r.agent)} ${rIcon}`
                    if (displayItems.length === 0)
                        text += `\n${theme.fg('muted', r.exitCode === -1 ? '(running...)' : '(no output)')}`
                    else text += `\n${renderDisplayItems(displayItems, 5)}`
                }
                if (!isRunning) {
                    const usageStr = formatUsageStats(aggregateUsage(details.results))
                    if (usageStr) text += `\n\n${theme.fg('dim', `Total: ${usageStr}`)}`
                }
                if (!expanded) text += `\n${theme.fg('muted', '(Ctrl+O to expand)')}`
                return new Text(text, 0, 0)
            }

            const text = result.content[0]
            return new Text(text?.type === 'text' ? text.text : '(no output)', 0, 0)
        },
    })

    pi.registerTool({
        name: 'subagent_inspect',
        label: 'Subagent Inspect',
        description: [
            'Inspect a persisted subagent run by id (exact or unique prefix): status, agent, task, usage,',
            'and the tail of its transcript. Works on running subagents (e.g. debugging stuck runs).',
            'Failed and aborted runs persist until resumed; successful runs are cleaned up on completion,',
            "so their output is only in the parent session's tool result.",
        ].join(' '),
        parameters: SubagentInspectParams,

        async execute(_toolCallId, params) {
            const limit = Math.max(1, Math.floor(params.limit ?? INSPECT_DEFAULT_LIMIT))
            const resolved = resolveInspectTarget(params.id)
            if ('error' in resolved) {
                return {
                    content: [{ type: 'text', text: resolved.error }],
                    details: undefined,
                    isError: true,
                }
            }
            return {
                content: [
                    { type: 'text', text: buildSubagentInspectReport(resolved.id, limit) },
                ],
                details: undefined,
            }
        },

        renderCall(args, theme, _context) {
            const preview = args.id.length > 40 ? `${args.id.slice(0, 40)}...` : args.id
            let text =
                theme.fg('toolTitle', theme.bold('subagent_inspect ')) +
                theme.fg('accent', preview)
            if (args.limit !== undefined) text += theme.fg('muted', ` (last ${args.limit})`)
            return new Text(text, 0, 0)
        },

        renderResult(result, _options, _theme, _context) {
            const text = result.content[0]
            return new Text(text?.type === 'text' ? text.text : '(no output)', 0, 0)
        },
    })

    pi.registerCommand('subagents', {
        description:
            'List persisted subagent sessions (running, aborted, or failed runs), or attach to a running one: /subagents attach [id]',
        handler: async (args, ctx) => {
            const [sub, ...rest] = args.trim().split(/\s+/)
            if (sub === 'attach') {
                const resolved = resolveAttachTarget(rest[0])
                if (typeof resolved === 'string') {
                    if (ctx.mode === 'print') console.log(resolved)
                    else ctx.ui.notify(resolved, 'warning')
                    return
                }
                if (ctx.mode !== 'tui') {
                    const message = 'attach requires an interactive session'
                    if (ctx.mode === 'print') console.log(message)
                    else ctx.ui.notify(message, 'warning')
                    return
                }
                await attachToSubagent(ctx, resolved)
                return
            }
            const report = buildSubagentsListReport()
            // ctx.ui.notify is a no-op without a UI (pi -p / --mode json); print mode writes to stdout instead.
            if (ctx.mode === 'print') console.log(report)
            else ctx.ui.notify(report, 'info')
        },
    })
}

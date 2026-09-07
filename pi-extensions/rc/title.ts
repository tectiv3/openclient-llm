// Push notification body text (user decision 2026-09-07): finished pushes
// identify the session (session name → cwd basename → fixed fallback); question
// pushes carry the question's own text. The question body is a deliberate,
// spec-documented relaxation of the v1 "no agent/user text in payloads"
// invariant — capped and whitespace-sanitized, with a deterministic hard
// truncation whenever the optional LLM shortening is unavailable.
import { basename } from 'node:path'
import { dbgLog } from './debug'

const FINISHED_FALLBACK = 'Agent finished'
const QUESTION_FALLBACK = 'Agent has a question — answer needed'
// Bodies at or below this length ship verbatim; longer question text is
// shortened (LLM) or hard-truncated.
const SHORT_BODY_MAX = 80
// Hard cap for any body derived from long text (100 chars incl. the ellipsis).
const HARD_TRUNCATE_MAX = 100
const DEFAULT_MODEL = 'minimax/minimax-m3:free'
const DEFAULT_OPENROUTER_URL = 'https://openrouter.ai/api/v1'
const DEFAULT_TIMEOUT_MS = 3500

// Structural slice of the rc singleton: avoids importing index.ts (which would
// create a cycle) while accepting the real singleton unchanged.
export type TitleState = {
    binding?: {
        ctx?: {
            sessionManager?: {
                getSessionName?: () => string | undefined
                getCwd?: () => string
            }
        }
    } | null
}

// Strips control characters (C0 incl. \n\t\r, plus DEL) and format
// characters (Cf: bidi overrides like U+202E RLO — a lock-screen spoofing
// vector, ZWJ, soft hyphen), and collapses every whitespace run to a single
// space, so no body can smuggle line breaks, exotic spacing, or reversed-
// rendering tricks to the lock screen.
export function sanitizeBodyText(text: string): string {
    return text
        .replace(/[\p{Cc}\p{Cf}]/gu, '')
        .replace(/\s+/g, ' ')
        .trim()
}

// Deterministic cap: `max` code points including a trailing ellipsis.
// Slices by code point, never UTF-16 unit — a cut mid-surrogate-pair (emoji)
// would ship a lone surrogate (mojibake, or a possibly APNs-rejected JSON
// escape) to the lock screen.
export function hardTruncate(text: string, max = HARD_TRUNCATE_MAX): string {
    const cps = [...text]
    if (cps.length <= max) return text
    return `${cps.slice(0, max - 1).join('')}…`
}

export function finishedBody(state: TitleState): string {
    const manager = state.binding?.ctx?.sessionManager
    const name = sanitizeBodyText(manager?.getSessionName?.() ?? '')
    if (name) return hardTruncate(name, SHORT_BODY_MAX)
    const cwd = sanitizeBodyText(manager?.getCwd?.() ?? '')
    if (cwd) {
        const dir = basename(cwd)
        if (dir && dir !== '/' && dir !== '.') return hardTruncate(dir, SHORT_BODY_MAX)
    }
    return FINISHED_FALLBACK
}

export function questionBody(text: string | null | undefined): Promise<string> {
    const clean = typeof text === 'string' ? sanitizeBodyText(text) : ''
    if (!clean) return Promise.resolve(QUESTION_FALLBACK)
    if (clean.length <= SHORT_BODY_MAX) return Promise.resolve(clean)
    // Cap the LLM input at the first 300 code points: bounds egress for
    // pathological multi-KB questions — 300 is ample context for a ≤60-char
    // summary. The truncation fallback keeps using the full sanitized text.
    return shortenWithLlm([...clean].slice(0, 300).join('')).then(
        shortened => shortened ?? hardTruncate(clean)
    )
}

// Env is read per call (not at module load) so the test harness can flip the
// URL/timeout in a running child via its probe extension.
function timeoutMs(): number {
    const raw = Number.parseInt(process.env.PI_RC_TITLE_TIMEOUT_MS?.trim() ?? '', 10)
    return Number.isFinite(raw) && raw > 0 ? raw : DEFAULT_TIMEOUT_MS
}

function completionText(parsed: unknown): string | null {
    if (typeof parsed !== 'object' || parsed === null) return null
    const choices = (parsed as { choices?: unknown }).choices
    if (!Array.isArray(choices) || choices.length === 0) return null
    const message = (choices[0] as { message?: unknown } | null)?.message
    const content = (message as { content?: unknown } | null)?.content
    return typeof content === 'string' && content !== '' ? content : null
}

function stripWrappingQuotes(text: string): string {
    const quotes = '"\'‘’“”'
    if (
        text.length >= 2 &&
        quotes.includes(text[0]) &&
        quotes.includes(text[text.length - 1])
    ) {
        return text.slice(1, -1)
    }
    return text
}

// One OpenRouter chat completion (stdlib only: global fetch + AbortController).
// Missing key or ANY failure — non-200, unparseable body, timeout, network —
// resolves null so the caller falls back to deterministic truncation.
export async function shortenWithLlm(text: string): Promise<string | null> {
    const apiKey = process.env.OPENROUTER_API_KEY?.trim()
    if (!apiKey) return null
    const baseUrl = (
        process.env.PI_RC_OPENROUTER_URL?.trim() || DEFAULT_OPENROUTER_URL
    ).replace(/\/+$/, '')
    const model = process.env.PI_RC_TITLE_MODEL?.trim() || DEFAULT_MODEL
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs())
    try {
        const response = await fetch(`${baseUrl}/chat/completions`, {
            method: 'POST',
            headers: {
                authorization: `Bearer ${apiKey}`,
                'content-type': 'application/json',
            },
            body: JSON.stringify({
                model,
                messages: [
                    {
                        role: 'system',
                        content:
                            'You shorten notification bodies. Reply with ONLY the shortened text, at most 60 characters, no quotes.',
                    },
                    { role: 'user', content: text },
                ],
                max_tokens: 40,
            }),
            signal: controller.signal,
        })
        if (!response.ok) return null
        const content = completionText(await response.json())
        if (content === null) return null
        const cleaned = hardTruncate(stripWrappingQuotes(sanitizeBodyText(content)))
        return cleaned || null
    } catch (error) {
        dbgLog(
            'title llm shorten failed:',
            error instanceof Error ? error.message : String(error)
        )
        return null
    } finally {
        clearTimeout(timer)
    }
}

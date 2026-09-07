// Test-only pi extension: loaded into the spawned pi child by
// test-client.mjs via --extension (see the group-5b tests there). It drives
// the rc singleton's ask() signal path, which no wire message can express —
// ask() is an internal pi-extension API, not part of the wire protocol. The
// singleton is looked up on globalThis, never imported.
//
// /rcsignal aborted — ask() with an ALREADY-aborted signal: must resolve
//   null and broadcast question_resolved by:cancelled for its own id.
// /rcsignal pend — ask() with a signal aborted MID-WAIT: must resolve null
//   and broadcast question_resolved by:cancelled; an answer for that id sent
//   afterwards must be rejected with unknown_question (harness asserts it).
//
// /rctitle off — point the push-title LLM (title.ts) at an unreachable
//   127.0.0.1 port with a tiny timeout: the deterministic truncation
//   fallback path. /rctitle url <url> — point it at the harness's mock
//   OpenRouter server (also clears the timeout override, restoring the
//   spawn default). title.ts reads these env vars per call, so flipping
//   them here takes effect on the very next question push.
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent'

const RC_KEY = Symbol.for('pi-rc')

type ProbeAsk = {
    ask(opts: {
        kind: 'ask_user_question'
        params: Record<string, unknown>
        signal?: AbortSignal
    }): Promise<unknown>
}

export default function rcSignalProbe(pi: ExtensionAPI): void {
    pi.registerCommand('rctitle', {
        description: 'Test-only: flip the push-title LLM env (used by test-client.mjs)',
        handler: async (args, ctx) => {
            const parts = args.trim().split(/\s+/)
            if (parts[0] === 'off') {
                process.env.PI_RC_OPENROUTER_URL = 'http://127.0.0.1:9'
                process.env.PI_RC_TITLE_TIMEOUT_MS = '250'
            } else if (parts[0] === 'url' && parts[1]) {
                process.env.PI_RC_OPENROUTER_URL = parts[1]
                delete process.env.PI_RC_TITLE_TIMEOUT_MS
            } else {
                ctx.ui.notify(`rctitle: unsupported args='${args.trim()}'`, 'warning')
                return
            }
            ctx.ui.notify(`rctitle: ${parts[0]} ok`, 'info')
        },
    })
    pi.registerCommand('rcsignal', {
        description: 'Test-only: drive the rc ask() signal path (used by test-client.mjs)',
        handler: async (args, ctx) => {
            const rc = (globalThis as unknown as Record<symbol, ProbeAsk | undefined>)[RC_KEY]
            const which = args.trim()
            if (!rc || (which !== 'aborted' && which !== 'pend')) {
                ctx.ui.notify(
                    `rcsignal: unsupported (rc=${rc ? 'yes' : 'no'}, args='${which}')`,
                    'warning'
                )
                return
            }
            const controller = new AbortController()
            if (which === 'aborted') controller.abort()
            const askPromise = rc.ask({
                kind: 'ask_user_question',
                params: {
                    questions: [
                        { id: 'q1', prompt: 'rc signal probe', options: [{ label: 'yes', value: 'yes' }] },
                    ],
                },
                signal: controller.signal,
            })
            if (which === 'pend') {
                // Let the question broadcast land on the connected clients
                // before the abort, so the harness sees question then
                // question_resolved in order.
                await new Promise(resolve => setTimeout(resolve, 750))
                controller.abort()
            }
            const answer = await askPromise
            ctx.ui.notify(
                `rcsignal ${which}: resolved ${answer === null ? 'null' : 'non-null'}`,
                'info'
            )
        },
    })
}

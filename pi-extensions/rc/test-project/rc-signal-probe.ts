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
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent'

const RC_KEY = Symbol.for('pi-rc')

type ProbeAsk = {
    ask(opts: {
        kind: 'question' | 'questionnaire'
        params: Record<string, unknown>
        signal?: AbortSignal
    }): Promise<unknown>
}

export default function rcSignalProbe(pi: ExtensionAPI): void {
    pi.registerCommand('rcsignal', {
        description: 'Test-only: drive the rc ask() signal path (used by test-client.mjs)',
        handler: async (args, ctx) => {
            const rc = (globalThis as unknown as Record<symbol, ProbeAsk | undefined>)[RC_KEY]
            const which = args.trim()
            if (!rc || (which !== 'aborted' && which !== 'pend')) {
                ctx.ui.notify(`rcsignal: unsupported (rc=${rc ? 'yes' : 'no'}, args='${which}')`, 'warning')
                return
            }
            const controller = new AbortController()
            if (which === 'aborted') controller.abort()
            const askPromise = rc.ask({
                kind: 'question',
                params: {
                    question: 'rc signal probe',
                    options: [{ label: 'yes', value: 'yes' }],
                    allowOther: true,
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
            ctx.ui.notify(`rcsignal ${which}: resolved ${answer === null ? 'null' : 'non-null'}`, 'info')
        },
    })
}

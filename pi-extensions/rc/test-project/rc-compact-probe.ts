// Test-only pi extension: loaded into the spawned pi child by
// test-client.mjs via --extension (group 15, compaction visibility —
// spec: docs/plans/rc-compaction-visibility-spec.md). It triggers manual
// compaction — the only compaction entry point the harness can reach — and
// makes the in-flight compaction window stable for the late-join and
// abort-during-compact tests. Nothing here reaches the rc singleton; only
// the extension command context and the provider-request hook are used.
//
// /rccompact — ctx.compact() (fire-and-forget): starts a manual compaction;
//   the rc extension's session_before_compact / session_compact /
//   session_compact_failed handlers observe it and are what the harness
//   asserts on. The session needs real messages first — a short branch is
//   rejected with "Nothing to compact" — so test-project/.pi/settings.json
//   lowers compaction.keepRecentTokens (16) to make a couple of short
//   exchanges enough for a cut point to exist.
//
// before_provider_request — the compaction SUMMARIZATION request is the only
// provider request whose payload carries pi's summarization system prompt
// (SUMMARIZATION_SYSTEM_PROMPT, dist/core/compaction/utils.js), so sleeping
// ~3 s on that marker delays ONLY the summarization call — the hook is
// awaited by pi before the HTTP request — giving a stable in-flight window,
// while normal chat turns never match the marker and are never delayed.
import type { ExtensionAPI } from '@earendil-works/pi-coding-agent'

const SUMMARIZATION_MARKER = 'You are a context summarization assistant'
const SUMMARIZATION_DELAY_MS = 3000

export default function rcCompactProbe(pi: ExtensionAPI): void {
    pi.registerCommand('rccompact', {
        description:
            'Test-only: trigger a manual compaction (used by test-client.mjs group 15)',
        handler: async (_args, ctx) => {
            ctx.compact()
            ctx.ui.notify('rccompact: manual compaction triggered', 'info')
        },
    })
    pi.on('before_provider_request', async (event: { payload?: unknown }) => {
        const payload = event?.payload
        if (payload === undefined) return
        if (!JSON.stringify(payload).includes(SUMMARIZATION_MARKER)) return
        await new Promise<void>(resolve => setTimeout(resolve, SUMMARIZATION_DELAY_MS))
    })
}

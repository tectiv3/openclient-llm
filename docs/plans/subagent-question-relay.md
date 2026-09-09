# Subagent question relay

Status: SPEC FINAL (revised 2026-09-09), implementation pending.
Supersedes: 2026-09-09 original (queueing design), 2026-09-06 Unix-socket draft (parked).

## Problem

Subagent children run `--mode rpc`. In that mode:
1. `rcRemote()` → not serving → skipped (children don't run `/rc`).
2. Falls through to TUI guard → `ctx.mode !== 'tui'` → error "UI not available".
3. Agent aborts. The question never reaches the user.

The `extension_ui_request` auto-responder (subagent/index.ts) only covers `ctx.ui.*`
calls, not the `ask_user_question` tool — two different dead-end paths.

Observed: 2026-09-08, worker run 01a082d3 — question recovered manually from transcript.

## Design

### Transport

Reuse the existing rpc stdio channel (`extension_ui_request` / `extension_ui_response`).
No pi-mono modifications. No new transport, no sockets, no env vars.

The child's `ctx.ui.select()` in rpc mode emits `extension_ui_request {method:'select',
id, title, options}` on stdout and blocks until the matching `extension_ui_response`
arrives on stdin (verified against pi-mono `rpc-mode.ts:91–150`). The parent's
`processLine` already intercepts these events.

### Constraint: no pi-mono changes

Extensions can only emit `select`, `confirm`, `input` via `ctx.ui`. There is no
custom-payload extension UI method. The rpc-mode stdin is fully owned by pi — extensions
cannot add their own stdin listener. All relay data must flow through the existing
`extension_ui_request/response` wire format.

Consequence: relayed questions carry flat string options, not rich Question objects.
The phone (RC) receives a reconstructed minimal Question — functional but without
option descriptions or multi-question grouping.

### Child side (ask-user-question/index.ts)

When `ctx.mode !== 'tui'` (rpc mode), instead of returning error:

1. For each question, call `ctx.ui.select(question.prompt, question.options.map(o => o.label))`.
   Pi serializes this as `extension_ui_request {method:'select', title, options}` on stdout
   and blocks for `extension_ui_response`.
2. `allowOther`: append "Type something..." as the last option. If selected, follow up
   with `ctx.ui.input(question.prompt)`. Two-step UX, no custom transport needed.
3. Multi-question: sequential `ctx.ui.select()` calls, one per question.
4. Cancellation: `ctx.ui.select()` returns `undefined` → return
   `errorResult('User cancelled the question', questions)`.
5. Collect all answers, format the same `answerLines` text as the normal path.

### Parent side (subagent/index.ts — handleExtensionUiRequest)

Upgrade from auto-responding to interactive relay. Relay `select`, `confirm`, and
`input` methods — all child extension UI requests get relayed, not just
ask_user_question.

#### Relay callback

`runSingleAgent` receives a narrow callback (not the full `ctx`):

```ts
type RelayUiRequest = (
    event: { method: string; id: string; [key: string]: unknown },
    agentName: string,
    signal: AbortSignal
) => Promise<Record<string, unknown> | null>
```

The callback is constructed at the call site (tool `execute` function) from `ctx` and
`rcRemote()`. Returns the response payload to send to the child, or `null` for
cancellation.

**Implementation note:** `rcRemote()` (the `RcRemote` structural interface and
`Symbol.for('pi-rc')` globalThis lookup) currently exists only in
`ask-user-question/index.ts`. The subagent extension must replicate the interface and
lookup — same decoupled globalThis pattern, no import dependency on rc or
ask-user-question.

Relay target priority (same as parent's own questions):
1. RC (phone) if `rcRemote()?.askAvailable()` → translate to `rc.ask()` call.
2. TUI fallback → present via parent's `ctx.ui.select()` / `ctx.ui.confirm()` /
   `ctx.ui.input()`.

#### RC translation

Since the wire only carries flat strings, the callback reconstructs a minimal Question
for `rc.ask()`:

- **select**: `{id: 'Q1', label: agentName, prompt: title, options: options.map(o => ({label: o, value: o})), allowOther: false}`.
- **confirm**: `{id: 'Q1', label: agentName, prompt: title + ': ' + message, options: [{label: 'Yes', value: 'yes'}, {label: 'No', value: 'no'}], allowOther: false}`.
  Map answer back: 'yes' → `{confirmed: true}`, 'no' → `{confirmed: false}`.
- **input**: `{id: 'Q1', label: agentName, prompt: title, options: [], allowOther: true}`.
  Map answer back: `{value: answer.label}`.

#### Agent name prefix

The parent prepends `[agentName]` to the title when relaying. The agent name is known
at the parent level (`ActiveSubagent` entry). No env var needed on the child side.

#### Concurrency: FIFO mutex

A module-level async mutex serializes all relays. The user can only answer one question
at a time (TUI or phone), so concurrent questions from parallel children block in FIFO
order. Each child's `ctx.ui.select()` stays pending (rpc-mode blocks on the promise)
while it waits its turn.

```
Child A sends select → mutex acquired → relay to user → user answers → mutex released
Child B sends select → mutex acquired (was waiting) → relay to user → ...
```

#### Watchdog pause

A `relayPending` boolean flag per child, set `true` when the relay starts, `false` when
it resolves. The stall watchdog interval checks the flag and skips the kill when
`relayPending === true`. The flag and watchdog live in the same closure scope inside
`runSingleAgent`.

**Critical:** When clearing `relayPending`, also reset `lastActivityTime = Date.now()`.
Without this, a slow relay (user takes >5min to answer) leaves `lastActivityTime` stale,
and the next watchdog tick sees silence exceeding `STALL_TIMEOUT_MS` and kills the child
immediately after the relay completes.

#### Abort propagation

Each relay creates an `AbortController`. The run's abort signal is forwarded: if the
run aborts, the relay controller aborts, which cancels the parent's `ctx.ui.select()` or
`rc.ask()`. The cancelled relay returns `null`, which sends
`{type: 'extension_ui_response', id, cancelled: true}` to the child. The child's
`ctx.ui.select()` resolves `undefined`, and the tool returns `errorResult`.

#### Child death during relay

No special handling. If the child dies while a relay is in-flight, the relay completes
naturally. `writeChildStdin` fails silently (existing try/catch). The user may answer a
dead child's question — the response is discarded. The proc `exit` handler fires
normally.

#### Response flow

- User answers → `writeChildStdin({ type: 'extension_ui_response', id, value })`.
- User cancels (Esc / phone dismiss) → `writeChildStdin({ type: 'extension_ui_response',
  id, cancelled: true })`.
- For confirm: → `writeChildStdin({ type: 'extension_ui_response', id, confirmed: bool })`.
- Run abort → relay's AbortController fires → cancelled response sent to child.

### Unchanged

- `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text` — fire-and-forget,
  no relay needed (already handled).
- `custom` — not supported in rpc mode (`return undefined as never` in pi). No change.
- `editor` — stays auto-cancelled for v1 (multiline → single-line is lossy; add later
  if needed).

## Decisions

1. **Transport:** rpc stdio (extension_ui_request/response). No Unix socket, no pi-mono
   changes. Extensions can only use ctx.ui.select/confirm/input.
2. **Relay timing:** Immediate. No queueing. The original `ctx.isIdle()` / `agent_settled`
   drain design was a deadlock (parent is never idle while children run). Dropped.
3. **Concurrency:** Module-level FIFO mutex serializes concurrent relays. One question
   at a time to the user.
4. **Relay target:** RC first, TUI fallback (same priority as parent's own questions).
5. **RC fidelity:** Flat-string degradation accepted. Reconstruct minimal Question objects
   for `rc.ask()` from the wire data. No option descriptions or multi-question grouping
   on phone.
6. **Multi-question:** Sequential selects in the child, one per question.
7. **allowOther:** Two-step — select with "Type something..." option, then input if chosen.
   Two relay round-trips for that question. Acceptable.
8. **confirm relay:** Yes — relay to user (previously auto-denied). Mapped to yes/no
   Question for RC.
9. **input relay:** Yes — relay to user (previously auto-cancelled). Mapped to
   allowOther-only Question for RC.
10. **editor relay:** No — stays auto-cancelled for v1.
11. **Scope:** Always-on for select/confirm/input. No opt-in flag.
12. **Identity:** Parent prepends `[agentName]` to relay title. No child-side env var.
13. **Parent plumbing:** Narrow relay callback passed into `runSingleAgent`, not full `ctx`.
14. **Watchdog:** Boolean `relayPending` flag per child; watchdog skips kill when true.
15. **Abort:** AbortController per relay, linked to run signal. Cascading cancellation.
16. **Child death:** No special handling. writeChildStdin fails silently.
17. **Cancellation:** Return 'cancelled' tool result. Subagent decides how to proceed.

## Implementation order

1. **Parent relay callback construction.** In the tool's `execute` function, build the
   relay callback from `ctx` and `rcRemote()`. Covers RC → ask translation, TUI
   fallback, agent name prefixing, and abort signal linking.
2. **Parent: upgrade `handleExtensionUiRequest`.** Make it async. For select/confirm/input:
   acquire the FIFO mutex, set `relayPending`, call the relay callback, send response to
   child, clear `relayPending` (reset `lastActivityTime`), release mutex. Pass relay
   callback and agentName into `runSingleAgent`. The `processLine` call site must
   `.catch()` the returned promise — on error, log and send
   `{type: 'extension_ui_response', id, cancelled: true}` to the child so it doesn't
   hang.
3. **Child: `ask-user-question/index.ts`.** Add rpc-mode path: when `ctx.mode !== 'tui'`
   and RC is not available, iterate questions with `ctx.ui.select()` / `ctx.ui.input()`.
4. **Test:** Manual with a subagent that calls ask_user_question. Verify:
   - Single question relays to TUI.
   - Single question relays to RC (phone).
   - Multi-question: sequential selects work.
   - allowOther: two-step select→input works.
   - Parallel children: second question waits for first to be answered.
   - Abort: cancelling the run cancels the relay.
   - confirm/input from other extensions relay correctly.
5. **Phone:** No Swift changes needed — the RC path uses the existing `rc.ask()` and the
   phone already renders questions.

## Risks

- **Parent ctx.ui during tool execution.** The plan assumes the parent can present
  interactive UI while its agent loop is blocked in `runSingleAgent`. TUI is event-driven
  and async code can present modal UI during any await — expected to work but not formally
  verified against all pi versions.
- **Flat-string RC degradation.** Phone renders basic option lists without descriptions.
  Acceptable for v1; enriching the wire format (via pi-mono changes) would restore full
  fidelity in a future version.
- **FIFO starvation.** If a user is slow to answer, all parallel children block behind
  the mutex. The watchdog is paused, so no kills — but throughput drops to serial.
  Acceptable tradeoff.
- **Rollback.** Each step is independently revertable. Step 2 (parent upgrade) is backward
  compatible — if no relay callback is passed, the auto-responder behavior can be retained
  as a fallback.

## Out of scope

- rc wire-protocol changes
- pi-mono modifications (ExtensionUIContext, rpc-mode)
- Rich Question metadata in extension_ui_request (requires pi-mono)
- editor relay (multiline lossy; add in v2)
- Automated test harness for the relay
- Question/questionnaire UI behavior changes
- Any change to how extensions are symlinked into `~/.pi/agent/extensions/`

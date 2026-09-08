# Plan: rc remote commands

Status: spec only, 2026-09-09 (revised 2026-09-09); not yet implemented.
Date: 2026-09-09.
History: reviewed by independent critic + source scout 2026-09-09; revisions folded in (Decisions 2).
Parent: `docs/plans/rc-remote-control-spec.md` (FROZEN 2026-09-09).

**Context.** The shipped rc feature (parent spec) lets the phone watch a live pi
coding-agent session and send prompts, steers, aborts, and question answers over a
tailnet WebSocket. This feature adds **session control from the phone**: start a new
session, switch models, compact the context, and rename the session. The frozen
parent spec is the background reference (architecture, wire protocol, history,
questions, push); this doc is the **source of truth for the remote-commands
feature** — per the owner's 2026-09-09 rule that every new rc feature gets its own
spec doc in `docs/plans/`. The parent spec numbered this feature section A8
("Remote commands"); where wording below cites "A8" it means this doc.

## Decisions (owner-approved 2026-09-09 — do not revisit)

| # | Decision | Chosen |
|---|----------|--------|
| 1 | Command set v1 | `new`, `set_model` (the phone "Models" sheet — list + selection), `compact` (optional custom instructions), `name` (rename session) |
| 2 | Explicitly EXCLUDED for v1 | thinking level, cycle_model (redundant with the explicit sheet), resume/session-picker, fork/clone, quit (dangerous from phone), reload (owner is retiring `/reload`), export (no file transfer path) |
| 3 | Frame shape | ONE generic `command` frame with a `command` name field (not one frame type per action) |
| 4 | Model list delivery | optional `models` array added to the existing `state` frame (no new request/response) |
| 5 | Protocol compatibility | The protocol is frozen vs the Swift client, but both ends are owned by us and change atomically (precedent: ask consolidation). New frames/fields/codes are additive |

## Decisions 2 (2026-09-09 review round — do not revisit)

| # | Decision | Chosen |
|---|----------|--------|
| 6 | C1 — a run blocked on a remote ask cannot be settled by phone Stop (the ask tool ignores the run-abort signal) | NO proactive cancel in the `new`/`compact` handlers (owner: "overly defensive"). Instead: (a) document as accepted known behavior that `command new`/`compact` issued while a remote question is pending BLOCK until the question settles — in practice the question is on screen in the same phone UI, so it gets answered first; and (b) fix the pre-existing gap so the phone CAN unblock (decision 7) |
| 7 | Phone Stop must unblock a run blocked on a pending remote ask | rc's `abort` handler additionally calls `cancelPendingAsk(state)` — the pending ask resolves null → the ask tool falls through to the LOCAL TUI prompt (same semantics as the existing TUI Esc hatch). Also makes the parent spec's "X sends abort, cancelling the agent's current turn" true for the blocked-ask case |
| 8 | C2 — `session_shutdown` never clears pendingAsk; a reconnecting client re-receives the dead session's question | `session_shutdown` with reason ≠ `quit` also calls `cancelPendingAsk(state)` — the question belongs to the dead session; cancelPendingAsk already broadcasts the cancel to clients and resolves null |
| 9 | H3 misattribution (uncorrelated broadcasts: two phones, or compact racing a non-rc replacement, can see each other's command results) | ACCEPT and document for v1 (single-phone realistic usage; per-command ids deferred) |
| 10 | Remaining critique revisions (wording fixes, pinned mitigations, added tests) | Folded into the spec |

## Verified facts (2026-09-09, recon against pi-mono + `pi-extensions/rc/`)

1. **New session mid-run**: `AgentSessionRuntime.newSession`
   (agent-session-runtime.ts:226) aborts the in-flight run and AWAITs full settle
   (`agent_settled` tail on the OLD session, tagged with the old sessionId) BEFORE
   disposing and creating the new session → `session_start`. rc's existing rebind
   path handles it (clears `pendingSteers`, rebroadcasts state+history). No data
   leak: `sessionId(state)` is computed live from `state.binding?.ctx.sessionManager`
   per frame.
2. **Stale-binding window (pre-existing bug, fixed by this feature)**: between the
   old `dispose()` and the new `session_start`, `state.binding` holds the
   invalidated old ctx; pi's stale-ctx guard makes guarded methods throw ("stale
   after session replacement", runner.ts:593-603). `handlePrompt`/`handleSteer`
   DO have null-binding guards (index.ts:766-773 / 787-795) returning
   `invalid_message` — the throw→blanket-catch→misleading-`invalid_message`
   path is specifically the STALE-ctx case: the guarded
   `binding.ctx.isIdle()` (index.ts:774/800) throws on the invalidated old ctx
   (runner.ts:593-603) → blanket catch in `handleSocketData` → client dropped.
   FIX: in the `session_shutdown` handler (index.ts:996-999),
   when `reason !== 'quit'`, set `state.binding = null` and call
   `cancelPendingAsk(state)` (decision 8) — instead of the current
   no-op rebind to the old ctx at index.ts:997); keep `stop()` for quit.
   `buildState`/`sessionId` are already null-binding safe (index.ts:816-837).
3. **`newSession` availability**: only on `ExtensionCommandContext`
   (types.ts:363-369), NOT on ExtensionContext/ExtensionAPI. rc gets one from the
   `/rc` command handler (registerCommand at index.ts:1380, `state.bind(pi, ctx)`
   at index.ts:1394 — that ctx IS command-capable), but `forward()` overwrites
   `binding.ctx` with plain event ctxs on every forwarded event
   (index.ts:977-978), so the design needs a SEPARATE stash: `state.commandCtx`.
   `ReplacedSessionContext extends ExtensionCommandContext` (types.ts:396) —
   `newSession({withSession: (freshCmdCtx) => stash})` chains the stash across
   phone-driven replacements. Degraded case: a session replaced OUTSIDE rc
   (TUI `/new`, RPC `new_session`) invalidates the stashed commandCtx with no way
   to refresh it → `command new` returns a clean error; recovery = run `/rc` in
   the terminal.
4. **compact**: `AgentSession.compact(customInstructions?)`
   (agent-session.ts:1946) — first line is `await this.abort()`: callable
   mid-run, aborts+awaits the in-flight run, then summarizes.
   `ctx.compact(options?)` (ExtensionContext, types.ts:346) is fire-and-forget.
   **VERIFIED: the `CompactOptions` field name is `customInstructions`**
   (types.ts:298-302: `{customInstructions?: string; onComplete?; onError?}`).
   Extension events (NOT currently subscribed by rc): `session_before_compact`
   (types.ts:593-604), `session_compact` (types.ts:607-614, carries
   `compactionEntry`), `session_compact_failed` (types.ts:618-627, carries
   `errorMessage?`, `aborted`). `getContextUsage()` returns null tokens/percent
   after compaction until the next assistant message with usage (buildState
   already omits the field then; Swift keeps the stale header value — accepted).
5. **setModel**: `pi.setModel(model)` (ExtensionAPI, types.ts:1415) — no idle
   check, takes effect at the next LLM call, returns `false` when the provider has
   no auth. Emits `model_select` `{model, previousModel, source}`
   (types.ts:830-834) when the model actually changes — rc does NOT currently
   subscribe.
6. **rename**: `pi.setSessionName(name)` / `pi.getSessionName()` on ExtensionAPI
   (types.ts:1388). Emits `session_info_changed {name}` (types.ts:573-576) — rc
   does NOT currently subscribe. **VERIFIED normalization**
   (session-manager.ts:1150-1163): `[\r\n]+` → single space, then trim — NO
   length cap, NO whitespace collapsing; the TUI `/name` (handleNameCommand,
   interactive-mode.ts:6187-6201) has no length cap either. `session_info_changed`
   fires UNCONDITIONALLY — even when the normalized name equals the input
   (agent-session.ts:3091-3097) — harmless (state broadcast is idempotent).
   rc's `sessionName(state)` reads live from
   `ctx.sessionManager.getSessionName()` per frame.
7. **Model list for the phone — VERIFIED**: the TUI `/model` selector is
   constructed at interactive-mode.ts:2044 WITH
   `scopedModels: this.session.scopedModels`; the scoped-vs-all selection
   itself is in the model-selector constructor (`scope =
   scopedModels.length > 0 ? "scoped" : "all"`) (model-selector.ts:94, 162)
   — the scoped set is listed when non-empty, else the full catalog via
   `modelRuntime.getAvailableSnapshot()`. The extension-ctx equivalents map to
   the SAME underlying sources: `ctx.scopedModels` (types.ts:328 → runner.ts:756-759
   → `contextActions.getScopedModels` (runner.ts:344) → agent-session.ts:2624
   `() => this._scopedModels`) and `ctx.modelRegistry.getAvailable()`
   (model-registry.ts:52-54 = `runtime.getAvailableSnapshot()`,
   model-runtime.ts:422). Server derivation: `ctx.scopedModels` when non-empty,
   else `ctx.modelRegistry.getAvailable()`.
8. **Factory re-invocation**: pi re-invokes the extension factory per session
   runner; rc's entry (`rc(pi)`, index.ts:1374) re-attaches handlers +
   re-registers `/rc` on the new `pi`. Singleton state survives via
   `globalThis[Symbol.for("pi-rc")]`.
9. **Harness**: `pi-extensions/rc/test-client.mjs` spawns pi in RPC mode
   (PI_ARGS at test-client.mjs:47; spawn env `...process.env` at :2124); `/rc`
   is toggled via `{"type":"prompt","message":"/rc"}` (extension commands
   dispatch through `session.prompt` in all modes); RPC `new_session` replaces
   the session directly (group 13 T3 uses it). Harness groups are numbered (0-13
   so far: 11 = rate-limit, 12 = APNs, 13 = pending steers; tests sort by group
   number, test-client.mjs:79). There are FOUR existing `skip(...)` sites
   (env-conditioned-skip convention). A new group 14 for commands.
10. **Subagent landmine (implementation phase)**: subagents cannot run the full
    harness (long bash gets SIGTERM'd); the main session runs it.
11. **Pending-ask mechanism (C1)**: the `ask_user_question` tool IGNORES the
    run-abort signal (ask-user-question/index.ts:192
    `execute(_toolCallId, params, _signal, ...)`); the only AbortController
    wired into `rc.ask()` is the TUI Esc one
    (ask-user-question/index.ts:145-149). So a run blocked on a remote ask
    cannot be settled by a phone Stop (the run signal never reaches the ask).
    `rc.ask()` DOES support signal-based cancel (rc/index.ts:263-270); the only
    cancel path is `cancelPendingAsk` (rc/index.ts:280-290), currently
    reachable from `stop()` (:203), a superseding `ask()` (:238), and the TUI
    Esc controller (:265, via the ask signal listener). `session_shutdown`
    does NOT clear pendingAsk (pre-existing; fixed by this feature — decision 8).
12. **Swift "unknown" sessionId double-rebind + event drop (owner-verified)**:
    CodeViewModel.swift:427-451 — a state frame with sessionId `"unknown"`
    triggers `isRebind` → transcript + pendingQuestion cleared; the later
    `session_start` snapshot clears again. While `session.sessionId ==
    "unknown"`, the event filter (CodeViewModel+Messages.swift:89-91) drops ALL
    event frames until the next real state frame. Mitigation pinned below.

## Wire protocol (additive)

Additive vs the parent spec's frozen protocol in frames/fields/codes: one new
client→server frame, one optional field on `state`, six new error codes. No
version bump (additive precedent: `history.pending`). ONE behavioral change:
`prompt`/`steer` in the session-replacement window change from
drop-with-`invalid_message` to a clean `not_ready` error (the connection
stays up).

Client → server (new frame):

| type | fields | effect |
|------|--------|--------|
| `command` | `command: "new"\|"set_model"\|"compact"\|"name"` + per-command args (A8) | Session-control commands from the phone. ONE generic frame, `command` name field (not one frame type per action). No success frame — side effects flow through existing frames (A8). Per-command args: `set_model {provider, modelId}`; `compact {instructions?}`; `name {name}`; `new` takes none. Errors: `unknown_command`, `not_ready`, `stale_session`, `model_not_found`, `model_not_set`, `command_failed` |

Per-command args:
- `new` — no extra fields.
- `set_model` — `{provider: string, modelId: string}` (same derivation
  as `state.model`). Wire-shape asymmetry: the args use
  `modelId` while `state.model` uses `id`; the Swift client maps between them.
- `compact` — `{instructions?: string}` (trimmed server-side; empty/absent = no
  custom instructions; NO length cap — TUI parity, explicit).
- `name` — `{name: string}` (server trims and rejects empty after trim;
  normalization per verified fact 6 — `[\r\n]+` → single space + trim, no cap,
  no whitespace collapsing).

Server → client (modified frame):

| type | payload |
|------|---------|
| `state` | `{sessionId, cwd, sessionName, model: {provider, id}, thinkingLevel, isStreaming, contextUsage?, models?: [{provider, id}]}` — `models` (2026-09-09, A8) = the same set the TUI `/model` selector lists (scoped set when configured, else the full available catalog); omitted or empty when unavailable. Optional field — older clients ignore it, older servers omit it (additive, no version bump; precedent: `history.pending`) |

Error codes — additions to the parent spec's list (`bad_code`, `rate_limited`,
`version_mismatch`, `invalid_message`, `not_idle`, `unknown_question`);
(2026-09-09, A8 — `command` frames and the replacement window):
`unknown_command` (overloaded: unknown command name, malformed
args, or a `name` empty after trim), `not_ready` (session being replaced / null binding; prompt and steer
return this in the replacement window too, replacing the old
throw→`invalid_message`→drop), `stale_session` (the stashed command ctx was
invalidated by a non-rc session replacement — the message instructs running
`/rc` in the terminal), `model_not_found` (set_model ref not in the available
list), `model_not_set` (pi.setModel returned false — provider auth
unavailable), `command_failed` (compact cancelled/failed; message carries the
sanitized/truncated reason) — `command_failed` is ALSO the catch-all
fallback code for any unexpected error in the `handleCommand` try/catch.

Note: the live rc code already emits `send_failed` (index.ts:781, 812),
which is absent from the frozen parent's error-code list (pre-existing
drift; the parent is frozen, so it is not corrected there).

**No success frame**: each command's side effects flow through existing frames:

| command | client-observable side-effect frames |
|---------|--------------------------------------|
| `new` | (if mid-run: aborted-run tail — `turn_end` with `stopReason:"aborted"`, OLD sessionId) → `session_start` → state+history snapshot rebind |
| `set_model` | `model_select` event → `state` broadcast with the new `model` (and refreshed `models`) |
| `compact` | (if mid-run: aborted-run tail) → `session_compact` event → state+history snapshot; next history page includes the compaction entry |
| `name` | `session_info_changed` event → `state` broadcast with the new `sessionName` |

**Known behavior (v1, accepted — decision 6)**: a `command new`/`compact`
issued while a remote question is pending BLOCKs until the question settles
(the ask tool ignores the run-abort signal — verified fact 11; in practice the
question is on screen in the same phone UI, so it gets answered first — the
phone is also unblocked by Stop, which now cancels the ask, decision 7). For
`compact` specifically the block is invisible: the fire-and-forget IIFE hangs
silently — neither `session_compact` nor `session_compact_failed` fires, the
phone gets zero feedback; accepted (owner: scenario out of scope).

**H3 misattribution (v1, accepted — decision 9)**: command side-effect frames
(`session_compact`/`session_compact_failed`, `model_select`,
`session_info_changed`) are broadcast to ALL connected clients, uncorrelated
with the issuing client; a second phone (or a compact/rename racing a non-rc
replacement) can see another actor's result. Accepted for v1 (single-phone
realistic usage; per-command ids deferred).

**Second invariant (A8, 2026-09-09)**: `session_shutdown` with reason ≠ `quit`
NULLS the binding (the old ctx is about to be invalidated). Until the next
`session_start` rebinds, each handler behaves as follows (a captured ctx is
never dereferenced in that window):

- `prompt` / `steer` / `command` → `error {code:'not_ready'}` to the requesting
  client.
- `abort` → silent no-op (the existing "no-op if not streaming" behavior;
  index.ts:498 `state.binding?.ctx.isIdle()`) — plus the Stop fix: `abort`
  also calls `cancelPendingAsk(state)` (decision 7; server design below).
- `hello` snapshot / `get_state` / `get_history` → answered with the
  null-safe `buildState`/`buildHistory` fallbacks (`sessionId: "unknown"`,
  model `{provider: "unknown", id: "unknown"}` — object shape preserved, Swift
  decodes fine); the next `session_start` snapshot corrects them.

## Server design (`pi-extensions/rc/index.ts`)

- `state.commandCtx: ExtensionCommandContext | null` — stashed in the `/rc`
  command handler (index.ts:1394, alongside the existing `state.bind`) and
  refreshed in every `withSession` callback (the fresh ctx of a phone-driven
  replacement is `ReplacedSessionContext`, command-capable — types.ts:396).
  Kept separate from `state.binding` because `forward()` (index.ts:977-978)
  overwrites `binding.ctx` with plain event ctxs on every forwarded event.
- `handleCommand(state, client, message)`: same auth gate as prompt/steer;
  per-command validation → clean `writeJson` error responses (never throw to
  the blanket catch). Dispatch in `handleClientMessage` is synchronous
  (index.ts:479-521) and the blanket catch in `handleSocketData`
  (index.ts:384-385) cannot catch an async rejection, so `handleCommand`
  must be async with its OWN internal try/catch around the awaits (fallback:
  `writeJson` error), not reliance on the existing catch.
- `new`: serialize — while a `new` is in flight, reject ALL incoming `command`
  frames with `not_ready` (rationale: `ctx.compact` is fire-and-forget
  wrapping an IIFE that starts with `await this.abort()`
  (agent-session.ts:2641-2649, 1947-1948) — a compact racing the old
  session's `dispose()` can surface as a spurious
  `session_compact_failed` attributed to the NEW session). The
  serialization flag MUST reset in `finally` (also on stale/cancelled
  failure). `await state.commandCtx.newSession({withSession: (fresh) => {
  state.commandCtx = fresh }})` in a try/catch — stale-ctx throw
  (runner.ts:593-603) → `stale_session`; `{cancelled: true}` →
  `command_failed`. The await spans the abort+settle on the old session
  (agent-session-runtime.ts:226), so clients see the aborted-run tail strictly
  before `session_start`. Tiny known gap: `createRuntime` emits
  `session_start` BEFORE setup runs `withSession`, so a `command new` arriving
  in that ms-scale window sees the not-yet-refreshed commandCtx stash →
  spurious `stale_session` (accepted, documented).
- `set_model`: derive the available list (verified fact 7); derive each
  entry's `{provider, id}` with the SAME fallbacks `buildState` uses
  (index.ts:818-826); exact (provider, modelId) match →
  `await state.binding.pi.setModel(model)` — `pi.setModel` is
  `Promise<boolean>` (types.ts:1415); without the await, `model_not_set`
  is undetectable and the promise goes unhandled; no match →
  `model_not_found`; `pi.setModel` resolved to false → `model_not_set`.
  Selecting the already-active model is a SILENT no-op (no error, no broadcast
  — `_emitModelSelect` early-returns when the model is unchanged,
  agent-session.ts:1640-1649). When the derived list is empty/unavailable,
  SKIP membership validation and attempt `setModel` directly (a false result
  still yields `model_not_set`).
- `compact`: `state.binding.ctx.compact(instructions ? { customInstructions:
  instructions } : undefined)` — verified fact 4. Fire-and-forget: completion is
  observed via the `session_compact`/`session_compact_failed` events, not a
  return value.
- `name`: `state.binding.pi.setSessionName(trimmedName)` — verified fact 6:
  server trims and rejects empty after trim, applies NO cap of its own; the
  normalization (`[\r\n]+` → single space + trim, no whitespace collapsing)
  is pi's (session-manager.ts:1150-1163).
- New `pi.on` subscriptions:
  - `model_select` (types.ts:830) → `state.broadcast(buildState(state))`
  - `session_info_changed` (types.ts:573) → `state.broadcast(buildState(state))`
    — the name is already read live per frame by `sessionName(state)`
  - `session_compact` (types.ts:607) → `broadcastSessionSnapshot(state)`
    (state + history — the compaction entry is already mapped by
    `mapHistoryEntry`)
  - `session_compact_failed` (types.ts:618) → broadcast
    `error {code:'command_failed', message: <sanitized/truncated reason>}`
    ONLY when the event's `reason === "manual"` (the event carries
    `reason: "manual" | "threshold" | "overflow"`, types.ts:618-627 —
    verified). Auto-compaction failures (threshold/overflow) stay silent to
    the phone; a terminal `/compact` failure ALSO carries
    `reason: "manual"` and would produce the frame — accepted, rare, harmless
    toast. The `session_compact` (success) bullet keeps broadcasting the
    snapshot for ALL reasons (auto-compaction changes context too — the
    phone should refresh).
  - `session_before_compact` stays unsubscribed: the before-event can cancel;
    not needed for the side-effect contract.
- `state` frame gains optional `models: [{provider, id}]` (same derivation as
  `state.model`; omitted or empty when unavailable). Rides every existing state
  broadcast (connect, `get_state`, rebind, model/rename/compact events).
- **`session_shutdown` fix** (verified facts 2 + 11): for `reason !== 'quit'`,
  set `state.binding = null` AND call `cancelPendingAsk(state)` — the pending
  question belongs to the dead session (decision 8); the cancel broadcast +
  null resolve give the phone a clean question-cancelled frame instead of a
  zombie re-delivery on reconnect. Keep `stop()` for quit. (The current
  handler re-binds to the old ctx on every shutdown — index.ts:997 — and
  never clears pendingAsk.)
- **Stop fix (decision 7)**: rc's `abort` handler (index.ts:498) additionally
  calls `cancelPendingAsk(state)` — fixes the pre-existing gap where phone
  Stop/X did not cancel a pending remote ask (the run-signal never reached the
  ask tool — verified fact 11; parent spec B3.5's abort claim was false for
  the blocked-ask case). Semantics: the ask resolves null → the
  `ask_user_question` tool falls through to the LOCAL TUI prompt (identical to
  the existing TUI Esc hatch — ask-user-question/index.ts:134-152).
- **Null-binding guards**: `handlePrompt`/`handleSteer`/`handleCommand` treat a
  null `state.binding` as `error {code:'not_ready'}` to that client — a clean
  per-client error, replacing the current throw→`invalid_message`→drop in the
  replacement window.
- **Concurrency**: `command new`'s await spans the abort+settle (seconds while
  streaming). Other frames are handled concurrently during that window; the
  second `new` is rejected (`not_ready`); a `prompt` during the switch has
  THREE outcomes: `not_idle` (before the abort lands), `not_ready` (the
  null-binding window), or it lands on the new session (after
  `session_start`).
- **Security note**: `compact.instructions` and `name` are phone-authored
  input flowing into pi (summarization prompt / session title); auth-gated,
  but the implementation must run the `security.instructions.md` pass before
  commit.

**Known degraded cases (document, don't fix in v1)**

- A session replaced OUTSIDE rc (terminal `/new`, RPC `new_session`) invalidates
  the stashed `commandCtx` with no way to refresh it → `command new` returns
  `stale_session` (message: run `/rc` in the terminal). `set_model`/`compact`/
  `name` keep working off the live binding (rebound via `forward()` on the new
  session's events).
- After compact, `getContextUsage()` returns null until the next assistant
  message with usage → the context header keeps its stale value (buildState
  omits the field; Swift keeps the last known value). Accepted.

## Swift client design (`openclient-llm/Shared/Features/Code/`)

- `CodeClientMessage.command(command:args:)` — new case on the enum
  (CodeServerClient.swift:80-90); encode the generic frame in `encodeMessage`
  following the frozen encoding pattern (CodeServerClient.swift:~517-570):
  `dict["type"] = .string("command")`, `dict["command"] = .string(...)`, then
  the per-command args as optional keys.
- `CodeSessionInfo` gains `models: [CodeModelInfo]?` (CodeModels.swift:11-20) —
  optional so older servers decode fine; reuses the existing `CodeModelInfo`
  struct (`{provider, id}`, CodeModels.swift:22-29) — the wire shape matches
  exactly.
- `CodeServerError` — **VERIFIED 2026-09-09**: `code` is a plain `String`
  (CodeModels.swift:261-264), not an enum — decoding is already lenient. The
  six new codes decode as-is; no model change. Handling goes in the ViewModel,
  matching the existing string-match pattern (`error.code == "not_idle"` at
  CodeViewModel.swift:498; `case "bad_code":` etc. at :549-590). A
  forward-unknown code must not crash decoding (it can't — String).
- **ViewModel**: new events `newSession()`, `setModel(provider:id:)`,
  `compact(instructions:)`, `rename(name:)` — each maps to `.command(...)`.
  State-driven: `models`/`model` on `state` frames refresh the sheet data and
  the current selection. Error-code handling — NOTE the current `handleError`
  (CodeViewModel.swift:~498/549-590) toasts `not_idle` and SILENTLY IGNORES all
  other codes, so the toasts for the six new codes (including
  `unknown_command`) are NEW code: `model_not_found`/`model_not_set`/
  `stale_session`/`command_failed`/`unknown_command` → informative toast (the
  frame's `message`); `not_ready` → transient toast — it arrives on a LIVE
  connection (nothing to reconnect; the connection stays up), optionally auto
  `get_state` on the next `session_start`.
- **"unknown" sessionId pin (C3, verified fact 12)**: a `state` frame with
  `sessionId == "unknown"` (the null-binding window) must be treated as NOT a
  rebind/overwrite — no transcript/pendingQuestion clear, no session switch —
  and must not trip the event filter (CodeViewModel+Messages.swift:89-91);
  the real `session_start` snapshot does the correction.
- **UI** (describe at spec level; implement later per the
  `design-ui`/`chat-visual-style` specs):
  - Command sheet/menu in `CodeSessionView` (toolbar): New session, Models,
    Compact, Rename.
  - New session and Compact require an explicit confirmation (destructive:
    aborts the in-flight run).
  - Models sheet: list from `state.models`, current selection marked (from
    `state.model`), tap → `set_model`; refreshes on `state` frames (a model
    change arrives via `model_select` → state broadcast).
  - Rename: alert with a text field, pre-filled with the current
    `sessionName`; empty → client-side reject (no frame sent).

## Test plan

### Harness — `pi-extensions/rc/test-client.mjs` group 14 (WS commands)

Child in RPC mode; rc on via the `/rc` prompt (verified fact 9). Group 14 runs
last (registered after group 13) — after the rate-limit group (11) and its lockout
wait, with the IP counter reset by later successful hellos.

1. `command new` while idle → `session_start` + snapshot with a NEW sessionId;
   same client stays connected.
2. `command new` while a run is live → aborted-run tail (`turn_end`
   `stopReason:"aborted"`, OLD sessionId) strictly before `session_start`;
   snapshot reflects the new session.
3. Chained `command new` twice (withSession stash) → both succeed (second sees
   the new session).
4. `command new` after an RPC `new_session` replacement (non-rc path) →
   `stale_session` error.
5. `command set_model` with an available model → subsequent `state` carries the
   new model; unknown ref → `model_not_found`. (The child runs the real `zai`
   provider with inherited env auth (test-client.mjs:47 `PI_ARGS`, spawn env
   `...process.env` at :2124) and `test-project/` holds no model config — so
   the test reads the `models` array from the `state` frame (that IS the
   catalogue probe); require ≥ 2 entries, else skip (env-conditioned, same
   convention as the existing four skips); the positive case picks a
   (provider, modelId) different from the current `state.model`.)
6. Mid-stream compact (success path): seed first — run a couple of natural
   prompt/turn exchanges (the group-12 "Reply with exactly: PING-xN" settle
   pattern) — then start a live run (group-13 long-generation pattern) and
   issue `command compact` while it is streaming → abort tail +
   `session_compact` snapshot; next history includes the compaction entry.
   (The near-empty compact failure path is a SEPARATE test — item 11.)
7. `command name` → `state` carries the new `sessionName`; empty name →
   `unknown_command` (the overloaded code — same as unknown name / malformed
   args).
8. Unknown command name → `unknown_command`.
9. `not_ready` window: explicitly NOT pinned — the black-box window is
   ms-scale and an RPC-replacement + immediate-frame probe is too racy to pin
   deterministically; there is no TS unit harness for rc/index.ts in this repo
   (the harness is black-box WS), so there is no forced-null unit test either;
   covered indirectly by the rebind/`stale_session` tests.
10. Second `command new` issued while the first is in flight → `not_ready`
    (item 3 chains sequentially only).
11. Near-empty `command compact` (no seeded content) → assert a
    `command_failed` error frame reaches the client (exercises the
    `reason === "manual"` gate; rc's subscription is live in the harness —
    compact throws "Nothing to compact (session too small)" on a short branch,
    agent-session.ts:1966-1968 → `session_compact_failed`). Order it BEFORE
    item 6's seeding, or in a fresh session after a `command new` (items 1-3
    end in fresh sessions, so the session is near-empty by default).
12. `abort` (phone Stop) while a remote question is pending → client receives
    the question-cancelled frame (pins the Stop fix, decision 7; use the
    existing question harness pattern from group 12 / parent spec).
13. After an RPC `new_session` replacement, a pending question is NOT
    re-delivered to a reconnecting client (pins C2 — pendingAsk cleared on
    shutdown, decision 8).

### Swift unit tests (run order per parent spec C3)

- Command frame encoding — all four shapes (`new`, `set_model`, `compact`
  with/without `instructions`, `name`).
- `CodeSessionInfo` decode with and without `models`.
- Error-code decode: the six new codes + a forward-unknown code (lenient
  `String` — must not crash).
- VM handling: state-driven model updates (sheet data + current selection) and
  command error toasts.
- Canned state frame with `sessionId: "unknown"` → no rebind/overwrite (no
  transcript/pendingQuestion wipe); then a real `session_start` frame → normal
  rebind (C3 pin, verified fact 12).
- `not_ready` transient handling (toast, connection stays up).

### Manual smoke (phone; extends parent spec C4)

- Models sheet → pick a different model while streaming → state refreshes with
  the new model.
- Compact → confirm → context bar resets (stale until the next assistant
  message — accepted).
- Rename → new name shows in the header and in the body of the next
  finished-push (session name feeds push bodies).

## Open items / risks

- Terminal-`/new` stale `commandCtx` recovery: a session replaced outside rc
  leaves no automatic refresh path; `command new` returns `stale_session` until
  the user runs `/rc` again (documented degraded case, accepted for v1).
- `not_ready` window not pinned by the harness (timing-dependent); covered
  indirectly by the `stale_session` and rebind tests.
- `model_not_set` may be infeasible in the harness (requires a provider without
  auth) — env-conditioned skip, same convention as the existing four skips.
- `set_model` positive path is env-conditioned (real `zai` + ≥ 2 models in the
  catalog; no hermetic equivalent) — if the env lacks it the positive path
  silently skips (same convention as the existing skips); the
  `model_not_found` negative path is env-independent and always runs.
- Security pass (`security.instructions.md`) required before commit for the
  phone-authored-input surface (`compact.instructions`, `name`).

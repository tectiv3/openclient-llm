# Plan: rc remote commands

Status: spec only, 2026-09-09; not yet implemented.
Date: 2026-09-09.
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
   after session replacement", runner.ts:593-603). rc's unguarded
   `binding.ctx.isIdle()` in `handlePrompt`/`handleSteer` (index.ts:774/800) throws
   → blanket catch in `handleSocketData` → client dropped with a misleading
   `invalid_message`. FIX: in the `session_shutdown` handler (index.ts:996-999),
   when `reason !== 'quit'`, set `state.binding = null` (instead of the current
   no-op rebind to the old ctx at index.ts:997; keep `stop()` for quit).
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
   does NOT currently subscribe. **VERIFIED: the TUI `/name` has no length cap** —
   `handleNameCommand` (interactive-mode.ts:6187-6201) trims and passes to
   `session.setSessionName(name)` (agent-session.ts:3091 →
   `sessionManager.appendSessionInfo(name)`); the name is normalized
   server-side and `session_info_changed` fires with the normalized name (the TUI
   warns when normalization changed the input). rc's `sessionName(state)` reads
   live from `ctx.sessionManager.getSessionName()` per frame.
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
   runner; rc's entry (`rc(pi)`, index.ts:1373) re-attaches handlers +
   re-registers `/rc` on the new `pi`. Singleton state survives via
   `globalThis[Symbol.for("pi-rc")]`.
9. **Harness**: `pi-extensions/rc/test-client.mjs` spawns pi in RPC mode; `/rc`
   is toggled via `{"type":"prompt","message":"/rc"}` (extension commands
   dispatch through `session.prompt` in all modes); RPC `new_session` replaces
   the session directly (group 13 T3 uses it). Harness groups are numbered (0-13
   so far: 11 = rate-limit, 12 = APNs, 13 = pending steers; tests sort by group
   number, test-client.mjs:79). A new group 14 for commands.
10. **Subagent landmine (implementation phase)**: subagents cannot run the full
    harness (long bash gets SIGTERM'd); the main session runs it.

## Wire protocol (additive)

Purely additive vs the parent spec's frozen protocol: one new client→server
frame, one optional field on `state`, six new error codes. No version bump
(additive precedent: `history.pending`).

Client → server (new frame):

| type | fields | effect |
|------|--------|--------|
| `command` | `command: "new"\|"set_model"\|"compact"\|"name"` + per-command args (A8) | Session-control commands from the phone. ONE generic frame, `command` name field (not one frame type per action). No success frame — side effects flow through existing frames (A8). Per-command args: `set_model {provider, modelId}`; `compact {instructions?}`; `name {name}`; `new` takes none. Errors: `unknown_command`, `not_ready`, `stale_session`, `model_not_found`, `model_not_set`, `command_failed` |

Per-command args:
- `new` — no extra fields.
- `set_model` — `{provider: string, modelId: string}` (same field
  names/derivation as `state.model`).
- `compact` — `{instructions?: string}` (trimmed server-side; empty/absent = no
  custom instructions).
- `name` — `{name: string}` (server trims; empty after trim → reject).

Server → client (modified frame):

| type | payload |
|------|---------|
| `state` | `{sessionId, cwd, sessionName, model: {provider, id}, thinkingLevel, isStreaming, contextUsage?, models?: [{provider, id}]}` — `models` (2026-09-09, A8) = the same set the TUI `/model` selector lists (scoped set when configured, else the full available catalog); omitted or empty when unavailable. Optional field — older clients ignore it, older servers omit it (additive, no version bump; precedent: `history.pending`) |

Error codes — additions to the parent spec's list (`bad_code`, `rate_limited`,
`version_mismatch`, `invalid_message`, `not_idle`, `unknown_question`);
(2026-09-09, A8 — `command` frames and the replacement window):
`unknown_command` (unknown command name or malformed
args), `not_ready` (session being replaced / null binding; prompt and steer
return this in the replacement window too, replacing the old
throw→`invalid_message`→drop), `stale_session` (the stashed command ctx was
invalidated by a non-rc session replacement — the message instructs running
`/rc` in the terminal), `model_not_found` (set_model ref not in the available
list), `model_not_set` (pi.setModel returned false — provider auth
unavailable), `command_failed` (compact cancelled/failed; message carries the
sanitized/truncated reason).

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

**Second invariant (A8, 2026-09-09)**: `session_shutdown` with reason ≠ `quit`
NULLS the binding (the old ctx is about to be invalidated). Until the next
`session_start` rebinds, each handler behaves as follows (a captured ctx is
never dereferenced in that window):

- `prompt` / `steer` / `command` → `error {code:'not_ready'}` to the requesting
  client.
- `abort` → silent no-op (the existing "no-op if not streaming" behavior;
  index.ts:491 `state.binding?.ctx.isIdle()`).
- `hello` snapshot / `get_state` / `get_history` → answered with the
  null-safe `buildState`/`buildHistory` fallbacks (`sessionId: "unknown"`,
  model `unknown`); the next `session_start` snapshot corrects them.

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
  `session_compact_failed` attributed to the NEW session). `await state.commandCtx.newSession({withSession: (fresh) => {
  state.commandCtx = fresh }})` in a try/catch — stale-ctx throw
  (runner.ts:593-603) → `stale_session`; `{cancelled: true}` →
  `command_failed`. The await spans the abort+settle on the old session
  (agent-session-runtime.ts:226), so clients see the aborted-run tail strictly
  before `session_start`.
- `set_model`: derive the available list (verified fact 7); derive each
  entry's `{provider, id}` with the SAME fallbacks `buildState` uses
  (index.ts:818-826); exact (provider, modelId) match →
  `await state.binding.pi.setModel(model)` — `pi.setModel` is
  `Promise<boolean>` (types.ts:1415); without the await, `model_not_set`
  is undetectable and the promise goes unhandled; no match →
  `model_not_found`; `pi.setModel` resolved to false → `model_not_set`.
- `compact`: `state.binding.ctx.compact(instructions ? { customInstructions:
  instructions } : undefined)` — verified fact 4. Fire-and-forget: completion is
  observed via the `session_compact`/`session_compact_failed` events, not a
  return value.
- `name`: `state.binding.pi.setSessionName(trimmedName)` — verified fact 6 (no
  TUI cap; server trims, rejects empty after trim, applies no cap of its own).
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
- **`session_shutdown` fix** (verified fact 2): for `reason !== 'quit'`, set
  `state.binding = null`; keep `stop()` for quit. (The current handler
  re-binds to the old ctx on every shutdown — index.ts:997.)
- **Null-binding guards**: `handlePrompt`/`handleSteer`/`handleCommand` treat a
  null `state.binding` as `error {code:'not_ready'}` to that client — a clean
  per-client error, replacing the current throw→`invalid_message`→drop in the
  replacement window.
- **Concurrency**: `command new`'s await spans the abort+settle (seconds while
  streaming). Other frames are handled concurrently during that window; the
  second `new` is rejected (`not_ready`); a `prompt` during the switch hits the
  abort/rebind naturally (`not_idle` before the abort, or lands on the new
  session after `session_start`).

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
  the current selection. Error-code handling: `model_not_found`/
  `model_not_set`/`stale_session`/`command_failed` → informative toast (the
  frame's `message`); `not_ready` → transient, dismissible (the client
  auto-reconnects/re-requests state as today).
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
   provider with inherited env auth (test-client.mjs:46 `PI_ARGS`, spawn env
   `...process.env` ~2138) and `test-project/` holds no model config — so the
   test reads the `models` array from the `state` frame (that IS the
   catalogue probe); require ≥ 2 entries, else skip (env-conditioned, same
   convention as the existing two skips); the positive case picks a
   (provider, modelId) different from the current `state.model`.)
6. Seed first: run a couple of natural prompt/turn exchanges (the group-12
   "Reply with exactly: PING-xN" settle pattern) before `command compact` —
   compact throws "Nothing to compact (session too small)" on a short branch
   (agent-session.ts:1966-1968) → `session_compact_failed` instead of
   `session_compact`. Items 1-3 end in fresh sessions, so item 6's session is
   near-empty by default. Then start a live run (group-13 long-generation
   pattern) and issue `command compact` while it is streaming → abort tail +
   `session_compact` snapshot; next history includes the compaction entry.
7. `command name` → `state` carries the new `sessionName`; empty name →
   `unknown_command` error.
8. Unknown command name → `unknown_command`.
9. `not_ready` window: explicitly NOT pinned (timing-dependent) — document.

### Swift unit tests (run order per parent spec C3)

- Command frame encoding — all four shapes (`new`, `set_model`, `compact`
  with/without `instructions`, `name`).
- `CodeSessionInfo` decode with and without `models`.
- Error-code decode: the six new codes + a forward-unknown code (lenient
  `String` — must not crash).
- VM handling: state-driven model updates (sheet data + current selection) and
  command error toasts.

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
  auth) — env-conditioned skip, same convention as the existing two skips.
- Implementation-time verification: Swift `updateSession`/state handling
  receiving a `state` frame with `sessionId: "unknown"` (possible when a
  (re)connect or `get_state` lands in the replacement window) — confirm the
  VM tolerates it and the `session_start` rebind snapshot corrects the UI
  (critic flagged this as untraced).

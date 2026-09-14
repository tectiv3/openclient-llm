# rc: subagent attach, stop-UX, reconnect dedupe

Status: IMPLEMENTED 2026-09-14. All tasks done: T1 `cfb9726`,
T2 `8ccfb6a`, T3 `022393a` (in `~/code/pi-extensions`), T4a `9946375` +
T4b `c3df3ea`, T5 `ded0307`, T6 `fbe8bcd`, T7 `e533064`. Spec (owner-approved decisions, 2026-09-13;
round-1 amended 2026-09-13 after in-repo verification — see Critic log).
Three features, one doc because they share the same surface (rc wire
protocol + `Features/Code` UI).

Parent refs: `docs/plans/rc-remote-control-spec.md` (frozen),
`docs/plans/rc-commands-spec.md`, `docs/plans/rc-multi-session-spec.md`,
`docs/plans/2026-09-08-subagent-attach-design.md` (TUI attach — different
feature, same word).

## Critic log

| Round | Reviewer | Outcome |
|-------|----------|---------|
| 1 | main agent (in-repo code verification) | Amended: buffer composition + prune rule corrected (toolcall_delta arg-junk placeholder); bus payload shape corrected (`event.type` = name, explicit filter set); lifecycle = `agent_start`/`agent_settled` only (no `exit` on bus); settle detection via terminal file-state poll; dir scan read-only (probe, never unlink); partial-ID decision #8 added (TUI surfaces already prefix-capable — verified); test scope corrected (unit tests only, no harness — LLM API rate-limited); Feature C steer-preservation clarified; test locations pinned |
| 2 | plan-critic subagent (text review; load-bearing claims re-verified in-repo by main agent: buffer clear sites, toolResult branch-entry shape in real session files, `RcClient.selectedId`, pidfile-removed-first settle choreography) | REVISE, no blockers. Folded in: **M1** prune rule extended to `toolResult` tails (the between-tools window re-duplicated committed text — real session files confirm `role:'toolResult'` branch entries); **M2** per-run in-flight buffer accumulates from first observed event, not from attach; **M3** all subagent frames scoped to the client's effective session (`selectedId ?? entryId`), attach state on `RcClient`; **M4** `hello_ok.features` capability gate + defensive no-op on new-request errors (new app vs un-restarted rc); **m1** settle keyed on META presence, not pidfile, deadline extends while pid alive; **m2** camelCase + exact shape parity pinned; **m3** T2/T5 reuse `mapAssistantContent`/`updateToolStepCompletion` and re-sign the `&session` helpers (named); **m4** reconnect-during-attach re-attach rule; **m5** concurrent attach semantics; **m6** T7 names the 4 preview fixtures + header-row (not ToolbarItem) host; test matrix gains toolResult-tail rows + mixed-block merge case |
| 3 | plan-critic subagent (verification pass) | Fold-in of all round-2 findings confirmed present in operative sections; two one-line fixes: m6 host claim corrected (dot IS in a native `ToolbarItem(placement: .navigation)` — `CodeSessionView.swift` ~L87–93, verified in code; T7 must build-verify the 44pt hit area with relocation fallback) + `M5`→`m5` typo. All other findings APPROVED implementation-ready. |

## Scope (owner decisions, 2026-09-13)

| # | Decision | Chosen |
|---|----------|--------|
| 1 | Duplicate subagent on reconnect | Fix server-side: prune the reconnect streaming buffer to branch-tail; client merges buffer by toolCallId instead of blind append |
| 2 | Subagent feature v1 | ATTACH ONLY, via tapping a live subagent tool step in the transcript. No header-menu entry, no list sheet, no steer, no stop, no resume/inspect from the phone |
| 3 | Cross-repo change allowed | YES, minimal: subagent ext writes `toolCallId` into the `.meta` sidecar at spawn (the only link between a transcript tool step and a run) |
| 4 | Live determination / list source | rc reads the same files `/subagents` lists: `~/.pi/agent/subagents/*.meta` + `.pid` liveness + `parentSessionId` scoping; live tail from the `subagent:event` bus |
| 5 | Attach view content | Full live transcript incl. tool steps (forward child `tool_execution_*` + `message_*` from the bus) |
| 6 | Attach view on settle | Stay open, show finished banner |
| 7 | Stop button | REMOVE from the input bar entirely. Replace with the header status dot: while working the dot PULSES (no text label); tap = abort, haptic on stop. Input bar is send-only in all states (send/steer only — see Feature C) |
| 8 | Partial id resolution (owner, 2026-09-13) | rc's `attach_subagent` accepts a partial subagent id (exact, or unique prefix against this session's live runs — same semantics as the extension's resolvers). Verified in code: the TUI surfaces ALREADY do exact-or-unique-prefix — `resolvePersistedResumeTarget` (`/subagents resume`), `resolveAttachTarget` (`/subagents attach`/`abort`), `resolveInspectTarget` (`subagent_inspect` tool). No TUI work needed; T3 stays meta-only |

Out of scope v1 (future): subagents menu/list sheet, phone-side steer/stop of a
subagent, resume/inspect of persisted runs, persisted (finished) run transcripts
from the phone, tapping dead subagent steps (they keep normal expand behavior).

---

## Feature A — duplicate subagent on reconnect

### Root cause (verified in code, 2026-09-13)

On (re)connect the server sends `writeSessionSnapshot` (rc/index.ts:993):
`buildState` + `buildHistory` + `streamingBuffer`.

- `buildHistory` maps `ctx.sessionManager.getBranch()`.
- `streamingBuffer` = `state.currentTurnBuffer` (only when streaming and
  non-empty, per `hasStreamingBuffer`).

`currentTurnBuffer` accumulates the in-flight turn's blocks and is cleared only
at `message_start` (assistant role) and `turn_end` (also reset in `stop()`).
The assistant message is committed to the branch at `message_end` — BEFORE the
tools run. So while any tool is mid-run, the committed assistant message
(text/thinking + its `toolUse` blocks) is in BOTH the branch and the buffer.
The Swift client rebuilds items from history wholesale (`handleHistory`), then
appends the buffer as a fresh assistant item (`handleStreamingBuffer`) → the
text + tool step render twice.

Subagents run for minutes, so a reconnect always lands inside the overlap
window. bash/read finish in <1s, so the bug is invisible there. (Same latent
defect for any long tool.)

**Buffer composition (verified, refines the original sketch).** While the turn
is in flight the buffer holds, in order:

1. `text` / `thinking` blocks — accumulated from `message_update`
   `text_delta`/`thinking_delta` (real assistant content).
2. A `toolUse` **arg-junk placeholder** per generated tool call — from
   `message_update` `toolcall_delta`: the model's argument-stream chunks land in
   the block's `output`, with `toolCallId: ''`, `toolName: 'tool'`,
   `args: {}`. This block has no committed counterpart (the committed message
   carries the final args inside proper `toolUse` blocks).
3. `toolUse` **in-flight carriers** — pushed at `tool_execution_start`
   (real `toolCallId`/`toolName`/`args`), updated by
   `tool_execution_update`/`end` via `updateToolOutput`
   (`output` ← `partialResult`/`result`). These are the ONLY part of the buffer
   the client genuinely lacks while a tool runs.

So "the buffer is duplicated" is true for (1), and the real keep-set is (3);
(2) is noise that must not reach the client as a tool step.

### Fix — server prune (source of truth)

`turnBuffer.ts` (NEW small module, exported so it is unit-testable WITHOUT
importing index.ts — same pattern as the existing `apns.ts`/`registry.ts`
test seams) defines both pure pieces:

- `assistantTailToolCallIds(lastBranchEntry: unknown): string[] | null` —
  minimal self-contained parse of ONE branch entry (type `message`, role
  `assistant`) collecting the `toolUse`/`tool_use`/`toolCall` part ids
  (`toolCallId` ?? `id`); `null` when the entry is not an assistant message.
  (Not a reuse of index.ts's `contentBlocks` — keeps the module boundary clean;
  the id extraction is ~10 lines.)
- `tailClassification(lastBranchEntry: unknown):` — a small union, e.g. `{kind: 'assistant', toolCallIds: string[]}` | `{kind: 'toolResult', toolCallId: string} | {kind: 'uncommitted'}` — classifies ONE branch entry (verified real shapes: assistant = `message.role === 'assistant'` with `content[]` of `toolCall {id, name, arguments}` parts; tool result = `message.role === 'toolResult'` with `toolCallId`/`toolName`/`content`/`isError`). `uncommitted` = anything else (user/compaction/etc — genuinely no committed assistant tail).
- `pruneBufferForSnapshot(buffer: ContentBlock[], tail: TailClassification):` `ContentBlock[]` — the drop/keep rule below.

index.ts composes them at snapshot build time. VERIFIED choke point: the
`streaming_buffer` frame is built ONLY by `streamingBuffer(state)` and emitted
ONLY from the two snapshot functions — `writeSessionSnapshot` (hello burst) and
`broadcastSessionSnapshot` (`session_start` re-broadcast,
`session_compact`/`session_compact_failed` re-broadcasts). The `get_state`/
`get_history` answers send NO buffer frame (verified), so they need no prune
hook. Prune INSIDE `streamingBuffer()` itself — one choke point covers both
call sites; `hasStreamingBuffer`'s gate is unchanged.

IN-VARIANT the rule relies on (consequence of clear-on-assistant-
`message_start`): the buffer's content belongs to AT MOST ONE assistant
message — its `text`/`thinking` deltas plus that message's tool-call carriers.

- `tail.kind === 'assistant'` (buffer's message committed with its toolUse
  blocks):
  - DROP the buffer's `text`/`thinking` blocks (duplicated in the branch).
  - KEEP buffer `toolUse` blocks whose `toolCallId` matches a committed
    `toolUse` in the tail message (the in-flight carriers, with their live
    `output`).
  - DROP everything else — in particular the arg-junk placeholder
    (`toolCallId: ''` never matches; keeping it would render a phantom
    "tool" step with argument-stream text as output).
- `tail.kind === 'toolResult'` (M1 — the BETWEEN-TOOLS window: the buffer's
  assistant message A is committed, its tool t has returned (result is in the
  branch), the model is generating the next message; buffer was NOT cleared —
  only `message_start`(assistant) clears it, and B has not started):
  - DROP the buffer's `text`/`thinking` blocks (A's content is in the branch).
  - DROP buffer carriers with `toolCallId === tail.toolCallId` (complete +
    committed via the toolResult entry).
  - KEEP other buffer carriers (parallel tools still in flight).
  - DROP the arg-junk placeholder as above.
- `tail.kind === 'uncommitted'` (branch tail is user/compaction — the buffer
  is a genuinely uncommitted tail): keep the buffer as-is. The arg-junk
  placeholder in this case is the existing live-streaming behavior (the
  placeholder is replaced in-place by the real carrier at
  `tool_execution_start`, same buffer slot) — unchanged by this fix.

No change to live `event` forwarding.

### Fix — client merge (defensive + required for Feature B)

Swift `handleStreamingBuffer` stops blindly appending a new assistant item. New
merge semantics over the rebuilt/merged items (shared helper — see Feature B;
the same function merges an attach snapshot):

- `toolUse` block → find LAST toolStep with the same `toolCallId` → update its
  `output`/`isComplete` (live = not complete). Not found → append a new
  toolStep (defensive fallback only — after the server prune this happens only
  if the committed tail is missing the id, which the server would have dropped).
- `text`/`thinking` block → append a streaming assistant item (existing
  behavior); with the server prune in place this only happens for genuinely
  uncommitted content (branch tail is not an assistant message).

### Tests

- UNIT ONLY (owner, 2026-09-13: the original "no new tests" note was
  mis-scoped — it applied to harness runs, which need live LLM turns and the
  API is rate-limited; unit tests are fine and expected):
  - TS: `turnBuffer.ts` unit-tested in
    `pi-extensions/rc/__tests__/turnBuffer.test.ts` (vitest, same setup as the
    existing `apns.test.ts`/`registry.test.ts`). Matrix (round-2 additions
    bolded): assistant tail drop/keep; arg-junk placeholder dropped in every
    committed-tail case; empty buffer; **tail=toolResult + its completed
    carrier → carrier dropped, text dropped**; **tail=toolResult + a
    DIFFERENT live carrier (parallel tool) → only the live carrier kept**;
    **tail=toolResult + buffer=[text, that carrier, live carrier] → text and
    completed carrier dropped, live carrier kept**; uncommitted tail kept
    as-is.
  - Swift: VM unit test for the merge semantics in
    `openclient-llm-test/Features/Code/CodeViewModelTests+Streaming.swift`
    (scripted `streaming_buffer` frames — the file already exists for this).
    Must include (m3): one scripted frame with MIXED blocks
    `[text, toolUse(live, new id), toolUse(completed, id already in items)]`
    → text becomes its own streaming assistant item, BOTH tool steps land on
    their existing toolSteps by `toolCallId`, no item duplication — the merge
    must route blocks to `mapAssistantContent`/`updateToolStepCompletion`
    (the existing groupers, `CodeViewModel+Messages.swift`), not a second
    invented path.
- NO new harness (test-client.mjs) group for reconnect-mid-tool: pinning it
  needs a live LLM turn mid-tool; not required while the API is rate-limited.

---

## Feature B — subagent attach (phone, v1 = attach via transcript tap)

### Entry points

- The `subagent` tool step in the main transcript is TAPABLE while its run is
  live → opens the attach view for that run.
- Dead runs: steps keep normal expand behavior (args + output), no attach.
- No header-menu entry, no list sheet (v1).

### Identity mapping (verified, 2026-09-13)

- Transcript tool step identity = the LLM `toolCallId` (already carried on
  `tool_execution_*` events and in history `toolUse` blocks).
- Run identity = the subagent id (uuidv7 at spawn).
- The subagent extension's `execute(_toolCallId, params, ...)` has BOTH; today
  it ignores the toolCallId (the parameter is literally `_toolCallId`).
  CHANGES IN THE OTHER REPO (`tectiv3/pi-extensions`, minimal):
  - `SubagentMeta` gains `toolCallId?: string`; written into the `.meta`
    sidecar at spawn alongside the existing fields (interface + spawn write).
- rc therefore learns `{subagentId, toolCallId}` from the same `.meta` files
  `/subagents` already lists — no event-bus command channel needed.

### rc data sources (no other-repo change beyond the meta field)

1. **Directory scan** `~/.pi/agent/subagents/` (the `getSubagentsDir()`
   location): `.meta` (agent, task, startedAt, model, status,
   parentSessionId, toolCallId) + `.pid` liveness probe (`process.kill(pid, 0)`:
   ESRCH = dead, EPERM = alive — the same probe the extension's
   `isProcessAlive` uses) + `parentSessionId === the requesting client's
   effective session` scoping (runs
   without the field are hidden, matching the `/subagents` manager).
   READ-ONLY: rc probes and never unlinks. (The extension's own
   `deriveSubagentRunStatus` deletes stale `.pid` files as a side effect; rc
   must NOT — a killed child's stale pidfile is harmless, the extension's next
   listing cleans it.) Torn `.meta` JSON is skipped, like the extension's
   `listPersistedSubagents`.
   "Live" = pidfile present AND probe alive AND status not terminal. Note the
   extension DELETES `.jsonl`/`.meta`/`.pid` of a run on success
   (`runSingleAgent` settlement), so settled-successful runs disappear from
   the scan on their own.
2. **Live tail** — rc subscribes to the `subagent:event` bus (already emitted by
   the subagent ext for every child stdout event). VERIFIED payload shape:
   `{subagentId, agent, event}` where `event` is the RAW pi RPC frame — the
   event name is `event.type` (there is no `name` field on the bus payload).
   rc:
   - maps `name = event.type`, `payload = event minus {type}` (mirroring the
     main session's `eventPayload` strip, so `subagent_event` frames have the
     same `name`/payload shape as the main `event` frame);
   - forwards to ATTACHED runs a WHITELIST of event types only:
     `message_start`, `message_update`, `tool_execution_start`,
     `tool_execution_update`, `tool_execution_end`, `turn_end`, `agent_start`,
     `agent_settled`. Everything else (`message_end`, `tool_result_end`,
     `queue_update`, `status`, `model_select`, `session_start`,
     `session_before_compact`, `session_info_changed`, …) is consumed for
     internal state only — PARSE, don't merely discard: `session_start` /
     `session_info_changed` update the run's model/session display fields in
     the scan cache, `message_end` updates the per-run `lastStopReason` (see
     the settle rule). A blanket forward would break the client reducer
     (`message_start`/`message_update` carry no `sessionId`, so the client
     cannot dedupe/attribute them, and unknown frames are decoded to
     `.unknown` anyway).
   - tracks in-flight tool output PER RUN — lazily, from the FIRST observed
     bus event for that subagentId, independent of attach state (M2: attach
     mid-run is the normal case; the in-flight turn is uncommitted, absent
     from the `.jsonl`, and must still appear in the attach snapshot). A
     `currentTurnBuffer`-style buffer keyed by subagentId, same
     `appendAssistantDelta`/`updateToolOutput` logic as the main session. One
     small buffer per live child run is the cost. Cleared on that run's
     assistant `message_start` / `turn_end` / settle. Because the buffer is
     always warm, re-attach (m4) gets the live tail for free.
   - treats `agent_start`/`agent_settled` (per child run) as lifecycle (there
     is NO `exit` event on the bus — child process exit is handled inside the
     extension and never re-emitted). On `agent_settled` for run R: wait for
     R's TERMINAL FILE STATE (poll ~50 ms apart, 2 s deadline) — KEYED ON
     META, not the pidfile (m1: the extension removes `.pid` unconditionally
     FIRST on every exit, so the pidfile is never a classifier; verified at
     subagent/index.ts settlement): `.meta` GONE → `succeeded` (only success
     deletes it); `.meta` present WITH `status` → that status (`failed` /
     `aborted`; the non-success path rewrites meta with
     `{status, stopReason, exitCode, sessionHeaderId}`); `.meta` present, no
     `status`, pid probe DEAD → `failed` (abnormal death); `.meta` present, no
     `status`, pid still ALIVE → still shutting down, EXTEND the deadline
     (a slow clean shutdown must not misreport `failed`); deadline exhausted →
     `failed`. `stopReason` source: meta's `stopReason` when present, else the
     last observed `message_end` payload's `message.stopReason` for that run
     (rc already tracks it per-run with the buffer), else omitted. Then
     broadcast `subagent_settled {subagentId, status, stopReason?}` + a
     refreshed `subagents` frame (scan again: R is no longer live), and
     stop streaming R's events + clear R's in-flight buffer. On
     `agent_start` (or a re-scan finding a new live run): broadcast a
     refreshed `subagents` frame so steps become tappable.
3. **Transcript history** — the child's `.jsonl` IS a pi session file
   (`{type:'message', message:{...}}` lines; same entry shape the extension's
   `parseSubagentTranscript` reads). rc reuses the existing `mapHistoryEntry` /
   `contentBlocks` mapping over those lines (skip non-message lines).
   Verified mapping: user → text item, assistant → content blocks,
   `toolResult` → completion of the matching toolUse step, compaction →
   separator; unrecognized roles return `[]` and are skipped. The child's
   jsonl carries the same entry shapes as any pi session file (the child IS a
   pi process), so the attach history renders user/assistant bubbles +
   COMPLETED tool steps with outputs; the in-flight tail (current turn) comes
   from the buffer merge.

### Wire protocol (additive; rollout-gated, M4)

- New KEYS in existing frames: safe as-is (Swift `JSONDecoder` ignores
  unknown keys — same precedent as `history.pending`).
- New REQUEST TYPES are NOT safe as-is: extensions load at pi process start, so
  a running pi keeps the OLD rc until restart while the phone runs the NEW
  app — `get_subagents`/`attach_subagent` would hit the old server's
  unknown-request path. Gate: rc advertises
  `hello_ok {version, features: ["subagents"]}` (additive field; old clients
  ignore it). Swift client sends the new requests ONLY when the capability
  was advertised (store `subagentFeatures: Set<String>` from `hello_ok` in the
  VM), and INDEPENDENTLY treats an `error` reply to `get_subagents`/
  `attach_subagent` as a NO-OP (log; keep all local state; never a
  session-level failure) — belt and braces so an un-restarted rc can't break
  the main transcript UI.

Client → server:

| type | fields | effect |
|------|--------|--------|
| `get_subagents` | — | Reply `subagents` frame (directory scan, this-session scope). Reply is always sent; `subagents` is an EMPTY array when there are no live runs (the Swift client clears `liveSubagents` from it — "omitted" would leak stale state) |
| `attach_subagent` | `subagentId?` and/or `toolCallId?` (rc resolves either against the client's effective session; `subagentId` accepts an exact id OR a unique prefix against that session's live runs — decision #8; `toolCallId` is exact match only) | Start attach: reply `subagent_snapshot`; stream `subagent_event` for that run until detach/settle. Unknown/ambiguous/dead → `error {code: 'subagent_not_found', message}` (message lists the live candidates on ambiguity, mirroring the extension's ambiguity errors). Attach state lives on `RcClient` (next to `selectedId`): ONE attach per client — a new `attach_subagent` implicitly detaches the client's previous attach; TWO clients MAY attach to the same run simultaneously (the per-run buffer is a shared read-only mirror, m5) |
| `detach_subagent` | `subagentId` | Stop streaming (also implicit on new attach, on session-selection change away from the run's session, on client close, and on run settle) |

Server → client:

| type | payload |
|------|---------|
| `subagents` | `{subagents: [{id, agent, toolCallId?, task, startedAt, model?}]}` — LIVE runs of the RECEIVING client's effective session (`client.selectedId ?? state.entryId` — per-connection session selection exists; "current session" without the qualifier was the M3 hole). Sent on connect (snapshot burst), on session-selection change (the `session_start` re-broadcast site already exists for the main snapshot), on `get_subagents`, and on lifecycle changes |
| `subagent_snapshot` | `{subagentId, agent, task, startedAt, running: Bool, history: [history messages], buffer?: [content blocks]}` — `history` from the `.jsonl` (same message shape as `history.messages`, built with `mapHistoryEntry`); `buffer` = in-flight tail, PRUNED by the Feature A function (branch tail = last jsonl message) |
| `subagent_event` | `{subagentId, name, payload}` — one whitelisted child event per frame, `name` = the child's `event.type`, `payload` same shape as the main `event` frame's payload |
| `subagent_settled` | `{subagentId, status: 'succeeded' \| 'failed' \| 'aborted', stopReason?}` — derived per the lifecycle rule above (meta-keyed terminal file state) |

Error handling: unknown/dead/ambiguous id on `attach_subagent` → `error {code:
'subagent_not_found'}` (new code).

FIELD CONVENTIONS (m2 — pin these; a TS and a Swift implementer must agree):
all new frames use CAMELCASE keys exactly as shown (`subagentId`,
`toolCallId`, `startedAt`) — same convention as the existing frames.
`subagent_snapshot.history` elements are byte-for-byte the same JSON shape as
`history.messages` elements (Swift `CodeHistoryMessage` decodes them
unmodified). `subagent_event` decodes like the main `event` frame's payload
(`CodeStreamEvent`'s `{name, content?, delta?, args?, output?, partialResult?,
toolName?, toolCallId?, message?}` field set, minus `sessionId`, plus the
frame's own `subagentId`) — the child emits the same pi event types, so the
field names are identical.

### Swift client

- Models (`CodeModels.swift`): `CodeSubagentInfo`,
  `CodeSubagentSnapshot` (history reuses `CodeHistoryMessage`; buffer reuses
  `CodeContentBlock`); `CodeSubagentSettled`; `CodeClientMessage` gains
  `.getSubagents`, `.attachSubagent(id: String?, toolCallId: String?)`,
  `.detachSubagent(id: String)`; `CodeEvent` gains `.subagents([CodeSubagentInfo])`,
  `.subagentSnapshot(CodeSubagentSnapshot)`, `.subagentEvent(subagentId: String, name: String, payload: [String: AnyCodableValue])`
  (decode like `CodeStreamEvent`, minus `sessionId`),
  `.subagentSettled(subagentId: String, status: String, stopReason: String?)`.
- `CodeViewModel`:
  - `session.liveSubagents: [CodeSubagentInfo]` (from `subagents` frames —
    always replace, the frame is authoritative incl. empty). Refreshed on
    connect (the server sends it in the snapshot burst) and via
    `get_subagents` when the session view appears OR when `handleHistory`
    rebuilds items that include a `subagent` tool step not already in
    `liveSubagents` (cheap: one frame per such history receipt).
  - Attach state: `attachedSubagent: (snapshot + merged items + running)?` —
    its OWN item array (NOT the main transcript). On `subagentSnapshot`:
    items = `mapHistoryToItems(history.messages)` then the Feature A buffer
    merge over `buffer`. Live `subagent_event` frames (matching
    `subagentId`) drive the SAME stream-event reducer the main transcript uses:
    m3 — name the real functions (all in
    `CodeViewModel+Messages.swift`, today taking `&session: inout
    SessionState`): the extract is a RE-SIGN of `appendToolStep`,
    `updateToolOutput`, `markToolStepComplete`, `updateLastAssistantContent`,
    `finalizeStreamingBubbles` to take the item array (and any pure args) so
    the attach path can call them over its own items; `handleStreamEvent`
    (`+Messages.swift:89`) keeps the session-level side effects
    (`isStreaming`, `pendingPromptEchoes`, `refreshState`, prompt-echo dedupe)
    at the main call site. SPLIT `agent_settled` handling explicitly:
    item-finalize (shared — the attach view finalizes its bubbles too) vs
    `isStreaming`/`refreshState` (main only).
    `message_start` user-role events append plain user items in the attach
    view (no echo/pending dedupe).
  - `subagent_settled` → mark finished (view stays open, banner), drop the
    run from `liveSubagents` (do NOT trust a local remove: the server also
    re-broadcasts `subagents`; the client replace handles it — belt and
    braces, both are frame-driven). The capability gate (M4) also covers the
    VM: `liveSubagents` stays empty and the new request-senders are never
    called when `hello_ok` lacked the `subagents` feature.
  - Tap routing: `CodeTranscriptItemView`'s toolStep rendering gains an
    `onOpenSubagent: (String) -> Void = { _ in }` callback (threaded from
    `CodeSessionView`'s transcript into `CodeTranscriptItemView` →
    `toolStepView` → `CodeToolStepView`). A step is tappable-for-attach ONLY
    when `toolName == "subagent"` AND its `toolCallId` is in
    `liveSubagents` (by `toolCallId`) AND `isComplete == false`. Tappable
    steps get an affordance (e.g. the chevron row shows a "live" glyph /
    accent) and a tap invokes `onOpenSubagent(toolCallId)`; non-tappable
    subagent steps keep the existing expand behavior unchanged.
    `CodeToolStepView` gains an optional `onOpenLive: (() -> Void)?` — when
    nil the view is byte-for-byte the current one.
- Views:
  - New `CodeSubagentAttachView`: full-screen overlay (iOS) / sheet (macOS),
    presented from `CodeSessionView` over the transcript (a
    `@State var liveSubagentOpen: CodeSubagentInfo?` or attach-by-id state;
    the VM holds the data, the view is display + close only).
    Header: agent name, short id (first 8 chars, like the extension's
    `LIST_ID_SHORT_CHARS`), elapsed (client-side from `startedAt` — spec'd
    tick: `TimelineView(.periodic(from: .now, by: 1))` or
    `Text(.relative)`; do NOT hand-roll a timer), status
    (running = pulsing indicator reusing Feature C's pulse / settled =
    "Finished (<status>)" banner). Body: transcript rendered with the existing
    `CodeTranscriptItemView` (read-only: `onRetry` no-op, no
    `onOpenSubagent` — nested subagents are out of scope v1).
    Close button (X). Stays open on settle with the finished banner. Live
    auto-scroll reusing the `ScrollTriggerModifier` pattern (the modifier is
    in `Shared/Core/Views/ScrollTriggerModifier.swift`).
  - Transient state: attaching (no snapshot yet) → simple progress state.
- Session switch: on rebind (`handleStateInfo` isRebind) or `get_history`
  for a different session, the VM DETACHES any attached subagent (send
  `detach_subagent` if connected; clear local attach state) — a subagent run
  belongs to one session's transcript.
- Reconnect during attach (m4): on `hello_ok`, if local attach state is open:
  if the refreshed `subagents` frame still lists the run → re-send
  `attach_subagent` (attach state is per-connection, so the socket close
  dropped the server-side attach; the always-warm per-run buffer means the
  fresh snapshot carries the live tail). If the run is gone from
  `subagents` → apply the settle locally (finished banner) — a settle
  broadcast lost to the disconnect is replaced by the gone-from-list signal;
  the exact status is lost (banner says "finished"), accepted for v1.
- Concurrent attach (m5): tapping another live step replaces the current
  attach locally (view swap; the new `attach_subagent` implicitly detaches the
  old one server-side). Two phones attaching to the same run simultaneously is
  fine — attach state and event forwarding are per-client; no serialization
  anywhere.

### Tests

- UNIT ONLY (owner, 2026-09-13 — see Feature A test note). The originally
  sketched fixture-driven WS harness group is DROPPED (it is a harness run;
  not required while the API is rate-limited).
- Swift VM unit (`openclient-llm-test/Features/Code/`): scripted
  `subagents`/`subagent_snapshot`/`subagent_event`/`subagent_settled` frames
  → liveSubagents set/replaced (incl. empty = clear), attach items build
  (history + buffer merge), event routing only hits the attached run, settle
  behavior (banner state, liveSubagents cleared), step-tappability predicate
  (toolName + toolCallId in liveSubagents + !isComplete) — pin BOTH directions:
  tappable when live+incomplete, AND NOT tappable when the step `isComplete ==
  true` even if a live run with the same `toolCallId` exists (round-2
  addition; the plan listed the predicate conjunctively without pinning the
  inverse).
- TS unit (`pi-extensions/rc/__tests__/`, vitest): directory-scan/resolve pure
  functions against a temp dir (fixture `.meta`/`.pid`/`.jsonl` files written
  by the test — no pi process, no LLM): live filtering, parentSessionId
  scoping, torn-meta skip, toolCallId/prefix/exact resolution, ambiguity,
  settle-frame derivation.
- Manual smoke (phone, owner): real subagent run → step tappable → attach →
  live tool output streams → run finishes → banner, view stays → close → step
  no longer tappable.

---

## Feature C — stop UX (pulsing dot, no input-bar Stop)

- `CodeInputBarView`: DELETE `stopButton` + the `isStreaming`-conditional
  stop-button layout; `onStop` removed from the view's API; `CodeSessionView`
  stops passing it. THE FOUR PREVIEW FIXTURES (m6, `CodeInputBarView.swift`
  ~L125–153) pass `onStop: {}` — T7 updates them (they break until it does).
  STEER IS PRESERVED: while streaming the bar keeps the
  "Steer pi..." placeholder and send = `sendSteer` (unchanged routing in
  `CodeSessionView.handleSend`). "Send-only in all states" = no STOP button
  (the send/steer button remains the only button).
- `CodeSessionView` toolbar `statusDot` (currently an 8pt non-interactive
  circle, orange = reconnecting / green = connected):
  - idle/connected: green dot (unchanged).
  - reconnecting: unchanged.
  - streaming (`session.isStreaming`): dot PULSES (repeating scale/opacity
    animation, accent color; respect `reduceMotion` → static accent dot, no
    pulse). No text label (owner decision).
  - tap while streaming → `viewModel.send(.abort)` + haptic (`.impact` / the
    app's existing haptic utility). Tap while not streaming = no-op (dot keeps
    its connected/reconnecting meaning; no new behavior).
  - The 8pt dot is not a viable touch target: wrap it so the tap area is the
    full hit region (`.contentShape` / `frame(minWidth: 44, minHeight: 44)`
    around the dot). NOTE (m6, round-3 corrected — verified in code):
    `statusDot` is hosted in a NATIVE `ToolbarItem(placement: .navigation)`
    (`CodeSessionView.swift` ~L87–93; `CodeSessionView+Panels.swift` only
    defines the computed property). T7 wraps the dot at the ToolbarItem site
    and MUST verify in a build that the 44pt hit area actually works in the
    nav bar; fallback if the nav bar limits hit-testing or distorts the
    layout: relocate the dot out of the toolbar into a custom row.
  - Accessibility: `accessibilityLabel` "Stop" while streaming,
    `accessibilityHint` "Double tap to stop the run"; keep the existing
    Connected/Reconnecting labels otherwise.
- `handleAbort` already does the optimistic local finalize — no VM change
  beyond the view wiring + haptic.
- Tests: no tests (view-layer only; the pulse is a plain SwiftUI animation).

---

## Implementation plan (small sequential subagent deliverables; tests run ONLY at the end by the main agent)

Order matters: A's client merge is B's snapshot-merge foundation; the rc wire
additions (A prune + B frames) share one server diff area.

1. **T1 (TS, this repo)** — rc Feature A prune: `turnBuffer.ts` (tail probe +
   prune, per the Fix section) + wiring into `streamingBuffer()` (the single
   choke point of both snapshot emitters) + vitest unit tests
   (`rc/__tests__/turnBuffer.test.ts`, in-memory fixtures, no LLM).
2. **T2 (Swift, this repo)** — Feature A client merge: `handleStreamingBuffer`
   (CodeViewModel.swift:516) merge semantics — route buffer blocks through the
   EXISTING groupers (`mapAssistantContent` + `updateToolStepCompletion`,
   `CodeViewModel+Messages.swift`), no second grouping path (m3) + VM unit
   tests in `CodeViewModelTests+Streaming.swift` (incl. the mixed-block case
   from the test matrix).
3. **T3 (TS, other repo)** — subagent ext: `toolCallId` on `SubagentMeta` +
   spawn write. (Standalone, tiny; its own commit in `tectiv3/pi-extensions`.
   NO resolver changes — prefix resolution already exists on every TUI
   surface; say so in the commit message. Backwards compatibility NOT
   required per owner — document the field addition in the commit message +
   one line in the extension's README/AGENTS if it has one.)
4. **T4 (TS, this repo)** — rc Feature B: pure logic in a NEW small module
   `pi-extensions/rc/subagents.ts` (dir scan, live filter, id resolution,
   settle derivation — unit-testable against a temp dir without index.ts) +
   index.ts wiring: `subagents` scan/broadcast, `attach_subagent`/
   `detach_subagent`/`subagent_snapshot`/`subagent_event`/`subagent_settled`,
   bus subscription + per-run in-flight tail (reuses T1 prune),
   `subagent_not_found` error code, vitest unit tests
   (`rc/__tests__/subagents.test.ts`, temp-dir fixtures, no pi process).
5. **T5 (Swift, this repo)** — Feature B client: models/frames, VM attach
   state + the stream-reducer re-sign per m3 (named helpers, `agent_settled`
   split), liveSubagents, session-switch detach, reconnect re-attach (m4),
   capability gate (M4), unit tests.
6. **T6 (Swift, this repo)** — Feature B UI: `CodeSubagentAttachView` +
   tappable step (`onOpenLive` threading) + previews.
7. **T7 (Swift, this repo)** — Feature C: input-bar Stop removal (steer
   preserved) + pulsing dot + haptic + hit area + previews.

Verification (main agent, after all runs): `xcodebuild build` iOS (+ the
affected `-only-testing` classes), `pnpm test` in `pi-extensions` (this repo),
`pnpm test`/lint in `../pi-extensions` per its own setup. Commit as each task
verifies (imperative messages; this repo + the other repo each get their own
commits). No git push.

## Open items / accepted

- Phone attach is READ-ONLY v1; a live subagent cannot be stopped from the
  phone (TUI `/subagents abort` remains the path).
- `toolCallId` in `.meta` is written from now on; runs spawned before the
  subagent-ext update have no toolCallId → their steps are not tappable
  (graceful; documented).
- rc's `subagents` dir scan is read-only (probe only; the extension's own
  listing is what unlinks stale pidfiles). Torn `.meta` JSON is skipped.
- A child killed without `agent_settled` (stall watchdog, OOM) emits no settle
  on the bus; its attach view would then stay "running" until the user closes
  it or re-attaches (the next `subagents` frame / snapshot refresh corrects
  the main transcript's tappability). Accepted for v1.
- Feature C discoverability: a pulsing dot as the only abort affordance is a
  deliberate owner choice (clean header); haptic + pulse are the feedback loop.
- Partial ids (decision #8): rc resolution is scoped to this session's live
  runs (exact cross-session ids are NOT accepted by rc — attach is
  live-only, and live runs of other sessions are invisible to rc by the
  same scoping rule as the `/subagents` listing).

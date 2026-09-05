# Plan: Remote control of pi (Code tab)

Status: revised (round 3) — pending implementation.
Date: 2026-09-05 (round 3 revision; original 2026-07-09)

## Goal

Control a live pi coding-agent TUI session from the openclient-llm app (iOS + macOS)
over the Tailscale network: watch the session live, send prompts, steer, abort, and
answer the agent's `question`/`questionnaire` prompts from the phone.

## Decisions (from grill + critic revision)

| # | Decision | Chosen |
|---|----------|--------|
| 1 | Architecture | In-process pi extension with embedded WS server (not a separate RPC bridge daemon) |
| 2 | Capability scope | View live + prompt + steer + abort + answer agent questions from phone |
| 3 | Multi-session | Fixed port (47800). On-demand enable. If port is taken (another pi session already serving), this instance cannot start its server |
| 4 | Auth | Tailnet-only bind + 6-hex pairing code generated fresh on each `/rc` toggle-on, printed in TUI, entered in app. Code is ephemeral (in-memory only, not persisted). Rate-limit failed `hello`: 5 per IP → 60 s lockout. App stores host/port in `CodeSettings` (SettingsManager) for convenience; code is entered each session |
| 5 | App scope | New "Code" tab in the existing tab bar (iOS TabView + macOS sidebar), shared feature code, both platforms |
| 6 | Persistence | No local transcript persistence — pi session file is the source of truth; history re-fetched on (re)connect |
| 7 | Server lifetime | Process-level: survives `/new`, `/resume`, `/fork`; dies when pi exits. `session_shutdown`/`session_start` re-point event forwarding only |
| 8 | Question timeout | None. Pending question survives phone disconnect and is re-delivered on reconnect. `/rc` off or pi exit cancels pending questions |
| 9 | Multiple clients | Allowed. Broadcast to all; first answer to a pending question wins, others get `question_resolved` |
| 10 | Code location | Extension + forked question/questionnaire extensions stored in this repo (`pi-extensions/rc/`, `pi-extensions/question/`, `pi-extensions/questionnaire/`), symlinked into `~/.pi/agent/extensions/`. Commit after each completed task |
| 11 | Images | Deferred to v2. No evidence of image support in pi's extension API (`sendUserMessage` itself is unverified) |

## Critical unknowns (must verify before Task 1)

These are load-bearing API assumptions the spec makes but that could not be confirmed
from the existing extension source or documentation:

1. **Programmatic message submission**: The spec assumes a `pi.sendUserMessage(text)`
   or equivalent API exists. Existing extensions use `ctx.ui.setEditorText()` to put
   text in the editor, not to submit messages programmatically. **Verify**: check pi's
   `ExtensionAPI` type definition (from `@earendil-works/pi-coding-agent`) for
   `sendUserMessage`, `submitMessage`, or similar. If it does not exist, the
   alternative is `ctx.ui.setEditorText(text)` + a simulated Enter, or a different
   API surface. This changes the entire prompt/steer/abort protocol.

2. **`deliverAs` option for steer/followUp**: Referenced but not seen in any extension.
   If it doesn't exist, steer semantics must use a different mechanism or be
   dropped from v1.

3. **Mid-stream steer injection**: No existing extension demonstrates injecting a
   message while the agent is streaming. Even if `sendUserMessage` exists, it may
   reject calls during an active turn. The probe must attempt sending while
   streaming to confirm behavior.

4. **Programmatic abort**: No existing extension demonstrates cancelling the current
   turn programmatically. Check for `ctx.abort()`, `pi.abort()`, or equivalent.
   Without this, the Stop button is non-functional.

5. **Event names**: The spec lists specific event names (`message_start`,
   `message_update`, etc.). Existing extensions use `pi.on("session_start", ...)`
   and `pi.on("session_tree", ...)`. Verify the full set of subscribable events.

6. **History API**: The spec references `sessionManager.buildContextEntries()`.
   Existing extensions use `sessionManager.getBranch()` which returns `SessionEntry[]`
   (with `type: "message" | "compaction"`, `message: AgentMessage`, etc.). The
   history mapping must be built on the actual API, not the assumed one.

7. **WebSocket server dependency**: The spec says "stdlib only" with `node:ws`, but
   `ws` is NOT a Node.js built-in. Either pi bundles it, or the server must use raw
   `node:http` upgrade handling (significantly more complex). Check if `ws` or
   another WS library is available in the pi extension runtime.

**Action**: Build a minimal probe extension (`pi-extensions/rc-probe/`) that imports
the `ExtensionAPI` type, logs all available methods/properties on `pi` and `ctx`,
subscribes to all discoverable events, and attempts: (a) `sendUserMessage` or
equivalent, (b) mid-stream message injection (steer), (c) programmatic turn abort,
(d) `require("ws")` / `import("ws")`. Run it, capture the output, then delete the
probe and update this spec with findings before proceeding to Task 1.

## Part A — pi extension `rc`

Location: `pi-extensions/rc/` in this repo; symlink `~/.pi/agent/extensions/rc` → repo dir.

### A1. Components

- `pi-extensions/rc/index.ts` — extension factory:
  - `pi.registerCommand("rc")` — **toggle** (no arguments):
    - If server is off → start it:
      - Get Tailscale IPv4 (`tailscale ip -4` — take first line, trim whitespace),
        bind `node:http` + WS upgrade on `ws://<ip>:47800` (plain WebSocket, no TLS).
      - Generate fresh 6-hex code (random, in-memory only — not persisted).
      - Print in TUI: `ctx.ui.notify` + footer status
        (`rc: ws://mac.ts.net:47800 code A1B2C3`).
      - If port already in use (EADDRINUSE) → notify "port 47800 busy — another pi
        session is serving; toggle /rc there first".
    - If server is on → stop it:
      - Close server, clear status, cancel pending questions (resolve with
        "cancelled"), notify "rc stopped".
  - Message handlers (on authenticated client messages):
    - `prompt`: call pi's message submission API (discovered by probe) when not
      streaming. Return `not_idle` error if streaming.
    - `steer`: call pi's steer/mid-turn injection API when streaming. If not
      streaming, treat as `prompt`.
    - `abort`: call pi's turn-abort API. No-op if not streaming.
    - Exact API calls depend on probe findings (Critical unknowns 1-4).
  - Event forwarding (registered in factory, active only while server is on):
    Subscribe via `pi.on(eventName, handler)` for all available agent lifecycle
    events. Known working events: `session_start`, `session_tree`. Full event list
    to be confirmed by probe (see Critical unknowns). Broadcast as
    `{type:"event", name, ...payload}`.
  - Session rebind: `session_start` re-points forwarding at the new session (snapshot
    + history re-send to all connected clients, since `ctx.sessionManager` changes
    identity on switch); `session_shutdown` (final/quit) closes the server.

### A2. Process-level server (critical constraint)

jiti loads extensions with `moduleCache: false`; module-level singletons are NOT
reliable across session rebinds or `/reload`. Therefore:

- The WS server + client set + pending-question registry live on `globalThis`
  keyed by `Symbol.for("pi-rc")` (global symbol registry — shared across modules
  loaded by jiti, collision-proof). Access:
  `globalThis[Symbol.for("pi-rc")]`. Created lazily by `/rc` toggle-on.
- The `pi` factory re-runs on every session start/rebind; it re-attaches event
  forwarding to the process-level server and re-registers `/rc`.
- Captured old `ctx`/`pi` objects are stale after session replacement — all
  session-bound work goes through the *current* binding stored on the singleton,
  updated at `session_start`.

**Lifecycle state machine:**

```
                  ┌─────────────┐
     pi starts ──→│  STOPPED    │←──── /rc (when ON)
                  └──────┬──────┘      or pi exit
                         │ /rc
                         ▼
                  ┌─────────────┐
                  │  RUNNING    │←──── session_start (rebind:
                  │  port=47800 │      re-attach events,
                  │  code=A1B2C3│      re-send state+history)
                  └──────┬──────┘
                         │ /reload or session rebind
                         ▼
                  ┌─────────────┐
                  │  RUNNING    │  Factory re-runs:
                  │  (same svr) │  - detect globalThis[Symbol.for("pi-rc")]
                  │             │  - re-register /rc command
                  └─────────────┘  - re-attach event handlers
                                   - update ctx binding
                                   Server stays up, clients stay connected.
                                   NO user action required.
```

Key invariant: after factory re-run, the singleton's `ctx` binding is updated to
the new context. Old `ctx` references are never used for session-bound work.

### A3. WS protocol (JSON messages)

**Protocol version**: `1`. Client sends version in `hello`; server responds with its
version in `hello_ok`. If versions are incompatible, server sends
`error {code:"version_mismatch"}` + close.

Client → server:

| type | fields | effect |
|------|--------|--------|
| `hello` | `code`, `version` | Validate 6-hex code. Rate-limit: 5 failures per IP in 60 s → `error {code:"rate_limited"}` + close. OK → `hello_ok` + `state` + `history` (+ pending `question`). Bad → `error {code:"bad_code"}` + close |
| `prompt` | `text` | Submit user message when idle. Error `not_idle` if streaming |
| `steer` | `text` | Submit message during streaming (steer equivalent). If not streaming, treated as `prompt` (no error) |
| `abort` | — | Current turn abort (Esc equivalent). No-op if not streaming |
| `answer` | `id`, `value`, `wasCustom`, `index?` | Resolve pending `question` (first wins). `value`: selected label or custom text. `wasCustom`: true if typed. `index`: 1-based option index (omit if custom) |
| `answer_questionnaire` | `id`, `answers` | Resolve pending `questionnaire`. `answers` is `[{id, value, label, wasCustom, index?}]` — one entry per sub-question, matching the questionnaire's Answer shape |
| `get_state` | — | Refresh `state` |
| `get_history` | `cursor?` | Request a page of history (200 entries). Without cursor: latest 200. With cursor from a previous `history` response: the 200 entries before that cutoff |
| `ping` | — | Client keepalive; server responds with `pong` |

Server → client:

| type | payload |
|------|---------|
| `hello_ok` | `{version: 1}` |
| `state` | `{sessionId, cwd, sessionName, model: {provider, id}, thinkingLevel, isStreaming, contextUsage?}` |
| `history` | `{sessionId, messages: [...], cursor?}` — see History format below |
| `event` | `{sessionId, name, ...}` forwarded pi events. Client MUST ignore events whose `sessionId` doesn't match the last received `state.sessionId` (guards against stale events during session rebind) |
| `streaming_buffer` | `{sessionId, content: ContentBlock[]}` — accumulated content of the in-progress assistant turn. Sent after `state`+`history` on reconnect when `isStreaming` is true. Omitted when not streaming |
| `question` | `{sessionId, id, kind: "question", params: {question, options}}` |
| `questionnaire` | `{sessionId, id, kind: "questionnaire", params: {questions}}` |
| `question_resolved` | `{id, by: "client"|"cancelled", value?}` — `value` included when `by:"client"` so other clients can display what was answered |
| `pong` | — |
| `error` | `{code, message?}` |

Error codes: `bad_code`, `rate_limited`, `version_mismatch`, `invalid_message`,
`not_idle` (prompt sent while streaming), `unknown_question` (answer for
non-pending question).

**`contextUsage` shape** (when available):
`{used: number, total: number}` — token counts. UI renders as percentage bar.
May be null immediately after compaction.

### A4. History format

Built from `ctx.sessionManager.getBranch()` which returns `SessionEntry[]`:
- `{type: "message", message: AgentMessage}` — user, assistant, toolCall, toolResult
- `{type: "compaction", summary: string, ...}` — compacted region

Mapping to the `history.messages` array:

```typescript
type ContentBlock =
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "toolUse"; toolCallId: string; toolName: string; args: Record<string, unknown> };

type HistoryMessage =
  | { role: "user"; text: string }
  | { role: "assistant"; content: ContentBlock[] }
  | { role: "toolResult"; toolName: string; toolCallId: string; output: string; isError?: boolean }
  | { role: "compaction"; summary: string };
```

**Pagination**: Always send the last 200 entries. If there are more, include
`cursor` pointing to the cutoff; the client can request older pages via
`get_history {cursor}` (each page is 200 entries). In practice, sessions rarely
exceed 200 entries before compaction.

**Streaming buffer**: The server maintains a `currentTurnBuffer: ContentBlock[]`
that accumulates content from the in-progress assistant turn:
- `message_start` → reset buffer, begin accumulating
- `message_update` → append text/thinking blocks
- `tool_execution_start` → append toolUse block
- `tool_execution_update` → update the last toolUse's output
- `turn_end` → reset buffer (turn complete, content is now in `getBranch()`)

The buffer represents a single assistant message in progress. Multi-message turns
(message → tool → message) reset on each new `message_start`. On client
(re)connect while `isStreaming` is true, send a `streaming_buffer` message after
`state`+`history` so the client can render the in-progress turn immediately.

### A5. Remote-aware questions

The `question` and `questionnaire` extensions are forked into this repo:
- `pi-extensions/question/index.ts` — copy of `~/.pi/agent/extensions/question/index.ts`
- `pi-extensions/questionnaire/index.ts` — copy of `~/.pi/agent/extensions/questionnaire/index.ts`

Symlinked: `~/.pi/agent/extensions/question` → `<repo>/pi-extensions/question/`,
`~/.pi/agent/extensions/questionnaire` → `<repo>/pi-extensions/questionnaire/`.

**Modification — remote-first with TUI fallback:**

When rc is running with connected clients, route the question to remote clients
first. The TUI shows a non-blocking status ("Question sent to remote client(s).
Press Esc to answer locally."). If Esc is pressed, the remote ask is cancelled and
the normal TUI prompt appears. If no clients are connected when the question fires,
skip straight to the TUI prompt.

Add import: `import { uuidv7 } from "@earendil-works/pi-ai";`

At the top of `execute()`, before the `ctx.mode !== "tui"` check:

```typescript
const RC_KEY = Symbol.for("pi-rc");
const rc = globalThis[RC_KEY];
if (rc?.hasConnectedClients()) {
  // Route to remote — TUI shows wait status with Esc escape hatch
  const result = await rc.ask({
    id: uuidv7(),
    kind: "question",
    params,
    // signal allows TUI Esc to cancel the remote wait
    signal: ctx.mode === "tui" ? await showRemoteWaitUI(ctx) : undefined,
  });
  if (result !== null) {
    // Remote client answered — build return matching tool's expected shape
    const simpleOptions = params.options.map((o) => o.label);
    const text = result.wasCustom
      ? `User wrote: ${result.value}`
      : `User selected: ${result.index}. ${result.value}`;
    return {
      content: [{ type: "text", text }],
      details: {
        question: params.question,
        options: simpleOptions,
        answer: result.value,
        wasCustom: result.wasCustom,
      },
    };
  }
  // null = cancelled (Esc), all clients disconnected, or /rc toggled off
  // → fall through to normal TUI prompt below
}
```

For `questionnaire`, the pattern is identical but `result.answers` is
`[{id, value, label, wasCustom, index?}]` and the return shape matches
`QuestionnaireResult`.

`showRemoteWaitUI(ctx)` displays a non-blocking `ctx.ui.custom()` status panel
("Waiting for remote answer... Esc to answer locally") and returns an `AbortSignal`
that fires when Esc is pressed. Implementation detail for Task 2.

The `ask` function is exposed by the rc singleton on `globalThis[Symbol.for("pi-rc")]`:
- Checks `hasConnectedClients()` before awaiting (caller checks too, but
  defensive)
- Broadcasts `question`/`questionnaire` to all connected clients
- Returns a `Promise<Answer | null>` — resolves with the answer (first client wins)
  or `null` (signal aborted / all clients disconnected / `/rc` toggled off / pi exit)
- Pending asks are stored in the singleton's registry; re-delivered to
  new/reconnecting clients
- **Answer shape** for `question`: `{value: string, wasCustom: boolean, index?: number}`
- **Answer shape** for `questionnaire`: `{answers: [{id, value, label, wasCustom, index?}]}`

No event bus needed — the question extensions access the rc singleton directly via
`globalThis[Symbol.for("pi-rc")]`.

### A6. Heartbeat

Client sends `ping` every 30 seconds. Server responds with `pong`. If the server
receives no messages from a client for 90 seconds, it closes that connection
(stale detection). If the client receives no `pong` within 10 seconds of a `ping`,
it considers the connection dead and initiates reconnect.

### A7. Rate limiting

Per-IP tracking of failed `hello` attempts:
- Map of `IP → {failures: number, lockedUntil: Date | null}`
- On failed `hello`: increment failures. If failures >= 5, set `lockedUntil` to
  now + 60 seconds. Send `error {code:"rate_limited"}` + close.
- On successful `hello`: reset that IP's counter.
- Entries expire after 5 minutes of inactivity (cleanup on connection).

## Part B — Swift app "Code" feature

Feature folder: `openclient-llm/Shared/Features/Code/` (ViewModels/Views/Models,
mirroring existing feature layout). Tests in `openclient-llm-test/Features/Code/`.

### B1. Data layer

- `CodeServerClient` (protocol `CodeServerClientProtocol`): wraps
  `URLSessionWebSocketTask` against `ws://<host>:<port>`; sends JSON commands; emits
  an `AsyncStream<CodeEvent>` (Codable envelope of the A3 protocol). Reconnect with
  exponential backoff (1s, 2s, 4s, 8s, max 30s); on (re)connect always re-`hello` +
  receive `state`+`history`. **Auth-error handling**: on `bad_code` or
  `rate_limited` errors during reconnect, abandon auto-reconnect immediately and
  emit a `.authFailed` event (the code has changed — server was toggled). The VM
  transitions to the connect screen so the user can enter the new code. Auto-reconnect
  only fires on transport errors (TCP close, timeout, pong timeout), never on
  authentication failures.
- **Ping/pong**: Client sends application-level JSON `{"type":"ping"}` every 30s
  via a background `Task` (NOT `URLSessionWebSocketTask.sendPing()` which uses
  WS-protocol-level frames — the server handles JSON messages only). Tracks last
  `pong` received; if no `pong` within 10s, considers connection dead → reconnect.
- **Receive loop**: `URLSessionWebSocketTask.receive()` is pull-based. Wrap in an
  `AsyncStream` via a dedicated `Task` that loops `receive()` and yields parsed
  `CodeEvent` values. Handle cancellation and errors to trigger reconnect.
- **Streaming buffer**: On reconnect, if `state.isStreaming` is true, expect a
  `streaming_buffer` message after `state`+`history`. Render accumulated content
  immediately so the in-progress turn is visible.
- `CodeSessionState` (value type): messages, streaming deltas, tool steps
  (start/running with partial output/end), pending question, `isStreaming`, model,
  contextUsage, `sessionId` (for ignoring stale events during rebind).
- Message mapping: user → bubble; assistant text blocks → markdown bubbles
  (streaming); thinking → collapsed block; toolCall+toolResult → collapsible tool
  step (icon + tool name + one-line arg summary; expand shows args + output). Mirrors
  the app's existing agent-loop tool-step UI language (see
  `specs/agent-tool-calling.instructions.md` UI section) but data is live WS events,
  not the LiteLLM loop.
- **Storage**: `CodeSettings` in `SettingsManager`: add `getCodeHost()`/
  `setCodeHost(_:)` and `getCodePort()`/`setCodePort(_:)` to
  `SettingsManagerProtocol` following the existing getter/setter pattern. Code is
  NOT persisted — entered fresh each session (ephemeral on both sides).
- **Background behavior** (iOS): Use the existing `BackgroundTaskManager` (via a
  new `CodeBackgroundUseCase`) to keep the WS connection alive during the allowed
  background window (~30s). If a `question`/`questionnaire` arrives while
  backgrounded, fire a local notification via `LocalNotificationManager` — add a
  new `sendQuestionNotification()` method to `LocalNotificationManagerProtocol`
  ("pi is asking a question — tap to answer"). If the background task expires,
  disconnect gracefully. On foreground, reconnect and receive pending questions.
  This matches the existing `StreamingBackgroundUseCase` +
  `NotifyStreamingCompletedUseCase` pattern.
- **Background behavior** (macOS): No special handling needed. macOS apps do not
  suspend; the WS connection stays alive indefinitely. No local notifications
  required (the app window is accessible).

### B2. ViewModel

`CodeViewModel` — Event/State shape per project conventions (`@Observable`,
`@MainActor`, `send(_:)`):

- States: `.disconnected(ConnectForm)`, `.connecting`, `.connected(SessionView)`,
  `.reconnecting(SessionView)` (preserves transcript, shows inline banner),
  `.failed(error)`. Transitions: transport error while connected → `.reconnecting`;
  auth error (`bad_code`/`rate_limited`) while reconnecting → `.disconnected`
  (prompt for new code); reconnect success → `.connected`.
- Events: `connect(host:port:code:)`, `disconnect()`, `sendPrompt(text)`,
  `sendSteer(text)`, `abort()`, `answer(id, answer)`,
  `answerQuestionnaire(id, answers)`, `refreshState()`.
- Input bar semantics: idle → Send = `prompt`; streaming → Send = `steer`,
  Stop button = `abort`.
- Pending question → question card (options + "Type something..." for `question`;
  list of tabbed questions for `questionnaire`).

**File length**: Split via extensions to stay under SwiftLint's 500-line limit:
- `CodeViewModel.swift` — state, events, connection lifecycle
- `CodeViewModel+Messages.swift` — history/event → view model item mapping
- `CodeViewModel+Questions.swift` — question/questionnaire handling

### B3. Views

- `CodeView` (root): switches on state. Connect screen = host/port/code fields +
  Connect button; code field 6 chars, hex, uppercase. Host/port pre-filled from
  `CodeSettings` if previously connected; code always entered fresh (ephemeral).
- `CodeSessionView`: header (project path from `cwd`, model name, streaming
  indicator, context usage as percentage bar), transcript list, input bar, Stop
  button.
- Tool step rows collapsible; bash steps show streaming output while running
  (default collapsed after start, expand to follow).
- `#Preview` in every view file; localized strings via `String(localized:)`; follow
  `chat-visual-style`/`design-ui` specs for look.

### B4. Tab wiring

`HomeView` changes (4 insertion points):
1. `AppTab` enum: add `.code` case
2. `TabView` body: add `Tab` block for `.code` with
   `systemImage: "chevron.left.forwardslash.chevron.right"`
3. `SidebarDestination` enum: add `.code` case
4. `detailContent`: add `case .code:` → `CodeView()`

No deep-link/shortcut changes in v1.

### B5. Testing (Swift)

Per `testing.instructions.md` / AGENTS.md conventions:

- `CodeViewModelTests`: connect/disconnect transitions, prompt vs steer routing by
  streaming state, abort, question answer, questionnaire answer, history rendering
  into view model items, reconnect re-hello, streaming buffer rendering on reconnect,
  stale sessionId event filtering.
- `CodeServerClientTests`: message framing, bad-code error mapping, re-delivered
  question handling, ping/pong, streaming_buffer handling — with a
  `MockWebSocketTransport` (protocol boundary) that replays canned server messages.
- `CodeMessageMapperTests`: `SessionEntry`-shaped JSON → view model items. Covers:
  user text, assistant text/thinking/toolUse, toolResult, compaction summary,
  malformed entries.
- `CodeNotificationTests`: verify local notification fires when question arrives
  while app is backgrounded (mock `LocalNotificationManager`).
- All test classes `@MainActor`; `@testable import openclient_llm`.
- `MockCodeServerClient` conforming to `CodeServerClientProtocol` for ViewModel tests.

## Part C — Testing plan

### C1. Extension probe (before Task 1)

Build `pi-extensions/rc-probe/index.ts`:
- Log all enumerable properties/methods of `pi` (the `ExtensionAPI` object)
- Log all enumerable properties/methods of `ctx` (the `ExtensionContext` object)
- Register a command `/probe` that:
  - Lists all properties of `ctx.sessionManager`
  - Attempts `pi.sendUserMessage?.("test")` and logs result/error
  - Attempts `pi.abort?.()` / `ctx.abort?.()` and logs result/error
  - Checks if `require("ws")` or `import("ws")` resolves
  - Subscribes to every plausible event name and logs which ones fire:
    `message_start`, `message_update`, `message_end`, `tool_execution_start`,
    `tool_execution_update`, `tool_execution_end`, `turn_start`, `turn_end`,
    `agent_start`, `agent_end`, `agent_settled`, `queue_update`,
    `compaction_start`, `compaction_end`, `model_select`,
    `thinking_level_select`, `session_start`, `session_info_changed`,
    `session_shutdown`, `session_tree`
- Register a command `/probe-steer` that sends a message while the agent is
  mid-stream (to test steer/mid-turn injection)
- Symlink into `~/.pi/agent/extensions/probe` → repo dir
- Run pi, execute `/probe`, trigger a prompt, run `/probe-steer` mid-stream,
  capture output
- Delete probe extension and symlink after capturing findings
- **Update this spec** with verified API surface before starting Task 1

### C2. Extension test script (`pi-extensions/rc/test-client.mjs`)

Automated Node.js script with assertions and exit codes (not manual "check" steps):

```
Test suite:
  1. Connection
     - Connect with valid code → hello_ok + state + history
     - Connect with invalid code → error {code:"bad_code"} + close
     - 5 rapid bad codes from same IP → error {code:"rate_limited"} + close
     - Wait 60s → can connect again (or: mock time in test)
     - Connect with wrong version → error {code:"version_mismatch"} + close

  2. State & history
     - get_state → valid state shape with cwd, model, isStreaming
     - history messages array is non-empty after at least one exchange
     - History pagination: if > 200 entries, cursor is present

  3. Prompt & steer
     - Send prompt when idle → agent starts processing (verify via event stream)
     - Send prompt when streaming → error {code:"not_idle"}
     - Send steer when streaming → accepted (verify steer delivery via events)

  4. Abort
     - Start a long-running prompt, send abort → turn ends (turn_end event)

  5. Questions
     - Trigger a question (via test project AGENTS.md) → question message received
     - Send answer → question_resolved received
     - Disconnect without answering → reconnect → question re-delivered
     - Two clients connected → first answer wins → second gets question_resolved

  6. Heartbeat
     - Send ping → receive pong
     - Do not send anything for >90s → server closes connection

  7. Multi-client
     - Two clients connected → both receive events
     - Prompt from client A → both see events

  8. Server lifecycle
     - /rc → server starts, status shown
     - /rc again → server stops, clients disconnected
     - Port busy: start second pi, /rc → error message about port 47800

  9. Session rebind
     - /new in pi → clients get session_start event + fresh state + history
     - Events from old session (pre-rebind) are tagged with old sessionId

  10. Streaming buffer
      - Connect while agent is mid-stream → receive streaming_buffer with content
      - streaming_buffer content matches what has been streamed so far
```

Each test: connect → action → assert → disconnect. Script exits 0 on all pass,
non-zero on any failure, with a summary of pass/fail counts.

### C3. Swift unit tests

Run order:
1. `CodeMessageMapperTests` — pure mapping, no async
2. `CodeServerClientTests` — framing and protocol with mock transport
3. `CodeViewModelTests` — full state machine with `MockCodeServerClient`
4. Full iOS test suite (regression)
5. Build both schemes (iOS + macOS)

### C4. End-to-end testing (manual, Task 4)

Real phone ↔ Mac on tailnet:
1. `/rc` in pi → note address + code
2. Enter in app → connect → see session state + history
3. Send prompt → watch streaming response
4. Send steer mid-stream → verify injection
5. Send abort mid-stream → verify stop
6. Trigger question → answer from phone → verify resolution
7. Trigger questionnaire → answer all sub-questions → verify
8. Kill app → reopen → reconnect → verify state restored
9. `/rc` in pi → verify clients disconnected
10. `/rc` again → verify clients can reconnect
11. Two devices: connect both, answer question from one, verify other gets resolved
12. Background app → trigger question from pi → verify local notification fires
13. Tap notification → app foregrounds → reconnect → see pending question → answer
14. Background app → wait 2 min → foreground → verify reconnect
15. Reconnect mid-stream → verify streaming_buffer delivers in-progress content

## Part D — Workflow

1. **Task 0 — API probe**: Build and run `rc-probe` extension per C1. Update spec
   with verified API surface. Delete probe. No commit (spec update only).

2. **Task 1 — extension core**: `pi-extensions/rc/` (server, `/rc` toggle, protocol,
   event forwarding, history/state, rate limiting, heartbeat), symlink. Run test
   script (C2, tests 1-4, 6-8). Commit.

3. **Task 2 — forked question extensions + remote-aware ask**: Copy
   `~/.pi/agent/extensions/{question,questionnaire}/index.ts` into
   `pi-extensions/{question,questionnaire}/`, add `globalThis[Symbol.for("pi-rc")]`
   remote-ask integration per A5, update symlinks. Run test script (C2, test 5).
   Commit.

4. **Task 3 — Swift Code feature**: data layer + ViewModel + Views + tab wiring +
   tests. Compile + run Code feature tests (C3) + both platform builds. Commit.

5. **Task 4 — end-to-end**: Manual testing per C4. Fix issues, commit.

Branch from `develop` (per AGENTS.md git workflow). Compile and commit after each
completed task (linter and formatter run on commit hook); never push to remote.

## Open items / risks

- **`sendUserMessage` / steer / abort APIs** (CRITICAL): If the probe reveals no
  such APIs, the prompt/steer/abort protocol must be redesigned around
  `ctx.ui.setEditorText()` + simulated submit, or a different mechanism. This is
  the single largest implementation risk. All three must be tested in the probe.
- `contextUsage` availability: may be null right after compaction — treat as
  optional in UI.
- Tailscale IPv4 lookup: `tailscale ip -4` must be on PATH in the pi process env;
  may return multiple IPs — take first line, trim. Fail with a clear message if
  not available (safety decision, no fallback to `0.0.0.0`).
- 6-hex code = 24 bits: acceptable as a tailnet pairing code with rate-limiting.
  Generated fresh per `/rc` toggle-on (ephemeral). Document that tailnet membership
  is the real boundary.
- **Background notifications** (v1 limitation): Local notifications via
  `LocalNotificationManager` during the background task window (~30s). If the app
  is suspended longer, the user won't be alerted until they reopen the app (pending
  question is re-delivered on reconnect). APNs-based push notifications are future
  work requiring server infrastructure.
- **SwiftLint file length**: `CodeViewModel` must be split via extensions (see B2).
- **WS server dependency**: If `ws` is not available in pi's runtime, raw
  `node:http` upgrade handling adds significant complexity to Task 1. The probe
  (Task 0) will determine this.
- **`executionMode: "sequential"`**: The question/questionnaire tools block all
  other tool execution while awaiting an answer. With remote-first routing, this
  means pi is blocked until a remote client answers or the TUI user presses Esc.
  Acceptable for v1 (matches existing TUI behavior where the user must answer
  before pi proceeds).

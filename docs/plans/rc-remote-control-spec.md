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
| 4 | Auth | Tailnet-only bind + 6-digit decimal pairing code generated fresh on each `/rc` toggle-on, printed in TUI, entered in app. Code is ephemeral (in-memory only, not persisted). Rate-limit failed `hello`: 5 per IP → 60 s lockout. App stores host/port in `CodeSettings` (SettingsManager) for convenience; code is entered each session |
| 5 | App scope | New "Code" tab in the existing tab bar (iOS TabView + macOS sidebar), shared feature code, both platforms |
| 6 | Persistence | No local transcript persistence — pi session file is the source of truth; history re-fetched on (re)connect |
| 7 | Server lifetime | Process-level: survives `/new`, `/resume`, `/fork`; dies when pi exits. `session_shutdown`/`session_start` re-point event forwarding only |
| 8 | Question timeout | None. Pending question survives phone disconnect and is re-delivered on reconnect. `/rc` off or pi exit cancels pending questions |
| 9 | Multiple clients | Allowed. Broadcast to all; first answer to a pending question wins, others get `question_resolved` |
| 10 | Code location | Extension + forked question/questionnaire extensions stored in this repo (`pi-extensions/rc/`, `pi-extensions/question/`, `pi-extensions/questionnaire/`), symlinked into `~/.pi/agent/extensions/`. Commit after each completed task |
| 11 | Images | Deferred to v2. No evidence of image support in pi's extension API (`sendUserMessage` itself is unverified) |

## Verified API surface (Task 0 probe, 2026-09-05)

Verified by driving a real pi v0.85.0 TUI in a pty with a throwaway probe
extension (`pi-extensions/rc-probe/`, since deleted). Session files written to
`~/.pi/agent/sessions/` were read back as ground-truth entry shapes. All
statements below are empirical, not from docs.

### Working model flag

`pi --provider openai --model gpt-5` works for the probe.
(`google/gemini-2.5-flash` returns 404 for new users.) The rc server reads the model
from `ctx.model`, so this flag only affects what the probe session itself used.

### `pi` (`ExtensionAPI`) surface — 25 keys

`on, registerTool, registerCommand, registerShortcut, registerFlag,
registerMessageRenderer, registerMarkdownTransformer, registerEntryRenderer,
getFlag, sendMessage, sendUserMessage, appendEntry, setSessionName, getSessionName,
setLabel, exec, getActiveTools, getAllTools, setActiveTools, getCommands, setModel,
getThinkingLevel, setThinkingLevel, registerProvider, unregisterProvider, events`

### `ctx` (`ExtensionCommandContext`) surface — 25 keys

`ui, mode, hasUI, cwd, sessionManager, modelRegistry, model, scopedModels,
thinkingLevel, isIdle, isProjectTrusted, signal, abort, hasPendingMessages,
shutdown, getContextUsage, compact, getSystemPrompt, getSystemPromptOptions,
waitForIdle, newSession, fork, navigateTree, switchSession, reload`

### `sendUserMessage` (resolves unknowns #1, #2, #3)

- **Idle**: `pi.sendUserMessage("...")` → resolves (no throw), starts a new turn.
- **Mid-stream, no `deliverAs`**: **throws**
  `Error: Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.`
- **Mid-stream, `{deliverAs:"steer"}`**: resolves (no throw). The message is **queued
  and delivered at the next turn boundary as a new user turn**; the `input` event for
  it carries `source:"extension"` and `streamingBehavior:"steer"`. The TUI renders it
  as `Steering: <text>`. Steer does **not** interrupt the in-flight generation — it
  appends a follow-up turn (verified: a streaming "1..12" run finished 1..12, then the
  steer became the next user turn).
- `ctx.isIdle()` correctly reports `false` while a turn (incl. tool exec) is active,
  `true` otherwise.
- **Implication**: steer is "insert a queued instruction", **not** "cut off". To stop
  mid-stream use `ctx.abort()` (below). Never call `sendUserMessage` with no
  `deliverAs` while `!ctx.isIdle()` — it throws.

### `ctx.abort()` (resolves unknown #4)

Returns `undefined` (void), does not throw. Aborts the current turn: `message_end` /
`turn_end` fire with the assistant message carrying `stopReason:"aborted"`,
`errorMessage:"Operation aborted"`, `content:""`. Then `agent_end` + `agent_settled`
fire and the agent is idle. This is the Stop-button mechanism.

### Events (resolves unknown #5)

`pi.on(eventName, handler)` accepted **all 35** documented event names (no throw on
subscribe), including the session-*/model_select/thinking_level_select/queue_update
family. The following **fired** in a clean TUI run (with payload key sets):

| event | payload keys | notes |
|---|---|---|
| `session_start` | `type, reason` | `reason:"startup"` |
| `resources_discover` | `type, cwd, reason` | fires at boot |
| `input` | `type, text, images, source, streamingBehavior?` | `source` = `interactive` \| `extension`; steer adds `streamingBehavior:"steer"` |
| `before_agent_start` | `type, prompt, images, systemPrompt, systemPromptOptions` | |
| `agent_start` | `type` | once per agent run |
| `turn_start` | `type, turnIndex, timestamp` | per LLM turn |
| `context` | `type, messages` | per turn |
| `before_provider_headers` | `type, headers` | |
| `before_provider_request` | `type, payload` | |
| `after_provider_response` | `type, status, headers` | |
| `message_start` | `type, message` | message role starts |
| `message_update` | `type, message, assistantMessageEvent` | per token delta; `assistantMessageEvent` = `{type:"text_delta" \| "thinking_delta" \| "toolcall_delta", delta, contentIndex}` |
| `message_end` | `type, message` | message role ends |
| `tool_execution_start` | `type, toolCallId, toolName, args` | |
| `tool_call` | `type, toolName, toolCallId, input` | |
| `tool_execution_update` | `type, toolCallId, toolName, args, partialResult` | `partialResult:{content}` |
| `tool_result` | `type, toolName, toolCallId, input, content, details, isError, usage` | |
| `tool_execution_end` | `type, toolCallId, toolName, result, isError` | `result:{content}` |
| `turn_end` | `type, turnIndex, message, toolResults` | `message` = full assistant msg; `toolResults` = `toolResult` msgs |
| `agent_end` | `type, messages` | low-level run end |
| `agent_settled` | `type` | fully idle (no retries/queued) |
| `ui_prompt_start` / `ui_prompt_end` | `type, reason, kind` | |
| `session_shutdown` | `type, reason` | `reason:"quit"` on `/quit` |

**Did NOT fire** (subscribable, but no trigger in a plain interactive run — they fire
under other conditions): `session_info_changed`, `session_tree`,
`session_before_switch`, `session_before_fork`, `session_before_compact`,
`session_compact`, `session_compact_failed`, `project_trust`, `model_select`,
`thinking_level_select`, and **`queue_update`**.

> **Correction to the draft**: `queue_update` is an **RPC-mode** event (see
> `docs/rpc.md`, `json.md`) and **never fires as a TUI/extension event**. The rc
> extension must **not** rely on it. Use `agent_start` → streaming and
> `agent_settled` → idle for `isStreaming` inference (see B2), which both fire.

### History API (resolves unknown #6)

`ctx.sessionManager.getBranch()` returns `SessionEntry[]` **for the live branch**
(root → current leaf). Verified: it returns a **mix** of entry types, not just
messages — the probe branch contained `model_change`, `thinking_level_change` and
`message` entries. **The history mapper must filter to the relevant types**
(`message`, `compaction`, …) and **skip** `model_change` / `thinking_level_change`.
`sessionManager` keys include `sessionId, sessionFile, entryCount, filePath,
getBranch, getEntries, getContext, getLeafId, getLeafEntry, getSessionId,
getSessionName, getLabel, getHeader, getCompactionEntry` (full list logged by the probe).

> **Correction to the draft**: the protocol `sessionId` is `sessionManager.getSessionId()` —
> the **Session UUID, stable for the session lifetime**. `getLeafId()` is the
> **leaf-entry position** and advances as messages are appended; it is **NOT** a session id
> (using it as `sessionId` broke harness group 10 and would break Swift rebind detection).

`getContextUsage()` returns **`{tokens: number, contextWindow: number, percent: number}`**
(verified: `{"tokens":7,"contextWindow":400000,"percent":0.00175}`).

> **Correction to the draft**: the `contextUsage` shape is **not** `{used, total}` —
> it is `{tokens, contextWindow, percent}` (see A3).

### Session entry shapes (ground truth from on-disk JSONL)

`user`:
```json
{"role":"user","content":[{"type":"text","text":"Reply with exactly: PROBE-A"}],"timestamp":1788608590861}
```

`assistant` — `content` is an array that can contain any of these block types (in
order of appearance):
- `{"type":"thinking","thinking":string,"thinkingSignature":string}`
- `{"type":"text","text":string,"textSignature":string}`
- `{"type":"toolCall","id":string,"name":string,"arguments":object}`

Top-level keys: `role, content, api, provider, model,
usage{input,output,cacheRead,cacheWrite,reasoning,totalTokens,cost}, stopReason,
timestamp, responseId, rawStopReason`. Captured example (`stopReason:"toolUse"`):

```json
{"role":"assistant","content":[
  {"type":"thinking","thinking":"","thinkingSignature":"{...encrypted...}"},
  {"type":"toolCall","id":"call_7b3XsDu1SBT8fYcFTeqSSIF1|fc_082e...","name":"bash","arguments":{"command":"echo PROBE_TOOL_OK"}}],
 "api":"openai-responses","provider":"openai","model":"gpt-5",
 "usage":{"input":2784,"output":234,"cacheRead":0,"cacheWrite":0,"reasoning":192,"totalTokens":3018,"cost":{"input":0.00348,"output":0.00234,"cacheRead":0,"cacheWrite":0,"total":0.00582}},
 "stopReason":"toolUse","timestamp":1788608593001,"responseId":"resp_082e7070..."}
```

`toolResult`:
```json
{"role":"toolResult","toolCallId":"call_7b3XsDu1SBT8fYcFTeqSSIF1|fc_082e...","toolName":"bash","content":[{"type":"text","text":"PROBE_TOOL_OK\n"}],"isError":false,"timestamp":1788608604646}
```

`compaction` (real on-disk entry; 22 samples all use the `firstKeptEntryId` format —
the doc's newer `retainedTail` variant was **not** observed):
```json
{"type":"compaction","id":"03f8472c","parentId":"4103ddbb","timestamp":"2026-09-02T06:51:18.420Z",
 "summary":"No prior history.\n\n---\n\n**Turn Context (split turn):** ...",
 "firstKeptEntryId":"43b12667","tokensBefore":111767,
 "details":{"readFiles":["/abs/path/a.ts"],"modifiedFiles":["/abs/path/b.ts"]},
 "usage":{"input":49522,"output":2428,"cacheRead":0,"cacheWrite":0,"reasoning":813,"totalTokens":51950,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},
 "fromHook":false}
```

The `assistant` `thinking` block's `thinkingSignature` and the `text` block's
`textSignature` are **opaque encrypted strings** (base64-encoded JSON carrying an
`id` of the form `msg_...`). The rc extension must **copy them through verbatim**
(see A4); do not parse or re-derive them.

### WebSocket dependency (resolves unknown #7)

`require("ws")` → **fails** (`MODULE_NOT_FOUND`). `import("ws")` → **fails**
(`MODULE_NOT_FOUND`). The pi extension runtime does **not** bundle `ws`. The draft's
"stdlib only" assumption is **wrong**: `ws` is not a Node built-in and is
unavailable. Task 1 must either (a) use raw `node:http` + a minimal in-process
WebSocket frame codec (RFC 6455) with zero dependencies, or (b) vendor `ws`.
**Recommended**: (a) raw `node:http` upgrade + minimal codec, to honor the
stdlib-only constraint.

## Part A — pi extension `rc`

Location: `pi-extensions/rc/` in this repo; symlink `~/.pi/agent/extensions/rc` → repo dir.

### A1. Components

- `pi-extensions/rc/index.ts` — extension factory:
  - `pi.registerCommand("rc")` — **toggle** (no arguments):
    - If server is off → start it:
      - Get Tailscale IPv4 (`tailscale ip -4` — take first line, trim whitespace),
        bind `node:http` + WS upgrade on `ws://<ip>:47800` (plain WebSocket, no TLS).
      - Generate fresh 6-digit decimal code (random, in-memory only — not persisted). Digits only so it is trivial to enter on a phone keypad.
      - Print in TUI: `ctx.ui.notify` + footer status
        (`rc: ws://mac.ts.net:47800 code A1B2C3`).
      - If port already in use (EADDRINUSE) → notify "port 47800 busy — another pi
        session is serving; toggle /rc there first".
    - If server is on → stop it:
      - Close server, clear status, cancel pending questions (resolve with
        "cancelled"), notify "rc stopped".
  - Message handlers (on authenticated client messages):
    - `prompt`: call `pi.sendUserMessage(text)` (verified) when not streaming
      (`ctx.isIdle()` true). Return `not_idle` error if streaming.
    - `steer`: call `pi.sendUserMessage(text, {deliverAs:"steer"})` (verified)
      while streaming — queues a follow-up turn. If not streaming, treat as
      `prompt` (`sendUserMessage(text)` with no deliverAs).
    - `abort`: call `ctx.abort()` (verified). No-op if not streaming.
    - Verified API calls — see "Verified API surface".
  - Event forwarding (registered in factory, active only while server is on):
    Subscribe via `pi.on(eventName, handler)` for the verified lifecycle events
    (see "Verified API surface": `agent_start`, `turn_start`, `message_start`,
    `message_update`, `message_end`, `tool_execution_start`/`_update`/`_end`,
    `tool_call`, `tool_result`, `turn_end`, `agent_end`, `agent_settled`,
    `session_start`, `before_agent_start`, `input`). Broadcast as
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
| `hello` | `code`, `version` | Validate 6-digit code (exact match). Rate-limit: 5 failures per IP in 60 s → `error {code:"rate_limited"}` + close. OK → `hello_ok` + `state` + `history` (+ pending `question`). Bad → `error {code:"bad_code"}` + close |
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
| `question` | `{sessionId, id, kind: "question", params: {question: string, options: QuestionOption[]}}` — see shapes below |
| `questionnaire` | `{sessionId, id, kind: "questionnaire", params: {questions: SubQuestion[]}}` — see shapes below |
| `question_resolved` | `{id, by: "client"|"cancelled", value?}` — `value` included when `by:"client"` so other clients can display what was answered |
| `pong` | — |
| `error` | `{code, message?}` |

Error codes: `bad_code`, `rate_limited`, `version_mismatch`, `invalid_message`,
`not_idle` (prompt sent while streaming), `unknown_question` (answer for
non-pending question).

**Question/questionnaire param shapes** (from the extension source):

```typescript
type QuestionOption = { label: string; description?: string };

type SubQuestion = {
  id: string;
  label?: string;       // tab/page label, defaults to "Q1", "Q2", ...
  prompt: string;       // full question text
  options: QuestionOption[];
  allowOther?: boolean; // show "Type something..." option (default true)
};
```

**`contextUsage` shape** (verified, Task 0):
`{tokens: number, contextWindow: number, percent: number}` — e.g.
`{"tokens":7,"contextWindow":400000,"percent":0.00175}`. UI renders `percent`
as the bar. (The draft's `{used, total}` was wrong.) May be null immediately after
compaction. When null, context bar is hidden.

### A4. History format

Built from `ctx.sessionManager.getBranch()` which returns `SessionEntry[]`
**for the live branch** (root → current leaf). Verified in the probe: it is a
**mix** of entry types — besides `message` and `compaction` it contains
`model_change` and `thinking_level_change` entries. **Filter to** `message` /
`compaction` (other content-bearing types) and **skip** `model_change` /
`thinking_level_change`:
- `{type: "message", message: AgentMessage}` — user, assistant, toolCall, toolResult
- `{type: "compaction", summary, firstKeptEntryId, tokensBefore, details, ...}` — compacted region

Mapping to the `history.messages` array:

```typescript
type ContentBlock =
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "toolUse"; toolCallId: string; toolName: string; args: Record<string, unknown>; output?: string };

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
- `message_update` → append using `event.assistantMessageEvent` =
  `{type:"text_delta"|"thinking_delta"|"toolcall_delta", delta, contentIndex}`;
  append `delta` to the text/thinking block at `contentIndex`
- `tool_execution_start` → append toolUse block
- `tool_execution_update` → update the last toolUse's `output` field from
  `event.partialResult.content` (streaming tool output, e.g. bash stdout)
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

> **Correction to the draft (Task 2, implemented):** the implementation deviates
> from the sketch above in three ways. (1) The question `id` is generated
> server-side in `rc.ask()` (`crypto.randomBytes(4).toString("hex")`); the
> caller does not pass one (`uuidv7` is not imported). (2) There is no
> `showRemoteWaitUI` / Esc escape hatch: while a remote ask is pending, the TUI
> shows the in-flight tool call; a local answer cannot preempt it (v1 limitation,
> acceptable per the `executionMode: "sequential"` note below). (3) `ask()`
> resolves `null` (tool reports "cancelled") when the server stops or `/rc`
> toggles off; if no clients are connected at ask time, the extension falls
> through to the normal TUI path.

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

> **Correction to the draft (Task 1b-2):** the rate-limit state lives in the
> singleton and survives `/rc` stop/start cycles within one pi process; a lockout
> is only cleared by time (60 s), a successful hello, or process exit. The test
> harness therefore runs its rate-limit tests last (group 11) so a lockout cannot
> poison earlier tests in the same run.

## Part B — Swift app "Code" feature

Feature folder: `openclient-llm/Shared/Features/Code/` (ViewModels/Views/Models,
mirroring existing feature layout). Tests in `openclient-llm-test/Features/Code/`.

### B1. Data layer

- `CodeServerClient` (protocol `CodeServerClientProtocol`): wraps
  `URLSessionWebSocketTask` against `ws://<host>:<port>`; sends JSON commands; emits
  an `AsyncStream<CodeEvent>` (Codable envelope of the A3 protocol). Reconnect with
  exponential backoff (1s, 2s, 4s, 8s, max 30s, **max 10 attempts** — after which
  emit `.connectionFailed` and stop retrying; VM transitions to `.failed`). On
  (re)connect always re-`hello` + receive `state`+`history`. **Auth-error handling**:
  on `bad_code` or `rate_limited` errors during reconnect, abandon auto-reconnect
  immediately and emit a `.authFailed` event (the code has changed — server was
  toggled). The VM transitions to the connect screen so the user can enter the new
  code. Auto-reconnect only fires on transport errors (TCP close, timeout, pong
  timeout), never on authentication failures. **Connection timeout**: initial
  connect attempt has a 10s timeout; if the server is unreachable, emit
  `.connectionFailed` (VM transitions to `.failed` with a Retry button).
- **Task lifecycle**: `URLSessionWebSocketTask` is NOT reusable after close/cancel.
  Each reconnect attempt must create a NEW task via `urlSession.webSocketTask(with:)`.
  Cancelling the receive loop requires calling `task.cancel(with:reason:)` on the
  underlying task to unblock the blocking `receive()` call.
- **Ping/pong**: Client sends application-level JSON `{"type":"ping"}` every 30s
  via a background `Task` (NOT `URLSessionWebSocketTask.sendPing()` which uses
  WS-protocol-level frames — the server handles JSON messages only). Tracks last
  `pong` received; if no `pong` within 10s, considers connection dead → reconnect.
- **Receive loop**: `URLSessionWebSocketTask.receive()` is pull-based. Wrap in an
  `AsyncStream` via a dedicated `Task` that loops `receive()` and yields parsed
  `CodeEvent` values. Handle cancellation and errors to trigger reconnect.
- **Event coalescing**: Batch incoming `message_update` events on a 50–100ms timer
  before pushing to the `AsyncStream` / applying to `@Observable` state. Prevents
  per-character state mutations from causing `LazyVStack` frame drops during
  streaming. The timer fires on the last event in the batch window.
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
  background window (best-effort, typically 5–30s depending on system pressure —
  NOT a guaranteed duration). If a `question`/`questionnaire` arrives while
  backgrounded, fire a local notification via `LocalNotificationManager` — add a
  new `sendQuestionNotification()` method to `LocalNotificationManagerProtocol`
  ("pi is asking a question — tap to answer"). If the background task expires,
  disconnect gracefully. On foreground, reconnect and receive pending questions
  (question survives disconnect per Decision 8, so the notification path is
  opportunistic — the question is always re-delivered on reconnect regardless).
  This matches the existing `StreamingBackgroundUseCase` +
  `NotifyStreamingCompletedUseCase` pattern.
- **Background behavior** (macOS): No special handling needed. macOS apps do not
  suspend; the WS connection stays alive indefinitely. No local notifications
  required (the app window is accessible).

### B2. ViewModel

`CodeViewModel` — Event/State shape per project conventions (`@Observable`,
`@MainActor`, `send(_:)`):

- States: `.disconnected(ConnectForm)`, `.connecting`, `.connected(SessionView)`,
  `.reconnecting(SessionView)` (preserves transcript, shows top amber banner),
  `.failed(error)`. `ConnectForm` tracks whether host/port are saved (code-only
  mode) or need initial setup (full form mode). Transitions: transport error while
  connected → `.reconnecting`; auth error (`bad_code`/`rate_limited`) while
  reconnecting → `.disconnected` (prompt for new code); reconnect success →
  `.connected`; 10 consecutive transport reconnect failures → `.failed`;
  connection timeout (10s) → `.failed`.
- Events: `connect(host:port:code:)`, `cancelConnect()`, `disconnect()`,
  `sendPrompt(text)`, `sendSteer(text)`, `abort()`, `answer(id, answer)`,
  `answerQuestionnaire(id, answers)`, `refreshState()`.
- Input bar semantics: idle → Send = `prompt`; streaming → Send = `steer`,
  Stop button = `abort`.
- Pending question → modal overlay (see B3 question modal details). X button on
  modal sends `abort` to pi, cancelling the agent's current turn.
- **`isStreaming` inference**: Client infers streaming state from events since
  `state` is only pushed on connect/reconnect. Verified event names (Task 0):
  `agent_start` → set `isStreaming = true`. `agent_settled` → set
  `isStreaming = false`. These toggle the input bar mode and Stop button
  visibility. Do **not** use `message_start`/`turn_end` (they fire per LLM turn and
  would flicker during multi-turn tool runs) and do **not** rely on
  `queue_update` (RPC-only; never fires in TUI mode). The server computes
  `state.isStreaming` from `ctx.isIdle()` (verified working).
- **Session rebind**: When a `state` message arrives with a different `sessionId`
  than the current one (pi executed `/new`, `/resume`, `/fork`):
  1. Clear transcript, rebuild from the accompanying `history` message
  2. Dismiss any active question modal (the question belongs to the old session)
  3. Reset `isStreaming` from the new `state.isStreaming`
  4. If `isStreaming` is true, render `streaming_buffer` content
  5. No state transition — stays in `.connected` (brief loading indicator optional)
- **`question_resolved` handling**: When received, if a question modal is showing
  for that `id`, auto-dismiss it. If `by: "cancelled"`, no transcript trace. If
  `by: "client"`, show a resolved card in transcript with the answer value.

**File length**: Split via extensions to stay under SwiftLint's 500-line limit:
- `CodeViewModel.swift` — state, events, connection lifecycle
- `CodeViewModel+Messages.swift` — history/event → view model item mapping
- `CodeViewModel+Questions.swift` — question/questionnaire handling

### B3. Views

General: `#Preview` in every view file; localized strings via `String(localized:)`;
follow `chat-visual-style`/`design-ui` specs for look; all views theme-aware
(light/dark).

#### B3.1 `CodeView` (root)

Switches on `CodeViewModel.state`:
- `.disconnected` → connect screen
- `.connecting` → connect screen with spinner, disabled fields, Cancel button
- `.connected` → `CodeSessionView`
- `.reconnecting` → `CodeSessionView` with reconnect overlay
- `.failed` → error state (message + Retry button + Back to form link)

#### B3.2 Connect screen

**Adaptive layout** — first time (no saved host/port) vs repeat:

- **First time**: Centered branded card — terminal icon (SF Symbol
  `chevron.left.forwardslash.chevron.right`) in a `.glassEffect(.regular, in:
  .circle)`, title "Connect to pi", three fields: host (text, placeholder
  `mac.ts.net`), port (numeric, default `47800`), code (6 digits, monospace,
  uppercase, auto-advance). Connect button below. On successful connect, host/port
  saved to `CodeSettings`.
- **Repeat** (host/port already saved): Shows only the code field (large, centered,
  monospace) + Connect button. Small "Change host" link below that expands to reveal
  host/port fields inline. Pre-filled from saved values.
- **Validation**: code must be exactly 6 hex characters; Connect button disabled
  until valid. Host non-empty. Port 1–65535.
- **Error display**: Wrong code → inline error below code field ("Invalid code —
  check the code shown in pi"). Rate-limited → "Too many attempts — wait 60s" with
  countdown. Connection refused → "Cannot reach host — check Tailscale connection".
- **Focus**: auto-focus code field (on repeat) or host field (on first time).

#### B3.3 `CodeSessionView`

- **Header**: Navigation toolbar (`.principal` placement). Shows:
  - Truncated `cwd` path (last 2 components, e.g. `~/code/myproject`)
  - Model name pill
  - Connection status dot (green = connected, amber = reconnecting)
  - Context usage percentage bar (below toolbar, same pattern as
    `ChatContextUsageView`)

- **Transcript**: `LazyVStack` with message items, same scroll behavior as Chat
  (`ScrollTriggerModifier`). Auto-scroll on new events; user scroll up disables
  auto-scroll + shows floating "jump to bottom" button. **Note**: the rendering
  below uses the verified event payload shapes (see "Verified API surface",
  Task 0). Message types:
  - **User messages**: right-aligned glass bubbles (accent-tinted), same as Chat
  - **Assistant text**: left-aligned with sparkles icon, streaming markdown with
    blinking cursor, same as Chat's `MessageBubbleView` pattern
  - **Thinking/reasoning**: collapsible disclosure (same `ReasoningDisclosureState`
    pattern as Chat — collapsed by default, expand to see reasoning text)
  - **Tool steps**: collapsible inline rows within assistant message area. Each row:
    tool icon (SF Symbol per tool type) + tool name + one-line arg summary (e.g.
    "Read src/main.ts", "Bash npm test"). Default collapsed after completion;
    expand shows args + output. Bash steps show streaming monospace output while
    running (live-updating, capped to last 20 lines collapsed; expanded state
    capped to 200 lines with "Show more" pagination to prevent scroll performance
    issues). Matches the collapsible pattern from `agent-tool-calling.instructions.md`.
  - **Resolved question cards**: compact inline card showing question (truncated, 1
    line) + selected answer with checkmark. Glass background, left-aligned. Shows
    "(wrote)" prefix for custom answers. Appears in transcript after a question is
    answered via the modal.
  - **Compaction summary**: subtle separator with "Context compacted" label,
    collapsed summary text.

- **Empty state** (connected but no history): centered glass card — terminal icon
  in glass circle, "Connected to pi" title, cwd path, model name. Subtitle:
  "Send a message or use pi directly — activity will appear here."

- **Reconnecting overlay**: amber glass banner pinned to top of session view (below
  toolbar). Spinner + "Reconnecting..." text. Transcript visible and scrollable
  underneath. Input bar disabled. Disappears on successful reconnect with brief
  success animation.

#### B3.4 `CodeInputBarView`

New simplified input bar (NOT reusing `ChatInputBarView` — different semantics, no
attachments/recording/web search):

- **Structure**: text field + send button + stop button (when streaming). No image
  picker, document picker, camera picker, recording, or web search indicator.
- **Idle mode**: placeholder "Message pi...", standard glass capsule bar style
  (matching `chat-visual-style` input bar pattern), send button (arrow.up icon).
- **Streaming/steer mode**: placeholder "Steer pi...", bar uses accent-tinted glass
  (`.glassEffect(.regular.tint(Color.appAccent))`) to signal steer mode — stays
  within the existing design system, no new color needed. Send icon changes. Stop
  button (square.fill) appears adjacent to input field.
- **Disabled states**: during `.connecting` and `.reconnecting`, bar is disabled
  (greyed out, not interactive).
- **macOS**: same bar, keyboard shortcut Enter to send, Shift+Enter for newline
  (same as Chat).

#### B3.5 Question modal overlay

**iOS**: Presented as a centered modal card over the session view (dimmed
background, dismissable via X button or swipe-down).
**macOS**: Presented as a `.sheet()` attached to the window (native macOS
convention). Same content layout, different presentation.

- **Single question (`question`)**: card shows question text at top, options as
  tappable rows (each row: option label, optional description below in muted text),
  "Type something..." row at bottom when `allowOther` is true (tapping opens inline
  text field within the card). X button at top-right to dismiss — **sends `abort`
  to pi, cancelling the agent's current turn** (same as pressing Stop). After
  tapping an option → card dismisses, resolved card appears in transcript, answer
  sent to pi.

- **Questionnaire (multi-question)**: swipeable horizontal pages with page dots at
  bottom (UIPageControl / TabView with .page style). Each page is one question with
  its options. Last page has Submit button (enabled when all questions answered).
  Page header shows "1 of N" with navigation arrows. Same option row style as
  single question. X button dismisses entire questionnaire (sends `abort`). For
  questionnaires with 7+ questions, hide page dots and rely on "1 of N" header
  with arrows as sole navigation.

- **Custom text input**: when "Type something..." is tapped, the option row expands
  to show a text field inline. Submit with Enter / Done button. Esc/tap outside to
  collapse back to option list.

- **Glass styling**: card uses `.glassEffect(.regular)` with rounded corners
  (`.rect(cornerRadius: 20)`). Options use subtle dividers between rows.

- **Notification-triggered**: if question arrived via local notification (app was
  backgrounded), tapping the notification foregrounds the app and the modal
  auto-presents.

- **Disconnect during modal**: if the WebSocket drops while the question modal is
  showing, the modal stays visible (the reconnecting banner appears underneath).
  If the user answers while disconnected, the answer is queued and submitted after
  reconnect. If `question_resolved` arrives during reconnect (another client
  answered, or server cancelled), the modal auto-dismisses.

- **`question_resolved` while modal is showing**: auto-dismiss the modal. If
  `by: "client"`, briefly show a toast: "Answered from another device." If
  `by: "cancelled"`, briefly show "Question cancelled."

- **Accessibility**: modal has `.accessibilityAddTraits(.isModal)` for VoiceOver
  focus trapping. Each option row has an accessibility label. "Type something..."
  row has `.accessibilityHint("Double tap to enter a custom answer")`. Connection
  status dot has `.accessibilityLabel("Connected"/"Reconnecting")`. Context usage
  bar has `.accessibilityLabel("Context: N% used")`. Steer mode change announced
  via `.accessibilityValue`. Reconnect animation respects
  `@Environment(\.accessibilityReduceMotion)`.

### B4. Tab wiring

`HomeView` changes (4 insertion points):
1. `AppTab` enum: add `.code` case (order: Chats, **Code**, Models, Settings)
2. `TabView` body: add `Tab` block for `.code` with
   `systemImage: "chevron.left.forwardslash.chevron.right"`, positioned after
   Chats tab
3. `SidebarDestination` enum: add `.code` case (same position — after Chats,
   before Models)
4. `detailContent`: add `case .code:` → `CodeView()`

No deep-link/shortcut changes in v1.

**History pagination**: v1 does not implement scroll-to-top history loading.
Sessions rarely exceed 200 entries before compaction. `get_history` with `cursor`
is available in the protocol for future use but no UI trigger is wired in v1.

### B5. Shared component extraction

Before building the Code feature, extract these from `Chat/` to
`Shared/Common/Views/`:

- `ReasoningDisclosureState` → `Shared/Common/Views/ReasoningDisclosureState.swift`
- `ChatContextUsageView` → `Shared/Common/Views/ContextUsageView.swift` (rename)
- Create `MarkdownBubbleView` — generic markdown bubble (extracted from
  `MessageBubbleView`'s assistant rendering: markdown + streaming cursor + blinking
  animation). Both Chat and Code import this.
- `ScrollTriggerModifier` → refactor to accept a protocol for scroll-follow
  behavior (decouple from `ChatViewModel.LoadedState`), move to
  `Shared/Common/Views/ScrollTriggerModifier.swift`

`MessageBubbleView` stays in Chat (tightly coupled to `ChatMessage`). Code builds
its own `CodeMessageView` using `MarkdownBubbleView` + `ReasoningDisclosureState`.

### B6. Testing (Swift)

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

### C1. Extension probe (before Task 1) — DONE

Completed 2026-09-05: probe extension was built, run against a live pi v0.85.0
session, and deleted. Findings with evidence are in "Verified API surface
(Task 0 probe, 2026-09-05)" above. Original instructions, for the record:

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

Automated Node.js script with assertions and exit codes (not manual "check" steps).

**Harness design (verified 2026-09-05 against pi v0.85.0 RPC mode):**

- pi is spawned in **RPC mode** (`pi --mode rpc --provider openrouter --model
  qwen/qwen3.8-27b --approve`), cwd = `pi-extensions/rc/test-project/` (temp
  copy or in-place; AGENTS.md there forces the `question`/`questionnaire`
  tools for test 5).
  Extension discovery uses the real symlinks (no `-e` flag) so the shipped
  configuration is what gets tested.
- JSONL over stdin/stdout: commands are `{"id":..., "type":...}` lines; events
  stream on stdout as JSON lines. Readiness = response to an initial
  `get_session_stats` command. Extension commands dispatch via
  `{"type":"prompt","message":"/rc"}` (response `{success:true}` only — the
  handler return value is NOT surfaced).
- **Test seams** (env-gated, diagnostic-only, never active in production use):
  - `PI_RC_BIND` — bind address override. Default resolution: `tailscale` on
    PATH, then the CLI bundled in the macOS app
    (`/Applications/Tailscale.app/Contents/MacOS/Tailscale`), then fail with a
    clear message (never `0.0.0.0`). Harness uses `127.0.0.1`.
  - `PI_RC_AUTH_FILE` — path to a status file the extension rewrites on every
    state change: `{"status":"running","host","port","code","ts"}` or
    `{"status":"stopped","reason","detail","ts"}`. Written ONLY when this env
    is set — there is no default path, production never creates an rc status
    file. Harness reads it to obtain the pairing code and to observe
    toggle/port-busy outcomes (in TUI mode the same facts are shown via
    `ctx.ui.notify`).
  - `PI_RC_DEBUG` / `PI_RC_DEBUG_FILE` — append every lifecycle event and wire
    frame (recv/send, hello results, ask lifecycle, stale closes, start
    failures) to `~/.pi/agent/rc-debug.log` (or the `_FILE` path). Off by
    default; pure diagnostics, no behavior change.
- WS client = Node 24 built-in global `WebSocket` (no dependencies).
- LLM-dependent tests use `openrouter/qwen/qwen3.8-27b` (cheap, verified
  working 2026-09-05). Model round-trips are the slow part — allow 60 s
  timeouts per LLM-dependent assertion.

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
4. `CodeEndToEndTests` — see C3.1
5. Full iOS test suite (regression)
6. Build both schemes (iOS + macOS)

### C3.1. Swift end-to-end tests (automated, no app run)

`CodeEndToEndTests` (`openclient-llm-test/Features/Code/`) exercises the real
`CodeServerClient` (URLSession transport, no mocks) against a real pi process
running the real rc extension — the full cross-language stack, driven from
XCTest so no app has to be launched:

- Each test spawns `pi --mode rpc --approve --no-session` in a temp copy of
  `pi-extensions/rc/test-project`, toggles `/rc` over RPC, and reads the
  pairing code from the `PI_RC_AUTH_FILE` status file (the code is random per
  toggle, so it is read, not hardcoded). The test then connects with the real
  client and asserts on decoded `CodeEvent`s.
- The LLM is a local deterministic stand-in: simulator test processes have
  blocked egress and no API keys, so each test also runs `MockModelServer`, a
  minimal OpenAI-compatible chat-completions server on 127.0.0.1 whose canned
  replies are keyed on the test-project prompt markers (PONG-E2E, ASK,
  ASKFORM, LONG). pi is pointed at it with `--provider openai
  --model <mock> --base-url http://127.0.0.1:<port>`. The tests are therefore
  hermetic: no network, no API key, no flaky model output.
- pi binary resolution: `PI_RC_E2E_PI_BIN` env override → candidate paths
  (homebrew, nvm, `~/.npm/_npx/*/node_modules/.bin/pi`) → `zsh -lc` lookup →
  `XCTSkip` if not found (keeps the standard suite green where pi is absent).
- Scenarios: connect → `helloOk`/`state`/`history` (decoded shapes);
  prompt → `agent_start`…`agent_settled` events + history contains the prompt;
  `ASK` → decoded `question` (options carry `value`) → answer →
  `questionResolved(by: "client")`; `ASKFORM` → decoded `questionnaire` →
  `answerQuestionnaire` → resolved; prompt-while-streaming →
  `.notIdle` error → abort settles; ping/pong keep-alive.

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

4. **Task 3a — shared component extraction**: Extract `ReasoningDisclosureState`,
   `ChatContextUsageView` → `ContextUsageView`, create `MarkdownBubbleView`,
   refactor `ScrollTriggerModifier` to accept protocol — per B5. Update Chat
   imports. Verify Chat still builds and tests pass. Commit.

5. **Task 3b — Swift Code feature**: data layer + ViewModel + Views + tab wiring +
   tests. Compile + run Code feature tests (C3) + both platform builds. Commit.

6. **Task 4 — end-to-end**: Manual testing per C4. Fix issues, commit.

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
- 6-digit decimal code = 20 bits: acceptable as a tailnet pairing code with
  rate-limiting (5 attempts per IP per 60 s). Digits-only for easy phone entry.
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

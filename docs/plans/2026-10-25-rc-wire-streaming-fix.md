# rc: wire payload trimming + delta streaming + stable transcript

Status: implementing (2026-10-25).
Territory: `pi-extensions/rc/` (server), `openclient-llm/Shared/Features/Code` (client).

## Symptom

On long conversations the phone drops and reconnects ("Reconnecting…") on every
model turn — worse inside subagent runs — then replays the transcript and
scrolls to the bottom; sometimes it cycles a few times.

## Root cause (verified, not inferred)

1. `URLSessionWebSocketTask.maximumMessageSize` defaults to **1 MiB**
   (verified in this environment: `task.maximumMessageSize == 1048576`). A
   single inbound frame above it kills the socket: `receive()` fails with
   `NSPOSIXErrorDomain Code=40 "Message too long"` (reproduced with a 2 MiB
   frame against a local WS server). `CodeServerClient` maps that to
   `.connectionLost` → reconnect → snapshot replay.
2. rc forwards payloads that routinely exceed 1 MiB and that the phone never
   renders:
   - `tool_execution_end.result` / `turn_end.toolResults` /
     `message_start.message` for `toolResult` messages carry the raw tool
     result, including `details`. A `subagent` result holds the child's entire
     transcript in `details.results`: **17–51 MB per call** in the owner's real
     session files (`~/.pi/agent/sessions/--Users-fenrir-code--`).
   - `message_update` ships the cumulative `message` **and**
     `assistantMessageEvent.partial`, which is the same full message — the
     whole message twice per token delta (O(n²) per turn).
   - `tool_execution_update.partialResult` is the cumulative tool output,
     re-sent on every update.

So every turn that finishes a subagent or a big tool sends multi-MB frames →
socket dies → reconnect → transcript rebuild → scroll reset.

## Decisions

| # | Decision | Chosen |
|---|----------|--------|
| D1 | Wire compat | **Atomic.** Server sends the new shapes; app must be rebuilt/reinstalled with the new rc. No capability negotiation, no legacy branch. (Owner decision 2026-10-25; precedent: ask consolidation, pending steers.) |
| D2 | `message_update` | Forward `assistantMessageEvent` only, stripped of `partial` (mirrors pi's own `toJsonEvent` for json/rpc modes). No `message`, no `usage`. Tool-call deltas are forwarded (small; they mark content indices) but the client ignores them. |
| D3 | `turn_end` | Forward `{turnIndex, message}` where `message` is trimmed to `{role, stopReason, content}` with `content` limited to `text`/`thinking` blocks (authoritative final content for the delta-assembled bubble). The harness asserts `turnEnd.message.stopReason`, so `stopReason` must survive when present. |
| D4 | `message_start` | Forward `message: {role}` plus `content` **only** for the `user` role (the client extracts user text from it). Assistant/toolResult starts carry no content. |
| D5 | `tool_execution_update` | Forward `partialResult` as the flattened string the server already computes (`stringFromDeep`), capped to `TOOL_OUTPUT_PREVIEW_BYTES` (64 KiB, first bytes). The client's tool view paginates anyway; uncapped cumulative output is what made this frame quadratic. |
| D6 | `tool_execution_end` | Forward `{toolCallId, toolName, isError}` only. Drop `args` and `result`. |
| D7 | Server-side memory | Cap tool output stored in `currentTurnBuffer` / subagent run buffers to the same `TOOL_OUTPUT_PREVIEW_BYTES` (the buffer is what `streaming_buffer` snapshots replay). |
| D8 | Shared trimmer | One `trimForwardedPayload(name, payload)` helper used by both the main-event `forward()` path and the subagent bus frames, so the two can never drift. |
| D9 | Client transport | `maximumMessageSize` set explicitly (64 MiB) at task creation — defense in depth: one pathological frame must never kill the socket again. |
| D10 | Client liveness | **Any** received frame refreshes the pong clock, not only `pong`. A backed-up receive loop must not false-trip the 10 s pong deadline. |
| D11 | Client history identity | `mapHistoryToItems` assigns deterministic UUIDs derived from content (SHA-256 of sessionId + role + canonical payload + duplicate ordinal), so replaying the same history keeps view identity and scroll position across reconnects. Local echoes keep random ids (they are replaced by the replay anyway). |

## Wire shapes after this change

```jsonc
{ "type": "event", "name": "message_update",
  "assistantMessageEvent": { "type": "text_delta", "contentIndex": 0, "delta": "..." } }

{ "type": "event", "name": "turn_end", "turnIndex": 3,
  "message": { "role": "assistant", "stopReason": "stop",
               "content": [ { "type": "text", "text": "..." } ] } }

{ "type": "event", "name": "message_start", "message": { "role": "user", "content": [ { "type": "text", "text": "..." } ] } }

{ "type": "event", "name": "tool_execution_update",
  "toolCallId": "tc1", "toolName": "bash", "args": { ... }, "partialResult": "…(≤64 KiB)…" }

{ "type": "event", "name": "tool_execution_end",
  "toolCallId": "tc1", "toolName": "bash", "isError": false }
```

Text and thinking blocks occupy a contiguous prefix of `contentIndex` in every
pi assistant message (tool calls come last), so the client reducer appends by
`contentIndex` and ignores tool-call deltas; an out-of-range index appends
defensively. `text_end` / `thinking_end` carry the authoritative block text and
are applied once per block (O(n), not per delta).

## Verification

- `pi-extensions/rc/__tests__/wirePayloads.test.ts` — pure trimmer unit tests
  (subagent-sized `details`, cumulative partials, tool results, user vs
  assistant `message_start`, output cap).
- Node harness (`node pi-extensions/rc/test-client.mjs`) — groups 1–4, 6, 10,
  13, 15 still pass; `turn_end.message.stopReason` assertions keep working.
- iOS: `CodeViewModelTests+Streaming`, `CodeServerClientTests`,
  `CodeViewModelTests+BufferMerge` updated to delta frames; new tests for the
  liveness rule, `maximumMessageSize`, and history-id stability.

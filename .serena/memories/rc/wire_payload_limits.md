# rc wire: 1 MiB frame cap and payload trimming (2026-10-25)

## Root cause of the "reconnect on every turn" bug (verified)

- `URLSessionWebSocketTask.maximumMessageSize` defaults to **1 048 576 bytes**
  (verified locally with a Swift probe). Any inbound frame above it makes
  `receive()` fail with `NSPOSIXErrorDomain Code=40 "Message too long"`
  (reproduced with a 2 MiB frame). `CodeServerClient.handleConnectionLost`
  treats that as a dropped socket → `.reconnecting` banner → reconnect →
  snapshot replay → transcript rebuild → scroll to bottom.
- rc was forwarding multi-MB payloads the phone never renders. Measured in
  `~/.pi/agent/sessions/--Users-fenrir-code--`:
  - subagent tool result `details.results` = the child's whole transcript,
    **17–51 MB per call**; it rode `tool_execution_end.result`,
    `turn_end.toolResults`, and `message_start.message`.
  - raw pi `AssistantMessageEvent` carries `partial: AssistantMessage` on EVERY
    variant, and `message_update` also carried the cumulative `message` — the
    full message twice per delta (O(n²) per turn).
  - `tool_execution_update.partialResult` is the cumulative tool output,
    re-sent on every update.
- Session **file** size is irrelevant to the wire: `historyMap` drops
  `details`, so a 262 MB session file maps to ~0.5 MB of history.

## Fix (landed 2026-10-25)

Spec: `docs/plans/2026-10-25-rc-wire-streaming-fix.md`. Two halves, **atomic**
(old app + new server shows no streaming text; rebuild both together):

- Server (`pi-extensions/rc/wirePayloads.ts`, wired into `forward()` and the
  subagent bus path): `message_update` = `assistantMessageEvent` only (no
  `partial`, no `message`); `turn_end` = `{turnIndex, message:{role,
  stopReason, content:[text|thinking]}}`; `message_start` = role (+user text
  only); `tool_execution_update.partialResult` = flattened string capped at
  64 KiB; `tool_execution_end` = `{toolCallId, toolName, isError}`. Stored
  turn/subagent buffer output capped at the same 64 KiB.
- Client: `URLSessionCodeWebSocketTask` sets `maximumMessageSize = 64 MiB`;
  liveness = any received frame (not just pong); assistant text is assembled
  from deltas by `contentIndex` (`CodeViewModel+StreamDeltas.swift`), with
  `turn_end.message` as the authoritative repair.

## Not done

- D11 (deterministic history item ids so a reconnect replay keeps view
  identity/scroll) was deferred — a reconnect still replaces transcript items
  with new UUIDs and can jump.
- iOS unit tests for the delta reducer were updated but could not be executed
  from the agent process tree (`xcodebuild test` → "Pseudo Terminal Setup
  Error" / host abort). Build is clean; run the Code tests from Xcode.
- rc changes only take effect after restarting pi (extensions load at start).

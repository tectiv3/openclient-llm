# RC (remote control) feature — status

Working branch: `code-rc` (shared with a second agent; never push). Spec (source of truth, kept current): `docs/plans/rc-remote-control-spec.md`.

## Done (as of 2026-09-06)
- **rc extension** `pi-extensions/rc/index.ts` (~950 lines): stdlib-only RFC6455 WS server on `node:http`, fixed port 47800, `/rc` toggle command, hello auth with 6-digit decimal code, per-IP rate limit (lock at >=5 failures, 60 s), state/history builders, event forwarding (8 events), prompt/steer/abort via `pi.sendUserMessage`/`ctx.abort`, streaming buffer for mid-stream connects, session rebind on `new_session`, 90 s stale close, port-busy detection, quit auth file.
- **Remote ask** (Task 2): singleton `ask({kind, params}) -> Promise<answer|null>`; `pi-extensions/question/index.ts` + `questionnaire/index.ts` check `globalThis[Symbol.for("pi-rc")]` before the TUI path; server-generated ids (8 hex); `null` = cancelled (toggle-off/stop) → tool reports cancelled; falls through to TUI when no clients connected.
- **Debug logging**: `PI_RC_DEBUG=1` (→ `~/.pi/agent/rc-debug.log`) or `PI_RC_DEBUG_FILE=<path>` — every lifecycle event + wire frame, append-only, off by default.
- **Tailscale bind**: PATH `tailscale` → `/Applications/Tailscale.app/Contents/MacOS/Tailscale` → fail loud (never 0.0.0.0). `PI_RC_BIND` overrides.
- **Node harness** `pi-extensions/rc/test-client.mjs` (~900 lines): spawns pi in RPC mode in a temp copy of `test-project/`, 21 tests in groups 0–11 (rate-limit tests run LAST — group 11 — lockout would poison earlier groups).
- **Swift E2E** `openclient-llm-test/Features/Code/CodeEndToEndTests.swift` (+ RcE2eServer, MockModelServer, PosixProcessHandle, EventCollector): real `CodeServerClient` vs real pi+extension; LLM = local deterministic `MockModelServer` (simulator test processes have no non-loopback egress); hermetic, 6 tests.
- **Streaming fixes** (commits `0ee914e`, `04a1580`, `91922e8`, `c0aa449` on `code-rc`), all in `openclient-llm/Shared/Features/Code/`:
  - User prompt local echo with dedup (dedup reuses the trailing identical user item and resets its `failed` flag).
  - `message_update` snapshot replace: content blocks pattern-matched from `AnyCodableValue`, NOT strict `CodeContentBlock` (raw wire thinking blocks key `thinking`; tool calls are `{toolCall,id,name,arguments}` — strict decoding would throw).
  - `message_start` role filter: only `role == "assistant"` frames open a bubble — **pi also emits `message_start` for the user prompt** (`pi-agent-core agent-loop.js:51`) and the RC server forwards it; the unfiltered client created a phantom empty bubble per prompt (root cause of the phone "double sparkle").
  - Tool steps: matched by `toolCallId` (not "last step"), marked complete on `tool_execution_end`; `updateToolOutput` reads `partialResult` (cumulative — REPLACE, pi sends response-so-far `agent-loop.js:219-223`) and `result` — the old `output` key was dead (live tool output never rendered, pre-existing bug).
  - Empty assistant bubbles dropped in `finalizeStreamingBubbles` (single cleanup point, `turn_end` + `agent_settled`); `agent_settled → send(.refreshState)` for the context header.
  - Failed-send handling: `CodeServerClient.send` returns success (was swallow-and-log); prompt/steer echoes marked failed on dead-socket send or server `not_idle` rejection (positional correlation — error frames carry no text; no-op when the trailing item is not a pending echo); failed bubble shows a retry badge, tap re-sends the same text reusing the item (bypasses the local `!isStreaming` pre-block — server is the authority).
- **Device-verified (real phone on tailnet, 2026-09-06):** paired with 6-digit code, prompted, streamed, keepalive pings; single assistant bubble per message (no phantom) and tool spinners complete; context header tracks real token usage after turns (the `agent_settled` refresh works end-to-end).
- **Code review** of the streaming fixes: verdict "Request Changes (minor)", all items fixed and re-verified against code + pi source (review doc `_code-review.md` deleted after the fixes landed — its durable conclusions are in this file and in Key invariants).

## Decisions (do not revisit without a deliberate decision)
- Unknown history roles/content blocks are DROPPED (`case .unknown: break`); tests pin `count == 0`. Do not re-introduce fallback mappings (e.g. `unknown → .text("")`).
- Content blocks in `message_update` are pattern-matched, not strictly decoded (wire shape differs from the normalized history shape — see Done above).
- Steer prompts render as plain user messages — verified: `mapHistoryEntry` has no steer-specific branch; steers hit the `role === 'user'` path (`index.ts:698`).
- Cumulative-snapshot premise verified against pi source (`pi-ai` types the stream `partial` as the live response-so-far `AssistantMessage`): replace-per-frame is correct. The RC server's `appendAssistantDelta` buffer does NOT corroborate this — it only feeds hello/`session_start` `streaming_buffer` snapshot frames.
- Retry bypasses the local `isStreaming` guard on purpose; a rejected retry re-marks the same bubble failed.

## Known follow-ups (non-blocking)
- `getContextUsage()` may return null at settle → context header silently keeps the stale value (edge case; not observed on device).
- History only re-syncs on connect — mid-session desyncs (e.g. a prompt accepted server-side but whose echo was already marked failed by a stale `not_idle`) persist until reconnect.
- No way to switch chat/session or back out of the RC session screen — **another agent is on this** (user-confirmed 2026-09-06); do not duplicate.
- APNs push notifications: planning spec landed as commit `ba07122` (separate agent).

## Not done
- Spec C4 manual matrix (most items covered by harness/E2E/phone smoke; notification/background/foreground/reconnect scenarios untested on device).
- 3 PRE-EXISTING test failures outside the Code feature (verified identical on clean HEAD via git stash): `ChatViewModelTests.test_send_sendTapped_withLongHistory_limitsRequestHistory` (50 vs 51), `LMStudioChatModelsTests.test_pluginIntegration_stringEncodingAndDecoding_roundTrips` + `test_request_withMCPIntegration_encodesNativeLMStudioFields`. Unrelated to RC; belongs to Chat/LMStudio work.

## Key invariants (don't regress)
- Protocol is FROZEN against the Swift client (`openclient-llm/Shared/Features/Code/Models/`): strict Codable decoding, so field names/shapes must match exactly. `contextUsage = {tokens, contextWindow, percent}`; `sessionId = sessionManager.getSessionId()` (NOT `getLeafId()`); error codes: `bad_code, rate_limited, version_mismatch, invalid_message, not_idle, unknown_question`.
- Question tool params carry no `value` — server-side `ask()` maps `value: label`.
- Singleton state lives on `globalThis[Symbol.for("pi-rc")]` (jiti loads extensions with `moduleCache:false`).
- The client must keep role-filtering `message_start` (user-role frames are transcript noise) and treat `message_update.message.content` as a full snapshot (replace, never append).

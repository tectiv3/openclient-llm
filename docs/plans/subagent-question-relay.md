# Subagent question relay

Status: SPEC FINAL, implementation pending.
Date: 2026-09-09 (supersedes the parked 2026-09-06 Unix-socket draft).

## Problem

Subagent children run `--mode rpc`. In that mode:
1. `ask_user_question` tries `rcRemote()` → not serving → skipped.
2. Falls through to TUI guard → `ctx.mode !== 'tui'` → error "UI not available".
3. Agent aborts. The question never reaches the user.

The `extension_ui_request` auto-responder (subagent/index.ts) only covers `ctx.ui.*`
calls, not the `ask_user_question` tool — two different dead-end paths.

Observed: 2026-09-08, worker run 01a082d3 — question recovered manually from transcript.

## Design

Reuse the existing rpc stdio channel (`extension_ui_request` / `extension_ui_response`).
No new transport, no sockets, no env vars.

### Child side (ask-user-question/index.ts)

When `ctx.mode !== 'tui'` (rpc mode), instead of returning error:

1. For each question, call `ctx.ui.select(prompt, options)` — pi serializes this as
   `extension_ui_request {method:'select', title, options}` on stdout and blocks for
   `extension_ui_response`.
2. Prefix the prompt with `[agentName] ` for identity (agent name passed via env or
   derived from the question context).
3. `allowOther`: append "Type something..." as the last option. If selected, follow up
   with `ctx.ui.input(prompt)`. Two-step UX, no custom transport needed.
4. Multi-question: sequential `ctx.ui.select()` calls, one per question.
5. Cancellation: `ctx.ui.select()` returns `undefined` → return `errorResult('User
   cancelled the question', questions)`.
6. Collect all answers, format the same `answerLines` text as the normal path.

### Parent side (subagent/index.ts — handleExtensionUiRequest)

Upgrade from auto-responding to interactive relay. Always-on for `select`, `confirm`,
and `input` methods — all child extension UI requests get relayed, not just
ask_user_question.

**Relay priority** (same as parent's own questions):
1. RC (phone) if `rc.askAvailable()` → translate to `rc.ask()` call → phone renders.
2. TUI fallback → present via parent's `ctx.ui.select()` / `ctx.ui.confirm()` /
   `ctx.ui.input()`.

**Queueing:** If the parent is mid-stream (`!ctx.isIdle()`), queue the request. Drain
the queue FIFO when the parent settles (`agent_settled` event). The child stays blocked
on `ctx.ui.select()` — this is fine because the child produces no other output while
waiting.

**Stall watchdog:** Pause the watchdog for a child that has a pending relayed question.
The child is intentionally idle (waiting for user input), not stalled. Resume the
watchdog when the response is sent back.

**Response flow:**
- User answers → `writeChildStdin({ type: 'extension_ui_response', id, value })`.
- User cancels (Esc / phone dismiss) → `writeChildStdin({ type: 'extension_ui_response',
  id, cancelled: true })`.
- Run abort → cancel any pending relayed question for that child (same as current
  abort-with-pending-ask flow).

### Unchanged

- `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text` — fire-and-forget,
  no relay needed (already handled).
- `custom` — not supported in rpc mode (`return undefined as never` in pi). No change.
- `editor` — relay via `ctx.ui.input()` (editor is overkill for relay; input suffices).

## Decisions

1. **Transport:** rpc stdio (extension_ui_request/response). No Unix socket, no new IPC.
   The old socket design is dropped — the rpc channel already carries these events.
2. **Multi-question:** Sequential selects, not tabbed UI. Acceptable for relay.
3. **Relay target:** RC first, TUI fallback (same priority as parent's own questions).
4. **Interruption:** Queue until parent settles. FIFO drain on agent_settled.
5. **Identity:** Prefix question text with `[agentName]`.
6. **allowOther:** Two-step — select with "Type something..." option, then input if chosen.
7. **Cancellation:** Return 'cancelled' tool result. Subagent decides how to proceed.
8. **confirm relay:** Yes — relay to user (previously auto-denied).
9. **Scope:** Always-on for select/confirm/input. No opt-in flag.

## Implementation order

1. Parent: upgrade `handleExtensionUiRequest` — add relay logic, question queue,
   watchdog pause, FIFO drain on settle.
2. Child: `ask-user-question/index.ts` — add rpc-mode path using `ctx.ui.select()` /
   `ctx.ui.input()`.
3. Test: manual with a subagent that calls ask_user_question. Harness test if feasible
   (the rpc child can call ctx.ui.select, parent intercepts — testable in group 5 or a
   new group).
4. Phone: no Swift changes needed — the RC path uses the existing `rc.ask()` and the
   phone already renders questions.

# Subagent Attach — Design Spec

**Date**: 2026-09-08
**Scope**: `pi-extensions/subagent/` (TypeScript, pi TUI extension)

## Summary

Add `/subagents attach [id]` command that takes over the TUI to show a running subagent's live transcript and allows steering it via typed input. Escape detaches back to the parent session.

## Decisions

| Question | Answer |
|---|---|
| Input routing while attached | All input → child as steer. Escape detaches. |
| Child process mode | Always `--mode rpc` (replaces `--mode json`) |
| Attach view content | Match parent TUI feel (Markdown, tool calls, thinking) |
| On subagent finish | Auto-detach back to parent |
| Parallel support | Single subagent only for now |

## Architecture

### 1. Module-level active subagent registry

A `Map<string, ActiveSubagent>` at module scope, keyed by subagent id.

```typescript
interface ActiveSubagent {
    id: string
    agent: string
    task: string
    proc: ChildProcess
    steer: (message: string) => void  // steer handle, wired at spawn
    eventEmitter: EventEmitter  // per-subagent event stream
    settled: boolean
    events: SubagentStreamEvent[]  // capped ring buffer for late-attach replay
}
```

Entries are added immediately after spawn, removed on process exit.

**Ring buffer cap**: Max 500 events. On overflow, oldest events are evicted. This bounds memory for long-running subagents while keeping enough history for meaningful late-attach replay. Only renderable events are pushed (`message_end`, `tool_result_end`, `tool_execution_end`, lifecycle frames); high-frequency `*_update` frames are forwarded live (emitter + event bus) but excluded from the ring, so late-attach replay history stays renderable.

### 2. Switch children from `--mode json` to `--mode rpc`

**Why**: `--mode json` is fire-and-forget with no stdin reading. `--mode rpc` is bidirectional — same stdout events, but stdin accepts JSON-line commands for steering, abort, etc.

**Verified**: rpc mode ignores positional CLI args entirely. The `initialMessage` from CLI is only passed to interactive and print modes. The task must be sent via stdin prompt.

**Verified**: rpc mode supports `--session <path>` for resume — session creation happens before the mode branch, identical behavior.

**Changes to `runSingleAgent`**:

1. `stdio` changes from `['ignore', 'pipe', 'pipe']` to `['pipe', 'pipe', 'pipe']`
2. CLI arg `--mode json` becomes `--mode rpc`
3. Task text is **removed from CLI args** (the existing `args.push(\`Task: ${task}\`)` is removed). After spawn, send:
   ```json
   {"type":"prompt","message":"Task: <task text>"}\n
   ```
   as a newline-terminated JSON line on child stdin.
4. Register child in `activeSubagents` immediately after spawn.
5. Forward all parsed stdout events via per-subagent `EventEmitter` and via `pi.events.emit('subagent:event', { subagentId, name, event })`.
6. `processLine` gets a new branch for `agent_settled`: close stdin pipe → child exits cleanly via its `shutdown()` path.
7. On process exit: remove from `activeSubagents`.

**Stdin backpressure**: `proc.stdin.write()` returns a boolean. If it returns `false` (buffer full), the write is still queued by Node but we log a debug warning. Steers are small and infrequent, so backpressure is unlikely but must not crash.

**Stall watchdog adjustment**: When writing a steer to child stdin, reset `lastActivityTime` — a steer triggers a new LLM turn that may be legitimately silent for >120s on large contexts. Without this, the watchdog could kill a child during a post-steer prefill.

### 3. RPC stdin protocol (child ← parent)

Commands written as newline-terminated JSON lines to child stdin:

| Command | Format | When |
|---|---|---|
| Initial task | `{"type":"prompt","message":"Task: ..."}` | Immediately after spawn |
| Steer | `{"type":"steer","message":"..."}` | User types while attached |
| Abort | `{"type":"abort"}` | Not sent by this implementation — the parent abort path SIGTERMs the child directly (pre-existing); SIGTERM is strictly stronger because an rpc `abort` ack would abort the run but leave the child alive awaiting stdin. |

### 4. RPC stdout frame types (child → parent)

Beyond the existing `message_end`, `tool_result_end`, `message_update`, `tool_execution_*` events that json mode emits, rpc mode adds:

| Frame type | Handling |
|---|---|
| `response` | Command ack (`{"type":"response","command":"...","success":true}`). Skip in `processLine` — do not forward or count. |
| `extension_ui_request` | Extension UI dialog (confirm, select, notify, setStatus, etc.). Requires `extension_ui_response` reply on stdin. See Section 5. |
| `extension_error` | Extension load/runtime error. Log to debug, do not forward. |
| `queue_update` | Steering/follow-up queue state change (emitted when a steer is queued and when dequeued at delivery). Used by the attach view to render pending steers; excluded from the ring buffer. |

`processLine` must recognize these three types and handle them before the existing event dispatch logic.

### 5. Extension UI request handling

In rpc mode, the child can emit `extension_ui_request` frames on stdout. These require `extension_ui_response` replies on stdin or the child hangs.

**v1 — auto-respond with conservative defaults** (when not attached):
- `confirm` → `false` (deny by default — safer than auto-approving destructive operations)
- `select` → first option
- `input` → `{cancelled: true}` (rpc mode awaits a reply)
- `editor` → `{cancelled: true}` (rpc mode awaits a reply)
- `notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text` → no response needed (fire-and-forget)

The confirm default is `false` rather than `true` because auto-approving could allow destructive operations (file deletions, irreversible commands) without the user's knowledge. Subagents that need confirms should have their trust established before spawn (the existing `confirmProjectAgents` gate in the parent handles this).

**Future**: When attached, forward confirm/select dialogs to the user via the custom view.

### 6. Event forwarding from `processLine`

Today `processLine` only calls `emitUpdate()` on `message_end` and `tool_result_end`. Other events (`message_update`, `tool_execution_start/update/end`, `agent_start`, `agent_settled`) are consumed only for stall detection.

**Change**: All parsed events are also:
1. Pushed to the per-subagent ring buffer (capped at 500) — renderable events only; high-frequency `*_update` frames are excluded (see §1)
2. Emitted via per-subagent `EventEmitter`
3. Emitted via `pi.events.emit('subagent:event', ...)` (for cross-extension use)

The `emitUpdate()` call to the parent tool result renderer stays as-is — it continues to update the collapsed/expanded view for the parent session.

### 7. `/subagents attach [id]` command

**Subcommand parsing**: The existing `/subagents` command handler receives `args: string`. Parse with `args.trim()` — same pattern as `/rc push-setup` in the rc extension. `attach` with optional trailing id.

**Resolution logic**:
1. If `id` is provided: find it in `activeSubagents` (exact match or unique prefix).
2. If no `id`: if exactly one entry in `activeSubagents`, attach to it. If zero, notify "no running subagents". If multiple, list them with short ids.

**Attach flow**:
1. Subscribe to the subagent's `EventEmitter`.
2. Replay buffered events from the ring buffer (so late-attaching shows recent history).
3. Open `ctx.ui.custom(factory)` — takes over the TUI editor region with a custom component. Returns a Promise that resolves when `done()` is called.
4. The custom component is a `ScrollView` containing rendered transcript items:
   - Assistant text → `Markdown` component
   - Thinking blocks → styled `Text` (dimmed)
   - Tool calls → formatted like the parent TUI (`formatToolCall` reuse)
   - Tool output → truncated `Text`
5. Register `ctx.ui.onTerminalInput(handler)` to intercept input:
   - Bare Escape (`"\x1b"`) → call `done()` to detach
   - Enter with buffered text → write `{"type":"steer","message":"<text>"}` to child stdin, reset `lastActivityTime` on the child
   - Other keys → buffer for line editing (or pass through to input component)
   - Return `{ consume: true }` for all keys to prevent them reaching the parent
6. On `agent_settled` event: call `done()` to auto-detach, unregister handlers.

**Input handling detail**: `ctx.ui.onTerminalInput(handler)` receives complete terminal sequences (parsed by pi's `StdinBuffer`). Bare Escape arrives as `"\x1b"` after a brief timeout (~50ms). Arrow keys arrive as distinct sequences (`"\x1b[A"` etc.). This makes Escape detection reliable.

**Steer delivery semantics**: A steer command only queues the text in the child session; the child emits the user-role `message_end` (rendered as a `‹you›` line) only at **delivery** — the next LLM request boundary, possibly minutes later, or never if the child is killed first. Acceptance alone produces no transcript line. Until delivery, the attach view renders still-queued steers as `‹pending›` lines driven by `queue_update` frames (emitted on every queue change, including the dequeue at delivery — at which point the `‹pending›` line disappears and the `‹you›` line takes over).

Note: `onTerminalInput` is only functional in interactive (TUI) mode — the parent's mode. This is correct since the parent runs interactively; the child runs in rpc mode.

### 8. Cleanup and safety

**Zombie prevention**:
- Existing stall watchdog (SIGTERM after `STALL_TIMEOUT_MS` of silence) already covers stuck children. Steer resets the activity timer so the watchdog doesn't kill actively-steered children.
- Add a `process.on('exit')` handler that SIGTERMs all entries in `activeSubagents`.
- Closing stdin on `agent_settled` causes the rpc child to exit via its `shutdown()` path.

**Detach cleanup**:
- Unsubscribe from EventEmitter
- Unregister `onTerminalInput` handler
- The child keeps running — detaching is observation-only, doesn't kill it

**Abort while attached**:
- The existing parent abort signal path (`signal.addEventListener('abort', killProc)`) kills the child via SIGTERM. This should also trigger auto-detach by emitting a synthetic settled/aborted event.

### 9. What does NOT change

- `subagent_inspect` tool — still reads persisted `.jsonl` files, unchanged
- `renderCall` / `renderResult` — parent tool result display stays as-is
- Chain and parallel modes — they use `runSingleAgent` internally, so they get rpc mode automatically, but `/subagents attach` only supports single mode for now
- Persistence — `.jsonl`, `.meta`, `.pid` files work the same way (rpc mode uses `--session` the same as json mode — verified)
- Resume — the meta sidecar records the same data; resume re-sends the continuation task as a stdin prompt instead of a CLI arg

## Implementation deviations (resolved)

Deliberate departures from the original design, resolved during implementation:

- **§7 input routing**: `ctx.ui.onTerminalInput` → focused custom component with its own `handleInput`; keys reach the focused component before app keybindings, so no terminal-input interception hook is needed.
- **§7 scrolling**: `ScrollView` → manual scroll window (render all lines, slice a viewport); the layout engine cannot drive a `ScrollView` inside `ui.custom`.
- **§8 abort while attached**: no synthetic settled/aborted event — the `proc` `close` hook already covers the detach on SIGTERM exit.
- **Post-review fixes (M1/M2)**: failed `response` acks are surfaced (steer errors render as `‹err›` lines in the attach view; a rejected initial prompt fails fast instead of stalling until the watchdog), and the ring buffer keeps renderable events only.

## Out of scope (future)

- Attaching to parallel subagents individually
- Forwarding extension_ui_request to attached user (confirm/select dialogs)
- `/subagents detach` (Escape is sufficient)
- Input history / readline in the attach view
- Attach view showing the full parent context alongside subagent

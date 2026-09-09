# pi source reference

The pi (pi-coding-agent) source checkout is at `~/code/pi-mono`.

## Key files

- **Agent loop:** `packages/agent/src/agent-loop.ts` — steer/followUp delivery,
  `message_start`/`message_update` emission. Steering queue polled at run start and
  `prepareNextTurn`; aborted path returns without re-polling.
- **Session:** `packages/coding-agent/src/core/agent-session.ts` — steering queue
  `_steeringMessages`, `pendingMessageCount` = steering + followUp lengths; session
  splices steer text from the queue on delivery `message_start` before extension events;
  `_handlePostAgentRun` → `hasQueuedMessages()` → `agent.continue()` auto-continues to
  drain the queue.
- **RPC mode:** `packages/coding-agent/src/modes/rpc/rpc-mode.ts` — extension_ui_request
  serialization for `select`, `confirm`, `input`, `editor`, `notify`; `custom()` returns
  `undefined as never` (not supported in rpc mode).
- **Extension runner:** `packages/coding-agent/src/core/extensions/runner.ts` —
  `withUIPrompt` wrapper, extension mode/context setup.
- **Extension API types:** `packages/*/src`.

Use this instead of the pnpm store copy under `~/Library/pnpm/store/`.

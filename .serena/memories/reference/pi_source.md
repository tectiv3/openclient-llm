# pi source location

The pi (pi-coding-agent) source checkout is at `~/code/pi-mono` (sibling of this repo).

Key files:
- Agent loop: `packages/agent/src/agent-loop.ts` (steer/followUp delivery, `message_start`/`message_update` emission). Steer/followUp queue is polled ONCE at run start (before the first LLM call) and again at each `prepareNextTurn`; the aborted path returns WITHOUT re-polling.
- Session: `packages/coding-agent/src/core/agent-session.ts` — steering queue `_steeringMessages` (~line 325, in-memory only); `pendingMessageCount` = steering + followUp lengths (the `hasPendingMessages()` backing); the session splices a steer's text from the queue on its delivery `message_start` BEFORE extension events fire; `_handlePostAgentRun` → `hasQueuedMessages()` → `agent.continue()` AUTO-CONTINUES a finished/aborted run to drain the queue (so a steer queued across an aborted run is delivered within ms of the abort, not held pending at settle).
- Extension API types: `packages/*/src` — check `packages/` layout when needed.

Use this instead of digging into the pnpm store copy under `~/Library/pnpm/store/...` (installed, build-only).

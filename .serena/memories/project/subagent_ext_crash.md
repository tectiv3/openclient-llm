# Subagent extension: runs dying with SIGTERM (exit 143) mid-toolUse

MITIGATED 2026-09-07 (watchdog default raised to 300s + env override; opened same day, user-confirmed cross-session).

## Symptom
- Subagent child pi processes die with **exit code 143 (SIGTERM)** while a tool call is in
  flight; persisted run shows `Stop reason: toolUse`, `Status: failed`, and the transcript ends
  on a narration line (no error output from the child itself).
- Observed 2026-09-07 on three consecutive `worker` runs (dying at 39, 51, and 11 turns —
  different phases, so not a single bad tool call; one died during pure file reads).
- User sees the same in other sessions. **Resuming a persisted run works** and the child
  continues from where it died — until it may die again.

## Mechanism (confirmed in code, 2026-09-07)
`pi-extensions/subagent/index.ts`:
- `STALL_TIMEOUT_MS = 120_000` (L36), watchdog interval 10 s.
- Activity = **child stdout+stderr data only** (`proc.stdout.on('data')` / `proc.stderr.on('data')`
  set `lastActivityTime`; L~1016-1024). The watchdog (L1064-1078) SIGTERMs the child after
  120 s of total stdio silence (then SIGKILL +5 s).
- Worker children run `pi --mode json -p` on a LOCAL model (`lmstudio/qwen3.8-27b`). json mode
  emits per-chunk `message_update` lines only while tokens stream; **while waiting for the first
  token of a turn (TTFT) the child is completely silent.** A slow/saturated LM Studio server
  (local 27B over ~45k ctx, or contending with the user's other local-model sessions / harness
  spawns) → TTFT > 120 s → watchdog SIGTERMs a perfectly healthy child. That is exit 143 with
  `Stop reason: toolUse` (it dies between a tool result and the model's next response).
- Fits all observations: 4/4 deaths mid-toolUse at different turn counts, one during pure file
  reads, cross-session. Recent ext changes (2fe9d50/1ef3135/6c87605) touched exit-fallback,
  not the watchdog — they are probably innocent bystanders; the threshold vs local-model
  TTFT is the actual mismatch.

## Fix landed (2026-09-07)
`STALL_TIMEOUT_MS` is now `Number(process.env.PI_SUBAGENT_STALL_TIMEOUT_MS ?? 300_000)` with a
WHY comment (subagent/index.ts, ~L36). Takes effect in NEW pi sessions only (extensions load
once at session start) — the session where the deaths happened must be restarted to pick it up.
If deaths recur at 300s, next steps: env-override per-session (cloud fast / local slow), or a
child-side "mid-LLM-turn" heartbeat so the watchdog can distinguish model wait from a true hang.

## Where to verify
- Gated file logger (6c87605, PI_RC_DEBUG=1 → ~/.pi/agent/rc-debug.log): the watchdog logs
  `stall watchdog: no activity for Ns, events=X, last=Y, killing child` right before the kill —
  check the last lines for dead run ids 01a07cb8-7e07-736c-b81d-d2ddf6323c19 and
  01a07cdf-e2ec-736c-b81d-d2dfcaf9de39.
- Correlate deaths with LM Studio server load (other local-model sessions running concurrently).

## Workaround until fixed
Resume the persisted run (`resume: <id>`) — it continues; budget for repeated resumes. For
critical long tasks, split into smaller subagent tasks so a death loses less.

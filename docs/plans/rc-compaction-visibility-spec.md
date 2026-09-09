# Plan: Compaction visibility in rc (banner + stop)

Status: implemented (server: commit 12c6130; Swift client + tests landed after).
Date: 2026-09-09
Parent: `docs/plans/rc-remote-control-spec.md`. Partial pull of the
`session_compact*` event handling out of `rc-commands-spec.md` (no command set —
the `compact` command itself stays in that spec).

## Problem

Compaction (auto threshold/overflow mid-run, or terminal `/compact`) is invisible
to the phone:

1. `pi-extensions/rc/index.ts` subscribes to **none** of `session_before_compact`,
   `session_compact`, `session_compact_failed`. No state broadcast, no snapshot —
   the transcript and context header go stale until reconnect.
2. Observed incident (2026-09-09): auto-compaction mid-run; phone Stop tap gave no
   feedback; a steer sent during compaction queued; compaction then completed, the
   steer was delivered, and the turn ended `aborted`. Root cause NOT pinned
   (owner decision: skip forensics, re-verify after this work with
   `PI_RC_DEBUG=1`). Static analysis shows the server abort path *should* work
   (`!isIdle()` is true while compacting → `ctx.abort()` → `session.abort()` →
   `abortCompaction()` aborts both manual and auto controllers, and
   `agent-session.ts` re-checks `signal.aborted` after the summary call), yet the
   summary was saved — so `session.abort()` evidently never ran during the
   compaction. The re-verification below is mandatory, not optional.

## Decisions

| # | Decision | Chosen |
|---|----------|--------|
| D1 | Wire shape | New **optional** field on the existing `state` frame: `compacting: { reason: "manual"\|"threshold"\|"overflow", willRetry?: boolean }`. Present only while a compaction is in flight; absent otherwise. Chosen over a dedicated event frame: the `state` frame is what a reconnecting client receives in the connect burst, so a mid-compaction reconnect shows the banner for free, and there is one source of truth instead of an event + state pair that can desync |
| D2 | Server subscriptions | `session_before_compact` → set `state.compacting`, broadcast `state` to all clients. `session_compact` (ALL reasons) and `session_compact_failed` → clear `state.compacting`, broadcast `state` + `history` snapshot (the compaction entry is already mapped to `role: "compaction"` by the history builder, and the Swift client already renders it). `state.compacting` also cleared on `session_start` rebind and `session_shutdown` (same hygiene as `pendingSteers`) |
| D3 | Failure feedback | `session_compact_failed` with `aborted: true` → banner clears, NO error frame (the phone's own Stop caused it). `aborted: false` (genuine failure) → additionally `{ type: 'error', code: 'compaction_failed', message }` (new error code, additive) → phone toast |
| D4 | Stop path | **Unchanged.** The existing `abort` frame already targets this: while compacting `isIdle()` is false, so the server calls `ctx.abort()`, which aborts compaction AND the run. Mandatory re-verification with `PI_RC_DEBUG=1` after implementation (see Tests) |
| D5 | Phone UI | Banner/chip "Compacting context…" with a spinner and an inline **Stop** button (tap = send `.abort`). Shown while the last `state` frame carries `compacting`. `reason` is NOT surfaced in v1 (one string for all reasons; the field is carried for the future). Banner sits above the input bar (or context header area — implementer's call, match `chat-visual-style`); a11y: banner is a group, Stop has its own trait, announcement on appear/disappear |
| D6 | Protocol framing | The protocol is NOT frozen — both ends are owner-controlled and change atomically (precedent: ask consolidation, `pending` steers). The "frozen" wording in the parent/commands/push specs is being reworded to say the docs are historical records, not protocol change-blocks |
| D7 | Swift model | `CodeSessionInfo` gains `compacting: CodeCompacting?`; new `CodeCompacting: Codable` (`reason: String`, `willRetry: Bool?`). Strict decode is safe: JSONDecoder ignores unknown keys, so a pre-change server is invisible to a new client and a new server's field is additive |

## Server changes (`pi-extensions/rc/index.ts`)

- `state.compacting: { reason, willRetry? } | null` on the singleton.
- `buildState()` includes `compacting` only when non-null.
- Three new `pi.on` subs (mirror the `session_compact` bullet in
  `rc-commands-spec.md` A-events; that spec stays the design record for the
  command set and cross-references this spec for the events).
- `session_before_compact` may be cancelled by an extension handler and replaced
  (`compaction` result) — rc has no such handler; the later
  `session_compact`/`failed` event is the clearing path either way, so no
  special-case.

## Swift changes (`Shared/Features/Code/`)

- `CodeModels`: `CodeCompacting`, `CodeSessionInfo.compacting`.
- VM: session state carries `compacting?`; set from state frames (connect burst,
  broadcasts, snapshot) — single update point next to `session.isStreaming`.
- View: banner per D5; Stop button calls the existing `handleAbort()`.
- `compaction_failed` error → toast (existing error-frame path, new code).

## Tests

- **Harness group 15** (`test-client.mjs`; MAIN session runs it — subagent
  SIGTERM landmine). Trigger = test-only probe extension
  (`test-project/rc-compact-probe.ts`, pattern: `rc-signal-probe.ts`) that calls
  `ctx.compact()`; session seeded with a few exchanges first (manual compact
  rejects "Nothing to compact"). MockModelServer gets a ~3 s delay on the
  summarization request (detected by prompt content marker) so the in-flight
  window is stable. Tests:
  1. mid-compact `state` (late-join connect burst) carries
     `compacting.reason == "manual"`.
  2. after completion: state has no `compacting`; history snapshot contains a
     `role: "compaction"` entry.
  3. **abort-during-compact** (the incident): client sends `abort` mid-compact →
     expect `state` broadcast WITHOUT `compacting` and NO compaction entry in
     history (pins D4; if this fails, the 2026-09-09 incident root cause has
     reproduced — stop and investigate before shipping).
  4. rebind (`new_session`) snapshot has no `compacting`.
- **Swift unit**: decode `state` with/without `compacting`; VM banner set/clear
  transitions; `compaction_failed` toast path.
- **Phone re-verification (operator)**: real auto-compaction (or terminal
  `/compact` during a long run) with `PI_RC_DEBUG=1` — banner appears, Stop tap
  interrupts compaction (wire log shows the `abort` frame; terminal shows the
  cancelled compaction), banner clears.

## Out of scope

- The `compact` *command* from the phone (stays in `rc-commands-spec.md`).
- Distinct banner copy per `reason`; surfacing `willRetry`.
- Branch-summary visibility (`_branchSummaryAbortController` shares `isCompacting`
  but has no separate event; `session_before_compact` won't fire for it — banner
  simply won't show; accepted).

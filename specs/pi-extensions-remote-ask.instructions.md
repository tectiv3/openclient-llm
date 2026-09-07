---
description: "Use when changing pi-extensions/rc, pi-extensions/question, or pi-extensions/questionnaire — APNs push mode-guards, the rc globalThis singleton shape-version rules, the shared remote-ask helper, or remote question relaying."
applyTo: "pi-extensions/**"
---

# pi Extensions — Remote-Control Ask Pipeline (rc / question / questionnaire)

## Status

**SUPERSEDED (2026-09-07).** Plan disposition:

- **T1 (push mode-guard)** — landed (8df74bd).
- **T2 (widened full-shape guard)** — landed in the merged ask-user-question extension
  (41fcc98); the widened `rcRemote()` guard (requires BOTH `ask` AND `askAvailable`)
  lives in `pi-extensions/ask-user-question/index.ts`.
- **T3 (singleton shape-versioning)** — DROPPED by owner decision 2026-09-07: `/reload`
  is being retired, and the widened guard covers the current call surface.
- **T4 (APNs session unref)** — REMAINING optional hardening, not landed.

The INV1–INV4 invariants below remain true and binding. The rest of this file is
kept as the historical record of the bug mechanisms (verified 2026-09-07 against
pi 0.85.1, `../pi-mono` source) and the original plan.

## Background

### Bug B1 — subagent hang (and spurious pushes)

1. Subagent children run `pi --mode json -p` (`subagent/index.ts:739`); all extensions load in
   the child. The child's rc singleton reads the shared `~/.pi/agent/rc-push.json` → real device
   token + APNs config.
2. Child's `agent_settled` → `trackEvent` → `fireFinishedPush` (`rc/index.ts:943`) — no mode check.
3. `sendApnsPush` → `getSession()` (`rc/apns.ts:235`) opens an http2 session cached at module
   level. On success it is never closed and never unref'd (`closeApns()` runs only on timeout).
4. Print mode exits by natural event-loop drain (no `process.exit` on the normal path; only
   SIGHUP/SIGINT handlers exit), so the open h2/TLS socket keeps the child alive forever.
5. Parent's stall watchdog kills the child after 120 s of silence (`subagent/index.ts:36`) →
   every subagent "hangs" ~2 min then fails. Side effect: one "Agent finished" push per subagent.
   Corroborated by three stuck subagent runs in this project: complete final transcript on disk,
   child never exits, killed at the watchdog deadline.

### Bug B2 — question-tool TypeError after `/reload`

1. The rc singleton lives on `globalThis[Symbol.for('pi-rc')]` (`rc/index.ts:125–127`) and
   survives `/reload` (pi re-evaluates extension modules — `loader.ts` jiti `moduleCache: false`
   + generation bump — but `globalThis` persists).
2. After `/reload`, new rc code reuses the old singleton object; `rc()` rebinds only
   `handleUpgrade`/`handleSocketData`/`refreshStatus` (`rc/index.ts:1231–1233`). Methods added
   later (e.g. `askAvailable`) are missing from the old object.
3. `rcRemote()` in question/questionnaire guards only `typeof ask === 'function'`; `ask`
   predates `askAvailable`, so a stale singleton passes the guard.
4. `execute` calls `rc.askAvailable()` (`question/index.ts:192`, `questionnaire/index.ts:219`)
   → `TypeError: rc.askAvailable is not a function`.

Reload context (pi `core/extensions/loader.ts`): `/reload` re-evaluates extension modules with
jiti `moduleCache: false` + a generation bump, and `invalidate()` on the stale ctx unsubscribes
that generation's tracked event-bus handlers — so old `pi.on` handlers do NOT double-fire after
a reload. The only cross-reload survivor is the `globalThis` singleton itself.

`ExtensionMode` is `"tui" | "rpc" | "json" | "print"` (pi `core/extensions/types.ts:307`). Only
`tui` and `rpc` are interactive.

## Invariants (durable rules)

- **INV1 — Push mode-guard.** APNs pushes fire only when `binding.ctx.mode` is `tui` or `rpc`.
  Every current or future push site goes through the same guard helper in `rc/index.ts`.
  `apns.ts` stays mode-agnostic. Deliberately NOT gated on the `/rc` server being enabled:
  in a TUI session a finished push still fires on every settled turn whenever a token is
  registered and creds resolve, even if `/rc` was never toggled — push is the completion
  notification, the server is for interactive control (matches
  `rc-push-notifications-spec.md` "only when a token is registered").
- **INV2 — Singleton surface is append-only.** The `RcSingleton` method surface only ever gains
  methods; renames/removals are forbidden. Any surface change bumps `SINGLETON_SHAPE_VERSION`.
  The wire-protocol `VERSION` constant is unrelated and must not be reused for this.
- **INV3 — Decoupled access with full-shape guard.** question/questionnaire never import rc.
  They reach it exclusively through the shared helper's `rcRemote()`, which accepts a cached
  singleton only if every method the callers invoke is a `function`.
- **INV4 — APNs session must not pin the event loop.** The cached http2 session is unref'd;
  in-flight sends stay protected by the ref'd `SEND_TIMEOUT_MS` timer. This is safe *only in
  combination with INV1*: unref would drop a push fired while the loop is already draining,
  so any future non-interactive push site must re-evaluate INV4 before relying on delivery.

## Plan

Tasks are ordered; T0 is a decision gate for T2's import style. Each task lands as one commit
and can be reverted independently.

### T0 — Spike: cross-directory import through symlinked deployment

`question/index.ts` importing `../common/remote-ask` must resolve to the repo's real
`pi-extensions/common/` when run through pi's jiti loader with the symlinked deployment
(`~/.pi/agent/extensions/question -> .../pi-extensions/question`).

Expected result (partially pre-verified 2026-09-07 with a bare-node symlink test): the
entry's realpath resolution already routes `../common` into the repo's `pi-extensions/common/`
— a relative import resolves against the importing file's realpath, NOT against the
`~/.pi/agent/extensions/` deployment dir. So `common/` is **not** an extension entry and needs
no new deployment symlink (the Out-of-scope symlink rule is untouched); the only bare-node
failure was Node-ESM's missing `.ts` extension resolution, which jiti handles. The spike
confirms this through pi's actual jiti loader, with two recorded outcomes:

1. **Resolution** — `../common/remote-ask` loads from the repo path.
2. **Instance regime** — whether question and questionnaire get one shared module instance
   or per-importer instances (compare a module sentinel across both importers). Both regimes
   are safe — the relay pending map is keyed by `randomUUID()` ids and each stdin listener
   resolves only ids present in its own map — but record which regime actually occurs.

- **Pass** → T2 uses `../common/remote-ask` imports.
- **Fail** → fallback: in-repo file symlinks `question/remote-ask.ts` and
  `questionnaire/remote-ask.ts` → `../common/remote-ask.ts`, imported as `./remote-ask`.
  Single source of truth either way.

T0 commit also registers this spec in the `AGENTS.md` spec table (it landed without one).

### T1 — Fix B1: guard pushes to interactive modes (`rc/index.ts`)

Add:

```ts
function pushAllowed(state: RcSingleton): boolean {
    const mode = state.binding?.ctx?.mode
    return mode === 'tui' || mode === 'rpc'
}
```

`fireFinishedPush` and `fireQuestionPush` return early when `!pushAllowed(state)` (before the
token check). A null `binding` means no push — correct default before the first event binds.
`fireQuestionPush` is currently unreachable in children (`askAvailable()` requires a live
server, which only `/rc` — interactive — starts); the guard there is defensive symmetry.

T1 also amends `docs/plans/rc-push-notifications-spec.md` in the same commit: decision #2
trigger points and the `agent_settled` bullet gain the mode gate (interactive modes only;
subagent children in json/print mode never push), and the Out-of-scope/Open-items area notes
INV1.

**Acceptance:** with push configured, `time pi --mode json -p "Reply with: ok"` exits in ~1–2 s
(pre-fix: hangs indefinitely on manual runs — the 120 s kill only exists under the subagent
watchdog); `PI_RC_DEBUG=1` shows no `apns` lines from the child; TUI mode still pushes on
settle.

### T2 — Fix B2 (immediate): shared remote-ask helper + full-shape guard

New `pi-extensions/common/remote-ask.ts` (import style per T0), moving the duplicated code
from `question/index.ts` and `questionnaire/index.ts`:

- `RC_KEY`, the `RcRemote` structural interface, and `rcRemote()` — guard now requires **both**
  `askAvailable` and `ask` to be functions (the only methods the callers invoke;
  `isServing`/`hasConnectedClients` stay in the interface, optionally in the guard).
- `askRemoteWithEscHatch(ctx, kind, params)` — generic over kind; call sites keep their
  params mapping.

Both extensions' `execute` switches to the shared imports; local TUI UI, `renderCall`,
`renderResult`, and result interpretation stay in each extension.

The parent-relay block (`RelayResponse`, `attachRelayStdin`, `relayPending`, `relayAsk`) is
NOT moved here: it is dead code of the PARKED subagent-question-relay track
(`docs/plans/subagent-question-relay.md` — stdin design rejected, `PI_SUBAGENT_RELAY_SOCK`
socket design adopted, and `PI_SUBAGENT_RELAY` is set nowhere in the current tree). Moving
it into `common/` would give the rejected design a shared home inside the B2 fix commit and
couple the fix's revertability to a parked track. Relocate it only when that track is revived,
as part of the socket-design work.

**Acceptance:** stale-singleton simulation (manually `delete (globalThis[RC_KEY] as any).askAvailable`
in a debug session, or a `/reload` from a pre-`askAvailable` build) makes the question tool fall
back to the local prompt instead of throwing; both tools behave unchanged otherwise.

### T3 — Fix B2 (class): shape-version the singleton (`rc/index.ts`)

- Add module constant `SINGLETON_SHAPE_VERSION = 2` and a `shapeVersion: number` field on
  `RcSingleton` (set in the state literal).
- `singleton()` resolution order:
  1. cached exists, `shapeVersion` equals mine → return cached;
  2. cached exists, its `shapeVersion` is a number **greater** than mine → return cached
     (a newer module already ran; its surface is a superset — INV2);
  3. otherwise (missing field, or lower version) → fire-and-forget
     `void cached.stop('stale_shape', ...)`, then build and store a fresh singleton.
- A singleton without `shapeVersion` is by definition stale — first deploy of this fix replaces
  any pre-fix survivor.
- `stop()` on the stale singleton cancels its pending ask (resolves `null` → callers fall back
  to local), closes clients and the server. `singleton()` stays synchronous; the async stop is
  fire-and-forget. If the user toggles `/rc` before the old server finishes closing, the
  existing EADDRINUSE branch already degrades gracefully; additionally call
  `server.closeAllConnections()` in `closeServer()` to shrink that window.
- No bind-before-stop race: pi unsubscribes a stale ctx's tracked event-bus handlers on
  reload (`loader.ts` `invalidate()`), and the new module's `rc()` → `singleton()` runs during
  extension load, before any event dispatch — so the old `forward` can never bind the new ctx
  to the old state.
- The stale `stop('stale_shape')` writes `stopped` to the auth file — correct (that server
  really did stop). The fresh `/rc` then writes `running` last (after `resolveBindHost` +
  `listen`), so the file ends `running`. In-memory `rateLimits` reset with the discarded
  singleton is benign: `start()` re-randomizes the connect code anyway.
- Remove the now-dead rebinds at `rc/index.ts:1231–1233` (`handleUpgrade`, `handleSocketData`,
  `refreshStatus` reassignment in `rc()`).

**Acceptance:** with `/rc` serving: bump `SINGLETON_SHAPE_VERSION`, `/reload` → debug log shows
`server stopped: stale_shape`, status line clears, `/rc` starts a fresh server on the same port,
the auth file ends `status: running`, and the phone client can answer a question post-reload.

### T4 — Hardening: unref the cached APNs session (`rc/apns.ts`)

In `getSession()`, `newSession.unref()` after connect (plus `newSession.socket?.unref()` if the
session call does not propagate). Rationale: any drained process (now or future non-interactive
call paths) must be able to exit even with a cached session; an in-flight send keeps the loop
alive via the ref'd `SEND_TIMEOUT_MS` timer, so delivery is unaffected.

**Acceptance:** TUI push flow unchanged (a naturally settled turn still delivers the finished
push); a synthetic drained process holding a cached session exits immediately.

## Verification matrix

| Bug | Fix | Procedure |
|---|---|---|
| B1 hang | T1 | `time pi --mode json -p` child-exit test; debug log shows no child `apns` lines |
| B1 pushes | T1 | subagent run under `PI_RC_DEBUG=1`: child log has no `apns` lines (phone optional) |
| B2 TypeError | T2 | stale-singleton simulation → local fallback, no throw |
| B2 class | T3 | `/reload` shape-bump procedure; remote question works post-reload |
| regression | T1–T4 | manual pass: local question/questionnaire UI, remote ask with Esc hatch, push flow, subagent delegation completes |

Manual procedures use `PI_RC_DEBUG=1` (writes `~/.pi/agent/rc-debug.log`), the `PI_RC_AUTH_FILE`
test seam, and `pi-extensions/rc/test-project/` (ASK / ASKFORM scripts).

## Risks

- **EADDRINUSE race after T3** — mitigated (fire-and-forget stop + `closeAllConnections()` +
  graceful existing branch). Window is sub-second and requires an immediate manual `/rc`.
  Auth-file transient during the window (`stopped, reason: stale_shape` then `running`) is
  correct sequencing, not corruption; the acceptance asserts the terminal `running` state.
- **jiti cross-dir resolution (T2)** — pre-verified at the realpath level; T0 gates the
  jiti-specific confirmation with a symlink fallback.
- **unref subtlety (T4)** — in-flight sends keep the ref'd timeout timer; no delivery change
  for sends started before drain. INV4's INV1 dependency is the actual invariant that keeps
  this true.
- **Missed shape-version bump (T3)** — a surface change that forgets the INV2 bump would
  silently reuse the stale singleton with the rebinds removed, mixing old-module closures into
  the new surface (the B2 class, undetected). Mitigation: the T3 stale-shape reload
  procedure doubles as the regression check any surface-add commit must run.
- **Rollback** — one commit per task; revert independently.

## Out of scope

rc wire-protocol changes, subagent relay protocol changes, question/questionnaire UI behavior,
an automated test harness for pi-extensions, and any change to how extensions are symlinked
into `~/.pi/agent/extensions/`.

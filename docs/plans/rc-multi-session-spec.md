# Plan: rc multiple remote sessions (one machine, many pi sessions)

Status: spec only, 2026-09-11; not yet implemented.
Date: 2026-09-11.
Parent: `docs/plans/rc-remote-control-spec.md` (FROZEN 2026-09-09). Sibling: `docs/plans/rc-commands-spec.md` (session-control commands, shipped 2026-09-10).

**Context.** Today one box serves at most one remote session: rc is a
process-level singleton on fixed port 47800, and a second pi process on the
same machine that runs `/rc` gets an EADDRINUSE warning and no server (frozen
parent spec, Decision 3). The phone is a single-session client: it stores one
`SessionState` and rebinds in place when a `state` frame carries a new
`sessionId` (built for in-process `/new`).

This feature makes **N concurrent pi sessions on one machine** visible and
switchable from the phone: the user starts 2-3 pi sessions in terminals (each
with `/rc`), and the phone shows a session list, switches among them, and
prompts/steers/answers/compacts/renames per session — all over **one**
WebSocket connection to the anchor.

Per the owner rule (rc-commands-spec.md), this doc is the **source of truth
for the multi-session feature**. Where the frozen parent spec's Decision 3
("if the port is taken, this instance cannot start its server") conflicts,
this doc supersedes it: a losing process now starts a **loopback sibling
server** instead of nothing.

## Decisions (owner-approved 2026-09-11 — do not revisit)

| # | Decision | Chosen |
|---|----------|--------|
| 1 | Scope | Multiple concurrent pi sessions on **one machine**, phone connects and switches among them. Cross-host (different machines) already works via the recent-connections list and is unchanged |
| 2 | Topology | **Anchor broker**: the phone holds ONE WS connection to the anchor (port 47800). The anchor proxies frames to sibling sessions. No phone-visible multiplexing beyond the anchor |
| 3 | Sibling exposure | Sibling servers bind **127.0.0.1 only**, dynamic port. The only tailnet-exposed surface is the anchor on 47800. One pairing relationship, one auth implementation to audit |
| 4 | Anchor election & failover | Anchor = whichever process owns 47800 (first `/rc` wins). **No active failover**: when the anchor's pi exits, the phone connection dies; siblings keep their loopback servers; the **next** `/rc` on the box binds the freed 47800 and becomes anchor. No rebind races |
| 5 | Pairing | The 6-digit code stays **per-process, first-time pairing only** (shown in the terminal that ran `/rc`). No persisted machine code, no new secrets on disk beyond the registry's internal tokens (see §Registry). All subsequent connects use push-token auto-auth, which already works machine-wide because the device token persists in `~/.pi/agent/rc-push.json` |
| 6 | Proxy subscription | **Lazy (subscribe-on-select)**: the anchor opens a proxy connection to a sibling only while the phone has that session selected. No standing anchor→sibling connections |
| 7 | List liveness | **File-based status**: each session process (anchor included) writes its own registry entry with live status fields on state changes (debounced). The anchor watches the file and re-broadcasts a `sessions` frame to the phone. No standing connections needed for badges |
| 8 | Session lifecycle from phone | **View/switch/manage only.** Phone can prompt, steer, abort, answer, and send the existing commands (`new`/`set_model`/`compact`/`name`) per selected session. Spawning and killing pi processes from the phone is explicitly **excluded** for v1 |
| 9 | Push | **Per-session collapse ids** (session id in the APNs collapse-id) so one session's finished/question push no longer eats another's; `thread-id` already carries the session id (unchanged). Notification tap = **deep link that selects that session** in the app |
| 10 | Phone UI | **Single view + picker sheet**: existing session view unchanged; a sessions button in the toolbar opens a sheet/list (name, cwd, model, streaming/question badges, anchor tag); tapping switches in place via the existing rebind logic. No multi-view, no new top-level tab |

## Verified facts (2026-09-11, recon against `pi-extensions/rc/` + Swift client)

1. **Singleton shape** (`index.ts:40, 96-133`): one `RcSingleton` on
   `globalThis[Symbol.for('pi-rc')]`; `binding`/`commandCtx`/`pendingAsk`/
   `pushToken` are all singular. `PORT = 47800` is a constant; EADDRINUSE →
   warning + `writeStoppedAuth('port_busy')`, no server. `resolveBindHost()`
   picks the tailnet IP (`PI_RC_BIND` override).
2. **Session identity is live**: `sessionId(state)` is computed per frame from
   `state.binding?.ctx.sessionManager.getSessionId()` — no stored session id
   on the singleton. `state`/`history`/`event`/`question` frames all carry
   `sessionId`.
3. **Client already multiplexes by filter**: `CodeViewModel+Messages.swift:91`
   guards `event.sessionId == session.sessionId` (frames for other sessions are
   ignored), and `handleStateInfo` (CodeViewModel.swift:459-468) **rebinds in
   place** on a `state` frame with a different sessionId — the switch
   machinery already exists from the `/new` work (rc-commands-impl.md Task 6).
4. **Auth** (`index.ts` handleHello): `hello` accepts code **or** the
   registered push token (`helloTokenMatches`); the device token is persisted
   machine-wide in `~/.pi/agent/rc-push.json` via `saveDeviceToken`
   (handlePushToken), read back at startup — so token auto-auth already works
   for any rc process on the box. Per-IP rate limit: 5 fails → 60 s lockout.
5. **Push** (`apns.ts`, `index.ts` fire*Push): `thread-id` = pi session id;
   collapse ids are **constants** (`FINISHED_COLLASPE_ID` /
   `QUESTION_COLLASPE_ID` imported in index.ts) — a new push of the same kind
   replaces the old one app-wide regardless of session. Push gate: interactive
   mode (tui/rpc) + `isServing()` (INV1). Push config + device token share one
   file (`~/.pi/agent/rc-push.json`), env seam `PI_RC_APNS_CONFIG`.
6. **Lifecycle**: `session_shutdown` reason `quit` → server stop; other reasons
   (`new`/`resume`/`fork`) → `binding = null` only, server survives (frozen
   Decision 7: process-level lifetime). `process.once('exit')` writes
   quit-stopped auth.
7. **Commands** (rc-commands-spec, shipped): one generic `command` frame,
   names `new`/`set_model`/`compact`/`name`; `commandInFlight` rejects
   concurrent commands; `newSession` uses the stashed `ExtensionCommandContext`
   and re-stashes via `withSession`.
8. **Swift client state**: `State` enum holds exactly one `SessionState`
   (CodeViewModel.swift:41-46); recent-connections list (host+port, cap 5)
   persisted in SettingsManager; pairing code ephemeral (in-memory
   `lastConnect`); push token in Keychain. No session-list/picker concept
   anywhere (grep-verified).
9. **Test seams pattern**: `PI_RC_AUTH_FILE`, `PI_RC_APNS_CONFIG`,
   `PI_RC_DEBUG` — new persistent state follows the same env-seam convention.

## Design

### Roles

| Role | Binds | Registers | Pushes |
|---|---|---|---|
| **Anchor** | tailnet IP : 47800 | yes | yes (own session) |
| **Sibling** | 127.0.0.1 : dynamic (47801-47899) | yes | yes (own session) |

Every pi process that runs `/rc` registers itself; the role is decided by
whether the 47800 bind succeeded. The anchor's **own** session is just entry #0
in the same list (`isAnchor: true`) — no special-case list construction.

### Registry file

- Path: `~/.pi/agent/rc-registry.json` (env seam `PI_RC_REGISTRY`, mirroring
  the existing seam pattern). Mode `0600`. Atomic tmp+rename writes (same
  pattern as `rc-push.json`).
- Shape:
  ```jsonc
  {
    "sessions": [
      {
        "id": "<uuid, stable for the life of this pi process>",
        "port": 47801,              // anchor: 47800
        "pid": 12345,
        "host": "127.0.0.1",        // anchor entry: tailnet host (informational; see probe note)
        "token": "<random 32B hex — internal proxy auth, see below>",
        "isAnchor": false,
        "sessionId": "<pi session id, changes on in-process /new>",
        "cwd": "/path/to/project",
        "name": "openclient-llm",   // session name or cwd basename
        "model": { "provider": "...", "id": "..." },
        "isStreaming": true,
        "hasQuestion": false,
        "compacting": false,
        "lastActivity": "2026-09-11T12:00:00Z"
      }
    ]
  }
  ```
- **Entry id**: generated once per pi process at first registration (uuid).
  Survives in-process `/new` (session replacement keeps the same entry, new
  `sessionId`). A process restart = new entry.
- **Writers**: each process updates ONLY its own entry (keyed by `id`):
  - on `/rc` enable (create) and `/rc` disable (remove) and process exit (remove);
  - on status changes: `isStreaming`, `hasQuestion`, `compacting`,
    `sessionId`, `name`, `model`, `lastActivity` — debounced (~250 ms
    coalesced write), never per-token.
- **Merge-on-write rule (concurrency)**: every writer (including the anchor
  pruner) performs **fresh read → mutate own entry → write** with the read
  immediately before the rename, keeping all *other* entries exactly as they
  appear in the fresh read. The fresh read happens **at write time (after the
  debounce flush), not when the change was debounced** — reading at trigger
  time reintroduces the stale-clobber the rule exists to kill. If the file is
  **unparseable, the pending write is aborted** (value retained, retried on
  the next change) and logged: a writer must never merge into an empty read,
  or it clobbers every other entry. This eliminates stale-read clobbering: B's write
  can never carry A's status from an old snapshot. Own-entry freshness is
  guaranteed (one writer per entry). Remaining race: two writers read at
  t0, both write at t1 — the second rename wins with the newer read, so the
  loser's *own* entry may be one update behind for ≤250 ms (the debounce
  window); a following status change self-heals. Status fields are
  best-effort badges, not control state — no correctness depends on them.
- **Readers/pruner**: the anchor reads the file via `fs.watch` **plus an
  always-on 5 s poll** (watch is a latency accelerator on a busy machine,
  not a liveness requirement). The pruner removes entries whose process is
  gone: **TCP connect probe to `127.0.0.1:port` is the authoritative check**
  (probes target loopback because sibling servers are loopback-only; the
  anchor's own entry is exempt from probe-pruning — the anchor self-excludes
  it by entry id since its listener is bound to the tailnet interface, not
  loopback, and is owned by the pruner's own process); `kill(pid, 0)`
  is advisory only (`EPERM` = alive). The probe also covers pid reuse after
  restart (reused pid → old port not listening → pruned). The anchor rewrites
  the file **only when content actually changes** (diff before rename) so its
  own prune write cannot re-trigger its own watch in a loop.
- **Internal proxy token** (`token` field): each process generates a random
  32-byte hex token at registration (token does NOT change on in-process
  `/new` — only on re-registration, i.e. `/rc` re-enable or process start);
  the anchor presents it in `hello` when opening a proxy connection to that
  entry's port. **Sibling-side auth change (required)**: the entry token is
  also held in the owning process's singleton, and that process's
  `handleHello` accepts it as a **third hello credential** alongside the
  6-digit code and the device push token — today `handleHello` authenticates
  only those two (index.ts:560-597), so without this change the sibling would
  reject every anchor proxy hello. This keeps auth uniform (no loopback
  trust special-case) and works even before any phone push token is
  registered. Threat model
  (accepted, per owner): the file is `0600` in the user's own home; any
  process running as the user — including another pi session's agent with a
  `bash` tool — can read the tokens and impersonate the anchor toward
  siblings. The box is single-user; a rogue local agent already has shell
  access to everything else on the machine. Decision 3's "one auth
  implementation to audit" is only as strong as this file's permissions.

### Wire protocol (additive; phone ↔ anchor only)

Server → client (new):

```jsonc
{ "type": "sessions",
  "sessions": [ { "id", "sessionId", "cwd", "name", "model",
                  "isStreaming", "hasQuestion", "compacting",
                  "lastActivity", "isAnchor" } ] }
```

Broadcast to all authenticated phone clients:
- after the phone's `hello_ok` (immediately, before/with the snapshot);
- whenever the anchor's view of the registry changes (entry added/removed/
  status change), debounced ~250 ms.

Client → server (new):

```jsonc
{ "type": "select_session", "id": "<registry entry id>" }
```

- `select_session` for the **anchor's own session** (or the currently
  connected default): pure in-process switch — anchor re-broadcasts that
  session's snapshot to the phone; no proxy needed.
- `select_session` for a **sibling**: anchor opens (or reuses) a proxy
  connection to `127.0.0.1:port`, hellos with that entry's `token` (and the
  current `VERSION` constant — never hardcoded), and forwards:
  - the sibling's `hello_ok`-snapshot (`state` + `history`
    `+ streaming_buffer` while streaming — the full `writeSessionSnapshot`
    burst) → phone, then
  - all subsequent sibling frames (`state`, `history` responses, `event`,
    `question`, `question_resolved`, `streaming_buffer`, `error`) → phone.
    Frames already carry `sessionId`; no retagging.
- Phone → anchor frames for the **selected** session are forwarded verbatim:
  `prompt`, `steer`, `abort`, `answer`, `get_state`, `get_history`, `command`
  (all four command names). `ping` is NOT forwarded — the anchor answers pings
  itself AND sends its own pings to the proxy every 30 s (see Proxy
  lifecycle: the sibling's 90 s `STALE_MS` stale-close would otherwise kill
  a selected-but-idle proxy, since the phone's 30 s pings keep only the
  phone↔anchor socket alive).
- **One selected session at a time** per phone connection. Selecting B while
  A is selected: anchor closes A's proxy (if any; A may be the anchor session),
  opens/uses B's, streams B's snapshot. The phone's existing rebind logic
  adopts B — see the suppression rule below, which is what makes that true.

**Anchor's own frames while a sibling is selected (suppression rule).**
The phone's `handleStateInfo` rebinds on ANY `state` frame whose
`sessionId` differs from the current one (that is the in-process `/new`
rebind mechanism; `handleHistory`/`handleStreamEvent`/`handleQuestion`
carry sessionId guards, `state` deliberately does not). The anchor
broadcasts its own session's `state`/`history` on `model_select`,
`session_info_changed`, compact start/finish, and `session_start`
(`broadcastSessionSnapshot`). Without a rule, one `/compact` or model change
in the anchor's TUI would yank a phone that is viewing sibling B back to the
anchor session (state-only broadcasts would also clear the transcript with
no history following). Rule: the anchor tracks the selected entry per phone
connection (it must, to route `prompt`/`command`). For a connection whose
selection is a **non-anchor** entry, the anchor suppresses its own session's
`state`, `history`, `event`, `question`, `question_resolved`,
`streaming_buffer`, **and `error`** broadcast frames to that client (the
phone's `handleError` is session-agnostic — error frames carry no sessionId —
so an anchor `compaction_failed` would otherwise toast over the sibling's
transcript). `sessions` frames and the selected sibling's frames (including
its `error` frames) are always delivered. Scope: suppression applies to the
anchor's **broadcast of its own session's** frames only; per-client protocol
frames (`hello_ok`, `sessions`, `session_not_found`, `session_gone`) are
never suppressed. Selection of the anchor entry (or the
default, pre-selection state) delivers everything as today. The phone's
rebind path is thereby exercised exactly as it is today (in-process `/new` on
the anchor session, snapshot on sibling select) — "rebind logic unchanged"
holds only because of this rule.

**Selection restore on phone reconnect.** The anchor's per-connection
selection dies with the socket, and `handleHello` always sends the anchor's
own snapshot after `hello_ok` — so a phone that was viewing B, drops its WS
(background suspension is the norm), and reconnects, would silently land on
the anchor session while the picker still marks B. Rule: the phone keeps
`selectedId` in memory (not across app launches); after `helloOk`, if
`selectedId` is set, it re-sends `select_session(selectedId)`. The phone
briefly rebinds to the anchor (hello snapshot) then back to B (proxy
snapshot) — double rebind is harmless (each just clears items). Across an app
launch, selection resets to the anchor session (documented default view).

- Unknown/stale `id`: if the id is **not in the registry at all** (e.g.
  phone connected to a different box via the recent-connections list), reply
  `{type:'error', code:'session_not_found'}` immediately — no probe (there
  is no port to probe). If the id IS in the registry: anchor TCP-probes the
  entry's port, **prunes it synchronously** if dead (does not wait for the
  next prune cycle), then selects it or replies `session_not_found`; either
  way the refreshed `sessions` list is re-broadcast.
- **`session_not_found` with `id == selectedId` clears `selectedId`** on the
  phone (picker unmarks, no banner — the refreshed `sessions` list is the
  state). This is the restore path's failure frame (entry pruned or
  never-existed); without it the picker would keep marking a dead session
  while the transcript shows the anchor — the exact desync the restore rule
  exists to kill.
- Select ack semantics: the arriving sibling snapshot (or the anchor
  snapshot, for the anchor entry) IS the ack — no separate ack frame. If no
  snapshot arrives within 10 s (proxy open stalled, sibling wedged), the
  phone shows a non-destructive "connecting to session…" toast and keeps the
  selection pending; a further 10 s with nothing → the phone behaves
  **exactly as if it had received `session_not_found` for the pending id**
  (same clear, same list state; no invented local-only code path). The
  anchor side times out the proxy open at 10 s and closes it (sending the
  real `session_not_found`).
- Sibling goes away mid-selection (its proxy socket dies): anchor sends the
  phone a top-level `{type:'session_gone', id}` frame + refreshed `sessions`
  list; the phone shows a non-destructive `failed`-style banner and clears
  the selection (picker shows nothing selected, transcript frozen).
- When the phone disconnects: anchor closes **all** proxy connections.
- **Question catch-up**: on proxy connect the sibling re-sends its pending
  ask (existing `handleHello` behavior) — a question raised while the session
  was unselected appears on selection, and the list badge (`hasQuestion`)
  covered it before that.

### Proxy connection lifecycle (anchor side)

- Opened lazily on `select_session` (Decision 6); one at a time; closed on
  re-select, phone disconnect, or sibling death. Reconnects on re-select
  (snapshot re-fetch; last-200 history makes this cheap).
- **Keepalive**: anchor sends a JSON `ping` (same shape as the phone's;
  NOT a WS-level ping — the phone↔anchor path never uses WS-level pings) on
  the proxy socket every 30 s (independent of phone traffic) so the
  sibling's `STALE_MS` (90 s) stale close never fires on a selected-but-idle
  session. The sibling answers with `{type:'pong'}`; **the proxy reader
  swallows `pong`** — it is not in the forward list, and the anchor neither
  forwards it to the phone nor toasts on it.
- Proxy auth failure (stale token, e.g. sibling re-registered): the anchor
  keeps the selection **pending**, re-reads the entry **at probe time** (not
  at failure time — the token may have landed in between), and re-probes on
  the NEXT registry change event for that entry (not a fixed retry count).
  Bounded by the 10 s select timeout above (→ `session_not_found`).
- **Rate-limiter interaction**: a failed sibling `hello` increments the
  sibling's per-IP limiter keyed `127.0.0.1` — 5 stale-token failures would
  lock out ALL proxy connects to that sibling for 60 s. Fix: the sibling's
  `recordFailedHello`/lockout check exempts loopback source IPs
  (`127.0.0.1`/`::1`) — the limiter exists for tailnet strangers; the only
  loopback client is the machine itself.
- **Proxy as authenticated client — accepted side effects** (documented,
  no action): the proxy counts in the sibling's `connectedClientCount`, so
  while selected the sibling's `askAvailable()` is true and its TUI routes
  questions to the phone (Esc-hatch "Press Esc to answer locally" now also
  depends on phone-side selection — consistent with today's
  connected-phone semantics). Proxy hellos and phone hellos take the same
  `handleHello` code path (Decision 3's "one auth implementation to audit"
  holds literally).

### Sibling process changes

- On `/rc` enable: try 47800 (tailnet) → else bind `127.0.0.1` on 47801-47899
  (first free; port recorded in the registry entry). Either way: register
  entry, start serving. The EADDRINUSE warning text changes: siblings are the
  normal case now, not an error.
  - **Port range exhaustion** (all 99 ports taken — pathological): degrade to
    "no server" + terminal notify (same shape as today's EADDRINUSE message);
    the process still runs, just unregistered.
- Status write points (all debounced): streaming start/stop (existing
  `isStreaming` tracking), pending ask set/clear, compact start/finish,
  `session_start`/`session_shutdown` (sessionId/name/cwd/model), `set_model`,
  rename. **`hasQuestion` must be computed as "pendingAsk exists AND its
  sessionId == current sessionId" at every session-change write point** —
  pre-existing wart (out of scope, frozen Decision 7 territory): nothing
  cancels `pendingAsk` on in-process session replacement, so an unselected
  sibling that did `/new` keeps a stale ask (re-sent on every proxy open,
  invisible to the phone thanks to the sessionId guard); the badge must not
  stay lit for it.
- `/rc` disable: remove entry, close server. Process exit: remove entry
  (`process 'exit'` hook, alongside the existing quit-auth write).
- Push: **unchanged per process** — each session pushes its own finished/
  question APNs notifications to the phone (token shared machine-wide).
  Decision 9 changes only the collapse ids:
  `collapseId = <kind>:<sessionId>` (e.g. `finished:<sessionId>`),
  `thread-id` unchanged (already = sessionId, coherent with the per-session
  collapse groups). `apns.ts` payload builders gain a session-scoped
  collapse id; the fixed constants go away for multi-session-capable builds.
  (This bullet's wire changes are the collapse id + the custom `sessionId`
  key below; the token-resolution fix below is independent of both.)
  Within one session the dedupe the finished-push relies on ("latest settle
  wins") is preserved — same collapse id per session.
- **Token resolution per push (N1)**: `pushToken` is currently loaded ONCE at
  singleton creation (`readStoredDeviceToken()`) — but the default setup flow
  is "start 2-3 sessions, then pair the phone": a sibling that started before
  pairing would otherwise have `pushToken = null` forever (the phone talks
  only to the anchor, and the proxy hello carries the entry token, not the
  push token), so it could never push. Fix: resolve the device token from
  `rc-push.json` **at each push**, mirroring `resolveApnsConfig()` (which
  already re-reads the same file per use). The file is the single source of
  truth the anchor updates on every `push_token`. (Relaying `push_token`
  through the proxy is the wrong fix: unselected siblings have no proxy.)
- **Deep-link payload key (wire change)**: today both payloads carry ONLY
  `aps.{alert, sound, thread-id[, timeSensitive]}` — iOS does not expose
  `thread-id` to the app, so the tap handler cannot resolve a session from
  it. Add a custom top-level `"sessionId": <pi session id>` key to BOTH
  payload builders (question + finished); the Swift side reads it from
  `userInfo` and matches against the `sessions` list by `sessionId` (then
  sends `select_session` with the matched entry's registry `id`).

### Phone (Swift) changes

- **Models**: `SessionInfo` (registry entry as broadcast); `CodeEvent` gains
  `.sessions([SessionInfo])` and `.sessionGone(id:)` (top-level frame, NOT an
  error code); `CodeClientMessage` gains `selectSession(id)`; error code
  `session_not_found`.
- **ViewModel**: holds `sessions: [SessionInfo]` + `selectedId` alongside the
  existing single `SessionState` (the view stays single-view, Decision 10).
  - `.sessions` → refresh list (badges: streaming, question, compacting,
    anchor tag).
  - Select tap → send `selectSession(id)`; the arriving snapshot rebinds the
    existing `SessionState` (rebind logic unchanged — the anchor-side
    suppression rule is what keeps it true; see §Wire protocol).
  - After `helloOk` (fresh connect or WS reconnect): if `selectedId` is set
    in memory, re-send `selectSession(selectedId)` (selection restore;
    §Wire protocol). `selectedId` is cleared on app launch and on
    `session_gone`.
  - While a sibling is selected, prompt/steer/abort/answer/command frames go
    to the anchor as today — the anchor forwards; the client is
    proxy-transparent (no client-side routing).
- **UI**: toolbar "sessions" button in `CodeSessionView` (file is already
  over the 500-line warn threshold — new views in separate files per the
  commands_ui memory) → sheet: list rows (name, cwd basename, model, badges,
  anchor tag), tap to select + dismiss; current selection marked. Disabled
  while disconnected.
- **Notifications**: tap deep link resolves `sessionId` from the custom
  payload key (see §Sibling process changes — new wire field). **Match by
  `sessionId` (pi id) against the in-memory `sessions` list and map to the
  registry `id` AT TAP TIME** — and **write `selectedId` immediately**,
  pre-empting the restore re-send (otherwise both the restore
  `select_session(selectedId)` and the tap's select fire after one
  `helloOk` and the last frame wins — the phone could land on the old
  selection instead of the tapped session):
  - tapped session in the list → `selectedId` = its registry id; then:
    - **connected**: select it (send `selectSession`; no-op if it is the
      already-selected anchor session). `handleNotificationTapped` currently
      early-returns when state is `.connected` (CodeViewModel.swift:310) —
      the deep link must override that early return, or the tap is a no-op in
      the common (already-connected) case.
    - **disconnected/connecting**: reconnect first (existing `lastConnect`
      path); the post-`helloOk` restore re-send is now a duplicate of the
      tap's select (same `selectedId`) and needs no separate tap logic.
  - tapped `sessionId` absent from the current `sessions` list → keep the
    existing `selectedId` (no restore pre-emption) and show a non-destructive
    "session no longer exists" banner.
  - **Cold-launch taps**: `pendingNotificationTap` is a bare boolean with no
    payload (AppDelegate → HomeView → VM), and the tap handler itself cannot
    reconnect (it guards on `lastConnect`, which a fresh VM lacks) — the
    reconnect that happens is the app-level auto-connect via the persisted
    recent-connections list. A cold-launch tap therefore cannot select; it
    just re-establishes the connection — documented, consistent with the
    documented default (selection is not across launches).
  Push-notification handling lives in
  `CodeBackgroundUseCase`/`RemoteNotificationManager` — extend the existing
  background-relay path rather than adding a new extension.
- **SettingsManager/recent connections**: unchanged (host:port of the anchor
  per box; the anchor is the only address the phone needs for a box).

### Out of scope (explicit)

- Spawning/killing pi processes from the phone (Decision 8).
- Multiple phones / multi-device pairing (existing single-token
  last-writer-wins limitation, pre-existing).
- Active anchor failover, anchor rebinding races (Decision 4).
- Standing anchor→sibling subscriptions (Decision 6).
- Session resume/picker across the file store (rc-commands Decision 2
  exclusion still stands).
- macOS target (per AGENTS.md, low priority).

### Testing

Follow `specs/testing.instructions.md`; mirror the existing rc test seams:

- **Registry**: unit tests for read/write/prune (tmp dir via `PI_RC_REGISTRY`):
  **concurrent-writer freshness** — two-writer interleaving (A writes status,
  B writes status concurrently, then A writes again): assert A's LATEST value
  survives B's write (the merge-on-write rule); entry existence alone must NOT
  be the assertion (that passes for the naive bug too); prune writes only on
  change (diff-before-rename); dead-pid pruning with the TCP probe
  authoritative (reused-pid case: live pid, dead port → pruned); anchor
  self-exclusion (its own non-loopback-bound entry is kept unprobed while a
  dead sibling in the same pass is pruned); atomic-write corruption recovery
  (invalid JSON → write ABORTED, value retained, retried on next change, logged —
  never merged into an empty read).
- **Anchor proxy** — **MANUAL (owner test, 2026-09-13): the automated 2-child
  harness was dropped as out-of-budget (worker runs on it blew the turn/time
  budget); the checklist below is what the owner verifies by hand** with two
  rc-enabled pi processes on one box (first child wins 47800 = anchor,
  second = loopback sibling; sibling port read from the registry file, never
  hardcoded): phone→anchor→sibling prompt round-trip; select
  switch A→B→A; **anchor-frame suppression** — while B is selected, trigger a
  `model_select`/compact on the anchor child and assert NO non-B `state`/`event`
  frame reaches the phone client (and the phone's effective session is
  unchanged); **selection restore** — connect, select B, close the phone
  socket, reconnect, assert `select_session(B)` re-sent after `hello_ok` and
  the phone ends on B; **proxy keepalive** — selected-but-idle sibling
  survives >90 s (proxy not stale-closed); sibling kill mid-selection →
  `session_gone` + refreshed list; phone disconnect closes proxy; proxy auth
  with entry token; **loopback rate-limiter exemption** — 5+ failed proxy
  hellos from 127.0.0.1 do not lock out subsequent good hellos; unknown id →
  `session_not_found` + synchronous prune (dead row disappears from the
  broadcast list immediately, not on the next poll); id not in registry at
  all → `session_not_found` with NO probe; **sibling `pong` is never
  delivered to the phone** (proxy keepalive is invisible to the phone);
  **anchor `error` broadcast (e.g. `compaction_failed`) is suppressed while a
  sibling is selected**;
  **stale pendingAsk badge** — sibling does `/new` while unselected, then a
  fresh registry status write asserts `hasQuestion` false (N5).
- **Wire**: `sessions` frame broadcast on registry change (debounced);
  `select_session` for anchor session needs no proxy; `sessions` delivered in
  the `.reconnecting`→`.connected` window as well.
- **APNs**: collapse id is `<kind>:<sessionId>` (pure-function tests on the
  payload builders); custom `sessionId` key present in BOTH question and
  finished payloads (same tests).
- **Swift**: ViewModel tests — list refresh, select sends frame, rebind on
  snapshot, `session_gone` banner path, helloOk→select re-send,
  `session_not_found`(id==selectedId) clears selection (no banner),
  deep-link select (including the already-connected tap, i.e. overriding the
  `.connected` early return in `handleNotificationTapped`; and the tap-
  pre-empts-restore race: tapped C ≠ selectedId B → lands on C) (existing
  test harness per testing spec).
- **Push (manual, same 2-process setup as above)**: sibling push with a token registered AFTER the sibling
  started (the default setup flow) — assert the sibling's finished/question
  push fires once the token lands in `rc-push.json` (N1 regression).
- Harness notes: children need isolated envs (`PI_RC_REGISTRY`,
  `PI_RC_APNS_CONFIG`, `PI_RC_AUTH_FILE` already exist as seams; existing
  harness binds 127.0.0.1 via `PI_RC_BIND`). Start order pins the anchor
  (first child wins 47800); the sibling's dynamic port is read from the
  registry file, never hardcoded.

### Implementation sketch (order)

1. Registry module (new file `pi-extensions/rc/registry.ts`): read/merge-write/
   prune + status debounce + env seam.
2. Sibling role: `/rc` enable binds 47800-else-loopback; entry lifecycle
   hooks; `handleHello` accepts the own entry token as third credential;
   status write points; loopback rate-limiter exemption.
3. Anchor: registry watch+poll + `sessions` broadcast; `select_session`
   handler + proxy connection (hello with entry token, frame forwarding,
   keepalive pings, per-connection selection + own-frame suppression,
   lifecycle).
4. APNs per-session collapse ids + custom `sessionId` payload keys.
5. Swift: models/frames, ViewModel list+select+restore, picker sheet UI,
   deep-link select (incl. connected-tap override).
6. Unit tests per §Testing (the 2-child anchor-proxy harness is a manual
   owner test — see §Testing; automated harness dropped 2026-09-13).

Spec status note: `docs/plans/rc-remote-control-spec.md` Decision 3 should
get a superseded marker ("multi-session part superseded by
rc-multi-session-spec.md 2026-09-11") when the spec lands.

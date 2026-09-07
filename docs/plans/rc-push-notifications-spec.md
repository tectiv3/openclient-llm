# Plan: RC push notifications (APNs)

Status: design agreed (revised after plan-critic review) — implemented.
Date: 2026-09-07. Supersedes the parent spec's open item "APNs-based push
notifications are future work".
Parent: `docs/plans/rc-remote-control-spec.md`

## Goal

Notify the iOS phone via APNs when (1) the agent finished (`agent_settled`) and
(2) the agent has a pending question/`ask()`, in the background/suspended state
(user switched apps or locked the phone). The existing local-notification path
(parent spec B1) only reaches the user within the ~30 s background-task window;
APNs push covers the suspended case.

## Decisions

| # | Decision | Chosen |
|---|----------|--------|
| 1 | Delivery path | APNs **direct from the pi rc server** (not a Casa/relay proxy). APNs is a public HTTPS/HTTP2 endpoint; the rc server needs only outbound egress, which it already has (LLM calls). Rejected: local notifications only (dead after the ~30 s background window — the case this feature targets); silent push (content-available) to wake the app (throttled by Apple for battery, unreliable); Casa proxy (extra hop, no benefit — Casa would only be for the app, not for pushing to the app) |
| 2 | Trigger points | `agent_settled` → "Agent finished" (normal); `ask()` creating a remote question → "Agent has a question — answer needed" with `timeSensitive`. Push bodies identify the session/task (user decision 2026-09-07, revising v1): finished pushes carry the session name → cwd basename → fixed fallback (pi-side metadata, never agent text); question pushes carry the question's own text — verbatim when ≤80 chars, LLM-shortened via OpenRouter (or hard-truncated, 100-char cap) when longer; see the Payload section for the documented invariant relaxation. Only when a token is registered, **the session is in an interactive mode (`tui`/`rpc`)**, **and `/rc` is enabled** (the finished push checks `isServing()`; question pushes get the same gate transitively via `askAvailable`). Pushes follow the `/rc` toggle — rc off means zero push traffic |
| 3 | Server impl | Node stdlib only (constraint preserved): `node:http2` + `node:tls` for APNs HTTP/2 over TLS, `node:crypto` for a per-send ES256 JWT (5-min TTL) from a P-256 key parsed out of a `.p8` PEM file |
| 4 | Config | Env vars on the pi machine (`PI_RC_APNS_*`) or `~/.pi/agent/rc-push.json` (written by the `/rc push-setup` command, chmod 600, holds team id + key id + key path + APNs host — never key contents; the singleton also maintains a runtime `token` field there); env overrides config file. Nothing committed. Push is **disabled** (no-op, single log line) unless key file + team id + key id are all set; all other RC features unaffected |
| 5 | Protocol | Additive: one new client→server message `push_token`. **No new server→client messages** — pushes go via APNs, never over the WS |
| 6 | Token lifetime | **Singleton-persistent**: the last-registered token wins and is kept on the pi-rc singleton (globalThis state, consistent with the existing RC singleton's `clients`/streaming state). Survives client disconnects and process-suspension churn on the phone. This is what makes pushes work for the **full phone-suspension lifetime**: by then the WS is dead and the client's reconnects may be exhausted, so a per-connection token would be long gone before the push is triggered. Accepted trade-off: a tailnet client running the current client code could register *its own* device token and replace the stored one — but APNs device tokens are per-device, so this **redirects pushes only** (and the payload carries no agent/user text, so there is nothing sensitive to leak) |
| 7 | iOS app | Push capability + Time Sensitive Notifications entitlement; `registerForRemoteNotifications` at app init; notification authorization requested contextually on first RC connect (not at launch). Push registration code is `#if os(iOS)` — macOS target must compile, macOS gets no push |
| 8 | Foreground behavior | `UNUserNotificationCenterDelegate.willPresent` returns `[]` (suppress) only while the RC session is `.connected` — the in-app UI already shows the question modal / settled state, so a foreground banner would be a duplicate. When the app is foregrounded but the session is down (`.failed`/`.disconnected`/`.connecting`), the in-app UI shows nothing, so it returns `[.banner]` instead of silently dropping a `timeSensitive` push |

## Wire protocol (additive)

The RC protocol is frozen against the strict-Codable Swift client; this is a
purely additive change (new message type, no field/shape changes).

Client → server (new):

```json
{ "type": "push_token", "token": "<apns-device-token-string>" }
```

- Sent by the Swift client **after** `hello_ok` (the server rejects any
  non-`hello` message before authentication, so it can only be sent
  post-hello), and re-sent after every reconnect's `hello_ok`.
- **Token-arrival ordering**: the device token can arrive **after** `hello_ok`
  (first launch: `registerForRemoteNotifications` at app init, the auth prompt
  fires on first RC connect, and the OS delivers the token seconds later).
  Therefore the client sends `push_token` **whenever the token first arrives
  or refreshes while a session is connected**, not only on `hello_ok`.
- Server: stores `pushToken` on the **RC singleton** (new optional field next
  to `clients`/`isStreaming` on the globalThis-backed state), **last-registered
  wins**, and it **persists across client disconnects**. Validation: a valid
  APNs device token is a **64-character hex string**; anything else (wrong
  type, wrong length, non-hex) is ignored silently — no error close, no crash,
  connection continues. Stored but unused when the APNs module is
  unconfigured.
- Server: no response. `hello_ok`, state, history, and all other messages are
  unchanged.

Swift side: new `CodeClientMessage.pushToken(token: String)` case + one
`encodeMessage` branch emitting the frame above. **No `CodeEvent` change** —
there are no new server→client frames, so the frozen decode side is untouched.
`CodeViewModel` sends `.pushToken(token:)` in two places: (a) on `.helloOk`
if a token is already known (covers initial connect and every auto-reconnect),
and (b) when the `didRegisterForRemoteNotifications` token handler fires while
the session is connected (covers token arrival/refresh mid-session).

## Server implementation (`pi-extensions/rc/`)

- New `pi-extensions/rc/apns.ts` (or a section of `index.ts`; jiti loads the
  directory, relative imports work) — **Node stdlib only**: `node:http2`,
  `node:tls`, `node:crypto`, `node:fs`.
- **JWT ES256, signed per send, 5-min TTL**: header
  `{ "alg": "ES256", "kid": KEY_ID }`, claims `{ iss: TEAM_ID, sub: KEY_ID,
  aud: "apns", iat: now, exp: now + 300 }` (APNs rejects a JWT missing `kid`
  in the header, `sub`, or `aud: "apns"`). Key object from
  `crypto.createPrivateKey({ key: <p8 PEM>, format: "pem", type: "pkcs8" })`
  (P-256); signature via `crypto.sign("sha256", data, { key: p256Key,
  dsaEncoding: "ieee-p1363" })` — the `dsaEncoding` option is REQUIRED: Node's
  default for EC keys is DER (~71 bytes, verified), which APNs rejects; IEEE
  P-1363 yields the raw R||S (64 bytes) format APNs expects for ES256.
  Base64url parts.
- **Send**: APNs speaks HTTP/2 **over TLS** — connect with `tls.connect` to
  the authority (default `api.push.apple.com:443`), then `http2.connect` on
  that socket; plaintext h2 is not acceptable. `POST /3/device/<token>` with
  headers `authorization: Bearer <jwt>`, `apns-topic`, `apns-priority: 5`,
  `apns-timestamp`, and (always) `apns-collapse-id`:
  - finished push → constant `rc-finished` (see triggers — collapses
    duplicates from one agent run)
  - question push → constant `rc-question` (a stale question push is
    replaced by a newer one)

  `apns-notification-traversal` is **not** used. Cache one h2 session per
  authority; recreate on error.
- **Config** (env vars or `~/.pi/agent/rc-push.json` via `/rc
  push-setup` — see the `/rc push-setup command` section; env overrides
  the config file; push disabled unless all three of key file / team id /
  key id are set — log once "APNs push disabled (missing PI_RC_APNS_*)",
  every other RC feature unaffected):
  - `PI_RC_APNS_KEY_FILE` — path to the `.p8` private key (never committed)
  - `PI_RC_APNS_TEAM_ID`
  - `PI_RC_APNS_KEY_ID`
  - `PI_RC_APNS_TOPIC` — app bundle id, default `com.kinchaku.openclient-llm`
    (must match the app's `PRODUCT_BUNDLE_IDENTIFIER` exactly)
  - `PI_RC_APNS_HOST` — default `api.sandbox.push.apple.com:443`;
    overridable (e.g. `127.0.0.1:8443`) for the test harness. Sandbox is
    the default because this project's builds are development-signed:
    their device tokens are sandbox tokens, and the production endpoint
    rejects them (400 `BadDeviceToken`) while the sandbox endpoint
    accepts both sandbox and production tokens. (Observed directly
    against APNs, 2026-09-07: identical token → 400 on production, 200
    + `apns-id` on sandbox; the rejection reason arrives in the JSON
    response body `{"reason": ...}`, not only the `apns-reason` header.)
- **Triggers** (only when the singleton holds a token, and only in
  interactive mode — `tui`/`rpc`; subagent `json`/`print` children never
  push, see INV1 in `specs/pi-extensions-remote-ask.instructions.md`):
  - `agent_settled` (inside `trackEvent`, which already toggles
    `isStreaming`) → push "Agent finished". **Gate**: skipped when `/rc` is
    not enabled (`isServing()` false) — pushes follow the `/rc` toggle, the
    same gate question pushes get via `askAvailable`. **Firing frequency**:
    this fires
    turn — normal completion and every follow-up turn, but NOT aborted
    turns (the 2026-09-07 abort gate: `message_end`/`turn_end` carrying
    `stopReason: "aborted"` suppresses the finished push — the user
    cancelled, so "finished" would be a lie) — and additionally the
    question tool's own turn settles again after
    the user answers, so a single ask/answer cycle can produce up to **3**
    settles. Hence the finished push uses the **constant**
    `apns-collapse-id: rc-finished`: APNs discards the in-flight duplicates
    and only the latest is delivered. This is deliberate — the decision to
    collapse is explicit, not incidental.
  - `ask()` creating a pending remote question → push "Agent
    has a question — answer needed", payload carries `timeSensitive: true`,
    collapse-id `rc-question`. (The ask_user_question tool gates on the rc
    singleton's `askAvailable()` — serving AND (clients connected OR push
    sendable) — so this fires exactly when the remote modal would show or
    would be pushed to a locked phone.)
- **Payload** (minimal, < 4 KB, no secrets, no full paths). Bodies identify
  the session/task (user decision 2026-09-07 — supersedes v1's "bodies are
  fixed strings" rule; see the relaxation note below):

```json
{
  "aps": {
    "alert": { "title": "Agent finished", "body": "<session name | cwd basename>" },
    "sound": "default",
    "thread-id": "<sessionId>"
  }
}
```

  - Finished push: title "Agent finished". Body = the session name
    (`sessionManager.getSessionName()`), falling back to the cwd basename
    (`sessionManager.getCwd()` — a single directory name, not a path),
    falling back to the fixed string "Agent finished". Whitespace-collapsed,
    capped at 80 chars (hard truncate + ellipsis). Server-side metadata
    only — never agent output.
  - Question push: title "Agent has a question". Body = the first question's
    prompt (ALL asks — the 2026-09-07 protocol collapse left no per-kind
    split), sanitized (control chars stripped, whitespace runs collapsed to
    single spaces); ≤80 chars ships verbatim;
    longer text is shortened via one OpenRouter chat completion, and on ANY
    LLM failure or timeout the deterministic fallback hard-truncates the
    original (100-char cap including a trailing ellipsis). Plus
    `"timeSensitive": true` in `aps`. If the pending ask is answered,
    cancelled, or superseded while the body resolves (LLM shortening can
    take up to the timeout), the push is dropped — a "has a question" alert
    for a dead question would be wrong.
  - **Invariant relaxation (user decision 2026-09-07)**: v1's "no agent- or
    user-controlled text in any push payload" is DELIBERATELY RELAXED for
    question pushes only — a question push without the question text is
    near-useless on a lock screen. Exposure is bounded: question text only
    (never agent prose), capped at 100 chars, control/format-char-free,
    whitespace-sanitized. Finished pushes keep the invariant: the session
    name and cwd basename are pi-side metadata, not agent/user text.
  - **Shortening LLM (question pushes only, only when text >80 chars)**:
    Node stdlib only (global `fetch` + `AbortController`, Node 24). Model
    `minimax/minimax-m3:free`, env override `PI_RC_TITLE_MODEL`. Base URL
    default `https://openrouter.ai/api/v1`, env override
    `PI_RC_OPENROUTER_URL` (test seam). Timeout default 3500 ms, env
    override `PI_RC_TITLE_TIMEOUT_MS` (test seam). API key from
    `OPENROUTER_API_KEY` (already present on the pi machine — no new
    setup). Finished pushes never call OpenRouter; with the key absent or
    the call failing, question pushes fall back to deterministic
    truncation and behave identically otherwise — the dependency is
    strictly optional.

Question push: title "Agent has a question", body = the question text per
the rules above (fixed fallback "Agent has a question — answer needed" when
no text can be extracted), plus `"timeSensitive": true` in `aps`.
There is **no `rc-session` (or any other) custom payload field in v1** — the
earlier draft's deep-linking field is dropped as dead weight; it comes back,
if at all, with v2 deep-linking. (`thread-id` is the server-generated session
id, not user content, and only threads notifications.)

**Token storage**: the singleton keeps one `pushToken`; last write wins. This
is a deliberate narrowing of the parent spec's multi-client broadcast model:
pushes are ambient alerts, not the question-answer channel, so one phone gets
one push. The accepted trade-off (Decision 6): a tailnet client with the
current code could replace the token and redirect pushes to its own device —
harmless in practice because the payload carries only session identity and,
for questions, capped sanitized question text (nothing beyond that to leak).

## /rc push-setup command

Explicit setup command alongside the `/rc` toggle. Replaces the
env-var-export step as the primary way to configure push on the pi
machine (env vars remain supported — see config precedence below).

- **Registration**: the existing `pi.registerCommand('rc', ...)` in
  `pi-extensions/rc/index.ts`. Its handler has signature
  `(args: string, ctx) => Promise<void>` and currently ignores `_args`
  (pure toggle). Add a branch inside the same handler:
  `args.trim() === 'push-setup'` → run the setup flow; any other args
  keep the existing toggle behavior (a bare `/rc` still toggles).
  Optional: `getArgumentCompletions` suggesting `push-setup`.
- **What it collects** — four prompts, in order: (1) APNs Team ID,
  (2) APNs Key ID, (3) the FILE PATH to the `.p8` private key,
  (4) the APNs `host:port` (empty answer takes the sandbox default).
  **Never prompt for key contents** — ask() answers transit the WS and
  land in the pi session transcript, so anything prompted for becomes
  session content; only IDs and a path are ever asked.
- **Prompt transport** (dual path; remote branch uses the unified
  `ask_user_question` shape — `kind: 'question'` is rejected by the rc
  server as `unknown_question`):
  - If `rc.isServing() && rc.hasConnectedClients()` →
    `rc.ask({ kind: 'ask_user_question', params: { questions: [{ id: 'q1',
    prompt: title, options: [] }] } })` (free-text entry via the phone's
    question modal; empty `options` + a typed answer); each answer comes
    back as `{ id, value, label, wasCustom, index? }`, the flow takes
    `answers[0]`, or `null` on cancellation/abort. Confirms pass a
    two-option question (`Yes, continue` / `No, cancel`) and check
    `value === 'yes'` (custom answers are lowercased first).
  - Otherwise → TUI `ctx.ui.input(title)`; returns a
    string or `undefined` (confirm branch: `ctx.ui.confirm`).
  Both paths surface cancellation as a nullish result.
- **Validation** (per value, immediately when it arrives; an invalid
  value re-asks the same question, with the precise reason):
  - Team ID and Key ID: exactly 10 alphanumeric characters
    (`/^[A-Za-z0-9]{10}$/`).
  - Key file path (expand a leading `~`): file exists and is readable;
    parses via `crypto.createPrivateKey({ key: <pem>, format: 'pem',
    type: 'pkcs8' })` as a P-256 EC key; and a test signature of a
    fixed buffer via `crypto.sign('sha256', buf, { key,
    dsaEncoding: 'ieee-p1363' })` yields exactly 64 bytes. (Same
    ES256/IEEE-P1363 trap as the JWT path above: Node's default DER
    encoding would pass a naive parse but is rejected by APNs.)
  - Cross-check: if the key file's basename matches
    `AuthKey_<KEYID>.p8`, compare the embedded KEYID against the
    entered Key ID; on mismatch, confirm via one more prompt (remote
    question or TUI confirm) — do not silently accept.
- **Persistence**: `~/.pi/agent/rc-push.json`, written `chmod 600`
  (same pattern as the rc auth-file writer: write to a temp file in the
  same directory, `rename` over the target — atomic, and only after
  all three values are validated):

    { "teamId": "<TEAM_ID>", "keyId": "<KEYID>", "keyFile": "<path to AuthKey_<KEYID>.p8>",
      "host": "api.sandbox.push.apple.com:443" }

  (placeholder values, not real IDs). The singleton also maintains a
  `token` field in the same file at runtime: the last-registered device
  token, written on registration (so a fresh pi session is push-ready
  before the phone reconnects) and deleted on exact-token 410 — both via
  the same atomic 0600 write, merge-preserving the other fields.
- **Config precedence** (the APNs module resolves config on every use):
  env vars `PI_RC_APNS_TEAM_ID` / `PI_RC_APNS_KEY_ID` /
  `PI_RC_APNS_KEY_FILE` / `PI_RC_APNS_HOST` (when set) **override** the
  config file, field by field; a missing host falls back to the sandbox
  default. `PI_RC_APNS_CONFIG` overrides the config file path itself — a
  test seam so the harness can isolate its child from the user's real
  file (mirrors `PI_RC_AUTH_FILE`).
- **Output**: a confirmation summarizing the effective source per
  value (env vs config file) and the validation results, or the
  precise failure reason. If push is already fully configured, report
  the current source (env vs `rc-push.json`) up front and offer
  re-entry, which rewrites the config file (env vars are not
  modifiable by the command).
- **Failure / cancellation handling**: any `null` answer (cancel on
  either transport, or `rc.ask()` returning `null` because the phone
  disconnected / the server stopped) → print a short guidance line
  (what `/rc push-setup` expects, where the `.p8` lives) and exit.
  **No partial writes**: the config file is written exactly once,
  after all three values are collected and validated (atomic
  temp-file + rename).

## iOS app

- **App ID entitlements**: Push (already present:
  `openclient-llm/Resources/openclient-llm.entitlements` has
  `aps-environment: development`) + **Time Sensitive Notifications — NOT yet
  present**. Steps:
  1. Add `com.apple.developer.usernotifications.time-sensitive` (boolean
     `true`) to `openclient-llm/Resources/openclient-llm.entitlements`.
  2. **Regenerate / re-download the provisioning profile** — the key must be
     granted in the App ID *and* carried by the profile, or signing/build
     fails.
  3. `aps-environment` flips to `production` for release (App Store) builds.
     **To be confirmed**: how the existing app build handles
     development-vs-production (separate entitlements file or build-setting
     swap) — verify before shipping a release build.
- `registerForRemoteNotifications()` at app init; the device token is handed
  to `CodeViewModel` (new callback/handler). Because first-launch token
  arrival can postdate `hello_ok` (and tokens can refresh later), the handler
  sends `push_token` immediately whenever a token arrives/refreshes while a
  session is connected, in addition to the `hello_ok` path.
- Authorization (`UNUserNotificationCenter.requestAuthorization(
  options: [.alert, .sound, .timeSensitive])`) requested **contextually on
  first RC connect** (when the user taps Connect on the Code tab), not at
  launch — notifications are an RC feature.
- `UNUserNotificationCenterDelegate` (app delegate):
  - `willPresent` → return `[]` (suppress) only while the Code VM state is
    `.connected` (the session view already shows these events over the
    WebSocket); return `[.banner]` otherwise — when the app is foregrounded
    but the session is down (failed/disconnected screen), nothing in-app
    indicates the push, so a silently dropped `timeSensitive` question push
    would be invisible.
  - `didReceive` (responseAction / default open) → tap-to-reopen: the app
    **always initiates a reconnect via `lastConnect`**, regardless of
    `backgroundDisconnected`. This is required, not a nice-to-have —
    verified in `CodeViewModel+Background.swift`:
    `handleAppWillEnterForeground` only auto-reconnects when
    `backgroundDisconnected == true` (set solely by the background-task
    expiry path), and the **burn-out path** (`CodeServerClient` exhausting
    `maxReconnectAttempts` → `.connectionFailed` → VM `.failed`) does **not**
    set it. That is precisely the long-suspension case this feature targets:
    the WS is dead, reconnects are exhausted, the VM sits in `.failed`, and a
    normal foregrounding pass would never reconnect. The pairing code remains
    valid for the server's lifetime, so `lastConnect` (in-memory
    host/port/code) is still sufficient to re-establish the session.
    Accept (separate case): if the process itself was **killed** in the
    background, `lastConnect` is gone (it is in-memory only) and the user
    re-enters the 6-digit code; the push still served its purpose of opening
    the app to the connect screen.
    Implementation: the delegate sends `CodeViewModel.Event.notificationTapped`,
    which bypasses the `.disconnected`/`backgroundDisconnected` guards of the
    foregrounding pass and re-establishes from `lastConnect` (a no-op while
    `.connected`/`.connecting`). If no VM exists yet (cold launch), the tap
    is flagged pending and forwarded to the fresh VM, where it is a safe
    no-op (no in-memory `lastConnect`).
- Existing `LocalNotificationManager` (local notifications during the ~30 s
  background window) stays as-is; APNs push is a superset that also covers
  suspension.
- macOS: everything guarded by `#if os(iOS)`; both schemes must build.

## Verification plan

1. **Node harness** (`pi-extensions/rc/test-client.mjs`, new group 12). Note:
   it **runs its own connect after group 11's lockout wait** (group 11
   poisons the shared 60 s rate-limit counter, which must not bleed into
   groups 1–10) and **registers its push assertions before the LLM wait**. A
   local HTTP/2 server (self-signed cert) stands in for APNs via
   `PI_RC_APNS_HOST` + a generated throwaway P-256 `.p8`. The fake endpoint
   is trusted because the **harness sets `NODE_EXTRA_CA_CERTS` for the
   spawned pi process** (the harness owns the child's environment) — no CA
   config option is invented in the extension. Assert:
   - `agent_settled` → one request; headers (`apns-topic`,
     `apns-priority: 5`, `apns-timestamp`, `apns-collapse-id: rc-finished`,
     Bearer JWT with **valid ES256 signature** and claims
     `{iss: team, sub: keyId, aud: "apns", iat, exp}`, header
     `{alg: "ES256", kid: keyId}`) and payload shape: title "Agent
     finished", body = the finished-identity chain (in the harness, the
     basename of the child's cwd — the session is never named).
   - `ask()` → one request; `timeSensitive: true` +
     `apns-collapse-id: rc-question`; body = the question text: verbatim
     when ≤80 chars (and the shortening LLM — pointed at a recording mock
     via `PI_RC_OPENROUTER_URL` — is never called), the canned mock
     completion when longer, and the deterministic 100-char truncation
     when the LLM is unreachable (`PI_RC_TITLE_TIMEOUT_MS` small).
   - Connected client with **no** `push_token` → zero requests.
   - APNs env **unset** → zero requests, all other RC tests still pass.
   - **Invalid token** (`push_token` with a non-64-hex / malformed token) →
     ignored: no crash, no connection close, subsequent valid messages
     still served, and no push attempted with the bad token.
   - Token survives a client disconnect/reconnect (singleton-persistent);
     a second registration replaces it (last write wins).
   - (Optional) fake endpoint returns 410 → token dropped, subsequent
     trigger sends nothing, RC keeps working.
2. **Swift unit tests** (existing `CodeServerClientTests` /
   `CodeViewModelTests` seams): mock transport captures outgoing frames —
   assert `{"type":"push_token","token":...}` is sent (a) exactly once after
   each `hello_ok` when the token is already known (initial + reconnect),
   not before it, and (b) immediately when the token arrives/refreshes
   while a session is connected. The `UNUserNotificationCenterDelegate`
   cannot be exercised in-process, so it is covered by VM-level tests of the
   tap event the delegate forwards (`notificationTapped`): the tap triggers a
   `lastConnect` reconnect even with `backgroundDisconnected == false` and
   VM state `.failed` (the burn-out path), and is a no-op while `.connected`.
   `willPresent` returns `[]` when the VM state is `.connected` and
   `[.banner]` otherwise (VM state drives it; asserted at the VM level).
3. **Real device** (final, manual): user supplies the real `.p8`, Team ID,
   and Key ID on the pi machine; lock phone, trigger agent finish + question
   from pi, verify banners arrive while suspended and tap → foreground →
   reconnect via `lastConnect` → pending question modal appears.

## Open items / risks

- **Mode gate (INV1, implemented 2026-09-07)**: pushes fire only in
  interactive modes (`tui`/`rpc`). Subagent children (`pi --mode json -p`)
  load this extension and would otherwise push on every settled turn — and
  the APNs session they open pins the event loop so the child can never
  exit (the B1 hang). See `specs/pi-extensions-remote-ask.instructions.md`.
- **Environment-declared push endpoint (follow-up, not implemented)**: the
  `push_token` frame should carry the client's own aps environment
  (`{ token, env: "development" | "production" }`, from the app's
  `aps-environment`), stored alongside the token; the server would route
  each push to `api.sandbox.push.apple.com` or `api.push.apple.com` to match
  the token it holds, and the server-side host config becomes an
  override/test seam only. This removes the endpoint/token mismatch class of
  400 `BadDeviceToken` (the 2026-09-07 sandbox incident) by construction and
  lets one pi machine serve dev builds and App Store builds. Additive and
  backward-compatible: clients omitting `env` fall back to the configured
  host.
- **Token invalidation**: APNs `410` / `BadDeviceToken` response → drop the
  stored token from the singleton, log, keep serving; the client re-sends on
  next (re)connect or on token refresh. No retry/backoff.
- **Token rotation**: APNs tokens can change (OS update, reinstall,
  key rotation). Since the token is singleton-persistent, a rotated token
  that arrives while the session is connected is pushed immediately
  (`push_token` on token arrival); otherwise the every-(re)connect re-send
  covers it.
- **Privacy/battery**: the device token is a public routing identifier, sent
  only over the tailnet-bound, code-authenticated WS (plain WS, tailnet-only
  bind per parent spec). No payload contains secrets or full project paths:
  finished bodies carry the session name or cwd basename, and question bodies
  carry the question's own text capped at 100 chars and whitespace-sanitized
  (the documented 2026-09-07 relaxation) — never agent prose beyond the
  question itself. `apns-priority: 5` keeps both pushes battery-friendly;
  `timeSensitive` overrides the low-priority hold for questions only.
- **`timeSensitive` entitlement**: if the App ID / provisioning profile
  lacks it, Apple rejects the question push (`BadCollapseId`/`TimeSensitive`
  error surfaced in the APNs response) — caught by the setup checklist (and
  the build, if the entitlements file and profile disagree) and the device
  test.
- JWT clock skew: 5-min TTL per send means no caching; a clock-skewed pi
  machine would get `InvalidToken` — same failure class as missing config,
  surfaced in the response status.
- **Locked-phone question gap (closed)**: the ask-user-question extension
  gates remote routing on the rc singleton's `askAvailable()` — serving AND
  (clients connected OR push sendable) — instead of requiring a connected
  client, so `ask()` still routes with 0 clients whenever a push can actually
  be delivered. "Push sendable" means a registered token AND resolvable APNs
  credentials (`resolveApnsConfig()`), mirroring the status line's
  `push ok` / `push: no token` / `push: not configured` readiness; a token
  alone is not enough, or the question would silently wait forever on a
  no-op push. Config is resolved at ask time (not cached) because
  `/rc push-setup` can rewrite creds while serving. With 0 clients and no
  sendable push, the extensions keep the pi TUI fallback (unchanged).
  `pendingAsk` survives disconnects and is redelivered after `hello_ok` on
  reconnect, so the phone gets the timeSensitive push, the user unlocks,
  reconnects, and the pending question modal appears; there is no TTL (the
  ask blocks until answered/superseded/stopped) and no wire-protocol change.
  `/rc push-setup` prompts keep their stricter `isServing() &&
  hasConnectedClients()` gate — setup is interactive by design. Verified by
  harness group 12 (`ask_locked_phone_zero_clients_pushes_and_redelivers`,
  `ask_zero_clients_not_push_ready_falls_back_without_push`,
  `ask_zero_clients_token_without_creds_stays_local`). Diagnostic aid added
  alongside: the footer's `last` APNs outcome segment and the read-only
  `rc_inspect` tool (live singleton status: serving host/port/code, client
  count, push readiness, last APNs outcome, pending question). The earlier
  `/rc push-test` and `/rc show-token` subcommands were removed
  (2026-09-07): the footer segment and `rc_inspect` cover the diagnostics
  without special-cased push paths.

## Out of scope

- macOS notifications, deep links beyond opening the app (hence no custom
  payload fields in v1), pushes for any pi event other than
  `agent_settled` and remote questions, web/other platforms, push-based
  question answering (the WS `answer` path is unchanged).

## Setup checklist for the operator

1. **Apple Developer**: App ID `com.kinchaku.openclient-llm` — *Push* is
   already enabled; enable **Time Sensitive Notifications**. Then
   **regenerate/re-download the provisioning profile** so the new key is
   granted, and update the project's profile reference.
2. **App entitlements file**: add
   `com.apple.developer.usernotifications.time-sensitive` to
   `openclient-llm/Resources/openclient-llm.entitlements` (already carries
   `aps-environment: development`). Confirm how release builds will flip
   `aps-environment` to `production`.
3. **APNs key**: Certificates, Identifiers & Profiles → Keys → "Apple Push
   Notifications" key (ES256) → download `.p8` once; note the Key ID. Note
   the Team ID from the account page.
4. **pi machine**: place the `.p8` (e.g. `~/.pi/agent/apns/AuthKey_<ID>.p8`
   — placeholder, use the real filename) and run `/rc push-setup` to
   record the Team ID, Key ID, and key path in
   `~/.pi/agent/rc-push.json` (chmod 600). Env vars
   (`PI_RC_APNS_KEY_FILE` / `PI_RC_APNS_TEAM_ID` / `PI_RC_APNS_KEY_ID`)
   remain an alternative/override; if set, they win over the config
   file. `PI_RC_APNS_TOPIC` defaults correctly; leave
   `PI_RC_APNS_HOST` unset. Verify the "APNs push enabled" / "disabled"
   log line on `/rc` toggle-on.
5. **Phone**: re-install the app build with the push capability; open the
   Code tab, connect once (authorization prompt appears), lock the phone,
   trigger an agent finish and a question from pi.

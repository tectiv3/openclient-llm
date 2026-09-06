# Plan: RC push notifications (APNs)

Status: design agreed (revised after plan-critic review) — pending implementation.
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
| 2 | Trigger points | `agent_settled` → "Agent finished" (normal); `ask()` creating a remote question → "Agent has a question — answer needed" with `timeSensitive`. Push bodies are **fixed strings, chosen at send time by the server** — no LLM-generated or agent/user-controlled text in any push payload. Only when a token is registered |
| 3 | Server impl | Node stdlib only (constraint preserved): `node:http2` + `node:tls` for APNs HTTP/2 over TLS, `node:crypto` for a per-send ES256 JWT (5-min TTL) from a P-256 key parsed out of a `.p8` PEM file |
| 4 | Config | Env vars on the pi machine, nothing committed. Push is **disabled** (no-op, single log line) unless key file + team id + key id are all set; all other RC features unaffected |
| 5 | Protocol | Additive: one new client→server message `push_token`. **No new server→client messages** — pushes go via APNs, never over the WS |
| 6 | Token lifetime | **Singleton-persistent**: the last-registered token wins and is kept on the pi-rc singleton (globalThis state, consistent with the existing RC singleton's `clients`/streaming state). Survives client disconnects and process-suspension churn on the phone. This is what makes pushes work for the **full phone-suspension lifetime**: by then the WS is dead and the client's reconnects may be exhausted, so a per-connection token would be long gone before the push is triggered. Accepted trade-off: a tailnet client running the current client code could register *its own* device token and replace the stored one — but APNs device tokens are per-device, so this **redirects pushes only** (and the payload carries no agent/user text, so there is nothing sensitive to leak) |
| 7 | iOS app | Push capability + Time Sensitive Notifications entitlement; `registerForRemoteNotifications` at app init; notification authorization requested contextually on first RC connect (not at launch). Push registration code is `#if os(iOS)` — macOS target must compile, macOS gets no push |
| 8 | Foreground behavior | `UNUserNotificationCenterDelegate.willPresent` returns `[]` (suppress). The in-app UI already shows the question modal / settled state, so a foreground banner would be a duplicate |

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
- **Config** (env on the pi machine; push disabled unless all three of
  key file / team id / key id are set — log once "APNs push disabled (missing
  PI_RC_APNS_*)", every other RC feature unaffected):
  - `PI_RC_APNS_KEY_FILE` — path to the `.p8` private key (never committed)
  - `PI_RC_APNS_TEAM_ID`
  - `PI_RC_APNS_KEY_ID`
  - `PI_RC_APNS_TOPIC` — app bundle id, default `com.kinchaku.openclient-llm`
    (must match the app's `PRODUCT_BUNDLE_IDENTIFIER` exactly)
  - `PI_RC_APNS_HOST` — default `api.push.apple.com:443`; overridable (e.g.
    `127.0.0.1:8443`) for the test harness
- **Triggers** (only when the singleton holds a token):
  - `agent_settled` (inside `trackEvent`, which already toggles
    `isStreaming`) → push "Agent finished". **Firing frequency**: this fires
    on *every* settled turn — normal completion, aborts, every follow-up
    turn — and additionally the question tool's own turn settles again after
    the user answers, so a single ask/answer cycle can produce up to **3**
    settles. Hence the finished push uses the **constant**
    `apns-collapse-id: rc-finished`: APNs discards the in-flight duplicates
    and only the latest is delivered. This is deliberate — the decision to
    collapse is explicit, not incidental.
  - `ask()` creating a pending remote question/questionnaire → push "Agent
    has a question — answer needed", payload carries `timeSensitive: true`,
    collapse-id `rc-question`. (The question/questionnaire extensions call
    `rc.ask()` only when the server is serving and clients are connected, so
    this fires exactly when the remote modal would show.)
- **Payload** (minimal, < 4 KB, no secrets, no paths, and — explicitly —
  **no agent- or user-controlled text at all**; the bodies are fixed strings
  compiled into the sender, so a compromised/verbose agent can never place
  secret data on a lock screen):

```json
{
  "aps": {
    "alert": { "title": "Agent finished", "body": "Agent finished" },
    "sound": "default",
    "thread-id": "<sessionId>"
  }
}
```

Question push: title "Agent has a question", body
"Agent has a question — answer needed", plus `"timeSensitive": true` in `aps`.
There is **no `rc-session` (or any other) custom payload field in v1** — the
earlier draft's deep-linking field is dropped as dead weight; it comes back,
if at all, with v2 deep-linking. (`thread-id` is the server-generated session
id, not user content, and only threads notifications.)

**Token storage**: the singleton keeps one `pushToken`; last write wins. This
is a deliberate narrowing of the parent spec's multi-client broadcast model:
pushes are ambient alerts, not the question-answer channel, so one phone gets
one push. The accepted trade-off (Decision 6): a tailnet client with the
current code could replace the token and redirect pushes to its own device —
harmless in practice because the payload is fixed text with no session
content.

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
  - `willPresent` → return `[]` (suppress foreground banner; the in-app UI
    already shows the question modal / settled state).
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
     `{alg: "ES256", kid: keyId}`) and fixed-text payload shape.
   - `ask()` → one request; `timeSensitive: true` +
     `apns-collapse-id: rc-question`.
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
   while a session is connected. Delegate tests: `willPresent` returns `[]`;
   `didReceive` action triggers a `lastConnect` reconnect even with
   `backgroundDisconnected == false` and VM state `.failed`.
3. **Real device** (final, manual): user supplies the real `.p8`, Team ID,
   and Key ID on the pi machine; lock phone, trigger agent finish + question
   from pi, verify banners arrive while suspended and tap → foreground →
   reconnect via `lastConnect` → pending question modal appears.

## Open items / risks

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
  bind per parent spec). No payload contains project paths, secrets, or
  agent/user text. `apns-priority: 5` keeps both pushes battery-friendly;
  `timeSensitive` overrides the low-priority hold for questions only.
- **`timeSensitive` entitlement**: if the App ID / provisioning profile
  lacks it, Apple rejects the question push (`BadCollapseId`/`TimeSensitive`
  error surfaced in the APNs response) — caught by the setup checklist (and
  the build, if the entitlements file and profile disagree) and the device
  test.
- JWT clock skew: 5-min TTL per send means no caching; a clock-skewed pi
  machine would get `InvalidToken` — same failure class as missing config,
  surfaced in the response status.

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
4. **pi machine**: place the `.p8` (e.g. `~/.pi/agent/apns/AuthKey_<ID>.p8`)
   and set `PI_RC_APNS_KEY_FILE`, `PI_RC_APNS_TEAM_ID`, `PI_RC_APNS_KEY_ID`
   in the pi process env (`PI_RC_APNS_TOPIC` defaults correctly; leave
   `PI_RC_APNS_HOST` unset). Verify the "APNs push enabled" / "disabled"
   log line on `/rc` toggle-on.
5. **Phone**: re-install the app build with the push capability; open the
   Code tab, connect once (authorization prompt appears), lock the phone,
   trigger an agent finish and a question from pi.

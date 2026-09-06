# Plan: RC push notifications (APNs)

Status: design agreed — pending implementation.
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
| 2 | Trigger points | `agent_settled` → "Agent finished" (normal); `ask()` creating a remote question → "Agent has a question" with `timeSensitive`. Only when a token is registered |
| 3 | Server impl | Node stdlib only (constraint preserved): `node:http2` for APNs HTTP/2, `node:crypto` for a per-send ES256 JWT (5-min TTL) from a P-256 key parsed out of a `.p8` PEM file |
| 4 | Config | Env vars on the pi machine, nothing committed. Push is **disabled** (no-op, single log line) unless key file + team id + key id are all set; all other RC features unaffected |
| 5 | Protocol | Additive: one new client→server message `push_token`. **No new server→client messages** — pushes go via APNs, never over the WS |
| 6 | Token lifetime | Stored **per-connection** on the `RcClient` object; dropped on disconnect (the client is removed from the singleton's `clients` Set). Re-sent by the client on every (re)connect because the pairing code is ephemeral and every reconnect starts a fresh authenticated connection |
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
- Server: stores `pushToken` on the `RcClient` (new optional field, set in a new
  `case 'push_token'` branch of `handleClientMessage`). If `token` is not a
  string, ignore the frame silently (no error close — this message must degrade
  gracefully). Stored but unused when the APNs module is unconfigured.
- Server: no response. `hello_ok`, state, history, and all other messages are
  unchanged.

Swift side: new `CodeClientMessage.pushToken(token: String)` case + one
`encodeMessage` branch emitting the frame above. **No `CodeEvent` change** —
there are no new server→client frames, so the frozen decode side is untouched.
`CodeViewModel` sends `.pushToken` when it observes `.helloOk` on the event
stream (covers initial connect and every auto-reconnect in one place).

## Server implementation (`pi-extensions/rc/`)

- New `pi-extensions/rc/apns.ts` (or a section of `index.ts`; jiti loads the
  directory, relative imports work) — **Node stdlib only**: `node:http2`,
  `node:crypto`, `node:fs`.
- **JWT ES256, signed per send, 5-min TTL**: header `{alg:"ES256",
  typ:"JWT"}`, claims `{iss: TEAM_ID, iat: now, exp: now + 300}`. Key object
  from `crypto.createPrivateKey({ key: <p8 PEM>, format: "pem", type: "pkcs8"
  })` (P-256); signature via `crypto.sign("sha256", data, key)`. Base64url parts.
- **Send**: `http2.connect(authority)` → `POST /3/device/<token>` with headers
  `authorization: Bearer <jwt>`, `apns-topic`, `apns-priority: 5`,
  `apns-timestamp`, and (for the question push) `apns-collapse-id` (constant,
  e.g. `rc-question`, so a stale question push is replaced by a newer one).
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
- **Triggers** (only when the connection(s) hold a token):
  - `agent_settled` (inside `trackEvent`, which already toggles `isStreaming`)
    → push "Agent finished".
  - `ask()` creating a pending remote question/questionnaire → push "Agent has
    a question", payload carries `timeSensitive: true`. (The question/
    questionnaire extensions call `rc.ask()` only when the server is serving
    and clients are connected, so this fires exactly when the remote modal
    would show.)
- **Payload** (minimal, < 4 KB, no secrets, paths):

```json
{
  "aps": {
    "alert": { "title": "Agent finished", "body": "<session name or cwd basename>" },
    "sound": "default",
    "thread-id": "<sessionId>"
  },
  "rc-session": "<sessionId>"
}
```

`rc-session` is a reserved field for future deep-linking; v1 ignores it on
iOS. Question push: title "Agent has a question", body = the question prompt
truncated to ~100 chars, plus `"timeSensitive": true` in `aps`.

**Single-client invariant**: in practice exactly one RC client (the phone) is
connected. If multiple authenticated clients register tokens, push goes to the
**most recently received token** (last write wins on a singleton `pushToken`),
not broadcast — one phone, one push. This is a deliberate narrowing of the
parent spec's multi-client broadcast model and is acceptable because pushes are
ambient alerts, not the question-answer channel.

## iOS app

- App ID entitlements: Push + Time Sensitive Notifications (requires paid dev
  account — available).
- `registerForRemoteNotifications()` at app init; the device token is handed
  to `CodeViewModel` (new callback/handler).
- Authorization (`UNUserNotificationCenter.requestAuthorization(
  options: [.alert, .sound, .timeSensitive])`) requested **contextually on
  first RC connect** (when the user taps Connect on the Code tab), not at
  launch — notifications are an RC feature.
- `CodeViewModel`: on `.helloOk`, send `.pushToken(token:)` if a token is
  known. The pairing code is ephemeral and every (re)connect authenticates
  fresh, so the token is re-sent on **every** (re)connect; the server's
  per-connection storage means nothing needs to survive a disconnect.
- `UNUserNotificationCenterDelegate` (app delegate):
  - `willPresent` → return `[]` (suppress foreground banner; the in-app UI
    already shows the question modal / settled state).
  - `didReceive` → default banner. Tap → open app → existing foreground
    auto-reconnect + history resync (already implemented via `lastConnect` in
    `CodeViewModel`). Accept: if the process was killed in the background, the
    user re-enters the 6-digit code and the push lands on the connect screen.
- Existing `LocalNotificationManager` (local notifications during the ~30 s
  background window) stays as-is; APNs push is a superset that also covers
  suspension.
- macOS: everything guarded by `#if os(iOS)`; both schemes must build.

## Verification plan

1. **Node harness** (`pi-extensions/rc/test-client.mjs`, new group 12, run
   after the rate-limit group 11 as before): a local HTTP/2 server
   (self-signed cert, harness supplies the CA) standing in for APNs via
   `PI_RC_APNS_HOST` + a generated throwaway P-256 `.p8`. Assert:
   - `agent_settled` → one request; headers (`apns-topic`,
     `apns-priority: 5`, `apns-timestamp`, Bearer JWT parses with valid
     ES256 signature/claims) and payload shape.
   - `ask()` → one request; `timeSensitive: true` + `apns-collapse-id`
     present.
   - Connected client with **no** `push_token` → zero requests.
   - APNs env **unset** → zero requests, all other RC tests still pass.
   - Multiple tokens → only the latest receives the push.
   - (Optional) fake endpoint returns 410 → token dropped, subsequent
     trigger sends nothing, RC keeps working.
2. **Swift unit tests** (existing `CodeServerClientTests` /
   `CodeViewModelTests` seams): mock transport captures outgoing frames —
   assert `{"type":"push_token","token":...}` is sent exactly once after each
   `hello_ok` (initial + reconnect), and not before it. Delegate test:
   `willPresent` returns `[]`.
3. **Real device** (final, manual): user supplies the real `.p8`, Team ID, and
   Key ID on the pi machine; lock phone, trigger agent finish + question from
   pi, verify banners arrive while suspended and tap → foreground →
   auto-reconnect → pending question modal appears.

## Open items / risks

- **Token invalidation**: APNs `410` / `BadDeviceToken` response → drop the
  stored token, log, keep serving; the client will re-send on next
  (re)connect. No retry/backoff.
- **Token rotation**: APNs tokens can change (OS update, reinstall,
  key rotation). The every-(re)connect re-send covers reconnects; a mid-session
  rotation with no reconnect leaves the stale token until the next
  (re)connect. Acceptable for v1.
- **Privacy/battery**: the device token is a public routing identifier, sent
  only over the tailnet-bound, code-authenticated WS (plain WS, tailnet-only
  bind per parent spec). No payload contains project paths or secrets.
  `apns-priority: 5` keeps both pushes battery-friendly; `timeSensitive`
  overrides the low-priority hold for questions only.
- **`timeSensitive` entitlement**: if the App ID lacks it, Apple rejects the
  question push (`BadCollapseId`/`TimeSensitive` error surfaced in APNs
  response) — caught by the operator checklist and the device test.
- JWT clock skew: 5-min TTL per send means no caching; a clock-skewed pi
  machine would get `InvalidToken` — same failure class as missing config,
  surfaced in the response status.

## Out of scope

- macOS notifications, deep links beyond opening the app, pushes for any pi
  event other than `agent_settled` and remote questions, web/other platforms,
  push-based question answering (the WS `answer` path is unchanged).

## Setup checklist for the operator

1. **Apple Developer**: App ID `com.kinchaku.openclient-llm` — enable
   *Push* and *Time Sensitive Notifications*.
2. **APNs key**: Certificates, Identifiers & Profiles → Keys → "Apple Push
   Notifications" key (ES256) → download `.p8` once; note the Key ID. Note
   the Team ID from the account page.
3. **pi machine**: place the `.p8` (e.g. `~/.pi/agent/apns/AuthKey_<ID>.p8`)
   and set `PI_RC_APNS_KEY_FILE`, `PI_RC_APNS_TEAM_ID`, `PI_RC_APNS_KEY_ID`
   in the pi process env (`PI_RC_APNS_TOPIC` defaults correctly; leave
   `PI_RC_APNS_HOST` unset). Verify the "APNs push enabled" / "disabled"
   log line on `/rc` toggle-on.
4. **Phone**: re-install the app build with the push capability; open the
   Code tab, connect once (authorization prompt appears), lock the phone,
   trigger an agent finish and a question from pi.

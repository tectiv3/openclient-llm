# RC (remote control) feature — status

Working branch: `code-rc` (shared with a second agent; never push). Spec (source of truth, kept current): `docs/plans/rc-remote-control-spec.md`.

## Done (as of 2026-09-06)
- **rc extension** `pi-extensions/rc/index.ts` (~950 lines): stdlib-only RFC6455 WS server on `node:http`, fixed port 47800, `/rc` toggle command, hello auth with 6-digit decimal code, per-IP rate limit (lock at >=5 failures, 60 s), state/history builders, event forwarding (8 events), prompt/steer/abort via `pi.sendUserMessage`/`ctx.abort`, streaming buffer for mid-stream connects, session rebind on `new_session`, 90 s stale close, port-busy detection, quit auth file.
- **Remote ask** (Task 2): singleton `ask({kind, params}) -> Promise<answer|null>`; `pi-extensions/question/index.ts` + `questionnaire/index.ts` check `globalThis[Symbol.for("pi-rc")]` before the TUI path; server-generated ids (8 hex); `null` = cancelled (toggle-off/stop) → tool reports cancelled; falls through to TUI when no clients connected.
- **Debug logging**: `PI_RC_DEBUG=1` (→ `~/.pi/agent/rc-debug.log`) or `PI_RC_DEBUG_FILE=<path>` — every lifecycle event + wire frame, append-only, off by default.
- **Tailscale bind**: PATH `tailscale` → `/Applications/Tailscale.app/Contents/MacOS/Tailscale` → fail loud (never 0.0.0.0). `PI_RC_BIND` overrides.
- **Node harness** `pi-extensions/rc/test-client.mjs` (~900 lines): spawns pi in RPC mode in a temp copy of `test-project/`, 21 tests in groups 0–11 (rate-limit tests run LAST — group 11 — lockout would poison earlier groups).
- **Swift E2E** `openclient-llm-test/Features/Code/CodeEndToEndTests.swift` (+ RcE2eServer, MockModelServer, PosixProcessHandle, EventCollector): real `CodeServerClient` vs real pi+extension; LLM = local deterministic `MockModelServer` (simulator test processes have no non-loopback egress); hermetic, 6 tests.
- **Real phone verified** (2026-09-06): phone on tailnet connected with 6-digit code, prompted, streamed, keepalive pings.

## Not done
- Spec C4 manual matrix (most items covered by harness/E2E/phone smoke; notification/background/foreground/reconnect scenarios untested on device).
- Full iOS suite + both platform builds after the last shared-code changes (run before declaring done).

## Key invariants (don't regress)
- Protocol is FROZEN against the Swift client (`openclient-llm/Shared/Features/Code/Models/`): strict Codable decoding, so field names/shapes must match exactly. `contextUsage = {tokens, contextWindow, percent}`; `sessionId = sessionManager.getSessionId()` (NOT `getLeafId()`); error codes: `bad_code, rate_limited, version_mismatch, invalid_message, not_idle, unknown_question`.
- Question tool params carry no `value` — server-side `ask()` maps `value: label`.
- Singleton state lives on `globalThis[Symbol.for("pi-rc")]` (jiti loads extensions with `moduleCache:false`).

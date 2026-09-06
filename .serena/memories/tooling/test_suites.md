# Test suites for the rc feature

## Node harness (server-side, fast, uses real LLM)
```bash
node pi-extensions/rc/test-client.mjs            # ~40 s, 27 tests, exit 0/1/2
node pi-extensions/rc/test-client.mjs --only 5   # single group
# NOTE: RC_FAST=true is hardcoded in the harness => group 6 (90 s stale-close)
# ALWAYS skips, even without --fast. See note below.
```
- Spawns `pi --mode rpc --provider openrouter --model qwen/qwen3.8-27b --approve --no-session` in a fresh temp copy of `pi-extensions/rc/test-project/` (AGENTS.md there defines PONG-E2E/ASK/ASKFORM/LONG trigger behaviors).
- Sets `PI_RC_BIND=127.0.0.1` + temp `PI_RC_AUTH_FILE` itself; reads the pairing code from the auth file (never hardcoded — random per toggle).
- **Port 47800 must be free**: a live `/rc` session (TUI or otherwise) blocks the harness with port-busy setup failure. Check: `lsof -iTCP:47800 -sTCP:LISTEN`. Toggle `/rc` off in the live session first.
- Rate-limit tests are group 11 (last): the lockout persists in-process across toggles, would poison earlier groups.
- **`RC_FAST = true` is hardcoded** (test-client.mjs line 37, since the initial harness commit): the 90 s stale-close test (group 6) ALWAYS skips. Stale-close relies on the shared `closeClient` path exercised by the disconnect tests. Reference run 2026-09-06: 27 passed, 1 skipped (stale), 0 failed.

## Swift E2E (full stack, hermetic)
```bash
xcodebuild test -project openclient-llm.xcodeproj -scheme openclient-llm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:openclient-llm-test/CodeEndToEndTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
- Real `CodeServerClient` (URLSession WS) ↔ real pi + rc extension; LLM mocked locally (`MockModelServer`, OpenAI-compatible, canned replies keyed on prompt markers) because simulator test processes have no non-loopback egress.
- Resolves `pi` via `PI_RC_E2E_PI_BIN` → candidate paths → `zsh -lc` → XCTSkip.
- Also needs port 47800 free.

## Quick sanity
- `node -e "import('./pi-extensions/rc/index.ts').then(() => console.log('ok'))"` — module parse check (pi loads TS directly via jiti; no compile step).
- Verify no orphans after runs: `pgrep -fl "mode rpc"` empty; temp dirs gone.

## Full regression (after shared-code changes)
Full iOS suite + both platform builds per AGENTS.md commands.

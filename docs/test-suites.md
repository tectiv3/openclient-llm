# Test suites

## When to run the Node harness

Tier by territory, NOT by diff size — a 1-line change in major territory (e.g. renaming
a frame field) passes tsc but breaks the frozen Swift client:

- **Any change under `pi-extensions/rc/`**: commit hook (tsc + eslint + prettier).
- **Major territory** → run the harness, narrowed with `--only <group>` when one group
  covers the change: wire/frames (groups 1–4, 10), hello/auth/rate-limit (1, 11), event
  forwarding (2–4), streaming buffer (10), ask/singleton/pending-ask (5), push/APNs (12),
  pending steers (13), compaction visibility (15). Full run when a change spans
  territories or when in doubt.
- **Cosmetic** (status-line text, debug logging, diagnostics): hook suffices; harness
  optional.

## Node harness (47 tests, groups 0–13 + 15)

```bash
node pi-extensions/rc/test-client.mjs            # ~5-7 min (LLM round trips)
node pi-extensions/rc/test-client.mjs --only 5   # single group
node pi-extensions/rc/test-client.mjs --only 5,12  # multiple groups
node pi-extensions/rc/test-client.mjs --no-apns  # skip fake APNs endpoint (group 12)
node pi-extensions/rc/test-client.mjs --list      # print all tests
```

- Spawns pi in RPC mode with a cheap model in a temp copy of `test-project/`.
- Sets `PI_RC_BIND=127.0.0.1` + temp `PI_RC_AUTH_FILE`; reads the pairing code from
  the auth file.
- **Port 47800 must be free**: a live `/rc` session blocks the harness. Check:
  `lsof -iTCP:47800 -sTCP:LISTEN`.
- `RC_FAST = true` is hardcoded — the 90 s stale-close test (group 6) always skips.
- Rate-limit tests are group 11 (last of the non-APNs groups): lockout persists
  in-process, would poison earlier groups.
- APNs isolation: child gets `PI_RC_APNS_CONFIG` pointed at a temp file — the user's
  real `rc-push.json` never leaks into harness runs.
- Group 12 ask tests have flaked once on LLM round-trip timing — re-run
  `--only 12` before debugging a single failure.
- Group 14 (rc commands) is spec'd but not yet implemented.
- `--only` accepts comma-separated group numbers AND test-name substrings (case-
  insensitive). Filtering out prerequisites makes state-dependent tests SKIP.

## Swift E2E (hermetic, real stack)

```bash
xcodebuild test -project openclient-llm.xcodeproj -scheme openclient-llm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:openclient-llm-test/CodeEndToEndTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  -skipPackageUpdates -skipMacroValidation \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

- Real `CodeServerClient` ↔ real pi + rc extension; LLM mocked locally
  (`MockModelServer`) — simulator has no non-loopback egress.
- Resolves `pi` via `PI_RC_E2E_PI_BIN` → candidate paths → `zsh -lc` → XCTSkip.
- Also needs port 47800 free.

## Known blocker: full iOS suite crash-loops (iOS 26.3 sim runtime)

The full `xcodebuild test` crash-loops: test host dies on a malloc error inside
`swift::TaskLocal::StopLookupScope::~StopLookupScope()` in `libswift_Concurrency.dylib`.
ASan-verified: bad-free on a fixed address, reached via `swift_task_deinitOnExecutor`
from ordinary `__deallocating_deinit`. Reproduced on clean `origin/main`. Apple-side bug.

**Workaround:** Use targeted runs (`-only-testing:openclient-llm-test/<Class>`). The 4
Code-feature classes run clean (121/121). Re-test the full suite after Xcode/sim-runtime
updates.

## Full regression

Full iOS suite + both platform builds per AGENTS.md commands. Use targeted runs until
the sim-runtime crash is fixed.

# Test suites for the rc feature

## When to run the Node harness (tiered rule, decided 2026-09-07)

The old rule — "MUST run after ANY change under `pi-extensions/rc/`" — came from the safeJson
ReferenceError (commit 7229933, which only exists on `backup/main-9-04-57`). That bug class
(identifier referenced in a live path but not imported/defined) is now caught at commit time:
the pre-commit hook runs `tsc --noEmit` over `pi-extensions/**/*.ts` and blocks new errors not
in `.tsc-baseline` (`rc/index.ts` is fully type-checked, 8 baseline errors pinned there). The
harness's unique value is runtime-only behavior: wire shapes vs the frozen Swift Codable client,
event ordering, live pi+LLM round trips, APNs H2, singleton/`globalThis` dynamics.

Tier by territory, NOT by diff size — a 1-line change in major territory (e.g. renaming a frame
field) passes tsc but breaks the frozen Swift client:

- **Any change under `pi-extensions/rc/`**: commit hook (tsc + eslint + prettier) + the Quick
  sanity module-load check below.
- **Major territory** → run the harness, narrowed with `--only <group>` when one group covers
  the change: wire/frames (groups 1–4, 10), hello/auth/rate-limit (1, 11), event forwarding
  (2–4), streaming buffer (10), ask/singleton/pending-ask (5), push/APNs (12). Full run when a
  change spans territories or when in doubt.
- **Cosmetic** (status-line text, debug logging, diagnostics like `rc_inspect`, test-project
  tweaks): hook + load check suffices; harness optional.

## Node harness (server-side, fast, uses real LLM)
```bash
node pi-extensions/rc/test-client.mjs            # ~5-7 min (LLM round trips), 41 tests, exit 0/1/2
node pi-extensions/rc/test-client.mjs --only 5   # single group
node pi-extensions/rc/test-client.mjs --no-apns  # skip the fake APNs endpoint (group 12 pushes)
# NOTE: RC_FAST=true is hardcoded in the harness => group 6 (90 s stale-close)
# ALWAYS skips, even without --fast. See note below.
```
- Spawns `pi --mode rpc --provider zai --model glm-5.3-flash --approve --no-session` (cheap exact-instruction model; the harness only needs the test-project AGENTS.md contracts followed, not reasoning quality) in a fresh temp copy of `pi-extensions/rc/test-project/` (AGENTS.md there defines PONG-E2E/ASK/ASKFORM/LONG trigger behaviors).
- Sets `PI_RC_BIND=127.0.0.1` + temp `PI_RC_AUTH_FILE` itself; reads the pairing code from the auth file (never hardcoded — random per toggle).
- **Port 47800 must be free**: a live `/rc` session (TUI or otherwise) blocks the harness with port-busy setup failure. Check: `lsof -iTCP:47800 -sTCP:LISTEN`. Toggle `/rc` off in the live session first.
- Rate-limit tests are group 11 (last): the lockout persists in-process across toggles, would poison earlier groups. Group 12 starts behind `waitForLockoutClear` (polls a correct-code hello until the 60 s lockout expires). Group 12 is also LLM-dependent (ask/question round trips) — individual ask tests have flaked once and passed on re-run; treat a single ask-test failure as suspect-flake, re-run `--only 12` before debugging.
- **`RC_FAST = true` is hardcoded** (test-client.mjs line 37, since the initial harness commit): the 90 s stale-close test (group 6) ALWAYS skips. Stale-close relies on the shared `closeClient` path exercised by the disconnect tests. Reference runs: 2026-09-06 27/0/1 (pre-push); 2026-09-07 31 passed, 0 failed, 2 skipped on the default push-enabled spawn (skips = the two --no-apns-only cases; the push tests run against a local fake APNs H2 endpoint); 2026-09-07 (esc-hatch commit) 33 passed, 0 failed, 2 skipped in BOTH spawn modes — the extra tests: 2 group-5 ask() signal tests (via test-project/rc-signal-probe.ts) + the group-12 uppercase push_token auto-auth test. 2026-09-07 (commit `2e3fd76`, push session-identity bodies + abort gate + rc_inspect) grew the suite to 37 tests (group 12 push-body/abort tests). 2026-09-08 (pending steers) grew it to 41 (group 13 ×3, steer-pending visibility) — reference run 39 passed / 0 failed / 2 skipped, exit 0 (the 2 skips are the by-design env-conditioned cases above).
- **APNs isolation**: the child gets `PI_RC_APNS_CONFIG` pointed at a temp file (initially absent) in the temp root — the user's real `~/.pi/agent/rc-push.json` (token + creds) never leaks into harness runs, and the child starts with no APNs creds. `apnsEnabled` = the fake endpoint was started (env seam), independent of file creds.

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
- Static check: `cd pi-extensions && npx tsc --noEmit` (the pre-commit hook runs this vs `.tsc-baseline`). A plain `node -e` dynamic-import parse check does NOT work from the repo context for files with value imports of pi runtime packages (`@earendil-works/pi-tui`, `typebox` — unresolvable: no parent `node_modules` has them, and the pnpm store `links/` dirs are pruned to `node_modules` only); it only works for type-only-import files. For a real load check, boot a pi process that loads the extensions: the harness child (group 0 fails on any extension load error) or a fresh pi session.
- Verify no orphans after runs: `pgrep -fl "mode rpc"` empty; temp dirs gone.

## Full regression (after shared-code changes)
Full iOS suite + both platform builds per AGENTS.md commands.

## Known blocker: full iOS suite crash-loops (iOS 26.3 sim runtime, found 2026-09-08)

The full `xcodebuild test` run crash-loops: the test host dies on a malloc error and
xcodebuild restarts it, forever. Crash points vary between restarts (VM-lifecycle tests
in Chat/Home/Launch/Onboarding), always during normal ARC deinit of view models.

- **Root cause (ASan-verified): a Swift Concurrency runtime bug in the iOS 26.3 simulator
  runtime (build 23D8133), NOT app memory corruption.** ASan report: `bad-free` on a fixed
  address (0x2610e4360) inside `swift::TaskLocal::StopLookupScope::~StopLookupScope()` in
  `libswift_Concurrency.dylib`, reached via `swift_task_deinitOnExecutorImpl` from an
  ordinary `__deallocating_deinit` (e.g. `ChatViewModel.deinit` → `PlayAudioUseCase`
  deinit on the main executor). All frames above the app's deinit are system code; app code
  under ARC cannot free arbitrary pointers. Reproduced identically on a clean `origin/main`
  worktree → pre-existing, independent of any recent change.
- **Workaround:** verify with targeted runs — `-only-testing:openclient-llm-test/<Class>`
  (the 4 Code-feature classes run clean: 121/121). A single test method can be targeted too:
  `-only-testing:openclient-llm-test/<Class>/<method>`. Do NOT chase this as an app bug.
- **Why no runtime switch:** app minimum is iOS 26; the only other installed sim runtime is
  iOS 18.4 (too old to run the app). Re-test the full suite after Xcode/sim-runtime updates —
  this is tracked as Apple-side.
- The 3 stale-test failures that previously also red-lined the suite (LMStudio ×2, Chat
  history-limit off-by-one) were fixed 2026-09-08 — they were stale expectations orphaned
  by commit 5ad1c89 (encoder revert) and a birth-time arithmetic error, not bugs.

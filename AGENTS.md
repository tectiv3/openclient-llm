# AGENTS.md

Project-wide operating guide. Focused rules live in `specs/`. Read both before changing the project.

> Forked from [ArtCC/openclient-llm](https://github.com/ArtCC/openclient-llm).

## Specifications

Each spec uses `.instructions.md` suffix with YAML front matter. Update this table when adding or removing one.

| File | Read when |
|---|---|
| `agent-tool-calling.instructions.md` | Implementing tool calling, tool UI, or the agent loop. |
| `architecture.instructions.md` | Creating Swift files, features, or changing layer boundaries. |
| `changelog.instructions.md` | Updating `CHANGELOG.md`. |
| `chat-visual-style.instructions.md` | Designing chat-specific SwiftUI. |
| `code-style.instructions.md` | Writing or reviewing Swift style. |
| `concurrency.instructions.md` | Working with async code, isolation, or `Sendable`. |
| `design-ui.instructions.md` | Designing general SwiftUI UI, accessibility, haptics, or animation. |
| `litellm-api.instructions.md` | Changing LiteLLM/OpenAI-compatible API integration. |
| `pi-extensions-remote-ask.instructions.md` | Remote ask protocol — rc question/answer frames, ask gate, pending-question push (SUPERSEDED 2026-09-07; kept as the historical record of the push mode-guard and singleton-shape rules). |
| `security.instructions.md` | Handling sensitive data, user input, credentials, or security review. |
| `swiftui-multiplatform.instructions.md` | Building shared iOS, iPadOS, or macOS SwiftUI. |
| `testing.instructions.md` | Adding or changing tests and mocks. |

## Platform

- Swift 6+, SwiftUI, iOS 26 / macOS 26 minimum.
- Backend: self-hosted LiteLLM (OpenAI-compatible API), user-configurable base URL.
- Credentials in `KeychainManager`; settings in `SettingsManager`.

## Build & Test

```bash
# Build iOS
xcodebuild build -project openclient-llm.xcodeproj -scheme openclient-llm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'

# Build macOS
xcodebuild build -project openclient-llm.xcodeproj -scheme openclient-llm-macOS \
  -destination 'platform=macOS'

# Test (iOS)
xcodebuild test -project openclient-llm.xcodeproj -scheme openclient-llm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

# Single test class
xcodebuild test -project openclient-llm.xcodeproj -scheme openclient-llm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:openclient-llm-test/ChatViewModelTests \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

- Use `.xcodeproj` (not `.xcworkspace`). SPM packages: SwiftLintPlugins, ConfettiSwiftUI.
- CI skips signing: append `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`.
- VS Code + XcodeBuildMCP config at `.xcodebuildmcp/config.yaml`.

### CLI Build Workarounds

`xcodebuild` from the CLI (coding agents, CI) requires SPM sandbox workarounds — always append
the flags below to the build/test commands above when running from CLI:

```bash
-skipPackageUpdates -skipMacroValidation \
OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

## Targets

| Target | Purpose |
|---|---|
| `openclient-llm` | iOS app + all shared code |
| `openclient-llm-macOS` | macOS app (macOS-only UI; references `Shared/` from iOS target) |
| `openclient-llm-test` | Unit tests (linked to iOS target) |
| `ShareExtension` | iOS Share Extension (App Group, does NOT link Shared) |
| `WidgetsExtension` | WidgetKit extension (App Group, selected shared resources) |

Shared business logic: `openclient-llm/Shared/`, referenced by both app targets. Tests: `openclient-llm-test/`.

## pi Extensions

`pi-extensions/` contains TypeScript extensions for [pi](https://github.com/earendil-works/pi) (the `@earendil-works/pi-coding-agent` coding agent):

| Directory | Purpose |
|---|---|
| `rc/` | Remote control — WebSocket server + APNs push for mobile companion access to a pi session. |
| `subagent/` | Subagent tool — delegates tasks to specialized agents with isolated context (single, parallel, chain modes). |
| `ask-user-question/` | Structured question tool — single- and multi-question prompts with typed answers (tabbed per-question pages, `allowOther` "Type something" option). |

These run inside the pi process (Node/Bun). The Swift app's `Features/Code/` is the mobile client for `rc`.

## Git Workflow

- Work directly on `main`.
- Commit messages: imperative style ("Add chat streaming support").
- After implementation: compile and commit (linter runs on commit hook).
- Build both iOS and macOS after changing shared code.

### Pre-commit Hook

The git pre-commit hook automatically runs formatting and linting on staged files.
**Do not duplicate these checks manually** — the hook handles them.

**Swift files:**
1. `swiftformat` — auto-formats and re-stages.
2. `swiftlint --fix` — auto-fixes and re-stages.
3. `swiftlint lint` — blocks on remaining errors.

**TypeScript files (`pi-extensions/`):**
1. `prettier --write` — auto-formats and re-stages.
2. `eslint --fix` — auto-fixes and re-stages; blocks on remaining errors.
3. `tsc --noEmit` — type-checks against a baseline (`pi-extensions/.tsc-baseline`). Only **new** errors (not in the baseline) block the commit.

**Baseline rules:**
- `pi-extensions/.tsc-baseline` lists known tsc errors from pre-existing type mismatches (stub-vs-runtime gaps). Checked into git.
- If you fix a baseline error, regenerate the baseline: `cd pi-extensions && npx tsc --noEmit 2>&1 | grep "error TS" | sort > .tsc-baseline`
- If you introduce a new tsc error, the commit is blocked. Fix it or update the baseline with justification.
- Keep eslint warnings at zero — the hook blocks on any eslint output.

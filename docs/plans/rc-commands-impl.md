# RC Remote Commands — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers-extended-cc:subagent-driven-development (if subagents available) or superpowers-extended-cc:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add session control from the phone (new session, switch models, compact context, rename session) over the existing rc WebSocket protocol.

**Architecture:** One generic `command` client→server frame dispatches to per-command handlers. No success frames — side effects flow through existing event broadcasts. Server stashes a `commandCtx` for `newSession` calls; other commands use the live binding. Swift client gains a `.command` message case and models the `models` array on `state` frames.

**Tech Stack:** TypeScript (pi-extensions/rc), Swift/SwiftUI (openclient-llm), test harness (test-client.mjs)

**Spec:** `docs/plans/rc-commands-spec.md` (owner-approved 2026-09-09, two review rounds)

---

### Task 1: Server — RcSingleton type + commandCtx stash

**Files:**
- Modify: `pi-extensions/rc/index.ts:100-134` (RcSingleton type)
- Modify: `pi-extensions/rc/index.ts:140-158` (singleton factory)
- Modify: `pi-extensions/rc/index.ts:1459-1466` (`/rc` command handler)

- [ ] **Step 1: Add `commandCtx` to `RcSingleton` type**

At `pi-extensions/rc/index.ts:116` (after `compacting`), add:

```typescript
commandCtx: ExtensionCommandContext | null
```

The type import: `ExtensionCommandContext` is the context type received by `registerCommand` handlers (types.ts:363-369). The rc extension uses local stubs — grep for the existing `ExtensionContext` type alias and add `ExtensionCommandContext` alongside it (or use the same structural shape since the ctx IS command-capable when received from `registerCommand`).

In the singleton factory initializer (~line 156), add:

```typescript
commandCtx: null,
```

- [ ] **Step 2: Stash commandCtx in the /rc command handler**

At `pi-extensions/rc/index.ts:1461` inside `handler: async (args, ctx)`, after `state.bind(pi, ctx)`, add:

```typescript
state.commandCtx = ctx
```

The `ctx` from `registerCommand` is an `ExtensionCommandContext` (has `newSession`). This is the ONLY place we get a command-capable context.

- [ ] **Step 3: Verify tsc baseline**

Run: `cd pi-extensions && npx tsc --noEmit 2>&1 | grep "error TS" | sort | diff .tsc-baseline - || true`
Expected: No new errors (existing baseline unchanged).

- [ ] **Step 4: Commit**

```bash
git add pi-extensions/rc/index.ts
git commit -m "Add commandCtx field to RcSingleton for rc remote commands"
```

---

### Task 2: Server — session_shutdown fix + null-binding guards

**Files:**
- Modify: `pi-extensions/rc/index.ts:1022-1026` (session_shutdown handler)
- Modify: `pi-extensions/rc/index.ts:783-806` (handlePrompt)
- Modify: `pi-extensions/rc/index.ts:808-837` (handleSteer)

- [ ] **Step 1: Fix session_shutdown handler**

At `pi-extensions/rc/index.ts:1022-1026`, the current code is:

```typescript
pi.on('session_shutdown', async (event, ctx) => {
    state.bind(pi, ctx)
    state.compacting = null
    if (event.reason === 'quit') await state.stop('quit', 'pi shutdown')
})
```

Replace with (spec: verified fact 2, decision 8):

```typescript
pi.on('session_shutdown', async (event, ctx) => {
    state.compacting = null
    if (event.reason === 'quit') {
        state.bind(pi, ctx)
        await state.stop('quit', 'pi shutdown')
    } else {
        state.binding = null
    }
})
```

When `reason !== 'quit'` (new/resume/fork), null the binding — the old ctx is about to be invalidated. Do NOT cancelPendingAsk (decision 8: unreachable while ask is live; would wrongly cancel on reload). The next `session_start` rebinds.

- [ ] **Step 2: Change handlePrompt null-binding error to `not_ready`**

At `pi-extensions/rc/index.ts:789-795`, change the null-binding guard from:

```typescript
if (!binding) {
    writeJson(client, {
        type: 'error',
        code: 'invalid_message',
        message: 'no active pi session',
    })
    return
}
```

to:

```typescript
if (!binding) {
    writeJson(client, { type: 'error', code: 'not_ready' })
    return
}
```

- [ ] **Step 3: Change handleSteer null-binding error to `not_ready`**

Same change at `pi-extensions/rc/index.ts:814-820`:

```typescript
if (!binding) {
    writeJson(client, { type: 'error', code: 'not_ready' })
    return
}
```

- [ ] **Step 4: Verify tsc baseline**

Run: `cd pi-extensions && npx tsc --noEmit 2>&1 | grep "error TS" | sort | diff .tsc-baseline - || true`

- [ ] **Step 5: Commit**

```bash
git add pi-extensions/rc/index.ts
git commit -m "Fix session_shutdown binding + change null-binding errors to not_ready"
```

---

### Task 3: Server — models in buildState + new event subscriptions

**Files:**
- Modify: `pi-extensions/rc/index.ts:839-875` (buildState)
- Modify: `pi-extensions/rc/index.ts:1011-1091` (registerEventHandlers)

- [ ] **Step 1: Add models array to buildState**

At `pi-extensions/rc/index.ts:839`, in `buildState`, after the existing model derivation block and before the `return`, build the models list (spec: verified fact 7 — scoped set when non-empty, else full catalog):

```typescript
const scopedModels = safeArray(ctx?.scopedModels)
const catalogModels = scopedModels.length > 0
    ? scopedModels
    : safeArray((ctx?.modelRegistry as { getAvailable?: () => unknown[] })?.getAvailable?.())
const models = catalogModels
    .filter(isObject)
    .map(m => ({
        provider:
            stringFrom(m.provider) ??
            stringFrom(m.providerId) ??
            stringFrom(m.providerName) ??
            'unknown',
        id:
            stringFrom(m.id) ??
            stringFrom(m.model) ??
            stringFrom(m.name) ??
            'unknown',
    }))
```

Then in the return object, add after the `contextUsage` spread:

```typescript
...(models.length > 0 ? { models } : {}),
```

- [ ] **Step 2: Subscribe to model_select event**

In `registerEventHandlers`, after the existing `session_compact_failed` subscription (~line 1091), add:

```typescript
pi.on('model_select', (event, ctx) => {
    state.bind(pi, ctx)
    state.broadcast(buildState(state))
})
```

- [ ] **Step 3: Subscribe to session_info_changed event**

```typescript
pi.on('session_info_changed', (event, ctx) => {
    state.bind(pi, ctx)
    state.broadcast(buildState(state))
})
```

- [ ] **Step 4: Verify tsc baseline**

Run: `cd pi-extensions && npx tsc --noEmit 2>&1 | grep "error TS" | sort | diff .tsc-baseline - || true`

- [ ] **Step 5: Commit**

```bash
git add pi-extensions/rc/index.ts
git commit -m "Add models to state frame + subscribe to model_select/session_info_changed"
```

---

### Task 4: Server — handleCommand + dispatch

**Files:**
- Modify: `pi-extensions/rc/index.ts:493-546` (handleClientMessage — add `command` case)
- Create new function `handleCommand` (after handleSteer, ~line 838)

- [ ] **Step 1: Add `command` case to handleClientMessage**

At `pi-extensions/rc/index.ts:506`, in the `switch (message.type)` block, add before the `default` case:

```typescript
case 'command':
    void handleCommand(state, client, message)
    break
```

The `void` prefix is intentional: `handleCommand` is async (it awaits newSession), but `handleClientMessage` is synchronous. The `void` silences the unhandled-promise lint. `handleCommand` has its own internal try/catch — the blanket catch in `handleSocketData` cannot catch async rejections (spec: server design).

- [ ] **Step 2: Implement handleCommand**

Insert after `handleSteer` (before `buildState`):

```typescript
async function handleCommand(
    state: RcSingleton,
    client: RcClient,
    message: JsonObject
): Promise<void> {
    const command = stringFrom(message.command as string)
    if (!command) {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }

    const binding = state.binding
    if (!binding) {
        writeJson(client, { type: 'error', code: 'not_ready' })
        return
    }

    try {
        switch (command) {
            case 'new':
                await handleCommandNew(state, client)
                break
            case 'set_model':
                handleCommandSetModel(state, client, binding, message)
                break
            case 'compact':
                handleCommandCompact(binding, message)
                break
            case 'name':
                handleCommandName(state, binding, client, message)
                break
            default:
                writeJson(client, { type: 'error', code: 'unknown_command' })
        }
    } catch (error) {
        const msg = errorMessage(error)
        if (msg.includes('stale')) {
            writeJson(client, {
                type: 'error',
                code: 'stale_session',
                message: 'Session replaced outside rc — run /rc in the terminal to recover',
            })
        } else {
            writeJson(client, {
                type: 'error',
                code: 'command_failed',
                message: msg.slice(0, 200),
            })
        }
    }
}
```

- [ ] **Step 3: Implement handleCommandNew**

```typescript
let commandInFlight = false

async function handleCommandNew(
    state: RcSingleton,
    client: RcClient
): Promise<void> {
    if (commandInFlight) {
        writeJson(client, { type: 'error', code: 'not_ready' })
        return
    }
    const cmdCtx = state.commandCtx
    if (!cmdCtx || typeof cmdCtx.newSession !== 'function') {
        writeJson(client, {
            type: 'error',
            code: 'stale_session',
            message: 'Session replaced outside rc — run /rc in the terminal to recover',
        })
        return
    }
    commandInFlight = true
    try {
        await cmdCtx.newSession({
            withSession: (fresh) => {
                state.commandCtx = fresh
            },
        })
    } finally {
        commandInFlight = false
    }
}
```

- [ ] **Step 4: Implement handleCommandSetModel**

```typescript
function handleCommandSetModel(
    state: RcSingleton,
    client: RcClient,
    binding: Binding,
    message: JsonObject
): void {
    const provider = stringFrom(message.provider as string)
    const modelId = stringFrom(message.modelId as string)
    if (!provider || !modelId) {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }
    const registry = binding.ctx.modelRegistry as {
        find?: (provider: string, modelId: string) => unknown
    }
    if (typeof registry?.find !== 'function') {
        writeJson(client, {
            type: 'error',
            code: 'command_failed',
            message: 'Model registry unavailable',
        })
        return
    }
    const model = registry.find(provider, modelId)
    if (!model) {
        writeJson(client, { type: 'error', code: 'model_not_found' })
        return
    }
    void (async () => {
        try {
            const ok = await binding.pi.setModel(model)
            if (!ok) {
                writeJson(client, { type: 'error', code: 'model_not_set' })
            }
        } catch (error) {
            writeJson(client, {
                type: 'error',
                code: 'command_failed',
                message: errorMessage(error).slice(0, 200),
            })
        }
    })()
}
```

- [ ] **Step 5: Implement handleCommandCompact**

```typescript
function handleCommandCompact(binding: Binding, message: JsonObject): void {
    const raw = message.instructions
    const instructions =
        typeof raw === 'string' ? raw.trim() : undefined
    binding.ctx.compact(
        instructions ? { customInstructions: instructions } : undefined
    )
}
```

- [ ] **Step 6: Implement handleCommandName**

```typescript
function handleCommandName(
    state: RcSingleton,
    binding: Binding,
    client: RcClient,
    message: JsonObject
): void {
    const raw = message.name
    if (typeof raw !== 'string') {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }
    const trimmed = raw.trim()
    if (trimmed.length === 0) {
        writeJson(client, { type: 'error', code: 'unknown_command' })
        return
    }
    binding.pi.setSessionName(trimmed)
}
```

- [ ] **Step 7: Guard handleCommand against commandInFlight**

In `handleCommand`, at the top after the binding check, add the `commandInFlight` gate for ALL commands during `new`:

```typescript
if (commandInFlight) {
    writeJson(client, { type: 'error', code: 'not_ready' })
    return
}
```

(This goes before the `switch`, so all commands are rejected while `new` is in-flight — spec: "rejects ALL incoming command frames with not_ready".)

- [ ] **Step 8: Verify tsc baseline**

Run: `cd pi-extensions && npx tsc --noEmit 2>&1 | grep "error TS" | sort | diff .tsc-baseline - || true`

- [ ] **Step 9: Commit**

```bash
git add pi-extensions/rc/index.ts
git commit -m "Implement handleCommand: new, set_model, compact, name"
```

---

### Task 5: Swift — CodeClientMessage.command + encoding

**Files:**
- Modify: `openclient-llm/Shared/Features/Code/Models/CodeServerClient.swift:80-90` (CodeClientMessage enum)
- Modify: `openclient-llm/Shared/Features/Code/Models/CodeServerClient.swift:523-575` (encodeMessage)

- [ ] **Step 1: Add `.command` case to CodeClientMessage**

At `CodeServerClient.swift:89` (before the closing `}`), add:

```swift
case command(command: String, args: [String: AnyCodableValue] = [:])
```

- [ ] **Step 2: Add encoding for `.command` in encodeMessage**

At `CodeServerClient.swift:571` (before `case .ping:`), add:

```swift
case let .command(command, args):
    dict["type"] = .string("command")
    dict["command"] = .string(command)
    for (key, value) in args {
        dict[key] = value
    }
```

- [ ] **Step 3: Build iOS**

Run: `xcodebuild build -project openclient-llm.xcodeproj -scheme openclient-llm -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackageUpdates -skipMacroValidation OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'`

- [ ] **Step 4: Commit**

```bash
git add openclient-llm/Shared/Features/Code/Models/CodeServerClient.swift
git commit -m "Add command case to CodeClientMessage with generic args encoding"
```

---

### Task 6: Swift — CodeSessionInfo.models + ViewModel models handling

**Files:**
- Modify: `openclient-llm/Shared/Features/Code/Models/CodeModels.swift:12-23` (CodeSessionInfo)
- Modify: `openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel.swift:56-65` (SessionState)
- Modify: `openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel.swift:434-461` (handleStateInfo)

- [ ] **Step 1: Add `models` to CodeSessionInfo**

At `CodeModels.swift:22` (before `var compacting`), add:

```swift
var models: [CodeModelInfo]?
```

Uses `var` with implicit nil default, same pattern as `compacting` — call sites predating this field stay source-compatible.

- [ ] **Step 2: Add `models` to SessionState**

At `CodeViewModel.swift:60` (after `model`), add:

```swift
var models: [CodeModelInfo] = []
```

- [ ] **Step 3: Update handleStateInfo to populate models**

At `CodeViewModel.swift:448-451`, after `session.model = info.model`, add:

```swift
if let models = info.models {
    session.models = models
}
```

- [ ] **Step 4: Pin "unknown" sessionId — skip rebind**

At `CodeViewModel.swift:437-444`, the current rebind logic is:

```swift
let isRebind = !session.sessionId.isEmpty
    && session.sessionId != info.sessionId

if isRebind {
    session.items = []
    session.pendingQuestion = nil
    pendingPromptEchoes.removeAll()
}
```

Change to (spec: verified fact 12, C3 pin):

```swift
let isUnknown = info.sessionId == "unknown"
let isRebind = !isUnknown
    && !session.sessionId.isEmpty
    && session.sessionId != info.sessionId

if isRebind {
    session.items = []
    session.pendingQuestion = nil
    pendingPromptEchoes.removeAll()
}

if isUnknown { return }
```

When `sessionId == "unknown"` (null-binding window during session replacement): do NOT rebind, do NOT overwrite model/cwd/contextUsage with stale values, do NOT clear transcript. The early return skips all the field assignments below. The real `session_start` snapshot corrects everything.

- [ ] **Step 5: Build iOS**

Run: `xcodebuild build ...` (same flags as Task 5 Step 3)

- [ ] **Step 6: Commit**

```bash
git add openclient-llm/Shared/Features/Code/Models/CodeModels.swift \
  openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel.swift
git commit -m "Add models to state frame, pin unknown sessionId to prevent spurious rebind"
```

---

### Task 7: Swift — ViewModel command events + error handling

**Files:**
- Modify: `openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel.swift:19-35` (Event enum)
- Modify: `openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel.swift:348-401` (handleEvent)
- Modify: `openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel+Errors.swift:16-34` (handleError)

- [ ] **Step 1: Add command events to the Event enum**

At `CodeViewModel.swift:34` (before `case clearToast`), add:

```swift
case newSession
case setModel(provider: String, modelId: String)
case compact(instructions: String?)
case rename(name: String)
```

- [ ] **Step 2: Handle command events in handleEvent or a new method**

At `CodeViewModel.swift:348`, in `handleEvent`, these are USER-initiated events (from UI). They send messages to the server. Add a method (or inline in `handleEvent`):

```swift
case .newSession:
    Task { await client.send(.command(command: "new")) }

case let .setModel(provider, modelId):
    Task {
        await client.send(.command(
            command: "set_model",
            args: ["provider": .string(provider), "modelId": .string(modelId)]
        ))
    }

case let .compact(instructions):
    var args: [String: AnyCodableValue] = [:]
    if let instructions, !instructions.isEmpty {
        args["instructions"] = .string(instructions)
    }
    Task { await client.send(.command(command: "compact", args: args)) }

case let .rename(name):
    Task {
        await client.send(.command(
            command: "name",
            args: ["name": .string(name)]
        ))
    }
```

- [ ] **Step 3: Update handleError for new error codes**

At `CodeViewModel+Errors.swift:25` (the `guard error.code == "not_idle" else { return }` line), replace with a switch that handles the six new codes:

```swift
func handleError(_ error: CodeServerError) {
    if error.code == "compaction_failed" {
        transientToast = error.message
            ?? String(localized: "Compaction failed")
        return
    }

    switch error.code {
    case "not_idle":
        transientToast = error.message
            ?? String(localized: "Cannot send while streaming")
        markPendingEchoFailed()

    case "not_ready":
        transientToast = error.message
            ?? String(localized: "Session loading, try again shortly")

    case "stale_session":
        transientToast = error.message
            ?? String(localized: "Session replaced — run /rc in terminal")

    case "model_not_found":
        transientToast = error.message
            ?? String(localized: "Model not found")

    case "model_not_set":
        transientToast = error.message
            ?? String(localized: "Model unavailable (no provider auth)")

    case "command_failed":
        transientToast = error.message
            ?? String(localized: "Command failed")

    case "unknown_command":
        transientToast = error.message
            ?? String(localized: "Unknown command")

    default:
        break
    }
}
```

- [ ] **Step 4: Fix event filter for "unknown" sessionId**

At `CodeViewModel+Messages.swift:91`, the event filter is:

```swift
guard event.sessionId == session.sessionId else { return }
```

Add an exception so events still flow when the session's stored id is "unknown":

```swift
guard event.sessionId == session.sessionId
    || session.sessionId == "unknown" else { return }
```

Wait — actually, the spec says during the `unknown` window, event frames should be DROPPED (verified fact 12: "while session.sessionId == 'unknown', the event filter drops ALL event frames until the next real state frame"). But with the Task 6 Step 4 change, the "unknown" state frame returns early before setting `session.sessionId`, so `session.sessionId` keeps its previous value (e.g., the old session's id). Events from the old session still match by id; events from the new session won't match until the `session_start` state frame arrives with the real id. This is correct behavior — no change needed here.

Skip this step — the "unknown" pin in Task 6 Step 4 handles it correctly by never storing "unknown" as the sessionId.

- [ ] **Step 5: Build iOS**

Run: `xcodebuild build ...`

- [ ] **Step 6: Commit**

```bash
git add openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel.swift \
  openclient-llm/Shared/Features/Code/ViewModels/CodeViewModel+Errors.swift
git commit -m "Add command events to CodeViewModel, handle new error codes with toasts"
```

---

### Task 8: Harness — group 14 (WS commands)

**Files:**
- Modify: `pi-extensions/rc/test-client.mjs` (add group 14 tests after group 13, before group 15)

Spec test plan items 1-12. Key patterns to reuse from existing groups:
- Group 0/3 settle pattern for prompt→turn_end
- Group 12 "Reply with exactly: PING-xN" pattern for seeding content
- Group 13 long-generation + abort pattern
- Group 12 question harness pattern for the Stop-cancels-ask test

- [ ] **Step 1: Implement group 14 helper: waitForSessionStart**

A helper that waits for a `state` frame with a new sessionId (different from the provided current one) — used after `command new`.

- [ ] **Step 2: T1 — command new while idle**

```
registerTest(14, 'command new (idle)', async (ws, opts) => { ... })
```
Send `{type:'command', command:'new'}`, wait for `session_start` + state snapshot with new sessionId. Assert sessionId changed, client stays connected.

- [ ] **Step 3: T2 — command new while streaming**

Start a long generation, send `command new` mid-stream. Assert: turn_end with stopReason "aborted" (old sessionId) arrives before session_start; snapshot reflects the new session.

- [ ] **Step 4: T3 — chained command new (withSession stash)**

Two sequential `command new` calls. Both succeed; second sees the sessionId from the first new session.

- [ ] **Step 5: T4 — command set_model**

Read `models` from state frame. If ≥ 2 entries, pick one different from current model, send `{type:'command', command:'set_model', provider, modelId}`. Wait for state broadcast with the new model. Unknown ref → `model_not_found`. Env-conditioned skip if < 2 models.

- [ ] **Step 6: T5 — command compact (mid-stream, seeded)**

Seed with a couple of prompt/turn exchanges. Start a live run, send `command compact`. Assert: abort tail + session_compact snapshot; history includes compaction entry.

- [ ] **Step 7: T6 — command name**

Send `{type:'command', command:'name', name:'test-rename'}`. Assert: state broadcast with new sessionName. Empty name → `unknown_command`.

- [ ] **Step 8: T7 — unknown command**

Send `{type:'command', command:'nonexistent'}`. Assert: `unknown_command` error.

- [ ] **Step 9: T8 — second command new while first in-flight → not_ready**

Start a long generation, send `command new` (async, don't await), immediately send another `command new`. Assert: second gets `not_ready`.

- [ ] **Step 10: T9 — near-empty compact → command_failed**

Issue `command new` to get fresh session, then `command compact`. Assert: `command_failed` error (or `compaction_failed` error frame — the session_compact_failed event fires).

- [ ] **Step 11: T10 — abort while remote question pending → question_resolved**

Use the existing question harness pattern. Trigger a question, then send `abort`. Assert: `question_resolved {by:'cancelled'}` + turn settles.

- [ ] **Step 12: T11 — stale_session after RPC new_session**

Issue RPC `new_session` (non-rc path), then `command new`. Assert: `stale_session` error. Run LAST in group.

- [ ] **Step 13: Run the full harness**

Run: `cd pi-extensions && node rc/test-client.mjs`
Expected: All groups pass (including new group 14).

- [ ] **Step 14: Commit**

```bash
git add pi-extensions/rc/test-client.mjs
git commit -m "Add harness group 14: rc remote command tests"
```

---

### Task 9: Swift unit tests

**Files:**
- Modify: existing test file or create if needed in `openclient-llm-test/`

- [ ] **Step 1: Command frame encoding tests**

Test all four shapes encode correctly:
- `.command(command: "new")` → `{"type":"command","command":"new"}`
- `.command(command: "set_model", args: ["provider": .string("x"), "modelId": .string("y")])` → correct JSON
- `.command(command: "compact", args: ["instructions": .string("focus on X")])` → correct JSON
- `.command(command: "compact")` → no `instructions` key
- `.command(command: "name", args: ["name": .string("test")])` → correct JSON

- [ ] **Step 2: CodeSessionInfo decode with and without models**

Decode a state JSON with `models: [{provider:"a", id:"b"}]` → `info.models` has one entry.
Decode a state JSON without `models` → `info.models` is nil.

- [ ] **Step 3: Error code decode — new codes + forward-unknown**

Decode `{"code":"stale_session","message":"run /rc"}` → `CodeServerError(code: "stale_session", ...)`.
Decode `{"code":"future_error_code","message":"x"}` → decodes fine (String is lenient).

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -project openclient-llm.xcodeproj -scheme openclient-llm -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO -skipPackageUpdates -skipMacroValidation OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'`

- [ ] **Step 5: Commit**

```bash
git add openclient-llm-test/
git commit -m "Add Swift tests for rc command encoding, models decode, error codes"
```

---

## Notes

- **Decision 7 (Stop fix)** is already implemented in commit d5869ac. No changes needed in ask-user-question/index.ts.
- **UI** (command sheet, models picker, rename alert) is deferred per spec: "describe at spec level; implement later per the design-ui/chat-visual-style specs." This plan covers the wire protocol, models, and ViewModel event plumbing — the UI layer will be a follow-up.
- **Security**: `compact.instructions` and `name` are phone-authored input → auth-gated by the hello handshake. No additional sanitization needed server-side (pi's own normalization handles names; compact instructions flow into the summarization prompt which pi controls).
- **compaction_failed reason gate**: The spec says broadcast `command_failed` only when `event.reason === "manual"`. But the EXISTING `session_compact_failed` handler already broadcasts `compaction_failed` for non-aborted failures. Review whether the existing handler needs a reason gate or whether both codes should coexist.

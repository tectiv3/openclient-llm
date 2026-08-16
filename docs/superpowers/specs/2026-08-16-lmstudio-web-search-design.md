# LM Studio Web Search Integration

## Problem

The web search toggle (globe button) and settings are wired exclusively for LiteLLM mode. In LM Studio mode:

- `isWebSearchToolConfigured` checks `getWebSearchToolName()` (LiteLLM-only), so the globe button never enables.
- `streamWithWebSearch` routes to `performLMStudioChat` which ignores `webSearchEnabled`.
- The settings web search section shows LiteLLM-specific UI (search tool picker, fetch button) regardless of server type.

LM Studio provides web search via plugins (e.g. `npacker/web-tools`) that are passed as `integrations` in the Responses API request. LM Studio does not expose an API to list installed plugins.

## Design

### 1. Settings Storage

**New setting in `SettingsManager`:**
- `lmStudioWebSearchPluginId` — String, defaults to empty. Stores the LM Studio plugin ID (e.g. `npacker/web-tools`).
- Add `Keys.lmStudioWebSearchPluginId` constant.
- Add `getLMStudioWebSearchPluginId()` and `setLMStudioWebSearchPluginId(_:)` to both `SettingsManagerProtocol` and `SettingsManager`.
- Add `defaults.removeObject(forKey: Keys.lmStudioWebSearchPluginId)` to `deleteAll()`.

**Server-type-aware configuration check:**
- LiteLLM: `!getWebSearchToolName().isEmpty` (unchanged)
- LM Studio: `!getLMStudioWebSearchPluginId().isEmpty`

The existing `isWebSearchEnabled` bool is shared across both modes.

**Edge case — server type switch:** If web search is enabled in LiteLLM mode and the user switches to LM Studio mode without configuring a plugin ID, `isWebSearchToolConfigured` becomes false and the globe button shows as unavailable. This is acceptable — the toggle state persists but is inert until a plugin ID is set.

### 2. Settings UI — Web Search Section

`SettingsView+WebSearch.swift` adapts based on `loadedState.serverType`:

**LiteLLM mode** (unchanged): status label, search tool picker, "Load Available Tools" button, results stepper, footer referencing LiteLLM server.

**LM Studio mode**: text field for the plugin ID, no fetch button, no results stepper. Footer: "Enter the plugin ID installed in LM Studio."

### 3. Chat Path — Integration Injection

When building `SendMessageContext` in `performSend` (`ChatViewModel+Message.swift`):
- If `serverType == .lmStudio` and `webSearchEnabled == true` and a web search plugin ID is configured, inject `.plugin(id: pluginId)` into `mcpIntegrations`.
- This is a runtime merge — the stored global integrations and conversation integrations are not modified.
- If the plugin is already in the integrations (user added it manually as a global integration), do not duplicate it.

No changes to `performLMStudioChat`, `LMStudioChatRequest`, or `LMStudioChatResponse`.

**Routing dependency:** The injection ensures `mcpIntegrations` is non-empty, which routes through `performLMStudioChat` (the `if !context.mcpIntegrations.isEmpty` branch in `streamWithWebSearch`). This is intentional — even with no other integrations, the web search plugin alone triggers the LM Studio path.

### 4. Globe Button Gating

In `ChatViewModel+MCP.swift`, `isWebSearchToolConfigured` is set based on server type:
- LiteLLM: `!getChatPreferencesUseCase.getWebSearchToolName().isEmpty`
- LM Studio: `!getLMStudioWebSearchPluginId().isEmpty` (read from settings manager or passed through use case)

The model capability check (`modelCapabilities.contains(.functionCalling)`) in `toggleWebSearch` works as-is — LM Studio models with `trainedForToolUse == true` already have `.functionCalling`.

### 5. Settings ViewModel

`SettingsViewModel.LoadedState` gains:
- `lmStudioWebSearchPluginId: String`

New event:
- `.lmStudioWebSearchPluginIdChanged(String)`

The event routes through `handleWebSearchEvent` (alongside existing `.webSearchToolNameChanged` and `.webSearchMaxResultsChanged`). Handler persists to `SettingsManager` and updates loaded state.

`loadSettings()` must include the new field when constructing `LoadedState`:
- `lmStudioWebSearchPluginId: settingsManager.getLMStudioWebSearchPluginId()`

## Files Changed

| File | Change |
|------|--------|
| `SettingsManager.swift` | Add `lmStudioWebSearchPluginId` storage key, getter, setter, reset |
| `SettingsViewModel.swift` | Add `lmStudioWebSearchPluginId` to LoadedState, add event + handler |
| `SettingsView+WebSearch.swift` | Branch UI by server type: text field for LM Studio, existing picker for LiteLLM |
| `ChatViewModel+MCP.swift` | Make `isWebSearchToolConfigured` server-type-aware |
| `ChatViewModel+Message.swift` | Inject web search plugin into integrations when building context |
| `GetChatPreferencesUseCase.swift` | Add `getLMStudioWebSearchPluginId()` to both protocol and struct |
| `MockSettingsManager.swift` | Add protocol-required `getLMStudioWebSearchPluginId()` / `setLMStudioWebSearchPluginId(_:)` stubs |
| `MockGetChatPreferencesUseCase.swift` | Add `getLMStudioWebSearchPluginId()` stub |

## Constraints

- No new files or types needed.
- No changes to LM Studio request/response models.
- No changes to `MCPIntegration` enum.
- The "Results" stepper is LiteLLM-only (LM Studio plugins handle result count internally).

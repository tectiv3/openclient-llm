//
//  SettingsView.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 30/03/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI
import TipKit
#if os(iOS)
import StoreKit
import SwiftUI
#endif

struct SettingsView: View {
    // MARK: - Properties

    @State var viewModel = SettingsViewModel()
    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var isAPIKeyVisible = false
    @State private var isShowingUserProfile = false
    @State private var isShowingMemory = false
    @State private var isShowingDefaultSystemPrompt = false
    @State private var isShowingPromptLibrary = false
    @State var isShowingHelp = false
    @State var isShowingTipJar = false
    @State private var showResetAlert = false
    @State var mcpServerSheet: MCPServerInfo?
    @State var isAddingGlobalIntegration = false
    @State private var newGlobalIntegrationId = ""
    @State var presentedWebURL: WebDestination?
    @State private var canShowMemoryTip = false
    @State private var shouldRequestReviewAfterSync = false
    @FocusState private var focusedField: Field?
    @Environment(\.scenePhase) private var scenePhase
    private let liteLLMHintText = String(localized: "Optimised for LiteLLM. Any OpenAI-compatible server also works.")
    private let settingsManager: SettingsManagerProtocol = SettingsManager()
    private let appReviewManager: AppReviewManagerProtocol = AppReviewManager()

    // MARK: - View

    var body: some View {
#if os(iOS)
        NavigationStack {
            settingsContent
        }
#else
        settingsContent
#endif
    }
}

// MARK: - Private

private extension SettingsView {
    var settingsContent: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .tint(.secondary)
            case .loaded(let loadedState):
                loadedView(loadedState)
            }
        }
        .navigationTitle(String(localized: "Settings"))
        .sheet(item: $presentedWebURL) { destination in
            if let url = destination.url {
                WebContentView(title: destination.title, url: url)
            }
        }
        .sheet(isPresented: $isShowingUserProfile) {
            UserProfileView()
        }
        .sheet(isPresented: $isShowingMemory) {
            MemoryView()
#if os(macOS)
                .frame(width: 500, height: 460)
#endif
        }
        .sheet(isPresented: $isShowingDefaultSystemPrompt) {
            defaultSystemPromptSheet
#if os(macOS)
                .frame(width: 500, height: 460)
#endif
        }
        .sheet(isPresented: $isShowingHelp) {
            HelpView()
#if os(macOS)
                .frame(width: 500, height: 460)
#endif
        }
        .sheet(isPresented: $isShowingTipJar) {
            TipJarView()
#if os(macOS)
                .frame(width: 500, height: 460)
#endif
        }
        .alert(
            String(localized: "iCloud Sync Conflict"),
            isPresented: cloudSyncConflictBinding,
            actions: {
                Button(String(localized: "Use Local Data")) {
                    viewModel.send(.cloudSyncConflictResolved(keepLocal: true))
                }
                Button(String(localized: "Use iCloud Data")) {
                    viewModel.send(.cloudSyncConflictResolved(keepLocal: false))
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    viewModel.send(.cloudSyncConflictCancelled)
                }
                .buttonStyle(.plain)
            },
            message: {
                Text(String(
                    localized: "Your local personal context differs from iCloud. Which version would you like to keep?"
                ))
            }
        )
        .alert(
            String(localized: "Reset App Data"),
            isPresented: $showResetAlert
        ) {
            Button(String(localized: "Reset"), role: .destructive) {
                canShowMemoryTip = false
                viewModel.send(.resetConfirmed)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(
                localized: "All local settings and credentials will be deleted. iCloud data will not be affected."
            ))
        }
        .alert(String(localized: "Add Integration"), isPresented: $isAddingGlobalIntegration) {
            TextField(String(localized: "mcp/server-name"), text: $newGlobalIntegrationId)
                .autocorrectionDisabled()
            Button(String(localized: "Add")) {
                let id = newGlobalIntegrationId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { return }
                viewModel.send(.globalIntegrationAdded(.plugin(id: id)))
                newGlobalIntegrationId = ""
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                newGlobalIntegrationId = ""
            }
        } message: {
            Text(String(localized: "Enter the MCP plugin ID as configured in your LM Studio mcp.json."))
        }
        .task {
            viewModel.send(.viewAppeared)
            if case .loaded(let initialState) = viewModel.state {
                serverURL = initialState.serverURL
                apiKey = initialState.apiKey
            }
            canShowMemoryTip = settingsManager.getHasEnoughConversationsForMemoryTip()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.send(.notificationStatusRefresh)
            }
        }
        .onChange(of: viewModel.state) { _, newState in
            if case .loaded(let loadedState) = newState {
                serverURL = loadedState.serverURL
                apiKey = loadedState.apiKey
            }
        }
        .onDisappear(perform: requestReviewAfterSuccessfulSyncIfNeeded)
    }

    enum Field {
        case serverURL
        case apiKey
    }

    var cloudSyncConflictBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .loaded(let loadedState) = viewModel.state else { return false }
                return loadedState.showCloudSyncConflictAlert
            },
            set: { newValue in
                if !newValue {
                    viewModel.send(.cloudSyncConflictCancelled)
                }
            }
        )
    }

    func loadedView(_ loadedState: SettingsViewModel.LoadedState) -> some View {
        VStack(spacing: 0) {
            Form {
                serverSection(loadedState)
                cloudSyncSection(loadedState)
                personalizationSection()
                chatSection(loadedState)
                webSearchSection(loadedState)
                if loadedState.serverType == .liteLLM {
                    mcpSection(loadedState)
                } else {
                    globalIntegrationsSection(loadedState)
                }
                supportSection()
                legalSection()
                dangerSection()
            }
#if os(iOS)
            .scrollDismissesKeyboard(.immediately)
#elseif os(macOS)
            .formStyle(.grouped)
#endif
        }
        .sheet(item: $mcpServerSheet) { server in
            mcpToolSheet(server: server, loadedState: loadedState)
#if os(macOS)
                .frame(minWidth: 500, maxWidth: 500, minHeight: 460, maxHeight: 460)
#endif
        }
    }

    func serverSection(_ loadedState: SettingsViewModel.LoadedState) -> some View {
        Section {
            serverURLField()
            apiKeyField()
            serverTypePicker(loadedState)
            connectionStatusView(loadedState.connectionStatus)
            Button {
                focusedField = nil
                viewModel.send(.testConnectionTapped)
            } label: {
                HStack(spacing: 8) {
                    if loadedState.connectionStatus == .testing {
                        ProgressView()
                            .tint(.secondary)
                            .controlSize(.small)
                    }
                    Text(
                        loadedState.connectionStatus == .testing
                        ? String(localized: "Testing...")
                        : String(localized: "Test Connection")
                    )
                }
            }
            .disabled(loadedState.serverURL.isEmpty || loadedState.connectionStatus == .testing)
            .buttonStyle(.plain)

            Button {
                focusedField = nil
                viewModel.send(.saveTapped)
            } label: {
                HStack {
                    Text(String(localized: "Save"))
                    Spacer()
                    if loadedState.isSaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text(String(localized: "Server"))
        } footer: {
            if loadedState.serverType == .liteLLM, loadedState.showLiteLLMHint {
                Label(liteLLMHintText, systemImage: "info.circle").foregroundStyle(.secondary)
            }
        }
    }

    func serverURLField() -> some View {
        TextField(
            String(localized: "Server URL"),
            text: $serverURL
        )
        .focused($focusedField, equals: .serverURL)
        .textSelection(.enabled)
        .textContentType(.URL)
        .autocorrectionDisabled()
#if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
#endif
        .onChange(of: serverURL) { _, newValue in
            viewModel.send(.serverURLChanged(newValue))
        }
    }

    func apiKeyField() -> some View {
        HStack {
            Group {
                if isAPIKeyVisible {
                    TextField(
                        String(localized: "API Key (Optional)"),
                        text: $apiKey
                    )
                    .focused($focusedField, equals: .apiKey)
                } else {
                    SecureField(
                        String(localized: "API Key (Optional)"),
                        text: $apiKey
                    )
                    .focused($focusedField, equals: .apiKey)
                }
            }
            .textSelection(.enabled)

            Button {
                isAPIKeyVisible.toggle()
            } label: {
                Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isAPIKeyVisible
                ? String(localized: "Hide API Key")
                : String(localized: "Show API Key")
            )
        }
        .onChange(of: apiKey) { _, newValue in
            viewModel.send(.apiKeyChanged(newValue))
        }
    }

    func serverTypePicker(_ loadedState: SettingsViewModel.LoadedState) -> some View {
        Picker(selection: Binding(
            get: { loadedState.serverType },
            set: { viewModel.send(.serverTypeChanged($0)) }
        )) {
            ForEach(ServerType.allCases, id: \.self) { type in
                Text(type.displayName).tag(type)
            }
        } label: {
            Label(String(localized: "Server Type"), systemImage: "server.rack")
        }
    }

    @ViewBuilder
    func connectionStatusView(_ status: SettingsViewModel.ConnectionStatus) -> some View {
        switch status {
        case .idle, .testing:
            EmptyView()
        case .success:
            Label(String(localized: "Connection successful"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    func cloudSyncSection(_ loadedState: SettingsViewModel.LoadedState) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { loadedState.isCloudSyncEnabled },
                set: { viewModel.send(.cloudSyncToggled($0)) }
            )) {
                Label(String(localized: "iCloud Sync"), systemImage: "icloud")
            }
            .disabled(!loadedState.isCloudAvailable)

            if loadedState.isCloudSyncEnabled {
                Button(String(localized: "Sync Now")) {
                    synchronizeConversations()
                }
            }

            if !loadedState.isCloudAvailable {
                Label(
                    String(localized: "Sign in to iCloud to enable sync"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Sync"))
        } footer: {
            Text(cloudSyncFooter(loadedState.conversationSyncResult))
        }
    }

    func cloudSyncFooter(_ result: ConversationSyncResult?) -> String {
        switch result {
        case .synchronized:
            return String(localized: "Conversations are synchronized across your devices via iCloud.")
        case .pendingDownload:
            return String(localized: "iCloud is downloading changes. Sync will continue automatically.")
        case .unavailable:
            return String(localized: "iCloud is unavailable. Your changes will stay on this device until sync resumes.")
        case .failed:
            return String(localized: "Sync could not finish. Your changes remain safely stored on this device.")
        case nil:
            return String(localized: "Sync conversations across your devices via iCloud.")
        }
    }

    func chatSection(_ loadedState: SettingsViewModel.LoadedState) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { loadedState.showTokenUsage },
                set: { viewModel.send(.showTokenUsageToggled($0)) }
            )) {
                Label(String(localized: "Show Token Usage"), systemImage: "number")
            }
#if os(iOS)
            Toggle(isOn: Binding(
                get: { loadedState.isPrivacyScreenEnabled },
                set: { viewModel.send(.privacyScreenToggled($0)) }
            )) {
                Label(String(localized: "Hide Content in App Switcher"), systemImage: "lock.shield")
            }
#endif
            switch loadedState.notificationPermissionStatus {
            case .authorized:
                Label(String(localized: "Notifications enabled"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label(String(localized: "Notifications disabled"), systemImage: "bell.slash")
                    .foregroundStyle(.secondary)
#if os(iOS)
                Button {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label(String(localized: "Open Settings"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
#endif
            case .notDetermined:
                Label(String(localized: "Notifications not authorized"), systemImage: "bell.badge.slash")
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.send(.requestNotificationPermissionTapped)
                } label: {
                    Label(String(localized: "Enable Notifications"), systemImage: "bell")
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(String(localized: "Chat"))
        } footer: {
            Text(String(localized: "Sent when a response finishes while the app is in the background."))
        }
    }

    func personalizationSection() -> some View {
        Section {
            Button {
                isShowingUserProfile = true
            } label: {
                Label(String(localized: "Personal Context"), systemImage: "person.text.rectangle")
            }
            .buttonStyle(.plain)

            Button {
                AppTips.memory.invalidate(reason: .actionPerformed)
                isShowingMemory = true
            } label: {
                Label(String(localized: "Memory"), systemImage: "brain.head.profile")
            }
            .buttonStyle(.plain)
            .popoverTip(canShowMemoryTip ? AppTips.memory : nil)

            Button {
                isShowingDefaultSystemPrompt = true
            } label: {
                Label(String(localized: "Default System Prompt"), systemImage: "text.bubble")
            }
            .buttonStyle(.plain)
        } header: {
            Text(String(localized: "Personalization"))
        } footer: {
            Text(String(localized: "Configure your personal context, memory, and default system prompt to personalise model responses."))
        }
    }

    var defaultSystemPromptSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .center) {
                        Text(String(localized: "Pre-fills new conversations. Can be changed per conversation."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            isShowingPromptLibrary = true
                        } label: {
                            Label(String(localized: "Browse Library"), systemImage: "books.vertical")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    TextEditor(text: Binding(
                        get: {
                            guard case .loaded(let loadedState) = viewModel.state else { return "" }
                            return loadedState.defaultSystemPrompt
                        },
                        set: { viewModel.send(.defaultSystemPromptChanged($0)) }
                    ))
                    .frame(minHeight: 200)
                } header: {
                    Text(String(localized: "Default System Prompt"))
                }
            }
            .navigationTitle(String(localized: "Default System Prompt"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        isShowingDefaultSystemPrompt = false
                    }
                }
            }
#endif
            .sheet(isPresented: $isShowingPromptLibrary) {
                PromptTemplatesView { template in
                    viewModel.send(.defaultSystemPromptChanged(template.content))
                }
            }
        }
    }

    func synchronizeConversations() {
        viewModel.send(.syncConversationsTapped)
        guard case .loaded(let loadedState) = viewModel.state,
              loadedState.conversationSyncResult == .synchronized else { return }
        shouldRequestReviewAfterSync = true
    }

    func requestReviewAfterSuccessfulSyncIfNeeded() {
        guard shouldRequestReviewAfterSync else { return }
        shouldRequestReviewAfterSync = false
        appReviewManager.requestReview()
    }

    func dangerSection() -> some View {
        Section {
            Button {
                showResetAlert = true
            } label: {
                Label(String(localized: "Reset App Data"), systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        } header: {
            Text(String(localized: "App Data"))
        } footer: {
            Text(String(localized: "Deletes all local settings and credentials. iCloud data will not be affected."))
        }
    }
}

#Preview {
    SettingsView()
}

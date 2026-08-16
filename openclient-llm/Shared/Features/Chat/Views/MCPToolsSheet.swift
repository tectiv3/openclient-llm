//
//  MCPToolsSheet.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 25/07/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct MCPToolsSheet: View {
    @Bindable var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    @State private var isAddingIntegration = false
    @State private var newIntegrationId = ""

    var body: some View {
        Group {
            if case .loaded(let loadedState) = viewModel.state {
                loadedContent(loadedState)
            }
        }
    }
}

private extension MCPToolsSheet {
    func loadedContent(_ loadedState: ChatViewModel.LoadedState) -> some View {
        NavigationStack {
            List {
                integrationsSection(loadedState)
                if loadedState.isLoadingMCPTools {
                    Section {
                        HStack {
                            Spacer()
                            VStack {
                                ProgressView().tint(.secondary)
                                Text(String(localized: "Loading tools..."))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                            }
                            Spacer()
                        }
                    }
                } else if !loadedState.availableMCPServers.isEmpty {
                    discoveredServersSection(loadedState)
                }
            }
            .navigationTitle(String(localized: "MCP Servers"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { doneToolbar }
            .toolbar { refreshToolbar(loadedState: loadedState) }
            .alert(String(localized: "Add Integration"), isPresented: $isAddingIntegration) {
                TextField(String(localized: "mcp/server-name"), text: $newIntegrationId)
                    .autocorrectionDisabled()
                Button(String(localized: "Add")) {
                    let id = newIntegrationId.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { return }
                    viewModel.send(.mcpIntegrationAdded(.plugin(id: id)))
                    newIntegrationId = ""
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    newIntegrationId = ""
                }
            } message: {
                Text(String(localized: "Enter the MCP plugin ID as configured in your LM Studio mcp.json."))
            }
        }
    }

    func integrationsSection(_ loadedState: ChatViewModel.LoadedState) -> some View {
        Section {
            if loadedState.mcpIntegrations.isEmpty {
                Label(
                    String(localized: "No integrations configured for this conversation."),
                    systemImage: "puzzlepiece.extension"
                )
                .foregroundStyle(.secondary)
                .font(.subheadline)
            } else {
                ForEach(loadedState.mcpIntegrations, id: \.self) { integration in
                    integrationRow(integration)
                }
                .onDelete { indexSet in
                    let integrations = loadedState.mcpIntegrations
                    for index in indexSet {
                        viewModel.send(.mcpIntegrationRemoved(integrations[index]))
                    }
                }
            }
            Button {
                isAddingIntegration = true
            } label: {
                Label(String(localized: "Add Integration"), systemImage: "plus")
            }
        } header: {
            Text(String(localized: "LM Studio Integrations"))
        } footer: {
            Text(String(
                localized: "Server-side MCP tools handled by LM Studio. Register servers in LM Studio's mcp.json first."
            ))
        }
    }

    func integrationRow(_ integration: MCPIntegration) -> some View {
        HStack {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(integration.displayName)
                    .font(.body)
                switch integration {
                case .plugin:
                    Text(String(localized: "Plugin"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ephemeral(_, let url, _, _):
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    func discoveredServersSection(_ loadedState: ChatViewModel.LoadedState) -> some View {
        Section(String(localized: "Discovered Servers")) {
            ForEach(loadedState.availableMCPServers) { server in
                let serverTools = loadedState.toolsForServer(server.serverId)
                NavigationLink {
                    serverDetailView(
                        server: server,
                        tools: serverTools,
                        loadedState: loadedState
                    )
                } label: {
                    serverRow(server: server, tools: serverTools, loadedState: loadedState)
                }
            }
        }
    }

    func serverRow(
        server: MCPServerInfo,
        tools: [MCPToolInfo],
        loadedState: ChatViewModel.LoadedState
    ) -> some View {
        let enabled = tools.filter { loadedState.enabledMCPToolIds.contains($0.id) }.count
        return HStack {
            Image(systemName: enabled > 0 ? "server.rack" : "server.rack")
                .foregroundStyle(enabled > 0 ? Color.appAccent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.serverName)
                    .font(.headline)
                if let description = server.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(String(localized: "\(enabled)/\(tools.count)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func serverDetailView(
        server: MCPServerInfo,
        tools: [MCPToolInfo],
        loadedState: ChatViewModel.LoadedState
    ) -> some View {
        let allEnabled = tools.allSatisfy { loadedState.enabledMCPToolIds.contains($0.id) }
        let serverId = server.serverName
        return List {
            Section {
                Toggle(isOn: Binding(
                    get: { allEnabled },
                    set: { enable in
                        for tool in tools {
                             viewModel.send(.mcpToolToggled(
                                 toolId: tool.id,
                                enabled: enable
                            ))
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Enable All Tools"))
                            .font(.headline)
                        let count = tools.count
                        Text(String(localized: "\(count) tool(s) available"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            Section {
                ForEach(tools) { tool in
                    mcpToolRow(tool, loadedState: loadedState)
                }
            }
        }
        .navigationTitle(serverId)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    func mcpToolRow(
        _ tool: MCPToolInfo,
        loadedState: ChatViewModel.LoadedState
    ) -> some View {
        let isEnabled = loadedState.enabledMCPToolIds.contains(tool.id)
        return Toggle(isOn: Binding(
            get: { isEnabled },
            set: { enabled in
                viewModel.send(.mcpToolToggled(toolId: tool.id, enabled: enabled))
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                if let description = tool.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ToolbarContentBuilder
    var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(String(localized: "Done")) {
                isPresented = false
            }
        }
    }

    @ToolbarContentBuilder
    func refreshToolbar(loadedState: ChatViewModel.LoadedState?) -> some ToolbarContent {
        let isLoading = loadedState?.isLoadingMCPTools ?? false
        ToolbarItem(placement: .cancellationAction) {
            Button {
                viewModel.send(.mcpToolsRefreshed)
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isLoading)
            .accessibilityLabel(String(localized: "Refresh"))
        }
    }
}

// MARK: - Helpers

extension ChatViewModel.LoadedState {
    func toolsForServer(_ serverId: String) -> [MCPToolInfo] {
        availableMCPTools.filter { $0.serverId == serverId }
    }
}

#Preview {
    let servers = [
        MCPServerInfo(serverId: "gh", serverName: "github", description: "Manage repos, issues, PRs", allowedTools: nil)
    ]
    let tool1 = MCPToolInfo(name: "search_issues", description: "Search GitHub issues",
        serverId: "gh", serverName: "github", inputSchema: nil)
    let tool2 = MCPToolInfo(name: "create_pr", description: "Create a pull request",
        serverId: "gh", serverName: "github", inputSchema: nil)
    return MCPToolsSheet(
        viewModel: ChatViewModel(state: .loaded(ChatViewModel.LoadedState(
            isMCPSupported: true,
            availableMCPTools: [tool1, tool2],
            availableMCPServers: servers,
            enabledMCPToolIds: ["gh-search_issues"]
        ))),
        isPresented: .constant(true)
    )
}

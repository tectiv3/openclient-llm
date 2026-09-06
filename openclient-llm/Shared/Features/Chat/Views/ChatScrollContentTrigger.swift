//
//  ChatScrollContentTrigger.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation

struct ChatScrollContentTrigger: Equatable {
    let lastMessage: ChatMessage?
    let isStreaming: Bool
    let contextUsage: ContextUsage?
    let hasActiveToolCalls: Bool
    let errorMessage: String?
    let showTokenUsage: Bool

    init(loadedState: ChatViewModel.LoadedState) {
        lastMessage = loadedState.messages.last
        isStreaming = loadedState.isStreaming
        contextUsage = loadedState.contextUsage
        hasActiveToolCalls = !loadedState.activeToolCallIds.isEmpty
        errorMessage = loadedState.errorMessage
        showTokenUsage = loadedState.showTokenUsage
    }
}

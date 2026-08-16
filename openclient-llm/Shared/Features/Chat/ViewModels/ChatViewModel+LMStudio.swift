//
//  ChatViewModel+LMStudio.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 16/08/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

// MARK: - LM Studio chat helpers

extension ChatViewModel {
    func performLMStudioChat(_ context: SendMessageContext) async {
        do {
            let input = context.text.isEmpty
                ? context.messages.last(where: { $0.role == .user })?.content ?? ""
                : context.text
            let response = try await lmStudioChatUseCase.execute(
                input: input,
                model: context.modelId,
                systemPrompt: context.systemPrompt,
                parameters: parametersCappedToModelOutput(context.parameters, model: context.selectedModel),
                contextWindowTokens: context.contextWindowTokens ?? context.selectedModel.maxInputTokens,
                previousResponseId: context.lmStudioResponseId,
                integrations: context.mcpIntegrations
            )
            applyLMStudioResponse(response, assistantMessageId: context.assistantId)
            await finishStreaming(context.assistantId, model: context.modelId)
        } catch {
            handleLMStudioError(error, assistantMessageId: context.assistantId, model: context.modelId)
        }
    }
}

// MARK: - Private

private extension ChatViewModel {
    func applyLMStudioResponse(_ response: LMStudioChatResponse, assistantMessageId: UUID) {
        guard isActiveStream(assistantMessageId), case .loaded(var currentState) = state,
              let index = currentState.messages.firstIndex(where: { $0.id == assistantMessageId }) else { return }
        for output in response.output {
            switch output.type {
            case "message":
                currentState.messages[index].content += output.content ?? ""
            case "reasoning":
                currentState.messages[index].reasoningContent =
                    (currentState.messages[index].reasoningContent ?? "") + (output.content ?? "")
            default:
                continue
            }
        }
        if let stats = response.stats {
            let outputTokens = stats.totalOutputTokens ?? 0
            currentState.messages[index].tokenUsage = TokenUsage(
                promptTokens: stats.inputTokens ?? 0,
                completionTokens: outputTokens,
                totalTokens: (stats.inputTokens ?? 0) + outputTokens,
                tokensPerSecond: stats.tokensPerSecond
            )
        }
        currentState.conversation?.lmStudioResponseId = response.responseId
        state = .loaded(currentState)
    }

    func handleLMStudioError(_ error: Error, assistantMessageId: UUID, model: String) {
        guard !Task.isCancelled, isActiveStream(assistantMessageId), case .loaded(var currentState) = state else {
            return
        }
        LogManager.error("performLMStudioChat error model=\(model): \(error)")
        if let index = currentState.messages.firstIndex(where: { $0.id == assistantMessageId }),
           currentState.messages[index].content.isEmpty {
            currentState.messages.remove(at: index)
        }
        currentState.isStreaming = false
        currentState.errorMessage = error.localizedDescription
        state = .loaded(currentState)
        scheduleErrorDismiss()
        persistConversation()
        streamingBackgroundUseCase.end()
        completeActiveStream(assistantMessageId)
    }
}

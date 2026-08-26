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
        let input = context.text.isEmpty
            ? context.messages.last(where: { $0.role == .user })?.content ?? ""
            : context.text
        let stream = lmStudioChatUseCase.stream(
            input: input,
            model: context.modelId,
            systemPrompt: context.systemPrompt,
            parameters: parametersCappedToModelOutput(context.parameters, model: context.selectedModel),
            contextWindowTokens: context.contextWindowTokens ?? context.selectedModel.maxInputTokens,
            previousResponseId: context.lmStudioResponseId,
            integrations: context.mcpIntegrations
        )
        streamStartTime = ContinuousClock.now

        do {
            for try await chunk in stream {
                guard !Task.isCancelled, isActiveStream(context.assistantId),
                      case .loaded(var currentState) = state else { return }
                applyLMStudioChunk(chunk, to: &currentState, assistantMessageId: context.assistantId)
                state = .loaded(currentState)
            }
            await finishStreaming(context.assistantId, model: context.modelId)
        } catch {
            handleLMStudioError(error, assistantMessageId: context.assistantId, model: context.modelId)
        }
    }
}

// MARK: - Private

private extension ChatViewModel {
    func applyLMStudioChunk(
        _ chunk: LMStudioStreamChunk,
        to state: inout LoadedState,
        assistantMessageId: UUID
    ) {
        switch chunk {
        case .token(let text):
            guard let index = state.messages.firstIndex(where: { $0.id == assistantMessageId }) else { return }
            state.messages[index].content += text
        case .reasoning(let text):
            guard let index = state.messages.firstIndex(where: { $0.id == assistantMessageId }) else { return }
            state.messages[index].reasoningContent = (state.messages[index].reasoningContent ?? "") + text
        case .toolCallStarted:
            state.isSearchingWeb = true
        case .toolCallCompleted:
            state.isSearchingWeb = false
        case .usage(var usage):
            if let start = streamStartTime {
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if seconds > 0 {
                    usage = TokenUsage(
                        promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens,
                        totalTokens: usage.totalTokens,
                        tokensPerSecond: Double(usage.completionTokens) / seconds
                    )
                }
            }
            if let index = state.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                state.messages[index].tokenUsage = usage
            }
        case .responseId(let rid):
            state.conversation?.lmStudioResponseId = rid
        }
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
        currentState.isSearchingWeb = false
        currentState.errorMessage = error.localizedDescription
        state = .loaded(currentState)
        scheduleErrorDismiss()
        persistConversation()
        streamingBackgroundUseCase.end()
        completeActiveStream(assistantMessageId)
    }
}

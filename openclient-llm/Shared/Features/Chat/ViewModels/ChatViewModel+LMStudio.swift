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
                guard !Task.isCancelled, isActiveStream(context.assistantId) else { return }
                applyLMStudioChunk(chunk, assistantMessageId: context.assistantId)
            }
            flushStreamingTextUpdates(for: context.assistantId)
            await finishStreaming(context.assistantId, model: context.modelId)
        } catch {
            flushStreamingTextUpdates(for: context.assistantId)
            handleLMStudioError(error, assistantMessageId: context.assistantId, model: context.modelId)
        }
    }
}

// MARK: - Private

private extension ChatViewModel {
    func applyLMStudioChunk(
        _ chunk: LMStudioStreamChunk,
        assistantMessageId: UUID
    ) {
        switch chunk {
        case .token(let text):
            enqueueStreamingTextUpdate(.token(text), assistantMessageId: assistantMessageId)
        case .reasoning(let text):
            enqueueStreamingTextUpdate(.reasoning(text), assistantMessageId: assistantMessageId)
        case .toolCallStarted:
            guard case .loaded(var currentState) = state else { return }
            currentState.isSearchingWeb = true
            state = .loaded(currentState)
        case .toolCallCompleted:
            guard case .loaded(var currentState) = state else { return }
            currentState.isSearchingWeb = false
            state = .loaded(currentState)
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
            flushStreamingTextUpdates(for: assistantMessageId)
            guard case .loaded(var currentState) = state else { return }
            if let index = currentState.messages.firstIndex(where: { $0.id == assistantMessageId }) {
                currentState.messages[index].tokenUsage = usage
            }
            state = .loaded(currentState)
        case .responseId(let rid):
            guard case .loaded(var currentState) = state else { return }
            currentState.conversation?.lmStudioResponseId = rid
            state = .loaded(currentState)
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

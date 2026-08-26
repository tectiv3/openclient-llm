//
//  MockChatRepository.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 30/03/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation
@testable import openclient_llm

// Safety: Only used within serialized @MainActor test methods.
final class MockChatRepository: ChatRepositoryProtocol, @unchecked Sendable {
    // MARK: - Properties

    var sendMessageResult: Result<(String, TokenUsage?), Error> = .success(("Mock response", nil))
    var streamChunks: [StreamChunk] = []
    var streamError: Error?
    var agentCompletionDelay: Duration?
    var agentCompletionCallCount = 0
    var lmStudioCompletionResult: Result<LMStudioChatResponse, Error> = .success(
        LMStudioChatResponse(output: [], stats: nil, responseId: nil)
    )
    var agentCompletionResult: Result<ChatCompletionResponse, Error> = .success(
        ChatCompletionResponse(
            id: "mock-id",
            choices: [ChatCompletionResponse.Choice(
                message: ChatCompletionResponse.Message(
                    role: "assistant",
                    content: "Mock answer",
                    reasoningContent: nil,
                    images: nil,
                    toolCalls: nil
                ),
                finishReason: "stop"
            )],
            usage: nil
        )
    )

    // MARK: - Public

    func sendMessage(
        messages: [ChatMessage],
        model: String,
        parameters: ModelParameters
    ) async throws -> (String, TokenUsage?) {
        try sendMessageResult.get()
    }

    func streamMessage(
        messages: [ChatMessage],
        model: String,
        parameters: ModelParameters,
        integrations: [MCPIntegration]?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let chunks = streamChunks
        let error = streamError
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    func agentCompletion(
        messages: [ChatMessage],
        model: String,
        parameters: ModelParameters,
        tools: [ToolDefinition]?,
        integrations: [MCPIntegration]?
    ) async throws -> ChatCompletionResponse {
        agentCompletionCallCount += 1
        if let agentCompletionDelay {
            try? await Task.sleep(for: agentCompletionDelay)
        }
        return try agentCompletionResult.get()
    }

    func lmStudioCompletion(
        input: String,
        model: String,
        systemPrompt: String,
        parameters: ModelParameters,
        contextWindowTokens: Int?,
        previousResponseId: String?,
        integrations: [MCPIntegration]
    ) async throws -> LMStudioChatResponse {
        try lmStudioCompletionResult.get()
    }

    var lmStudioStreamChunks: [LMStudioStreamChunk] = []
    var lmStudioStreamError: Error?

    func streamLMStudioChat(
        input: String,
        model: String,
        systemPrompt: String,
        parameters: ModelParameters,
        contextWindowTokens: Int?,
        previousResponseId: String?,
        integrations: [MCPIntegration]
    ) -> AsyncThrowingStream<LMStudioStreamChunk, Error> {
        let chunks = lmStudioStreamChunks
        let error = lmStudioStreamError
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    func buildNonStreamingRequestBody(
        messages: [ChatMessage],
        model: String,
        parameters: ModelParameters
    ) -> Data? { nil }
}

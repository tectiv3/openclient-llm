//
//  LMStudioChatUseCase.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 16/08/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

protocol LMStudioChatUseCaseProtocol: Sendable {
    func execute(
        input: String,
        model: String,
        systemPrompt: String,
        parameters: ModelParameters,
        contextWindowTokens: Int?,
        previousResponseId: String?,
        integrations: [MCPIntegration]
    ) async throws -> LMStudioChatResponse

    func stream(
        input: String,
        model: String,
        systemPrompt: String,
        parameters: ModelParameters,
        contextWindowTokens: Int?,
        previousResponseId: String?,
        integrations: [MCPIntegration]
    ) -> AsyncThrowingStream<LMStudioStreamChunk, Error>
}

struct LMStudioChatUseCase: LMStudioChatUseCaseProtocol {
    // MARK: - Properties

    private let repository: ChatRepositoryProtocol

    // MARK: - Init

    init(repository: ChatRepositoryProtocol = ChatRepository()) {
        self.repository = repository
    }

    // MARK: - Public

    func execute(
        input: String,
        model: String,
        systemPrompt: String,
        parameters: ModelParameters,
        contextWindowTokens: Int?,
        previousResponseId: String?,
        integrations: [MCPIntegration]
    ) async throws -> LMStudioChatResponse {
        try await repository.lmStudioCompletion(
            input: input,
            model: model,
            systemPrompt: systemPrompt,
            parameters: parameters,
            contextWindowTokens: contextWindowTokens,
            previousResponseId: previousResponseId,
            integrations: integrations
        )
    }

    func stream(
        input: String,
        model: String,
        systemPrompt: String,
        parameters: ModelParameters,
        contextWindowTokens: Int?,
        previousResponseId: String?,
        integrations: [MCPIntegration]
    ) -> AsyncThrowingStream<LMStudioStreamChunk, Error> {
        repository.streamLMStudioChat(
            input: input,
            model: model,
            systemPrompt: systemPrompt,
            parameters: parameters,
            contextWindowTokens: contextWindowTokens,
            previousResponseId: previousResponseId,
            integrations: integrations
        )
    }
}

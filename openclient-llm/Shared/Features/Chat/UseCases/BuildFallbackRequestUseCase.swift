//
//  BuildFallbackRequestUseCase.swift
//  openclient-llm
//

import Foundation

protocol BuildFallbackRequestUseCaseProtocol: Sendable {
    func execute(messages: [ChatMessage], model: String, parameters: ModelParameters) -> Data?
}

struct BuildFallbackRequestUseCase: BuildFallbackRequestUseCaseProtocol {
    private let repository: ChatRepositoryProtocol

    init(repository: ChatRepositoryProtocol = ChatRepository()) {
        self.repository = repository
    }

    func execute(messages: [ChatMessage], model: String, parameters: ModelParameters) -> Data? {
        repository.buildNonStreamingRequestBody(messages: messages, model: model, parameters: parameters)
    }
}

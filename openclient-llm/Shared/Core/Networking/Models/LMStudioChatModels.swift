//
//  LMStudioChatModels.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 16/08/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

// MARK: - LMStudioChatRequest

nonisolated struct LMStudioChatRequest: Encodable, Sendable {
    let model: String
    let input: String
    let systemPrompt: String?
    let integrations: [MCPIntegration]
    let temperature: Double?
    let maxOutputTokens: Int?
    let topP: Double?
    let reasoning: String?
    let contextLength: Int?
    let previousResponseId: String?
    let store: Bool
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case systemPrompt = "system_prompt"
        case integrations
        case temperature
        case maxOutputTokens = "max_output_tokens"
        case topP = "top_p"
        case reasoning
        case contextLength = "context_length"
        case previousResponseId = "previous_response_id"
        case store
        case stream
    }
}

// MARK: - LMStudioChatResponse

nonisolated struct LMStudioChatResponse: Decodable, Sendable {
    let output: [Output]
    let stats: Stats?
    let responseId: String?

    nonisolated struct Output: Decodable, Sendable {
        let type: String
        let content: String?
        let tool: String?
        let output: String?
        let reason: String?
    }

    nonisolated struct Stats: Decodable, Sendable {
        let inputTokens: Int?
        let totalOutputTokens: Int?
        let reasoningOutputTokens: Int?
        let tokensPerSecond: Double?
    }
}

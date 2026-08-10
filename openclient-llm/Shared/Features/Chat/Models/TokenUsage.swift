//
//  TokenUsage.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 31/03/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

struct TokenUsage: Equatable, Sendable, Codable {
    // MARK: - Properties

    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let tokensPerSecond: Double?

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case promptTokens
        case completionTokens
        case totalTokens
        case tokensPerSecond
    }

    // MARK: - Init

    init(
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int = 0,
        tokensPerSecond: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.tokensPerSecond = tokensPerSecond
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try container.decode(Int.self, forKey: .promptTokens)
        completionTokens = try container.decode(Int.self, forKey: .completionTokens)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        tokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .tokensPerSecond)
    }
}

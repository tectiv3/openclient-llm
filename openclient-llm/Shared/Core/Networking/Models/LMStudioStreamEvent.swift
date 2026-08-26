//
//  LMStudioStreamEvent.swift
//  openclient-llm
//
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

nonisolated struct LMStudioStreamEvent: Decodable, Sendable {
    let type: String
    let content: String?
    let toolName: String?
    let tool: String?
    let result: LMStudioChatResponse?

    enum CodingKeys: String, CodingKey {
        case type
        case content
        case toolName = "tool_name"
        case tool
        case result
    }
}

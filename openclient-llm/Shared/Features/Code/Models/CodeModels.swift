//
//  CodeModels.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

// MARK: - Session Info

struct CodeSessionInfo: Equatable, Sendable, Codable {
    let sessionId: String
    let cwd: String
    let sessionName: String?
    let model: CodeModelInfo
    let thinkingLevel: String?
    let isStreaming: Bool
    let contextUsage: CodeContextUsage?
}

struct CodeModelInfo: Equatable, Sendable, Codable {
    let provider: String
    let id: String

    var name: String { id }
}

struct CodeContextUsage: Equatable, Sendable, Codable {
    let tokens: Int
    let contextWindow: Int
    let percent: Double
}

// MARK: - History

struct CodeHistory: Equatable, Sendable, Codable {
    let sessionId: String
    let messages: [CodeHistoryMessage]
    let cursor: String?
}

// MARK: - Content Blocks

enum CodeContentBlock: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case toolUse(
        toolCallId: String,
        toolName: String,
        args: [String: AnyCodableValue],
        output: String?
    )
    case unknown
}

extension CodeContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, toolCallId, toolName, args, output
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "thinking":
            let text = try container.decode(String.self, forKey: .text)
            self = .thinking(text)
        case "toolUse":
            let toolCallId = try container.decode(String.self, forKey: .toolCallId)
            let toolName = try container.decode(String.self, forKey: .toolName)
            let args = try container.decodeIfPresent(
                [String: AnyCodableValue].self, forKey: .args
            ) ?? [:]
            let output = try container.decodeIfPresent(String.self, forKey: .output)
            self = .toolUse(
                toolCallId: toolCallId,
                toolName: toolName,
                args: args,
                output: output
            )
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let text):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let toolCallId, let toolName, let args, let output):
            try container.encode("toolUse", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(args, forKey: .args)
            try container.encodeIfPresent(output, forKey: .output)
        case .unknown:
            try container.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - History Messages

enum CodeHistoryMessage: Equatable, Sendable {
    case user(text: String)
    case assistant(content: [CodeContentBlock])
    case toolResult(
        toolName: String,
        toolCallId: String,
        output: String,
        isError: Bool
    )
    case compaction(summary: String)
    case unknown
}

extension CodeHistoryMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case role, text, content, toolName, toolCallId, output, isError, summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        switch role {
        case "user":
            let text = try container.decode(String.self, forKey: .text)
            self = .user(text: text)
        case "assistant":
            let content = try container.decode(
                [CodeContentBlock].self, forKey: .content
            )
            self = .assistant(content: content)
        case "toolResult":
            let toolName = try container.decode(String.self, forKey: .toolName)
            let toolCallId = try container.decode(
                String.self, forKey: .toolCallId
            )
            let output = try container.decode(String.self, forKey: .output)
            let isError = try container.decodeIfPresent(
                Bool.self, forKey: .isError
            ) ?? false
            self = .toolResult(
                toolName: toolName,
                toolCallId: toolCallId,
                output: output,
                isError: isError
            )
        case "compaction":
            let summary = try container.decode(String.self, forKey: .summary)
            self = .compaction(summary: summary)
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user(let text):
            try container.encode("user", forKey: .role)
            try container.encode(text, forKey: .text)
        case .assistant(let content):
            try container.encode("assistant", forKey: .role)
            try container.encode(content, forKey: .content)
        case .toolResult(let toolName, let toolCallId, let output, let isError):
            try container.encode("toolResult", forKey: .role)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(toolCallId, forKey: .toolCallId)
            try container.encode(output, forKey: .output)
            try container.encode(isError, forKey: .isError)
        case .compaction(let summary):
            try container.encode("compaction", forKey: .role)
            try container.encode(summary, forKey: .summary)
        case .unknown:
            try container.encode("unknown", forKey: .role)
        }
    }
}

// MARK: - Questions

struct CodeQuestion: Equatable, Sendable, Codable {
    let sessionId: String
    let id: String
    let kind: String
    let params: CodeQuestionParams
}

struct CodeQuestionParams: Equatable, Sendable, Codable {
    let question: String
    let description: String?
    let options: [CodeQuestionOption]
    let allowOther: Bool?

    init(
        question: String,
        description: String? = nil,
        options: [CodeQuestionOption],
        allowOther: Bool? = nil
    ) {
        self.question = question
        self.description = description
        self.options = options
        self.allowOther = allowOther
    }
}

struct CodeQuestionOption: Equatable, Sendable, Codable {
    let label: String
    let value: String
    let description: String?

    init(label: String, value: String? = nil, description: String? = nil) {
        self.label = label
        self.value = value ?? label
        self.description = description
    }
}

struct CodeQuestionnaire: Equatable, Sendable, Codable {
    let sessionId: String
    let id: String
    let kind: String
    let params: CodeQuestionnaireParams
}

struct CodeQuestionnaireParams: Equatable, Sendable, Codable {
    let questions: [CodeSubQuestion]
}

struct CodeSubQuestion: Equatable, Sendable, Codable, Identifiable {
    let id: String
    let label: String?
    let prompt: String
    let options: [CodeQuestionOption]
    let allowOther: Bool?
}

struct CodeQuestionResolved: Equatable, Sendable, Codable {
    let id: String
    let resolvedBy: String
    let value: String?

    enum CodingKeys: String, CodingKey {
        case id
        case resolvedBy = "by"
        case value
    }
}

// MARK: - Errors

struct CodeServerError: Equatable, Sendable, Codable {
    let code: String
    let message: String?
}

// MARK: - Stream Events

struct CodeStreamEvent: Equatable, Sendable, Codable {
    let sessionId: String
    let name: String
    let payload: [String: AnyCodableValue]

    private enum CodingKeys: String, CodingKey {
        case sessionId, name
    }

    init(sessionId: String, name: String, payload: [String: AnyCodableValue]) {
        self.sessionId = sessionId
        self.name = name
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try container.decode(String.self, forKey: .name)

        let allKeys = try decoder.container(
            keyedBy: DynamicCodingKey.self
        )
        var remaining: [String: AnyCodableValue] = [:]
        let reserved: Set<String> = ["type", "sessionId", "name"]
        for key in allKeys.allKeys where !reserved.contains(key.stringValue) {
            remaining[key.stringValue] = try allKeys.decode(
                AnyCodableValue.self, forKey: key
            )
        }
        payload = remaining
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(name, forKey: .name)
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in payload {
            try dynamic.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
}

// MARK: - Questionnaire Answer

struct CodeQuestionnaireAnswer: Sendable, Codable {
    let id: String
    let value: String
    let label: String
    let wasCustom: Bool
    let index: Int?
}

// MARK: - AnyCodableValue

enum AnyCodableValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
}

extension AnyCodableValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: AnyCodableValue].self
        ) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - DynamicCodingKey

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

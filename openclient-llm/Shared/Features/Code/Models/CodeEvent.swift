//
//  CodeEvent.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

// MARK: - CodeEvent

enum CodeEvent: Sendable {
    case helloOk(version: Int)
    case state(CodeSessionInfo)
    case history(CodeHistory)
    case event(CodeStreamEvent)
    case streamingBuffer(sessionId: String, content: [CodeContentBlock])
    case question(CodeQuestion)
    case questionnaire(CodeQuestionnaire)
    case questionResolved(CodeQuestionResolved)
    case pong
    case error(CodeServerError)
    case connectionFailed(String)
    case authFailed(CodeServerError)
    case disconnected
    case unknown
}

// MARK: - Decodable

extension CodeEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, version, sessionId, content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "hello_ok":
            let version = try container.decode(Int.self, forKey: .version)
            self = .helloOk(version: version)

        case "state":
            let info = try CodeSessionInfo(from: decoder)
            self = .state(info)

        case "history":
            let history = try CodeHistory(from: decoder)
            self = .history(history)

        case "event":
            let event = try CodeStreamEvent(from: decoder)
            self = .event(event)

        case "streaming_buffer":
            let sessionId = try container.decode(
                String.self, forKey: .sessionId
            )
            let content = try container.decode(
                [CodeContentBlock].self, forKey: .content
            )
            self = .streamingBuffer(sessionId: sessionId, content: content)

        case "question":
            let question = try CodeQuestion(from: decoder)
            self = .question(question)

        case "questionnaire":
            let questionnaire = try CodeQuestionnaire(from: decoder)
            self = .questionnaire(questionnaire)

        case "question_resolved":
            let resolved = try CodeQuestionResolved(from: decoder)
            self = .questionResolved(resolved)

        case "pong":
            self = .pong

        case "error":
            let serverError = try CodeServerError(from: decoder)
            self = .error(serverError)

        default:
            self = .unknown
        }
    }
}

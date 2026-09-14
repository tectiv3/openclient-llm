//
//  CodeEvent.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation

// MARK: - CodeEvent

enum CodeEvent: Sendable {
    /// `features` is the capability advertisement (M4 rollout gate): the
    /// VM only sends the Feature B requests when "subagents" is present;
    /// older servers omit the key entirely.
    case helloOk(version: Int, features: [String])
    case state(CodeSessionInfo)
    case history(CodeHistory)
    case event(CodeStreamEvent)
    case streamingBuffer(sessionId: String, content: [CodeContentBlock])
    case question(CodeQuestion)
    case questionResolved(CodeQuestionResolved)
    case sessions([SessionInfo])
    case sessionGone(id: String)
    case pong
    case error(CodeServerError)
    case connectionLost
    case connectionFailed(String)
    case authFailed(CodeServerError)
    case disconnected
    case subagents([CodeSubagentInfo])
    case subagentSnapshot(CodeSubagentSnapshot)
    case subagentEvent(
        subagentId: String,
        name: String,
        payload: [String: AnyCodableValue]
    )
    case subagentSettled(subagentId: String, status: String, stopReason: String?)
    case unknown
}

// MARK: - Decodable

extension CodeEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, version, sessionId, content, sessions, id
        case features, subagents, subagentId, name, status, stopReason
    }

    /// The `subagent_event` frame's payload: every key except the frame's
    /// own identity keys — same convention as the main `event` frame.
    private static func decodeSubagentEventPayload(
        from decoder: Decoder
    ) throws -> [String: AnyCodableValue] {
        let allKeys = try decoder.container(keyedBy: DynamicCodingKey.self)
        var payload: [String: AnyCodableValue] = [:]
        let reserved: Set = ["type", "subagentId", "name"]
        for key in allKeys.allKeys where !reserved.contains(key.stringValue) {
            payload[key.stringValue] = try allKeys.decode(
                AnyCodableValue.self, forKey: key
            )
        }
        return payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "hello_ok":
            let version = try container.decode(Int.self, forKey: .version)
            let features = try container.decodeIfPresent(
                [String].self, forKey: .features
            ) ?? []
            self = .helloOk(version: version, features: features)

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

        case "question_resolved":
            let resolved = try CodeQuestionResolved(from: decoder)
            self = .questionResolved(resolved)

        case "sessions":
            let list = try container.decode(
                [SessionInfo].self, forKey: .sessions
            )
            self = .sessions(list)

        case "session_gone":
            let id = try container.decode(String.self, forKey: .id)
            self = .sessionGone(id: id)

        case "pong":
            self = .pong

        case "subagents":
            let list = try container.decode(
                [CodeSubagentInfo].self, forKey: .subagents
            )
            self = .subagents(list)

        case "subagent_snapshot":
            let snapshot = try CodeSubagentSnapshot(from: decoder)
            self = .subagentSnapshot(snapshot)

        // Decoded like the main `event` frame's payload (m2).
        case "subagent_event":
            let subagentId = try container.decode(
                String.self, forKey: .subagentId
            )
            let name = try container.decode(String.self, forKey: .name)
            self = try .subagentEvent(
                subagentId: subagentId, name: name,
                payload: Self.decodeSubagentEventPayload(from: decoder)
            )

        case "subagent_settled":
            let subagentId = try container.decode(
                String.self, forKey: .subagentId
            )
            let status = try container.decode(String.self, forKey: .status)
            let stopReason = try container.decodeIfPresent(
                String.self, forKey: .stopReason
            )
            self = .subagentSettled(
                subagentId: subagentId, status: status, stopReason: stopReason
            )

        case "error":
            let serverError = try CodeServerError(from: decoder)
            self = .error(serverError)

        default:
            self = .unknown
        }
    }
}

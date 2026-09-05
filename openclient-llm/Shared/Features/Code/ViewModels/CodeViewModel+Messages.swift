//
//  CodeViewModel+Messages.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

// MARK: - CodeTranscriptItem

enum CodeTranscriptItem: Equatable, Identifiable {
    case user(id: UUID, text: String)
    case assistant(
        id: UUID,
        content: [CodeContentBlock],
        isStreaming: Bool
    )
    case toolStep(
        id: UUID,
        toolName: String,
        toolCallId: String,
        args: [String: AnyCodableValue],
        output: String?,
        isComplete: Bool
    )
    case resolvedQuestion(
        id: UUID,
        questionText: String,
        answerText: String,
        wasCustom: Bool
    )
    case compaction(id: UUID, summary: String)

    var id: UUID {
        switch self {
        case .user(let id, _),
             .assistant(let id, _, _),
             .toolStep(let id, _, _, _, _, _),
             .resolvedQuestion(let id, _, _, _),
             .compaction(let id, _):
            return id
        }
    }
}

// MARK: - History Mapping

extension CodeViewModel {
    func mapHistoryToItems(
        _ messages: [CodeHistoryMessage]
    ) -> [CodeTranscriptItem] {
        var items: [CodeTranscriptItem] = []

        for message in messages {
            switch message {
            case .user(let text):
                items.append(.user(id: UUID(), text: text))

            case .assistant(let content):
                mapAssistantContent(
                    content, into: &items, isStreaming: false
                )

            case .toolResult(let toolName, let toolCallId,
                             let output, _):
                updateToolStepCompletion(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    output: output,
                    in: &items
                )

            case .compaction(let summary):
                items.append(
                    .compaction(id: UUID(), summary: summary)
                )
            }
        }

        return items
    }

    func handleStreamEvent(_ event: CodeStreamEvent) {
        guard var session = currentSession else { return }
        guard event.sessionId == session.sessionId else { return }

        switch event.name {
        case "message_start":
            session.isStreaming = true
            session.items.append(.assistant(
                id: UUID(), content: [], isStreaming: true
            ))

        case "message_update":
            updateLastAssistantContent(event, in: &session)

        case "tool_execution_start":
            appendToolStep(event, in: &session)

        case "tool_execution_update":
            updateToolOutput(event, in: &session)

        case "turn_end":
            finalizeStreaming(in: &session)

        default:
            break
        }

        updateSession(session)
    }
}

// MARK: - Private

private extension CodeViewModel {
    func mapAssistantContent(
        _ content: [CodeContentBlock],
        into items: inout [CodeTranscriptItem],
        isStreaming: Bool
    ) {
        var textBlocks: [CodeContentBlock] = []

        for block in content {
            switch block {
            case .text, .thinking:
                textBlocks.append(block)

            case .toolUse(let toolCallId, let toolName,
                          let args, let output):
                if !textBlocks.isEmpty {
                    items.append(.assistant(
                        id: UUID(),
                        content: textBlocks,
                        isStreaming: isStreaming
                    ))
                    textBlocks = []
                }
                items.append(.toolStep(
                    id: UUID(),
                    toolName: toolName,
                    toolCallId: toolCallId,
                    args: args,
                    output: output,
                    isComplete: !isStreaming
                ))
            }
        }

        if !textBlocks.isEmpty {
            items.append(.assistant(
                id: UUID(),
                content: textBlocks,
                isStreaming: isStreaming
            ))
        }
    }

    func updateToolStepCompletion(
        toolCallId: String,
        toolName: String,
        output: String,
        in items: inout [CodeTranscriptItem]
    ) {
        guard let index = items.lastIndex(where: {
            if case .toolStep(_, _, let id, _, _, _) = $0 {
                return id == toolCallId
            }
            return false
        }) else {
            items.append(.toolStep(
                id: UUID(),
                toolName: toolName,
                toolCallId: toolCallId,
                args: [:],
                output: output,
                isComplete: true
            ))
            return
        }

        if case .toolStep(let id, let name, let tcId,
                          let args, _, _) = items[index] {
            items[index] = .toolStep(
                id: id,
                toolName: name,
                toolCallId: tcId,
                args: args,
                output: output,
                isComplete: true
            )
        }
    }

    func updateLastAssistantContent(
        _ event: CodeStreamEvent,
        in session: inout SessionState
    ) {
        guard let lastIndex = session.items.lastIndex(where: {
            if case .assistant = $0 { return true }
            return false
        }) else { return }

        if case .assistant(let id, var content, _)
            = session.items[lastIndex] {
            let text = event.payload["text"]
            let thinking = event.payload["thinking"]

            if case .string(let textValue) = text {
                appendOrUpdateTextBlock(
                    .text(textValue), in: &content
                )
            }
            if case .string(let thinkingValue) = thinking {
                appendOrUpdateTextBlock(
                    .thinking(thinkingValue), in: &content
                )
            }

            session.items[lastIndex] = .assistant(
                id: id, content: content, isStreaming: true
            )
        }
    }

    func appendOrUpdateTextBlock(
        _ block: CodeContentBlock,
        in content: inout [CodeContentBlock]
    ) {
        switch block {
        case .text(let newText):
            if case .text(let existing) = content.last {
                content[content.count - 1] = .text(
                    existing + newText
                )
            } else {
                content.append(block)
            }

        case .thinking(let newText):
            if let lastThinkingIndex = content.lastIndex(where: {
                if case .thinking = $0 { return true }
                return false
            }), case .thinking(let existing)
                = content[lastThinkingIndex] {
                content[lastThinkingIndex] = .thinking(
                    existing + newText
                )
            } else {
                content.append(block)
            }

        case .toolUse:
            content.append(block)
        }
    }

    func appendToolStep(
        _ event: CodeStreamEvent,
        in session: inout SessionState
    ) {
        let toolName: String
        if case .string(let name) = event.payload["toolName"] {
            toolName = name
        } else {
            toolName = "tool"
        }

        let toolCallId: String
        if case .string(let id) = event.payload["toolCallId"] {
            toolCallId = id
        } else {
            toolCallId = UUID().uuidString
        }

        var args: [String: AnyCodableValue] = [:]
        if case .object(let argsObj) = event.payload["args"] {
            args = argsObj
        }

        session.items.append(.toolStep(
            id: UUID(),
            toolName: toolName,
            toolCallId: toolCallId,
            args: args,
            output: nil,
            isComplete: false
        ))
    }

    func updateToolOutput(
        _ event: CodeStreamEvent,
        in session: inout SessionState
    ) {
        guard let lastIndex = session.items.lastIndex(where: {
            if case .toolStep = $0 { return true }
            return false
        }) else { return }

        if case .toolStep(let id, let name, let tcId,
                          let args, let existing, _)
            = session.items[lastIndex] {
            let newOutput: String
            if case .string(let text) = event.payload["output"] {
                newOutput = (existing ?? "") + text
            } else {
                newOutput = existing ?? ""
            }
            session.items[lastIndex] = .toolStep(
                id: id,
                toolName: name,
                toolCallId: tcId,
                args: args,
                output: newOutput,
                isComplete: false
            )
        }
    }

    func finalizeStreaming(in session: inout SessionState) {
        session.isStreaming = false

        for index in session.items.indices {
            if case .assistant(let id, let content, true)
                = session.items[index] {
                session.items[index] = .assistant(
                    id: id,
                    content: content,
                    isStreaming: false
                )
            }
        }
    }
}

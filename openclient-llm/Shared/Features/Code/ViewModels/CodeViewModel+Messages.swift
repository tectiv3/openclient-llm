//
//  CodeViewModel+Messages.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
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
        case let .user(id, _),
             let .assistant(id, _, _),
             let .toolStep(id, _, _, _, _, _),
             let .resolvedQuestion(id, _, _, _),
             let .compaction(id, _):
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
            case let .user(text):
                items.append(.user(id: UUID(), text: text))

            case let .assistant(content):
                mapAssistantContent(
                    content, into: &items, isStreaming: false
                )

            case let .toolResult(toolName, toolCallId,
                                 output, _):
                updateToolStepCompletion(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    output: output,
                    in: &items
                )

            case let .compaction(summary):
                items.append(
                    .compaction(id: UUID(), summary: summary)
                )

            case .unknown:
                break
            }
        }

        return items
    }

    func handleStreamEvent(_ event: CodeStreamEvent) {
        guard var session = currentSession else { return }
        guard event.sessionId == session.sessionId else { return }

        switch event.name {
        case "agent_start":
            // Only agent-scoped events drive the session-level flag;
            // message_start/turn_end fire per LLM turn and would flicker
            // during multi-turn tool runs.
            session.isStreaming = true

        case "agent_settled":
            session.isStreaming = false
            finalizeStreamingBubbles(in: &session)

        case "message_start":
            // Transcript content only — does not touch session.isStreaming.
            session.items.append(.assistant(
                id: UUID(), content: [], isStreaming: true
            ))

        case "message_update":
            updateLastAssistantContent(event, in: &session)

        case "tool_execution_start":
            appendToolStep(event, in: &session)

        case "tool_execution_update":
            updateToolOutput(event, in: &session)

        case "tool_execution_end":
            markToolStepComplete(event, in: &session)

        case "turn_end":
            // Ends the current LLM turn's bubble, not the whole agent run.
            finalizeStreamingBubbles(in: &session)

        default:
            break
        }

        updateSession(session)

        // The server only sends `state` on connect / session_start /
        // get_state, so refresh after the agent settles to keep the context
        // estimate current.
        if event.name == "agent_settled" {
            send(.refreshState)
        }
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

            case let .toolUse(toolCallId, toolName,
                              args, output):
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

            case .unknown:
                break
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
            if case let .toolStep(_, _, id, _, _, _) = $0 {
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

        if case let .toolStep(id, name, tcId,
                              args, _, _) = items[index]
        {
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
            if case .assistant = $0 {
                return true
            }
            return false
        }) else { return }

        // The server forwards the raw pi `message_update` frame; its
        // `message.content` is a full snapshot of the partial message, so
        // replace (not diff) the streaming bubble's content on every frame.
        // Guard against an empty parse (toolCall-only frames) so we don't
        // wipe content an earlier frame already populated on this bubble.
        guard let content = messageContentBlocks(event.payload["message"]),
              !content.isEmpty else { return }

        if case let .assistant(id, _, _) = session.items[lastIndex] {
            session.items[lastIndex] = .assistant(
                id: id, content: content, isStreaming: true
            )
        }
    }

    /// Parses the raw pi assistant `message.content` array carried by a
    /// `message_update` frame. The wire shape differs from the normalized
    /// history shape (thinking blocks use a `thinking` key, tool calls are
    /// `{type: "toolCall", ...}`), so the strict `CodeContentBlock` decoder
    /// cannot consume it directly. Only text and thinking blocks are
    /// transcript-relevant here; tool steps are driven by
    /// `tool_execution_*` events.
    func messageContentBlocks(
        _ message: AnyCodableValue?
    ) -> [CodeContentBlock]? {
        guard case let .object(message)? = message,
              case let .array(content)? = message["content"]
        else {
            return nil
        }

        var blocks: [CodeContentBlock] = []
        for part in content {
            guard case let .object(part) = part,
                  case let .string(type)? = part["type"]
            else {
                continue
            }
            switch type {
            case "text":
                if case let .string(text)? = part["text"] {
                    blocks.append(.text(text))
                }
            case "thinking":
                if case let .string(thinking)? = part["thinking"] {
                    blocks.append(.thinking(thinking))
                }
            default:
                break
            }
        }
        return blocks
    }

    func appendToolStep(
        _ event: CodeStreamEvent,
        in session: inout SessionState
    ) {
        let toolName: String
        if case let .string(name) = event.payload["toolName"] {
            toolName = name
        } else {
            toolName = "tool"
        }

        let toolCallId: String
        if case let .string(id) = event.payload["toolCallId"] {
            toolCallId = id
        } else {
            toolCallId = UUID().uuidString
        }

        var args: [String: AnyCodableValue] = [:]
        if case let .object(argsObj) = event.payload["args"] {
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
        let toolCallId: String?
        if case let .string(id)? = event.payload["toolCallId"] {
            toolCallId = id
        } else {
            toolCallId = nil
        }

        // Match by toolCallId (when present) rather than the last tool step,
        // so concurrent tool steps don't clobber each other's output.
        guard let index = session.items.lastIndex(where: {
            if case let .toolStep(_, _, id, _, _, _) = $0 {
                return toolCallId.map { id == $0 } ?? true
            }
            return false
        }) else { return }

        if case let .toolStep(id, name, tcId,
                              args, existing, _)
            = session.items[index]
        {
            // pi sends `partialResult` as a cumulative snapshot (never
            // `output`), so replace (not append) the step's output.
            let newOutput: String?
            if case let .string(text) = event.payload["partialResult"] {
                newOutput = text
            } else {
                newOutput = existing
            }
            session.items[index] = .toolStep(
                id: id,
                toolName: name,
                toolCallId: tcId,
                args: args,
                output: newOutput,
                isComplete: false
            )
        }
    }

    func markToolStepComplete(
        _ event: CodeStreamEvent,
        in session: inout SessionState
    ) {
        guard case let .string(toolCallId)? = event.payload["toolCallId"],
              let index = session.items.lastIndex(where: {
                  if case let .toolStep(_, _, id, _, _, _) = $0 {
                      return id == toolCallId
                  }
                  return false
              }) else { return }

        if case let .toolStep(id, name, tcId,
                              args, output, _)
            = session.items[index]
        {
            session.items[index] = .toolStep(
                id: id,
                toolName: name,
                toolCallId: tcId,
                args: args,
                output: output,
                isComplete: true
            )
        }
    }
}

// MARK: - Session Finalization

extension CodeViewModel {
    /// Marks streaming assistant bubbles complete and drops empty ones,
    /// without touching the session-level `isStreaming` flag (driven by
    /// agent events). pi emits one assistant message per tool call in a
    /// turn; toolCall-only messages parse to empty content, so those stray
    /// bubbles are removed here as the single cleanup point.
    func finalizeStreamingBubbles(in session: inout SessionState) {
        for index in session.items.indices.reversed() {
            if case let .assistant(id, content, isStreaming)
                = session.items[index]
            {
                if content.isEmpty {
                    session.items.remove(at: index)
                } else if isStreaming {
                    session.items[index] = .assistant(
                        id: id,
                        content: content,
                        isStreaming: false
                    )
                }
            }
        }
    }
}

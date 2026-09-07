//
//  CodeViewModel+Messages.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation

// MARK: - CodeTranscriptItem

enum CodeTranscriptItem: Equatable, Identifiable {
    case user(id: UUID, text: String, failed: Bool)
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
        case let .user(id, _, _),
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
                items.append(.user(
                    id: UUID(), text: text, failed: false
                ))

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
            // The run is underway, so every earlier prompt send was either
            // accepted (this run) or already rejected (not_idle consumed
            // its entry); nothing may stay pending.
            pendingPromptEchoes.removeAll()

        case "agent_settled":
            session.isStreaming = false
            finalizeStreamingBubbles(in: &session)

        case "message_start":
            // Transcript content only — does not touch session.isStreaming.
            // pi emits message_start for every role: assistant opens a
            // bubble; user renders a transcript item — the only record of a
            // TUI-typed prompt (no local echo exists), and the server twin
            // of this device's own echo otherwise (shared append dedupes).
            // toolResult is covered by tool_execution_* events.
            if case let .object(message)? = event.payload["message"],
               case let .string(role)? = message["role"]
            {
                switch role {
                case "assistant":
                    session.items.append(.assistant(
                        id: UUID(), content: [], isStreaming: true
                    ))
                case "user":
                    if let text = userText(fromMessage: message) {
                        appendUserItem(text, to: &session)
                    }
                default:
                    break
                }
            }

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

// MARK: - Prompt Handling

extension CodeViewModel {
    func handleSendPrompt(_ text: String) {
        guard case var .connected(session) = state,
              !session.isStreaming else { return }
        let echo = appendLocalEcho(text, to: &session)
        updateSession(session)
        sendPromptText(text, echo: echo)
    }

    /// Re-sends a failed prompt by reusing its existing echo item, so the
    /// dedup guard cannot append a duplicate. Deliberately skips the
    /// `isStreaming` guard in `handleSendPrompt`: a tap is an explicit user
    /// intent and the server is the authority — a prompt rejected while
    /// streaming answers `not_idle`, which re-marks the same bubble failed.
    func handleRetryPrompt(id: UUID) {
        guard case var .connected(session) = state,
              let index = session.items.firstIndex(where: {
                  if case let .user(itemId, _, _) = $0 {
                      return itemId == id
                  }
                  return false
              }),
              case let .user(_, text, failed) = session.items[index],
              failed
        else { return }

        let echo = CodeTranscriptItem.user(
            id: id, text: text, failed: false
        )
        session.items[index] = echo
        updateSession(session)
        sendPromptText(text, echo: echo)
    }

    func handleSendSteer(_ text: String) {
        guard case var .connected(session) = state,
              session.isStreaming else { return }
        let echo = appendLocalEcho(text, to: &session)
        updateSession(session)
        Task {
            let sent = await client.send(.steer(text: text))
            if !sent {
                markLocalEchoFailed(echo.id)
            }
        }
    }
}

// MARK: - Private (Prompt Echoes)

private extension CodeViewModel {
    /// Shares the prompt-send tail between `handleSendPrompt` and
    /// `handleRetryPrompt` so a failed transport marks the echoed item
    /// failed in both paths.
    func sendPromptText(_ text: String, echo: CodeTranscriptItem) {
        pendingPromptEchoes.append(echo.id)
        let id = echo.id
        Task {
            let sent = await client.send(.prompt(text: text))
            if !sent {
                markLocalEchoFailed(id)
            }
        }
    }

    func markLocalEchoFailed(_ id: UUID) {
        guard var session = currentSession,
              let index = session.items.firstIndex(where: {
                  if case let .user(itemId, _, _) = $0 {
                      return itemId == id
                  }
                  return false
              })
        else { return }

        if case let .user(itemId, text, _) = session.items[index] {
            session.items[index] = .user(
                id: itemId, text: text, failed: true
            )
            updateSession(session)
        }
    }

    /// Local echo so the prompt renders immediately instead of waiting for
    /// the next server history sync. Deduped against a trailing identical
    /// user item, which can only exist if the same text was already synced
    /// from the server history. Returns the trailing user item (existing or
    /// new) so the caller can correlate later send failures with it.
    func appendLocalEcho(
        _ text: String,
        to session: inout SessionState
    ) -> CodeTranscriptItem {
        appendUserItem(text, to: &session)
    }

    /// Shared user-item append, deduped against a trailing identical user
    /// item: a forwarded user frame and its local echo collapse into one
    /// entry regardless of arrival order.
    func appendUserItem(
        _ text: String,
        to session: inout SessionState
    ) -> CodeTranscriptItem {
        if case let .user(id, lastText, _)? = session.items.last,
           lastText == text
        {
            // Reusing the existing item also resets its failed flag, so a
            // re-send of the same text (type-again or retry) starts clean.
            let item = CodeTranscriptItem.user(
                id: id, text: lastText, failed: false
            )
            session.items[session.items.count - 1] = item
            return item
        }
        let item = CodeTranscriptItem.user(
            id: UUID(), text: text, failed: false
        )
        session.items.append(item)
        return item
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

    /// Mirrors the server's textFromMessage for user-role frames (string
    /// shortcuts first, text parts joined with no separator) so the result
    /// equals what a later history sync would hold for the same message —
    /// keeps frame/history dedup stable.
    func userText(
        fromMessage message: [String: AnyCodableValue]
    ) -> String? {
        if case let .string(text)? = message["text"] {
            return text
        }
        if case let .string(text)? = message["content"] {
            return text
        }
        guard case let .array(content)? = message["content"] else {
            return nil
        }

        var result = ""
        for part in content {
            switch part {
            case let .string(text):
                result += text
            case let .object(part):
                if case let .string(text)? = part["text"] {
                    result += text
                } else if case let .string(text)? = part["content"] {
                    result += text
                }
            default:
                break
            }
        }
        return result.isEmpty ? nil : result
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

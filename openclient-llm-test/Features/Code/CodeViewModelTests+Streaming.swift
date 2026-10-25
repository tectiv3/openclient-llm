//
//  CodeViewModelTests+Streaming.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

// The suite predates the split-by-feature extension files; the streaming
// tests stay beside their subject instead of fragmenting again.
// swiftlint:disable file_length

// MARK: - CodeViewModelTests — Local echo / streaming / state refresh

extension CodeViewModelTests {
    func test_sendPrompt_connectedIdle_appendsLocalUserEcho() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .user(_, text, failed, pending)? = items.last else {
            return XCTFail("Expected user echo, got \(items.last)")
        }
        XCTAssertEqual(text, "hi")
        XCTAssertFalse(failed)
        XCTAssertFalse(pending)
    }

    func test_sendPrompt_sameTextAlreadyInHistory_doesNotDuplicate() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil,
            pending: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then — echo deduped to the existing history item
        XCTAssertEqual(currentSession()?.items.count, 1)
        XCTAssertFalse(lastUserItem()?.failed ?? true)

        // The prompt is still sent exactly once (dedup skips the echo,
        // not the send).
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }
    }

    func test_sendSteer_connectedStreaming_sendsSteerMessage() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)

        // When / Then — waits until exactly one steer with the text is sent
        sut.send(.sendSteer(text: "be brief"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .steer(text) = $0 {
                    return text == "be brief"
                }
                return false
            }) == 1
        }

        // Then — steer also gets a local echo, marked queued in pi
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .user(_, text, failed, pending)? = items.last else {
            return XCTFail("Expected user echo, got \(items.last)")
        }
        XCTAssertEqual(text, "be brief")
        XCTAssertFalse(failed)
        XCTAssertTrue(pending)
    }

    func test_messageUpdate_assemblesAssistantContentFromDeltas() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When — first frames: thinking and text deltas, no snapshot
        emit([
            messageUpdateEvent(type: "thinking_start", contentIndex: 0),
            messageUpdateEvent(
                type: "thinking_delta", contentIndex: 0,
                delta: "let's think"
            ),
            messageUpdateEvent(type: "text_start", contentIndex: 1),
            messageUpdateEvent(
                type: "text_delta", contentIndex: 1, delta: "hello "
            ),
        ])
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content == [
                .thinking("let's think"), .text("hello "),
            ]
        }

        // When — a later frame continues the same block
        emit([
            messageUpdateEvent(
                type: "text_delta", contentIndex: 1, delta: "world"
            ),
            messageUpdateEvent(
                type: "text_end", contentIndex: 1, content: "hello world"
            ),
        ])
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content == [
                .thinking("let's think"), .text("hello world"),
            ]
        }

        // Then — deltas assembled the bubble content, in order
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .assistant(_, content, _)? = items.last else {
            return XCTFail("Expected assistant item, got \(items.last)")
        }
        XCTAssertEqual(content, [.thinking("let's think"), .text("hello world")])
    }

    func test_messageUpdate_ignoresToolCallDeltas() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When — text delta followed by the tool-call delta run
        emit([
            messageUpdateEvent(type: "text_start", contentIndex: 0),
            messageUpdateEvent(
                type: "text_delta", contentIndex: 0, delta: "checking"
            ),
            messageUpdateEvent(type: "toolcall_start", contentIndex: 1),
            messageUpdateEvent(
                type: "toolcall_delta", contentIndex: 1,
                delta: #"{"command"#
            ),
            messageUpdateEvent(type: "toolcall_end", contentIndex: 1),
        ])

        // Then — text kept, no tool block appended to the bubble
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content == [.text("checking")]
        }
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 1, "tool-call deltas must not add items")
        guard case let .assistant(_, content, _)? = items.last else {
            return XCTFail("Expected assistant item, got \(items.last)")
        }
        XCTAssertEqual(content, [.text("checking")])
    }

    func test_messageUpdate_malformedFrame_doesNotCrash() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When — malformed frame: assistantMessageEvent is not an object
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1",
            name: "message_update",
            payload: [
                "assistantMessageEvent": .string("not-an-object"),
            ]
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then — no crash, existing bubble content unchanged
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .assistant(_, content, _)? = items.last else {
            return XCTFail("Expected assistant item, got \(items.last)")
        }
        XCTAssertEqual(content, [])
    }

    // MARK: - Tests — Delta assembly edge cases

    func test_messageUpdate_textSplitMidWord_reassemblesExactText() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When — one word spread across three frames
        mockClient.emit(.event(messageUpdateEvent(
            type: "text_start", contentIndex: 0
        )))
        for delta in ["Hel", "lo, wo", "rld"] {
            mockClient.emit(.event(messageUpdateEvent(
                type: "text_delta", contentIndex: 0, delta: delta
            )))
        }
        mockClient.emit(.event(messageUpdateEvent(
            type: "text_end", contentIndex: 0, content: "Hello, world"
        )))

        // Then
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content == [.text("Hello, world")]
        }
        guard let items = currentSession()?.items,
              case let .assistant(_, content, _)? = items.last
        else {
            return XCTFail("Expected assistant item, got \(String(describing: currentSession()?.items.last))")
        }
        XCTAssertEqual(content, [.text("Hello, world")])
    }

    func test_messageUpdate_outOfRangeIndex_padsWithUnknownWithoutShifting()
        async throws
    {
        // Given — thinking at 0 and text at 1, the contiguous prefix pi
        // produces (a tool call would occupy 2)
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }
        emit([
            messageUpdateEvent(type: "thinking_start", contentIndex: 0),
            messageUpdateEvent(
                type: "thinking_delta", contentIndex: 0, delta: "plan"
            ),
            messageUpdateEvent(type: "text_start", contentIndex: 1),
            messageUpdateEvent(
                type: "text_delta", contentIndex: 1, delta: "body"
            ),
        ])
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content == [.thinking("plan"), .text("body")]
        }

        // When — a delta one index past the end
        mockClient.emit(.event(messageUpdateEvent(
            type: "text_delta", contentIndex: 3, delta: "tail"
        )))

        // Then — exactly one gap filler at index 2, content still in order
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content == [
                .thinking("plan"), .text("body"), .unknown, .text("tail"),
            ]
        }
        guard let items = currentSession()?.items,
              case let .assistant(_, content, _)? = items.last
        else {
            return XCTFail("Expected assistant item")
        }
        XCTAssertEqual(content[2], .unknown)
        XCTAssertEqual(content.dropFirst(3), [.text("tail")])
    }

    func test_turnEnd_authoritativeContent_overwritesDriftedDeltas()
        async throws
    {
        // Given — a bubble whose delta assembly drifted (a dropped frame)
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }
        let bubbleId = try XCTUnwrap(currentSession()?.items.last?.id)
        mockClient.emit(.event(messageUpdateEvent(
            type: "text_delta", contentIndex: 0, delta: "drifted "
        )))
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content == [.text("drifted ")]
        }

        // When — turn_end carries the authoritative final content
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1",
            name: "turn_end",
            payload: [
                "turnIndex": .int(3),
                "message": .object([
                    "role": .string("assistant"),
                    "stopReason": .string("stop"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("authoritative"),
                        ]),
                        .object([
                            "type": .string("thinking"),
                            "text": .string("reasoning"),
                        ]),
                    ]),
                ]),
            ]
        )))

        // Then — content repaired, identity preserved, bubble closed
        try await waitUntil {
            guard case let .assistant(_, _, isStreaming)?
                = self.currentSession()?.items.last else { return false }
            return !isStreaming
        }
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .assistant(id, content, isStreaming) = items.last else {
            return XCTFail("Expected assistant item, got \(items.last)")
        }
        XCTAssertEqual(id, bubbleId)
        XCTAssertEqual(content, [.text("authoritative"), .thinking("reasoning")])
        XCTAssertFalse(isStreaming)
    }

    func test_toolExecutionUpdate_stringPartialResult_replacesOutput()
        async throws
    {
        // Given — a live tool step
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(toolExecutionEvent(
            name: "tool_execution_start", toolCallId: "tc1", toolName: "bash"
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When — the wire now carries a plain, capped string preview
        mockClient.emit(.event(toolExecutionEvent(
            name: "tool_execution_update", toolCallId: "tc1",
            toolName: "bash", partialResult: "line 1"
        )))
        try await waitUntil {
            guard case let .toolStep(_, _, _, _, output, _)?
                = self.currentSession()?.items.last else { return false }
            return output == "line 1"
        }
        mockClient.emit(.event(toolExecutionEvent(
            name: "tool_execution_update", toolCallId: "tc1",
            toolName: "bash", partialResult: "line 1\nline 2"
        )))

        // Then — the cumulative preview replaces, never appends
        try await waitUntil {
            guard case let .toolStep(_, _, _, _, output, _)?
                = self.currentSession()?.items.last else { return false }
            return output == "line 1\nline 2"
        }
        guard case let .toolStep(_, _, toolCallId, _, output, isComplete)?
            = currentSession()?.items.last
        else {
            return XCTFail("Expected tool step")
        }
        XCTAssertEqual(toolCallId, "tc1")
        XCTAssertEqual(output, "line 1\nline 2")
        XCTAssertFalse(isComplete)
    }

    func test_agentSettled_triggersStateRefresh() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1",
            name: "agent_settled",
            payload: [:]
        )))

        // Then
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .getState = $0 {
                    return true
                }
                return false
            }) == 1
        }
    }

    func test_toolExecutionEnd_marksMatchingToolStepComplete() async throws {
        // Given — two in-flight tool steps, matched by toolCallId
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(toolExecutionEvent(
            name: "tool_execution_start", toolCallId: "tc1", toolName: "read"
        )))
        mockClient.emit(.event(toolExecutionEvent(
            name: "tool_execution_start", toolCallId: "tc2", toolName: "write"
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 2
        }

        // When — complete only tc1
        mockClient.emit(.event(toolExecutionEvent(
            name: "tool_execution_end", toolCallId: "tc1", toolName: "read"
        )))
        try await waitUntil {
            guard case let .toolStep(_, _, _, _, _, done)?
                = self.currentSession()?.items[0] else { return false }
            return done
        }

        // Then — tc1 complete, tc2 untouched
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .toolStep(_, _, id1, _, _, done1) = items[0] else {
            return XCTFail("Expected toolStep, got \(items[0])")
        }
        XCTAssertEqual(id1, "tc1")
        XCTAssertTrue(done1)
        guard case let .toolStep(_, _, id2, _, _, done2) = items[1] else {
            return XCTFail("Expected toolStep, got \(items[1])")
        }
        XCTAssertEqual(id2, "tc2")
        XCTAssertFalse(done2)
    }

    func test_turnEnd_removesEmptyAssistantBubbles() async throws {
        // Given — message_start appends an empty streaming bubble that
        // never receives content (toolCall-only message)
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "turn_end", payload: [:]
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 0
        }

        // Then — the empty bubble was dropped
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    func test_turnEnd_keepsNonEmptyAssistantBubbleMarkedComplete() async throws {
        // Given — bubble with real content
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        emit(messageDeltas(thinking: "", text: "done"))
        try await waitUntil {
            guard let items = self.currentSession()?.items,
                  case let .assistant(_, content, _)? = items.last
            else {
                return false
            }
            return content.contains(.text("done"))
        }

        // When
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "turn_end", payload: [:]
        )))
        try await waitUntil {
            guard case let .assistant(_, _, isStreaming)?
                = self.currentSession()?.items.last else { return false }
            return !isStreaming
        }

        // Then — preserved, not removed, and no longer streaming
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .assistant(_, content, isStreaming) = items.last
        else { return XCTFail("Expected assistant, got \(items.last)") }
        XCTAssertFalse(content.isEmpty)
        XCTAssertFalse(isStreaming)
    }

    // MARK: - Tests — message_start role handling

    func test_messageStart_userRoleFrame_withText_appendsUserItem() async throws {
        // Given — TUI-typed prompt arrives as a forwarded user frame;
        // no local echo exists for it
        try await connectAndEstablish()

        // When
        mockClient.emit(.event(messageStartEvent(
            role: "user",
            content: .array([.object([
                "type": .string("text"),
                "text": .string("typed in the tui"),
            ])])
        )))

        // Then
        try await waitUntil {
            self.currentSession()?.items.count == 1
        }
        let last = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(last.text, "typed in the tui")
        XCTAssertFalse(last.failed)
    }

    func test_messageStart_userRoleMatchesPendingSteer_flipsToDelivered()
        async throws
    {
        // Given — a steer echo queued in pi
        try await connectAndEstablish(isStreaming: true)
        sut.send(.sendSteer(text: "be brief"))
        try await waitUntil { self.lastUserItem() != nil }

        // When — pi delivers the steer at the turn boundary
        mockClient.emit(.event(messageStartEvent(
            role: "user",
            content: .array([.object([
                "type": .string("text"),
                "text": .string("be brief"),
            ])])
        )))
        try await waitUntil { self.lastUserItem()?.pending == false }

        // Then — the queued item flipped to delivered, no duplicate
        XCTAssertEqual(currentSession()?.items.count, 1)
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "be brief")
        XCTAssertFalse(item.failed)
        XCTAssertFalse(item.pending)
    }

    func test_messageStart_userRoleNoPendingMatch_appendsDeliveredItem()
        async throws
    {
        // Given — no queued steer in the transcript
        try await connectAndEstablish()

        // When — a TUI-typed prompt arrives as a forwarded user frame
        mockClient.emit(.event(messageStartEvent(
            role: "user",
            content: .array([.object([
                "type": .string("text"),
                "text": .string("typed in the tui"),
            ])])
        )))

        // Then — a plain delivered item is appended
        try await waitUntil { self.currentSession()?.items.count == 1 }
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "typed in the tui")
        XCTAssertFalse(item.failed)
        XCTAssertFalse(item.pending)
    }

    func test_messageStart_userRoleFrame_afterLocalEcho_dedupesToOneItem() async throws {
        // Given — phone-originated prompt already rendered its echo
        try await connectAndEstablish()
        sut.send(.sendPrompt(text: "hi"))
        let echoId = lastUserItem()?.id

        // When — the forwarded twin of that echo arrives
        mockClient.emit(.event(messageStartEvent(
            role: "user",
            content: .array([.object([
                "type": .string("text"),
                "text": .string("hi"),
            ])])
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then — collapsed into the existing echo, identity preserved
        XCTAssertEqual(currentSession()?.items.count, 1)
        XCTAssertEqual(lastUserItem()?.id, echoId)
    }

    func test_messageStart_userRoleFrame_stringContent_usesContentText() async throws {
        // Given — server textFromMessage fallback shape: content as string
        try await connectAndEstablish()

        // When
        mockClient.emit(.event(messageStartEvent(
            role: "user", content: .string("plain string content")
        )))

        // Then
        try await waitUntil { self.lastUserItem()?.text == "plain string content" }
    }

    func test_messageStart_userRoleFrame_withoutText_doesNotAppendItem() async throws {
        // Given — degenerate frame: role but no text payload
        try await connectAndEstablish(isStreaming: true)

        // When
        mockClient.emit(.event(messageStartEvent(role: "user")))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    func test_messageStart_toolResultRoleFrame_doesNotAppendItem() async throws {
        // Given — toolResult frames are transcript noise here; tool steps
        // are driven by tool_execution_* events
        try await connectAndEstablish(isStreaming: true)

        // When
        mockClient.emit(.event(messageStartEvent(role: "toolResult")))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    func test_messageStart_assistantRoleFrame_appendsStreamingBubble() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)

        // When
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // Then
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .assistant(_, content, isStreaming) = items[0] else {
            return XCTFail("Expected assistant item, got \(items[0])")
        }
        XCTAssertTrue(isStreaming)
        XCTAssertTrue(content.isEmpty)
    }

    func test_messageStart_missingRole_doesNotAppendItem() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)

        // When
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "message_start", payload: [:]
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    // MARK: - Helpers

    /// Builds a raw pi `message_start` frame. The role drives handling:
    /// assistant frames open a bubble, user frames render a transcript
    /// item (TUI-typed prompts have no local echo), other roles are noise.
    func messageStartEvent(
        role: String,
        content: AnyCodableValue? = nil
    ) -> CodeStreamEvent {
        var message: [String: AnyCodableValue] = [
            "role": .string(role),
        ]
        if let content {
            message["content"] = content
        }
        return CodeStreamEvent(
            sessionId: "s1",
            name: "message_start",
            payload: [
                "message": .object(message),
            ]
        )
    }

    func toolExecutionEvent(
        name: String,
        toolCallId: String,
        toolName: String,
        partialResult: String? = nil
    ) -> CodeStreamEvent {
        var payload: [String: AnyCodableValue] = [
            "toolCallId": .string(toolCallId),
            "toolName": .string(toolName),
        ]
        switch name {
        case "tool_execution_start":
            payload["args"] = .object([:])
        case "tool_execution_end":
            payload["isError"] = .bool(false)
        default:
            if let partialResult {
                payload["partialResult"] = .string(partialResult)
            }
        }
        return CodeStreamEvent(
            sessionId: "s1",
            name: name,
            payload: payload
        )
    }

    /// Builds a trimmed `message_update` frame: only the
    /// `assistantMessageEvent` (the wire carries neither the cumulative
    /// `message` nor `partial`).
    func messageUpdateEvent(
        type: String,
        contentIndex: Int,
        delta: String? = nil,
        content: String? = nil
    ) -> CodeStreamEvent {
        var event: [String: AnyCodableValue] = [
            "type": .string(type),
            "contentIndex": .int(contentIndex),
        ]
        if let delta {
            event["delta"] = .string(delta)
        }
        if let content {
            event["content"] = .string(content)
        }
        return CodeStreamEvent(
            sessionId: "s1",
            name: "message_update",
            payload: ["assistantMessageEvent": .object(event)]
        )
    }

    /// One assistant message as pi sends it after the wire trim: thinking
    /// at index 0 and text at index 1, each closed by its authoritative
    /// `*_end` block. An empty string still opens its block, so callers
    /// keep seeing `[.thinking(""), .text(...)]`.
    func messageDeltas(
        thinking: String,
        text: String
    ) -> [CodeStreamEvent] {
        [
            messageUpdateEvent(type: "thinking_start", contentIndex: 0),
            messageUpdateEvent(
                type: "thinking_delta", contentIndex: 0, delta: thinking
            ),
            messageUpdateEvent(
                type: "thinking_end", contentIndex: 0, content: thinking
            ),
            messageUpdateEvent(type: "text_start", contentIndex: 1),
            messageUpdateEvent(
                type: "text_delta", contentIndex: 1, delta: text
            ),
            messageUpdateEvent(
                type: "text_end", contentIndex: 1, content: text
            ),
        ]
    }

    /// Drains delta frames into the mock server stream in order.
    func emit(_ events: [CodeStreamEvent]) {
        for event in events {
            mockClient.emit(.event(event))
        }
    }
}

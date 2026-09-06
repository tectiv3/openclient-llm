//
//  CodeViewModelTests+Streaming.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Local echo / streaming / state refresh

extension CodeViewModelTests {
    func test_sendPrompt_connectedIdle_appendsLocalUserEcho() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .user(_, text)? = items.last else {
            return XCTFail("Expected user echo, got \(items.last)")
        }
        XCTAssertEqual(text, "hi")
    }

    func test_sendPrompt_sameTextAlreadyInHistory_doesNotDuplicate() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then
        XCTAssertEqual(currentSession()?.items.count, 1)
    }

    func test_sendSteer_connectedStreaming_sendsSteerMessage() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)

        // When / Then — waits until exactly one steer with the text is sent
        sut.send(.sendSteer(text: "be brief"))
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case let .steer(text) = $0 {
                    return text == "be brief"
                }
                return false
            }) == 1
        }

        // Then — steer also gets a local echo
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .user(_, text)? = items.last else {
            return XCTFail("Expected user echo, got \(items.last)")
        }
        XCTAssertEqual(text, "be brief")
    }

    func test_messageUpdate_replacesAssistantContentFromMessageSnapshot() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1",
            name: "message_start",
            payload: [:]
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When — raw pi frame: full partial message snapshot
        mockClient.emit(.event(messageUpdateEvent(
            thinking: "let's think", text: "hello "
        )))
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

        // Then — snapshot replaced the empty bubble, in order
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .assistant(_, content, _)? = items.last else {
            return XCTFail("Expected assistant item, got \(items.last)")
        }
        XCTAssertEqual(content, [.thinking("let's think"), .text("hello ")])
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
            self.mockClient.sentMessageCount(where: {
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
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "message_start", payload: [:]
        )))
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
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "message_start", payload: [:]
        )))
        mockClient.emit(.event(messageUpdateEvent(
            thinking: "", text: "done"
        )))
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

    // MARK: - Helpers

    func toolExecutionEvent(
        name: String,
        toolCallId: String,
        toolName: String
    ) -> CodeStreamEvent {
        CodeStreamEvent(
            sessionId: "s1",
            name: name,
            payload: [
                "toolCallId": .string(toolCallId),
                "toolName": .string(toolName),
                "args": .object([:]),
            ]
        )
    }

    /// Builds a raw pi `message_update` frame: the `message` object carries
    /// the full partial content snapshot (wire shape, not the normalized
    /// history shape).
    func messageUpdateEvent(
        thinking: String,
        text: String
    ) -> CodeStreamEvent {
        CodeStreamEvent(
            sessionId: "s1",
            name: "message_update",
            payload: [
                "message": .object([
                    "content": .array([
                        .object([
                            "type": .string("thinking"),
                            "thinking": .string(thinking),
                        ]),
                        .object([
                            "type": .string("text"),
                            "text": .string(text),
                        ]),
                    ]),
                ]),
            ]
        )
    }
}

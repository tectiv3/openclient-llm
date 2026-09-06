//
//  CodeViewModelTests+Streaming.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import XCTest
@testable import openclient_llm

// MARK: - CodeViewModelTests — Local echo / streaming / state refresh

extension CodeViewModelTests {
    func test_sendPrompt_connectedIdle_appendsLocalUserEcho() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then
        let items = try XCTUnwrap(currentSession()?.items)
        guard case .user(_, let text)? = items.last else {
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
                if case .steer(let text) = $0 { return text == "be brief" }
                return false
            }) == 1
        }

        // Then — steer also gets a local echo
        let items = try XCTUnwrap(currentSession()?.items)
        guard case .user(_, let text)? = items.last else {
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
                  case .assistant(_, let content, _)? = items.last else {
                return false
            }
            return content == [
                .thinking("let's think"), .text("hello ")
            ]
        }

        // Then — snapshot replaced the empty bubble, in order
        let items = try XCTUnwrap(currentSession()?.items)
        guard case .assistant(_, let content, _)? = items.last else {
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
                if case .getState = $0 { return true }
                return false
            }) == 1
        }
    }

    // MARK: - Helpers

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

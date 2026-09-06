//
//  CodeViewModelTests+EchoRetry.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/06/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Echo failure and retry

extension CodeViewModelTests {
    func test_sendPrompt_sendFails_marksLocalEchoFailed() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.sendResult = false

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then — the echo stays in the transcript, marked failed
        try await waitUntil { self.lastUserItem()?.failed == true }
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "hi")
        XCTAssertTrue(item.failed)
        XCTAssertEqual(currentSession()?.items.count, 1)
    }

    func test_sendSteer_sendFails_marksLocalEchoFailed() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.sendResult = false

        // When
        sut.send(.sendSteer(text: "be brief"))

        // Then
        try await waitUntil { self.lastUserItem()?.failed == true }
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "be brief")
        XCTAssertTrue(item.failed)
    }

    func test_errorNotIdle_trailingPendingEcho_marksEchoFailed() async throws {
        // Given — the echo was sent, the server rejected it
        try await connectAndEstablish()
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }

        // When
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))

        // Then
        try await waitUntil { self.lastUserItem()?.failed == true }
        XCTAssertEqual(currentSession()?.items.count, 1)
    }

    func test_errorNotIdle_trailingAssistantItem_mutatesNothing() async throws {
        // Given — an assistant item followed the prompt, so the
        // rejection is uncorrelatable and must be ignored
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then — no user item was created or mutated
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 1)
        guard case let .assistant(id, _, _) = items[0] else {
            return XCTFail("Expected assistant item, got \(items[0])")
        }
        XCTAssertFalse(
            items.contains { item in
                if case .user(_, _, true) = item {
                    return true
                }
                return false
            }
        )
        _ = id
    }

    func test_retryPrompt_failedEcho_clearsFlagAndResendsPrompt() async throws {
        // Given — a failed echo, as left behind by a failed send
        try await connectAndEstablish()
        mockClient.sendResult = false
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil { self.lastUserItem()?.failed == true }
        let echoId = try XCTUnwrap(lastUserItem()).id
        mockClient.sendResult = true

        // When
        sut.send(.retryPrompt(id: echoId))

        // Then — flag cleared, no duplicate echo, prompt sent again
        try await waitUntil { self.lastUserItem()?.failed == false }
        XCTAssertEqual(currentSession()?.items.count, 1)
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case let .prompt(text) = $0 {
                    return text == "hi"
                }
                return false
            }) == 2
        }
    }

    func test_retryPrompt_dedupedEcho_reusesExistingHistoryItem() async throws {
        // Given — the echo was deduped onto a synced history item
        try await connectAndEstablish()
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }
        mockClient.sendResult = false
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil { self.lastUserItem()?.failed == true }
        let echoId = try XCTUnwrap(lastUserItem()).id
        mockClient.sendResult = true

        // When
        sut.send(.retryPrompt(id: echoId))

        // Then — the single history item was reused, not duplicated
        try await waitUntil { self.lastUserItem()?.failed == false }
        XCTAssertEqual(currentSession()?.items.count, 1)
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case let .prompt(text) = $0 {
                    return text == "hi"
                }
                return false
            }) == 1
        }
    }

    func test_retryPrompt_whileStreaming_stillSends() async throws {
        // Given — the echo failed while idle, then the session started
        // streaming; the retry must not be swallowed by the `isStreaming`
        // guard in `handleSendPrompt`
        try await connectAndEstablish()
        mockClient.sendResult = false
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil { self.lastUserItem()?.failed == true }
        mockClient.emit(.state(sessionInfo(isStreaming: true)))
        try await waitUntil {
            (self.currentSession()?.isStreaming ?? false) == true
        }
        let echoId = try XCTUnwrap(lastUserItem()).id
        mockClient.sendResult = true

        // When
        sut.send(.retryPrompt(id: echoId))

        // Then — the prompt is sent despite streaming
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case let .prompt(text) = $0 {
                    return text == "hi"
                }
                return false
            }) == 2
        }
    }

    // MARK: - Helpers

    func lastUserItem() -> (id: UUID, text: String, failed: Bool)? {
        guard let items = currentSession()?.items,
              case let .user(id, text, failed)? = items.last
        else {
            return nil
        }
        return (id, text, failed)
    }
}

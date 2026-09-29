//
//  CodeViewModelTests+AbortSettle.swift
//  openclient-llm
//
//  Created by tectiv3 on 29/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Abort settle / outbox

// Kept in an extension file because the main suite already trips
// swiftlint's file/type length warnings.

extension CodeViewModelTests {
    func test_sendAbort_setsAwaitingSettle() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        sut.abortReconcileDelay = .seconds(30)
        sut.abortReabortDelay = .seconds(30)

        // When
        sut.send(.abort)

        // Then — local streaming cleared, but the server is not settled yet
        let session = try XCTUnwrap(currentSession())
        XCTAssertFalse(session.isStreaming)
        XCTAssertTrue(session.awaitingSettle)
    }

    func test_sendPrompt_whileAwaitingSettle_queuesAndSendsOnAgentSettled()
        async throws
    {
        // Given — Stop leaves the server settling
        try await connectAndEstablish(isStreaming: true)
        sut.abortReconcileDelay = .seconds(30)
        sut.abortReabortDelay = .seconds(30)
        sut.send(.abort)

        // When — a prompt composed while settling is queued, not sent
        sut.send(.sendPrompt(text: "next"))
        try await waitUntil { self.lastUserItem()?.text == "next" }

        // Then
        XCTAssertEqual(promptSends(), 0)
        XCTAssertEqual(sut.pendingOutbox.count, 1)
        XCTAssertEqual(lastUserItem()?.pending, true)

        // When — the server confirms the run settled
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "agent_settled", payload: [:]
        )))

        // Then — the queued prompt is delivered exactly once, no longer queued
        try await waitUntil { self.promptSends() == 1 }
        XCTAssertTrue(sut.pendingOutbox.isEmpty)
        XCTAssertEqual(lastUserItem()?.pending, false)
    }

    func test_sendPrompt_whileAwaitingSettle_stateIdleFlushes() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        sut.abortReconcileDelay = .seconds(30)
        sut.abortReabortDelay = .seconds(30)
        sut.send(.abort)
        sut.send(.sendPrompt(text: "next"))
        try await waitUntil { self.lastUserItem()?.text == "next" }
        XCTAssertEqual(promptSends(), 0)

        // When — a state frame reports the server idle
        mockClient.emit(.state(sessionInfo(sessionId: "s1", isStreaming: false)))

        // Then
        try await waitUntil { self.promptSends() == 1 }
        XCTAssertEqual(currentSession()?.awaitingSettle, false)
        XCTAssertTrue(sut.pendingOutbox.isEmpty)
        XCTAssertEqual(lastUserItem()?.pending, false)
    }

    func test_notIdle_requeuesPendingPrompt() async throws {
        // Given — Stop, then a prompt composed while awaiting settle
        try await connectAndEstablish(isStreaming: true)
        sut.abortReconcileDelay = .seconds(30)
        sut.abortReabortDelay = .seconds(30)
        sut.send(.abort)
        sut.send(.sendPrompt(text: "next"))
        try await waitUntil { self.lastUserItem()?.text == "next" }

        // When — a racing not_idle arrives
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))
        try await waitUntil { self.sut.transientToast != nil }

        // Then — the queued text is not marked failed and survives
        XCTAssertEqual(lastUserItem()?.failed, false)
        XCTAssertEqual(sut.pendingOutbox.count, 1)

        // And — a later settle still delivers it
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "agent_settled", payload: [:]
        )))
        try await waitUntil { self.promptSends() == 1 }
    }

    func test_notIdle_requeuesAlreadySentPrompt() async throws {
        // Given — a prompt was accepted by the local guard and sent, then
        // Stop issued while the server is still busy
        try await connectAndEstablish()
        sut.abortReconcileDelay = .seconds(30)
        sut.abortReabortDelay = .seconds(30)
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil { self.promptSends() == 1 }
        sut.send(.abort)

        // When — the server rejects the in-flight prompt
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))
        try await waitUntil { self.lastUserItem()?.pending == true }

        // Then — it is requeued for a later send, not marked failed
        XCTAssertEqual(lastUserItem()?.failed, false)
        XCTAssertEqual(sut.pendingOutbox.count, 1)

        // And — the next settle delivers it
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "agent_settled", payload: [:]
        )))
        try await waitUntil { self.promptSends() == 2 }
    }

    func test_disconnect_clearsOutbox() async throws {
        // Given — a prompt queued while awaiting settle
        try await connectAndEstablish(isStreaming: true)
        sut.abortReconcileDelay = .seconds(30)
        sut.abortReabortDelay = .seconds(30)
        sut.send(.abort)
        sut.send(.sendPrompt(text: "queued"))
        try await waitUntil { self.sut.pendingOutbox.count == 1 }
        XCTAssertEqual(currentSession()?.awaitingSettle, true)

        // When
        sut.send(.disconnect)

        // Then
        XCTAssertTrue(sut.pendingOutbox.isEmpty)
        XCTAssertNil(currentSession())
        guard case .disconnected = sut.state else {
            return XCTFail("Expected disconnected, got \(sut.state)")
        }

        // And — a fresh connection does not inherit the settle gate
        try await connectAndEstablish()
        XCTAssertEqual(currentSession()?.awaitingSettle, false)
    }

    // MARK: - Helpers

    private func promptSends() -> Int {
        mockClient.attemptsCount(where: {
            if case .prompt = $0 {
                return true
            }
            return false
        })
    }
}

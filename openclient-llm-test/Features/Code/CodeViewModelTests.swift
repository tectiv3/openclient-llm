//
//  CodeViewModelTests.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import XCTest
@testable import openclient_llm

@MainActor
final class CodeViewModelTests: XCTestCase {
    // MARK: - Properties

    var sut: CodeViewModel!
    var mockClient: MockCodeServerClient!
    var mockSettings: MockSettingsManager!
    var mockBackground: MockCodeBackgroundUseCase!
    var mockNotifications: MockLocalNotificationManager!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        mockClient = MockCodeServerClient()
        mockSettings = MockSettingsManager()
        mockBackground = MockCodeBackgroundUseCase()
        mockNotifications = MockLocalNotificationManager()
        sut = CodeViewModel(
            client: mockClient,
            settingsManager: mockSettings,
            backgroundUseCase: mockBackground,
            notificationManager: mockNotifications
        )
    }

    override func tearDown() {
        mockClient.finishStream()
        sut = nil
        mockClient = nil
        mockSettings = nil
        mockBackground = nil
        mockNotifications = nil
        super.tearDown()
    }

    // MARK: - Tests — Connect / disconnect transitions

    func test_send_connect_transitionsToConnectingAndSendsHello() async throws {
        // When
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))

        // Then
        XCTAssertEqual(sut.state, .connecting)
        XCTAssertEqual(mockClient.connectCalls.count, 1)
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case .hello = $0 { return true }
                return false
            }) == 1
        }
    }

    func test_connect_helloOk_transitionsToConnected() async throws {
        // Given
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))

        // When
        mockClient.emit(.helloOk(version: 1))
        try await waitUntil {
            if case .connected = self.sut.state { return true }
            return false
        }

        // Then
        guard case .connected = sut.state else {
            return XCTFail("Expected connected, got \(sut.state)")
        }
    }

    func test_connect_stateEvent_updatesSessionFields() async throws {
        // Given
        try await connectAndEstablish(sessionId: "s1")

        // Then
        let session = try XCTUnwrap(currentSession())
        XCTAssertEqual(session.sessionId, "s1")
        XCTAssertEqual(session.cwd, "/tmp/project")
        XCTAssertEqual(session.model?.id, "model-1")
        XCTAssertFalse(session.isStreaming)
    }

    func test_send_disconnect_fromConnected_resetsToDisconnected() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.disconnect)

        // Then
        guard case .disconnected(let form) = sut.state else {
            return XCTFail("Expected disconnected, got \(sut.state)")
        }
        XCTAssertNil(form.errorMessage)
        XCTAssertEqual(mockClient.disconnectCount, 1)
    }

    func test_send_cancelConnect_fromConnecting_resetsToDisconnected() {
        // Given
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))

        // When
        sut.send(.cancelConnect)

        // Then
        guard case .disconnected = sut.state else {
            return XCTFail("Expected disconnected, got \(sut.state)")
        }
    }

    func test_event_connectionFailed_setsFailedState() async throws {
        // Given
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))

        // When
        mockClient.emit(.connectionFailed("boom"))
        try await waitUntil {
            if case .failed = self.sut.state { return true }
            return false
        }

        // Then
        guard case .failed(let message) = sut.state else {
            return XCTFail("Expected failed, got \(sut.state)")
        }
        XCTAssertEqual(message, "boom")
    }

    func test_event_authFailed_badCode_returnsToDisconnectedWithMessage() async throws {
        // Given
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "badcode"))

        // When
        mockClient.emit(.authFailed(
            CodeServerError(code: "bad_code", message: "invalid")
        ))
        try await waitUntil {
            if case .disconnected = self.sut.state { return true }
            return false
        }

        // Then
        guard case .disconnected(let form) = sut.state else {
            return XCTFail("Expected disconnected, got \(sut.state)")
        }
        XCTAssertNotNil(form.errorMessage)
    }

    // MARK: - Tests — Prompt / steer / abort routing

    func test_sendPrompt_connectedIdle_sendsPromptMessage() async throws {
        // Given
        try await connectAndEstablish()

        // When / Then — waits until exactly one prompt with the text is sent
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case .prompt(let text) = $0 { return text == "hi" }
                return false
            }) == 1
        }
    }

    func test_sendPrompt_connectedStreaming_doesNotSend() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)

        // When
        sut.send(.sendPrompt(text: "hi"))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(
            mockClient.sentMessageCount(where: {
                if case .prompt = $0 { return true }
                return false
            }),
            0
        )
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
    }

    func test_sendSteer_connectedIdle_doesNotSend() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.sendSteer(text: "be brief"))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(
            mockClient.sentMessageCount(where: {
                if case .steer = $0 { return true }
                return false
            }),
            0
        )
    }

    func test_sendAbort_connected_sendsAbortMessage() async throws {
        // Given
        try await connectAndEstablish()

        // When / Then — waits until exactly one abort is sent
        sut.send(.abort)
        try await waitUntil {
            self.mockClient.sentMessageCount(where: {
                if case .abort = $0 { return true }
                return false
            }) == 1
        }
    }

    func test_sendAbort_disconnected_doesNotSend() async throws {
        // When
        sut.send(.abort)
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(
            mockClient.sentMessageCount(where: {
                if case .abort = $0 { return true }
                return false
            }),
            0
        )
    }

    // MARK: - Tests — History and streaming buffer

    func test_history_event_populatesTranscriptItems() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [
                .user(text: "hi"),
                .assistant(content: [.text("yo")])
            ],
            cursor: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 2
        }

        // Then
        let items = try XCTUnwrap(currentSession()?.items)
        guard case .user(_, let text) = items[0] else {
            return XCTFail("Expected user item, got \(items[0])")
        }
        XCTAssertEqual(text, "hi")
        guard case .assistant = items[1] else {
            return XCTFail("Expected assistant item, got \(items[1])")
        }
    }

    func test_history_sessionIdMismatch_ignored() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.history(CodeHistory(
            sessionId: "other",
            messages: [.user(text: "hi")],
            cursor: nil
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    func test_streamingBuffer_matchingSession_appendsStreamingAssistantItem() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.streamingBuffer(sessionId: "s1", content: [.text("partial")]))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // Then
        let item = try XCTUnwrap(currentSession()?.items.first)
        guard case .assistant(_, let content, let isStreaming) = item else {
            return XCTFail("Expected assistant item, got \(item)")
        }
        XCTAssertEqual(content, [.text("partial")])
        XCTAssertTrue(isStreaming)
    }

    func test_streamingBuffer_staleSessionId_ignored() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.streamingBuffer(
            sessionId: "stale", content: [.text("nope")]
        ))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    // MARK: - Tests — Reconnect

    func test_disconnected_event_fromConnected_transitionsToReconnecting() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.disconnected)
        try await waitUntil {
            if case .reconnecting = self.sut.state { return true }
            return false
        }

        // Then
        let session = try XCTUnwrap(currentSession())
        XCTAssertEqual(session.sessionId, "s1", "Session preserved while reconnecting")
    }

    func test_reconnect_helloOk_restoresConnectedWithSameSession() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.disconnected)
        try await waitUntil {
            if case .reconnecting = self.sut.state { return true }
            return false
        }

        // When
        mockClient.emit(.helloOk(version: 1))
        try await waitUntil {
            if case .connected = self.sut.state { return true }
            return false
        }

        // Then
        XCTAssertEqual(try XCTUnwrap(currentSession())?.sessionId, "s1")
    }

    func test_backgroundReconnect_foregrounding_sendsHelloAgain() async throws {
        // Given
        try await connectAndEstablish()
        sut.isBackgrounded = { true }
        sut.send(.appDidEnterBackground)
        try await waitUntil { self.mockBackground.beginCount == 1 }
        try XCTUnwrap(mockBackground.expirationHandler)()
        guard case .disconnected = sut.state else {
            return XCTFail("Expected disconnected after background expiry")
        }

        // When
        sut.send(.appWillEnterForeground)
        try await waitUntil {
            self.mockClient.connectCalls.count == 2 &&
            self.mockClient.sentMessageCount(where: {
                if case .hello = $0 { return true }
                return false
            }) == 2
        }

        // Then — reconnected and re-sent hello
        XCTAssertEqual(mockClient.connectCalls.count, 2)
    }

    func test_state_newSessionId_rebindsAndClearsItems() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.streamingBuffer(sessionId: "s1", content: [.text("x")]))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When
        mockClient.emit(.state(sessionInfo(sessionId: "s2")))
        try await waitUntil {
            self.currentSession()?.sessionId == "s2"
        }

        // Then
        let session = try XCTUnwrap(currentSession())
        XCTAssertEqual(session.sessionId, "s2")
        XCTAssertEqual(session.items.count, 0, "Rebind clears stale transcript")
    }

    func test_streamEvent_staleSessionId_ignored() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "stale",
            name: "agent_start",
            payload: [:]
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(currentSession()?.isStreaming, false)
    }

    // MARK: - Helpers

    /// Connects, acks with hello_ok + state, and waits until `.connected`.
    func connectAndEstablish(
        sessionId: String = "s1",
        isStreaming: Bool = false
    ) async throws {
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))
        mockClient.emit(.helloOk(version: 1))
        mockClient.emit(.state(sessionInfo(sessionId: sessionId, isStreaming: isStreaming)))
        try await waitUntil {
            if case .connected = self.sut.state { return true }
            return false
        }
    }

    func currentSession() -> CodeViewModel.SessionState? {
        switch sut.state {
        case .connected(let session), .reconnecting(let session):
            return session
        default:
            return nil
        }
    }

    func sessionInfo(
        sessionId: String = "s1",
        isStreaming: Bool = false
    ) -> CodeSessionInfo {
        CodeSessionInfo(
            sessionId: sessionId,
            cwd: "/tmp/project",
            sessionName: nil,
            model: CodeModelInfo(provider: "pi", id: "model-1"),
            thinkingLevel: nil,
            isStreaming: isStreaming,
            contextUsage: nil
        )
    }

    func waitUntil(
        _ timeout: TimeInterval = 2.0,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            try await Task.sleep(for: .milliseconds(10))
            if Date.now > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
        }
    }
}

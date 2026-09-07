//
//  CodeNotificationTests.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

@MainActor
final class CodeNotificationTests: XCTestCase {
    // MARK: - Properties

    private var sut: CodeViewModel!
    private var mockClient: MockCodeServerClient!
    private var mockSettings: MockSettingsManager!
    private var mockBackground: MockCodeBackgroundUseCase!
    private var mockNotifications: MockLocalNotificationManager!

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

    // MARK: - Tests

    func test_question_backgrounded_firesQuestionNotificationExactlyOnce() async throws {
        // Given
        try await connectAndEstablish()
        sut.isBackgrounded = { true }

        // When
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 1)
    }

    func test_multiQuestion_backgrounded_firesQuestionNotificationExactlyOnce() async throws {
        // Given
        try await connectAndEstablish()
        sut.isBackgrounded = { true }

        // When
        mockClient.emit(.question(Self.multiQuestion(id: "s1a")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 1)
    }

    func test_question_foregrounded_doesNotFireNotification() async throws {
        // Given
        try await connectAndEstablish()
        sut.isBackgrounded = { false }

        // When
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 0)
    }

    func test_question_staleSessionId_doesNotFireNotification() async throws {
        // Given
        try await connectAndEstablish()
        sut.isBackgrounded = { true }

        // When
        mockClient.emit(
            .question(Self.question(id: "q1", sessionId: "stale"))
        )
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 0)
    }

    func test_questionResolved_backgrounded_doesNotFireNotification() async throws {
        // Given
        try await connectAndEstablish()
        sut.isBackgrounded = { true }

        // When
        mockClient.emit(.questionResolved(CodeQuestionResolved(
            id: "q1", resolvedBy: "client", value: "yes"
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 0)
    }

    // MARK: - Tests — Background transition

    func test_appDidEnterBackground_withPendingQuestion_firesQuestionNotification() async throws {
        // Given — question arrives while foregrounded (push suppressed,
        // no notification yet)
        try await connectAndEstablish()
        sut.isBackgrounded = { false }
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // When
        sut.send(.appDidEnterBackground)

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 1)
        XCTAssertEqual(mockNotifications.sendQuestionIds, ["q1"])
    }

    func test_appDidEnterBackground_withoutPendingQuestion_doesNotFireNotification() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.appDidEnterBackground)

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 0)
    }

    func test_appDidEnterBackground_alreadyNotifiedQuestion_doesNotDuplicate() async throws {
        // Given — question arrived while backgrounded (notification fired)
        try await connectAndEstablish()
        sut.isBackgrounded = { true }
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }
        XCTAssertEqual(mockNotifications.sendQuestionCount, 1)

        // When — briefly foregrounded, then backgrounded again with the
        // question still pending
        sut.isBackgrounded = { false }
        sut.send(.appWillEnterForeground)
        sut.send(.appDidEnterBackground)

        // Then
        XCTAssertEqual(mockNotifications.sendQuestionCount, 1)
    }

    // MARK: - Helpers

    private func connectAndEstablish() async throws {
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))
        mockClient.emit(.helloOk(version: 1))
        mockClient.emit(.state(CodeSessionInfo(
            sessionId: "s1",
            cwd: "/tmp/project",
            sessionName: nil,
            model: CodeModelInfo(provider: "pi", id: "model-1"),
            thinkingLevel: nil,
            isStreaming: false,
            contextUsage: nil
        )))
        try await waitUntil {
            if case .connected = self.sut.state {
                return true
            }
            return false
        }
    }

    private func currentSession() -> CodeViewModel.SessionState? {
        switch sut.state {
        case let .connected(session), let .reconnecting(session):
            return session
        default:
            return nil
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date.now.addingTimeInterval(2.0)
        while !condition() {
            try await Task.sleep(for: .milliseconds(10))
            if Date.now > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
        }
    }

    private static func question(id: String, sessionId: String = "s1") -> CodeQuestion {
        CodeQuestion(
            sessionId: sessionId,
            id: id,
            kind: "ask_user_question",
            params: CodeQuestionParams(
                questions: [
                    CodeSubQuestion(
                        id: "Q1",
                        label: nil,
                        prompt: "Pick one",
                        options: [
                            CodeQuestionOption(label: "Yes", value: "yes"),
                        ],
                        allowOther: nil
                    ),
                ]
            )
        )
    }

    private static func multiQuestion(id: String) -> CodeQuestion {
        CodeQuestion(
            sessionId: "s1",
            id: id,
            kind: "ask_user_question",
            params: CodeQuestionParams(
                questions: [
                    CodeSubQuestion(
                        id: "q1",
                        label: nil,
                        prompt: "Which environment?",
                        options: [
                            CodeQuestionOption(label: "A", value: "a"),
                        ],
                        allowOther: nil
                    ),
                    CodeSubQuestion(
                        id: "q2",
                        label: nil,
                        prompt: "Which size?",
                        options: [
                            CodeQuestionOption(label: "B", value: "b"),
                        ],
                        allowOther: nil
                    ),
                ]
            )
        )
    }
}

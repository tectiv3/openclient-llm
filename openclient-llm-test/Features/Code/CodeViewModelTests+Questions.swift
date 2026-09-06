//
//  CodeViewModelTests+Questions.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Questions

extension CodeViewModelTests {
    // MARK: - Question / questionnaire receipt

    func test_question_event_setsPendingQuestion() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // Then
        let pending = try XCTUnwrap(currentSession()?.pendingQuestion)
        XCTAssertEqual(pending.id, "q1")
        guard case let .question(params) = pending.kind else {
            return XCTFail("Expected question kind")
        }
        XCTAssertEqual(params.question, "Pick one")
    }

    func test_questionnaire_event_setsPendingQuestionnaire() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.questionnaire(Self.questionnaire(id: "s1a")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // Then
        guard case .questionnaire =
            try XCTUnwrap(currentSession()?.pendingQuestion)?.kind
        else {
            return XCTFail("Expected questionnaire kind")
        }
    }

    func test_question_staleSessionId_ignored() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.question(Self.question(id: "q1", sessionId: "stale")))
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertNil(currentSession()?.pendingQuestion)
    }

    func test_reDeliveredQuestion_sameId_isNotDuplicated() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // When — the server re-delivers the same pending question on reconnect
        mockClient.emit(.question(Self.question(id: "q1")))
        try await Task.sleep(for: .milliseconds(100))

        // Then — still exactly one pending question, no transcript entry added
        XCTAssertEqual(currentSession()?.pendingQuestion?.id, "q1")
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    // MARK: - Answers

    func test_answer_connected_sendsAnswerMessageAndDismisses() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // When
        sut.send(.answer(id: "q1", value: "yes", wasCustom: false, index: 0))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .answer(id, value, wasCustom, index) = $0 {
                    return id == "q1" && value == "yes"
                        && !wasCustom && index == 0
                }
                return false
            }) == 1
        }

        // Then
        XCTAssertNil(currentSession()?.pendingQuestion)
    }

    func test_answer_reconnecting_queuesAndSendsOnReconnect() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.disconnected)
        try await waitUntil {
            if case .reconnecting = self.sut.state {
                return true
            }
            return false
        }

        // When
        sut.send(.answer(id: "q1", value: "yes", wasCustom: false, index: nil))
        XCTAssertEqual(
            mockClient.attemptsCount(where: {
                if case .answer = $0 {
                    return true
                }
                return false
            }),
            0, "Answer must not be sent while the transport is down"
        )

        mockClient.emit(.helloOk(version: 1))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .answer = $0 {
                    return true
                }
                return false
            }) == 1
        }

        // Then — queued answer sent exactly once on re-hello
        XCTAssertEqual(
            mockClient.attemptsCount(where: {
                if case .answer = $0 {
                    return true
                }
                return false
            }),
            1
        )
    }

    func test_answerQuestionnaire_connected_sendsQuestionnaireAnswers() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.questionnaire(Self.questionnaire(id: "s1a")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }
        let answers = [
            CodeQuestionnaireAnswer(
                id: "q1", value: "a", label: "A", wasCustom: false, index: 0
            ),
        ]

        // When
        sut.send(.answerQuestionnaire(id: "s1a", answers: answers))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .answerQuestionnaire(id, sent) = $0 {
                    return id == "s1a"
                        && sent.count == 1
                        && sent.first?.id == "q1"
                        && sent.first?.value == "a"
                }
                return false
            }) == 1
        }

        // Then
        XCTAssertNil(currentSession()?.pendingQuestion)
    }

    // MARK: - Question resolution

    func test_questionResolved_resolvesPendingQuestion() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // When
        mockClient.emit(.questionResolved(CodeQuestionResolved(
            id: "q1", resolvedBy: "client", value: "yes"
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // Then — a client-resolved answer is appended to the transcript
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(currentSession()?.pendingQuestion)
        guard case let .resolvedQuestion(_, questionText, answerText, _)
            = items[0]
        else {
            return XCTFail("Expected resolvedQuestion item, got \(items[0])")
        }
        XCTAssertEqual(questionText, "Pick one")
        XCTAssertEqual(answerText, "yes")
    }

    // MARK: - Helpers

    static func question(id: String, sessionId: String = "s1") -> CodeQuestion {
        CodeQuestion(
            sessionId: sessionId,
            id: id,
            kind: "question",
            params: CodeQuestionParams(
                question: "Pick one",
                options: [
                    CodeQuestionOption(label: "Yes", value: "yes"),
                    CodeQuestionOption(label: "No", value: "no"),
                ]
            )
        )
    }

    static func questionnaire(id: String) -> CodeQuestionnaire {
        CodeQuestionnaire(
            sessionId: "s1",
            id: id,
            kind: "questionnaire",
            params: CodeQuestionnaireParams(
                questions: [
                    CodeSubQuestion(
                        id: "q1",
                        label: nil,
                        prompt: "Pick one",
                        options: [
                            CodeQuestionOption(label: "A", value: "a"),
                        ],
                        allowOther: nil
                    ),
                ]
            )
        )
    }
}

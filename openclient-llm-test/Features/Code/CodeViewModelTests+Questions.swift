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
    // MARK: - Question receipt

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
        let first = try XCTUnwrap(
            pending.params.questions.first,
            "A single-question ask carries one sub-question"
        )
        XCTAssertEqual(first.prompt, "Pick one")
    }

    func test_multiQuestion_event_setsPendingQuestion() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockClient.emit(.question(Self.multiQuestion(id: "s1a")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // Then
        let pending = try XCTUnwrap(currentSession()?.pendingQuestion)
        XCTAssertEqual(pending.id, "s1a")
        XCTAssertEqual(pending.params.questions.count, 2)
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

    // MARK: - Answers (unified frame)

    func test_answer_connected_sendsAnswerMessageAndDismisses() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // When
        sut.send(.answer(id: "q1", answers: [
            CodeAnswer(id: "Q1", value: "yes", label: "Yes", wasCustom: false, index: 1),
        ]))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .answer(id, answers) = $0 {
                    return id == "q1" && answers.count == 1
                        && answers.first?.value == "yes"
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
        sut.send(.answer(id: "q1", answers: [
            CodeAnswer(
                id: "Q1", value: "yes", label: "Yes",
                wasCustom: false, index: nil
            ),
        ]))
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

    func test_multiQuestion_answer_sendsAllAnswers() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.question(Self.multiQuestion(id: "s1a")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }
        let answers = [
            CodeAnswer(id: "q1", value: "a", label: "A", wasCustom: false, index: 1),
            CodeAnswer(id: "q2", value: "b", label: "B", wasCustom: false, index: 1),
        ]

        // When
        sut.send(.answer(id: "s1a", answers: answers))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .answer(id, sent) = $0 {
                    return id == "s1a" && sent.count == 2
                        && sent.first?.id == "q1"
                        && sent.first?.value == "a"
                }
                return false
            }) == 1
        }

        // Then
        XCTAssertNil(currentSession()?.pendingQuestion)
    }

    func test_answer_single_appendsResolvedTranscriptWithValue() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.question(Self.question(id: "q1")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // When
        sut.send(.answer(id: "q1", answers: [
            CodeAnswer(
                id: "Q1", value: "yes", label: "Yes",
                wasCustom: false, index: 1
            ),
        ]))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // Then — a single answer shows its value
        let item = try XCTUnwrap(currentSession()?.items.first)
        guard case let .resolvedQuestion(_, questionText, answerText, wasCustom)
            = item
        else {
            return XCTFail("Expected resolvedQuestion, got \(item)")
        }
        XCTAssertEqual(questionText, "Pick one")
        XCTAssertEqual(answerText, "yes")
        XCTAssertFalse(wasCustom)
    }

    func test_multiQuestion_answer_appendsResolvedTranscriptWithSummary() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.emit(.question(Self.multiQuestion(id: "s1a")))
        try await waitUntil {
            self.currentSession()?.pendingQuestion != nil
        }

        // When
        sut.send(.answer(id: "s1a", answers: [
            CodeAnswer(id: "q1", value: "a", label: "A", wasCustom: false, index: 1),
            CodeAnswer(id: "q2", value: "b", label: "B", wasCustom: false, index: 1),
        ]))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // Then — a multi answer shows the joined labels
        let item = try XCTUnwrap(currentSession()?.items.first)
        guard case let .resolvedQuestion(_, questionText, answerText, wasCustom)
            = item
        else {
            return XCTFail("Expected resolvedQuestion, got \(item)")
        }
        XCTAssertEqual(questionText, "Which environment?")
        XCTAssertEqual(answerText, "A, B")
        XCTAssertFalse(wasCustom)
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

    static func question(
        id: String,
        sessionId: String = "s1",
        prompt: String = "Pick one"
    ) -> CodeQuestion {
        CodeQuestion(
            sessionId: sessionId,
            id: id,
            kind: "ask_user_question",
            params: CodeQuestionParams(
                questions: [
                    CodeSubQuestion(
                        id: "Q1",
                        label: nil,
                        prompt: prompt,
                        options: [
                            CodeQuestionOption(label: "Yes", value: "yes"),
                            CodeQuestionOption(label: "No", value: "no"),
                        ],
                        allowOther: nil
                    ),
                ]
            )
        )
    }

    static func multiQuestion(id: String) -> CodeQuestion {
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

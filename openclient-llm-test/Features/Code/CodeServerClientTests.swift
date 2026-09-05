//
//  CodeServerClientTests.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import XCTest
@testable import openclient_llm

@MainActor
final class CodeServerClientTests: XCTestCase {
    // MARK: - Properties

    private var transport: MockCodeWebSocketTransport!
    // Fast ping cadence keeps the ping/pong tests under a few seconds.
    private var sut: CodeServerClient!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        transport = MockCodeWebSocketTransport()
        sut = CodeServerClient(
            transport: transport,
            pingIntervalSeconds: 1.0,
            pongTimeoutSeconds: 1.0
        )
    }

    override func tearDown() {
        sut.disconnect()
        sut = nil
        transport = nil
        super.tearDown()
    }

    // MARK: - Tests — Client -> Server framing

    func test_send_hello_encodesHelloFrame() async throws {
        // Given
let stream = sut.connect(host: "10.0.0.1", port: 47800, code: "abc123")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.hello(code: "abc123"))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "hello")
        XCTAssertEqual(frame?["code"] as? String, "abc123")
        XCTAssertEqual(frame?["version"] as? Int, 1)
    }

    func test_send_prompt_encodesPromptFrame() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.prompt(text: "do the thing"))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "prompt")
        XCTAssertEqual(frame?["text"] as? String, "do the thing")
    }

    func test_send_steer_encodesSteerFrame() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.steer(text: "actually, be brief"))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "steer")
        XCTAssertEqual(frame?["text"] as? String, "actually, be brief")
    }

    func test_send_abort_encodesAbortFrame() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.abort)

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?.count, 1)
        XCTAssertEqual(frame?["type"] as? String, "abort")
    }

    func test_send_answer_encodesAnswerFrameWithIndex() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.answer(id: "q1", value: "yes", wasCustom: false, index: 0))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "answer")
        XCTAssertEqual(frame?["id"] as? String, "q1")
        XCTAssertEqual(frame?["value"] as? String, "yes")
        XCTAssertEqual(frame?["wasCustom"] as? Bool, false)
        XCTAssertEqual(frame?["index"] as? Int, 0)
    }

    func test_send_answerWithoutIndex_omitsIndexKey() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.answer(
            id: "q1", value: "custom text", wasCustom: true, index: nil
        ))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "answer")
        XCTAssertNil(frame?["index"])
        XCTAssertEqual(frame?["wasCustom"] as? Bool, true)
    }

    func test_send_answerQuestionnaire_encodesAnswersArray() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)
        let answers = [
            CodeQuestionnaireAnswer(
                id: "q1", value: "a", label: "A", wasCustom: false, index: 0
            ),
            CodeQuestionnaireAnswer(
                id: "q2", value: "b", label: "B", wasCustom: true, index: nil
            )
        ]

        // When
        await sut.send(.answerQuestionnaire(id: "survey", answers: answers))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "answer_questionnaire")
        XCTAssertEqual(frame?["id"] as? String, "survey")
        let rows = frame?["answers"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?["id"] as? String, "q1")
        XCTAssertEqual(rows.last?["value"] as? String, "b")
    }

    func test_send_getState_and_getHistory_encodeExpectedFrames() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.getState)
        await sut.send(.getHistory(cursor: "cursor-1"))
        await sut.send(.getHistory(cursor: nil))

        // Then
        let frames = try task.sentFrames.map { try Self.decodeFrame($0) }
        XCTAssertEqual(frames[0]["type"] as? String, "get_state")
        XCTAssertEqual(frames[1]["type"] as? String, "get_history")
        XCTAssertEqual(frames[1]["cursor"] as? String, "cursor-1")
        XCTAssertEqual(frames[2]["type"] as? String, "get_history")
        XCTAssertNil(frames[2]["cursor"])
    }

    // MARK: - Tests — Server -> Client framing

    func test_connect_helloOkJson_decodesHelloOkEvent() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        try XCTUnwrap(transport.lastTask).enqueue(#"{"type":"hello_ok","version":1}"#)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .helloOk(let version) = event else {
            return XCTFail("Expected helloOk, got \(String(describing: event))")
        }
        XCTAssertEqual(version, 1)
    }

    func test_connect_stateJson_decodesStateEvent() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"state","sessionId":"s1","cwd":"/tmp/project",
         "model":{"provider":"pi","id":"model-1"},"isStreaming":false,
         "contextUsage":{"used":10,"total":100}}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .state(let info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertEqual(info.sessionId, "s1")
        XCTAssertEqual(info.cwd, "/tmp/project")
        XCTAssertEqual(info.model.id, "model-1")
        XCTAssertFalse(info.isStreaming)
        XCTAssertEqual(info.contextUsage?.used, 10)
        XCTAssertEqual(info.contextUsage?.total, 100)
    }

    func test_connect_historyJson_decodesHistoryEvent() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"history","sessionId":"s1","cursor":"c1",
         "messages":[{"role":"user","text":"hi"}]}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .history(let history) = event else {
            return XCTFail("Expected history, got \(String(describing: event))")
        }
        XCTAssertEqual(history.sessionId, "s1")
        XCTAssertEqual(history.cursor, "c1")
        XCTAssertEqual(history.messages.count, 1)
    }

    func test_connect_streamingBufferJson_decodesStreamingBufferEvent() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"streaming_buffer","sessionId":"s1",
         "content":[{"type":"text","text":"partial"}]}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .streamingBuffer(let sessionId, let content) = event else {
            return XCTFail(
                "Expected streamingBuffer, got \(String(describing: event))"
            )
        }
        XCTAssertEqual(sessionId, "s1")
        XCTAssertEqual(content, [.text("partial")])
    }

    func test_connect_unknownType_decodesAsUnknown() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        try XCTUnwrap(transport.lastTask).enqueue(#"{"type":"mystery","foo":1}"#)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .unknown = event else {
            return XCTFail("Expected unknown, got \(String(describing: event))")
        }
    }

    // MARK: - Tests — Error mapping

    func test_errorBadCode_mapsToAuthFailedAndDisconnects() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "badcode")
        let task = try XCTUnwrap(transport.lastTask)
        task.enqueue(#"{"type":"error","code":"bad_code","message":"invalid"}"#)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .authFailed(let serverError) = event else {
            return XCTFail("Expected authFailed, got \(String(describing: event))")
        }
        XCTAssertEqual(serverError.code, "bad_code")
        // The client disconnects right after yielding; poll briefly.
        let deadline = Date.now.addingTimeInterval(1.0)
        while task.cancelCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
            if Date.now > deadline { break }
        }
        XCTAssertGreaterThan(task.cancelCount, 0, "Client must close the socket")
    }

    func test_errorRateLimited_mapsToAuthFailed() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        try XCTUnwrap(transport.lastTask).enqueue(#"{"type":"error","code":"rate_limited"}"#)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .authFailed(let serverError) = event else {
            return XCTFail("Expected authFailed, got \(String(describing: event))")
        }
        XCTAssertEqual(serverError.code, "rate_limited")
    }

    func test_errorOtherCode_passesThroughAsError() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        try XCTUnwrap(transport.lastTask).enqueue(
            #"{"type":"error","code":"not_idle","message":"streaming"}"#
        )

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case .error(let serverError) = event else {
            return XCTFail("Expected error, got \(String(describing: event))")
        }
        XCTAssertEqual(serverError.code, "not_idle")
        XCTAssertEqual(transport.tasks.count, 1, "No reconnect on plain error")
    }

    // MARK: - Tests — Ping / pong

    func test_pingLoop_pongReceived_sendsPingsAndKeepsConnection() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        try await Task.sleep(for: .seconds(2.5))

        // Then
        XCTAssertGreaterThanOrEqual(task.sentPingCount, 2)
        XCTAssertEqual(transport.tasks.count, 1, "Pong replies prevent reconnects")
    }

    func test_pingLoop_missingPong_reconnectsAndResendsHello() async throws {
        // Given
        transport.autoPong = false
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }

        // When
        try await Task.sleep(for: .seconds(3.0))

        // Then
        XCTAssertGreaterThanOrEqual(transport.tasks.count, 2,
                                    "Missing pong must trigger a reconnect")
        let reconnectedTask = transport.tasks[1]
        XCTAssertTrue(reconnectedTask.sentFrames.contains {
            (try? Self.decodeFrame($0))?["type"] as? String == "hello"
        }, "Reconnect must re-send hello")
    }

    // MARK: - Tests — Connection loss

    func test_receiveLoop_connectionLoss_cancelsStaleTask() async throws {
        // Given
let stream = sut.connect(host: "h", port: 1, code: "c")
// Keep the stream alive for the duration of the test;
// releasing it would terminate the client's continuation.
defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        task.enqueueFailure(URLError(.networkConnectionLost))
        try await Task.sleep(for: .seconds(0.5))

        // Then
        XCTAssertGreaterThan(task.cancelCount, 0,
                             "Lost connection must cancel the stale socket")
    }

    // MARK: - Helpers

    private func nextEvent(from stream: AsyncStream<CodeEvent>) async throws -> CodeEvent {
        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        return try XCTUnwrap(next, "Stream ended before the expected event")
    }

    private static func decodeFrame(_ frame: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: Data(frame.utf8)
        )
        return object as? [String: Any] ?? [:]
    }
}

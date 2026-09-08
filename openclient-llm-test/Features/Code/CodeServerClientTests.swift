//
//  CodeServerClientTests.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

@MainActor
final class CodeServerClientTests: XCTestCase {
    // MARK: - Properties

    private var transport: MockCodeWebSocketTransport!
    /// Fast ping cadence keeps the ping/pong tests under a few seconds.
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
        await sut.send(
            .answer(
                id: "q1",
                answers: [
                    CodeAnswer(
                        id: "Q1", value: "yes", label: "Yes",
                        wasCustom: false, index: 1
                    ),
                ]
            )
        )

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "answer")
        XCTAssertEqual(frame?["id"] as? String, "q1")
        let rows = frame?["answers"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as? String, "Q1")
        XCTAssertEqual(rows.first?["value"] as? String, "yes")
        XCTAssertEqual(rows.first?["wasCustom"] as? Bool, false)
        XCTAssertEqual(rows.first?["index"] as? Int, 1)
    }

    func test_send_answerWithoutIndex_omitsIndexKey() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        // Keep the stream alive for the duration of the test;
        // releasing it would terminate the client's continuation.
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(
            .answer(
                id: "q1",
                answers: [
                    CodeAnswer(
                        id: "Q1", value: "custom text",
                        label: "custom text", wasCustom: true, index: nil
                    ),
                ]
            )
        )

        // Then — the unified frame omits a nil index on the row.
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "answer")
        XCTAssertEqual(frame?["id"] as? String, "q1")
        let row = (frame?["answers"] as? [[String: Any]])?.first ?? [:]
        XCTAssertEqual(row["value"] as? String, "custom text")
        XCTAssertEqual(row["wasCustom"] as? Bool, true)
        XCTAssertNil(row["index"])
    }

    func test_send_answer_encodesMultiQuestionAnswersArray() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        // Keep the stream alive for the duration of the test;
        // releasing it would terminate the client's continuation.
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)
        let answers = [
            CodeAnswer(
                id: "q1", value: "a", label: "A", wasCustom: false, index: 1
            ),
            CodeAnswer(
                id: "q2", value: "b", label: "B", wasCustom: true, index: nil
            ),
        ]

        // When
        await sut.send(.answer(id: "survey", answers: answers))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "answer")
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

    func test_send_pushToken_encodesPushTokenFrame() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        // Keep the stream alive for the duration of the test;
        // releasing it would terminate the client's continuation.
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)
        let token = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

        // When
        await sut.send(.pushToken(token: token))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?.count, 2)
        XCTAssertEqual(frame?["type"] as? String, "push_token")
        XCTAssertEqual(frame?["token"] as? String, token)
    }

    // MARK: - Tests — Frozen wire: hello token encoding

    func test_send_helloWithToken_encodesTokenField() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        // Keep the stream alive for the duration of the test;
        // releasing it would terminate the client's continuation.
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)
        let token = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

        // When
        await sut.send(.hello(code: "c", token: token))

        // Then
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "hello")
        XCTAssertEqual(frame?["code"] as? String, "c")
        XCTAssertEqual(frame?["version"] as? Int, 1)
        XCTAssertEqual(frame?["token"] as? String, token)
    }

    func test_send_helloWithoutToken_omitsTokenKey() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        // Keep the stream alive for the duration of the test;
        // releasing it would terminate the client's continuation.
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        // When
        await sut.send(.hello(code: "c"))

        // Then — the frozen wire format omits the key, it never sends null.
        let frame = try? Self.decodeFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "hello")
        XCTAssertEqual(frame?["code"] as? String, "c")
        XCTAssertNil(frame?["token"], "Nil token must omit the key entirely")
    }

    // MARK: - Tests — Server -> Client framing

    func test_connect_helloOkJson_decodesHelloOkEvent() async throws {
        // Given
        let stream = sut.connect(host: "h", port: 1, code: "c")
        try XCTUnwrap(transport.lastTask).enqueue(#"{"type":"hello_ok","version":1}"#)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case let .helloOk(version) = event else {
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
         "contextUsage":{"tokens":10,"contextWindow":100,"percent":10.0}}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case let .state(info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertEqual(info.sessionId, "s1")
        XCTAssertEqual(info.cwd, "/tmp/project")
        XCTAssertEqual(info.model.id, "model-1")
        XCTAssertFalse(info.isStreaming)
        XCTAssertEqual(info.contextUsage?.tokens, 10)
        XCTAssertEqual(info.contextUsage?.contextWindow, 100)
        XCTAssertEqual(info.contextUsage?.percent, 10.0)
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
        guard case let .history(history) = event else {
            return XCTFail("Expected history, got \(String(describing: event))")
        }
        XCTAssertEqual(history.sessionId, "s1")
        XCTAssertEqual(history.cursor, "c1")
        XCTAssertEqual(history.messages.count, 1)
        XCTAssertNil(history.pending, "absent pending decodes to nil")
    }

    func test_connect_historyJsonWithPending_decodesPendingSteers()
        async throws
    {
        // Given — a snapshot carrying steers still queued in pi
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"history","sessionId":"s1","cursor":null,
         "messages":[],
         "pending":["be brief","then stop"]}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case let .history(history) = event else {
            return XCTFail("Expected history, got \(String(describing: event))")
        }
        XCTAssertEqual(history.pending, ["be brief", "then stop"])
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
        guard case let .streamingBuffer(sessionId, content) = event else {
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
        guard case let .authFailed(serverError) = event else {
            return XCTFail("Expected authFailed, got \(String(describing: event))")
        }
        XCTAssertEqual(serverError.code, "bad_code")
        // The client disconnects right after yielding; poll briefly.
        let deadline = Date.now.addingTimeInterval(1.0)
        while task.cancelCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
            if Date.now > deadline {
                break
            }
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
        guard case let .authFailed(serverError) = event else {
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
        guard case let .error(serverError) = event else {
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

    // MARK: - Tests — Reconnect hello token

    /// Internal re-hellos must present the registered device token, so the
    /// client's own reconnect loop can auto-authenticate after a pi restart
    /// (fresh pairing code, token still registered server-side).
    func test_reconnectHello_withTokenProvider_carriesToken() async throws {
        // Given — provider supplies the registered device token; the dead
        // peer (no pongs) forces the client's internal reconnect loop.
        let token = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        transport.autoPong = false
        sut = CodeServerClient(
            transport: transport,
            pingIntervalSeconds: 1.0,
            pongTimeoutSeconds: 1.0,
            tokenProvider: { token }
        )
        let stream = sut.connect(host: "h", port: 1, code: "c")
        // Keep the stream alive for the duration of the test;
        // releasing it would terminate the client's continuation.
        defer { _ = stream }

        // When — the pong deadline fires and the client reconnects.
        try await Task.sleep(for: .seconds(3.0))

        // Then — the re-hello on the fresh socket carries the token.
        XCTAssertGreaterThanOrEqual(transport.tasks.count, 2)
        let hello = try XCTUnwrap(
            try Self.helloFrame(in: XCTUnwrap(transport.tasks[1])),
            "Reconnect must re-send hello"
        )
        XCTAssertEqual(hello["code"] as? String, "c")
        XCTAssertEqual(hello["token"] as? String, token)
    }

    func test_reconnectHello_withoutTokenProvider_omitsTokenKey() async throws {
        // Given — default provider (no token); dead peer forces reconnect.
        transport.autoPong = false
        let stream = sut.connect(host: "h", port: 1, code: "c")
        // Keep the stream alive for the duration of the test;
        // releasing it would terminate the client's continuation.
        defer { _ = stream }

        // When — the pong deadline fires and the client reconnects.
        try await Task.sleep(for: .seconds(3.0))

        // Then — the re-hello omits the token key.
        XCTAssertGreaterThanOrEqual(transport.tasks.count, 2)
        let hello = try XCTUnwrap(
            try Self.helloFrame(in: XCTUnwrap(transport.tasks[1])),
            "Reconnect must re-send hello"
        )
        XCTAssertNil(hello["token"], "No token: the key must be omitted")
    }

    // MARK: - Helpers

    private static func helloFrame(in task: MockCodeWebSocketTask) -> [String: Any]? {
        task.sentFrames.compactMap {
            (try? decodeFrame($0))
        }.first(where: { $0["type"] as? String == "hello" })
    }

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

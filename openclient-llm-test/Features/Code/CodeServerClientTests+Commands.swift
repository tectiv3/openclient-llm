//
//  CodeServerClientTests+Commands.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeServerClientTests — Command frame encoding

extension CodeServerClientTests {
    func test_send_command_encodesCommandFrame() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        await sut.send(.command(command: "new"))

        let frame = try? Self.parseFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "command")
        XCTAssertEqual(frame?["command"] as? String, "new")
    }

    func test_send_commandWithArgs_spreadsArgsIntoFrame() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        await sut.send(.command(
            command: "set_model",
            args: [
                "provider": .string("anthropic"),
                "modelId": .string("claude-sonnet-4-20250514"),
            ]
        ))

        let frame = try? Self.parseFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?["type"] as? String, "command")
        XCTAssertEqual(frame?["command"] as? String, "set_model")
        XCTAssertEqual(frame?["provider"] as? String, "anthropic")
        XCTAssertEqual(frame?["modelId"] as? String, "claude-sonnet-4-20250514")
    }

    func test_send_commandWithEmptyArgs_encodesOnlyTypeAndCommand() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        defer { _ = stream }
        let task = try XCTUnwrap(transport.lastTask)

        await sut.send(.command(command: "compact"))

        let frame = try? Self.parseFrame(try XCTUnwrap(task.lastSentFrame))
        XCTAssertEqual(frame?.count, 2)
        XCTAssertEqual(frame?["type"] as? String, "command")
        XCTAssertEqual(frame?["command"] as? String, "compact")
    }

    // MARK: - State decode — models array

    func test_stateJsonWithModels_decodesModelsArray() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"state","sessionId":"s1","cwd":"/tmp",
         "model":{"provider":"pi","id":"m1"},"isStreaming":false,
         "contextUsage":{"tokens":1,"contextWindow":100,"percent":1.0},
         "models":[
           {"provider":"pi","id":"m1"},
           {"provider":"anthropic","id":"claude-sonnet-4-20250514"}
         ]}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .state(info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertEqual(info.models?.count, 2)
        XCTAssertEqual(info.models?.first?.provider, "pi")
        XCTAssertEqual(info.models?.last?.id, "claude-sonnet-4-20250514")
    }

    func test_stateJsonWithoutModels_decodesNilModels() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"state","sessionId":"s1","cwd":"/tmp",
         "model":{"provider":"pi","id":"m1"},"isStreaming":false,
         "contextUsage":{"tokens":1,"contextWindow":100,"percent":1.0}}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .state(info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertNil(info.models)
    }

    func test_stateJsonWithEmptyModels_decodesEmptyArray() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"state","sessionId":"s1","cwd":"/tmp",
         "model":{"provider":"pi","id":"m1"},"isStreaming":false,
         "contextUsage":{"tokens":1,"contextWindow":100,"percent":1.0},
         "models":[]}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .state(info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertEqual(info.models, [])
    }

    // MARK: - Error frame decode — command error codes

    func test_errorJson_commandFailed_decodesErrorEvent() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"{"type":"error","code":"command_failed","message":"boom"}"#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .error(err) = event else {
            return XCTFail("Expected error, got \(String(describing: event))")
        }
        XCTAssertEqual(err.code, "command_failed")
        XCTAssertEqual(err.message, "boom")
    }

    func test_errorJson_unknownCommand_decodesErrorEvent() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"{"type":"error","code":"unknown_command"}"#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .error(err) = event else {
            return XCTFail("Expected error, got \(String(describing: event))")
        }
        XCTAssertEqual(err.code, "unknown_command")
        XCTAssertNil(err.message)
    }

    func test_errorJson_modelNotFound_decodesErrorEvent() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"{"type":"error","code":"model_not_found"}"#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .error(err) = event else {
            return XCTFail("Expected error, got \(String(describing: event))")
        }
        XCTAssertEqual(err.code, "model_not_found")
    }

    func test_errorJson_notReady_decodesErrorEvent() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"{"type":"error","code":"not_ready","message":"Session loading"}"#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .error(err) = event else {
            return XCTFail("Expected error, got \(String(describing: event))")
        }
        XCTAssertEqual(err.code, "not_ready")
        XCTAssertEqual(err.message, "Session loading")
    }

    func test_errorJson_staleSession_decodesErrorEvent() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"{"type":"error","code":"stale_session","message":"Session replaced outside rc"}"#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .error(err) = event else {
            return XCTFail("Expected error, got \(String(describing: event))")
        }
        XCTAssertEqual(err.code, "stale_session")
    }

    func test_errorJson_modelNotSet_decodesErrorEvent() async throws {
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"{"type":"error","code":"model_not_set"}"#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        let event = try await nextEvent(from: stream)

        guard case let .error(err) = event else {
            return XCTFail("Expected error, got \(String(describing: event))")
        }
        XCTAssertEqual(err.code, "model_not_set")
    }
}

// MARK: - Helpers

private extension CodeServerClientTests {
    static func parseFrame(_ frame: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(frame.utf8))
        return object as? [String: Any] ?? [:]
    }
}

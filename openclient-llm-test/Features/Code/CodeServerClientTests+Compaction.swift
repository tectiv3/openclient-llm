//
//  CodeServerClientTests+Compaction.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeServerClientTests — Compaction `state` decoding

extension CodeServerClientTests {
    func test_stateJsonWithCompacting_decodesCompacting() async throws {
        // Given — mid-compaction state broadcast
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"state","sessionId":"s1","cwd":"/tmp/project",
         "model":{"provider":"pi","id":"model-1"},"isStreaming":true,
         "contextUsage":{"tokens":10,"contextWindow":100,"percent":10.0},
         "compacting":{"reason":"threshold","willRetry":true}}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case let .state(info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertEqual(info.compacting?.reason, "threshold")
        XCTAssertEqual(info.compacting?.willRetry, true)
    }

    func test_stateJsonCompactingWithoutWillRetry_decodesNil() async throws {
        // Given — `willRetry` is optional on the wire
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"state","sessionId":"s1","cwd":"/tmp/project",
         "model":{"provider":"pi","id":"model-1"},"isStreaming":true,
         "compacting":{"reason":"manual"}}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case let .state(info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertEqual(info.compacting?.reason, "manual")
        XCTAssertNil(info.compacting?.willRetry, "absent willRetry decodes to nil")
    }

    func test_stateJsonWithoutCompacting_decodesNilCompacting() async throws {
        // Given — pre-change server shape: no compacting key at all
        let stream = sut.connect(host: "h", port: 1, code: "c")
        let json = #"""
        {"type":"state","sessionId":"s1","cwd":"/tmp/project",
         "model":{"provider":"pi","id":"model-1"},"isStreaming":false}
        """#
        try XCTUnwrap(transport.lastTask).enqueue(json)

        // When
        let event = try await nextEvent(from: stream)

        // Then
        guard case let .state(info) = event else {
            return XCTFail("Expected state, got \(String(describing: event))")
        }
        XCTAssertNil(info.compacting)
    }
}

//
//  LMStudioChatModelsTests.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 16/08/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import XCTest
@testable import openclient_llm

@MainActor
final class LMStudioChatModelsTests: XCTestCase {
    // MARK: - Tests

    func test_pluginIntegration_stringEncodingAndDecoding_roundTrips() throws {
        // Given
        let integrations: [MCPIntegration] = [.plugin(id: "mcp/transmission")]

        // When
        let data = try JSONEncoder().encode(integrations)
        let decoded = try JSONDecoder().decode([MCPIntegration].self, from: data)

        // Then
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"mcp/transmission\"]")
        XCTAssertEqual(decoded, integrations)
    }

    func test_request_withMCPIntegration_encodesNativeLMStudioFields() throws {
        // Given
        let request = LMStudioChatRequest(
            model: "qwen3",
            input: "Find an active torrent",
            systemPrompt: "Use the available tools.",
            integrations: [.plugin(id: "mcp/transmission")],
            temperature: 0,
            maxOutputTokens: 512,
            topP: nil,
            reasoning: "off",
            contextLength: 8_000,
            previousResponseId: "resp_previous",
            store: true,
            stream: nil
        )

        // When
        let data = try JSONEncoder().encode(request)
        let json = String(decoding: data, as: UTF8.self)

        // Then
        XCTAssertTrue(json.contains("\"input\":\"Find an active torrent\""))
        XCTAssertTrue(json.contains("\"integrations\":[\"mcp/transmission\"]"))
        XCTAssertTrue(json.contains("\"previous_response_id\":\"resp_previous\""))
        XCTAssertTrue(json.contains("\"system_prompt\":\"Use the available tools.\""))
    }

    func test_response_withToolCallAndMessage_decodesMessageOutput() throws {
        // Given
        let data = Data("""
        {
          "output": [
            { "type": "tool_call", "tool": "transmission-get-torrents", "output": "[]" },
            { "type": "message", "content": "There are no active torrents." }
          ],
          "stats": { "input_tokens": 10, "total_output_tokens": 8, "tokens_per_second": 20 },
          "response_id": "resp_current"
        }
        """.utf8)

        // When
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(LMStudioChatResponse.self, from: data)

        // Then
        XCTAssertEqual(response.output[1].content, "There are no active torrents.")
        XCTAssertEqual(response.stats?.inputTokens, 10)
        XCTAssertEqual(response.responseId, "resp_current")
    }
}

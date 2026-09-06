//
//  CodeMessageMapperTests.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

@MainActor
final class CodeMessageMapperTests: XCTestCase {
    // MARK: - Properties

    private var sut: CodeViewModel!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        sut = CodeViewModel(
            client: MockCodeServerClient(),
            settingsManager: MockSettingsManager(),
            backgroundUseCase: MockCodeBackgroundUseCase(),
            notificationManager: MockLocalNotificationManager()
        )
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Tests

    func test_mapHistoryToItems_userMessage_returnsUserItem() throws {
        // Given
        let messages = try Self.decodeMessages(#"[{"role":"user","text":"hi"}]"#)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 1)
        guard case let .user(_, text, failed) = items[0] else {
            return XCTFail("Expected user item, got \(items[0])")
        }
        XCTAssertEqual(text, "hi")
        XCTAssertFalse(failed, "History user items never fail")
    }

    func test_mapHistoryToItems_assistantText_returnsAssistantItem() throws {
        // Given
        let json = #"""
        [{"role":"assistant","content":[{"type":"text","text":"hello"}]}]
        """#
        let messages = try Self.decodeMessages(json)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 1)
        guard case let .assistant(_, content, isStreaming) = items[0] else {
            return XCTFail("Expected assistant item, got \(items[0])")
        }
        XCTAssertEqual(content, [.text("hello")])
        XCTAssertFalse(isStreaming)
    }

    func test_mapHistoryToItems_assistantThinking_returnsThinkingBlock() throws {
        // Given
        let json = #"""
        [{"role":"assistant","content":[{"type":"thinking","text":"hmm"}]}]
        """#
        let messages = try Self.decodeMessages(json)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        guard case let .assistant(_, content, _) = items[0] else {
            return XCTFail("Expected assistant item, got \(items[0])")
        }
        XCTAssertEqual(content, [.thinking("hmm")])
    }

    func test_mapHistoryToItems_assistantTextThenToolUse_splitsItems() throws {
        // Given
        let json = #"""
        [{"role":"assistant","content":[
            {"type":"text","text":"let me check"},
            {"type":"toolUse","toolCallId":"tc1","toolName":"bash","args":{"cmd":"ls"},"output":null}
        ]}]
        """#
        let messages = try Self.decodeMessages(json)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 2)
        guard case let .assistant(_, content, _) = items[0] else {
            return XCTFail("Expected assistant item first, got \(items[0])")
        }
        XCTAssertEqual(content, [.text("let me check")])
        guard case let .toolStep(_, toolName, toolCallId, _, output,
                                 isComplete) = items[1]
        else {
            return XCTFail("Expected toolStep item second, got \(items[1])")
        }
        XCTAssertEqual(toolName, "bash")
        XCTAssertEqual(toolCallId, "tc1")
        XCTAssertNil(output)
        XCTAssertTrue(isComplete, "History toolUse is final, so step is complete")
    }

    func test_mapHistoryToItems_toolResultAfterToolUse_completesMatchingStep() throws {
        // Given
        let json = #"""
        [
            {"role":"assistant","content":[
                {"type":"toolUse","toolCallId":"tc1","toolName":"bash","args":{},"output":null}
            ]},
            {"role":"toolResult","toolName":"bash","toolCallId":"tc1","output":"ok","isError":false}
        ]
        """#
        let messages = try Self.decodeMessages(json)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 1, "toolResult must merge into existing step")
        guard case let .toolStep(_, _, _, _, output, isComplete) = items[0]
        else {
            return XCTFail("Expected toolStep item, got \(items[0])")
        }
        XCTAssertEqual(output, "ok")
        XCTAssertTrue(isComplete)
    }

    func test_mapHistoryToItems_orphanToolResult_appendsNewToolStep() throws {
        // Given
        let json = #"""
        [{"role":"toolResult","toolName":"bash","toolCallId":"tc9","output":"x","isError":true}]
        """#
        let messages = try Self.decodeMessages(json)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 1)
        guard case let .toolStep(_, _, toolCallId, _, _, isComplete) = items[0]
        else {
            return XCTFail("Expected toolStep item, got \(items[0])")
        }
        XCTAssertEqual(toolCallId, "tc9")
        XCTAssertTrue(isComplete)
    }

    func test_mapHistoryToItems_compaction_returnsCompactionItem() throws {
        // Given
        let messages = try Self.decodeMessages(
            #"[{"role":"compaction","summary":"condensed"}]"#
        )

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 1)
        guard case let .compaction(_, summary) = items[0] else {
            return XCTFail("Expected compaction item, got \(items[0])")
        }
        XCTAssertEqual(summary, "condensed")
    }

    func test_mapHistoryToItems_unknownRole_isDroppedNoCrash() throws {
        // Given
        let messages = try Self.decodeMessages(#"[{"role":"system","text":"x"}]"#)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 0)
    }

    func test_mapHistoryToItems_unknownContentBlock_isDroppedNoCrash() throws {
        // Given
        let json = #"""
        [{"role":"assistant","content":[{"type":"mystery","text":"?","other":1}]}]
        """#
        let messages = try Self.decodeMessages(json)

        // When
        let items = sut.mapHistoryToItems(messages)

        // Then
        XCTAssertEqual(items.count, 0)
    }

    func test_mapHistoryToItems_malformedJSON_throwsInsteadOfCrashing() {
        // Given
        let malformed = #"[{"role":"user"}]"#

        // When / Then
        XCTAssertThrowsError(
            try Self.decodeMessages(malformed),
            "Missing required fields must fail decoding, not crash"
        )
    }

    // MARK: - Helpers

    private static func decodeMessages(_ json: String) throws -> [CodeHistoryMessage] {
        try JSONDecoder().decode([CodeHistoryMessage].self, from: Data(json.utf8))
    }
}

//
//  CodeViewModelTests+BufferMerge.swift
//  openclient-llm
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Streaming buffer merge

extension CodeViewModelTests {
    func test_streamingBuffer_mixedBlocks_mergesByToolCallId() async throws {
        // Given — committed tail already carries text and a completed step
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [
                .user(text: "hi"),
                .assistant(content: [
                    .text("committed"),
                    toolUseBlock("tc1", "read", output: "done"),
                ]),
            ],
            cursor: nil,
            pending: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 3
        }

        // When — mixed buffer: text + a genuinely new carrier + tc1's
        // carrier (its id already in items)
        mockClient.emit(.streamingBuffer(sessionId: "s1", content: [
            .text("buffer text"),
            toolUseBlock("tc2", "bash", output: nil),
            toolUseBlock("tc1", "read", output: "partial"),
        ]))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 5
        }

        // Then — no duplication: exactly one step per id, tc1 updated in
        // place as live, the text is its own streaming bubble
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(
            items.filter {
                if case let .toolStep(_, _, id, _, _, _) = $0 {
                    return id == "tc1"
                }
                return false
            }.count, 1
        )
        guard case let .toolStep(_, _, id1, _, out1, done1) = items[2] else {
            return XCTFail("Expected tc1 step, got \(items[2])")
        }
        XCTAssertEqual(id1, "tc1")
        XCTAssertEqual(out1, "partial")
        XCTAssertFalse(done1)
        guard case let .assistant(_, content, streaming) = items[3] else {
            return XCTFail("Expected assistant item, got \(items[3])")
        }
        XCTAssertTrue(streaming)
        XCTAssertEqual(content, [.text("buffer text")])
        guard case let .toolStep(_, name2, id2, _, _, done2) = items[4] else {
            return XCTFail("Expected tc2 step, got \(items[4])")
        }
        XCTAssertEqual(name2, "bash")
        XCTAssertEqual(id2, "tc2")
        XCTAssertFalse(done2)
    }

    func test_streamingBuffer_carriersOnly_updatesExistingStepsInPlace() async throws {
        // Given — history already rebuilt the committed steps
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.assistant(content: [
                toolUseBlock("tc1", "read", output: "done"),
                toolUseBlock("tc2", "bash", output: "done"),
            ])],
            cursor: nil,
            pending: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 2
        }

        // When — carriers-only buffer (the pruned committed-tail shape)
        mockClient.emit(.streamingBuffer(sessionId: "s1", content: [
            toolUseBlock("tc1", "read", output: "live output"),
            toolUseBlock("tc2", "bash", output: nil),
        ]))
        try await Task.sleep(for: .milliseconds(100))

        // Then — same two items, both flipped live, tc1 output replaced;
        // no assistant bubble was invented
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            items.filter {
                if case .assistant = $0 {
                    true
                } else {
                    false
                }
            }
            .count, 0
        )
        guard case let .toolStep(_, _, id1, _, out1, done1) = items[0] else {
            return XCTFail("Expected tc1 step, got \(items[0])")
        }
        XCTAssertEqual(id1, "tc1")
        XCTAssertEqual(out1, "live output")
        XCTAssertFalse(done1)
        guard case let .toolStep(_, _, id2, _, _, done2) = items[1] else {
            return XCTFail("Expected tc2 step, got \(items[1])")
        }
        XCTAssertEqual(id2, "tc2")
        XCTAssertFalse(done2)
    }

    func test_streamingBuffer_textOnly_appendsOneStreamingAssistantItem() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil,
            pending: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When — uncommitted tail: thinking + text of the live message
        mockClient.emit(.streamingBuffer(sessionId: "s1", content: [
            .thinking("thinking..."),
            .text("partial text"),
        ]))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 2
        }

        // Then — ONE bubble holding both blocks, streaming
        let items = try XCTUnwrap(currentSession()?.items)
        guard case let .assistant(_, content, streaming) = items[1] else {
            return XCTFail("Expected assistant item, got \(items[1])")
        }
        XCTAssertTrue(streaming)
        XCTAssertEqual(
            content, [.thinking("thinking..."), .text("partial text")]
        )
    }

    func test_streamingBuffer_emptyOrRepeatedFrames_areHarmless() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)

        // When — empty buffer, then a repeated carriers-only pair
        mockClient.emit(.streamingBuffer(sessionId: "s1", content: []))
        mockClient.emit(.streamingBuffer(
            sessionId: "s1",
            content: [toolUseBlock("tc1", "read", output: "live output")]
        ))
        mockClient.emit(.streamingBuffer(
            sessionId: "s1",
            content: [toolUseBlock("tc1", "read", output: "live output")]
        ))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // Then — exactly one step, from the first real frame
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 1)
        guard case let .toolStep(_, _, id, _, out, done) = items[0] else {
            return XCTFail("Expected tc1 step, got \(items[0])")
        }
        XCTAssertEqual(id, "tc1")
        XCTAssertEqual(out, "live output")
        XCTAssertFalse(done)
    }

    /// Fixture content block for scripted history/buffer frames; args stay
    /// empty because the merge never reads them.
    func toolUseBlock(
        _ toolCallId: String,
        _ toolName: String,
        output: String?
    ) -> CodeContentBlock {
        .toolUse(
            toolCallId: toolCallId,
            toolName: toolName,
            args: [:],
            output: output
        )
    }
}

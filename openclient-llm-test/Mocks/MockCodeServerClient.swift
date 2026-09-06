//
//  MockCodeServerClient.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation
@testable import openclient_llm

// Safety: Only used within serialized @MainActor test methods.
final class MockCodeServerClient: CodeServerClientProtocol, @unchecked Sendable {
    // MARK: - Properties

    private(set) var eventContinuation: AsyncStream<CodeEvent>.Continuation?
    private(set) var connectCalls: [(host: String, port: Int, code: String)] = []
    private(set) var disconnectCount = 0
    private(set) var sentMessages: [CodeClientMessage] = []

    /// Failure injection for `send`: when set to `false`, `send` reports
    /// failure to the caller (mirroring a dead socket).
    var sendResult: Bool = true

    // MARK: - CodeServerClientProtocol

    func connect(host: String, port: Int, code: String) -> AsyncStream<CodeEvent> {
        connectCalls.append((host, port, code))
        let (stream, continuation) = AsyncStream.makeStream(of: CodeEvent.self)
        eventContinuation = continuation
        return stream
    }

    @discardableResult
    func send(_ message: CodeClientMessage) async -> Bool {
        sentMessages.append(message)
        return sendResult
    }

    func disconnect() {
        disconnectCount += 1
    }

    // MARK: - Test Helpers

    /// Yields an event into the stream the view model is iterating.
    func emit(_ event: CodeEvent) {
        eventContinuation?.yield(event)
    }

    func finishStream() {
        eventContinuation?.finish()
    }

    func sentMessageCount(where matches: (CodeClientMessage) -> Bool) -> Int {
        sentMessages.filter(matches).count
    }
}

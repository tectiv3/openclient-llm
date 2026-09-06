//
//  MockCodeWebSocketTransport.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation
import Synchronization
@testable import openclient_llm

// MARK: - Mock Incoming

/// A canned server frame or failure to replay into the client's receive loop.
enum MockWebSocketIncoming: Sendable {
    case message(URLSessionWebSocketTask.Message)
    case failure(URLError)
}

// MARK: - Mock Task

// Safety: Mutable state is guarded by a Mutex because the client's receive
// and ping loops invoke this mock from background tasks while tests read
// the recorded state on the MainActor.
final class MockCodeWebSocketTask: CodeWebSocketTask, @unchecked Sendable {
    // MARK: - Properties

    private struct LockedState {
        var sentFrames: [String] = []
        var resumed = false
        var cancelCount = 0
        var cancelCloseCode: URLSessionWebSocketTask.CloseCode?
    }

    let url: URL
    private let state = Mutex(LockedState())
    private let queue = MockWebSocketIncomingQueue()

    /// When true, a "ping" frame triggers an automatic "pong" reply.
    /// Disabling it simulates a dead peer for the pong-timeout path.
    /// Must be set before connecting; the client reads it from background
    /// tasks afterwards.
    var autoPong = true

    // MARK: - Init

    init(url: URL) {
        self.url = url
    }

    // MARK: - CodeWebSocketTask

    func resume() {
        state.withLock { $0.resumed = true }
    }

    func cancel() {
        state.withLock { $0.cancelCount += 1 }
        queue.close()
    }

    func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        state.withLock {
            $0.cancelCount += 1
            $0.cancelCloseCode = code
        }
        queue.close()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        state.withLock { $0.sentFrames.append(text) }
        if autoPong, Self.isPingFrame(text) {
            queue.put(.message(.string(Self.pongFrame)))
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        // Receive is called serially by the client's receive loop.
        guard let item = await queue.take() else {
            throw URLError(.networkConnectionLost)
        }
        switch item {
        case .message(let message):
            return message
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Recorded State (read accessors)

    var sentFrames: [String] { state.withLock { $0.sentFrames } }
    var resumed: Bool { state.withLock { $0.resumed } }
    var cancelCount: Int { state.withLock { $0.cancelCount } }
    var cancelCloseCode: URLSessionWebSocketTask.CloseCode? {
        state.withLock { $0.cancelCloseCode }
    }

    var lastSentFrame: String? { state.withLock { $0.sentFrames.last } }

    var sentPingCount: Int {
        state.withLock { $0.sentFrames.filter(Self.isPingFrame).count }
    }

    func sentFrameCount(where matches: (String) -> Bool) -> Int {
        state.withLock { $0.sentFrames.filter(matches).count }
    }

    // MARK: - Test Helpers

    func enqueue(_ message: String) {
        queue.put(.message(.string(message)))
    }

    func enqueueFailure(_ error: URLError) {
        queue.put(.failure(error))
    }

    // MARK: - Frame Helpers

    static let pongFrame = #"{"type":"pong"}"#

    static let pingFrame = #"{"type":"ping"}"#

    static func isPingFrame(_ frame: String) -> Bool {
        guard let data = frame.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any]
        else { return false }
        return object["type"] as? String == "ping"
    }
}

// MARK: - Incoming Queue

// Safety: Mutable state is guarded by a Mutex; waiters are
// CheckedContinuations, which are Sendable and safe to resume after the
// lock is released.
final class MockWebSocketIncomingQueue: @unchecked Sendable {
    // MARK: - Properties

    private struct QueuedState: Sendable {
        var pending: [MockWebSocketIncoming] = []
        var waiters:
            [CheckedContinuation<MockWebSocketIncoming?, Never>] = []
        var closed = false
    }

    private let state = Mutex(QueuedState())

    // MARK: - Public

    func put(_ item: MockWebSocketIncoming) {
        let waiter = state.withLock {
            locked -> CheckedContinuation<MockWebSocketIncoming?, Never>? in
            guard !locked.closed else { return nil }
            if let waiter = locked.waiters.first {
                locked.waiters.removeFirst()
                return waiter
            }
            locked.pending.append(item)
            return nil
        }
        waiter?.resume(returning: item)
    }

    func take() async -> MockWebSocketIncoming? {
        if let item = state.withLock { locked -> MockWebSocketIncoming? in
            guard !locked.closed else { return nil }
            guard !locked.pending.isEmpty else { return nil }
            return locked.pending.removeFirst()
        } {
            return item
        }

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<MockWebSocketIncoming?, Never>) in
            let shouldResumeNow = state.withLock { locked -> Bool in
                if locked.closed { return true }
                locked.waiters.append(continuation)
                return false
            }
            if shouldResumeNow {
                continuation.resume(returning: nil)
            }
        }
    }

    func close() {
        let waiters = state.withLock {
            locked -> [CheckedContinuation<MockWebSocketIncoming?, Never>] in
            guard !locked.closed else { return [] }
            locked.closed = true
            locked.pending.removeAll()
            let waiters = locked.waiters
            locked.waiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }
}

// Safety: `tasks` is guarded by a Mutex because reconnects happen on
// background tasks while tests read from the MainActor.
final class MockCodeWebSocketTransport: CodeWebSocketTransport, @unchecked Sendable {
    // MARK: - Properties

    private let state = Mutex<[MockCodeWebSocketTask]>([])

    /// Applied to every task created by this transport. Set before
    /// connecting; read from background tasks afterwards.
    var autoPong = true

    // MARK: - CodeWebSocketTransport

    func makeWebSocketTask(with url: URL) -> CodeWebSocketTask {
        let task = MockCodeWebSocketTask(url: url)
        task.autoPong = autoPong
        state.withLock { $0.append(task) }
        return task
    }

    // MARK: - Test Helpers

    var tasks: [MockCodeWebSocketTask] { state.withLock { $0 } }

    var lastTask: MockCodeWebSocketTask? {
        state.withLock { $0.last }
    }

    var connectURLs: [URL] {
        state.withLock { $0.map(\.url) }
    }
}

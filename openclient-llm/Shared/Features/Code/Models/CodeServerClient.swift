//
//  CodeServerClient.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation
import Synchronization

// MARK: - Protocol

protocol CodeServerClientProtocol: Sendable {
    func connect(host: String, port: Int, code: String) -> AsyncStream<CodeEvent>
    func send(_ message: CodeClientMessage) async
    func disconnect()
}

// MARK: - Transport Seam

/// Minimal abstraction over `URLSessionWebSocketTask` so tests can inject a
/// mock transport and replay canned server frames. `URLSession` websocket
/// tasks cannot be faked via `URLProtocol`, hence the seam.
protocol CodeWebSocketTask: Sendable {
    func resume()
    func cancel()
    func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

/// Default `CodeWebSocketTask` backed by a real `URLSessionWebSocketTask`.
struct URLSessionCodeWebSocketTask: CodeWebSocketTask {
    let task: URLSessionWebSocketTask

    func resume() { task.resume() }
    func cancel() { task.cancel() }

    func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: code, reason: reason)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }
}

protocol CodeWebSocketTransport: Sendable {
    func makeWebSocketTask(with url: URL) -> CodeWebSocketTask
}

/// Default `CodeWebSocketTransport` backed by a real `URLSession`.
struct URLSessionCodeWebSocketTransport: CodeWebSocketTransport {
    let session: URLSession

    func makeWebSocketTask(with url: URL) -> CodeWebSocketTask {
        URLSessionCodeWebSocketTask(
            task: session.webSocketTask(with: url)
        )
    }
}

// MARK: - Client Messages

enum CodeClientMessage: Sendable {
    case hello(code: String, version: Int = 1)
    case prompt(text: String)
    case steer(text: String)
    case abort
    case answer(id: String, value: String, wasCustom: Bool, index: Int?)
    case answerQuestionnaire(id: String, answers: [CodeQuestionnaireAnswer])
    case getState
    case getHistory(cursor: String?)
    case ping
}

// MARK: - Implementation

// Safety: All mutable state guarded by Mutex. URLSession is thread-safe.
final class CodeServerClient: CodeServerClientProtocol, @unchecked Sendable {
    // MARK: - Properties

    private struct LockedState: Sendable {
        var webSocketTask: CodeWebSocketTask?
        var receiveTask: Task<Void, Never>?
        var pingTask: Task<Void, Never>?
        var coalescingTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var continuation: AsyncStream<CodeEvent>.Continuation?
        var lastPongTime: Date = .now
        var reconnectAttempts = 0
        var attemptGeneration: Int = 0
        // True once the current attempt completed its handshake, so the
        // 10s connect timeout cannot kill a healthy, connected session.
        var helloAcked = false
        // Deduplicates concurrent connection-lost reports (receive-loop
        // catch + pong deadline) so one loss schedules one reconnect.
        var connectionLostInFlight = false
        var currentHost = ""
        var currentPort = 0
        var currentCode = ""
        var isDisconnecting = false
        var pendingCoalescedEvents: [CodeEvent] = []
    }

    private let transport: CodeWebSocketTransport
    private let pingIntervalSeconds: TimeInterval
    private let pongTimeoutSeconds: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let state = Mutex(LockedState())

    private static let maxReconnectAttempts = 10
    private static let connectionTimeoutSeconds: TimeInterval = 10
    private static let defaultPingIntervalSeconds: TimeInterval = 30
    private static let defaultPongTimeoutSeconds: TimeInterval = 10
    private static let coalesceIntervalMs: UInt64 = 75

    // MARK: - Init

    init(
        transport: CodeWebSocketTransport = URLSessionCodeWebSocketTransport(
            session: .shared
        ),
        pingIntervalSeconds: TimeInterval =
            CodeServerClient.defaultPingIntervalSeconds,
        pongTimeoutSeconds: TimeInterval =
            CodeServerClient.defaultPongTimeoutSeconds
    ) {
        self.transport = transport
        self.pingIntervalSeconds = pingIntervalSeconds
        self.pongTimeoutSeconds = pongTimeoutSeconds
    }

    // MARK: - Public

    func connect(
        host: String,
        port: Int,
        code: String
    ) -> AsyncStream<CodeEvent> {
        disconnect()

        state.withLock {
            $0.currentHost = host
            $0.currentPort = port
            $0.currentCode = code
            $0.reconnectAttempts = 0
            $0.attemptGeneration += 1
            $0.isDisconnecting = false
        }

        let stream = AsyncStream<CodeEvent> { continuation in
            self.state.withLock { $0.continuation = continuation }

            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in self.disconnect() }
            }

            self.startConnection()
        }

        return stream
    }

    func send(_ message: CodeClientMessage) async {
        guard let data = encodeMessage(message) else { return }
        let string = String(data: data, encoding: .utf8) ?? ""
        let task = state.withLock { $0.webSocketTask }

        guard let task else { return }
        do {
            try await task.send(.string(string))
        } catch {
            LogManager.error("CodeServerClient send failed: \(error)")
        }
    }

    func disconnect() {
        let snapshot = state.withLock { locked -> LockedState in
            locked.isDisconnecting = true
            locked.attemptGeneration += 1
            locked.timeoutTask?.cancel()
            locked.timeoutTask = nil
            let copy = locked
            locked.webSocketTask = nil
            locked.receiveTask = nil
            locked.pingTask = nil
            locked.coalescingTask = nil
            locked.continuation = nil
            locked.pendingCoalescedEvents.removeAll()
            return copy
        }

        snapshot.receiveTask?.cancel()
        snapshot.pingTask?.cancel()
        snapshot.coalescingTask?.cancel()
        snapshot.webSocketTask?.cancel(with: .normalClosure, reason: nil)
        snapshot.continuation?.yield(.disconnected)
        snapshot.continuation?.finish()
    }

    // MARK: - Private

    private func startConnection() {
        let (host, port, disconnecting, attempts) = state.withLock { locked -> (String, Int, Bool, Int) in
            locked.helloAcked = false
            locked.connectionLostInFlight = false
            locked.attemptGeneration += 1
            return (locked.currentHost, locked.currentPort, locked.isDisconnecting, locked.reconnectAttempts)
        }
        guard !disconnecting else { return }

        let urlString = "ws://\(host):\(port)"
        guard let url = URL(string: urlString) else {
            yield(.connectionFailed("Invalid URL: \(urlString)"))
            return
        }

        let task = transport.makeWebSocketTask(with: url)
        state.withLock { $0.webSocketTask = task }

        task.resume()
        startReceiveLoop(task)
        startPingLoop()
        if attempts == 0 {
            scheduleConnectionTimeout()
        }
    }

    private func startReceiveLoop(_ task: CodeWebSocketTask) {
        state.withLock { $0.receiveTask?.cancel() }

        let recvTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handleReceivedMessage(message)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.handleConnectionLost(error)
                    return
                }
            }
        }

        state.withLock { $0.receiveTask = recvTask }
    }

    private func handleReceivedMessage(
        _ message: URLSessionWebSocketTask.Message
    ) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return
        }

        do {
            let event = try decoder.decode(CodeEvent.self, from: data)
            processDecodedEvent(event)
        } catch {
            LogManager.warning(
                "CodeServerClient decode failed: \(error)"
            )
        }
    }

    private func processDecodedEvent(_ event: CodeEvent) {
        switch event {
        case .helloOk:
            state.withLock {
                $0.helloAcked = true
                $0.reconnectAttempts = 0
                $0.timeoutTask?.cancel()
                $0.timeoutTask = nil
            }
            yield(event)

        case .error(let serverError):
            if serverError.code == "bad_code"
                || serverError.code == "rate_limited" {
                yield(.authFailed(serverError))
                disconnect()
            } else {
                yield(event)
            }

        case .pong:
            state.withLock { $0.lastPongTime = .now }

        case .event(let streamEvent)
            where streamEvent.name == "message_update":
            coalesceEvent(event)

        default:
            flushCoalescedEvents()
            yield(event)
        }
    }

    private func coalesceEvent(_ event: CodeEvent) {
        let needsTimer = state.withLock { locked -> Bool in
            locked.pendingCoalescedEvents.append(event)
            let needs = locked.coalescingTask == nil
            return needs
        }

        guard needsTimer else { return }

        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.coalesceIntervalMs))
            self?.flushCoalescedEvents()
        }

        state.withLock { $0.coalescingTask = task }
    }

    private func flushCoalescedEvents() {
        let events = state.withLock { locked -> [CodeEvent] in
            let pending = locked.pendingCoalescedEvents
            locked.pendingCoalescedEvents.removeAll()
            locked.coalescingTask = nil
            return pending
        }

        for event in events {
            yield(event)
        }
    }

    private func handleConnectionLost(_ error: Error) {
        // Nested type keeps the withLock return tuple within the
        // two-member lint limit.
        struct LostConnection {
            let attempt: Int
            let code: String
            let shouldStop: Bool
            let staleSocket: CodeWebSocketTask?
        }

        let lost = state.withLock { locked -> LostConnection in
            guard !locked.isDisconnecting,
                  !locked.connectionLostInFlight else {
                return LostConnection(
                    attempt: 0, code: "", shouldStop: true, staleSocket: nil
                )
            }
            locked.connectionLostInFlight = true
            locked.pingTask?.cancel()
            locked.pingTask = nil
            locked.coalescingTask?.cancel()
            locked.coalescingTask = nil
            locked.pendingCoalescedEvents.removeAll()
            // Cancel the stale socket and receive loop: the old receive Task
            // would block in receive() forever otherwise. The continuation
            // is kept because the scheduled reconnect reuses it.
            locked.receiveTask?.cancel()
            locked.receiveTask = nil
            let staleSocket = locked.webSocketTask
            locked.webSocketTask = nil
            locked.reconnectAttempts += 1
            return LostConnection(
                attempt: locked.reconnectAttempts,
                code: locked.currentCode,
                shouldStop: false,
                staleSocket: staleSocket
            )
        }

        guard !lost.shouldStop else { return }
        lost.staleSocket?.cancel()

        yield(.connectionLost)

        if lost.attempt > Self.maxReconnectAttempts {
            yield(.connectionFailed(
                "Connection lost after \(Self.maxReconnectAttempts) attempts"
            ))
            return
        }

        LogManager.warning(
            "CodeServerClient connection lost (attempt \(lost.attempt)): \(error)"
        )

        let capturedGen = state.withLock { $0.attemptGeneration }
        let delay = min(30.0, pow(2.0, Double(lost.attempt - 1)))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }

            let (currentGen, disconnecting) = self.state.withLock {
                ($0.attemptGeneration, $0.isDisconnecting)
            }
            guard currentGen == capturedGen, !disconnecting else { return }

            self.startConnection()

            // startConnection() increments attemptGeneration by 1;
            // any other bump means a new connect() or disconnect() intervened.
            let stillCurrent = self.state.withLock { $0.attemptGeneration }
            guard stillCurrent == capturedGen + 1 else { return }
            await self.send(.hello(code: lost.code))
        }
    }

    private func startPingLoop() {
        state.withLock {
            $0.pingTask?.cancel()
            $0.lastPongTime = .now
        }

        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Cadence sleep + pong wait sum to pingIntervalSeconds, so
                // pings fire on the configured cadence while the pong
                // deadline stays pongTimeoutSeconds.
                try? await Task.sleep(
                    for: .seconds(
                        self.pingIntervalSeconds
                            - self.pongTimeoutSeconds
                    )
                )
                guard !Task.isCancelled else { return }

                // Pong is expected within pongTimeoutSeconds of this ping;
                // a missed deadline means the transport is dead. Only a
                // pong arriving after this ping was sent counts, so a
                // stale pong from the previous cycle cannot mask a dead
                // peer (and the check cannot false-positive on a healthy
                // one whose RTT is shorter than the sleep overshoot).
                let pingSentAt = Date.now
                await self.send(.ping)
                try? await Task.sleep(
                    for: .seconds(self.pongTimeoutSeconds)
                )
                guard !Task.isCancelled else { return }

                let pongAfterPing = self.state.withLock {
                    $0.lastPongTime >= pingSentAt
                }
                if !pongAfterPing {
                    self.handleConnectionLost(URLError(.timedOut))
                    return
                }
            }
        }

        state.withLock { $0.pingTask = task }
    }

    private func scheduleConnectionTimeout() {
        let task = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.connectionTimeoutSeconds)
            )
            guard let self else { return }

            let (acked, disconnecting) = self.state.withLock {
                ($0.helloAcked, $0.isDisconnecting)
            }

            if !acked, !disconnecting {
                self.yield(.connectionFailed("Connection timed out"))
                self.disconnect()
            }
        }
        state.withLock { $0.timeoutTask = task }
    }

}

// MARK: - Encoding

private extension CodeServerClient {
    func yield(_ event: CodeEvent) {
        let cont = state.withLock { $0.continuation }
        cont?.yield(event)
    }

    func encodeMessage(_ message: CodeClientMessage) -> Data? {
        var dict: [String: AnyCodableValue] = [:]

        switch message {
        case .hello(let code, let version):
            dict["type"] = .string("hello")
            dict["code"] = .string(code)
            dict["version"] = .int(version)

        case .prompt(let text):
            dict["type"] = .string("prompt")
            dict["text"] = .string(text)

        case .steer(let text):
            dict["type"] = .string("steer")
            dict["text"] = .string(text)

        case .abort:
            dict["type"] = .string("abort")

        case .answer(let id, let value, let wasCustom, let index):
            dict["type"] = .string("answer")
            dict["id"] = .string(id)
            dict["value"] = .string(value)
            dict["wasCustom"] = .bool(wasCustom)
            if let index {
                dict["index"] = .int(index)
            }

        case .answerQuestionnaire(let id, let answers):
            dict["type"] = .string("answer_questionnaire")
            dict["id"] = .string(id)
            if let data = try? encoder.encode(answers),
               let arr = try? decoder.decode(
                [AnyCodableValue].self, from: data
               ) {
                dict["answers"] = .array(arr)
            }

        case .getState:
            dict["type"] = .string("get_state")

        case .getHistory(let cursor):
            dict["type"] = .string("get_history")
            if let cursor {
                dict["cursor"] = .string(cursor)
            }

        case .ping:
            dict["type"] = .string("ping")
        }

        return try? encoder.encode(dict)
    }
}

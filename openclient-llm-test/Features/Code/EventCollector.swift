//
//  EventCollector.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import XCTest
@testable import openclient_llm

/// Collects `CodeEvent`s from a client stream so one collector can serve a
/// sequence of polling assertions. Main-actor isolated because the app target
/// compiles the Code model types with default main-actor isolation.
@MainActor
final class EventCollector {
    // `collected` is only touched under `lock`; the consumer task appends,
    // the test side snapshots.

    private let lock = NSLock()
    private var collected: [CodeEvent] = []
    private var consumer: Task<Void, Never>?

    init(stream: AsyncStream<CodeEvent>) {
        consumer = Task { [weak self] in
            for await event in stream {
                self?.record(event)
            }
        }
    }

    /// Waits up to `timeout` for an event matching `predicate`, polling the
    /// already-collected events every 100 ms.
    func wait(
        matching predicate: (CodeEvent) -> Bool,
        timeout: TimeInterval
    ) async -> CodeEvent? {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let snapshot = lock.withLock { collected }
            if let match = snapshot.first(where: predicate) {
                return match
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// Display names of every collected event, for failure messages.
    var names: [String] {
        lock.withLock { collected.map(Self.displayName) }
    }

    /// Names plus truncated payload JSON for stream events, for failure
    /// diagnostics (shows tool calls / error text inside looping turns).
    var summaries: [String] {
        lock.withLock {
            collected.map { event in
                guard case .event(let stream) = event else {
                    return Self.displayName(event)
                }
                let data = try? JSONEncoder().encode(stream.payload)
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let trimmed = text.count > 180 ? String(text.prefix(180)) + "…" : text
                return "event:\(stream.name) \(trimmed)"
            }
        }
    }

    /// Stops consuming the stream (the stream itself is finished by the
    /// client's disconnect).
    func cancel() {
        consumer?.cancel()
    }

    // MARK: - Private

    private func record(_ event: CodeEvent) {
        lock.lock()
        collected.append(event)
        lock.unlock()
    }

    private static func displayName(_ event: CodeEvent) -> String {
        if case .event(let stream) = event {
            return "event:\(stream.name)"
        }
        let raw = String(describing: event)
        return String(raw.prefix(while: { $0 != "(" }))
    }
}

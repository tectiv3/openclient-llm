//
//  CodeViewModelTests+EchoRetry.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/06/2026.
//

@testable import openclient_llm
import XCTest

/// A user transcript item's fields, projected for assertions.
/// A struct rather than a tuple: a 4-member tuple trips the
/// `large_tuple` error threshold.
struct UserItemSnapshot {
    let id: UUID
    let text: String
    let failed: Bool
    let pending: Bool
}

// MARK: - CodeViewModelTests — Echo failure and retry

extension CodeViewModelTests {
    func test_sendPrompt_sendFails_marksLocalEchoFailed() async throws {
        // Given
        try await connectAndEstablish()
        mockClient.sendResult = false

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then — the echo stays in the transcript, marked failed
        try await waitUntil { self.lastUserItem()?.failed == true }
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "hi")
        XCTAssertTrue(item.failed)
        XCTAssertEqual(currentSession()?.items.count, 1)
    }

    func test_sendSteer_sendFails_marksLocalEchoFailed() async throws {
        // Given
        try await connectAndEstablish(isStreaming: true)
        mockClient.sendResult = false

        // When
        sut.send(.sendSteer(text: "be brief"))

        // Then
        try await waitUntil { self.lastUserItem()?.failed == true }
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "be brief")
        XCTAssertTrue(item.failed)
    }

    func test_errorNotIdle_trailingPendingEcho_marksEchoFailed() async throws {
        // Given — the echo was sent, the server rejected it
        try await connectAndEstablish()
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }

        // When
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))

        // Then
        try await waitUntil { self.lastUserItem()?.failed == true }
        XCTAssertEqual(currentSession()?.items.count, 1)
    }

    func test_errorNotIdle_trailingAssistantItem_mutatesNothing() async throws {
        // Given — an assistant item followed the prompt, so the
        // rejection is uncorrelatable and must be ignored
        try await connectAndEstablish(isStreaming: true)
        mockClient.emit(.event(messageStartEvent(role: "assistant")))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }

        // When
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then — no user item was created or mutated
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 1)
        guard case let .assistant(id, _, _) = items[0] else {
            return XCTFail("Expected assistant item, got \(items[0])")
        }
        XCTAssertFalse(
            items.contains { item in
                if case .user(_, _, true, _) = item {
                    return true
                }
                return false
            }
        )
        _ = id
    }

    func test_retryPrompt_failedEcho_clearsFlagAndResendsPrompt() async throws {
        // Given — a failed echo, as left behind by a failed send
        try await connectAndEstablish()
        mockClient.sendResult = false
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil { self.lastUserItem()?.failed == true }
        let echoId = try XCTUnwrap(lastUserItem()).id
        mockClient.sendResult = true

        // When
        sut.send(.retryPrompt(id: echoId))

        // Then — flag cleared, no duplicate echo, prompt sent again
        try await waitUntil { self.lastUserItem()?.failed == false }
        XCTAssertEqual(currentSession()?.items.count, 1)
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .prompt(text) = $0 {
                    return text == "hi"
                }
                return false
            }) == 2
        }
    }

    func test_retryPrompt_dedupedEcho_reusesExistingHistoryItem() async throws {
        // Given — the echo was deduped onto a synced history item
        try await connectAndEstablish()
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil,
            pending: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }
        mockClient.sendResult = false
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil { self.lastUserItem()?.failed == true }
        let echoId = try XCTUnwrap(lastUserItem()).id
        mockClient.sendResult = true

        // When
        sut.send(.retryPrompt(id: echoId))

        // Then — the single history item was reused, not duplicated
        try await waitUntil { self.lastUserItem()?.failed == false }
        XCTAssertEqual(currentSession()?.items.count, 1)
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .prompt(text) = $0 {
                    return text == "hi"
                }
                return false
            }) == 1
        }
    }

    func test_retryPrompt_whileStreaming_stillSends() async throws {
        // Given — the echo failed while idle, then the session started
        // streaming; the retry must not be swallowed by the `isStreaming`
        // guard in `handleSendPrompt`
        try await connectAndEstablish()
        mockClient.sendResult = false
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil { self.lastUserItem()?.failed == true }
        mockClient.emit(.state(sessionInfo(isStreaming: true)))
        try await waitUntil {
            (self.currentSession()?.isStreaming ?? false) == true
        }
        let echoId = try XCTUnwrap(lastUserItem()).id
        mockClient.sendResult = true

        // When
        sut.send(.retryPrompt(id: echoId))

        // Then — the prompt is sent despite streaming
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .prompt(text) = $0 {
                    return text == "hi"
                }
                return false
            }) == 2
        }
    }

    // MARK: - Tests — not_idle correlation by pending prompt ID

    func test_errorNotIdle_trailingAcceptedSteer_marksPromptNotSteer()
        async throws
    {
        // Given — the exact mis-attribution repro: prompt A was accepted
        // and is pending, then a steer (never rejected not_idle) was
        // accepted and is the trailing echo
        try await connectAndEstablish()
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }
        mockClient.emit(.state(sessionInfo(isStreaming: true)))
        try await waitUntil {
            (self.currentSession()?.isStreaming ?? false) == true
        }
        sut.send(.sendSteer(text: "be brief"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .steer = $0 {
                    return true
                }
                return false
            }) == 1
        }

        // When — the busy-rejection arrives while the steer echo trails
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))

        // Then — the prompt echo is marked, the trailing steer is not
        try await waitUntil {
            self.userItems().contains {
                $0.text == "hi" && $0.failed
            }
        }
        let items = userItems()
        XCTAssertEqual(items.count, 2)
        let steer = try XCTUnwrap(
            items.first { $0.text == "be brief" },
            "Steer echo missing from transcript"
        )
        XCTAssertFalse(steer.failed)
    }

    func test_errorNotIdle_noPendingEcho_mutatesNothing() async throws {
        // Given — no prompt was ever sent, so nothing is pending
        try await connectAndEstablish()

        // When
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then — the toast-only path: transcript untouched
        XCTAssertEqual(currentSession()?.items.count, 0)
    }

    func test_errorNotIdle_afterAgentStart_mutatesNothing() async throws {
        // Given — the prompt was accepted (agent_start), so its pending
        // entry is cleared and a later rejection cannot re-attribute it
        try await connectAndEstablish()
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }
        mockClient.emit(.event(CodeStreamEvent(
            sessionId: "s1", name: "agent_start", payload: [:]
        )))

        // When — a stray not_idle arrives after the run is underway
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then — nothing was marked failed
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items.contains {
            if case .user(_, _, true, _) = $0 {
                return true
            }
            return false
        })
    }

    // MARK: - Tests — retry guards

    func test_retryPrompt_nonFailedItem_doesNotResend() async throws {
        // Given — a delivered (non-failed) echo; a double-tap on the
        // badge must not re-send the prompt
        try await connectAndEstablish()
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }
        let echoId = try XCTUnwrap(lastUserItem()).id

        // When
        sut.send(.retryPrompt(id: echoId))
        try await Task.sleep(for: .milliseconds(100))

        // Then — no second prompt, transcript untouched
        XCTAssertEqual(
            mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }),
            1
        )
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "hi")
        XCTAssertFalse(item.failed)
        XCTAssertEqual(currentSession()?.items.count, 1)
    }

    func test_errorNotIdle_afterHistoryReplacement_marksNothing()
        async throws
    {
        // Given — the prompt was sent and deduped onto a synced history
        // item, then a fresh history sync replaced the transcript with
        // new UUIDs, so any pending echo ID is now stale
        try await connectAndEstablish()
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil,
            pending: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.count ?? 0) == 1
        }
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }
        let staleId = try XCTUnwrap(lastUserItem()).id
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil,
            pending: nil
        )))
        try await waitUntil {
            (self.currentSession()?.items.first?.id != staleId)
        }

        // When — the in-flight rejection arrives for the churned UUID
        mockClient.emit(.error(CodeServerError(
            code: "not_idle", message: "agent is busy"
        )))
        try await Task.sleep(for: .milliseconds(100))

        // Then — no crash, the replacement item is untouched
        let items = try XCTUnwrap(currentSession()?.items)
        XCTAssertEqual(items.count, 1)
        guard case let .user(id, text, failed, pending) = items[0] else {
            return XCTFail("Expected user item, got \(items[0])")
        }
        XCTAssertNotEqual(id, staleId)
        XCTAssertEqual(text, "hi")
        XCTAssertFalse(failed)
        XCTAssertFalse(pending)
    }

    // MARK: - Tests — Pending steer echoes

    func test_sendSteer_connectedStreaming_localEchoMarkedPending()
        async throws
    {
        // Given
        try await connectAndEstablish(isStreaming: true)

        // When
        sut.send(.sendSteer(text: "be brief"))

        // Then — queued in pi until the next turn boundary delivers it
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "be brief")
        XCTAssertFalse(item.failed)
        XCTAssertTrue(item.pending)
    }

    func test_sendPrompt_connectedIdle_localEchoNotPending() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.sendPrompt(text: "hi"))

        // Then — a prompt is accepted or rejected, never queued
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertEqual(item.text, "hi")
        XCTAssertFalse(item.failed)
        XCTAssertFalse(item.pending)
    }

    func test_sendSteer_sendFails_echoFailedNotPending() async throws {
        // Given — the transport rejects the steer before pi can queue it
        try await connectAndEstablish(isStreaming: true)
        mockClient.sendResult = false

        // When
        sut.send(.sendSteer(text: "be brief"))

        // Then — failed, and pending was never set (mutually exclusive)
        try await waitUntil { self.lastUserItem()?.failed == true }
        let item = try XCTUnwrap(lastUserItem())
        XCTAssertTrue(item.failed)
        XCTAssertFalse(item.pending)
    }

    func test_historyResync_steerInPendingList_survivesAsQueuedItem()
        async throws
    {
        // Given — a steer echo that pi still has queued
        try await connectAndEstablish(isStreaming: true)
        sut.send(.sendSteer(text: "be brief"))
        try await waitUntil { self.lastUserItem() != nil }

        // When — the snapshot lacks the steer in messages but carries it
        // in the server-side pending queue
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "hi")],
            cursor: nil,
            pending: ["be brief"]
        )))
        try await waitUntil {
            self.currentSession()?.items.count == 2
        }

        // Then — the steer survives the resync exactly once, as queued
        let items = userItems()
        XCTAssertEqual(items.count, 2)
        let steers = items.filter { $0.text == "be brief" }
        XCTAssertEqual(steers.count, 1, "no duplicate steer item")
        XCTAssertTrue(steers.first?.pending ?? false)
        XCTAssertFalse(steers.first?.failed ?? true)
    }

    func test_historyResync_steerDeliveredInMessages_singleDeliveredItem()
        async throws
    {
        // Given — a steer echo that pi delivered while the snapshot was
        // in flight
        try await connectAndEstablish(isStreaming: true)
        sut.send(.sendSteer(text: "be brief"))
        try await waitUntil { self.lastUserItem() != nil }
        let echoId = try XCTUnwrap(lastUserItem()).id

        // When — the snapshot holds the steer in messages, not pending
        mockClient.emit(.history(CodeHistory(
            sessionId: "s1",
            messages: [.user(text: "be brief")],
            cursor: nil,
            pending: nil
        )))
        // The resync replaces the transcript wholesale with a new UUID.
        try await waitUntil {
            self.currentSession()?.items.first?.id != echoId
        }

        // Then — exactly one item, delivered
        let items = userItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.text, "be brief")
        XCTAssertFalse(items.first?.failed ?? true)
        XCTAssertFalse(items.first?.pending ?? true)
    }

    // MARK: - Helpers

    func userItems() -> [UserItemSnapshot] {
        (currentSession()?.items ?? []).compactMap {
            if case let .user(id, text, failed, pending) = $0 {
                return UserItemSnapshot(
                    id: id, text: text, failed: failed, pending: pending
                )
            }
            return nil
        }
    }

    func lastUserItem() -> UserItemSnapshot? {
        guard let items = currentSession()?.items,
              case let .user(id, text, failed, pending)? = items.last
        else {
            return nil
        }
        return UserItemSnapshot(
            id: id, text: text, failed: failed, pending: pending
        )
    }
}

//
//  CodeViewModelTests+NotificationTap.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - Notification Tap Tests

extension CodeViewModelTests {
    // MARK: - Tests

    /// Spec (rc-push-notifications, `didReceive`): the tap always
    /// initiates a reconnect via `lastConnect`, bypassing the guards that
    /// leave the burn-out path (`.failed`, `backgroundDisconnected ==
    /// false`) unrecovered by the foregrounding pass.
    func test_send_notificationTapped_fromFailedWithLastConnect_reconnects() async throws {
        // Given — reconnect burn-out: the client exhausted its attempts
        // and the VM sits in `.failed` with `lastConnect` retained.
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))
        mockClient.emit(.connectionFailed("Connection lost after 10 attempts"))
        try await waitUntil {
            if case .failed = self.sut.state {
                return true
            }
            return false
        }

        // When
        sut.send(.notificationTapped)

        // Then — a fresh connection attempt via `lastConnect`
        XCTAssertEqual(mockClient.connectCalls.count, 2)
        let last = try XCTUnwrap(mockClient.connectCalls.last)
        XCTAssertEqual(last.host, "10.0.0.1")
        XCTAssertEqual(last.port, 47800)
        XCTAssertEqual(last.code, "abc123")
        guard case .connecting = sut.state else {
            return XCTFail("Expected connecting, got \(sut.state)")
        }
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .hello = $0 {
                    return true
                }
                return false
            }) == 2
        }
    }

    func test_send_notificationTapped_fromConnected_isNoOp() async throws {
        // Given
        try await connectAndEstablish()

        // When
        sut.send(.notificationTapped)
        try await Task.sleep(for: .milliseconds(100))

        // Then — no second connection
        XCTAssertEqual(mockClient.connectCalls.count, 1)
        guard case .connected = sut.state else {
            return XCTFail("Expected connected, got \(sut.state)")
        }
    }

    func test_send_notificationTapped_fromDisconnectedWithBackgroundFlag_reconnectsOnce() async throws {
        // Given — background-task expiry left `.disconnected` + the flag,
        // the common case where tap and foregrounding pass both fire.
        try await connectAndEstablish()
        sut.isBackgrounded = { true }
        sut.send(.appDidEnterBackground)
        try await waitUntil { self.mockBackground.beginCount == 1 }
        try XCTUnwrap(mockBackground.expirationHandler)()
        guard case .disconnected = sut.state else {
            return XCTFail("Expected disconnected after expiry")
        }
        XCTAssertEqual(sut.backgroundDisconnected, true)

        // When — the tap lands before the foregrounding pass runs.
        sut.send(.notificationTapped)
        sut.send(.appWillEnterForeground)

        // Then — exactly one reconnect; the tap consumed the flag.
        XCTAssertEqual(mockClient.connectCalls.count, 2,
                       "Tap and foregrounding pass must not double-connect")
        guard case .connecting = sut.state else {
            return XCTFail("Expected connecting, got \(sut.state)")
        }
        XCTAssertEqual(sut.backgroundDisconnected, false)
    }

    func test_send_notificationTapped_withoutLastConnect_isNoOp() async throws {
        // Given — no connect was ever made (e.g. process was killed in the
        // background, so `lastConnect` is gone).
        // When
        sut.send(.notificationTapped)
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.connectCalls.count, 0)
        guard case .disconnected = sut.state else {
            return XCTFail("Expected disconnected, got \(sut.state)")
        }
    }
}

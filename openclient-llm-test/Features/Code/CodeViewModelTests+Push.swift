//
//  CodeViewModelTests+Push.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - Push Token Tests

extension CodeViewModelTests {
    // MARK: - Properties

    private static let pushToken = "a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718a1b2c3d4e5f60718"

    // MARK: - Tests

    func test_handleHelloOk_withToken_sendsPushToken() async throws {
        // Given
        mockPush.token = Self.pushToken

        // When
        try await connectAndEstablish()

        // Then
        try await waitUntil {
            self.mockClient.attemptsCount(where: { Self.isPushToken($0) }) == 1
        }
    }

    func test_reconnect_helloOk_withToken_sendsPushTokenAgain() async throws {
        // Given
        mockPush.token = Self.pushToken
        try await connectAndEstablish()
        try await waitUntil {
            self.mockClient.attemptsCount(where: { Self.isPushToken($0) }) == 1
        }
        mockClient.emit(.disconnected)
        try await waitUntil {
            if case .reconnecting = self.sut.state {
                return true
            }
            return false
        }

        // When
        mockClient.emit(.helloOk(version: 1))

        // Then
        try await waitUntil {
            self.mockClient.attemptsCount(where: { Self.isPushToken($0) }) == 2
        }
    }

    func test_handleHelloOk_withoutToken_doesNotSendPushToken() async throws {
        // Given
        // No token registered.

        // When
        try await connectAndEstablish()
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.attemptsCount(where: { Self.isPushToken($0) }), 0)
    }

    /// Spec verification plan: `push_token` is only valid after `hello_ok`
    /// (the server rejects any non-hello frame before authentication), so
    /// the client must never emit it before the handshake completes.
    func test_pushToken_neverEmittedBeforeHelloOk() async throws {
        // Given — the token is already registered before the handshake.
        mockPush.token = Self.pushToken
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))

        // When — the hello is in flight, `hello_ok` has not arrived.
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .hello = $0 {
                    return true
                }
                return false
            }) == 1
        }
        try await Task.sleep(for: .milliseconds(100))

        // Then — no `push_token` before the handshake completed.
        XCTAssertEqual(
            mockClient.attemptsCount(where: { Self.isPushToken($0) }), 0,
            "push_token must never precede hello_ok"
        )

        // When — the handshake completes.
        mockClient.emit(.helloOk(version: 1))

        // Then — exactly one registration follows.
        try await waitUntil {
            self.mockClient.attemptsCount(where: { Self.isPushToken($0) }) == 1
        }
    }

    func test_tokenUpdate_whileConnected_sendsPushToken() async throws {
        // Given
        try await connectAndEstablish()

        // When
        mockPush.updateToken(Self.pushToken)

        // Then
        try await waitUntil {
            self.mockClient.attemptsCount(where: { Self.isPushToken($0) }) == 1
        }
    }

    func test_tokenUpdate_whileDisconnected_doesNotSendPushToken() async throws {
        // Given
        // No connection established.

        // When
        mockPush.updateToken(Self.pushToken)
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.attemptsCount(where: { Self.isPushToken($0) }), 0)
    }

    func test_handleConnect_requestsAuthorization() async throws {
        // When
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))

        // Then
        try await waitUntil { self.mockPush.requestAuthorizationCallCount == 1 }
    }

    // MARK: - Helpers

    private static func isPushToken(_ message: CodeClientMessage) -> Bool {
        if case .pushToken = message {
            return true
        }
        return false
    }
}

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

    func test_handleHelloOk_withoutToken_doesNotSendPushToken() async throws {
        // Given
        // No token registered.

        // When
        try await connectAndEstablish()
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.attemptsCount(where: { Self.isPushToken($0) }), 0)
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

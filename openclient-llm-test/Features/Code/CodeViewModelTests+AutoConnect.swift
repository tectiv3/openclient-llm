//
//  CodeViewModelTests+AutoConnect.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - Auto-Connect Tests

extension CodeViewModelTests {
    // MARK: - Properties

    /// Distinct from the token in CodeViewModelTests+Push.swift to avoid
    /// member redeclaration across extensions.
    private static let apnsToken =
        "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

    // MARK: - Tests

    func test_send_viewAppeared_withSavedHostAndToken_autoConnectsViaToken() async throws {
        // Given
        makeSutWithSavedHost(token: Self.apnsToken)

        // When
        sut.send(.viewAppeared)

        // Then
        XCTAssertEqual(sut.state, .connecting)
        XCTAssertEqual(mockClient.connectCalls.count, 1)
        XCTAssertEqual(mockClient.connectCalls.first?.code, "")
        XCTAssertEqual(sut.lastConnect?.host, "10.0.0.1")
        XCTAssertEqual(sut.lastConnect?.code, "")
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .hello(code, _, token) = $0 {
                    return code.isEmpty && token == Self.apnsToken
                }
                return false
            }) == 1
        }
        XCTAssertEqual(
            mockPush.requestAuthorizationCallCount, 0,
            "Auto-connect must not re-request push authorization"
        )

        mockClient.emit(.helloOk(version: 1))
        try await waitUntil {
            if case .connected = self.sut.state {
                return true
            }
            return false
        }
    }

    func test_send_viewAppeared_withoutSavedHost_doesNotConnect() async throws {
        // Given — default sut has no saved host, but a token exists.
        mockPush.token = Self.apnsToken

        // When
        sut.send(.viewAppeared)
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.connectCalls.count, 0)
    }

    func test_send_viewAppeared_withoutPushToken_doesNotConnect() async throws {
        // Given
        makeSutWithSavedHost(token: nil)

        // When
        sut.send(.viewAppeared)
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.connectCalls.count, 0)
    }

    func test_autoConnect_authFailedBadCode_returnsCleanDisconnectedForm() async throws {
        // Given
        makeSutWithSavedHost(token: Self.apnsToken)
        sut.send(.viewAppeared)
        try await waitUntil { !self.mockClient.connectCalls.isEmpty }

        // When
        mockClient.emit(.authFailed(
            CodeServerError(code: "bad_code", message: "invalid")
        ))
        try await waitUntil {
            if case .disconnected = self.sut.state {
                return true
            }
            return false
        }

        // Then
        XCTAssertNil(sut.connectForm.errorMessage)
        XCTAssertNil(sut.connectForm.rateLimitedUntil)
        XCTAssertEqual(sut.connectForm.code, "")
        XCTAssertEqual(sut.connectForm.hasSavedHost, true)
    }

    func test_autoConnect_authFailedBadCode_secondViewAppearedDoesNotReconnect() async throws {
        // Given
        makeSutWithSavedHost(token: Self.apnsToken)
        sut.send(.viewAppeared)
        try await waitUntil { !self.mockClient.connectCalls.isEmpty }
        mockClient.emit(.authFailed(
            CodeServerError(code: "bad_code", message: "invalid")
        ))
        try await waitUntil {
            if case .disconnected = self.sut.state {
                return true
            }
            return false
        }

        // When
        sut.send(.viewAppeared)
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.connectCalls.count, 1)
    }

    func test_send_viewAppeared_afterManualDisconnect_doesNotAutoConnect() async throws {
        // Given
        makeSutWithSavedHost(token: Self.apnsToken)
        sut.send(.viewAppeared)
        mockClient.emit(.helloOk(version: 1))
        try await waitUntil {
            if case .connected = self.sut.state {
                return true
            }
            return false
        }
        sut.send(.disconnect)
        guard case .disconnected = sut.state else {
            return XCTFail("Expected disconnected, got \(sut.state)")
        }

        // When
        sut.send(.viewAppeared)
        try await Task.sleep(for: .milliseconds(100))

        // Then
        XCTAssertEqual(mockClient.connectCalls.count, 1)
    }

    func test_autoConnect_authFailedRateLimited_surfacesCountdown() async throws {
        // Given
        makeSutWithSavedHost(token: Self.apnsToken)
        sut.send(.viewAppeared)
        try await waitUntil { !self.mockClient.connectCalls.isEmpty }

        // When
        mockClient.emit(.authFailed(
            CodeServerError(code: "rate_limited", message: nil)
        ))
        try await waitUntil {
            if case .disconnected = self.sut.state {
                return true
            }
            return false
        }

        // Then
        XCTAssertNotNil(sut.connectForm.errorMessage)
        XCTAssertNotNil(sut.connectForm.rateLimitedUntil)
    }

    func test_send_connect_afterSuppressedAutoFailure_connectsManually() async throws {
        // Given
        makeSutWithSavedHost(token: Self.apnsToken)
        sut.send(.viewAppeared)
        try await waitUntil { !self.mockClient.connectCalls.isEmpty }
        mockClient.emit(.authFailed(
            CodeServerError(code: "bad_code", message: "invalid")
        ))
        try await waitUntil {
            if case .disconnected = self.sut.state {
                return true
            }
            return false
        }

        // When
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))
        try await waitUntil {
            self.mockClient.connectCalls.count == 2
        }

        // Then
        XCTAssertEqual(sut.state, .connecting)
        try await waitUntil { self.mockPush.requestAuthorizationCallCount == 1 }
        mockClient.emit(.helloOk(version: 1))
        try await waitUntil {
            if case .connected = self.sut.state {
                return true
            }
            return false
        }
    }

    // MARK: - Helpers

    /// Rebuilds the sut with a saved Code host/port and an optional push
    /// token, mirroring a returning user with prior registration.
    private func makeSutWithSavedHost(token: String?) {
        mockSettings.codeHost = "10.0.0.1"
        mockSettings.codePort = 47800
        mockPush.token = token
        sut = CodeViewModel(
            client: mockClient,
            settingsManager: mockSettings,
            backgroundUseCase: mockBackground,
            notificationManager: mockNotifications,
            remoteNotificationManager: mockPush
        )
    }
}

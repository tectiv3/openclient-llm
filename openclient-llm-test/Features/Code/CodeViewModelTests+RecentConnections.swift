//
//  CodeViewModelTests+RecentConnections.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/26/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Recent connections

extension CodeViewModelTests {
    // MARK: - Tests — Recent connections

    func test_send_connect_recordsRecentConnection() {
        // When
        sut.send(.connect(host: "10.0.0.1", port: 47800, code: "abc123"))

        // Then
        XCTAssertEqual(mockSettings.codeRecentConnections, [
            CodeRecentConnection(host: "10.0.0.1", port: 47800),
        ])
    }

    func test_send_connect_repeatedConnections_dedupeWithMruOrdering() {
        // When
        sut.send(.connect(host: "a.ts.net", port: 47800, code: "abc123"))
        sut.send(.connect(host: "b.ts.net", port: 47801, code: "abc123"))
        sut.send(.connect(host: "a.ts.net", port: 47800, code: "abc123"))

        // Then
        XCTAssertEqual(mockSettings.codeRecentConnections, [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
            CodeRecentConnection(host: "b.ts.net", port: 47801),
        ])
    }

    func test_disconnectedForm_afterAuthFailure_includesRecentConnections() async throws {
        // Given
        mockSettings.codeRecentConnections = [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
        ]
        sut.send(.connect(host: "a.ts.net", port: 47800, code: "badcode"))

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
        XCTAssertEqual(sut.connectForm.recentConnections, [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
        ])
    }

    func test_init_withStoredRecents_populatesConnectForm() {
        // Given
        mockSettings.codeRecentConnections = [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
        ]

        // When
        sut = CodeViewModel(
            client: mockClient,
            settingsManager: mockSettings,
            backgroundUseCase: mockBackground,
            notificationManager: mockNotifications,
            remoteNotificationManager: mockPush
        )

        // Then
        XCTAssertEqual(sut.connectForm.recentConnections, [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
        ])
    }
}

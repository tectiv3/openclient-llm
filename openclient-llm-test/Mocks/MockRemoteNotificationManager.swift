//
//  MockRemoteNotificationManager.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation
@testable import openclient_llm

// Safety: Only used within serialized @MainActor test methods.
final class MockRemoteNotificationManager: RemoteNotificationManagerProtocol, @unchecked Sendable {
    // MARK: - Properties

    var token: String?
    var onTokenUpdate: ((String) -> Void)?
    private(set) var updateTokenCalls: [String] = []
    private(set) var clearTokenCallCount = 0
    private(set) var requestAuthorizationCallCount = 0
    private(set) var registrationFailureCount = 0

    // MARK: - RemoteNotificationManagerProtocol

    func getToken() -> String? {
        token
    }

    func setOnTokenUpdate(_ update: ((String) -> Void)?) {
        onTokenUpdate = update
    }

    func updateToken(_ token: String) {
        updateTokenCalls.append(token)
        self.token = token
        onTokenUpdate?(token)
    }

    func clearToken() {
        clearTokenCallCount += 1
        token = nil
    }

    func requestAuthorization() async {
        requestAuthorizationCallCount += 1
    }

    func handleRegistrationFailure(_: Error) {
        registrationFailureCount += 1
        token = nil
    }
}

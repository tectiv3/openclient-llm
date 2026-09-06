//
//  RemoteNotificationManager.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation
import UserNotifications

// MARK: - RemoteNotificationManagerProtocol

/// Owns the APNs device token for remote push. The token is kept in memory
/// only: the app re-registers on every launch and the server treats
/// registration as last-wins.
protocol RemoteNotificationManagerProtocol {
    /// Current hex device token, if registration has succeeded.
    func getToken() -> String?
    /// Sets the observer fired on the main actor when a token arrives or
    /// changes; pass `nil` to detach.
    func setOnTokenUpdate(_ update: ((String) -> Void)?)
    func updateToken(_ token: String)
    func clearToken()
    func requestAuthorization() async
    func handleRegistrationFailure(_ error: Error)
}

// MARK: - RemoteNotificationManager

@Observable
@MainActor
final class RemoteNotificationManager: RemoteNotificationManagerProtocol {
    // MARK: - Properties

    static let shared = RemoteNotificationManager()

    private(set) var token: String?

    var onTokenUpdate: ((String) -> Void)?

    // MARK: - Public

    func getToken() -> String? {
        token
    }

    func setOnTokenUpdate(_ update: ((String) -> Void)?) {
        onTokenUpdate = update
    }

    func updateToken(_ token: String) {
        guard token != self.token else { return }
        LogManager.info("APNs device token received (\(token.prefix(8))…)")
        self.token = token
        onTokenUpdate?(token)
    }

    func clearToken() {
        token = nil
    }

    func requestAuthorization() async {
        // .timeSensitive is app-wide and only takes effect at first grant,
        // so it must be requested here, not only by whichever feature asks
        // first (the chat notification request does this too).
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .timeSensitive])
            LogManager.info("Remote notification permission granted=\(granted)")
        } catch {
            LogManager.error("Remote notification permission failed: \(error)")
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        LogManager.error("Remote notification registration failed: \(error)")
        clearToken()
    }
}

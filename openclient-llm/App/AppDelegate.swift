//
//  AppDelegate.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 06/04/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import StoreKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    // MARK: - Properties

    private var transactionObserverTask: Task<Void, Never>?
    private var pushRegistrationFailed = false

    // MARK: - UIApplication

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: ShortcutAction.newChat.rawValue,
                localizedTitle: String(localized: "New Chat"),
                localizedSubtitle: String(localized: "Start a new conversation"),
                icon: UIApplicationShortcutIcon(type: .compose)
            ),
            UIApplicationShortcutItem(
                type: ShortcutAction.newPrivateChat.rawValue,
                localizedTitle: String(localized: "New Private Chat"),
                localizedSubtitle: String(localized: "Chat without saving history"),
                icon: UIApplicationShortcutIcon(systemImageName: "lock.fill")
            ),
            UIApplicationShortcutItem(
                type: ShortcutAction.search.rawValue,
                localizedTitle: String(localized: "Search"),
                localizedSubtitle: String(localized: "Find a conversation"),
                icon: UIApplicationShortcutIcon(type: .search)
            ),
        ]

        transactionObserverTask = Task {
            for await result in Transaction.updates {
                if case let .verified(transaction) = result {
                    await transaction.finish()
                }
            }
        }

        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()

        return true
    }

    // MARK: - Remote Notification Registration

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.0x", $0) }.joined()
        RemoteNotificationManager.shared.updateToken(token)
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushRegistrationFailed = true
        RemoteNotificationManager.shared.handleRegistrationFailure(error)
    }

    func applicationDidBecomeActive(_: UIApplication) {
        // Retry here: a transient failure at launch must not kill push for the process lifetime.
        guard pushRegistrationFailed else { return }
        pushRegistrationFailed = false
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Suppress foreground banners: the live RC UI already shows these
        // events over the WebSocket connection.
        completionHandler([])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // The payload carries no deep-link data; foregrounding the app lets
        // the Code feature's foreground auto-reconnect do the rest.
        completionHandler()
    }

    func application(
        _: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundCompletionService.sessionIdentifier {
            BackgroundCompletionService.shared.handleEventsForBackgroundURLSession(
                completionHandler: completionHandler
            )
        }
    }

    // MARK: - Scene Configuration

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self

        return config
    }
}

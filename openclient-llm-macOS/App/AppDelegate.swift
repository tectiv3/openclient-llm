//
//  AppDelegate.swift
//  openclient-llm-macOS
//
//  Created by Arturo Carretero Calvo on 10/04/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import AppKit
import StoreKit
import UserNotifications

// MARK: - Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // MARK: - Properties

    private var transactionObserverTask: Task<Void, Never>?
    private var pushRegistrationFailed = false

    private let menuBarManager = MenuBarManager()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_: Notification) {
        menuBarManager.setUp()

        transactionObserverTask = Task {
            for await result in Transaction.updates {
                if case let .verified(transaction) = result {
                    await transaction.finish()
                }
            }
        }

        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.registerForRemoteNotifications()
    }

    func applicationDidBecomeActive(_: Notification) {
        guard pushRegistrationFailed else { return }
        pushRegistrationFailed = false
        NSApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Remote Notification Registration

    func application(
        _: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        RemoteNotificationManager.shared.updateToken(token)
    }

    func application(
        _: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        pushRegistrationFailed = true
        RemoteNotificationManager.shared.handleRegistrationFailure(error)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

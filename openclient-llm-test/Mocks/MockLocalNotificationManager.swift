//
//  MockLocalNotificationManager.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation
@testable import openclient_llm

// Safety: Only used within serialized @MainActor test methods.
final class MockLocalNotificationManager: LocalNotificationManagerProtocol, @unchecked Sendable {
    // MARK: - Properties

    var requestAuthorizationCalled = false
    private(set) var sendCompletionCount = 0
    private(set) var sendExpiredCount = 0
    private(set) var sendQuestionCount = 0

    // MARK: - LocalNotificationManagerProtocol

    func requestAuthorization() async {
        requestAuthorizationCalled = true
    }

    func sendCompletionNotification() {
        sendCompletionCount += 1
    }

    func sendExpiredNotification() {
        sendExpiredCount += 1
    }

    func sendQuestionNotification() {
        sendQuestionCount += 1
    }
}

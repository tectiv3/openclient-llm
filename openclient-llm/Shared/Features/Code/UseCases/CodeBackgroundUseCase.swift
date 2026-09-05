//
//  CodeBackgroundUseCase.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

// MARK: - CodeBackgroundUseCaseProtocol

protocol CodeBackgroundUseCaseProtocol: AnyObject {
    func begin(expirationHandler: @escaping () -> Void)
    func end()
}

// MARK: - CodeBackgroundUseCase

/// Keeps the Code WebSocket connection alive during the iOS background window.
/// Class-based use case because it wraps a stateful manager (UIBackgroundTaskIdentifier lifecycle).
/// Isolated to @MainActor — safe to call from CodeViewModel without Sendable concerns.
@MainActor
final class CodeBackgroundUseCase: CodeBackgroundUseCaseProtocol {
    // MARK: - Properties

    private let backgroundTaskManager: BackgroundTaskManager

    // MARK: - Init

    init(backgroundTaskManager: BackgroundTaskManager = BackgroundTaskManager()) {
        self.backgroundTaskManager = backgroundTaskManager
    }

    // MARK: - Execute

    func begin(expirationHandler: @escaping () -> Void) {
        backgroundTaskManager.beginTask(expirationHandler: expirationHandler)
    }

    func end() {
        backgroundTaskManager.endTask()
    }
}

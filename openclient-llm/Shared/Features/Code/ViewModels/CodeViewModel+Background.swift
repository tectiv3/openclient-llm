//
//  CodeViewModel+Background.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation

#if os(iOS)
    import SwiftUI
#endif

// MARK: - Background Behavior

extension CodeViewModel {
    func handleAppDidEnterBackground() {
        #if os(iOS)
            // An abandoned connect has nothing to keep alive; dropping to the
            // disconnected form also prevents a dead spinner on foregrounding.
            // backgroundDisconnected stays unset so the foregrounding pass does
            // not auto-reconnect a connect the user never completed.
            if case .connecting = state {
                eventTask?.cancel()
                eventTask = nil
                client.disconnect()
                resetToDisconnected()
                return
            }

            // A question that arrived in the foreground never produced a
            // notification (APNs pushes are suppressed while active), so this
            // is the last chance to surface it on the lock screen.
            notifyPendingQuestionIfNeeded()
        #endif

        // Only keep a live session alive during the background window.
        guard currentSession != nil else { return }

        backgroundUseCase.begin { [weak self] in
            self?.handleBackgroundTaskExpired()
        }
    }

    private func handleBackgroundTaskExpired() {
        // The expiration handler can fire after the app returned to the
        // foreground; only tear down the session while still backgrounded.
        #if os(iOS)
            guard isBackgrounded() else {
                backgroundUseCase.end()
                return
            }
        #endif

        backgroundUseCase.end()

        // Graceful disconnect: pending questions survive and are
        // re-delivered when the user reconnects (spec Decision 8).
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()
        queuedAnswer = nil
        backgroundDisconnected = true
        resetToDisconnected()
    }

    func handleAppWillEnterForeground() {
        backgroundUseCase.end()
        guard backgroundDisconnected, let last = lastConnect else { return }
        backgroundDisconnected = false
        establishConnection(host: last.host, port: last.port, code: last.code)
    }
}

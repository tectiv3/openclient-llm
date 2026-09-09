//
//  CodeViewModel+Errors.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/09/2026.
//

import Foundation

// MARK: - Error Frames

// Split out of CodeViewModel.swift, which sits at swiftlint's file-length
// error limit; error-frame handling is self-contained behind handleError.

extension CodeViewModel {
    func handleError(_ error: CodeServerError) {
        switch error.code {
        case "compaction_failed":
            transientToast = error.message
                ?? String(localized: "Compaction failed")

        case "not_idle":
            transientToast = error.message
                ?? String(localized: "Cannot send while streaming")
            markPendingEchoFailed()

        case "not_ready":
            transientToast = error.message
                ?? String(localized: "Session loading, try again shortly")

        case "stale_session":
            transientToast = error.message
                ?? String(localized: "Session replaced — run /rc in terminal")

        case "model_not_found":
            transientToast = error.message
                ?? String(localized: "Model not found")

        case "model_not_set":
            transientToast = error.message
                ?? String(localized: "Model unavailable (no provider auth)")

        case "command_failed":
            transientToast = error.message
                ?? String(localized: "Command failed")

        case "unknown_command":
            transientToast = error.message
                ?? String(localized: "Unknown command")

        default:
            break
        }
    }

    /// Marks the newest pending prompt echo failed by UUID and removes it
    /// from the pending list. No-op when the echo no longer exists in the
    /// transcript (e.g. a history sync replaced the items in the meantime).
    private func markPendingEchoFailed() {
        guard var session = currentSession,
              !pendingPromptEchoes.isEmpty
        else { return }

        let id = pendingPromptEchoes.removeLast()
        guard let index = session.items.firstIndex(where: {
            if case let .user(itemId, _, _, _) = $0 {
                return itemId == id
            }
            return false
        }) else {
            LogManager.warning("Code not_idle: pending prompt echo not found")
            return
        }

        if case let .user(itemId, text, _, _) = session.items[index] {
            session.items[index] = .user(
                id: itemId, text: text, failed: true, pending: false
            )
            updateSession(session)
        }
    }

    // MARK: - Commands

    func sendCommand(
        _ command: String,
        args: [String: AnyCodableValue] = [:]
    ) {
        Task { await client.send(.command(command: command, args: args)) }
    }
}

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
        // Genuine compaction failure (a phone-caused abort reports no
        // error): surface as a toast, nothing else to correlate.
        if error.code == "compaction_failed" {
            transientToast = error.message
                ?? String(localized: "Compaction failed")
            return
        }

        guard error.code == "not_idle" else { return }
        transientToast = error.message
            ?? String(localized: "Cannot send while streaming")

        // The error frame carries no prompt text, so correlate by ID:
        // the server processes prompts in order and rejects only prompts
        // (a steer always goes through), so the rejection belongs to the
        // newest echo still pending.
        markPendingEchoFailed()
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
}

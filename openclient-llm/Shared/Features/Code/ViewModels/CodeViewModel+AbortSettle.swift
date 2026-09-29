//
//  CodeViewModel+AbortSettle.swift
//  openclient-llm
//
//  Created by tectiv3 on 29/09/2026.
//

import Foundation

// MARK: - Abort Settle / Outbox

// The server's abort is asynchronous: `ctx.abort()` returns immediately but
// `agent_settled` (and the idle `state` frame) only arrive once the run
// actually stops. A prompt sent in that window is rejected `not_idle` and
// was previously marked failed. The outbox holds such prompts client-side
// until the server confirms it is idle, and the reconciliation task is the
// backstop when no settle frame arrives at all.

extension CodeViewModel {
    /// Restarts the two-phase backstop: refresh state after a short grace
    /// period, then re-issue the abort and refresh once more. Cancelled as
    /// soon as a settle arrives (`clearAbortReconciliation`).
    func startAbortReconciliation() {
        abortReconcileTask?.cancel()
        let reconcileDelay = abortReconcileDelay
        let reabortDelay = abortReabortDelay
        abortReconcileTask = Task { [weak self] in
            try? await Task.sleep(for: reconcileDelay)
            guard let self, !Task.isCancelled,
                  currentSession?.awaitingSettle == true
            else { return }

            await client.send(.getState)
            try? await Task.sleep(for: reabortDelay)
            guard !Task.isCancelled,
                  currentSession?.awaitingSettle == true
            else { return }

            await client.send(.abort)
            await client.send(.getState)
        }
    }

    func clearAbortReconciliation() {
        abortReconcileTask?.cancel()
        abortReconcileTask = nil
    }

    func enqueueOutbox(id: UUID, text: String) {
        pendingOutbox.append((id: id, text: text))
    }

    /// Sends every held prompt once the server is confirmed idle. Each echo
    /// is flipped out of its queued rendering before the send so a failure
    /// marks a settled item, not a queued one.
    func flushPendingOutbox() {
        guard let session = currentSession, !session.awaitingSettle else {
            return
        }
        guard !pendingOutbox.isEmpty else { return }

        let entries = pendingOutbox
        pendingOutbox.removeAll()
        for entry in entries {
            let echo = CodeTranscriptItem.user(
                id: entry.id, text: entry.text, failed: false, pending: false
            )
            if var session = currentSession,
               let index = session.items.firstIndex(where: { $0.id == entry.id })
            {
                session.items[index] = echo
                updateSession(session)
            }
            sendPromptText(entry.text, echo: echo)
        }
    }

    /// `not_idle` defense: a prompt that raced the abort is moved back into
    /// the outbox (as a queued echo) instead of being marked failed, so its
    /// text is never lost. Returns false when no correlatable echo exists —
    /// the caller then falls back to the failed-echo path.
    @discardableResult
    func requeueNewestPendingPrompt() -> Bool {
        guard var session = currentSession,
              let id = pendingPromptEchoes.last,
              let index = session.items.firstIndex(where: { $0.id == id }),
              case let .user(_, text, _, _) = session.items[index]
        else { return false }

        pendingPromptEchoes.removeLast()
        session.items[index] = .user(
            id: id, text: text, failed: false, pending: true
        )
        session.awaitingSettle = true
        updateSession(session)
        enqueueOutbox(id: id, text: text)
        startAbortReconciliation()
        return true
    }
}

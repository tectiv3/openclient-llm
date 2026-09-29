//
//  CodeViewModel+IncomingFrames.swift
//  openclient-llm
//
//  Created by tectiv3 on 29/09/2026.
//

import Foundation

// Split out of CodeViewModel.swift, which sits at swiftlint's file-length
// error limit; the history replay and streaming-buffer frame handlers are
// self-contained behind handleEvent.

// MARK: - Incoming Frames

extension CodeViewModel {
    func handleHistory(_ history: CodeHistory) {
        guard var session = currentSession else { return }
        guard history.sessionId == session.sessionId else { return }

        // The transcript is replaced wholesale, so local-echo UUIDs are gone.
        pendingPromptEchoes.removeAll()
        var items = mapHistoryToItems(history.messages)
        let existingTexts = Set(items.compactMap {
            if case let .user(_, text, _, _) = $0 {
                text
            } else {
                nil
            }
        })
        for pendingText in history.pending ?? [] where !existingTexts.contains(pendingText) {
            items.append(.user(
                id: UUID(), text: pendingText, failed: false, pending: true
            ))
        }
        session.items = items
        updateSession(session)
    }

    func handleStreamingBuffer(
        sessionId: String,
        content: [CodeContentBlock]
    ) {
        guard var session = currentSession,
              sessionId == session.sessionId, !content.isEmpty
        else {
            return
        }

        // Merge, don't append: the buffer's toolUse carriers may duplicate
        // steps the rebuilt history already carries (reconnect mid-tool),
        // and its text/thinking only reaches us un-pruned when genuinely
        // uncommitted. Empty is a no-op so repeated frames are harmless.
        mergeBufferIntoItems(content, into: &session.items)
        updateSession(session)
    }
}

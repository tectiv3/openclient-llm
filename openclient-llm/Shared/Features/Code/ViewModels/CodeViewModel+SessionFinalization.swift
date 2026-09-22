//
//  CodeViewModel+SessionFinalization.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation

// Split out of CodeViewModel+Messages.swift to keep that file under the
// SwiftLint file_length limit. Self-contained: only the module-level
// CodeTranscriptItem enum is referenced, none of that file's private
// extensions.

// MARK: - Session Finalization

extension CodeViewModel {
    /// Marks streaming assistant bubbles complete and drops empty ones,
    /// without touching the session-level `isStreaming` flag (driven by
    /// agent events). pi emits one assistant message per tool call in a
    /// turn; toolCall-only messages parse to empty content, so those stray
    /// bubbles are removed here as the single cleanup point.
    /// Item-array re-sign (m3): the attach view finalizes its bubbles with
    /// the same pass (the session-level `isStreaming` flag stays main-only).
    func finalizeStreamingBubbles(in items: inout [CodeTranscriptItem]) {
        for index in items.indices.reversed() {
            if case let .assistant(id, content, isStreaming)
                = items[index]
            {
                if content.isEmpty {
                    items.remove(at: index)
                } else if isStreaming {
                    items[index] = .assistant(
                        id: id,
                        content: content,
                        isStreaming: false
                    )
                }
            }
        }
    }
}

//
//  CodeViewModel+BufferMerge.swift
//  openclient-llm
//

import Foundation

// MARK: - Streaming buffer merge

extension CodeViewModel {
    /// Merges a (pruned, server-side) streaming buffer over items already
    /// rebuilt from history — the (re)connect snapshot path and the
    /// subagent-attach snapshot path (same wire shape, T5) share this.
    ///
    /// Text and thinking blocks accumulate into ONE streaming assistant
    /// item, appended before any tool steps the buffer adds: in the
    /// uncommitted-tail case the buffer is [text, carriers] of one message,
    /// and the text rendered after its tool steps would look wrong. A
    /// pruned committed-tail buffer is carriers-only, so the append order
    /// is unobservable there.
    ///
    /// toolUse blocks update the last toolStep with the same toolCallId
    /// (live, isComplete false); no match appends a new step — defensive
    /// only, the server prune keeps only carriers whose id the committed
    /// tail already has, or a genuinely new one.
    func mergeBufferIntoItems(
        _ content: [CodeContentBlock],
        into items: inout [CodeTranscriptItem]
    ) {
        let textBlocks = bufferTextBlocks(content)
        if !textBlocks.isEmpty {
            mapAssistantContent(textBlocks, into: &items, isStreaming: true)
        }
        mergeBufferToolUseBlocks(content, into: &items)
    }

    private func bufferTextBlocks(
        _ content: [CodeContentBlock]
    ) -> [CodeContentBlock] {
        content.filter { block in
            switch block {
            case .text, .thinking:
                true
            case .toolUse, .unknown:
                false
            }
        }
    }

    private func mergeBufferToolUseBlocks(
        _ content: [CodeContentBlock],
        into items: inout [CodeTranscriptItem]
    ) {
        for block in content {
            guard case let .toolUse(
                toolCallId, toolName, _, output
            ) = block else { continue }
            updateToolStepCompletion(
                toolCallId: toolCallId,
                toolName: toolName,
                output: output ?? "",
                isComplete: false,
                in: &items
            )
        }
    }
}

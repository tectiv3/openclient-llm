//
//  CodeViewModel+StreamDeltas.swift
//  openclient-llm
//
//  Created by tectiv3 on 25/10/2026.
//

import Foundation

// MARK: - Assistant Delta Reducer

extension CodeViewModel {
    /// Which kind of delta-accumulated block a `contentIndex` addresses.
    /// pi's assistant messages keep text/thinking blocks in a contiguous
    /// index prefix (tool calls come last), so the two block types are all
    /// a delta can ever address.
    private enum DeltaKind {
        case text
        case thinking

        func block(_ text: String) -> CodeContentBlock {
            switch self {
            case .text: .text(text)
            case .thinking: .thinking(text)
            }
        }
    }

    /// Applies one `assistantMessageEvent` from a `message_update` frame to
    /// the last assistant bubble. The wire carries only the event (no
    /// cumulative `message`, no `partial`), so text is assembled by
    /// `contentIndex`: deltas append, `*_end` replaces that block with the
    /// authoritative text. Tool-call and lifecycle events are ignored —
    /// tool steps come from `tool_execution_*` frames, and an index past
    /// the block array pads with `.unknown` (rendered as EmptyView) rather
    /// than shifting content.
    func applyStreamDelta(
        payload: [String: AnyCodableValue],
        in items: inout [CodeTranscriptItem]
    ) {
        guard case let .object(event)? = payload["assistantMessageEvent"],
              case let .string(type)? = event["type"],
              case let .int(index)? = event["contentIndex"],
              let itemIndex = items.lastIndex(where: {
                  if case .assistant = $0 {
                      return true
                  }
                  return false
              })
        else { return }

        switch type {
        case "text_delta", "thinking_delta":
            guard case let .string(delta)? = event["delta"] else { return }
            updateBlocks(at: itemIndex, in: &items) { blocks in
                apply(delta, kind: kind(for: type), at: index,
                      replacing: false, to: &blocks)
            }

        case "text_end", "thinking_end":
            guard case let .string(content)? = event["content"] else { return }
            updateBlocks(at: itemIndex, in: &items) { blocks in
                apply(content, kind: kind(for: type), at: index,
                      replacing: true, to: &blocks)
            }

        default:
            break
        }
    }

    /// `turn_end.message` is the authoritative final content of the
    /// just-finished assistant message: it repairs deltas dropped or
    /// duplicated by a gap between frames, without touching the bubble's
    /// identity. An unusable payload leaves the delta-assembled content in
    /// place.
    func replaceLastAssistantContent(
        fromTurnEnd message: AnyCodableValue?,
        in items: inout [CodeTranscriptItem]
    ) {
        guard let content = messageContentBlocks(message), !content.isEmpty,
              let itemIndex = items.lastIndex(where: {
                  if case .assistant = $0 {
                      return true
                  }
                  return false
              })
        else { return }

        updateBlocks(at: itemIndex, in: &items) { blocks in
            blocks = content
        }
    }

    private func kind(for type: String) -> DeltaKind {
        type.hasPrefix("thinking") ? .thinking : .text
    }

    /// Rebuilds the assistant item so the mutation of its block array is
    /// explicit; the bubble stays streaming until the turn/settle
    /// finalizer runs.
    private func updateBlocks(
        at itemIndex: Int,
        in items: inout [CodeTranscriptItem],
        _ mutate: (inout [CodeContentBlock]) -> Void
    ) {
        guard case let .assistant(id, blocks, _) = items[itemIndex] else {
            return
        }
        var updated = blocks
        mutate(&updated)
        items[itemIndex] = .assistant(
            id: id, content: updated, isStreaming: true
        )
    }

    private func apply(
        _ text: String,
        kind: DeltaKind,
        at index: Int,
        replacing: Bool,
        to blocks: inout [CodeContentBlock]
    ) {
        guard index >= 0 else { return }

        if index > blocks.count {
            blocks.append(contentsOf: [CodeContentBlock](
                repeating: .unknown, count: index - blocks.count
            ))
        }
        guard index < blocks.count else {
            blocks.append(kind.block(text))
            return
        }

        if !replacing {
            switch (blocks[index], kind) {
            case let (.text(existing), .text):
                blocks[index] = .text(existing + text)
                return
            case let (.thinking(existing), .thinking):
                blocks[index] = .thinking(existing + text)
                return
            default:
                // A padded or mismatched slot: the delta establishes it.
                break
            }
        }
        blocks[index] = kind.block(text)
    }
}

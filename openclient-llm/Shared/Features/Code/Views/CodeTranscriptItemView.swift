//
//  CodeTranscriptItemView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeTranscriptItemView: View {
    let item: CodeTranscriptItem
    var onRetry: (UUID) -> Void = { _ in }

    @State private var isCompactionExpanded = false
    @State private var reasoningDisclosureState = ReasoningDisclosureState()

    var body: some View {
        switch item {
        case let .user(id, text, failed, pending):
            userBubble(id: id, text: text, failed: failed, pending: pending)

        case let .assistant(_, content, isStreaming):
            assistantBubble(content, isStreaming: isStreaming)

        case let .toolStep(_, toolName, toolId, args,
                           output, isComplete):
            toolStepView(
                toolName: toolName,
                toolId: toolId,
                args: args,
                output: output,
                isComplete: isComplete
            )

        case let .resolvedQuestion(_, questionText,
                                   answerText, wasCustom):
            resolvedQuestionCard(
                questionText: questionText,
                answerText: answerText,
                wasCustom: wasCustom
            )

        case let .compaction(_, summary):
            compactionSeparator(summary)
        }
    }
}

// MARK: - Private

private extension CodeTranscriptItemView {
    // MARK: User

    func userBubble(
        id: UUID,
        text: String,
        failed: Bool,
        pending: Bool
    ) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .glassEffect(
                    userBubbleTint(failed: failed, pending: pending),
                    in: .rect(cornerRadius: 18)
                )
                .overlay(alignment: .bottom) {
                    if failed {
                        retryBadgeButton(id: id)
                    }
                }
                .overlay(alignment: .bottom) {
                    if pending, !failed {
                        queuedCaption()
                    }
                }
                // Keep the prompt text in the label so VoiceOver users
                // don't lose the content; the retry itself is an explicit
                // action on the badge below, not part of the label.
                .accessibilityLabel(userBubbleAccessibilityLabel(
                    text: text,
                    failed: failed,
                    pending: pending
                ))
        }
    }

    func userBubbleTint(failed: Bool, pending: Bool) -> Glass {
        if failed {
            return .regular.tint(Color.red.opacity(0.45))
        }
        if pending {
            return .regular.tint(Color.appAccent.opacity(0.4))
        }
        return .regular.tint(Color.appAccent)
    }

    func userBubbleAccessibilityLabel(
        text: String,
        failed: Bool,
        pending: Bool
    ) -> String {
        if failed {
            return String(localized: "\(text) — failed to send")
        }
        if pending {
            return String(
                localized: "\(text) — queued, will be delivered during this run"
            )
        }
        return text
    }

    /// Dimmed "Queued" caption for a steer still sitting in pi's steering
    /// queue; the full explanation lives in the accessibility label.
    func queuedCaption() -> some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass")
                .font(.caption2)
            Text(String(localized: "Queued"))
                .font(.caption2)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.bottom, 4)
    }

    /// Retry affordance on a failed bubble. A Button rather than a tap
    /// gesture on the selectable text, so the hit is reliable and
    /// VoiceOver exposes it as a discrete "Retry" action.
    func retryBadgeButton(id: UUID) -> some View {
        Button {
            onRetry(id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                Text(String(localized: "Retry"))
                    .font(.caption2)
            }
            .foregroundStyle(Color.red.opacity(0.9))
            .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Retry"))
    }

    // MARK: Assistant

    func assistantBubble(
        _ content: [CodeContentBlock],
        isStreaming: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(Color.appAccent)
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(
                    Array(content.enumerated()),
                    id: \.offset
                ) { index, block in
                    let isLastBlock = index == content.count - 1
                    contentBlockView(
                        block,
                        isStreaming: isStreaming && isLastBlock
                    )
                }
            }
            .frame(minHeight: 28, alignment: .center)

            Spacer(minLength: 0)
        }
        .task(id: isStreaming) {
            if isStreaming {
                reasoningDisclosureState.viewAppeared(
                    isStreaming: true,
                    hasReasoning: content.hasThinking,
                    hasAnswer: content.hasAnswer
                )
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    reasoningDisclosureState.streamingEnded()
                }
            }
        }
    }

    @ViewBuilder
    func contentBlockView(
        _ block: CodeContentBlock,
        isStreaming: Bool
    ) -> some View {
        switch block {
        case let .text(text):
            MarkdownBubbleView(
                text: text,
                isStreaming: isStreaming
            )

        case let .thinking(text):
            thinkingDisclosure(text, isStreaming: isStreaming)

        case let .toolUse(_, toolName, args, _):
            inlineToolLabel(toolName: toolName, args: args)

        case .unknown:
            EmptyView()
        }
    }

    // MARK: Reasoning Disclosure

    func thinkingDisclosure(
        _ reasoning: String,
        isStreaming _: Bool
    ) -> some View {
        DisclosureGroup(isExpanded: thinkingExpansionBinding) {
            Text(reasoning)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption)
                Text(String(localized: "Thinking"))
                    .font(.caption)
            }
            .foregroundStyle(
                isActivelyReasoning
                    ? AnyShapeStyle(Color.appAccent)
                    : AnyShapeStyle(.secondary)
            )
        }
        .tint(.secondary)
    }

    var thinkingExpansionBinding: Binding<Bool> {
        Binding(
            get: { reasoningDisclosureState.isExpanded },
            set: { reasoningDisclosureState.userToggledExpansion($0) }
        )
    }

    var isActivelyReasoning: Bool {
        reasoningDisclosureState.phase == .reasoning
    }

    // MARK: Tool Step

    func toolStepView(
        toolName: String,
        toolId: String,
        args: [String: AnyCodableValue],
        output: String?,
        isComplete: Bool
    ) -> some View {
        CodeToolStepView(
            toolName: toolName,
            toolId: toolId,
            args: args,
            output: output,
            isComplete: isComplete
        )
    }

    func inlineToolLabel(
        toolName: String,
        args: [String: AnyCodableValue]
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: CodeToolDisplay.icon(for: toolName))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(CodeToolDisplay.summary(toolName: toolName, args: args))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Resolved Question

    func resolvedQuestionCard(
        questionText: String,
        answerText: String,
        wasCustom: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                if !questionText.isEmpty {
                    Text(questionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Color.appAccent)
                    if wasCustom {
                        Text("(\(String(localized: "wrote"))) \(answerText)")
                            .font(.subheadline)
                            .lineLimit(2)
                    } else {
                        Text(answerText)
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    // MARK: Compaction

    func compactionSeparator(_ summary: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                Text(String(localized: "Context compacted"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
            }

            if !summary.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCompactionExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(isCompactionExpanded ? nil : 2)
                        Image(systemName: isCompactionExpanded
                            ? "chevron.up"
                            : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(localized: "Compaction summary")
                )
                .accessibilityValue(
                    isCompactionExpanded
                        ? String(localized: "Expanded")
                        : String(localized: "Collapsed")
                )
            }
        }
    }
}

extension [CodeContentBlock] {
    var hasThinking: Bool {
        contains { block in
            if case let .thinking(text) = block {
                return !text.isEmpty
            }
            return false
        }
    }

    var hasAnswer: Bool {
        contains { block in
            if case let .text(text) = block {
                return !text.isEmpty
            }
            return false
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        CodeTranscriptItemView(item: .user(
            id: UUID(), text: "Fix the tests",
            failed: false, pending: false
        ))
        CodeTranscriptItemView(item: .user(
            id: UUID(), text: "This one failed",
            failed: true, pending: false
        ))
        CodeTranscriptItemView(item: .user(
            id: UUID(), text: "Use the blue theme",
            failed: false, pending: true
        ))
        CodeTranscriptItemView(item: .assistant(
            id: UUID(),
            content: [.text("I'll fix the failing tests.")],
            isStreaming: false
        ))
        CodeTranscriptItemView(item: .resolvedQuestion(
            id: UUID(),
            questionText: "Which file?",
            answerText: "src/main.ts",
            wasCustom: false
        ))
    }
    .padding()
}

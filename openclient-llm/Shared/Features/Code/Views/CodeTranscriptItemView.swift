//
//  CodeTranscriptItemView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct CodeTranscriptItemView: View {
    let item: CodeTranscriptItem

    @State private var isCompactionExpanded = false
    @State private var reasoningDisclosureState = ReasoningDisclosureState()

    var body: some View {
        switch item {
        case .user(_, let text):
            userBubble(text)

        case .assistant(_, let content, let isStreaming):
            assistantBubble(content, isStreaming: isStreaming)

        case .toolStep(_, let toolName, let toolId, let args,
                       let output, let isComplete):
            toolStepView(
                toolName: toolName,
                toolId: toolId,
                args: args,
                output: output,
                isComplete: isComplete
            )

        case .resolvedQuestion(_, let questionText,
                               let answerText, let wasCustom):
            resolvedQuestionCard(
                questionText: questionText,
                answerText: answerText,
                wasCustom: wasCustom
            )

        case .compaction(_, let summary):
            compactionSeparator(summary)
        }
    }
}

// MARK: - Private

private extension CodeTranscriptItemView {
    // MARK: User

    func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .glassEffect(
                    .regular.tint(Color.appAccent),
                    in: .rect(cornerRadius: 18)
                )
        }
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
        case .text(let text):
            MarkdownBubbleView(
                text: text,
                isStreaming: isStreaming
            )

        case .thinking(let text):
            thinkingDisclosure(text, isStreaming: isStreaming)

        case .toolUse(_, let toolName, let args, _):
            inlineToolLabel(toolName: toolName, args: args)
        }
    }

    // MARK: Reasoning Disclosure

    func thinkingDisclosure(
        _ reasoning: String,
        isStreaming: Bool
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
            if case .thinking(let text) = block { return !text.isEmpty }
            return false
        }
    }

    var hasAnswer: Bool {
        contains { block in
            if case .text(let text) = block { return !text.isEmpty }
            return false
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        CodeTranscriptItemView(item: .user(
            id: UUID(), text: "Fix the tests"
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

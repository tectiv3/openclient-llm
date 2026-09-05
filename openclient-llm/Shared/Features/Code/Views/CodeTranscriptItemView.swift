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

    var body: some View {
        switch item {
        case .user(_, let text):
            userBubble(text)

        case .assistant(_, let content, let isStreaming):
            assistantBubble(content, isStreaming: isStreaming)

        case .toolStep(_, let toolName, _, let args,
                       let output, let isComplete):
            toolStepView(
                toolName: toolName,
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
            ThinkingDisclosureView(text: text)

        case .toolUse(_, let toolName, let args, _):
            inlineToolLabel(toolName: toolName, args: args)
        }
    }

    // MARK: Tool Step

    func toolStepView(
        toolName: String,
        args: [String: AnyCodableValue],
        output: String?,
        isComplete: Bool
    ) -> some View {
        CodeToolStepView(
            toolName: toolName,
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
            Image(systemName: toolIcon(for: toolName))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(toolSummary(toolName: toolName, args: args))
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
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: Helpers

    func toolIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("bash") || lower.contains("shell") {
            return "terminal"
        } else if lower.contains("read") || lower.contains("file") {
            return "doc.text"
        } else if lower.contains("write") || lower.contains("edit") {
            return "pencil"
        } else if lower.contains("search") || lower.contains("grep") {
            return "magnifyingglass"
        } else if lower.contains("web") {
            return "globe"
        }
        return "wrench"
    }

    func toolSummary(
        toolName: String,
        args: [String: AnyCodableValue]
    ) -> String {
        if let command = args["command"],
           case .string(let cmd) = command {
            let first = cmd.components(separatedBy: "\n").first ?? cmd
            return "\(toolName) \(first)"
        }
        if let path = args["file_path"] ?? args["path"],
           case .string(let filePath) = path {
            let name = (filePath as NSString).lastPathComponent
            return "\(toolName) \(name)"
        }
        return toolName
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

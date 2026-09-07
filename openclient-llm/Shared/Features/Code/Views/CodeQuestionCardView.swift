//
//  CodeQuestionCardView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

/// iOS-only centered question card. Presented by `CodeSessionView` over a
/// dimmed background; only the X dismisses (sends abort to pi).
struct CodeQuestionCardView: View {
    // MARK: - Properties

    let question: CodeViewModel.PendingQuestion
    let onAnswer: (String, [CodeAnswer]) -> Void
    let onDismiss: () -> Void

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            header

            CodeQuestionContent(
                question: question,
                onAnswer: onAnswer
            )
        }
        .frame(maxWidth: 480)
        .frame(height: 440)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Private

private extension CodeQuestionCardView {
    var header: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                String(localized: "Dismiss")
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    var title: String {
        question.params.questions.count > 1
            ? String(localized: "Questionnaire")
            : String(localized: "Question")
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.4)
        CodeQuestionCardView(
            question: .init(
                id: "q1",
                params: CodeQuestionParams(
                    questions: [
                        CodeSubQuestion(
                            id: "Q1",
                            label: nil,
                            prompt: "Which authentication method?",
                            options: [
                                CodeQuestionOption(
                                    label: "OAuth 2.0",
                                    description: "Standard OAuth flow"
                                ),
                                CodeQuestionOption(
                                    label: "API Key",
                                    description: "Simple API key auth"
                                ),
                            ],
                            allowOther: nil
                        ),
                    ]
                )
            ),
            onAnswer: { _, _ in },
            onDismiss: {}
        )
        .padding(24)
    }
}

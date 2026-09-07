//
//  CodeQuestionModal.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

/// Question modal for macOS, presented as a `.sheet()`.
/// On iOS the session view shows `CodeQuestionCardView` instead.
struct CodeQuestionModal: View {
    // MARK: - Properties

    let question: CodeViewModel.PendingQuestion
    let onAnswer: (String, [CodeAnswer]) -> Void
    let onDismiss: () -> Void

    // MARK: - View

    var body: some View {
        NavigationStack {
            CodeQuestionContent(
                question: question,
                onAnswer: onAnswer
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(
                        String(localized: "Dismiss")
                    )
                }
            }
            .navigationTitle(title)
            .accessibilityAddTraits(.isModal)
        }
    }
}

// MARK: - Private

private extension CodeQuestionModal {
    var title: String {
        question.params.questions.count > 1
            ? String(localized: "Questionnaire")
            : String(localized: "Question")
    }
}

#Preview("Single Question") {
    CodeQuestionModal(
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
}

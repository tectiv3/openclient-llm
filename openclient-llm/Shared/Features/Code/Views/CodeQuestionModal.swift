//
//  CodeQuestionModal.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

/// Question modal for macOS, presented as a `.sheet()`.
/// On iOS the session view shows `CodeQuestionCardView` instead.
struct CodeQuestionModal: View {
    // MARK: - Properties

    let question: CodeViewModel.PendingQuestion
    let onAnswer: (String, String, Bool, Int?) -> Void
    let onAnswerQuestionnaire: (
        String, [CodeQuestionnaireAnswer]
    ) -> Void
    let onDismiss: () -> Void

    // MARK: - View

    var body: some View {
        NavigationStack {
            CodeQuestionContent(
                question: question,
                onAnswer: onAnswer,
                onAnswerQuestionnaire: onAnswerQuestionnaire
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
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .accessibilityAddTraits(.isModal)
        }
    }
}

// MARK: - Private

private extension CodeQuestionModal {
    var title: String {
        switch question.kind {
        case .question:
            return String(localized: "Question")
        case .questionnaire:
            return String(localized: "Questionnaire")
        }
    }
}

#Preview("Single Question") {
    CodeQuestionModal(
        question: .init(
            id: "q1",
            kind: .question(CodeQuestionParams(
                question: "Which authentication method?",
                options: [
                    CodeQuestionOption(
                        label: "OAuth 2.0",
                        description: "Standard OAuth flow"
                    ),
                    CodeQuestionOption(
                        label: "API Key",
                        description: "Simple API key auth"
                    ),
                ]
            ))
        ),
        onAnswer: { _, _, _, _ in },
        onAnswerQuestionnaire: { _, _ in },
        onDismiss: {}
    )
}

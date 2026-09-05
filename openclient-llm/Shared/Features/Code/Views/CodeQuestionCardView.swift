//
//  CodeQuestionCardView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

/// iOS-only centered question card. Presented by `CodeSessionView` over a
/// dimmed background; only the X dismisses (sends abort to pi).
struct CodeQuestionCardView: View {
    // MARK: - Properties

    let question: CodeViewModel.PendingQuestion
    let onAnswer: (String, String, Bool, Int?) -> Void
    let onAnswerQuestionnaire: (
        String, [CodeQuestionnaireAnswer]
    ) -> Void
    let onDismiss: () -> Void

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            header

            CodeQuestionContent(
                question: question,
                onAnswer: onAnswer,
                onAnswerQuestionnaire: onAnswerQuestionnaire
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
        switch question.kind {
        case .question:
            return String(localized: "Question")
        case .questionnaire:
            return String(localized: "Questionnaire")
        }
    }
}

#Preview {
    ZStack {
        Color.black.opacity(0.4)
        CodeQuestionCardView(
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
        .padding(24)
    }
}

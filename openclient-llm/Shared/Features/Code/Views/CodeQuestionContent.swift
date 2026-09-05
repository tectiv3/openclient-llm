//
//  CodeQuestionContent.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

/// Question/questionnaire form content shared by the macOS sheet
/// (`CodeQuestionModal`) and the iOS centered card (`CodeQuestionCardView`).
struct CodeQuestionContent: View {
    // MARK: - Properties

    let question: CodeViewModel.PendingQuestion
    let onAnswer: (String, String, Bool, Int?) -> Void
    let onAnswerQuestionnaire: (
        String, [CodeQuestionnaireAnswer]
    ) -> Void

    // MARK: - View

    var body: some View {
        Group {
            switch question.kind {
            case .question(let params):
                SingleQuestionView(
                    questionId: question.id,
                    params: params,
                    onAnswer: onAnswer
                )

            case .questionnaire(let params):
                QuestionnaireView(
                    questionId: question.id,
                    params: params,
                    onAnswerQuestionnaire: onAnswerQuestionnaire
                )
            }
        }
    }
}

// MARK: - Single Question

private struct SingleQuestionView: View {
    let questionId: String
    let params: CodeQuestionParams
    let onAnswer: (String, String, Bool, Int?) -> Void

    @State private var customText = ""
    @State private var isCustomExpanded = false
    @FocusState private var isCustomFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(params.question)
                    .font(.headline)
                    .padding(.top, 8)

                VStack(spacing: 0) {
                    ForEach(
                        Array(params.options.enumerated()),
                        id: \.offset
                    ) { index, option in
                        optionRow(option, index: index)

                        if index < params.options.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }

                    if params.allowOther != false {
                        Divider()
                            .padding(.leading, 16)
                        customInputRow
                    }
                }
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 16)
                )
            }
            .padding(.horizontal, 20)
        }
    }

    func optionRow(
        _ option: CodeQuestionOption,
        index: Int
    ) -> some View {
        Button {
            onAnswer(
                questionId,
                option.label,
                false,
                index
            )
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if let desc = option.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
    }

    var customInputRow: some View {
        VStack(spacing: 0) {
            if isCustomExpanded {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "Type something..."),
                        text: $customText,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .focused($isCustomFocused)
                    .onSubmit {
                        submitCustom()
                    }

                    Button {
                        submitCustom()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(
                                customText.isEmpty
                                    ? .secondary
                                    : Color.appAccent
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(customText.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                Button {
                    isCustomExpanded = true
                    isCustomFocused = true
                } label: {
                    HStack {
                        Text(String(localized: "Type something..."))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    String(localized: "Double tap to enter a custom answer")
                )
            }
        }
    }

    func submitCustom() {
        let text = customText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else { return }
        onAnswer(questionId, text, true, nil)
    }
}

// MARK: - Questionnaire

private struct QuestionnaireView: View {
    let questionId: String
    let params: CodeQuestionnaireParams
    let onAnswerQuestionnaire: (
        String, [CodeQuestionnaireAnswer]
    ) -> Void

    @State private var currentPage = 0
    @State private var answers: [String: String] = [:]
    @State private var customTexts: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            pageHeader

            TabView(selection: $currentPage) {
                ForEach(
                    Array(params.questions.enumerated()),
                    id: \.offset
                ) { index, question in
                    questionPage(question, index: index)
                        .tag(index)
                }
            }
#if os(iOS)
            .tabViewStyle(.page(indexDisplayMode:
                params.questions.count >= 7
                    ? .never
                    : .automatic
            ))
#endif

            if currentPage == params.questions.count - 1 {
                submitButton
            }
        }
    }

    var pageHeader: some View {
        HStack {
            Button {
                withAnimation {
                    currentPage = max(0, currentPage - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(
                        currentPage > 0 ? .primary : .tertiary
                    )
            }
            .disabled(currentPage == 0)
            .buttonStyle(.plain)

            Spacer()

            Text(String(localized: "\(currentPage + 1) of \(params.questions.count)"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                withAnimation {
                    currentPage = min(
                        params.questions.count - 1,
                        currentPage + 1
                    )
                }
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(
                        currentPage < params.questions.count - 1
                            ? .primary
                            : .tertiary
                    )
            }
            .disabled(currentPage >= params.questions.count - 1)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    func questionPage(
        _ question: CodeSubQuestion,
        index: Int
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(question.prompt)
                    .font(.headline)
                    .padding(.top, 8)

                VStack(spacing: 0) {
                    ForEach(
                        Array(question.options.enumerated()),
                        id: \.offset
                    ) { optIndex, option in
                        questionnaireOptionRow(
                            option,
                            questionId: question.id,
                            isSelected: answers[question.id]
                                == option.label
                        )

                        if optIndex < question.options.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 16)
                )

                if question.allowOther != false {
                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "Type something..."),
                            text: customTextBinding(for: question.id),
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        Button {
                            let text = (customTexts[question.id] ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            answers[question.id] = text
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                                .foregroundStyle(
                                    (customTexts[question.id] ?? "").isEmpty
                                        ? .secondary
                                        : Color.appAccent
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 20)
        }
    }

    func customTextBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { customTexts[questionId] ?? "" },
            set: { customTexts[questionId] = $0 }
        )
    }

    func questionnaireOptionRow(
        _ option: CodeQuestionOption,
        questionId: String,
        isSelected: Bool
    ) -> some View {
        Button {
            answers[questionId] = option.label
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if let desc = option.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.appAccent)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var submitButton: some View {
        Button {
            let questionnaireAnswers = params.questions.compactMap {
                question -> CodeQuestionnaireAnswer? in
                guard let selected = answers[question.id]
                else { return nil }
                let index = question.options.firstIndex {
                    $0.label == selected
                }
                return CodeQuestionnaireAnswer(
                    id: question.id,
                    value: selected,
                    label: selected,
                    wasCustom: index == nil,
                    index: index
                )
            }
            onAnswerQuestionnaire(questionId, questionnaireAnswers)
        } label: {
            Text(String(localized: "Submit"))
                .frame(maxWidth: 200)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!allQuestionsAnswered)
        .padding(.vertical, 12)
    }

    var allQuestionsAnswered: Bool {
        params.questions.allSatisfy { answers[$0.id] != nil }
    }
}

#Preview {
    CodeQuestionContent(
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
        onAnswerQuestionnaire: { _, _ in }
    )
    .frame(height: 300)
}

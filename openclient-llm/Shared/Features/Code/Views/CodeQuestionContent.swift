//
//  CodeQuestionContent.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

/// Question form content shared by the macOS sheet (`CodeQuestionModal`) and
/// the iOS centered card (`CodeQuestionCardView`). One rendering path for the
/// unified ask: a single question renders a simple option list, multiple
/// questions render the tabbed form with a submit button.
struct CodeQuestionContent: View {
    // MARK: - Properties

    let question: CodeViewModel.PendingQuestion
    let onAnswer: (String, [CodeAnswer]) -> Void

    // MARK: - View

    var body: some View {
        let questions = question.params.questions
        if questions.count == 1, let first = questions.first {
            SingleQuestionView(
                questionId: question.id,
                sub: first,
                onAnswer: onAnswer
            )
        } else {
            QuestionnaireView(
                questionId: question.id,
                questions: questions,
                onAnswer: onAnswer
            )
        }
    }
}

// MARK: - Single Question

private struct SingleQuestionView: View {
    let questionId: String
    let sub: CodeSubQuestion
    let onAnswer: (String, [CodeAnswer]) -> Void

    @State private var customText = ""
    @State private var isCustomExpanded = false
    @FocusState private var isCustomFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(sub.prompt)
                    .font(.headline)
                    .padding(.top, 8)

                VStack(spacing: 0) {
                    ForEach(
                        Array(sub.options.enumerated()),
                        id: \.offset
                    ) { index, option in
                        optionRow(option, index: index)

                        if index < sub.options.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }

                    if sub.resolvedAllowOther {
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
                [
                    CodeAnswer(
                        id: sub.id,
                        value: option.resolvedValue,
                        label: option.label,
                        wasCustom: false,
                        index: index + 1
                    ),
                ]
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
                // The first option is the preselected default.
                if index == 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.appAccent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
                    .lineLimit(1 ... 3)
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
        onAnswer(
            questionId,
            [
                CodeAnswer(
                    id: sub.id,
                    value: text,
                    label: text,
                    wasCustom: true,
                    index: nil
                ),
            ]
        )
    }
}

// MARK: - Questionnaire (multiple questions)

private struct QuestionnaireView: View {
    let questionId: String
    let questions: [CodeSubQuestion]
    let onAnswer: (String, [CodeAnswer]) -> Void

    @State private var currentPage = 0
    @State private var answers: [String: String] = [:]
    @State private var customTexts: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            pageHeader

            TabView(selection: $currentPage) {
                ForEach(
                    Array(questions.enumerated()),
                    id: \.offset
                ) { index, question in
                    questionPage(question)
                        .tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode:
                questions.count >= 7
                    ? .never
                    : .automatic))
            #endif

            if currentPage == questions.count - 1 {
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

            Text(String(localized: "\(currentPage + 1) of \(questions.count)"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                withAnimation {
                    currentPage = min(
                        questions.count - 1,
                        currentPage + 1
                    )
                }
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(
                        currentPage < questions.count - 1
                            ? .primary
                            : .tertiary
                    )
            }
            .disabled(currentPage >= questions.count - 1)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    func questionPage(_ question: CodeSubQuestion) -> some View {
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
                                == option.resolvedValue
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

                if question.resolvedAllowOther {
                    HStack(spacing: 8) {
                        TextField(
                            String(localized: "Type something..."),
                            text: customTextBinding(for: question.id),
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .lineLimit(1 ... 3)
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
            answers[questionId] = option.resolvedValue
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
            let submitted = questions.compactMap {
                question -> CodeAnswer? in
                guard let selected = answers[question.id]
                else { return nil }
                let index = question.options.firstIndex {
                    $0.resolvedValue == selected
                }
                let label = index.map {
                    question.options[$0].label
                } ?? selected
                return CodeAnswer(
                    id: question.id,
                    value: selected,
                    label: label,
                    wasCustom: index == nil,
                    index: index.map { $0 + 1 }
                )
            }
            onAnswer(questionId, submitted)
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
        questions.allSatisfy { answers[$0.id] != nil }
    }
}

#Preview("Single Question") {
    CodeQuestionContent(
        question: .init(
            id: "q1",
            params: CodeQuestionParams(
                questions: [
                    CodeSubQuestion(
                        id: "Q1",
                        label: "Q1",
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
        onAnswer: { _, _ in }
    )
    .frame(height: 300)
}

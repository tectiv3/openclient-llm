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

                    // Nothing is preselected until a tap; the first option is
                    // only visually marked as the recommended one.
                    if index == 0 {
                        Text(String(localized: "Recommended"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

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
        .accessibilityLabel(
            index == 0 ? option.label + ", " + String(localized: "Recommended") : option.label
        )
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
    /// question.id → selected value; a value matching no option's
    /// `resolvedValue` is a custom answer.
    @State private var answers: [String: String] = [:]
    @State private var customTexts: [String: String] = [:]
    @State private var expandedCustom: Set<String> = []
    @FocusState private var focusedCustom: String?

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
                        optionRow(
                            option,
                            questionId: question.id
                        )

                        if optIndex < question.options.count - 1 {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }

                    if question.resolvedAllowOther {
                        Divider()
                            .padding(.leading, 16)
                        customRow(for: question)
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

    func customTextBinding(for questionId: String) -> Binding<String> {
        Binding(
            get: { customTexts[questionId] ?? "" },
            set: { customTexts[questionId] = $0 }
        )
    }

    /// Selection is a toggle: a second tap on the selected option
    /// deselects it.
    func optionRow(
        _ option: CodeQuestionOption,
        questionId: String
    ) -> some View {
        let isSelected = answers[questionId] == option.resolvedValue
        return Button {
            if isSelected {
                answers.removeValue(forKey: questionId)
            } else {
                answers[questionId] = option.resolvedValue
                expandedCustom.remove(questionId)
                if focusedCustom == questionId {
                    focusedCustom = nil
                }
            }
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

                selectionIndicator(isSelected: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func selectionIndicator(isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.appAccent)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }

    /// Custom-answer row, last row inside the card. Collapsed shows the
    /// submitted custom answer (or the placeholder); expanded shows the
    /// TextField + submit arrow. Selection is derived, so a typed-but-
    /// unsubmitted edit immediately drops the checkmark.
    func customRow(for question: CodeSubQuestion) -> some View {
        let isSelected = isCustomSelected(question)
        return Group {
            if expandedCustom.contains(question.id) {
                HStack(spacing: 8) {
                    TextField(
                        String(localized: "Type something..."),
                        text: customTextBinding(for: question.id),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 3)
                    .focused($focusedCustom, equals: question.id)
                    .onSubmit {
                        submitCustom(for: question.id)
                    }

                    Button {
                        submitCustom(for: question.id)
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
                    .disabled(
                        (customTexts[question.id] ?? "")
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            .isEmpty
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                Button {
                    expandedCustom.insert(question.id)
                    focusedCustom = question.id
                } label: {
                    HStack {
                        if isSelected, let answer = answers[question.id] {
                            Text(answer)
                                .foregroundStyle(.primary)
                        } else {
                            Text(String(localized: "Type something..."))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        selectionIndicator(isSelected: isSelected)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Type something"))
                .accessibilityHint(
                    String(localized: "Double tap to enter a custom answer")
                )
            }
        }
        .onChange(of: customTexts[question.id] ?? "") { _, newValue in
            // Clearing the text deselects a submitted custom answer so the
            // form cannot submit a stale selection.
            guard newValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                let selected = answers[question.id],
                !question.options.contains(where: {
                    $0.resolvedValue == selected
                })
            else { return }
            answers.removeValue(forKey: question.id)
        }
    }

    /// The custom row counts as selected only when the stored answer is a
    /// custom value (matches no option) and still equals the typed text.
    func isCustomSelected(_ question: CodeSubQuestion) -> Bool {
        guard let selected = answers[question.id],
              !question.options.contains(where: {
                  $0.resolvedValue == selected
              })
        else { return false }
        let text = (customTexts[question.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selected == text
    }

    func submitCustom(for questionId: String) {
        let text = (customTexts[questionId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answers[questionId] = text
        expandedCustom.remove(questionId)
        focusedCustom = nil
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

#Preview("Questionnaire") {
    CodeQuestionContent(
        question: .init(
            id: "q2",
            params: CodeQuestionParams(
                questions: [
                    CodeSubQuestion(
                        id: "Q1",
                        label: "Q1",
                        prompt: "Which language?",
                        options: [
                            CodeQuestionOption(label: "Swift"),
                            CodeQuestionOption(label: "TypeScript"),
                        ],
                        allowOther: true
                    ),
                    CodeSubQuestion(
                        id: "Q2",
                        label: "Q2",
                        prompt: "How urgent?",
                        options: [
                            CodeQuestionOption(
                                label: "Now",
                                description: "Drop everything"
                            ),
                            CodeQuestionOption(label: "This week"),
                        ],
                        allowOther: false
                    ),
                    CodeSubQuestion(
                        id: "Q3",
                        label: "Q3",
                        prompt: "Add tests?",
                        options: [
                            CodeQuestionOption(label: "Yes"),
                            CodeQuestionOption(label: "No"),
                        ],
                        allowOther: nil
                    ),
                ]
            )
        ),
        onAnswer: { _, _ in }
    )
    .frame(height: 420)
}

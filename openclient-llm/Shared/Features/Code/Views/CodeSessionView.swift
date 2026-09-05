//
//  CodeSessionView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct CodeSessionView: View {
    // MARK: - Properties

    let session: CodeViewModel.SessionState
    let viewModel: CodeViewModel
    var isReconnecting: Bool = false

    @State private var inputText: String = ""
    @State private var shouldAutoScroll: Bool = true
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)
    @State private var scrollToMessageId: UUID?
    @State private var isManuallyScrolling: Bool = false
    @State private var scrollEdgeMetrics = ScrollEdgeMetrics()

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            if isReconnecting {
                reconnectingBanner
            }

            if let usage = contextUsage {
                ContextUsageView(usage: usage)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
            }

            if session.items.isEmpty {
                emptyState
            } else {
                transcript
            }

            CodeInputBarView(
                inputText: $inputText,
                isStreaming: session.isStreaming,
                isDisabled: isReconnecting,
                onSend: handleSend,
                onStop: { viewModel.send(.abort) }
            )
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                headerContent
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.send(.disconnect)
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(
                    String(localized: "Disconnect")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if !shouldAutoScroll && !session.items.isEmpty {
                jumpToBottomButton
            }
        }
        .sheet(item: pendingQuestion) { question in
            CodeQuestionModal(
                question: question,
                onAnswer: { id, value, wasCustom, index in
                    viewModel.send(.answer(
                        id: id, value: value,
                        wasCustom: wasCustom, index: index
                    ))
                },
                onAnswerQuestionnaire: { id, answers in
                    viewModel.send(.answerQuestionnaire(
                        id: id, answers: answers
                    ))
                },
                onDismiss: {
                    viewModel.send(.abort)
                }
            )
#if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
#endif
        }
    }
}

// MARK: - Private

private extension CodeSessionView {
    var pendingQuestion: Binding<CodeViewModel.PendingQuestion?> {
        Binding(
            get: { session.pendingQuestion },
            set: { _ in }
        )
    }

    var contextUsage: ContextUsage? {
        guard let usage = session.contextUsage else { return nil }
        return ContextUsage(
            estimatedInputTokens: usage.used,
            maxInputTokens: usage.total
        )
    }

    // MARK: - Header

    var headerContent: some View {
        HStack(spacing: 8) {
            statusDot
                .accessibilityLabel(
                    isReconnecting
                        ? String(localized: "Reconnecting")
                        : String(localized: "Connected")
                )

            VStack(spacing: 2) {
                Text(truncatedCwd)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let model = session.model {
                    Text(model.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    var statusDot: some View {
        Circle()
            .fill(isReconnecting ? Color.orange : Color.green)
            .frame(width: 8, height: 8)
    }

    var truncatedCwd: String {
        let components = session.cwd.split(separator: "/")
        if components.count <= 2 {
            return session.cwd.isEmpty
                ? String(localized: "Connected")
                : session.cwd
        }
        let last2 = components.suffix(2).joined(separator: "/")
        return "~/\(last2)"
    }

    // MARK: - Reconnecting

    var reconnectingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "Reconnecting..."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect(
            .regular.tint(.orange.opacity(0.3)),
            in: .rect(cornerRadius: 12)
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 32))
                .foregroundStyle(Color.appAccent)
                .frame(width: 64, height: 64)
                .glassEffect(.regular, in: .circle)

            Text(String(localized: "Connected to pi"))
                .font(.title3)
                .fontWeight(.semibold)

            if !session.cwd.isEmpty {
                Text(truncatedCwd)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let model = session.model {
                Text(model.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }

            Text(String(localized: "Send a message or use pi directly — activity will appear here."))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transcript

    var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(session.items) { item in
                    CodeTranscriptItemView(item: item)
                        .id(item.id)
                        .transition(.opacity)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.bottom, 15)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .modifier(ScrollTriggerModifier(
            scrollPosition: $scrollPosition,
            scrollToMessageId: $scrollToMessageId,
            shouldAutoScroll: $shouldAutoScroll,
            isManuallyScrolling: $isManuallyScrolling,
            messageCount: session.items.count,
            contentTrigger: session.items.last?.id,
            sessionId: session.sessionId,
            isAtBottom: scrollEdgeMetrics.isAtBottom
        ))
        .onScrollGeometryChange(for: ScrollEdgeMetrics.self) { geometry in
            let bottomDistance = geometry.contentSize.height
                - geometry.contentOffset.y
                - geometry.containerSize.height
            return ScrollEdgeMetrics(
                isNearBottom: bottomDistance < 150,
                isAtBottom: bottomDistance < 8,
                isNearTop: geometry.contentOffset.y < 150
            )
        } action: { _, newValue in
            scrollEdgeMetrics = newValue
        }
    }

    var jumpToBottomButton: some View {
        Button {
            shouldAutoScroll = true
            if let lastId = session.items.last?.id {
                scrollToMessageId = lastId
            }
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Actions

    func handleSend() {
        let text = inputText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else { return }
        inputText = ""

        if session.isStreaming {
            viewModel.send(.sendSteer(text: text))
        } else {
            viewModel.send(.sendPrompt(text: text))
        }
        shouldAutoScroll = true
    }
}

#Preview {
    NavigationStack {
        CodeSessionView(
            session: .init(
                sessionId: "test",
                cwd: "/Users/dev/code/myproject",
                model: CodeModelInfo(
                    provider: "anthropic",
                    id: "claude-sonnet-5"
                )
            ),
            viewModel: CodeViewModel()
        )
    }
}

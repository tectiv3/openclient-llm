//
//  CodeSessionView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeSessionView: View {
    // MARK: - Properties

    let session: CodeViewModel.SessionState
    let viewModel: CodeViewModel
    var onBack: () -> Void = {}
    var isReconnecting: Bool = false

    @State private var inputText: String = ""
    @State private var shouldAutoScroll: Bool = true
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)
    @State private var scrollToMessageId: UUID?
    @State private var isManuallyScrolling: Bool = false
    @State private var scrollEdgeMetrics = ScrollEdgeMetrics()
    @State private var showReconnectSuccess = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            if isReconnecting {
                reconnectingBanner
            } else if showReconnectSuccess {
                reconnectedBanner
                    .transition(.opacity)
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
                isQuestionPresented: session.pendingQuestion != nil,
                onSend: handleSend,
                onStop: { viewModel.send(.abort) }
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(
                    String(localized: "Back")
                )
            }

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
        .overlay(alignment: .top) {
            if let toast = viewModel.transientToast {
                toastView(toast)
            }
        }
        #if os(iOS)
        // iOS: centered card over a dimmed background (macOS keeps .sheet).
        .overlay {
            questionCardOverlay
        }
        #endif
        #if os(macOS)
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
            .frame(width: 480, height: 520)
        }
        #endif
        .animation(
            reduceMotion ? nil : .spring(duration: 0.3),
            value: viewModel.transientToast
        )
        .onChange(of: isReconnecting) { _, reconnecting in
            guard !reconnecting else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                showReconnectSuccess = true
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    showReconnectSuccess = false
                }
            }
        }
        .task(id: viewModel.transientToast) {
            guard viewModel.transientToast != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            viewModel.send(.clearToast)
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

    // MARK: - Question Modal (iOS card)

    @ViewBuilder
    var questionCardOverlay: some View {
        if let question = session.pendingQuestion {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                CodeQuestionCardView(
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
                .padding(24)
            }
        }
    }

    var contextUsage: ContextUsage? {
        guard let usage = session.contextUsage else { return nil }
        return ContextUsage(
            estimatedInputTokens: usage.tokens,
            maxInputTokens: usage.contextWindow
        )
    }

    var scrollContentTrigger: Int {
        guard let last = session.items.last else { return 0 }
        switch last {
        case let .assistant(id, content, _):
            var hasher = Hasher()
            hasher.combine(id)
            for block in content {
                switch block {
                case let .text(text): hasher.combine(text.count)
                case let .thinking(text): hasher.combine(text.count)
                case let .toolUse(tcId, _, _, _): hasher.combine(tcId)
                case .unknown: break
                }
            }
            return hasher.finalize()
        case let .toolStep(id, _, _, _, output, _):
            var hasher = Hasher()
            hasher.combine(id)
            hasher.combine(output?.count)
            return hasher.finalize()
        default:
            return last.id.hashValue
        }
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
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
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

    var reconnectedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Text(String(localized: "Reconnected"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect(
            .regular.tint(.green.opacity(0.3)),
            in: .rect(cornerRadius: 12)
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Toast

    func toastView(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                // Announce to VoiceOver: transient toast that appears and dismisses
                AccessibilityNotification.Announcement(message).post()
            }
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
                    CodeTranscriptItemView(
                        item: item,
                        onRetry: { id in
                            viewModel.send(.retryPrompt(id: id))
                        }
                    )
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
            contentTrigger: scrollContentTrigger,
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

//
//  CodeSessionView+Panels.swift
//  openclient-llm
//
//  Created by tectiv3 on 11/09/2026.
//

import SwiftUI

// Display-only panels of CodeSessionView (header, status banners, toast,
// empty state, the iOS question card, confirm-dialog messages). Split out
// of CodeSessionView.swift to keep that file under the SwiftLint
// file_length limit; none of this touches the view's @State, so a plain
// (non-private) extension works.

extension CodeSessionView {
    // MARK: - Question Binding

    var pendingQuestion: Binding<CodeViewModel.PendingQuestion?> {
        Binding(
            get: { session.pendingQuestion },
            set: { newValue in
                if newValue == nil {
                    viewModel.send(.abort)
                }
            }
        )
    }

    // MARK: - Dialog Messages

    var newSessionConfirmMessage: String {
        session.isStreaming || session.compacting != nil
            ? String(localized: "The in-flight run will be aborted.")
            : String(localized: "The current session will be replaced.")
    }

    var compactConfirmMessage: String {
        session.isStreaming
            ? String(localized: "The in-flight run will be aborted before compacting.")
            : String(localized: "Summarize the transcript to free context space.")
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
                    onAnswer: { id, answers in
                        viewModel.send(.answer(id: id, answers: answers))
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

    var identityHeader: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.sessionName.isEmpty ? truncatedCwd : session.sessionName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if !session.sessionName.isEmpty {
                    Text(truncatedCwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let model = session.model {
                Text(model.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
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

    // MARK: - Compacting

    var compactingBanner: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Compacting context…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Compacting context"))

            Spacer()

            Button {
                viewModel.send(.abort)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body)
                    .foregroundStyle(.red)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Stop compaction"))
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

            if !session.sessionName.isEmpty || !session.cwd.isEmpty {
                Text(session.sessionName.isEmpty ? truncatedCwd : session.sessionName)
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
}

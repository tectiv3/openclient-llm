//
//  CodeSubagentAttachView.swift
//  openclient-llm
//
//  Feature B (docs/plans/2026-09-13-rc-subagent-attach-stop-ux.md): the
//  fullscreen view of an attached pi subagent run. It renders the run's
//  OWN item array (not the main transcript), streamed by the shared
//  transcript item view. The view stays open on settle (finished state);
//  closing it sends the explicit detach.

import SwiftUI
#if os(iOS)
    import UIKit
#endif

struct CodeSubagentAttachView: View {
    // `attached` is the LIVE attach state re-read from the session on each
    // render (the fullScreenCover closure keeps the session in scope); the
    // presentation-time copy is only the fallback.
    let attached: CodeViewModel.AttachedSubagent
    let isConnecting: Bool
    let onDetach: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header

            if attached.items.isEmpty {
                emptyOrConnecting
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
            }

            if !attached.running {
                settledBar
            }
        }
        .onAppear(perform: hapticOnOpen)
    }
}

// MARK: - Private

private extension CodeSubagentAttachView {
    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(attached.info.agent)
                    .font(.headline)

                Spacer()

                if attached.running {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    hapticOnClose()
                    onDetach(attached.info.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(String(localized: "Close subagent view"))
            }

            Text(attached.info.task)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 8) {
                if let model = attached.info.model, !model.isEmpty {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(startedAtText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    var startedAtText: String {
        guard let date = Date(iso8601: attached.info.startedAt) else {
            return attached.info.startedAt
        }
        return date.formatted(.dateTime.hour().minute())
    }

    var emptyOrConnecting: some View {
        VStack(spacing: 12) {
            if isConnecting {
                ProgressView()
                Text(String(localized: "Connecting to run…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(String(localized: "No output yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(attached.items) { item in
                    CodeTranscriptItemView(item: item)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
    }

    var settledBar: some View {
        HStack(spacing: 8) {
            Image(systemName: settledIcon)
                .font(.caption)
                .foregroundStyle(settledColor)

            Text(settledText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(String(localized: "Close")) {
                hapticOnClose()
                onDetach(attached.info.id)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    var settledIcon: String {
        if attached.settledStatus == "failed" {
            return "xmark.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    var settledColor: Color {
        attached.settledStatus == "failed" ? .red : Color.appAccent
    }

    var settledText: String {
        if let status = attached.settledStatus {
            var text = String(localized: "Finished — \(status)")
            if let reason = attached.settledStopReason, !reason.isEmpty {
                text += " (\(reason))"
            }
            return text
        }
        return String(localized: "Finished")
    }

    func hapticOnOpen() {
        #if os(iOS)
            guard !reduceMotion else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    func hapticOnClose() {
        #if os(iOS)
            guard !reduceMotion else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

// MARK: - ISO8601 Date Helper

private extension Date {
    init?(iso8601: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso8601)
            ?? ISO8601DateFormatter().date(from: iso8601)
        else { return nil }
        self = date
    }
}

// MARK: - Previews

#Preview("Running") {
    CodeSubagentAttachView(
        attached: .init(
            info: .init(
                id: "run-1",
                agent: "plan-critic",
                task: "Critique the streaming buffer design for race conditions.",
                startedAt: "2026-09-13T10:15:00.000Z",
                toolCallId: "tc-9",
                model: "qwen3.8-27b"
            ),
            items: [
                .assistant(
                    id: UUID(),
                    content: [.text("Checking the merge semantics…")],
                    isStreaming: true
                ),
                .toolStep(
                    id: UUID(),
                    toolName: "bash", toolCallId: "tc-9.1",
                    args: ["command": .string("swift test")],
                    output: "All tests passed", isComplete: true
                ),
            ],
            running: true
        ),
        isConnecting: false
    ) { _ in }
}

#Preview("Connecting") {
    CodeSubagentAttachView(
        attached: .init(
            info: .init(
                id: "run-2",
                agent: "researcher",
                task: "Find the LiteLLM proxy docs for the fallback chain.",
                startedAt: "2026-09-13T10:16:00.000Z",
                toolCallId: nil,
                model: nil
            )
        ),
        isConnecting: true
    ) { _ in }
}

#Preview("Settled") {
    CodeSubagentAttachView(
        attached: .init(
            info: .init(
                id: "run-3",
                agent: "plan-critic",
                task: "Critique the streaming buffer design.",
                startedAt: "2026-09-13T10:15:00.000Z",
                toolCallId: "tc-9",
                model: nil
            ),
            items: [
                .assistant(
                    id: UUID(),
                    content: [.text("No blocking issues. Two minor notes…")],
                    isStreaming: false
                ),
            ],
            running: false,
            settledStatus: "succeeded",
            settledStopReason: "stop"
        ),
        isConnecting: false
    ) { _ in }
}

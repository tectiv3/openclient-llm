//
//  CodeInputBarView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct CodeInputBarView: View {
    // MARK: - Properties

    @Binding var inputText: String
    let isStreaming: Bool
    var isDisabled: Bool = false
    let onSend: () -> Void
    let onStop: () -> Void

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                TextField(
                    isStreaming
                        ? String(localized: "Steer pi...")
                        : String(localized: "Message pi..."),
                    text: $inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .textSelection(.enabled)
                .lineLimit(1...5)
#if os(iOS)
                .submitLabel(.send)
#endif
                .onSubmit {
                    inputText = ""
                    onSend()
                }
                .disabled(isDisabled)

                actionButtons
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .glassEffect(
            isStreaming
                ? .regular.tint(Color.appAccent.opacity(0.3))
                : .regular,
            in: .rect(cornerRadius: 25)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .opacity(isDisabled ? 0.5 : 1.0)
        .allowsHitTesting(!isDisabled)
        .accessibilityValue(
            isStreaming
                ? String(localized: "Steer mode")
                : String(localized: "Prompt mode")
        )
    }
}

// MARK: - Private

private extension CodeInputBarView {
    @ViewBuilder
    var actionButtons: some View {
        let hasText = !inputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        // Streaming: Stop (abort) and Send (steer) coexist; the send button
        // only appears while there is text to steer with.
        if isStreaming {
            stopButton
            if hasText {
                sendButton
            }
        } else if hasText {
            sendButton
        }
    }

    var sendButton: some View {
        Button {
            inputText = ""
            onSend()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.appAccent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Send"))
        .transition(.scale.combined(with: .opacity))
    }

    var stopButton: some View {
        Button { onStop() } label: {
            Image(systemName: "square.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Stop"))
        .transition(.scale.combined(with: .opacity))
    }
}

#Preview("Idle") {
    CodeInputBarView(
        inputText: .constant(""),
        isStreaming: false,
        onSend: {},
        onStop: {}
    )
}

#Preview("Streaming") {
    CodeInputBarView(
        inputText: .constant(""),
        isStreaming: true,
        onSend: {},
        onStop: {}
    )
}

#Preview("Streaming with steer") {
    CodeInputBarView(
        inputText: .constant("focus on tests"),
        isStreaming: true,
        onSend: {},
        onStop: {}
    )
}

#Preview("Disabled") {
    CodeInputBarView(
        inputText: .constant(""),
        isStreaming: false,
        isDisabled: true,
        onSend: {},
        onStop: {}
    )
}

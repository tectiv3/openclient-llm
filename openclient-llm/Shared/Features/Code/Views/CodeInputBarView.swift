//
//  CodeInputBarView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeInputBarView: View {
    // MARK: - Properties

    @Binding var inputText: String
    let isStreaming: Bool
    var isDisabled: Bool = false
    var isQuestionPresented: Bool = false
    let onSend: () -> Void

    @FocusState private var inputFocused: Bool

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
                .lineLimit(1 ... 5)
                #if os(iOS)
                    .submitLabel(.send)
                #endif
                    .onSubmit {
                        onSend()
                    }
                    .focused($inputFocused)
                    .disabled(isDisabled)

                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 25))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .opacity(isDisabled ? 0.5 : 1.0)
        .allowsHitTesting(!isDisabled)
        .onChange(of: isQuestionPresented) { _, presented in
            // The question card needs to be fully visible; drop keyboard focus.
            if presented {
                inputFocused = false
            }
        }
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

        // Send/steer is the bar's only button in every state (the Stop
        // affordance lives on the pulsing header status dot). The send
        // button only appears while there is text to send/steer with.
        if hasText {
            sendButton
        }
    }

    var sendButton: some View {
        Button {
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
}

#Preview("Idle") {
    CodeInputBarView(
        inputText: .constant(""),
        isStreaming: false,
        onSend: {}
    )
}

#Preview("Streaming") {
    CodeInputBarView(
        inputText: .constant(""),
        isStreaming: true,
        onSend: {}
    )
}

#Preview("Streaming with steer") {
    CodeInputBarView(
        inputText: .constant("focus on tests"),
        isStreaming: true,
        onSend: {}
    )
}

#Preview("Disabled") {
    CodeInputBarView(
        inputText: .constant(""),
        isStreaming: false,
        isDisabled: true,
        onSend: {}
    )
}

//
//  CodeModelsSheetView.swift
//  openclient-llm
//
//  Created by tectiv3 on 10/09/2026.
//

import SwiftUI

/// Model picker for the Code session, opened from the session toolbar.
/// List and selection refresh automatically: the parent re-renders this
/// sheet with fresh `models`/`selected` on every state frame, so there
/// is no manual refresh control.
struct CodeModelsSheetView: View {
    // MARK: - Properties

    let models: [CodeModelInfo]
    let selected: CodeModelInfo?
    let onSelect: (CodeModelInfo) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - View

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "Models"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) {
                            dismiss()
                        }
                    }
                }
        }
    }
}

// MARK: - Private

private extension CodeModelsSheetView {
    @ViewBuilder
    var content: some View {
        if models.isEmpty {
            ContentUnavailableView {
                Label(
                    String(localized: "No models available"),
                    systemImage: "brain.head.profile"
                )
            }
        } else {
            List(models, id: \.self) { model in
                Button {
                    onSelect(model)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(model.provider)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if model == selected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.appAccent)
                        }
                    }
                }
                .accessibilityHint(
                    String(localized: "Switch the session to this model")
                )
            }
        }
    }
}

#Preview("With models") {
    CodeModelsSheetView(
        models: [
            CodeModelInfo(provider: "pi", id: "qwen3-coder"),
            CodeModelInfo(provider: "anthropic", id: "claude-sonnet-4"),
        ],
        selected: CodeModelInfo(provider: "pi", id: "qwen3-coder"),
        onSelect: { _ in }
    )
}

#Preview("Empty") {
    CodeModelsSheetView(models: [], selected: nil, onSelect: { _ in })
}

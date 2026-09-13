//
//  CodeSessionsSheetView.swift
//  openclient-llm
//
//  Created by tectiv3 on 11/09/2026.
//

import SwiftUI

/// Multi-session picker (docs/plans/rc-multi-session-spec.md, Decision 10):
/// one row per pi session the anchor serves. Tapping a row rebinds the
/// existing session view in place — the sheet only reports the tap.
struct CodeSessionsSheetView: View {
    // MARK: - Properties

    let sessions: [SessionInfo]
    /// Registry `id` of the session the view is currently showing (the
    /// anchor row when nothing is explicitly selected), so the sheet can
    /// mark it. May not appear in `sessions` (stale list) — then nothing
    /// is marked.
    let effectiveSelectedId: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - View

    var body: some View {
        NavigationStack {
            List(sessions, id: \.id) { session in
                Button {
                    onSelect(session.id)
                } label: {
                    rowContent(for: session)
                }
                .accessibilityLabel(accessibilityLabel(for: session))
                .accessibilityHint(
                    String(localized: "Switch the view to this session")
                )
            }
            .navigationTitle(String(localized: "Sessions"))
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

private extension CodeSessionsSheetView {
    func rowContent(for session: SessionInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName(for: session))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if session.isAnchor {
                        badge(
                            String(localized: "anchor"),
                            color: Color.appAccent
                        )
                    }
                }

                Text(cwdBasename(session.cwd))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let model = session.model {
                    Text("\(model.provider)/\(model.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if session.isStreaming {
                    badge(
                        String(localized: "streaming"),
                        color: .green
                    )
                }
                if session.hasQuestion {
                    badge(
                        String(localized: "question"),
                        color: .orange
                    )
                }
                if session.compacting {
                    badge(
                        String(localized: "compacting"),
                        color: .orange
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .foregroundStyle(
            session.id == effectiveSelectedId
                ? Color.appAccent
                : Color.primary
        )
    }

    /// Name as broadcast by the anchor, falling back to the cwd basename
    /// for unnamed sessions (the anchor's own list already carries cwd
    /// basenames as names, but a rename to "" arrives as nil).
    func displayName(for session: SessionInfo) -> String {
        let name = session.name ?? ""
        return name.isEmpty ? cwdBasename(session.cwd) : name
    }

    /// Last path component: `/Users/dev/code/myproject` → `myproject`.
    /// An empty cwd shows as-is (a connected session always has one).
    func cwdBasename(_ cwd: String) -> String {
        let components = cwd.split(separator: "/", omittingEmptySubsequences: true)
        return components.last.map(String.init) ?? cwd
    }

    /// Rows are plain buttons; VoiceOver needs the selection state spelled
    /// out.
    func accessibilityLabel(for session: SessionInfo) -> String {
        var parts: [String] = [displayName(for: session), cwdBasename(session.cwd)]
        if let model = session.model {
            parts.append("\(model.provider)/\(model.id)")
        }
        if session.isAnchor {
            parts.append(String(localized: "anchor"))
        }
        if session.isStreaming {
            parts.append(String(localized: "streaming"))
        }
        if session.hasQuestion {
            parts.append(String(localized: "question"))
        }
        if session.compacting {
            parts.append(String(localized: "compacting"))
        }
        if session.id == effectiveSelectedId {
            parts.append(String(localized: "currently selected"))
        }
        return parts.joined(separator: ", ")
    }

    func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }
}

#Preview("Two sessions") {
    CodeSessionsSheetView(
        sessions: [
            SessionInfo(
                id: "b",
                sessionId: "sess-b",
                cwd: "/Users/dev/code/other",
                name: "other",
                model: CodeModelInfo(provider: "pi", id: "qwen3-coder"),
                isStreaming: true,
                hasQuestion: true,
                compacting: false,
                lastActivity: nil,
                isAnchor: false
            ),
            SessionInfo(
                id: "a",
                sessionId: "sess-a",
                cwd: "/Users/dev/code/openclient-llm",
                name: "openclient-llm",
                model: CodeModelInfo(provider: "pi", id: "qwen3-coder"),
                isStreaming: false,
                hasQuestion: false,
                compacting: true,
                lastActivity: nil,
                isAnchor: true
            ),
        ],
        effectiveSelectedId: "a",
        onSelect: { _ in }
    )
}

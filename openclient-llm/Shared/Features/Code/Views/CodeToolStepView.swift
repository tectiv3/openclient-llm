//
//  CodeToolStepView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeToolStepView: View {
    let toolName: String
    let toolId: String
    let args: [String: AnyCodableValue]
    let output: String?
    let isComplete: Bool

    @State private var isExpanded = false
    @State private var areArgsExpanded = false
    @State private var outputRevealedLines = 0

    private static let collapsedLineLimit = 20
    private static let expandedLineLimit = 200
    // Each "Show more" tap reveals another page of output lines.
    private static let linePage = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    if !isComplete {
                        ProgressView()
                            .controlSize(.mini)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(
                            .degrees(isExpanded ? 90 : 0)
                        )
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}

// MARK: - Private

private extension CodeToolStepView {
    var toolIcon: String { CodeToolDisplay.icon(for: toolName) }

    var summaryText: String {
        CodeToolDisplay.summary(toolName: toolName, args: args)
    }

    var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !args.isEmpty {
                argsSection
            }

            if let output, !output.isEmpty {
                outputSection(output)
            }
        }
    }

    var argsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(
                args.sorted(by: { $0.key < $1.key }),
                id: \.key
            ) { key, value in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(value.stringRepresentation)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(areArgsExpanded ? nil : 3)
                        .textSelection(.enabled)
                }
            }

            if argsNeedShowMore {
                Button(
                    areArgsExpanded
                        ? String(localized: "Show less")
                        : String(localized: "Show more")
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        areArgsExpanded.toggle()
                    }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var argsNeedShowMore: Bool {
        let limit = 3
        return args.values.contains {
            $0.stringRepresentation
                .components(separatedBy: "\n").count > limit
        }
    }

    func outputSection(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let baseLimit = isComplete
            ? Self.expandedLineLimit
            : Self.collapsedLineLimit
        let limit = min(
            baseLimit + outputRevealedLines,
            lines.count
        )
        let displayLines = Array(lines.suffix(limit))
        let truncated = lines.count > limit

        return VStack(alignment: .leading, spacing: 4) {
            Divider()

            if truncated {
                HStack {
                    Text(String(
                        localized: "Showing last \(limit) of \(lines.count) lines"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                    Spacer()

                    Button(String(localized: "Show more")) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            outputRevealedLines = min(
                                outputRevealedLines + Self.linePage,
                                lines.count
                            )
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .accessibilityHint(
                        String(localized: "Reveal more output")
                    )
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(displayLines.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

}

// MARK: - AnyCodableValue Helpers

private extension AnyCodableValue {
    var stringRepresentation: String {
        switch self {
        case .string(let str): return str
        case .int(let num): return "\(num)"
        case .double(let num): return "\(num)"
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array(let arr):
            return "[\(arr.count) items]"
        case .object(let obj):
            return "{\(obj.count) keys}"
        }
    }
}

// MARK: - Tool Display Helpers

enum CodeToolDisplay {
    static func icon(for toolName: String) -> String {
        let lower = toolName.lowercased()
        if lower.contains("bash") || lower.contains("shell") {
            return "terminal"
        } else if lower.contains("read") || lower.contains("file") {
            return "doc.text"
        } else if lower.contains("write") || lower.contains("edit") {
            return "pencil"
        } else if lower.contains("search") || lower.contains("grep") {
            return "magnifyingglass"
        } else if lower.contains("web") {
            return "globe"
        }
        return "wrench"
    }

    static func summary(
        toolName: String,
        args: [String: AnyCodableValue]
    ) -> String {
        if let command = args["command"],
           case .string(let cmd) = command {
            let first = cmd.components(separatedBy: "\n").first ?? cmd
            return "\(toolName): \(first)"
        }
        if let path = args["file_path"] ?? args["path"],
           case .string(let filePath) = path {
            let name = (filePath as NSString).lastPathComponent
            return "\(toolName): \(name)"
        }
        return toolName
    }
}

#Preview {
    VStack(spacing: 12) {
        CodeToolStepView(
            toolName: "Bash",
            toolId: "call_1",
            args: ["command": .string("npm test")],
            output: "All tests passed\n5 suites, 23 tests",
            isComplete: true
        )

        CodeToolStepView(
            toolName: "Read",
            toolId: "call_2",
            args: ["file_path": .string("/src/main.ts")],
            output: nil,
            isComplete: false
        )
    }
    .padding()
}

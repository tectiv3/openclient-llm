//
//  MarkdownBubbleView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct MarkdownBubbleView: View {
    // MARK: - Properties

    let text: String
    var isStreaming: Bool = false
    var onLayoutChanged: (() -> Void)?

    @State private var cursorVisible = false
    @State private var renderedMarkdown = RenderedMarkdown.empty

    // MARK: - View

    var body: some View {
        Group {
            if isStreaming
                || renderedMarkdown.source != text
                || renderedMarkdown.blocks.isEmpty {
                streamingTextView
            } else {
                blocksView
            }
        }
        .task(id: shouldBlink) {
            guard shouldBlink else {
                cursorVisible = false
                return
            }
            while !Task.isCancelled {
                cursorVisible.toggle()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .task(id: isStreaming ? nil : text) {
            await renderMarkdownIfNeeded()
        }
    }
}

// MARK: - Private

private extension MarkdownBubbleView {
    var shouldBlink: Bool {
        isStreaming && !text.isEmpty
    }

    var streamingTextView: some View {
        let content = Text(text).foregroundColor(.primary)
        let cursor = isStreaming
            ? Text("█").foregroundColor(cursorVisible ? .primary : .clear)
            : Text("")

        return Text("\(content)\(cursor)")
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var blocksView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(renderedMarkdown.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let content):
                    textBlockView(content)
                case .heading(let headingText, let level):
                    headingBlockView(headingText, level: level)
                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .blockquote(let content):
                    BlockquoteView(content: content, inlineContent: renderedMarkdown.inlineContent)
                case .unorderedList(let items):
                    BulletedListView(items: items, inlineContent: renderedMarkdown.inlineContent)
                case .orderedList(let items):
                    NumberedListView(items: items, inlineContent: renderedMarkdown.inlineContent)
                case .horizontalRule:
                    HorizontalRuleView()
                case .table(let headers, let rows):
                    MarkdownTableView(
                        headers: headers,
                        rows: rows,
                        inlineContent: renderedMarkdown.inlineContent
                    )
                case .taskList(let items):
                    TaskListView(items: items, inlineContent: renderedMarkdown.inlineContent)
                case .image(let alt, let url):
                    MarkdownImageView(alt: alt, urlString: url, onLayoutChanged: onLayoutChanged)
                }
            }
        }
    }

    func textBlockView(_ content: String) -> some View {
        Text(renderedMarkdown.attributedString(for: content))
            .foregroundStyle(Color.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func headingBlockView(_ headingText: String, level: Int) -> some View {
        Text(headingText)
            .font(headingFont(level))
            .fontWeight(.semibold)
            .foregroundStyle(Color.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }

    func renderMarkdownIfNeeded() async {
        guard !isStreaming, !text.isEmpty else { return }
        let source = text
        guard renderedMarkdown.source != source else { return }
        guard let rendered = await MarkdownParser.renderConcurrently(source),
              !Task.isCancelled else { return }
        renderedMarkdown = rendered
        onLayoutChanged?()
    }
}

#Preview("Streaming") {
    MarkdownBubbleView(
        text: "Hello, this is a **streaming** message...",
        isStreaming: true
    )
    .padding()
}

#Preview("Rendered") {
    MarkdownBubbleView(
        text: "# Heading\n\nSome **bold** text and `inline code`.\n\n```swift\nlet x = 42\n```"
    )
    .padding()
}

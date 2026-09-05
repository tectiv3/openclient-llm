//
//  ThinkingDisclosureView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct ThinkingDisclosureView: View {
    let text: String

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Thinking"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
    }
}

#Preview {
    ThinkingDisclosureView(
        text: "Let me think about how to approach this problem..."
    )
    .padding()
}

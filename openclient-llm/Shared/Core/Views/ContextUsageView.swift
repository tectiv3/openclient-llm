//
//  ContextUsageView.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 14/07/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct ContextUsageView: View {
    let usage: ContextUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Compact gauge: the meter is the instrument, the numbers are
            // its readout — one row instead of a caption stacked above a bar,
            // so it composes with a header above it instead of competing.
            HStack(spacing: 8) {
                ProgressView(value: Double(usage.percentage), total: 100)
                    .tint(tint)
                    .controlSize(.mini)

                usageText
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if usage.compactedMessageCount > 0 || usage.excludedMessageCount > 0 || usage.isLatestTurnOverBudget {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(usage.isLatestTurnOverBudget ? .red : .secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Estimated context"))
        .accessibilityValue(accessibilityValue)
    }
}

private extension ContextUsageView {
    @ViewBuilder
    var usageText: some View {
        Text(usage.formattedUsage)
            .lineLimit(1)
        Text("·")
            .lineLimit(1)
        Text(Double(usage.percentage) / 100, format: .percent)
            .lineLimit(1)
    }

    var statusText: String {
        if usage.isLatestTurnOverBudget {
            return String(localized: "The latest turn exceeds the available context")
        }
        if usage.compactedMessageCount > 0 && usage.excludedMessageCount > 0 {
            return String(
                localized: "\(usage.compactedMessageCount) compacted · \(usage.excludedMessageCount) excluded"
            )
        }
        if usage.compactedMessageCount > 0 {
            return String(localized: "\(usage.compactedMessageCount) messages compacted")
        }
        return String(localized: "\(usage.excludedMessageCount) messages excluded from this request")
    }

    var accessibilityValue: String {
        var value = String(localized: "\(usage.formattedUsage) tokens, \(usage.percentage) percent")
        if usage.compactedMessageCount > 0 || usage.excludedMessageCount > 0 || usage.isLatestTurnOverBudget {
            value += ". \(statusText)"
        }
        return value
    }

    var tint: Color {
        switch usage.percentage {
        case 90...: .red
        case 70...: .orange
        default: .secondary
        }
    }
}

#Preview("Gauge — 74% (orange)") {
    ContextUsageView(
        usage: ContextUsage(
            estimatedInputTokens: 94225,
            maxInputTokens: 128_000
        )
    )
    .padding()
}

#Preview("Gauge — low (secondary)") {
    ContextUsageView(
        usage: ContextUsage(
            estimatedInputTokens: 20000,
            maxInputTokens: 128_000
        )
    )
    .padding()
}

#Preview("Gauge — over budget status line") {
    ContextUsageView(
        usage: ContextUsage(
            estimatedInputTokens: 7200,
            maxInputTokens: 8192,
            excludedMessageCount: 2,
            compactedMessageCount: 14
        )
    )
    .padding()
}

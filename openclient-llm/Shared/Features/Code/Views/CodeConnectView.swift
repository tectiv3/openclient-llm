//
//  CodeConnectView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeConnectView: View {
    // MARK: - Properties

    @Binding var form: CodeViewModel.ConnectForm
    var isConnecting: Bool = false
    let onConnect: (String, Int, String) -> Void

    @State private var showHostFields: Bool = false
    @State private var portText: String = ""
    @State private var now: Date = .now
    @State private var didSyncPort = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host, port, code
    }

    // MARK: - View

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 40)

                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 64, height: 64)
                    .glassEffect(.regular, in: .circle)

                Text(String(localized: "Connect to pi"))
                    .font(.title2)
                    .fontWeight(.semibold)

                if form.hasSavedHost && !showHostFields {
                    repeatConnectLayout
                } else {
                    firstTimeLayout
                }

                statusMessage

                connectButton

                if form.hasSavedHost && !showHostFields && !isConnecting {
                    Button {
                        showHostFields = true
                        focusedField = .host
                    } label: {
                        Text(String(localized: "Change host"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if !didSyncPort {
                portText = form.port > 0 ? "\(form.port)" : "47800"
                didSyncPort = true
            }
            if form.errorMessage != nil && form.code.isEmpty {
                focusedField = .code
            } else if !form.hasSavedHost {
                focusedField = .host
            }
        }
        .task(id: form.rateLimitedUntil) {
            await tickRateLimit()
        }
        .disabled(isConnecting)
    }
}

// MARK: - Private

private extension CodeConnectView {
    @ViewBuilder
    var statusMessage: some View {
        if let until = form.rateLimitedUntil {
            let remaining = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
            Text(String(localized: "Too many attempts — wait \(remaining)s"))
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if let errorMessage = form.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    var repeatConnectLayout: some View {
        VStack(spacing: 16) {
            Text(form.host)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !form.recentConnections.isEmpty {
                recentConnectionsSection
            }

            // The pairing code is optional: it is only requested after a
            // failed attempt set an error message.
            if form.errorMessage != nil {
                Text(String(localized: "Enter the 6-digit code shown in pi"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                codeField
            }
        }
    }

    var firstTimeLayout: some View {
        VStack(spacing: 12) {
            if !form.recentConnections.isEmpty {
                recentConnectionsSection
            }

            TextField(
                String(localized: "Host (e.g. mac.ts.net)"),
                text: $form.host
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #endif
                .focused($focusedField, equals: .host)

            TextField(
                String(localized: "Port"),
                text: $portText
            )
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
                .focused($focusedField, equals: .port)

            if form.errorMessage != nil {
                codeField
            }
        }
    }

    /// Quick-pick of recent hosts, shown in both the repeat and the
    /// change-host layouts.
    var recentConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Recent connections"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                ForEach(form.recentConnections, id: \.self) { connection in
                    recentConnectionRow(connection)
                }
            }
        }
    }

    func recentConnectionRow(_ connection: CodeRecentConnection) -> some View {
        let isSelected = connection.host == form.host

        return Button {
            if form.host != connection.host {
                // The pairing code belongs to the previous host.
                form.code = ""
            }
            form.host = connection.host
            portText = String(connection.port)
            focusedField = nil
        } label: {
            HStack(spacing: 8) {
                Text(connection.host)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        .accessibilityLabel(connection.host)
        .accessibilityHint(String(localized: "Connects to this host"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var codeField: some View {
        TextField(
            String(localized: "Code"),
            text: $form.code
        )
        .textFieldStyle(.roundedBorder)
        .font(.system(.title2, design: .monospaced))
        .multilineTextAlignment(.center)
        .autocorrectionDisabled()
        #if os(iOS)
            .keyboardType(.numberPad)
        #endif
            .focused($focusedField, equals: .code)
            .onSubmit {
                if isValid {
                    submitConnect()
                }
            }
    }

    var connectButton: some View {
        Button {
            submitConnect()
        } label: {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Connecting..."))
                } else {
                    Text(String(localized: "Connect"))
                }
            }
            .frame(maxWidth: 200)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isValid || isConnecting || isRateLimited)
    }

    var isValid: Bool {
        let portValue = Int(portText) ?? 0
        return !form.host.isEmpty
            && portValue > 0
            && portValue <= 65535
    }

    var isRateLimited: Bool {
        guard let until = form.rateLimitedUntil else { return false }
        return now < until
    }

    func submitConnect() {
        let portValue = Int(portText) ?? 47800
        onConnect(form.host, portValue, form.code)
    }

    /// Ticks `now` once per second while the pairing-code lockout is active so
    /// the countdown and Connect button re-evaluate.
    func tickRateLimit() async {
        guard let until = form.rateLimitedUntil else { return }
        while !Task.isCancelled, Date.now < until {
            try? await Task.sleep(for: .seconds(1))
            now = .now
        }
        if !Task.isCancelled {
            now = .now
        }
    }
}

#Preview("First Time") {
    CodeConnectView(
        form: .constant(.init())
    ) { _, _, _ in }
}

#Preview("Repeat") {
    CodeConnectView(
        form: .constant(.init(
            host: "mac.ts.net",
            port: 47800,
            hasSavedHost: true,
            recentConnections: [
                CodeRecentConnection(host: "mac.ts.net", port: 47800),
                CodeRecentConnection(host: "pi-mini.ts.net", port: 47800),
            ]
        ))
    ) { _, _, _ in }
}

#Preview("Repeat Error") {
    CodeConnectView(
        form: .constant(.init(
            host: "mac.ts.net",
            port: 47800,
            errorMessage: "Invalid code — check the code shown in pi",
            hasSavedHost: true,
            recentConnections: [
                CodeRecentConnection(host: "mac.ts.net", port: 47800),
                CodeRecentConnection(host: "pi-mini.ts.net", port: 47800),
            ]
        ))
    ) { _, _, _ in }
}

#Preview("Error") {
    CodeConnectView(
        form: .constant(.init(
            host: "mac.ts.net",
            port: 47800,
            errorMessage: "Invalid code — check the code shown in pi",
            hasSavedHost: true
        ))
    ) { _, _, _ in }
}

#Preview("Connecting") {
    CodeConnectView(
        form: .constant(.init(host: "mac.ts.net", port: 47800, code: "152312", hasSavedHost: true)),
        isConnecting: true
    ) { _, _, _ in }
}

#Preview("Rate Limited") {
    CodeConnectView(
        form: .constant(.init(
            host: "mac.ts.net",
            port: 47800,
            errorMessage: "Too many attempts — wait 60s",
            hasSavedHost: true,
            rateLimitedUntil: .now.addingTimeInterval(45)
        ))
    ) { _, _, _ in }
}

#Preview("Recent Connections") {
    CodeConnectView(
        form: .constant(.init(
            host: "mac.ts.net",
            port: 47800,
            recentConnections: [
                CodeRecentConnection(host: "mac.ts.net", port: 47800),
                CodeRecentConnection(host: "pi-mini.ts.net", port: 47800),
                CodeRecentConnection(host: "10.0.0.42", port: 47801),
            ]
        ))
    ) { _, _, _ in }
}

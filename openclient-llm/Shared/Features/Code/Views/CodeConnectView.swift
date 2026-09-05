//
//  CodeConnectView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

/// Connect form for the Code tab. Field values are owned by the parent
/// (`CodeView`) so they survive the `.disconnected` → `.connecting` transition.
struct CodeConnectView: View {
    // MARK: - Properties

    let form: CodeViewModel.ConnectForm
    @Binding var host: String
    @Binding var portText: String
    @Binding var code: String
    var isConnecting: Bool = false
    let onConnect: (String, Int, String) -> Void

    @State private var showHostFields: Bool = false
    @State private var now: Date = .now
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
            if form.hasSavedHost {
                focusedField = .code
            } else {
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
            Text(String(localized: "Enter the 6-digit code shown in pi"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            codeField
        }
    }

    var firstTimeLayout: some View {
        VStack(spacing: 12) {
            TextField(
                String(localized: "Host (e.g. mac.ts.net)"),
                text: $host
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

            codeField
        }
    }

    var codeField: some View {
        TextField(
            String(localized: "Code"),
            text: $code
        )
        .textFieldStyle(.roundedBorder)
        .font(.system(.title2, design: .monospaced))
        .multilineTextAlignment(.center)
        .autocorrectionDisabled()
#if os(iOS)
        .textInputAutocapitalization(.characters)
#endif
        .focused($focusedField, equals: .code)
        .onChange(of: code) { _, newValue in
            let filtered = newValue
                .uppercased()
                .filter { $0.isHexDigit }
            if filtered != newValue {
                code = filtered
            }
            if code.count > 6 {
                code = String(code.prefix(6))
            }
        }
        .onSubmit {
            if isValid { submitConnect() }
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
        return !host.isEmpty
            && portValue > 0
            && portValue <= 65535
            && code.count == 6
    }

    var isRateLimited: Bool {
        guard let until = form.rateLimitedUntil else { return false }
        return now < until
    }

    func submitConnect() {
        let portValue = Int(portText) ?? 47800
        onConnect(host, portValue, code)
    }

    /// Ticks `now` once per second while the pairing-code lockout is active so
    /// the countdown and Connect button re-evaluate.
    func tickRateLimit() async {
        guard let until = form.rateLimitedUntil else { return }
        while !Task.isCancelled && Date.now < until {
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
        form: .init(),
        host: .constant(""),
        portText: .constant("47800"),
        code: .constant("")
    ) { _, _, _ in }
}

#Preview("Repeat") {
    CodeConnectView(
        form: .init(host: "mac.ts.net", port: 47800, hasSavedHost: true),
        host: .constant("mac.ts.net"),
        portText: .constant("47800"),
        code: .constant("")
    ) { _, _, _ in }
}

#Preview("Error") {
    CodeConnectView(
        form: .init(
            host: "mac.ts.net",
            port: 47800,
            errorMessage: "Invalid code — check the code shown in pi",
            hasSavedHost: true
        ),
        host: .constant("mac.ts.net"),
        portText: .constant("47800"),
        code: .constant("")
    ) { _, _, _ in }
}

#Preview("Connecting") {
    CodeConnectView(
        form: .init(host: "mac.ts.net", port: 47800, hasSavedHost: true),
        host: .constant("mac.ts.net"),
        portText: .constant("47800"),
        code: .constant("1A2B3C"),
        isConnecting: true
    ) { _, _, _ in }
}

#Preview("Rate Limited") {
    CodeConnectView(
        form: .init(
            host: "mac.ts.net",
            port: 47800,
            errorMessage: "Too many attempts — wait 60s",
            hasSavedHost: true,
            rateLimitedUntil: .now.addingTimeInterval(45)
        ),
        host: .constant("mac.ts.net"),
        portText: .constant("47800"),
        code: .constant("1A2B3C")
    ) { _, _, _ in }
}

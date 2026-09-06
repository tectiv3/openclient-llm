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

            codeField
        }
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
            && form.code.count == 6
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
        form: .constant(.init(host: "mac.ts.net", port: 47800, hasSavedHost: true))
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
        form: .constant(.init(host: "mac.ts.net", port: 47800, code: "1A2B3C", hasSavedHost: true)),
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

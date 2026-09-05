//
//  CodeConnectView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct CodeConnectView: View {
    // MARK: - Properties

    let form: CodeViewModel.ConnectForm
    var isConnecting: Bool = false
    let onConnect: (String, Int, String) -> Void

    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var code: String = ""
    @State private var showHostFields: Bool = false
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

                if let errorMessage = form.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                connectButton

                if form.hasSavedHost && !showHostFields {
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
            host = form.host
            portText = form.port > 0 ? "\(form.port)" : "47800"
            if form.hasSavedHost {
                focusedField = .code
            } else {
                focusedField = .host
            }
        }
        .disabled(isConnecting)
        .overlay {
            if isConnecting {
                connectingOverlay
            }
        }
    }
}

// MARK: - Private

private extension CodeConnectView {
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
            Text(String(localized: "Connect"))
                .frame(maxWidth: 200)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isValid || isConnecting)
    }

    var connectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(String(localized: "Connecting..."))
                .foregroundStyle(.secondary)
        }
    }

    var isValid: Bool {
        let portValue = Int(portText) ?? 0
        return !host.isEmpty
            && portValue > 0
            && portValue <= 65535
            && code.count == 6
    }

    func submitConnect() {
        let portValue = Int(portText) ?? 47800
        onConnect(host, portValue, code)
    }
}

#Preview("First Time") {
    CodeConnectView(
        form: .init()
    ) { _, _, _ in }
}

#Preview("Repeat") {
    CodeConnectView(
        form: .init(host: "mac.ts.net", port: 47800, hasSavedHost: true)
    ) { _, _, _ in }
}

#Preview("Error") {
    CodeConnectView(
        form: .init(
            host: "mac.ts.net",
            port: 47800,
            errorMessage: "Invalid code — check the code shown in pi",
            hasSavedHost: true
        )
    ) { _, _, _ in }
}

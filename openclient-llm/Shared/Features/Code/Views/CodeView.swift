//
//  CodeView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

struct CodeView: View {
    // MARK: - Properties

    @State private var viewModel = CodeViewModel()

    // MARK: - View

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .disconnected(let form):
                    CodeConnectView(form: form) { host, port, code in
                        viewModel.send(.connect(
                            host: host, port: port, code: code
                        ))
                    }

                case .connecting:
                    CodeConnectView(
                        form: .init(),
                        isConnecting: true
                    ) { _, _, _ in }
                    cancelConnectOverlay

                case .connected(let session):
                    CodeSessionView(
                        session: session,
                        viewModel: viewModel
                    )

                case .reconnecting(let session):
                    CodeSessionView(
                        session: session,
                        viewModel: viewModel,
                        isReconnecting: true
                    )

                case .failed(let errorMessage):
                    failedView(errorMessage)
                }
            }
            .navigationTitle(String(localized: "Code"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }
}

// MARK: - Private

private extension CodeView {
    var cancelConnectOverlay: some View {
        VStack {
            Spacer()
            Button {
                viewModel.send(.cancelConnect)
            } label: {
                Text(String(localized: "Cancel"))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 40)
        }
    }

    func failedView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                viewModel.send(.disconnect)
            } label: {
                Text(String(localized: "Try Again"))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)

            Button {
                viewModel.send(.disconnect)
            } label: {
                Text(String(localized: "Back"))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

#Preview {
    CodeView()
}

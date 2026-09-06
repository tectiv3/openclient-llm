//
//  CodeView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeView: View {
    // MARK: - Properties

    var viewModel: CodeViewModel
    @Environment(\.scenePhase) private var scenePhase

    // Connect form fields live here (not in CodeConnectView) so they survive
    // the .disconnected → .connecting → .disconnected transitions.
    @State private var connectHost: String = ""
    @State private var connectPortText: String = ""
    @State private var connectCode: String = ""
    @State private var hasPrefilledConnectFields = false

    // MARK: - View

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .disconnected(let form):
                    CodeConnectView(
                        form: form,
                        host: $connectHost,
                        portText: $connectPortText,
                        code: $connectCode
                    ) { host, port, code in
                        viewModel.send(.connect(
                            host: host, port: port, code: code
                        ))
                    }

                case .connecting:
                    CodeConnectView(
                        form: connectFormWhileConnecting,
                        host: $connectHost,
                        portText: $connectPortText,
                        code: $connectCode,
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
            .onAppear {
                prefillConnectFieldsIfNeeded()
            }
            .onChange(of: viewModel.state) { _, newState in
                syncConnectFields(from: newState)
            }
            .navigationTitle(String(localized: "Code"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    viewModel.send(.appDidEnterBackground)
                case .active:
                    viewModel.send(.appWillEnterForeground)
                default:
                    break
                }
            }
#endif
        }
    }
}

// MARK: - Private

private extension CodeView {
    var connectFormWhileConnecting: CodeViewModel.ConnectForm {
        CodeViewModel.ConnectForm(
            host: connectHost,
            port: Int(connectPortText) ?? 47800,
            hasSavedHost: true
        )
    }

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
                viewModel.send(.retry)
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

    func prefillConnectFieldsIfNeeded() {
        guard !hasPrefilledConnectFields,
              case .disconnected(let form) = viewModel.state
        else { return }
        hasPrefilledConnectFields = true
        connectHost = form.host
        connectPortText = form.port > 0 ? "\(form.port)" : "47800"
        connectCode = form.code
    }

    func syncConnectFields(from state: CodeViewModel.State) {
        guard case .disconnected(let form) = state else { return }
        connectHost = form.host
        connectPortText = form.port > 0 ? "\(form.port)" : "47800"
        connectCode = form.code
    }
}

#Preview {
    CodeView(viewModel: CodeViewModel())
}

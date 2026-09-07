//
//  CodeView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeView: View {
    // MARK: - Properties

    @Bindable var viewModel: CodeViewModel
    var onBack: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - View

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .disconnected:
                    CodeConnectView(
                        form: $viewModel.connectForm
                    ) { host, port, code in
                        viewModel.send(.connect(
                            host: host, port: port, code: code
                        ))
                    }

                case .connecting:
                    CodeConnectView(
                        form: $viewModel.connectForm,
                        isConnecting: true
                    ) { _, _, _ in }
                    cancelConnectOverlay

                case let .connected(session):
                    CodeSessionView(
                        session: session,
                        viewModel: viewModel,
                        onBack: onBack
                    )

                case let .reconnecting(session):
                    CodeSessionView(
                        session: session,
                        viewModel: viewModel,
                        onBack: onBack,
                        isReconnecting: true
                    )

                case let .failed(errorMessage):
                    failedView(errorMessage)
                }
            }
            .navigationTitle(String(localized: "Code"))
            .onAppear {
                viewModel.send(.viewAppeared)
            }
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
}

#Preview {
    CodeView(viewModel: CodeViewModel())
}

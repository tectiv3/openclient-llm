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
                    // WHY: safeAreaInset, not a sibling view — a sibling
                    // Group child would split the height with the greedy
                    // ScrollView and clip the connect form's button.
                    CodeConnectView(
                        form: $viewModel.connectForm,
                        isConnecting: true
                    ) { _, _, _ in }
                        .safeAreaInset(edge: .bottom) {
                            cancelButton
                        }

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
    var cancelButton: some View {
        Button {
            viewModel.send(.cancelConnect)
        } label: {
            Text(String(localized: "Cancel"))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 40)
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

#if DEBUG

    // MARK: - Previews

    /// Previews force a specific `State` without a live connection via the
    /// DEBUG-only `previewSetState` seam.
    func previewViewModel(
        _ state: CodeViewModel.State
    ) -> CodeViewModel {
        let viewModel = CodeViewModel()
        viewModel.previewSetState(state)
        return viewModel
    }

    var previewSession: CodeViewModel.SessionState {
        .init(
            sessionId: "preview",
            cwd: "openclient-llm",
            model: CodeModelInfo(
                provider: "openrouter", id: "qwen3.8-27b"
            ),
            isStreaming: false,
            contextUsage: CodeContextUsage(
                tokens: 102_891, contextWindow: 128_000, percent: 81
            ),
            items: [
                .assistant(
                    id: UUID(),
                    content: [
                        .text("Working on the RC pending-steers feature."),
                    ],
                    isStreaming: false
                ),
                .user(
                    id: UUID(),
                    text: "Use a subagent for the review",
                    failed: false, pending: false
                ),
                .user(
                    id: UUID(),
                    text: "Trying steering now. Ignore this message",
                    failed: false, pending: true
                ),
            ]
        )
    }

    /// Busy mode: `isStreaming` flips the input bar to "Steer pi..." +
    /// Stop, and the trailing assistant bubble renders as streaming.
    var previewStreamingSession: CodeViewModel.SessionState {
        var session = previewSession
        session.isStreaming = true
        session.items.append(.assistant(
            id: UUID(),
            content: [.text("Investigating the streaming buffer…")],
            isStreaming: true
        ))
        return session
    }

    #Preview("Disconnected") {
        CodeView(viewModel: CodeViewModel())
    }

    #Preview("Connecting") {
        CodeView(viewModel: previewViewModel(.connecting))
    }

    #Preview("Failed") {
        CodeView(
            viewModel: previewViewModel(
                .failed(
                    errorMessage: "Invalid code — check the code shown in pi"
                )
            )
        )
    }

    #Preview("Connected") {
        CodeView(viewModel: previewViewModel(.connected(previewSession)))
    }

    #Preview("Connected (streaming)") {
        CodeView(
            viewModel: previewViewModel(
                .connected(previewStreamingSession)
            )
        )
    }

    #Preview("Reconnecting") {
        CodeView(
            viewModel: previewViewModel(.reconnecting(previewSession))
        )
    }
#endif

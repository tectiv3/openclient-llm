//
//  CodeSessionView.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import SwiftUI

struct CodeSessionView: View {
    // MARK: - Properties

    let session: CodeViewModel.SessionState
    let viewModel: CodeViewModel
    var onBack: () -> Void = {}
    var isReconnecting: Bool = false

    @State private var inputText: String = ""
    @State private var shouldAutoScroll: Bool = true
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)
    @State private var scrollToMessageId: UUID?
    @State private var isManuallyScrolling: Bool = false
    @State private var scrollEdgeMetrics = ScrollEdgeMetrics()
    @State private var showReconnectSuccess = false
    @State private var showModelsSheet = false
    @State private var showSessionsSheet = false
    @State private var showNewSessionConfirm = false
    @State private var showCompactConfirm = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    // Non-private: shared with the Panels extension (status dot pulse).
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // MARK: - View

    var body: some View {
        mainContent
            .modifier(AttachCoverModifier(session: session, viewModel: viewModel))
            .sheet(isPresented: $showModelsSheet) { modelsSheet }
            .sheet(isPresented: $showSessionsSheet) { sessionsSheet }
            .confirmationDialog(
                String(localized: "New Session"),
                isPresented: $showNewSessionConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "New Session"), role: .destructive) {
                    viewModel.send(.newSession)
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(newSessionConfirmMessage)
            }
            .confirmationDialog(
                String(localized: "Compact Context"),
                isPresented: $showCompactConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Compact"), role: .destructive) {
                    viewModel.send(.compact(instructions: nil))
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(compactConfirmMessage)
            }
            .alert(
                String(localized: "Rename Session"),
                isPresented: $showRenameAlert
            ) {
                TextField(
                    String(localized: "Session name"), text: $renameText
                )
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Rename")) {
                    handleRenameSubmit()
                }
            }
            .animation(
                reduceMotion ? nil : .spring(duration: 0.3),
                value: viewModel.transientToast
            )
            .onChange(of: session.compacting != nil) { _, isCompacting in
                let message = isCompacting
                    ? String(localized: "Compacting context")
                    : String(localized: "Compaction ended")
                AccessibilityNotification.Announcement(message).post()
            }
            .onChange(of: isReconnecting) { _, reconnecting in
                guard !reconnecting else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    showReconnectSuccess = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(
                        reduceMotion ? nil : .easeInOut(duration: 0.3)
                    ) {
                        showReconnectSuccess = false
                    }
                }
            }
            .task(id: viewModel.transientToast) {
                guard viewModel.transientToast != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                viewModel.send(.clearToast)
            }
    }

    /// The main content column (banner, header, transcript, input bar)
    /// with its chrome — kept out of `body` for the type-checker.
    private var mainContent: some View {
        VStack(spacing: 0) {
            if isReconnecting {
                reconnectingBanner
            } else if showReconnectSuccess {
                reconnectedBanner
                    .transition(.opacity)
            }

            identityHeader

            // Standalone condition on purpose: reconnecting and compacting
            // are independent states and both banners can coexist.
            if session.compacting != nil {
                compactingBanner
            }

            if let usage = contextUsage {
                ContextUsageView(usage: usage)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
            }

            if session.items.isEmpty {
                emptyState
            } else {
                transcript
            }

            CodeInputBarView(
                inputText: $inputText,
                isStreaming: session.isStreaming,
                isDisabled: isReconnecting,
                isQuestionPresented: session.pendingQuestion != nil,
                onSend: handleSend
            )
        }
        .toolbar { mainToolbar }
        .overlay(alignment: .bottom) {
            if !shouldAutoScroll && !session.items.isEmpty {
                jumpToBottomButton
            }
        }
        .overlay(alignment: .top) {
            if let toast = viewModel.transientToast {
                toastView(toast)
            }
        }
        #if os(iOS)
        // iOS: centered card over a dimmed background (macOS keeps .sheet).
        .overlay {
            questionCardOverlay
        }
        #endif
        #if os(macOS)
        .sheet(item: pendingQuestion) { question in
            CodeQuestionModal(
                question: question,
                onAnswer: { id, answers in
                    viewModel.send(.answer(id: id, answers: answers))
                },
                onDismiss: {
                    viewModel.send(.abort)
                }
            )
            .frame(width: 480, height: 520)
        }
        #endif
    }
}

// MARK: - Private

private extension CodeSessionView {
    // MARK: - Toolbar

    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(String(localized: "Back"))
        }

        ToolbarItem(placement: .navigation) {
            statusDot
        }

        ToolbarItem(placement: .automatic) {
            sessionMenu
        }

        ToolbarItem(placement: .automatic) {
            sessionsButton
        }

        ToolbarItem(placement: .automatic) {
            Button {
                viewModel.send(.disconnect)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(String(localized: "Disconnect"))
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    var modelsSheet: some View {
        CodeModelsSheetView(
            models: session.models,
            selected: session.model,
            onSelect: { model in
                viewModel.send(
                    .setModel(provider: model.provider, modelId: model.id)
                )
                showModelsSheet = false
            }
        )
        #if os(macOS)
        .frame(width: 400, height: 480)
        #endif
    }

    @ViewBuilder
    var sessionsSheet: some View {
        CodeSessionsSheetView(
            sessions: viewModel.sessions,
            effectiveSelectedId: effectiveSelectedId,
            onSelect: { id in
                viewModel.selectSession(id: id)
                showSessionsSheet = false
            }
        )
        #if os(macOS)
        .frame(width: 420, height: 420)
        #endif
    }

    // MARK: - Session Commands

    var sessionMenu: some View {
        Menu {
            Button {
                showNewSessionConfirm = true
            } label: {
                Label(String(localized: "New Session"), systemImage: "plus")
            }

            Button {
                showModelsSheet = true
            } label: {
                Label(
                    String(localized: "Models"),
                    systemImage: "brain.head.profile"
                )
            }

            // Disabled while a compaction is in flight: the server rejects a
            // second compact with command_failed ("compact already in progress").
            Button {
                showCompactConfirm = true
            } label: {
                Label(
                    String(localized: "Compact"),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            .disabled(session.compacting != nil)

            Button {
                renameText = session.sessionName
                showRenameAlert = true
            } label: {
                Label(String(localized: "Rename"), systemImage: "pencil")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(String(localized: "Session Options"))
    }

    /// Toolbar "sessions" affordance (multi-session rc, spec Decision 10).
    /// Shown only while connected; disabled while the anchor has not
    /// broadcast a session list yet (`sessions` frames), so a single-session
    /// box sees an inert icon rather than an empty sheet.
    var sessionsButton: some View {
        Button {
            showSessionsSheet = true
        } label: {
            Image(systemName: "square.stack.3d.up")
                .overlay(alignment: .topTrailing) {
                    if viewModel.sessions.count > 1 {
                        Text("\(viewModel.sessions.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Color.appAccent, in: .circle)
                            .offset(x: 6, y: -6)
                    }
                }
        }
        .disabled(viewModel.sessions.isEmpty)
        .accessibilityLabel(String(localized: "Sessions"))
    }

    /// Row the sheet should mark: the explicit selection, or the anchor row
    /// (the effective view when nothing is selected). `nil` → no mark.
    var effectiveSelectedId: String? {
        if let selectedId = viewModel.selectedId {
            return selectedId
        }
        return viewModel.sessions.first(where: { $0.isAnchor })?.id
    }

    func handleRenameSubmit() {
        let name = renameText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        showRenameAlert = false
        // Client-side reject: an empty/whitespace name sends no frame.
        guard !name.isEmpty else { return }
        viewModel.send(.rename(name: name))
    }

    // MARK: - Transcript

    var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(session.items) { item in
                    let liveRun = liveSubagentRun(for: item)
                    CodeTranscriptItemView(
                        item: item,
                        onRetry: { id in
                            viewModel.send(.retryPrompt(id: id))
                        },
                        subagentRun: liveRun,
                        onOpenLive: liveRun.map {
                            run in { viewModel.attachSubagent(info: run) }
                        }
                    )
                    .id(item.id)
                    .transition(.opacity)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.bottom, 15)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .modifier(ScrollTriggerModifier(
            scrollPosition: $scrollPosition,
            scrollToMessageId: $scrollToMessageId,
            shouldAutoScroll: $shouldAutoScroll,
            isManuallyScrolling: $isManuallyScrolling,
            messageCount: session.items.count,
            contentTrigger: scrollContentTrigger,
            sessionId: session.sessionId,
            isAtBottom: scrollEdgeMetrics.isAtBottom
        ))
        .onScrollGeometryChange(for: ScrollEdgeMetrics.self) { geometry in
            let bottomDistance = geometry.contentSize.height
                - geometry.contentOffset.y
                - geometry.containerSize.height
            return ScrollEdgeMetrics(
                isNearBottom: bottomDistance < 150,
                isAtBottom: bottomDistance < 8,
                isNearTop: geometry.contentOffset.y < 150
            )
        } action: { _, newValue in
            scrollEdgeMetrics = newValue
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            if newPhase == .interacting {
                shouldAutoScroll = false
                isManuallyScrolling = true
            } else if newPhase == .idle {
                if oldPhase != .animating {
                    shouldAutoScroll = scrollEdgeMetrics.isAtBottom
                }
                isManuallyScrolling = false
            }
        }
    }

    var jumpToBottomButton: some View {
        Button {
            shouldAutoScroll = true
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
        .transition(.scale.combined(with: .opacity))
    }

    /// The live subagent run (Feature B) a transcript row links to, if any:
    /// only `subagent` tool steps, only when the capability is advertised,
    /// and only while the run is still live (matched by the toolCallId the
    /// subagent extension records in the run's meta at spawn).
    func liveSubagentRun(for item: CodeTranscriptItem) -> CodeSubagentInfo? {
        guard viewModel.canAttachSubagents,
              case let .toolStep(_, toolName, toolCallId, _, _, _)
              = item,
              toolName.lowercased() == "subagent"
        else { return nil }
        return session.liveSubagents.first { $0.toolCallId == toolCallId }
    }

    // MARK: - Actions

    func handleSend() {
        let text = inputText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else { return }
        inputText = ""

        if session.isStreaming {
            viewModel.send(.sendSteer(text: text))
        } else {
            viewModel.send(.sendPrompt(text: text))
        }
        shouldAutoScroll = true
    }
}

/// Feature B attach presentation: fullScreenCover on iOS, .sheet on macOS.
/// A ViewModifier keeps `body`'s chain a single simple call (the
/// type-checker rejects the mid-chain #if version). The live attach state
/// wins over the presentation-time copy so the view keeps streaming while
/// presented; the finished state stays up (m6).
private struct AttachCoverModifier: ViewModifier {
    let session: CodeViewModel.SessionState
    let viewModel: CodeViewModel

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(item: attachBinding) {
                attachView($0)
            }
        #else
            content.sheet(item: attachBinding) {
                attachView($0).frame(width: 520, height: 640)
            }
        #endif
    }

    /// sheet/fullScreenCover `item:` bindings take `Binding<Item?>`; the
    /// setter routes dismissal through the explicit detach (the same path
    /// as the view's Close button).
    private var attachBinding: Binding<CodeViewModel.AttachedSubagent?> {
        Binding(
            get: { session.attachedSubagent },
            set: { newValue in
                guard newValue == nil else { return }
                if let id = session.attachedSubagent?.info.id {
                    viewModel.detachSubagent(subagentId: id)
                }
            }
        )
    }

    func attachView(
        _ presented: CodeViewModel.AttachedSubagent
    ) -> some View {
        CodeSubagentAttachView(
            attached: session.attachedSubagent ?? presented,
            isConnecting: viewModel.pendingAttach != nil,
            onDetach: { id in
                viewModel.detachSubagent(subagentId: id)
            }
        )
    }
}

private func previewSession(
    name: String = "",
    tokens: Int = 94225
) -> CodeViewModel.SessionState {
    var session = CodeViewModel.SessionState(
        sessionId: "test",
        cwd: "~/code/openclient-llm",
        model: CodeModelInfo(
            provider: "zai",
            id: "qwen3.8-27b"
        )
    )
    if !name.isEmpty {
        session.sessionName = name
    }
    session.contextUsage = CodeContextUsage(
        tokens: tokens, contextWindow: 128_000, percent: Double(tokens) / 128_000
    )
    return session
}

#Preview("Header — cwd (orange gauge)") {
    NavigationStack {
        CodeSessionView(
            session: previewSession(),
            viewModel: CodeViewModel()
        )
    }
}

#Preview("Header — named session (low usage)") {
    NavigationStack {
        CodeSessionView(
            session: previewSession(name: "openclient-llm", tokens: 20000),
            viewModel: CodeViewModel()
        )
    }
}

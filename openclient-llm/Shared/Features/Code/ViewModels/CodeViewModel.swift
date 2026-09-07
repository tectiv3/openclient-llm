//
//  CodeViewModel.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation

#if os(iOS)
    import UIKit
#endif

@Observable
@MainActor
final class CodeViewModel {
    // MARK: - Types

    enum Event {
        case viewAppeared
        case connect(host: String, port: Int, code: String)
        case cancelConnect
        case disconnect
        case sendPrompt(text: String)
        case sendSteer(text: String)
        case retryPrompt(id: UUID)
        case abort
        case answer(id: String, value: String, wasCustom: Bool, index: Int?)
        case answerQuestionnaire(
            id: String,
            answers: [CodeQuestionnaireAnswer]
        )
        case refreshState
        case appDidEnterBackground
        case appWillEnterForeground
        case retry
        case clearToast
    }

    enum State: Equatable {
        case disconnected
        case connecting
        case connected(SessionState)
        case reconnecting(SessionState)
        case failed(errorMessage: String)
    }

    struct ConnectForm: Equatable {
        var host: String = ""
        var port: Int = 47800
        var code: String = ""
        var errorMessage: String?
        var hasSavedHost: Bool = false
        /// When a rate_limited error is received, the date the pairing-code
        /// lockout (fixed 60s per spec A7) lifts, so the UI can show a countdown.
        var rateLimitedUntil: Date?
    }

    struct SessionState: Equatable {
        var sessionId: String = ""
        var cwd: String = ""
        var model: CodeModelInfo?
        var isStreaming: Bool = false
        var contextUsage: CodeContextUsage?
        var items: [CodeTranscriptItem] = []
        var pendingQuestion: PendingQuestion?
    }

    struct PendingQuestion: Equatable, Identifiable {
        let id: String
        let kind: PendingQuestionKind
    }

    enum PendingQuestionKind: Equatable {
        case question(CodeQuestionParams)
        case questionnaire(CodeQuestionnaireParams)
    }

    /// Last-used connect credentials, retained in-memory because the pairing
    /// code is ephemeral (not persisted) and needed for auto-reconnect.
    struct ConnectCredentials: Equatable {
        let host: String
        let port: Int
        let code: String
    }

    // MARK: - Properties

    private(set) var state: State

    private(set) var client: CodeServerClientProtocol
    private(set) var settingsManager: SettingsManagerProtocol
    var eventTask: Task<Void, Never>?
    var queuedAnswer: CodeClientMessage?

    private(set) var backgroundUseCase: CodeBackgroundUseCaseProtocol
    private(set) var notificationManager: LocalNotificationManagerProtocol
    private(set) var remoteNotificationManager: RemoteNotificationManagerProtocol

    /// Persists across state transitions so editable fields survive
    /// .disconnected → .connecting → .disconnected cycles.
    var connectForm: ConnectForm

    private(set) var lastConnect: ConnectCredentials?
    var backgroundDisconnected = false

    /// True while the in-flight connection was auto-initiated from
    /// `viewAppeared` (push-token auth). WHY: lets auth failures
    /// distinguish "server no longer knows this device's token" from a
    /// user-typed bad pairing code, so the former can fail silently.
    private(set) var isAutoConnectAttempt = false

    /// WHY: bounds auto-connect to one attempt per ViewModel lifetime —
    /// a failed auto attempt or a user-initiated disconnect must not be
    /// silently retried when the tab re-appears.
    private(set) var autoConnectSuppressed = false

    /// Question id that already produced a local notification, keeping the
    /// arrival-while-backgrounded and background-transition paths idempotent.
    var notifiedQuestionId: String?

    /// Transient toast text (e.g. question resolved on another device),
    /// displayed by the session view which clears it after dismissal.
    var transientToast: String?

    /// Prompt-echo UUIDs sent but not yet acknowledged (agent_start) or
    /// rejected (not_idle). An ordered array so the rejection can always
    /// be attributed to the newest pending echo; steers are excluded
    /// because the server never rejects them not_idle. Shared with the
    /// CodeViewModel+Messages extension (agent_start clears the list).
    var pendingPromptEchoes: [UUID] = []

    /// Testability seam: production reads UIApplication state on every call;
    /// tests override this to simulate backgrounding without UIApplication.
    var isBackgrounded: @MainActor () -> Bool = {
        #if os(iOS)
            UIApplication.shared.applicationState == .background
        #else
            false
        #endif
    }

    // MARK: - Init

    init(
        client: CodeServerClientProtocol = CodeServerClient(),
        settingsManager: SettingsManagerProtocol = SettingsManager(),
        backgroundUseCase: CodeBackgroundUseCaseProtocol = CodeBackgroundUseCase(),
        notificationManager: LocalNotificationManagerProtocol = LocalNotificationManager(),
        remoteNotificationManager: RemoteNotificationManagerProtocol =
            RemoteNotificationManager.shared
    ) {
        let host = settingsManager.getCodeHost() ?? ""
        let port = settingsManager.getCodePort()
        let hasSaved = !host.isEmpty
        connectForm = ConnectForm(
            host: host,
            port: port > 0 ? port : 47800,
            hasSavedHost: hasSaved
        )
        state = .disconnected
        self.client = client
        self.settingsManager = settingsManager
        self.backgroundUseCase = backgroundUseCase
        self.notificationManager = notificationManager
        self.remoteNotificationManager = remoteNotificationManager
        self.remoteNotificationManager.setOnTokenUpdate { [weak self] token in
            self?.sendPushTokenIfNeeded(token)
        }
    }

    func send(_ event: Event) {
        switch event {
        case .viewAppeared:
            handleViewAppeared()
        case let .connect(host, port, code):
            handleConnect(host: host, port: port, code: code)
        case .cancelConnect:
            handleCancelConnect()
        case .disconnect:
            handleDisconnect()
        case let .sendPrompt(text):
            handleSendPrompt(text)
        case let .sendSteer(text):
            handleSendSteer(text)
        case let .retryPrompt(id):
            handleRetryPrompt(id: id)
        case .abort:
            handleAbort()
        case let .answer(id, value, wasCustom, index):
            handleAnswer(
                id: id, value: value,
                wasCustom: wasCustom, index: index
            )
        case let .answerQuestionnaire(id, answers):
            handleAnswerQuestionnaire(id: id, answers: answers)
        case .retry:
            handleRetry()
        case .refreshState:
            Task { await client.send(.getState) }
        case .appDidEnterBackground:
            handleAppDidEnterBackground()
        case .appWillEnterForeground:
            handleAppWillEnterForeground()
        case .clearToast:
            transientToast = nil
        }
    }
}

// MARK: - Connection Lifecycle

private extension CodeViewModel {
    func handleConnect(host: String, port: Int, code: String) {
        // Manual intent overrides any auto-attempt bookkeeping.
        isAutoConnectAttempt = false
        settingsManager.setCodeHost(host)
        settingsManager.setCodePort(port)
        lastConnect = ConnectCredentials(
            host: host, port: port, code: code
        )
        // The user-facing "connect to RC" moment: ask for push permission
        // so RC finished/question pushes can reach this device.
        Task { await remoteNotificationManager.requestAuthorization() }
        establishConnection(host: host, port: port, code: code)
    }

    /// Token-based auto-connect on screen appearance. The RC server accepts
    /// a hello carrying the currently-registered push token even without a
    /// pairing code, so a returning user with a saved host skips code entry.
    /// No `requestAuthorization()` here: a token implies prior registration.
    func handleViewAppeared() {
        guard case .disconnected = state,
              !autoConnectSuppressed,
              remoteNotificationManager.getToken() != nil
        else { return }

        // Same source of truth as `disconnectedForm()`: settings, not the
        // user-editable connect form fields.
        let host = settingsManager.getCodeHost() ?? ""
        let port = settingsManager.getCodePort()
        guard !host.isEmpty else { return }

        let portValue = port > 0 ? port : 47800
        isAutoConnectAttempt = true
        // Empty code so retry/foreground-reconnect re-auth via the token.
        lastConnect = ConnectCredentials(host: host, port: portValue, code: "")
        establishConnection(host: host, port: portValue, code: "")
    }

    func handleCancelConnect() {
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()
        backgroundUseCase.end()
        backgroundDisconnected = false
        isAutoConnectAttempt = false
        autoConnectSuppressed = true

        resetToDisconnected()
    }

    func handleRetry() {
        guard let last = lastConnect else {
            handleDisconnect()
            return
        }
        establishConnection(host: last.host, port: last.port, code: last.code)
    }

    func handleDisconnect() {
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()
        queuedAnswer = nil
        backgroundUseCase.end()
        backgroundDisconnected = false
        isAutoConnectAttempt = false
        autoConnectSuppressed = true

        resetToDisconnected()
    }

    func handleAbort() {
        guard case .connected = state else { return }
        Task { await client.send(.abort) }
    }
}

// MARK: - Event Handling

extension CodeViewModel {
    func establishConnection(host: String, port: Int, code: String) {
        state = .connecting
        queuedAnswer = nil
        backgroundDisconnected = false

        let stream = client.connect(
            host: host, port: port, code: code
        )
        eventTask?.cancel()
        eventTask = Task {
            await client.send(.hello(code: code, token: remoteNotificationManager.getToken()))
            for await event in stream {
                guard !Task.isCancelled else { break }
                handleEvent(event)
            }
        }
    }

    func handleEvent(_ event: CodeEvent) {
        switch event {
        case .helloOk:
            handleHelloOk()

        case let .state(info):
            handleStateInfo(info)

        case let .history(history):
            handleHistory(history)

        case let .event(streamEvent):
            handleStreamEvent(streamEvent)

        case let .streamingBuffer(sessionId, content):
            handleStreamingBuffer(
                sessionId: sessionId, content: content
            )

        case let .question(question):
            handleQuestionReceived(question)

        case let .questionnaire(questionnaire):
            handleQuestionnaireReceived(questionnaire)

        case let .questionResolved(resolved):
            handleQuestionResolved(resolved)

        case .pong:
            break

        case let .error(error):
            handleError(error)

        case .connectionLost:
            transitionToReconnecting()

        case let .connectionFailed(message):
            backgroundUseCase.end()
            // WHY: a failed auto attempt must not be retried on the next
            // tab appearance; the failed screen lets the user decide.
            if isAutoConnectAttempt {
                autoConnectSuppressed = true
                isAutoConnectAttempt = false
            }
            state = .failed(errorMessage: message)

        case let .authFailed(error):
            handleAuthFailed(error)

        case .disconnected:
            transitionToReconnecting()

        case .unknown:
            break
        }
    }

    private func handleHelloOk() {
        isAutoConnectAttempt = false
        switch state {
        case .connecting:
            state = .connected(SessionState())
            sendPushTokenIfNeeded()
        case let .reconnecting(session):
            state = .connected(session)
            sendQueuedAnswerIfNeeded()
            sendPushTokenIfNeeded()
        default:
            break
        }
    }

    /// Registers the device token with the server now that the handshake
    /// completed. Fires on first connect and on every reconnect. Duplicate
    /// sends are harmless: the server keeps the last-registered token.
    private func sendPushTokenIfNeeded(_ token: String? = nil) {
        let tokenToSend = token ?? remoteNotificationManager.getToken()
        guard let tokenToSend, case .connected = state else {
            LogManager.info("Push token skipped: hasToken=\(token != nil || remoteNotificationManager.getToken() != nil)")
            return
        }
        LogManager.info("Sending push token (\(tokenToSend.prefix(8))…)")
        Task { await client.send(.pushToken(token: tokenToSend)) }
    }

    private func handleStateInfo(_ info: CodeSessionInfo) {
        guard var session = currentSession else { return }

        let isRebind = !session.sessionId.isEmpty
            && session.sessionId != info.sessionId

        if isRebind {
            session.items = []
            session.pendingQuestion = nil
            pendingPromptEchoes.removeAll()
        }

        session.sessionId = info.sessionId
        session.cwd = info.cwd
        session.model = info.model
        session.isStreaming = info.isStreaming
        session.contextUsage = info.contextUsage

        // Authoritative server state: when not streaming, close out any
        // bubbles still marked as streaming (agent_settled may not arrive,
        // e.g. after reconnect).
        if !info.isStreaming {
            finalizeStreamingBubbles(in: &session)
        }

        updateSession(session)
    }

    private func handleHistory(_ history: CodeHistory) {
        guard var session = currentSession else { return }
        guard history.sessionId == session.sessionId else { return }

        // The transcript is replaced wholesale, so local-echo UUIDs are
        // gone: a failure mark arriving for one is a safe no-op.
        pendingPromptEchoes.removeAll()
        let items = mapHistoryToItems(history.messages)
        session.items = items
        updateSession(session)
    }

    private func handleStreamingBuffer(
        sessionId: String,
        content: [CodeContentBlock]
    ) {
        guard var session = currentSession,
              sessionId == session.sessionId else { return }

        let item = CodeTranscriptItem.assistant(
            id: UUID(), content: content, isStreaming: true
        )
        session.items.append(item)
        updateSession(session)
    }

    private func handleError(_ error: CodeServerError) {
        guard error.code == "not_idle" else { return }
        transientToast = error.message
            ?? String(localized: "Cannot send while streaming")

        // The error frame carries no prompt text, so correlate by ID:
        // the server processes prompts in order and rejects only prompts
        // (a steer always goes through), so the rejection belongs to the
        // newest echo still pending.
        markPendingEchoFailed()
    }

    /// Marks the newest pending prompt echo failed by UUID and removes it
    /// from the pending list. No-op when the echo no longer exists in the
    /// transcript (e.g. a history sync replaced the items in the meantime).
    private func markPendingEchoFailed() {
        guard var session = currentSession,
              !pendingPromptEchoes.isEmpty
        else { return }

        let id = pendingPromptEchoes.removeLast()
        guard let index = session.items.firstIndex(where: {
            if case let .user(itemId, _, _) = $0 {
                return itemId == id
            }
            return false
        }) else {
            LogManager.warning(
                "Code not_idle: pending prompt echo not found"
            )
            return
        }

        if case let .user(itemId, text, _) = session.items[index] {
            session.items[index] = .user(
                id: itemId, text: text, failed: true
            )
            updateSession(session)
        }
    }

    private func transitionToReconnecting() {
        switch state {
        case let .connected(session):
            state = .reconnecting(session)
        case .connecting:
            state = .failed(
                errorMessage: String(
                    localized: "Connection lost"
                )
            )
        default:
            break
        }
    }

    func authErrorMessage(_ error: CodeServerError) -> String {
        switch error.code {
        case "bad_code":
            return String(
                localized: "Invalid code — check the code shown in pi"
            )
        case "rate_limited":
            return String(
                localized: "Too many attempts — wait 60s"
            )
        default:
            return error.message ?? String(
                localized: "Authentication failed"
            )
        }
    }

    private func handleAuthFailed(_ error: CodeServerError) {
        let wasReconnecting: Bool
        if case .reconnecting = state {
            wasReconnecting = true
        } else {
            wasReconnecting = false
        }

        backgroundUseCase.end()

        // WHY: a bad_code on a token-auth auto attempt means the server no
        // longer knows this device (pi restarted, first pairing) — the clean
        // code-entry form is more useful than an error about a code the user
        // never typed. rate_limited stays visible: it is actionable.
        let message: String?
        if wasReconnecting, error.code == "bad_code" {
            message = String(localized: "Pairing code expired — re-pair from pi")
        } else if isAutoConnectAttempt, error.code == "bad_code" {
            message = nil
        } else {
            message = authErrorMessage(error)
        }

        connectForm = disconnectedForm(errorMessage: message)
        if error.code == "rate_limited" {
            connectForm.rateLimitedUntil = Date.now
                .addingTimeInterval(Self.rateLimitSeconds)
        }
        state = .disconnected

        // Suppression applies to any failed auto attempt, including
        // rate_limited: bounded retries, one shot.
        if isAutoConnectAttempt {
            autoConnectSuppressed = true
            isAutoConnectAttempt = false
        }
    }

    private func sendQueuedAnswerIfNeeded() {
        guard let answer = queuedAnswer else { return }
        queuedAnswer = nil
        Task { await client.send(answer) }
    }

    // MARK: - Session Helpers

    private static let rateLimitSeconds: TimeInterval = 60

    var currentSession: SessionState? {
        switch state {
        case let .connected(session), let .reconnecting(session):
            return session
        default:
            return nil
        }
    }

    func resetToDisconnected() {
        pendingPromptEchoes.removeAll()
        connectForm = disconnectedForm()
        state = .disconnected
    }

    func updateSession(_ session: SessionState) {
        switch state {
        case .connected:
            state = .connected(session)
        case .reconnecting:
            state = .reconnecting(session)
        default:
            break
        }
    }

    func disconnectedForm(
        errorMessage: String? = nil
    ) -> ConnectForm {
        let host = settingsManager.getCodeHost() ?? ""
        let port = settingsManager.getCodePort()
        return ConnectForm(
            host: host,
            port: port > 0 ? port : 47800,
            errorMessage: errorMessage,
            hasSavedHost: !host.isEmpty
        )
    }
}

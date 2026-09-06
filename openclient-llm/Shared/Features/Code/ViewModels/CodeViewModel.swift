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
        case connect(host: String, port: Int, code: String)
        case cancelConnect
        case disconnect
        case sendPrompt(text: String)
        case sendSteer(text: String)
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
        case disconnected(ConnectForm)
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
        // When a rate_limited error is received, the date the pairing-code
        // lockout (fixed 60s per spec A7) lifts, so the UI can show a countdown.
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

    let client: CodeServerClientProtocol
    let settingsManager: SettingsManagerProtocol
    var eventTask: Task<Void, Never>?
    var queuedAnswer: CodeClientMessage?

    // Shared with the CodeViewModel+Background / +Questions extensions.
    let backgroundUseCase: CodeBackgroundUseCaseProtocol
    let notificationManager: LocalNotificationManagerProtocol

    // Last successful-connect credentials (code is ephemeral, so the VM must
    // retain it to auto-reconnect after a background disconnect).
    var lastConnect: ConnectCredentials?
    var backgroundDisconnected = false

    // Transient toast text (e.g. question resolved on another device),
    // displayed by the session view which clears it after dismissal.
    var transientToast: String?

    // Testability seam: production reads UIApplication state on every call;
    // tests override this to simulate backgrounding without UIApplication.
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
        notificationManager: LocalNotificationManagerProtocol = LocalNotificationManager()
    ) {
        let host = settingsManager.getCodeHost() ?? ""
        let port = settingsManager.getCodePort()
        let hasSaved = !host.isEmpty
        self.state = .disconnected(ConnectForm(
            host: host,
            port: port > 0 ? port : 47800,
            hasSavedHost: hasSaved
        ))
        self.client = client
        self.settingsManager = settingsManager
        self.backgroundUseCase = backgroundUseCase
        self.notificationManager = notificationManager
    }

    func send(_ event: Event) {
        switch event {
        case .connect(let host, let port, let code):
            handleConnect(host: host, port: port, code: code)
        case .cancelConnect:
            handleCancelConnect()
        case .disconnect:
            handleDisconnect()
        case .sendPrompt(let text):
            handleSendPrompt(text)
        case .sendSteer(let text):
            handleSendSteer(text)
        case .abort:
            handleAbort()
        case .answer(let id, let value, let wasCustom, let index):
            handleAnswer(
                id: id, value: value,
                wasCustom: wasCustom, index: index
            )
        case .answerQuestionnaire(let id, let answers):
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
        settingsManager.setCodeHost(host)
        settingsManager.setCodePort(port)
        lastConnect = ConnectCredentials(
            host: host, port: port, code: code
        )
        establishConnection(host: host, port: port, code: code)
    }

    func handleCancelConnect() {
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()
        backgroundUseCase.end()
        backgroundDisconnected = false

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

        resetToDisconnected()
    }

    func handleSendPrompt(_ text: String) {
        guard case .connected(let session) = state,
              !session.isStreaming else { return }
        Task { await client.send(.prompt(text: text)) }
    }

    func handleSendSteer(_ text: String) {
        guard case .connected(let session) = state,
              session.isStreaming else { return }
        Task { await client.send(.steer(text: text)) }
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
            await client.send(.hello(code: code))
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

        case .state(let info):
            handleStateInfo(info)

        case .history(let history):
            handleHistory(history)

        case .event(let streamEvent):
            handleStreamEvent(streamEvent)

        case .streamingBuffer(let sessionId, let content):
            handleStreamingBuffer(
                sessionId: sessionId, content: content
            )

        case .question(let question):
            handleQuestionReceived(question)

        case .questionnaire(let questionnaire):
            handleQuestionnaireReceived(questionnaire)

        case .questionResolved(let resolved):
            handleQuestionResolved(resolved)

        case .pong:
            break

        case .error(let error):
            handleError(error)

        case .connectionLost:
            transitionToReconnecting()

        case .connectionFailed(let message):
            backgroundUseCase.end()
            state = .failed(errorMessage: message)

        case .authFailed(let error):
            handleAuthFailed(error)

        case .disconnected:
            transitionToReconnecting()

        case .unknown:
            break
        }
    }

    private func handleHelloOk() {
        switch state {
        case .connecting:
            state = .connected(SessionState())
        case .reconnecting(let session):
            state = .connected(session)
            sendQueuedAnswerIfNeeded()
        default:
            break
        }
    }

    private func handleStateInfo(_ info: CodeSessionInfo) {
        guard var session = currentSession else { return }

        let isRebind = !session.sessionId.isEmpty
            && session.sessionId != info.sessionId

        if isRebind {
            session.items = []
            session.pendingQuestion = nil
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
        if error.code == "not_idle" {
            transientToast = error.message
                ?? String(localized: "Cannot send while streaming")
        }
    }

    private func transitionToReconnecting() {
        switch state {
        case .connected(let session):
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
        backgroundUseCase.end()
        var form = disconnectedForm(
            errorMessage: authErrorMessage(error)
        )
        if error.code == "rate_limited" {
            // Server lockout is a fixed 60s (spec A7); expose the lift
            // date so the connect screen can render a countdown.
            form.rateLimitedUntil = Date.now
                .addingTimeInterval(Self.rateLimitSeconds)
        }
        state = .disconnected(form)
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
        case .connected(let session), .reconnecting(let session):
            return session
        default:
            return nil
        }
    }

    func resetToDisconnected() {
        state = .disconnected(disconnectedForm())
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

//
//  CodeViewModel.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

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
    }

    struct SessionState: Equatable {
        var sessionId: String = ""
        var cwd: String = ""
        var model: CodeModelInfo?
        var isStreaming: Bool = false
        var contextUsage: CodeContextUsage?
        var items: [CodeTranscriptItem] = []
        var pendingQuestion: PendingQuestion?
        var reconnectAttempt: Int = 0
    }

    struct PendingQuestion: Equatable, Identifiable {
        let id: String
        let kind: PendingQuestionKind
    }

    enum PendingQuestionKind: Equatable {
        case question(CodeQuestionParams)
        case questionnaire(CodeQuestionnaireParams)
    }

    // MARK: - Properties

    private(set) var state: State

    let client: CodeServerClientProtocol
    let settingsManager: SettingsManagerProtocol
    var eventTask: Task<Void, Never>?
    var queuedAnswer: CodeClientMessage?

    // MARK: - Init

    init(
        client: CodeServerClientProtocol = CodeServerClient(),
        settingsManager: SettingsManagerProtocol = SettingsManager()
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
        case .refreshState:
            Task { await client.send(.getState) }
        }
    }
}

// MARK: - Connection Lifecycle

private extension CodeViewModel {
    func handleConnect(host: String, port: Int, code: String) {
        settingsManager.setCodeHost(host)
        settingsManager.setCodePort(port)

        state = .connecting
        queuedAnswer = nil

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

    func handleCancelConnect() {
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()

        let host = settingsManager.getCodeHost() ?? ""
        let port = settingsManager.getCodePort()
        state = .disconnected(ConnectForm(
            host: host,
            port: port > 0 ? port : 47800,
            hasSavedHost: !host.isEmpty
        ))
    }

    func handleDisconnect() {
        eventTask?.cancel()
        eventTask = nil
        client.disconnect()
        queuedAnswer = nil

        let host = settingsManager.getCodeHost() ?? ""
        let port = settingsManager.getCodePort()
        state = .disconnected(ConnectForm(
            host: host,
            port: port > 0 ? port : 47800,
            hasSavedHost: !host.isEmpty
        ))
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

        case .connectionFailed(let message):
            state = .failed(errorMessage: message)

        case .authFailed(let error):
            let host = settingsManager.getCodeHost() ?? ""
            let port = settingsManager.getCodePort()
            let errorMsg = authErrorMessage(error)
            state = .disconnected(ConnectForm(
                host: host,
                port: port > 0 ? port : 47800,
                errorMessage: errorMsg,
                hasSavedHost: !host.isEmpty
            ))

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
        guard var session = currentSession else { return }

        if error.code == "not_idle" {
            session.items.append(.user(
                id: UUID(),
                text: error.message
                    ?? String(localized: "Cannot send while streaming")
            ))
        }
        updateSession(session)
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

    func authErrorMessage(
        _ error: CodeServerError
    ) -> String {
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

    private func sendQueuedAnswerIfNeeded() {
        guard let answer = queuedAnswer else { return }
        queuedAnswer = nil
        Task { await client.send(answer) }
    }

    // MARK: - Session Helpers

    var currentSession: SessionState? {
        switch state {
        case .connected(let session), .reconnecting(let session):
            return session
        default:
            return nil
        }
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
}

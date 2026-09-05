//
//  CodeViewModel+Questions.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

#if os(iOS)
import SwiftUI
#endif

// MARK: - Question Handling

extension CodeViewModel {
    func handleAnswer(
        id: String,
        value: String,
        wasCustom: Bool,
        index: Int?
    ) {
        let message = CodeClientMessage.answer(
            id: id,
            value: value,
            wasCustom: wasCustom,
            index: index
        )
        sendOrQueueAnswer(message)
        dismissQuestion(id: id)
    }

    func handleAnswerQuestionnaire(
        id: String,
        answers: [CodeQuestionnaireAnswer]
    ) {
        let message = CodeClientMessage.answerQuestionnaire(
            id: id,
            answers: answers
        )
        sendOrQueueAnswer(message)
        dismissQuestion(id: id)
    }

    func handleQuestionReceived(_ question: CodeQuestion) {
        guard var session = currentSession else { return }
        guard question.sessionId == session.sessionId else { return }

        session.pendingQuestion = PendingQuestion(
            id: question.id,
            kind: .question(question.params)
        )
        updateSession(session)
        notifyIfBackgrounded()
    }

    func handleQuestionnaireReceived(
        _ questionnaire: CodeQuestionnaire
    ) {
        guard var session = currentSession else { return }
        guard questionnaire.sessionId == session.sessionId
        else { return }

        session.pendingQuestion = PendingQuestion(
            id: questionnaire.id,
            kind: .questionnaire(questionnaire.params)
        )
        updateSession(session)
        notifyIfBackgrounded()
    }

    func handleQuestionResolved(
        _ resolved: CodeQuestionResolved
    ) {
        guard var session = currentSession else { return }

        // Single questions and questionnaires both resolve through
        // question_resolved, so one toast branch covers both modal kinds.
        let modalWasShowing = session.pendingQuestion?.id == resolved.id

        // Captured before the pending slot is cleared below, so the
        // transcript entry can still read the question text.
        let questionText = questionTextForId(resolved.id, in: session)

        if modalWasShowing {
            session.pendingQuestion = nil
            transientToast = toastForResolved(by: resolved.resolvedBy)
        }

        if resolved.resolvedBy == "client", let value = resolved.value {
            session.items.append(.resolvedQuestion(
                id: UUID(),
                questionText: questionText,
                answerText: value,
                wasCustom: false
            ))
        }

        updateSession(session)
    }
}

// MARK: - Private

private extension CodeViewModel {
    /// The question survives disconnect and is re-delivered on reconnect, so
    /// the notification is opportunistic — only shown while backgrounded.
    func notifyIfBackgrounded() {
        #if os(iOS)
        guard isBackgrounded() else { return }
        notificationManager.sendQuestionNotification()
        #endif
    }

    func sendOrQueueAnswer(_ message: CodeClientMessage) {
        switch state {
        case .connected:
            Task { await client.send(message) }
        case .reconnecting:
            queuedAnswer = message
        default:
            break
        }
    }

    func toastForResolved(by resolvedBy: String) -> String? {
        switch resolvedBy {
        case "client":
            return String(localized: "Answered from another device.")
        case "cancelled":
            return String(localized: "Question cancelled.")
        default:
            return nil
        }
    }

    func dismissQuestion(id: String) {
        guard var session = currentSession else { return }
        guard session.pendingQuestion?.id == id else { return }
        session.pendingQuestion = nil
        updateSession(session)
    }

    func questionTextForId(
        _ id: String,
        in session: SessionState
    ) -> String {
        if let pending = session.pendingQuestion,
           pending.id == id {
            switch pending.kind {
            case .question(let params):
                return params.question
            case .questionnaire:
                return String(localized: "Questionnaire")
            }
        }
        return ""
    }
}

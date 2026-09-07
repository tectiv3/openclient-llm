//
//  CodeViewModel+Questions.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation

#if os(iOS)
    import SwiftUI
#endif

// MARK: - Question Handling

extension CodeViewModel {
    /// Answers a pending ask (single- or multi-question). Sends the unified
    /// `answer` frame, dismisses the modal, and appends a transcript entry:
    /// a single-question ask shows its value, a multi-question ask shows the
    /// joined labels.
    func handleAnswer(id: String, answers: [CodeAnswer]) {
        let questionText: String
        if let session = currentSession {
            questionText = questionTextForId(id, in: session)
        } else {
            questionText = ""
        }

        let message = CodeClientMessage.answer(id: id, answers: answers)
        sendOrQueueAnswer(message)
        dismissQuestion(id: id)

        guard var session = currentSession else { return }
        if answers.count == 1, let first = answers.first {
            session.items.append(.resolvedQuestion(
                id: UUID(),
                questionText: questionText,
                answerText: first.value,
                wasCustom: first.wasCustom
            ))
        } else {
            let summary = answers.map(\.label).joined(separator: ", ")
            session.items.append(.resolvedQuestion(
                id: UUID(),
                questionText: questionText,
                answerText: summary,
                wasCustom: false
            ))
        }
        updateSession(session)
    }

    func handleQuestionReceived(_ question: CodeQuestion) {
        guard var session = currentSession else { return }
        guard question.sessionId == session.sessionId else { return }

        session.pendingQuestion = PendingQuestion(
            id: question.id,
            params: question.params
        )
        updateSession(session)
        notifyIfBackgrounded()
    }

    func handleQuestionResolved(
        _ resolved: CodeQuestionResolved
    ) {
        guard var session = currentSession else { return }

        let modalWasShowing = session.pendingQuestion?.id == resolved.id
        let questionText = questionTextForId(resolved.id, in: session)

        if modalWasShowing {
            session.pendingQuestion = nil
            transientToast = toastForResolved(by: resolved.resolvedBy)

            if resolved.resolvedBy == "client", let value = resolved.value {
                session.items.append(.resolvedQuestion(
                    id: UUID(),
                    questionText: questionText,
                    answerText: value,
                    wasCustom: false
                ))
            }
        }

        updateSession(session)
    }

    /// Fires the pending-question local notification at most once per
    /// question id, covering both paths: a question frame arriving while
    /// backgrounded and a question still showing when the app backgrounds
    /// (its APNs push was suppressed while the app was active).
    func notifyPendingQuestionIfNeeded() {
        #if os(iOS)
            guard let questionId = currentSession?.pendingQuestion?.id,
                  notifiedQuestionId != questionId
            else { return }
            notifiedQuestionId = questionId
            notificationManager.sendQuestionNotification(id: questionId)
        #endif
    }
}

// MARK: - Private

private extension CodeViewModel {
    /// The question survives disconnect and is re-delivered on reconnect, so
    /// the notification is opportunistic — only shown while backgrounded.
    func notifyIfBackgrounded() {
        #if os(iOS)
            guard isBackgrounded() else { return }
            notifyPendingQuestionIfNeeded()
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
           pending.id == id
        {
            // The first question's prompt — mirrors the question push body.
            return pending.params.questions.first?.prompt ?? ""
        }
        return ""
    }
}

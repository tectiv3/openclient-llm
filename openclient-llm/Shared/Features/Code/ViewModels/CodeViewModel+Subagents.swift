//
//  CodeViewModel+Subagents.swift
//  openclient-llm
//
//  Feature B (docs/plans/2026-09-13-rc-subagent-attach-stop-ux.md): the
//  phone-side half of the pi subagent attach — the `subagents` list frame,
//  the attach snapshot + relayed `subagent_event` stream, and the settle
//  frame. The attach's items live on `SessionState.attachedSubagent`, NOT
//  in the main transcript.

import Foundation

extension CodeViewModel {
    /// Feature B frame routing (single compound branch in `handleEvent`
    /// keeps that switch lean; the payload routing lives here with the
    /// handlers).
    func handleSubagentFrame(_ event: CodeEvent) {
        switch event {
        case let .subagents(list):
            handleSubagents(list)
        case let .subagentSnapshot(snapshot):
            handleSubagentSnapshot(snapshot)
        case let .subagentEvent(subagentId, name, payload):
            handleSubagentEvent(subagentId: subagentId, name: name, payload: payload)
        case let .subagentSettled(subagentId, status, stopReason):
            handleSubagentSettled(subagentId: subagentId, status: status, stopReason: stopReason)
        default:
            break
        }
    }

    // MARK: - Capability

    /// M4 rollout gate: only Feature B requests when `hello_ok` advertised
    /// the "subagents" feature. Older servers send nothing and the step
    /// affordance is simply absent.
    var canAttachSubagents: Bool {
        subagentFeatures.contains("subagents")
    }

    // MARK: - Incoming Frames

    /// `subagents` frame (full live-run list; may be empty): wholesale
    /// replace the list — there is no diff. Also the reconnect-reattach
    /// hook (m4): the server's per-connection attach dies with the socket,
    /// so if the run we had attached to is still live, re-send the attach
    /// (its snapshot follows in the same burst); if it's gone, close the
    /// attach locally — the run ended while we were dark.
    func handleSubagents(_ list: [CodeSubagentInfo]) {
        guard var session = currentSession else { return }
        if let attached = session.attachedSubagent {
            if list.contains(where: { $0.id == attached.info.id }) {
                sendSubagentRequest(.attachSubagent(
                    subagentId: attached.info.id, toolCallId: nil
                ))
            } else {
                session.attachedSubagent = nil
            }
        }
        session.liveSubagents = list
        updateSession(session)
    }

    /// `subagent_snapshot`: replace the attached run's items wholesale —
    /// committed history through the SAME mapper as the main transcript,
    /// then the in-flight tail through the shared Feature A buffer merge.
    /// Accepted when the attach is already open for this run (row tap,
    /// reconnect re-attach), or when the snapshot is the answer to an
    /// in-flight attach whose run id was unknown until now (a step tap by
    /// toolCallId). Anything else is stale or unsolicited and ignored.
    func handleSubagentSnapshot(_ snapshot: CodeSubagentSnapshot) {
        guard var session = currentSession else { return }
        let attached = session.attachedSubagent
        let pending = pendingAttach
        let knownAttach = attached?.info.id == snapshot.subagentId
        let answersPending = pending?.subagentId == snapshot.subagentId
            || (pending?.subagentId == nil
                && pending?.toolCallId != nil)
        guard knownAttach || answersPending else { return }

        var items = mapHistoryToItems(snapshot.history)
        if let buffer = snapshot.buffer, !buffer.isEmpty {
            mergeBufferIntoItems(buffer, into: &items)
        }
        if !snapshot.running {
            // It settled while the attach request was in flight: no more
            // relayed events will come, so the tail bubble must not sit
            // streaming. The settle frame's status may never arrive.
            finalizeStreamingBubbles(in: &items)
        }
        session.attachedSubagent = .init(
            info: .init(
                id: snapshot.subagentId,
                agent: snapshot.agent,
                task: snapshot.task,
                startedAt: snapshot.startedAt,
                toolCallId: attached?.info.toolCallId ?? pending?.toolCallId,
                model: attached?.info.model
            ),
            items: items,
            running: snapshot.running,
            settledStatus: snapshot.running ? nil : attached?.settledStatus,
            settledStopReason: snapshot.running ? nil : attached?.settledStopReason
        )
        pendingAttach = nil
        updateSession(session)
    }

    /// `subagent_event`: the whitelisted, session-scoped relay of the
    /// attached run's events. Routed to the attach's item array — never
    /// the main transcript — through the SAME reducers the main path uses
    /// (m3), so attach bubbles stream, append, update, and finalize
    /// identically. Unknown names and other runs' events are dropped.
    func handleSubagentEvent(
        subagentId: String, name: String, payload: [String: AnyCodableValue]
    ) {
        guard var session = currentSession,
              let attached = session.attachedSubagent,
              attached.info.id == subagentId
        else { return }

        var items = attached.items
        switch name {
        case "message_start":
            // A new streaming bubble per turn, exactly like the main path.
            items.append(.assistant(
                id: UUID(), content: [], isStreaming: true
            ))
        case "message_update":
            updateLastAssistantContent(
                message: payload["message"], in: &items
            )
        case "tool_execution_start":
            appendToolStep(payload: payload, in: &items)
        case "tool_execution_update":
            updateToolOutput(payload: payload, in: &items)
        case "tool_execution_end":
            markToolStepComplete(payload: payload, in: &items)
        case "turn_end":
            // Ends the current LLM turn's bubble, not the whole run: a
            // multi-turn run keeps streaming; the view stays open until
            // its own `subagent_settled`.
            finalizeStreamingBubbles(in: &items)
        default:
            break
        }
        session.attachedSubagent?.items = items
        updateSession(session)
    }

    /// `subagent_settled`: mark the attach settled and KEEP THE VIEW OPEN
    /// on the finished state (m6). The attach stays open until the user
    /// dismisses it; the row leaves `liveSubagents` on the next `subagents`
    /// frame.
    func handleSubagentSettled(
        subagentId: String, status: String, stopReason: String?
    ) {
        guard var session = currentSession,
              var attached = session.attachedSubagent,
              attached.info.id == subagentId
        else {
            // No open attach for this run: nothing to settle locally.
            return
        }
        attached.running = false
        attached.settledStatus = status
        attached.settledStopReason = stopReason
        finalizeStreamingBubbles(in: &attached.items)
        session.attachedSubagent = attached
        updateSession(session)
    }

    // MARK: - Outgoing Requests

    /// An attach request in flight whose run id is unknown until the
    /// snapshot (the transcript step-tap path resolves by toolCallId).
    struct PendingAttach: Equatable {
        let subagentId: String?
        let toolCallId: String?
    }

    /// T6 tap entry points. `info` = the tapped live-run row (known id —
    /// the attach opens optimistically with the row's meta); `toolCallId` =
    /// a transcript `subagent` tool step (the run id only becomes known
    /// when the snapshot answers). One attach at a time: a new tap
    /// replaces the open attach.
    func attachSubagent(
        info: CodeSubagentInfo? = nil, toolCallId: String? = nil
    ) {
        guard canAttachSubagents, info != nil || toolCallId != nil else {
            return
        }
        guard var session = currentSession else { return }
        session.attachedSubagent = info.map { .init(info: $0) }
        pendingAttach = .init(
            subagentId: info?.id, toolCallId: toolCallId ?? info?.toolCallId
        )
        updateSession(session)
        sendSubagentRequest(.attachSubagent(
            subagentId: info?.id, toolCallId: toolCallId ?? info?.toolCallId
        ))
    }

    /// The explicit detach the view's close button sends (m8), plus the
    /// silent orphans: a rebind (handled in `handleStateInfo`) and a return
    /// to the anchor view (`clearSelection`).
    func detachSubagent(subagentId: String) {
        guard var session = currentSession else { return }
        if session.attachedSubagent?.info.id == subagentId {
            session.attachedSubagent = nil
            updateSession(session)
        }
        sendSubagentRequest(.detachSubagent(subagentId: subagentId))
    }

    /// Silent-orphan helper used by the rebind and selection-clear paths:
    /// send the detach only when we actually had an attach open.
    func detachAttachedSubagentIfAny() {
        guard let session = currentSession,
              let attached = session.attachedSubagent
        else { return }
        detachSubagent(subagentId: attached.info.id)
    }

    /// Capability gate applied at send time as well as at the tap handler,
    /// so no Feature B frame ever reaches a server that can't handle it.
    private func sendSubagentRequest(_ message: CodeClientMessage) {
        guard canAttachSubagents else { return }
        Task { await client.send(message) }
    }
}

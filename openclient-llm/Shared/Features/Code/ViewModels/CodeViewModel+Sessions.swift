//
//  CodeViewModel+Sessions.swift
//  openclient-llm
//
//  Created by tectiv3 on 11/09/2026.
//

import Foundation

// MARK: - Multi-Session List

// Multi-session rc (docs/plans/rc-multi-session-spec.md): the anchor
// broadcasts a `sessions` list (one entry per pi process running /rc on
// the box) and the phone selects among them over the same single
// WebSocket. The view stays single-view: selecting rebinds the existing
// SessionState in place, which the anchor-side frame suppression keeps
// safe. Everything degrades to today's single-session UX when the server
// never sends a `sessions` frame.

extension CodeViewModel {
    // MARK: - Types

    /// Live view of the connected pi session, rebuilt from `state`/`history`
    /// frames and transcript events.
    struct SessionState: Equatable {
        var sessionId: String = ""
        var cwd: String = ""
        var sessionName: String = ""
        var model: CodeModelInfo?
        var models: [CodeModelInfo] = []
        var isStreaming: Bool = false
        var compacting: CodeCompacting?
        var contextUsage: CodeContextUsage?
        var items: [CodeTranscriptItem] = []
        var pendingQuestion: PendingQuestion?
        // Feature B: live runs of THIS session's view (a `subagents` frame
        // is a full list — always replaced wholesale, never diffed) and the
        // open attach, if any. Both are session-scoped: a rebind (or
        // returning to the anchor) clears them.
        var liveSubagents: [CodeSubagentInfo] = []
        var attachedSubagent: AttachedSubagent?
    }

    /// An attached subagent run: its meta, and its OWN item array (distinct
    /// from the main transcript's `items` — the attach view renders only
    /// this). `running` false = finished; `settledStatus` is present only
    /// when the `subagent_settled` frame actually arrived (a snapshot can
    /// report a run already ended without the status).
    struct AttachedSubagent: Equatable, Identifiable {
        var info: CodeSubagentInfo
        var items: [CodeTranscriptItem] = []
        var running: Bool = true
        var settledStatus: String?
        var settledStopReason: String?

        var id: String {
            info.id
        }
    }

    /// A pending `question` frame waiting for the phone's answer.
    struct PendingQuestion: Equatable, Identifiable {
        let id: String
        let params: CodeQuestionParams
    }

    // MARK: - Notification Tap (Legacy)

    /// Legacy pre-deep-link tap path: always reconnect via `lastConnect`,
    /// bypassing the foregrounding pass's guards (the burn-out case where
    /// the VM sits in `.failed`). Production now uses
    /// `handleNotificationTap(sessionId:)` (AppDelegate/HomeView); this
    /// Event case is kept only because the legacy test suite
    /// (CodeViewModelTests+NotificationTap.swift) still drives it — remove
    /// case and method together when those tests migrate to the deep-link
    /// API.
    func handleNotificationTapped() {
        // Consume the flag so the foregrounding pass cannot double-connect
        // when it runs after this handler.
        backgroundDisconnected = false
        guard let last = lastConnect else { return }
        if case .connected = state {
            return
        }
        if case .connecting = state {
            return
        }
        establishConnection(host: last.host, port: last.port, code: last.code)
    }

    // MARK: - Incoming Frames

    /// `sessions` frame: the registry view is a full snapshot, so replace
    /// the list wholesale (no diffing). A selection that the fresh list no
    /// longer contains is stale — fall back to the default anchor view and
    /// say so.
    func handleSessions(_ list: [SessionInfo]) {
        sessions = list
        guard let selectedId,
              !list.contains(where: { $0.id == selectedId })
        else {
            return
        }
        clearSelection()
        transientToast = String(localized: "Session no longer exists")
    }

    /// `session_gone` frame: the selected sibling died (its proxy socket
    /// went away). The refreshed list arrives separately in a `sessions`
    /// frame; here we only drop the selection and surface the banner.
    func handleSessionGone(id: String) {
        guard id == selectedId else { return }
        clearSelection()
        transientToast = String(localized: "Session no longer exists")
    }

    /// Called from `handleStateInfo`: a `state` frame carrying the
    /// in-flight select's target sessionId means the snapshot arrived —
    /// and the snapshot IS the select ack (the server sends no separate
    /// ack frame), so cancel the local select watchdog. The rebind itself
    /// (items clear, fields refresh) is handled by `handleStateInfo`.
    func noteSelectedSessionSnapshot(sessionId: String) {
        guard pendingSelectSessionId == sessionId else { return }
        pendingSelectSessionId = nil
        selectTimeoutTask?.cancel()
        selectTimeoutTask = nil
    }

    /// `error` frame with code `session_not_found` (server reply to a
    /// `select_session` for an unknown, pruned, or unreachable entry).
    /// Spec: clear the selection SILENTLY — no banner; the refreshed
    /// `sessions` list is the state (the picker unmarks, and the
    /// transcript's anchor view is already what's on screen).
    func handleSessionNotFound() {
        clearSelection()
    }

    /// Called when the socket is going away: the in-flight select dies
    /// with it, so drop the watchdog. `selectedId` is kept — it is
    /// re-sent by `restoreSelectionIfAny` after the reconnect's helloOk.
    func cancelPendingSelect() {
        pendingSelectSessionId = nil
        selectTimeoutTask?.cancel()
        selectTimeoutTask = nil
    }

    // MARK: - Selection

    /// Selects a session from the `sessions` list (picker row tap).
    /// `selectedId` updates immediately so the picker can mark the row;
    /// the rebind happens when the selected session's snapshot arrives.
    /// While disconnected the selection is remembered and restored by the
    /// post-helloOk re-send (`restoreSelectionIfAny`).
    func selectSession(id: String) {
        guard let entry = sessions.first(where: { $0.id == id }) else {
            // Stale picker row (the list may refresh concurrently); there
            // is nothing valid to select.
            transientToast = String(localized: "Session no longer exists")
            return
        }
        selectedId = id
        startSelect(entry)
    }

    /// Selection restore (spec: §Wire protocol): the anchor's
    /// per-connection selection dies with the socket, and `handleHello`
    /// always sends the anchor's own snapshot after `hello_ok` — so
    /// without this re-send a reconnect while viewing a sibling would
    /// silently land on the anchor session. The brief anchor→sibling
    /// double rebind is harmless (each just clears the transcript).
    func restoreSelectionIfAny() {
        guard case .connected = state,
              let selectedId,
              let entry = sessions.first(where: { $0.id == selectedId })
        else {
            return
        }
        startSelect(entry)
    }

    // MARK: - Notification Tap

    /// Deep-link tap (APNs push with the custom `sessionId` payload key):
    /// resolve the pi session id against the `sessions` list AT TAP TIME
    /// and select the matching entry. A `.connected` tap is a live switch,
    /// not a no-op — the select fires immediately. An unknown/stale
    /// `sessionId` (or nil on a legacy payload) just proceeds with the
    /// normal reconnect — no selection — keeping the documented
    /// "selection is not across launches" default.
    func handleNotificationTap(sessionId: String?) {
        backgroundDisconnected = false
        guard let last = lastConnect else { return }

        if let sessionId {
            if let entry = sessions.first(where: { $0.sessionId == sessionId }) {
                // Set before the state check: on `.connected` this is a live
                // switch (overriding the legacy tap's early return);
                // otherwise it is remembered and `restoreSelectionIfAny`
                // re-sends it after the (already-in-progress or new)
                // connect's helloOk.
                selectedId = entry.id
                if case .connected = state {
                    startSelect(entry)
                } else if case .connecting = state {
                    // Connect already in flight: the post-helloOk restore
                    // re-sends the select.
                } else {
                    // Covers `.disconnected`, `.reconnecting` and `.failed`
                    // (the burn-out case that foregrounding never retries).
                    establishConnection(
                        host: last.host, port: last.port, code: last.code
                    )
                }
                return
            }
            // Known session id, absent from the current list (the session
            // ended since the push was sent): spec — non-destructive banner,
            // keep the existing selection, reconnect as usual.
            transientToast = String(localized: "Session no longer exists")
        }

        if case .connected = state {
            return
        }
        if case .connecting = state {
            return
        }
        establishConnection(
            host: last.host, port: last.port, code: last.code
        )
    }

    // MARK: - Private (Select Lifecycle)

    private func startSelect(_ entry: SessionInfo) {
        guard case .connected = state else {
            // Selection remembered; restoreSelectionIfAny re-sends it
            // after the next helloOk (the server's per-connection
            // selection dies with the socket).
            return
        }
        // Re-selecting the session already on screen: no rebind happens,
        // but the anchor still answers with a snapshot, so a state frame
        // arrives and can ack the select.
        pendingSelectSessionId = entry.sessionId
        selectTimeoutTask?.cancel()
        // Two-phase watchdog (spec §Wire protocol): at 10 s surface a
        // non-destructive toast but KEEP the selection pending; at 20 s
        // behave exactly as if `session_not_found` had arrived (silent
        // clear — no banner, no invented local-only path). Capture the
        // per-instance timeout before the task so both phases use one value.
        let selectTimeout = selectTimeoutSeconds
        selectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(selectTimeout))
            guard let self, pendingSelectSessionId != nil, !Task.isCancelled else { return }
            transientToast = String(localized: "Connecting to session…")
            try? await Task.sleep(for: .seconds(selectTimeout))
            guard pendingSelectSessionId != nil, !Task.isCancelled else { return }
            clearSelection()
        }
        let id = entry.id
        Task { [client] in
            await client.send(.selectSession(id: id))
        }
    }

    private func clearSelection() {
        selectedId = nil
        pendingSelectSessionId = nil
        selectTimeoutTask?.cancel()
        selectTimeoutTask = nil
        detachAttachedSubagentIfAny()
    }
}

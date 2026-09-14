//
//  CodeViewModelTests+Sessions.swift
//  openclient-llm
//
//  Created by tectiv3 on 11/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - Multi-Session ViewModel Tests

//
// Spec: docs/plans/rc-multi-session-spec.md — §Testing, the **Swift** bullet.
// The phone is a single-view client: it holds one SessionState plus a
// `sessions` list and `selectedId`; selecting rebinds the view in place and
// the anchor's frame-suppression rule (server-side) is what keeps that safe.
// These tests exercise the phone-side ViewModel only.

extension CodeViewModelTests {
    // MARK: - 1. List refresh

    /// `sessions` frame is a full snapshot: it replaces the list wholesale,
    /// and a second frame supersedes the first entirely (no diffing).
    func test_sessions_frame_refreshesList_secondFrameReplacesWhole() async throws {
        // Given
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "sA", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")

        // When — first frame
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }

        // Then
        XCTAssertEqual(sut.sessions.map(\.id), ["a", "b"])
        XCTAssertEqual(sut.sessions.map(\.sessionId), ["sA", "sB"])

        // When — second frame, a different entry (wholesale snapshot)
        let rowC = sessionEntry(id: "c", sessionId: "sC")
        mockClient.emit(.sessions([rowC]))
        try await waitUntil { self.sut.sessions.count == 1 }

        // Then — replaced, not appended or merged
        XCTAssertEqual(sut.sessions.map(\.id), ["c"])
        XCTAssertFalse(sut.sessions.contains { $0.id == "a" })
        XCTAssertFalse(sut.sessions.contains { $0.id == "b" })
    }

    // MARK: - 2. Select sends frame

    func test_selectSession_connected_sendsSelectSessionFrame() async throws {
        // Given — connected with a loaded list
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "sA", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }

        // When
        sut.selectSession(id: "b")

        // Then — the frame targets the registry id
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .selectSession(id: id) = $0 {
                    return id == "b"
                }
                return false
            }) == 1
        }
        XCTAssertEqual(sut.selectedId, "b")
    }

    // MARK: - 3. Rebind on snapshot (the snapshot IS the ack)

    /// Selecting a sibling and then receiving its `state` snapshot both acks
    /// the in-flight select (clears the watchdog) and rebinds the view to
    /// that session's content.
    func test_selectSession_snapshotArrives_clearsPendingAndRebinds() async throws {
        // Given — connected on the anchor view; list has a sibling
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }

        // When — select the sibling
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.pendingSelectSessionId == "sB" }

        // When — the sibling's snapshot arrives (the ack)
        mockClient.emit(.state(sessionInfo(sessionId: "sB")))
        try await waitUntil { self.sut.pendingSelectSessionId == nil }

        // Then — watchdog cancelled (no task lingering to time out later)
        XCTAssertNil(sut.selectTimeoutTask, "Watchdog must be cancelled on ack")
        // And — the view rebinds to the snapshot's content
        let session = try XCTUnwrap(currentSession())
        XCTAssertEqual(session.sessionId, "sB")
    }

    // MARK: - 4. session_gone banner path

    /// A `session_gone` for the selected id clears the selection AND shows
    /// the banner; one for a non-selected id is ignored.
    func test_sessionGone_selectedId_clearsSelectionAndToasts_otherIdIgnored() async throws {
        // Given — connected, list loaded, "b" selected
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.selectedId == "b" }

        // When — the selected sibling dies
        mockClient.emit(.sessionGone(id: "b"))
        try await waitUntil { self.sut.selectedId == nil }

        // Then — selection cleared and a non-destructive banner shown
        XCTAssertNil(sut.selectedId)
        XCTAssertEqual(
            sut.transientToast,
            String(localized: "Session no longer exists")
        )

        // Dismiss the banner so the next assertion is unambiguous.
        sut.transientToast = nil

        // When — reselect "b", then a `session_gone` for a NON-selected id
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.selectedId == "b" }
        mockClient.emit(.sessionGone(id: "a"))
        try await Task.sleep(for: .milliseconds(50))

        // Then — ignored: selection intact and no new banner
        XCTAssertEqual(sut.selectedId, "b")
        XCTAssertNil(
            sut.transientToast, "A non-selected id must not raise a banner"
        )
    }

    // MARK: - 5. helloOk -> select re-send (selection restore)

    /// After a drop + reconnect, the post-helloOk restore re-sends
    /// `select_session` for the remembered `selectedId`.
    func test_reconnect_helloOk_resendsSelectForRememberedSelection() async throws {
        // Given — connected on sibling "b" (selectedId retained)
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.selectedId == "b" }
        let sentBeforeDrop = mockClient.attemptsCount(where: {
            if case .selectSession = $0 {
                return true
            }
            return false
        })

        // When — the socket drops and reconnects
        mockClient.emit(.disconnected)
        try await waitUntil {
            if case .reconnecting = self.sut.state {
                return true
            }
            return false
        }
        mockClient.emit(.helloOk(version: 1, features: []))
        try await waitUntil {
            if case .connected = self.sut.state {
                return true
            }
            return false
        }

        // Then — restore re-sent the select for the same id
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .selectSession(id: id) = $0 {
                    return id == "b"
                }
                return false
            }) == sentBeforeDrop + 1
        }
    }

    // MARK: - 6. session_not_found silent clear

    /// An `error` frame with code `session_not_found` (id == selectedId)
    /// clears the selection SILENTLY — no banner; the refreshed list is the
    /// state.
    func test_error_sessionNotFound_clearsSelectionNoToast() async throws {
        // Given — connected, "b" selected
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.selectedId == "b" }

        // When — the server reports the entry is gone
        mockClient.emit(.error(CodeServerError(
            code: "session_not_found", message: nil
        )))

        // Then — selection cleared, but no toast (silent)
        try await waitUntil { self.sut.selectedId == nil }
        XCTAssertNil(sut.selectedId)
        XCTAssertNil(sut.transientToast)
    }

    // MARK: - 7. Two-phase select timeout

    /// With the watchdog shortenable (seam on `selectTimeoutSeconds`):
    /// phase 1 surfaces a "Connecting to session…" toast but KEEPS the
    /// selection pending; phase 2 clears it with NO toast (the
    /// `session_not_found`-equivalent silent clear).
    func test_selectTimeout_twoPhases_toastThenSilentClear() async throws {
        // Given — connected, sibling selected, watchdog retuned to 0.2 s
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }
        sut.selectTimeoutSeconds = 0.2

        // When — select with no snapshot arriving
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.pendingSelectSessionId == "sB" }

        // Then — phase 1: toast shown, selection STILL pending
        try await waitUntil {
            self.sut.transientToast == String(localized: "Connecting to session…")
        }
        XCTAssertEqual(
            sut.transientToast,
            String(localized: "Connecting to session…")
        )
        XCTAssertEqual(sut.pendingSelectSessionId, "sB", "Phase 1 keeps pending")
        XCTAssertEqual(sut.selectedId, "b", "Phase 1 keeps selection")

        // When/Then — phase 2: silent clear (no new banner)
        try await waitUntil { self.sut.selectedId == nil }
        XCTAssertNil(sut.selectedId)
        XCTAssertNil(sut.pendingSelectSessionId)
        // The only toast that ever appeared was the phase-1 one; phase 2
        // must not invent a second one. Clear it and confirm nothing re-fires.
        sut.transientToast = nil
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(sut.transientToast, "Phase 2 clears silently")
    }

    // MARK: - 8. Deep-link select, already-connected override

    /// A deep-link tap for an in-list session while `.connected` is a live
    /// switch: it must NOT be swallowed by the legacy tap's `.connected`
    /// early return.
    func test_notificationTap_connected_selectsAndSendsImmediately() async throws {
        // Given — connected with a loaded list
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowC = sessionEntry(id: "c", sessionId: "sC")
        mockClient.emit(.sessions([rowA, rowC]))
        try await waitUntil { self.sut.sessions.count == 2 }

        // When — deep-link tap for session "c" (by pi sessionId)
        sut.handleNotificationTap(sessionId: "sC")

        // Then — selection becomes "c"'s registry id AND the frame fires
        // immediately (no wait for a reconnect)
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .selectSession(id: id) = $0 {
                    return id == "c"
                }
                return false
            }) == 1
        }
        XCTAssertEqual(sut.selectedId, "c")
        // No spurious second connection was opened.
        XCTAssertEqual(mockClient.connectCalls.count, 1)
    }

    // MARK: - 9. Tap pre-empts restore race

    /// In-memory `selectedId` = B; a tap for C (≠ B) arrives while
    /// disconnected. After connect + helloOk the phone must land on C, not
    /// B — the tap's select is what the post-helloOk restore re-sends.
    func test_notificationTap_disconnected_preEmptsRestore_landsOnTapped() async throws {
        // Given — connected on "b" (selectedId = b), then dropped
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        let rowC = sessionEntry(id: "c", sessionId: "sC")
        mockClient.emit(.sessions([rowA, rowB, rowC]))
        try await waitUntil { self.sut.sessions.count == 3 }
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.selectedId == "b" }
        mockClient.emit(.disconnected)
        try await waitUntil {
            if case .reconnecting = self.sut.state {
                return true
            }
            return false
        }

        // When — tap for "c" while disconnected (pre-empts the B restore)
        sut.handleNotificationTap(sessionId: "sC")
        XCTAssertEqual(sut.selectedId, "c", "Tap rewrites selectedId at tap time")

        // Then — after the reconnect's helloOk, the restore re-sends C (not B)
        mockClient.emit(.helloOk(version: 1, features: []))
        try await waitUntil {
            if case .connected = self.sut.state {
                return true
            }
            return false
        }
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case let .selectSession(id: id) = $0 {
                    return id == "c"
                }
                return false
            }) == 1
        }
        // And B was NOT re-sent as the selection.
        XCTAssertEqual(
            mockClient.attemptsCount(where: {
                if case let .selectSession(id: id) = $0 {
                    return id == "b"
                }
                return false
            }),
            1,
            "Restore must re-send the tapped id, not the stale one"
        )
        XCTAssertEqual(sut.selectedId, "c")
    }

    // MARK: - 10. Deep-link stale sessionId

    /// A deep-link tap whose `sessionId` is absent from the current list:
    /// show the banner, keep the existing selection, and send no select.
    func test_notificationTap_staleSessionId_toastsKeepsSelectionNoSelect() async throws {
        // Given — connected, list loaded, "b" selected
        try await connectAndEstablish()
        let rowA = sessionEntry(id: "a", sessionId: "s1", isAnchor: true)
        let rowB = sessionEntry(id: "b", sessionId: "sB")
        mockClient.emit(.sessions([rowA, rowB]))
        try await waitUntil { self.sut.sessions.count == 2 }
        sut.selectSession(id: "b")
        try await waitUntil { self.sut.selectedId == "b" }
        let selectsBeforeTap = mockClient.attemptsCount(where: {
            if case .selectSession = $0 {
                return true
            }
            return false
        })

        // When — tap references a sessionId not in the list
        sut.handleNotificationTap(sessionId: "sGone")
        try await Task.sleep(for: .milliseconds(100))

        // Then — banner, selection unchanged, and NO NEW select frame
        XCTAssertEqual(
            sut.transientToast,
            String(localized: "Session no longer exists")
        )
        XCTAssertEqual(sut.selectedId, "b")
        XCTAssertEqual(
            mockClient.attemptsCount(where: {
                if case .selectSession = $0 {
                    return true
                }
                return false
            }),
            selectsBeforeTap,
            "Stale tap must not send a select"
        )
    }

    // MARK: - Helpers

    /// Builds a `SessionInfo` list entry for the tests.
    private func sessionEntry(
        id: String, sessionId: String, isAnchor: Bool = false
    ) -> SessionInfo {
        SessionInfo(
            id: id,
            sessionId: sessionId,
            cwd: "/tmp/project",
            name: id,
            model: nil,
            isStreaming: false,
            hasQuestion: false,
            compacting: false,
            lastActivity: nil,
            isAnchor: isAnchor
        )
    }
}

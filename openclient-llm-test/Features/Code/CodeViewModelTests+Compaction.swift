//
//  CodeViewModelTests+Compaction.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Compaction visibility

extension CodeViewModelTests {
    func test_state_withCompacting_setsSessionCompacting() async throws {
        // Given
        try await connectAndEstablish()

        // When — mid-compaction state broadcast
        var info = sessionInfo()
        info.compacting = CodeCompacting(reason: "manual", willRetry: nil)
        mockClient.emit(.state(info))

        // Then
        try await waitUntil {
            self.currentSession()?.compacting?.reason == "manual"
        }
    }

    func test_state_withoutCompacting_clearsSessionCompacting() async throws {
        // Given — a session already showing the compaction banner
        try await connectAndEstablish()
        var info = sessionInfo()
        info.compacting = CodeCompacting(reason: "threshold", willRetry: true)
        mockClient.emit(.state(info))
        try await waitUntil { self.currentSession()?.compacting != nil }

        // When — compaction finished: the follow-up state omits the key
        mockClient.emit(.state(sessionInfo()))

        // Then — banner-clear transition
        try await waitUntil { self.currentSession()?.compacting == nil }
    }

    func test_error_compactionFailed_setsTransientToast() async throws {
        // Given
        try await connectAndEstablish()

        // When — genuine compaction failure (a phone-caused abort
        // reports no error frame)
        mockClient.emit(.error(CodeServerError(
            code: "compaction_failed", message: "boom"
        )))

        // Then
        try await waitUntil { self.sut.transientToast == "boom" }
    }

    func test_error_compactionFailedWithoutMessage_usesLocalizedFallback() async throws {
        // Given
        try await connectAndEstablish()

        // When — the error frame carries no message
        mockClient.emit(.error(CodeServerError(
            code: "compaction_failed", message: nil
        )))

        // Then
        try await waitUntil { self.sut.transientToast != nil }
        XCTAssertEqual(
            sut.transientToast,
            String(localized: "Compaction failed")
        )
    }

    func test_error_compactionFailed_leavesPendingEchoIntact() async throws {
        // Given — a pending prompt echo that not_idle failures would mark
        try await connectAndEstablish()
        sut.send(.sendPrompt(text: "hi"))
        try await waitUntil {
            self.mockClient.attemptsCount(where: {
                if case .prompt = $0 {
                    return true
                }
                return false
            }) == 1
        }

        // When
        mockClient.emit(.error(CodeServerError(
            code: "compaction_failed", message: "boom"
        )))
        try await waitUntil { self.sut.transientToast == "boom" }

        // Then — the compaction error is unrelated to the echo
        let session = try XCTUnwrap(currentSession())
        guard case let .user(_, text, failed, _) = session.items.last else {
            return XCTFail("Expected user echo, got \(session.items.last)")
        }
        XCTAssertEqual(text, "hi")
        XCTAssertFalse(failed)
    }
}

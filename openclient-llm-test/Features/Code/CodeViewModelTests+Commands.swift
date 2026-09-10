//
//  CodeViewModelTests+Commands.swift
//  openclient-llm
//
//  Created by tectiv3 on 10/09/2026.
//

@testable import openclient_llm
import XCTest

// MARK: - CodeViewModelTests — Session commands (sessionName)

extension CodeViewModelTests {
    func test_state_withSessionName_updatesSessionName() async throws {
        // Given
        try await connectAndEstablish()

        // When — a state frame carrying the session name
        mockClient.emit(.state(namedInfo("my session")))

        // Then
        try await waitUntil {
            self.currentSession()?.sessionName == "my session"
        }
    }

    func test_state_withoutSessionName_resetsToEmpty() async throws {
        // Given — the session already has a name
        try await connectAndEstablish()
        mockClient.emit(.state(namedInfo("my session")))
        try await waitUntil { self.currentSession()?.sessionName == "my session" }

        // When — a follow-up state frame omits the name (unnamed session)
        mockClient.emit(.state(sessionInfo()))

        // Then — the state frame is authoritative: nil resets to ""
        try await waitUntil { self.currentSession()?.sessionName == "" }
    }

    /// `sessionInfo()`-shaped frame with an explicit `sessionName`.
    private func namedInfo(_ name: String) -> CodeSessionInfo {
        CodeSessionInfo(
            sessionId: "s1",
            cwd: "/tmp/project",
            sessionName: name,
            model: CodeModelInfo(provider: "pi", id: "model-1"),
            thinkingLevel: nil,
            isStreaming: false,
            contextUsage: nil
        )
    }
}

//
//  CodeEndToEndTests.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

@testable import openclient_llm
import XCTest

/// End-to-end tests for the Code feature (spec C3.1): the real
/// `CodeServerClient` (URLSession WebSocket transport, no mocks) talks to a
/// real pi process running the real rc extension, spawned by `RcE2eServer`.
///
/// Missing prerequisites (no pi binary, no E2E model provider in the host
/// pi config) skip the test; spawn, readiness, or toggle failures fail it
/// with the captured stderr tail.
@MainActor
final class CodeEndToEndTests: XCTestCase {
    // MARK: - Properties

    private var server: RcE2eServer?
    private var mockModel: MockModelServer?
    private var host = "127.0.0.1"
    private var port = 0
    private var code = ""
    private var client: CodeServerClient?
    private var collector: EventCollector?

    // MARK: - XCTestCase

    override func setUp() async throws {
        try await super.setUp()
        guard resolvePiBinary() != nil else {
            throw XCTSkip("pi binary not found (set PI_RC_E2E_PI_BIN). diag: "
                + diagnosePiSearch())
        }
        guard modelProviderConfigured() else {
            throw XCTSkip(
                "no E2E model provider (\(RcE2eServer.e2eProvider)) in ~/.pi/agent/models.json"
            )
        }
        // The simulator blocks the test process from all non-loopback
        // destinations (per-app firewall), so the E2E model is a
        // deterministic mock served on the loopback; the child pi is
        // pointed at it through the mirrored models.json.
        let endpoint = try await startE2EServer()
        mockModel = endpoint.mock
        server = endpoint.server
        host = endpoint.endpoint.host
        port = endpoint.endpoint.port
        code = endpoint.endpoint.code
    }

    override func tearDown() async throws {
        collector?.cancel()
        client?.disconnect()
        client = nil
        collector = nil
        server?.stop()
        server = nil
        mockModel?.stop()
        mockModel = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private static let agentSettled: (CodeEvent) -> Bool = { event in
        if case let .event(stream) = event {
            return stream.name == "agent_settled"
        }
        return false
    }

    /// Connects a fresh client to the paired endpoint and sends the hello
    /// that starts the handshake. The returned collector serves all
    /// sequential assertions for this test.
    private func connectedClient(
        pingInterval: TimeInterval = 30,
        pongTimeout: TimeInterval = 10
    ) async -> (CodeServerClient, EventCollector) {
        let pair = await connectClient(
            host: host, port: port, code: code,
            pingInterval: pingInterval, pongTimeout: pongTimeout
        )
        client = pair.client
        collector = pair.collector
        return (pair.client, pair.collector)
    }

    // MARK: - Tests

    func test_connect_freshClient_receivesHelloStateHistoryInOrder() async {
        // Given
        let (client, collector) = await connectedClient()
        _ = client

        // When / Then — the handshake: helloOk, then state, then history,
        // in that order.
        guard case let .helloOk(version) = await awaitEvent(
            collector, labeled: "helloOk", timeout: 15,
            matching: {
                if case let .helloOk(ver) = $0 {
                    return ver == 1
                }
                return false
            }
        ) else {
            return XCTFail("helloOk had wrong shape")
        }
        XCTAssertEqual(version, 1, "protocol version should be 1")

        guard case let .state(session) = await awaitEvent(
            collector, labeled: "state", timeout: 15,
            matching: {
                if case .state = $0 {
                    return true
                }
                return false
            }
        ) else {
            return XCTFail("state had wrong shape")
        }
        XCTAssertFalse(session.sessionId.isEmpty, "state should carry a sessionId")

        guard case .history = await awaitEvent(
            collector, labeled: "history", timeout: 15,
            matching: {
                if case .history = $0 {
                    return true
                }
                return false
            }
        ) else {
            return XCTFail("history had wrong shape")
        }

        let names = collector.names
        guard
            let helloIndex = names.firstIndex(of: "helloOk"),
            let stateIndex = names.firstIndex(of: "state"),
            let historyIndex = names.firstIndex(of: "history")
        else {
            return XCTFail("expected event names not found: \(names)")
        }
        XCTAssertLessThan(
            helloIndex, stateIndex, "helloOk should precede state: \(names)"
        )
        XCTAssertLessThan(
            stateIndex, historyIndex, "state should precede history: \(names)"
        )
    }

    func test_prompt_pongPrompt_receivesAgentSettledAndHistoryContainsPrompt() async {
        // Given
        let (client, collector) = await connectedClient()

        // When — a prompt that must round-trip through the LLM.
        await client.send(.prompt(text: "Reply with exactly: PONG-E2E"))
        _ = await awaitEvent(
            collector, labeled: "agent_start", timeout: 45,
            matching: {
                if case let .event(stream) = $0 {
                    return stream.name == "agent_start"
                }
                return false
            }
        )
        _ = await awaitEvent(
            collector, labeled: "agent_settled", timeout: 45,
            matching: Self.agentSettled
        )

        // Then — the refreshed history contains the user prompt. The
        // predicate filters on the prompt text because the handshake already
        // delivered an (empty) history earlier.
        await client.send(.getHistory(cursor: nil))
        guard case let .history(history) = await awaitEvent(
            collector, labeled: "history after prompt", timeout: 15,
            matching: {
                if case let .history(hist) = $0 {
                    return hist.messages.contains {
                        if case let .user(text) = $0 {
                            return text.contains("PONG-E2E")
                        }
                        return false
                    }
                }
                return false
            }
        ) else {
            return XCTFail("history had wrong shape")
        }
        XCTAssertTrue(
            history.messages.contains {
                if case let .user(text) = $0 {
                    return text.contains("PONG-E2E")
                }
                return false
            },
            "history should contain the user prompt"
        )
    }

    func test_ask_prompt_receivesQuestionAndResolvesViaClientAnswer() async {
        // Given
        let (client, collector) = await connectedClient()

        // When
        await client.send(.prompt(text: "ASK"))
        guard case let .question(question) = await awaitEvent(
            collector, labeled: "question", timeout: 45,
            matching: {
                if case .question = $0 {
                    return true
                }
                return false
            }
        ) else {
            return XCTFail("question had wrong shape")
        }
        XCTAssertEqual(
            question.kind, "ask_user_question",
            "kind should be 'ask_user_question'"
        )
        guard let sub = question.params.questions.first else {
            return XCTFail("an ask carries at least one question")
        }
        XCTAssertTrue(
            sub.prompt.lowercased().contains("color"),
            "question should mention color, got: \(sub.prompt)"
        )
        let options = sub.options
        XCTAssertGreaterThanOrEqual(options.count, 3, "at least 3 options")
        XCTAssertTrue(options.allSatisfy { !$0.label.isEmpty }, "options carry labels")

        // Then — answer with the third option; expect a client resolution.
        guard options.count >= 3, let thirdIndex = options.firstIndex(of: options[2])
        else {
            return XCTFail("could not pick a third option")
        }
        await client.send(
            .answer(
                id: question.id,
                answers: [
                    CodeAnswer(
                        id: sub.id,
                        value: options[2].resolvedValue,
                        label: options[2].label,
                        wasCustom: false,
                        index: thirdIndex + 1
                    ),
                ]
            )
        )
        guard case let .questionResolved(resolved) = await awaitEvent(
            collector, labeled: "question_resolved", timeout: 10,
            matching: {
                if case let .questionResolved(res) = $0 {
                    return res.id == question.id
                }
                return false
            }
        ) else {
            return XCTFail("questionResolved had wrong shape")
        }
        XCTAssertEqual(
            resolved.resolvedBy, "client", "resolution should come from the client"
        )
        _ = await awaitEvent(
            collector, labeled: "agent_settled after answer", timeout: 60,
            matching: Self.agentSettled
        )
    }

    func test_askform_prompt_receivesQuestionnaireAndResolvesViaAnswers() async {
        // Given
        let (client, collector) = await connectedClient()

        // When
        await client.send(.prompt(text: "ASKFORM"))
        guard case let .question(form) = await awaitEvent(
            collector, labeled: "question (questionnaire)", timeout: 45,
            matching: {
                if case .question = $0 {
                    return true
                }
                return false
            }
        ) else {
            return XCTFail("questionnaire had wrong shape")
        }
        let subQuestions = form.params.questions
        XCTAssertEqual(subQuestions.count, 2, "form should carry two sub-questions")
        let answers = subQuestions.compactMap { sub -> CodeAnswer? in
            guard let option = sub.options.first else { return nil }
            return CodeAnswer(
                id: sub.id,
                value: option.resolvedValue,
                label: option.label,
                wasCustom: false,
                index: 1
            )
        }
        await client.send(.answer(id: form.id, answers: answers))

        // Then
        guard case let .questionResolved(resolved) = await awaitEvent(
            collector, labeled: "questionnaire_resolved", timeout: 10,
            matching: {
                if case let .questionResolved(res) = $0 {
                    return res.id == form.id
                }
                return false
            }
        ) else {
            return XCTFail("questionResolved had wrong shape")
        }
        XCTAssertEqual(
            resolved.resolvedBy, "client", "resolution should come from the client"
        )
        _ = await awaitEvent(
            collector, labeled: "agent_settled after answers", timeout: 60,
            matching: Self.agentSettled
        )
    }

    func test_prompt_whileStreaming_receivesNotIdleErrorThenAbortSettles() async {
        // Given
        let (client, collector) = await connectedClient()

        // When — start a long streaming reply, then reject a second prompt.
        await client.send(.prompt(text: "LONG"))
        _ = await awaitEvent(
            collector, labeled: "streaming start", timeout: 45,
            matching: {
                if case let .event(stream) = $0 {
                    return stream.name == "message_update"
                        || stream.name == "message_start"
                }
                return false
            }
        )
        await client.send(.prompt(text: "rejected"))
        guard case let .error(serverError) = await awaitEvent(
            collector, labeled: "not_idle error", timeout: 5,
            matching: {
                if case let .error(err) = $0 {
                    return err.code == "not_idle"
                }
                return false
            }
        ) else {
            return XCTFail("not_idle error had wrong shape")
        }
        XCTAssertEqual(
            serverError.code, "not_idle",
            "a prompt while streaming should be rejected as not_idle"
        )
        await client.send(.abort)
        _ = await awaitEvent(
            collector, labeled: "agent_settled after abort", timeout: 30,
            matching: Self.agentSettled
        )
    }

    /// The client consumes `pong` internally (keepalive liveness, not a
    /// surfaced event), so ping is verified end-to-end as connection
    /// liveness: with a 2s ping cadence and 1s pong deadline the client
    /// fires several pings; if the server never answered, the client would
    /// declare the connection dead (`connectionLost`) and reconnect. The
    /// connection must stay alive and remain usable afterwards.
    func test_ping_keepaliveConnection_staysAliveAcrossPongDeadlines() async {
        // Given
        let (client, collector) = await connectedClient(pingInterval: 2, pongTimeout: 1)

        // When — an explicit ping on top of the automatic keepalive cadence.
        await client.send(.ping)
        let livenessWindow: TimeInterval = 8
        _ = try? await Task.sleep(for: .seconds(livenessWindow))

        // Then — no liveness failure over several pong deadlines…
        let deathEvents = await collector.names.filter {
            $0 == "connectionLost" || $0 == "connectionFailed" || $0 == "disconnected"
        }
        XCTAssertEqual(deathEvents, [], "connection must stay alive: \(collector.names)")

        // …and the connection still round-trips.
        await client.send(.getState)
        _ = await awaitEvent(
            collector, labeled: "state after ping window", timeout: 10,
            matching: {
                if case .state = $0 {
                    return true
                }
                return false
            }
        )
    }
}

// MARK: - E2E bootstrap

/// A paired mock model server plus the pi server it backs.
struct E2EServerBundle {
    let mock: MockModelServer
    let server: RcE2eServer
    let endpoint: RcE2eServer.RcEndpoint
}

/// Boots the mock model server on the loopback, then the pi server pointed
/// at it (see the note in `setUp`). Failures fail the calling test; an
/// `XCTSkip` from pi resolution propagates unchanged.
@MainActor
func startE2EServer() async throws -> E2EServerBundle {
    let mock = MockModelServer()
    do {
        try mock.start()
    } catch {
        XCTFail("mock model server failed to start: \(error.localizedDescription)")
        throw error
    }
    let server = RcE2eServer()
    server.modelBaseUrlOverride = "http://127.0.0.1:\(mock.port)/v1"
    do {
        try server.start()
        try await server.waitReady(timeout: 30)
        let endpoint = try await server.toggleOn(timeout: 20)
        return E2EServerBundle(mock: mock, server: server, endpoint: endpoint)
    } catch let error as XCTSkip {
        server.stop()
        throw error
    } catch {
        let stderr = server.stderrTailText
        server.stop()
        XCTFail(
            "E2E server setup failed: \(error.localizedDescription) — stderr: \(stderr)"
        )
        throw error
    }
}

/// Connects a fresh client to the paired endpoint and sends the hello that
/// starts the handshake.
@MainActor
func connectClient(
    host: String,
    port: Int,
    code: String,
    pingInterval: TimeInterval = 30,
    pongTimeout: TimeInterval = 10
) async -> (client: CodeServerClient, collector: EventCollector) {
    let client = CodeServerClient(
        pingIntervalSeconds: pingInterval,
        pongTimeoutSeconds: pongTimeout
    )
    let stream = client.connect(host: host, port: port, code: code)
    let collector = EventCollector(stream: stream)
    await client.send(.hello(code: code))
    return (client, collector)
}

/// Waits for the first event matching `predicate`; fails the test with the
/// received event summaries when the timeout elapses (the returned `.unknown`
/// is then detected by the caller's pattern match).
@MainActor
func awaitEvent(
    _ collector: EventCollector,
    labeled label: String,
    timeout: TimeInterval,
    matching: (CodeEvent) -> Bool
) async -> CodeEvent {
    guard let event = await collector.wait(matching: matching, timeout: timeout)
    else {
        let last = collector.summaries.suffix(8)
        XCTFail(
            "\(label) not received within \(Int(timeout))s\n" + last.joined(separator: "\n")
        )
        return .unknown
    }
    return event
}

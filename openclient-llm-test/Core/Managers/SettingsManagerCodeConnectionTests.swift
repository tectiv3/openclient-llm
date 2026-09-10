//
//  SettingsManagerCodeConnectionTests.swift
//  openclient-llm
//
//  Created by tectiv3 on 09/26/2026.
//

@testable import openclient_llm
import XCTest

@MainActor
final class SettingsManagerCodeConnectionTests: XCTestCase {
    // MARK: - Properties

    private var sut: SettingsManager!
    private var mockKeychain: MockKeychainManager!
    private let suiteName = "com.kinchaku.openclient-llm.test.codeConnection"

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        UserDefaults().removePersistentDomain(forName: suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test UserDefaults")
            return
        }
        mockKeychain = MockKeychainManager()
        sut = SettingsManager(defaults: defaults, keychainManager: mockKeychain)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        sut = nil
        mockKeychain = nil

        try await super.tearDown()
    }

    // MARK: - Tests — upsert

    func test_upsert_newConnection_prependsEntryFirst() {
        // Given
        let list = [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
        ]

        // When
        let updated = CodeRecentConnection.upsert(
            CodeRecentConnection(host: "b.ts.net", port: 47900),
            into: list
        )

        // Then
        XCTAssertEqual(updated, [
            CodeRecentConnection(host: "b.ts.net", port: 47900),
            CodeRecentConnection(host: "a.ts.net", port: 47800),
        ])
    }

    func test_upsert_existingHostAndPort_movesToFrontWithoutDuplicate() {
        // Given
        let list = [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
            CodeRecentConnection(host: "b.ts.net", port: 47900),
        ]

        // When
        let updated = CodeRecentConnection.upsert(
            CodeRecentConnection(host: "a.ts.net", port: 47800),
            into: list
        )

        // Then
        XCTAssertEqual(updated, [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
            CodeRecentConnection(host: "b.ts.net", port: 47900),
        ])
    }

    func test_upsert_existingHostChangedPort_movesToFrontAndUpdatesPort() {
        // Given
        let list = [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
            CodeRecentConnection(host: "b.ts.net", port: 47900),
        ]

        // When
        let updated = CodeRecentConnection.upsert(
            CodeRecentConnection(host: "a.ts.net", port: 48000),
            into: list
        )

        // Then
        XCTAssertEqual(updated, [
            CodeRecentConnection(host: "a.ts.net", port: 48000),
            CodeRecentConnection(host: "b.ts.net", port: 47900),
        ])
    }

    func test_upsert_overCap_dropsOldestEntry() {
        // Given — MRU-first: host5 is the most recent, host1 the oldest
        let list = (1 ... 5).reversed().map {
            CodeRecentConnection(host: "host\($0).ts.net", port: 47800)
        }

        // When
        let updated = CodeRecentConnection.upsert(
            CodeRecentConnection(host: "host6.ts.net", port: 47800),
            into: list
        )

        // Then
        XCTAssertEqual(updated, [
            CodeRecentConnection(host: "host6.ts.net", port: 47800),
            CodeRecentConnection(host: "host5.ts.net", port: 47800),
            CodeRecentConnection(host: "host4.ts.net", port: 47800),
            CodeRecentConnection(host: "host3.ts.net", port: 47800),
            CodeRecentConnection(host: "host2.ts.net", port: 47800),
        ])
    }

    func test_upsert_emptyHost_returnsListUnchanged() {
        // Given
        let list = [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
        ]

        // When
        let updated = CodeRecentConnection.upsert(
            CodeRecentConnection(host: "", port: 47800),
            into: list
        )

        // Then
        XCTAssertEqual(updated, list)
    }

    // MARK: - Tests — persistence

    func test_getCodeRecentConnections_defaultIsEmpty() {
        XCTAssertTrue(sut.getCodeRecentConnections().isEmpty)
    }

    func test_recordCodeRecentConnection_persistsAndRoundtrips() {
        // When
        sut.recordCodeRecentConnection(host: "mac.ts.net", port: 47800)

        // Then
        XCTAssertEqual(sut.getCodeRecentConnections(), [
            CodeRecentConnection(host: "mac.ts.net", port: 47800),
        ])
    }

    func test_recordCodeRecentConnection_repeatedRecords_applyMruOrdering() {
        // When
        sut.recordCodeRecentConnection(host: "a.ts.net", port: 47800)
        sut.recordCodeRecentConnection(host: "b.ts.net", port: 47900)
        sut.recordCodeRecentConnection(host: "a.ts.net", port: 47800)

        // Then
        XCTAssertEqual(sut.getCodeRecentConnections(), [
            CodeRecentConnection(host: "a.ts.net", port: 47800),
            CodeRecentConnection(host: "b.ts.net", port: 47900),
        ])
    }

    func test_deleteAll_clearsRecentConnections() {
        // Given
        sut.recordCodeRecentConnection(host: "mac.ts.net", port: 47800)

        // When
        sut.deleteAll()

        // Then
        XCTAssertTrue(sut.getCodeRecentConnections().isEmpty)
    }
}

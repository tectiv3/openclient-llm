//
//  MockCodeBackgroundUseCase.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Foundation
@testable import openclient_llm

// Safety: Only used within serialized @MainActor test methods.
final class MockCodeBackgroundUseCase: CodeBackgroundUseCaseProtocol, @unchecked Sendable {
    // MARK: - Properties

    private(set) var beginCount = 0
    private(set) var endCount = 0
    var expirationHandler: (() -> Void)?

    // MARK: - CodeBackgroundUseCaseProtocol

    func begin(expirationHandler: @escaping () -> Void) {
        beginCount += 1
        self.expirationHandler = expirationHandler
    }

    func end() {
        endCount += 1
    }
}

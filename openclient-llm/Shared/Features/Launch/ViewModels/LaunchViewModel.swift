//
//  LaunchViewModel.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 30/03/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

@Observable
@MainActor
final class LaunchViewModel {
    // MARK: - Properties

    enum Event {
        case viewAppeared
        case onboardingCompleted
    }

    enum State: Equatable {
        case loading
        case onboarding
        case home
    }

    private(set) var state: State

    private let checkOnboardingUseCase: CheckOnboardingUseCaseProtocol
    private let resetAppDataUseCase: ResetAppDataUseCaseProtocol
    private let attachmentMigrationUseCase: AttachmentMigrationUseCaseProtocol
    private let launchDelay: Duration

    // MARK: - Init

    init(
        state: State = .loading,
        checkOnboardingUseCase: CheckOnboardingUseCaseProtocol = CheckOnboardingUseCase(),
        resetAppDataUseCase: ResetAppDataUseCaseProtocol = ResetAppDataUseCase(),
        attachmentMigrationUseCase: AttachmentMigrationUseCaseProtocol = AttachmentMigrationUseCase(),
        launchDelay: Duration = .milliseconds(1000)
    ) {
        self.state = state
        self.checkOnboardingUseCase = checkOnboardingUseCase
        self.resetAppDataUseCase = resetAppDataUseCase
        self.attachmentMigrationUseCase = attachmentMigrationUseCase
        self.launchDelay = launchDelay
    }

    // MARK: - Input functions

    func send(_ event: Event) {
        switch event {
        case .viewAppeared:
            attachmentMigrationUseCase.execute()

            let isCompleted = checkOnboardingUseCase.execute()
            if !isCompleted {
                resetAppDataUseCase.execute()
            }

            startLaunch(isOnboardingCompleted: isCompleted)
        case .onboardingCompleted:
            state = .home
        }
    }

    func startLaunch(isOnboardingCompleted: Bool) {
        Task { [weak self, launchDelay] in
            guard let self else { return }

            await Self.waitForLaunchDelay(launchDelay)
            state = isOnboardingCompleted ? .home : .onboarding
        }
    }

    nonisolated static func waitForLaunchDelay(_ launchDelay: Duration) async {
        guard launchDelay > .zero else { return }
        try? await Task.sleep(for: launchDelay)
    }
}

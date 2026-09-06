//
//  ScrollTriggerModifier.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 30/03/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI
#if canImport(UIKit)
import SwiftUI
#endif

private enum AutoScrollPriority: Int {
    case content
    case structural
    case keyboard
}

struct ScrollEdgeMetrics: Equatable {
    var isNearBottom = true
    var isAtBottom = true
    var isNearTop = true
}

struct ScrollTriggerModifier<ContentTrigger: Equatable, SessionID: Hashable>: ViewModifier {
    @Binding var scrollPosition: ScrollPosition
    @Binding var scrollToMessageId: UUID?
    @Binding var shouldAutoScroll: Bool
    @Binding var isManuallyScrolling: Bool

    let messageCount: Int
    let contentTrigger: ContentTrigger
    let sessionId: SessionID?
    let isAtBottom: Bool

    @State private var autoScrollTask: Task<Void, Never>?
    @State private var pendingPriority: AutoScrollPriority?

    func body(content: Content) -> some View {
        content
            .onChange(of: messageCount) {
                scheduleBottomScroll(
                    after: .zero,
                    animation: .easeInOut(duration: 0.25),
                    priority: .structural
                )
            }
            .onChange(of: scrollToMessageId) { _, newId in
                guard let id = newId else { return }
                cancelAutoScroll()
                shouldAutoScroll = false
                withAnimation(.easeInOut(duration: 0.35)) {
                    scrollPosition.scrollTo(id: id)
                }
                scrollToMessageId = nil
            }
            .onChange(of: shouldAutoScroll) { _, isEnabled in
                if !isEnabled { cancelAutoScroll() }
            }
            .onChange(of: isManuallyScrolling) { _, isScrolling in
                if isScrolling { cancelAutoScroll() }
            }
            .onChange(of: isAtBottom) { _, atBottom in
                guard !atBottom else { return }
                scheduleBottomScroll(
                    after: .milliseconds(50),
                    animation: .linear(duration: 0.1)
                )
            }
            .onChange(of: contentTrigger) {
                scheduleBottomScroll(
                    after: .milliseconds(50),
                    animation: .linear(duration: 0.1)
                )
            }
            .task(id: sessionId) {
                await handleInitialScroll()
            }
            .onDisappear(perform: cancelAutoScroll)
#if os(iOS)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillShowNotification
                )
            ) { handleKeyboardWillShow($0) }
#endif
    }

    private func handleInitialScroll() async {
        shouldAutoScroll = true
        guard messageCount > 0 else { return }
        do {
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            return
        }
        scheduleBottomScroll(
            after: .zero,
            animation: .easeInOut(duration: 0.25),
            priority: .structural
        )
    }

#if os(iOS)
    private func handleKeyboardWillShow(_ notification: Notification) {
        let duration = notification.userInfo?[
            UIResponder.keyboardAnimationDurationUserInfoKey
        ] as? Double ?? 0.25
        scheduleBottomScroll(
            after: .seconds(duration),
            animation: .easeInOut(duration: 0.25),
            priority: .keyboard
        )
    }
#endif

    private func scheduleBottomScroll(
        after delay: Duration,
        animation: Animation? = nil,
        priority: AutoScrollPriority = .content
    ) {
        guard shouldAutoScroll, !isManuallyScrolling else { return }
        if let pendingPriority {
            guard priority.rawValue > pendingPriority.rawValue else { return }
            cancelAutoScroll()
        }
        pendingPriority = priority
        autoScrollTask = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard shouldAutoScroll, !isManuallyScrolling, !Task.isCancelled else {
                autoScrollTask = nil
                pendingPriority = nil
                return
            }
            if let animation {
                withAnimation(animation) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            autoScrollTask = nil
            pendingPriority = nil
        }
    }

    private func cancelAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        pendingPriority = nil
    }
}

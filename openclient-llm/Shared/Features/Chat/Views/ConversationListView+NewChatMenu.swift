//
//  ConversationListView+NewChatMenu.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 13/07/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import SwiftUI

extension ConversationListView {
    // MARK: - New Chat Button

    var newChatToolbarButton: some View {
        Button {
            viewModel.send(.newConversationTapped)
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .help(String(localized: "New Chat"))
        .accessibilityLabel(String(localized: "New Chat"))
        .keyboardShortcut("c", modifiers: .command)
    }
}

//
//  ServerType.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 16/08/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

enum ServerType: String, CaseIterable, Sendable {
    case liteLLM = "litellm"
    case lmStudio = "lmstudio"

    var displayName: String {
        switch self {
        case .liteLLM: String(localized: "LiteLLM")
        case .lmStudio: String(localized: "LM Studio")
        }
    }
}

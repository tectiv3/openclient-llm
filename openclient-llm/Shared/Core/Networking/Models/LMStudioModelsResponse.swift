//
//  LMStudioModelsResponse.swift
//  openclient-llm
//
//  Created by Arturo Carretero Calvo on 16/08/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Foundation

nonisolated struct LMStudioModelsResponse: Decodable, Sendable {
    let models: [LMStudioModel]
}

// MARK: - LMStudioModel

nonisolated struct LMStudioModel: Decodable, Sendable {
    let type: String
    let publisher: String?
    let key: String
    let displayName: String?
    let architecture: String?
    let quantization: Quantization?
    let sizeBytes: Int?
    let paramsString: String?
    let loadedInstances: [LoadedInstance]?
    let maxContextLength: Int?
    let format: String?
    let capabilities: Capabilities?

    nonisolated struct Quantization: Decodable, Sendable {
        let name: String?
        let bitsPerWeight: Int?
    }

    nonisolated struct LoadedInstance: Decodable, Sendable {
        let id: String?
        let config: InstanceConfig?

        nonisolated struct InstanceConfig: Decodable, Sendable {
            let contextLength: Int?
        }
    }

    nonisolated struct Capabilities: Decodable, Sendable {
        let vision: Bool?
        let trainedForToolUse: Bool?
        let reasoning: Reasoning?

        nonisolated struct Reasoning: Decodable, Sendable {
            let allowedOptions: [String]?
            let `default`: String?
        }
    }
}

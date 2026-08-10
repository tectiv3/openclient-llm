//
//  BackgroundCompletionService.swift
//  openclient-llm
//

import Foundation

#if os(iOS)

// MARK: - Pending context (file-persisted, survives app termination)

struct BackgroundCompletionContext: Codable, Sendable {
    let conversationId: UUID
    let assistantMessageId: UUID
}

// MARK: - URLSession delegate (nonisolated — runs on background queue)

private final class BackgroundSessionDelegate: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "background-completion-delegate", qos: .utility)
    private var responseData = Data()
    var systemCompletionHandler: (() -> Void)?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.sync { responseData.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data: Data = queue.sync {
            let collected = responseData
            responseData = Data()
            return collected
        }
        let handler = systemCompletionHandler
        systemCompletionHandler = nil

        Task { @MainActor in
            BackgroundCompletionService.shared.handleTaskCompletion(data: data, error: error)
            handler?()
        }
    }
}

// MARK: - Service (MainActor — public API, response processing)

@MainActor
final class BackgroundCompletionService {
    static let shared = BackgroundCompletionService()
    static let sessionIdentifier = "com.arturocarretero.openclient-llm.background-completion"

    private let settingsManager: SettingsManagerProtocol = SettingsManager()
    private let notificationManager = LocalNotificationManager()
    private let delegate = BackgroundSessionDelegate()
    private let backgroundSession: URLSession

    private init() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        backgroundSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Fallback lifecycle

    func prepareFallback(
        requestBody: Data,
        conversationId: UUID,
        assistantMessageId: UUID
    ) {
        try? requestBody.write(to: requestBodyFileURL)
        let context = BackgroundCompletionContext(
            conversationId: conversationId,
            assistantMessageId: assistantMessageId
        )
        if let data = try? JSONEncoder().encode(context) {
            try? data.write(to: contextFileURL)
        }
        LogManager.debug("BackgroundCompletion: fallback prepared conv=\(conversationId)")
    }

    func submitFallback() -> Bool {
        guard FileManager.default.fileExists(atPath: requestBodyFileURL.path),
              let request = buildURLRequest() else {
            return false
        }
        let task = backgroundSession.uploadTask(with: request, fromFile: requestBodyFileURL)
        task.resume()
        LogManager.info("BackgroundCompletion: fallback upload task submitted")
        return true
    }

    func clearFallback() {
        try? FileManager.default.removeItem(at: requestBodyFileURL)
        try? FileManager.default.removeItem(at: contextFileURL)
    }

    func handleEventsForBackgroundURLSession(completionHandler: @escaping () -> Void) {
        delegate.systemCompletionHandler = completionHandler
        _ = backgroundSession
    }

    // MARK: - Task completion (called from delegate via MainActor dispatch)

    func handleTaskCompletion(data: Data, error: Error?) {
        if let error {
            LogManager.error("BackgroundCompletion: task failed — \(error.localizedDescription)")
            notificationManager.sendExpiredNotification()
            clearFallback()
            return
        }

        guard !data.isEmpty else {
            LogManager.error("BackgroundCompletion: empty response data")
            notificationManager.sendExpiredNotification()
            clearFallback()
            return
        }

        processCompletionResponse(data)
    }

    // MARK: - File URLs

    private var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundCompletion", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var requestBodyFileURL: URL {
        supportDirectory.appendingPathComponent("fallback-body.json")
    }

    private var contextFileURL: URL {
        supportDirectory.appendingPathComponent("fallback-context.json")
    }

    // MARK: - Request building

    private func buildURLRequest() -> URLRequest? {
        let baseURL = settingsManager.getServerBaseURL()
        guard !baseURL.isEmpty,
              let url = URL(string: baseURL)?.appendingPathComponent("chat/completions") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let apiKey = settingsManager.getAPIKey()
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Response processing

    private func processCompletionResponse(_ data: Data) {
        guard let contextData = try? Data(contentsOf: contextFileURL),
              let context = try? JSONDecoder().decode(BackgroundCompletionContext.self, from: contextData) else {
            LogManager.error("BackgroundCompletion: no context file — cannot update conversation")
            return
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(ChatCompletionResponse.self, from: data),
              let content = response.choices.first?.message.content else {
            LogManager.error("BackgroundCompletion: failed to decode response")
            notificationManager.sendExpiredNotification()
            clearFallback()
            return
        }

        updateConversationFile(
            conversationId: context.conversationId,
            assistantMessageId: context.assistantMessageId,
            content: content,
            reasoningContent: response.choices.first?.message.reasoningContent,
            usage: response.usage
        )

        notificationManager.sendCompletionNotification()
        NotificationCenter.default.post(name: .conversationDidUpdate, object: nil)
        clearFallback()
        LogManager.success("BackgroundCompletion: conversation updated with full response")
    }

    private func updateConversationFile(
        conversationId: UUID,
        assistantMessageId: UUID,
        content: String,
        reasoningContent: String?,
        usage: ChatCompletionResponse.Usage?
    ) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL
            .appendingPathComponent("Conversations", isDirectory: true)
            .appendingPathComponent("\(conversationId.uuidString).json")

        guard let fileData = try? Data(contentsOf: fileURL) else {
            LogManager.error("BackgroundCompletion: cannot read conversation file")
            return
        }

        let convDecoder = JSONDecoder()
        convDecoder.dateDecodingStrategy = .iso8601
        guard var conversation = try? convDecoder.decode(Conversation.self, from: fileData) else {
            LogManager.error("BackgroundCompletion: cannot decode conversation")
            return
        }

        guard let index = conversation.messages.firstIndex(where: { $0.id == assistantMessageId }) else {
            LogManager.error("BackgroundCompletion: assistant message \(assistantMessageId) not found")
            return
        }

        conversation.messages[index].content = content
        conversation.messages[index].reasoningContent = reasoningContent
        if let usage {
            conversation.messages[index].tokenUsage = TokenUsage(
                promptTokens: usage.promptTokens ?? 0,
                completionTokens: usage.completionTokens ?? 0,
                totalTokens: usage.totalTokens ?? 0
            )
        }
        conversation.updatedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let encoded = try? encoder.encode(conversation) else {
            LogManager.error("BackgroundCompletion: cannot encode updated conversation")
            return
        }

        try? encoded.write(to: fileURL, options: .atomic)
    }
}

#endif

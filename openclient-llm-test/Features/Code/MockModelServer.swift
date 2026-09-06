//
//  MockModelServer.swift
//  openclient-llm-test
//
//  Deterministic OpenAI-compatible model server for E2E tests.
//

import Foundation

/// Minimal OpenAI-compatible chat-completions server bound to
/// 127.0.0.1. The simulator blocks outbound traffic to LAN/tailnet/
/// internet, so the E2E tests run a deterministic local model: replies
/// are canned and keyed on prompt markers, keeping the tests hermetic.
final class MockModelServer: @unchecked Sendable {
    // Safety: `port` is written once in `start()` before the listener
    // thread begins, then read-only. `requestBodies` is guarded by
    // `stateLock`. The accept loop and per-connection threads each own
    // their file descriptors.
    private(set) var port = 0
    private var serverFd: Int32 = -1
    private let stateLock = NSLock()
    private var requestBodies: [String] = []

    // MARK: - Init

    init() {}

    // MARK: - Lifecycle

    /// Binds an ephemeral loopback port and starts the accept loop.
    func start() throws {
        let socketFd = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFd >= 0 else { throw MockModelError.bindFailed }
        var yes: Int32 = 1
        _ = setsockopt(
            socketFd, SOL_SOCKET, SO_REUSEADDR, &yes,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(socketFd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFd)
            throw MockModelError.bindFailed
        }
        guard listen(socketFd, 16) == 0 else {
            close(socketFd)
            throw MockModelError.listenFailed
        }
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(socketFd, saPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            close(socketFd)
            throw MockModelError.bindFailed
        }
        self.port = Int(UInt16(bigEndian: boundAddr.sin_port))
        self.serverFd = socketFd
        let thread = Thread { [self] in
            self.acceptLoop()
        }
        thread.name = "rc.e2e.mock-model"
        thread.start()
    }

    /// Stops the accept loop and closes the server socket.
    func stop() {
        let socketFd = serverFd
        serverFd = -1
        if socketFd >= 0 {
            _ = shutdown(socketFd, SHUT_RDWR)
            close(socketFd)
        }
    }

    /// Bodies of all chat-completion requests, for diagnostics.
    var capturedBodies: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestBodies
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFd = accept(serverFd, &clientAddr, &clientLen)
            guard clientFd >= 0 else { return }
            let thread = Thread { [self] in
                self.handleConnection(clientFd)
            }
            thread.name = "rc.e2e.mock-model.conn"
            thread.start()
        }
    }

    private func handleConnection(_ clientFd: Int32) {
        defer { close(clientFd) }
        var buffer = Data()
        while true {
            let parsed = parseNextRequest(from: &buffer)
            if case .request(let method, let path, let body) = parsed {
                if method == "POST", let body {
                    stateLock.lock()
                    requestBodies.append(body)
                    stateLock.unlock()
                }
                var alive = true
                for write in Self.responseWrites(
                    for: method, path: path, body: body
                ) {
                    guard writeChunk(write.chunk, to: clientFd) else {
                        alive = false
                        break
                    }
                    if write.delay > 0 { usleep(useconds_t(write.delay)) }
                }
                if !alive { return }
                if path.contains("chat/completions") { return }
                continue
            }
            // Incomplete request: block until more data arrives.
            guard readAvailable(into: &buffer, from: clientFd) else {
                return
            }
        }
    }

    /// Blocks reading from the socket into `buffer`; `false` on EOF or
    /// error (client gone).
    private func readAvailable(into buffer: inout Data, from socketFd: Int32) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(socketFd, &chunk, chunk.count)
        guard count > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<count])
        return true
    }

    // MARK: - HTTP parsing

    private enum ParsedRequest: Equatable {
        case request(method: String, path: String, body: String?)
        case needMore
        case eof
    }

    /// Consumes the next complete HTTP/1.1 request from `buffer`,
    /// returning `.needMore` while headers or body are incomplete.
    private func parseNextRequest(from buffer: inout Data) -> ParsedRequest {
        let data = buffer
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.isEmpty ? .eof : .needMore
        }
        let headerEndIndex = headerEnd.upperBound
        let headerBytes = data.subdata(in: 0..<headerEndIndex)
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            return .eof
        }
        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.components(separatedBy: ":")
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased()
               == "content-length" {
                contentLength = Int(
                    parts[1].trimmingCharacters(in: .whitespaces)
                ) ?? 0
            }
        }
        let bodyLength = data.count - headerEndIndex
        guard bodyLength >= contentLength else { return .needMore }
        var body = ""
        if contentLength > 0 {
            let bodyBytes = data.subdata(
                in: headerEndIndex..<(headerEndIndex + contentLength)
            )
            body = String(data: bodyBytes, encoding: .utf8) ?? ""
        }
        buffer = Data(data.suffix(from: headerEndIndex + contentLength))
        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return .needMore }
        return .request(
            method: requestParts[0], path: requestParts[1], body: body
        )
    }

    /// Writes one chunk to the socket; returns `false` on client gone.
    private func writeChunk(_ response: String, to socketFd: Int32) -> Bool {
        let data = response.data(using: .utf8) ?? Data()
        guard !data.isEmpty else { return true }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(socketFd, base.advanced(by: offset), raw.count - offset)
            }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    // MARK: - Scenario routing

    /// The response writes (chunk + trailing delay) for a request.
    /// Delays keep `longStream` in flight so a competing prompt is
    /// rejected as not_idle.
    private static func responseWrites(
        for method: String,
        path: String,
        body: String?
    ) -> [(chunk: String, delay: Int)] {
        if method == "GET", path.hasPrefix("/v1/models") {
            let json = "{\"object\":\"list\",\"data\":[{\"id\":\"\(modelId)\","
                + "\"object\":\"model\",\"owned_by\":\"mock\"}]}"
            return [(jsonResponse(body: json), 0)]
        }
        guard method == "POST", path.contains("chat/completions"),
              let body else {
            return [(
                jsonResponse(
                    body: #"{"error":"not found"}"#, status: "404 Not Found"
                ),
                0
            )]
        }
        // The OpenAI SDK iterator completes only when the body ends, so the
        // stream must be terminated by closing the connection after [DONE].
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        let id = "chatcmpl-mock"
        switch scenario(forBody: body) {
        case .text(let text):
            return [
                (header, 0),
                (sse(chunkJson(id, #"{"role":"assistant"}"#)), 0),
                (sse(chunkJson(id, #"{"content":\#(jsonString(text))}"#)), 0),
                (sse(chunkJson(id, "{}", finish: "stop")), 0),
                ("data: [DONE]\n\n", 0),
            ]
        case .toolCall(let name, let arguments):
            let toolCall = "{\"tool_calls\":[{\"index\":0,\"id\":\"call-mock\","
                + "\"type\":\"function\",\"function\":{\"name\":\(jsonString(name)),"
                + "\"arguments\":\(jsonString(arguments))}}]}"

            return [
                (header, 0),
                (sse(chunkJson(id, #"{"role":"assistant"}"#)), 0),
                (sse(chunkJson(id, toolCall)), 0),
                (sse(chunkJson(id, "{}", finish: "tool_calls")), 0),
                ("data: [DONE]\n\n", 0),
            ]
        case .longStream:
            var writes: [(chunk: String, delay: Int)] = [(header, 0)]
            writes.append((sse(chunkJson(id, #"{"role":"assistant"}"#)), 0))
            for chunk in 0..<25 {
                writes.append((sse(chunkJson(id, #"{"content":"token \#(chunk) "}"#)), 100_000))
            }
            writes.append((sse(chunkJson(id, "{}", finish: "stop")), 0))
            writes.append(("data: [DONE]\n\n", 0))
            return writes
        }
    }

    /// Routes a chat-completion request body to a canned scenario by
    /// inspecting the last user message; a trailing `tool` message means
    /// the pending question was answered, so finish the turn.
    static func scenario(forBody body: String) -> MockModelScenario {
        guard
            let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let messages = json["messages"] as? [[String: Any]],
            !messages.isEmpty
        else {
            return .text("Done.")
        }
        if let last = messages.last, (last["role"] as? String) == "tool" {
            return .text("Done.")
        }
        let lastUser = messages.last { ($0["role"] as? String) == "user" }
        let content = MockModelServer.messageContent(lastUser)
        if content.contains("ASKFORM") {
            return .toolCall(name: "questionnaire", arguments: questionnaireArgs)
        }
        if content.contains("ASK") {
            return .toolCall(name: "question", arguments: questionArgs)
        }
        if content.contains("PONG-E2E") {
            return .text("PONG-E2E")
        }
        if content.contains("LONG") {
            return .longStream
        }
        return .text("Done.")
    }

    /// Extracts plain text from an OpenAI `content` field, which may be a
    /// string or an array of content parts (`{"type":"text","text":...}`).
    static func messageContent(_ message: [String: Any]?) -> String {
        guard let message else { return "" }
        if let text = message["content"] as? String { return text }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    static let modelId = "qwen3.8-27b"

    /// Arguments for the `question` tool: a color question with three
    /// options (the test asserts these shapes).
    static let questionArgs =
        "{\"question\":\"What is your favorite color?\""
            + ",\"options\":[{\"label\":\"Red\"},{\"label\":\"Green\"},{\"label\":\"Blue\"}]}"

    static let questionnaireArgs =
        "{\"questions\":[{\"id\":\"q1\",\"prompt\":\"Which environment?\""
            + ",\"options\":[{\"value\":\"dev\",\"label\":\"Development\"},"
            + "{\"value\":\"staging\",\"label\":\"Staging\"}]}"
            + ",{\"id\":\"q2\",\"prompt\":\"Which size?\""
            + ",\"options\":[{\"value\":\"s\",\"label\":\"Small\"}]}]}"

    /// One SSE `data:` line of a chat-completion stream.
    private static func sse(_ payload: String) -> String {
        "data: \(payload)\n\n"
    }

    private static func chunkJson(
        _ id: String,
        _ delta: String,
        finish: String? = nil
    ) -> String {
        let finishJson = finish.map { "\"finish_reason\":\"\($0)\"" }
            ?? "\"finish_reason\":null"
        let deltaJson = delta.isEmpty ? "{}" : #""delta":\#(delta)"#
        return "{\"id\":\"\(id)\",\"object\":\"chat.completion.chunk\","
            + "\"created\":1,\"model\":\"\(modelId)\","
            + "\"choices\":[{\"index\":0,\(deltaJson),\(finishJson)}]}"
    }

    /// The JSON-encoded string literal (quoted + escaped) for `value`.
    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let array = String(data: data ?? Data(), encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func jsonResponse(
        body: String,
        status: String = "200 OK"
    ) -> String {
        "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: keep-alive\r\n\r\n\(body)"
    }
}

/// Canned reply shapes the mock server can emit.
enum MockModelScenario {
    case text(String)
    case toolCall(name: String, arguments: String)
    case longStream
}

enum MockModelError: Error {
    case bindFailed
    case listenFailed
}

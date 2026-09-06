//
//  RcE2eServer.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//  Copyright © 2026 Arturo Carretero Calvo. All rights reserved.
//

import Darwin
import Foundation

/// Drives a real `pi` process running the rc extension (spec C3.1) for
/// end-to-end tests. `pi` runs in RPC mode (JSON lines on stdin/stdout)
/// inside a temp copy of `pi-extensions/rc/test-project`; the `/rc` command
/// toggles the embedded WebSocket server that tests reach through the real
/// `CodeServerClient`.
///
/// `Foundation.Process` is absent from the iOS SDK, so the process is
/// started with `posix_spawn` through `/bin/sh -c` (cwd via sh, env passed
/// explicitly — neither spawnattr variant is importable from Swift).
/// Mutable state lives on serial `pipeQueue` (plumbing), `rpcQueue` (RPC).
final class RcE2eServer: @unchecked Sendable {
    // Safety: every mutable property is only touched on the serial queue that
    // owns it (`child`/`stdin`/`stderrTail`/`tempDirURL` on pipeQueue,
    // `pending` on rpcQueue); reader threads only read FileHandles published
    // by start() and the rpc id/line values crossing queues are Sendable.

    // MARK: - Errors

    enum RcE2eError: LocalizedError {
        case binaryNotFound
        case spawnFailed(String)
        case rpcTimeout(String)
        case rpcFailed(String)
        case notReady(String)
        case authFileNeverRunning(raw: String)
        case processExited(status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "pi binary not found (set PI_RC_E2E_PI_BIN)"
            case .spawnFailed(let detail):
                return "failed to spawn pi: \(detail)"
            case .rpcTimeout(let type):
                return "pi RPC '\(type)' timed out"
            case .rpcFailed(let detail):
                return "pi RPC failed: \(detail)"
            case .notReady(let stderr):
                return "pi did not become ready. stderr: \(stderr)"
            case .authFileNeverRunning(let raw):
                return "rc auth file never reached running state (raw: \(raw))"
            case .processExited(let status, let stderr):
                return "pi exited (status \(status)). stderr: \(stderr)"
            }
        }
    }

    // Provider/model names come from the host's ~/.pi/agent/models.json so
    // the mirrored child config is valid; the child's actual traffic is
    // intercepted via modelBaseUrlOverride (a local mock, see spec C3.1),
    // because simulator test processes have no non-loopback egress.
    static let e2eProvider = "lmstudio"
    static let e2eModel = "qwen3.8-27b"

    /// Test-side override of the baseUrl the child pi uses.
    var modelBaseUrlOverride: String?

    /// Mirrors the host agent dir into the temp dir so the child pi never
    /// reads or writes the user's real config. When an override is active,
    /// the e2e provider entry in models.json is rewritten to it.
    func buildChildAgentDir(in tempDir: URL) throws -> URL {
        let manager = FileManager.default
        let agentSource = hostHomeDirectory() + "/.pi/agent"
        let agentDest = tempDir.appendingPathComponent("pi-home/.pi/agent")
        try manager.createDirectory(at: agentDest, withIntermediateDirectories: true)
        let override = effectiveModelBaseUrl(override: modelBaseUrlOverride)
        for item in ["models.json", "settings.json", "auth.json"] {
            let source = agentSource + "/\(item)"
            guard manager.fileExists(atPath: source) else { continue }
            if item == "models.json", let override {
                try writeRewrittenModelsJson(agentDest: agentDest, override: override)
            } else {
                try manager.copyItem(
                    atPath: source, toPath: agentDest.appendingPathComponent(item).path
                )
            }
        }
        copyAgentDirectory(agentSource + "/extensions", to: agentDest.appendingPathComponent("extensions"))
        return tempDir.appendingPathComponent("pi-home")
    }

    /// Pairing endpoint read from the rc auth file after a `/rc` toggle.
    struct RcEndpoint {
        let host: String
        let port: Int
        let code: String
    }

    // MARK: - Properties

    private let pipeQueue = DispatchQueue(label: "rc.e2e.pipe")
    private let rpcQueue = DispatchQueue(label: "rc.e2e.rpc")
    private var child: PosixProcessHandle?
    private var stdin: FileHandle?
    private var stderrTail = ""
    private var pending: [String: (Result<String, RcE2eError>) -> Void] = [:]
    private var tempDirURL: URL?

    // MARK: - Init

    init() {}

    // MARK: - Binary resolution

    // MARK: - Lifecycle

    /// Copies the rc test project into a temp directory and spawns pi in RPC
    /// mode inside it, wiring up the JSON-RPC plumbing.
    func start() throws {
        let manager = FileManager.default
        let tempDir = makeTempDirectory()
        let sourceDir = testProjectSourceDir()
        for item in try manager.contentsOfDirectory(atPath: sourceDir.path) {
            try manager.copyItem(
                atPath: sourceDir.appendingPathComponent(item).path,
                toPath: tempDir.appendingPathComponent(item).path
            )
        }
        tempDirURL = tempDir

        let executable = try resolvedPiExecutable(in: tempDir)

        // pi is a node process: SIGPIPE on the stdin pipe must not kill this
        // test process, so writes surface as EPIPE errors instead.
        signal(SIGPIPE, SIG_IGN)

        // The child env is built explicitly (this macOS's posix_spawn drops
        // the parent env when envp is NULL). HOME is a synthetic pi home in
        // the temp dir mirroring ~/.pi/agent (simulator HOME is the app
        // container; the real one must never be touched by the child).
        let piHome: URL
        do {
            piHome = try buildChildAgentDir(in: tempDir)
        } catch {
            discardTempDir(tempDir)
            throw error
        }
        let env = childEnvironment(piHome: piHome, tempDir: tempDir)
        guard let piScript = resolvePiBinary() else {
            discardTempDir(tempDir)
            throw RcE2eError.binaryNotFound
        }
        let piArgs = [
            executable, piScript,
            "--mode", "rpc", "--provider", Self.e2eProvider, "--model", Self.e2eModel,
            "--approve", "--no-session",
        ]

        let handle: PosixProcessHandle
        do {
            handle = try PosixProcessHandle(
                workingDirectory: tempDir.path, arguments: piArgs, environment: env
            )
        } catch {
            discardTempDir(tempDir)
            throw error
        }

        pipeQueue.sync {
            child = handle
            stdin = handle.stdin
        }
        readLines(from: handle.stdout) { [weak self] line in
            self?.handleOutputLine(line)
        }
        readTail(from: handle.stderr) { [weak self] chunk in
            self?.appendStderr(chunk)
        }
    }

    /// Resolves the executable that runs the pi script. pi ships as a
    /// `#!/usr/bin/env node` script, so node is resolved to an absolute path
    /// so the child does not depend on its PATH.
    private func resolvedPiExecutable(in tempDir: URL) throws -> String {
        guard let piScript = resolvePiBinary(),
              let piHead = try? String(contentsOfFile: piScript, encoding: .utf8)
        else {
            discardTempDir(tempDir)
            throw RcE2eError.binaryNotFound
        }
        var executable = piScript
        let shebang = piHead.split(separator: "\n").first.map(String.init) ?? ""
        if shebang.hasPrefix("#!") && shebang.contains("node") {
            guard let node = resolveNode() else {
                discardTempDir(tempDir)
                throw RcE2eError.binaryNotFound
            }
            executable = node
        }
        return executable
    }

    /// Explicit env for the child: this macOS posix_spawn drops the parent
    /// env when envp is NULL, so it must be built by hand. HOME points at a
    /// synthetic pi home in the temp dir (simulator HOME is the app
    /// container; the real one must never be touched by the child).
    private func childEnvironment(piHome: URL, tempDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/run/current-system/sw/bin:/opt/homebrew/bin:/usr/local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin")
        env["HOME"] = piHome.path
        env["PI_RC_BIND"] = "127.0.0.1"
        env["PI_RC_AUTH_FILE"] = tempDir.appendingPathComponent("rc-auth.json").path
        return env
    }

    /// Toggles the rc server on (`/rc`) and waits for the auth file to carry
    /// a running state with a fresh 6-hex pairing code.
    func toggleOn(timeout: TimeInterval = 15) async throws -> RcEndpoint {
        _ = try await rpc(type: "prompt", extra: ["message": "/rc"], timeout: timeout)
        let authPath = try requireTempDir().appendingPathComponent("rc-auth.json").path
        var lastRaw = "auth file not found"
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let raw = try? String(contentsOfFile: authPath, encoding: .utf8) {
                lastRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = raw.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "running", let code = json["code"] as? String,
                   code.count == 6, let port = json["port"] as? Int {
                    let host = (json["host"] as? String) ?? "127.0.0.1"
                    return RcEndpoint(host: host, port: port, code: code)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RcE2eError.authFileNeverRunning(raw: lastRaw)
    }

    /// Sends the initial `get_session_stats` RPC; pi answers it once the RPC
    /// loop is up, so a success means the process is drivable.
    func waitReady(timeout: TimeInterval = 20) async throws {
        do {
            _ = try await rpc(type: "get_session_stats", timeout: timeout)
        } catch let error as RcE2eError {
            switch error {
            case .processExited, .rpcTimeout: throw RcE2eError.notReady(stderrTailText)
            default: throw error
            }
        }
    }

    /// Terminates the process (SIGTERM, then SIGKILL after 3 s) and removes
    /// the temp directory. Idempotent.
    func stop() {
        let stopped = pipeQueue.sync {
            let current: PosixProcessHandle? = child
            child = nil
            stdin = nil
            return current
        }
        // Fail pending RPCs on the rpcQueue, where `pending` is owned.
        let stderr = stderrTailText
        rpcQueue.async { [self] in failPending(.processExited(status: -1, stderr: stderr)) }
        stopped?.terminate(timeout: 3)
        removeTempDir()
    }

    /// Tail of the captured stderr output, for failure messages.
    var stderrTailText: String {
        pipeQueue.sync { String(stderrTail.suffix(500)) }
    }

    // MARK: - RPC

    /// Sends one JSON-RPC line to pi and awaits its `{"type":"response"}`
    /// reply. `success: false` replies and timeouts surface as thrown errors
    /// carrying the stderr tail.
    func rpc(
        type: String,
        extra: [String: Any] = [:],
        timeout: TimeInterval = 10
    ) async throws -> [String: Any] {
        // Encode on the caller thread so only Sendable values cross into the
        // @Sendable queue closure; the reply is resumed as the raw JSON
        // string because `[String: Any]` cannot cross into the continuation.
        let id = UUID().uuidString
        var payload: [String: Any] = ["type": type, "id": id]
        for (key, value) in extra {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8) else {
            throw RcE2eError.rpcFailed("could not encode RPC '\(type)'")
        }
        let reply = try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            rpcQueue.async { [self] in
                let stderr = self.stderrTailText
                let stdin = pipeQueue.sync { self.stdin }
                guard let stdin else {
                    box.resume(.failure(.processExited(status: -1, stderr: stderr)))
                    return
                }
                self.pending[id] = { box.resume($0) }
                rpcQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if let self, let waiter = self.pending.removeValue(forKey: id) {
                        waiter(.failure(.rpcTimeout(type)))
                    }
                }
                do {
                    try writeAll(line + "\n", to: stdin)
                } catch {
                    if let waiter = self.pending.removeValue(forKey: id) {
                        waiter(.failure(.rpcFailed("write to pi stdin failed: \(error)")))
                    }
                }
            }
        }
        guard let data = reply.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RcE2eError.rpcFailed("could not decode RPC reply for '\(type)'")
        }
        return json
    }

    // MARK: - Private

    private func discardTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        tempDirURL = nil
    }

    private struct ContinuationBox: @unchecked Sendable {
        // Safety: resume is only ever invoked on the serial rpcQueue, so the
        // checked continuation is resumed exactly once from one thread. The
        // payload is a Sendable String, so crossing back is race-free.
        let resume: (Result<String, RcE2eError>) -> Void

        init(_ continuation: CheckedContinuation<String, Error>) {
            self.resume = { result in
                switch result {
                case .success(let reply):
                    continuation.resume(returning: reply)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func handleOutputLine(_ line: String) {
        rpcQueue.async { [self] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "response", let id = json["id"] as? String,
                  let waiter = pending.removeValue(forKey: id) else { return }
            if json["success"] as? Bool == false {
                let message = (json["error"] as? String) ?? "unknown error"
                waiter(.failure(.rpcFailed("\(message) (stderr: \(stderrTailText.suffix(300)))")))
            } else {
                waiter(.success(trimmed))
            }
        }
    }

    private func failPending(_ error: RcE2eError) {
        pending.values.forEach { $0(.failure(error)) }
        pending = [:]
    }

    private func appendStderr(_ chunk: String) {
        pipeQueue.sync { stderrTail = String((stderrTail + chunk).suffix(2000)) }
    }

    private func removeTempDir() {
        let dir = pipeQueue.sync { tempDirURL }
        pipeQueue.sync { tempDirURL = nil }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func requireTempDir() throws -> URL {
        let dir = pipeQueue.sync { tempDirURL }
        guard let dir else {
            throw RcE2eError.spawnFailed("server is not started")
        }
        return dir
    }

}

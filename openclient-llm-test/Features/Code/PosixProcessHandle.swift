//
//  PosixProcessHandle.swift
//  openclient-llm
//
//  Created by tectiv3 on 05/09/2026.
//

import Darwin
import Foundation

/// A child process started with `posix_spawn` (Foundation.Process is not
/// available in the iOS SDK). The command runs through `/bin/sh -c` so the
/// working directory can be set; the leading `exec` replaces sh. `terminate`
/// sends SIGTERM, polls, SIGKILLs, and always reaps.
final class PosixProcessHandle: @unchecked Sendable {
    // Safety: only touched on the serial pipeQueue (plus the reader threads,
    // which only read the FileHandles after start() published them).

    let pid: pid_t
    let stdin: FileHandle
    let stdout: FileHandle
    let stderr: FileHandle

    init(workingDirectory: String, arguments: [String], environment: [String: String]) throws {
        var stdinFds = [Int32](repeating: 0, count: 2)
        var stdoutFds = [Int32](repeating: 0, count: 2)
        var stderrFds = [Int32](repeating: 0, count: 2)
        guard pipe(&stdinFds) == 0, pipe(&stdoutFds) == 0, pipe(&stderrFds) == 0 else {
            throw RcE2eServer.RcE2eError.spawnFailed(
                "pipe() failed: \(String(cString: strerror(errno)))"
            )
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The dup2 source fds must stay open until after posix_spawn returns:
        // Darwin validates the file actions' fds at call time.
        posix_spawn_file_actions_adddup2(&actions, stdinFds[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutFds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrFds[1], 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let quoted = arguments.map(shQuote).joined(separator: " ")
        let script = "cd " + shQuote(workingDirectory) + " && exec " + quoted
        guard let argvBase = charArgs(["/bin/sh", "-c", script]),
              let execPath = ("/bin/sh" as NSString).utf8String else {
            throw RcE2eServer.RcE2eError.spawnFailed("could not build spawn argv")
        }
        var argv = argvBase
        // This macOS's posix_spawn drops the parent environment when envp is
        // NULL, so the child environment is always passed explicitly.
        let envLines = environment.map { "\($0)=\($1)" }.sorted()
        guard let envpArray = charArgs(envLines) else {
            throw RcE2eServer.RcE2eError.spawnFailed("could not build spawn envp")
        }
        var envp = envpArray
        var spawnedPid: pid_t = 0
        let rcValue = posix_spawn(&spawnedPid, execPath, &actions, &attr, &argv, &envp)
        close(stdinFds[0])
        close(stdoutFds[1])
        close(stderrFds[1])
        let (stdinHandle, stdoutHandle, stderrHandle) = (
            FileHandle(fileDescriptor: stdinFds[1], closeOnDealloc: false),
            FileHandle(fileDescriptor: stdoutFds[0], closeOnDealloc: false),
            FileHandle(fileDescriptor: stderrFds[0], closeOnDealloc: false)
        )
        guard rcValue == 0 else {
            stdinHandle.closeFile()
            stdoutHandle.closeFile()
            stderrHandle.closeFile()
            throw RcE2eServer.RcE2eError.spawnFailed("posix_spawn failed (\(rcValue))")
        }
        self.pid = spawnedPid
        self.stdin = stdinHandle
        self.stdout = stdoutHandle
        self.stderr = stderrHandle
    }

    /// SIGTERM, wait up to `timeout` seconds, SIGKILL if still running, then
    /// reap.
    func terminate(timeout: TimeInterval) {
        guard isRunning() else {
            reap()
            return
        }
        kill(pid, SIGTERM)
        let deadline = Date.now.addingTimeInterval(timeout)
        while isRunning() && Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isRunning() {
            kill(pid, SIGKILL)
        }
        reap()
    }

    func isRunning() -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == 0
    }

    private func reap() {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        stdin.closeFile()
        stdout.closeFile()
        stderr.closeFile()
    }
}

/// strdup()s each argument plus a terminating nil; nil if one cannot be encoded.
func charArgs(_ arguments: [String]) -> [UnsafeMutablePointer<CChar>?]? {
    var result: [UnsafeMutablePointer<CChar>?] = []
    for argument in arguments {
        guard let cString = (argument as NSString).utf8String else {
            result.forEach { free($0) }
            return nil
        }
        result.append(strdup(cString))
    }
    result.append(nil)
    return result
}

/// Single-quote shell-escape for the `/bin/sh -c` command line.
private func shQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Sets one bit in an fd_set (the FD_SET macros are not importable).
func setFdBit(_ set: inout fd_set, _ socket: Int32) {
    withUnsafeMutablePointer(to: &set) { base in
        base.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<fd_set>.size) { ptr in
            for idx in 0..<MemoryLayout<fd_set>.size { ptr[idx] = 0 }
            let word = Int(socket) / 64
            let bit = Int(socket) % 64
            ptr[word * 8 + bit / 8] |= UInt8(truncatingIfNeeded: 1 << bit % 8)
        }
    }
}

/// Probes a baseUrl: TCP connect + minimal HTTP GET; "ok ..." or a diagnostic.
func probeEndpoint(baseUrl: String?, timeout: TimeInterval) -> String {
    guard let base = baseUrl,
          let url = URL(string: base),
          let hostName = url.host, let port = url.port else {
        return "no baseUrl in ~/.pi/agent/models.json"
    }
    guard let addr = resolveIpv4Address(hostName: hostName, port: port) else {
        return "dns failed for \(hostName)"
    }
    let socketFd = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFd >= 0 else { return "socket failed" }
    defer { close(socketFd) }
    let flags = fcntl(socketFd, F_GETFL, 0)
    _ = fcntl(socketFd, F_SETFL, flags | O_NONBLOCK)
    var addrCopy = addr
    let connectResult = withUnsafePointer(to: &addrCopy) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if connectResult == 0 {
        return httpHeadProbe(socketFd: socketFd, host: hostName, port: port, timeout: timeout)
    }
    guard errno == EINPROGRESS else {
        return "connect failed: \(String(cString: strerror(errno)))"
    }
    // SO_ERROR reads as 0 while a connect is in progress on macOS, so wait
    // for writability (select) first, then read the final SO_ERROR.
    var writeSet = fd_set()
    setFdBit(&writeSet, socketFd)
    var waitTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
    let selectResult = select(socketFd + 1, nil, &writeSet, nil, &waitTimeout)
    var finalError = Int32(0)
    var errorLength = socklen_t(MemoryLayout<Int32>.size)
    if selectResult > 0 {
        _ = getsockopt(socketFd, SOL_SOCKET, SO_ERROR, &finalError, &errorLength)
    }
    guard selectResult > 0, finalError == 0 else {
        return "connect failed: select \(selectResult), SO_ERROR \(finalError) to \(hostName):\(port)"
    }
    return httpHeadProbe(socketFd: socketFd, host: hostName, port: port, timeout: timeout)
}

func resolveIpv4Address(hostName: String, port: Int) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
    let ipValue = inet_addr(hostName)
    if ipValue != INADDR_NONE {
        addr.sin_addr.s_addr = ipValue
        return addr
    }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    if getaddrinfo(hostName, nil, &hints, &info) != 0 || info == nil {
        return nil
    }
    guard let resolved = info else { return nil }
    defer { freeaddrinfo(resolved) }
    guard let first = resolved.pointee.ai_addr,
          first.pointee.sa_family == sa_family_t(AF_INET) else {
        return nil
    }
    memcpy(&addr, first, MemoryLayout<sockaddr_in>.size)
    return addr
}

func httpHeadProbe(socketFd: Int32, host: String, port: Int, timeout: TimeInterval) -> String {
    var recvTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
    _ = setsockopt(socketFd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))
    _ = fcntl(socketFd, F_SETFL, fcntl(socketFd, F_GETFL, 0) & ~O_NONBLOCK)  // back to blocking
    let request = "GET /v1/models HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
    guard let requestBytes = request.data(using: .utf8) else {
        return "connect ok; request encoding failed"
    }
    var written = 0
    var writeErrno: Int32 = 0
    requestBytes.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        while written < buffer.count {
            let writeCount = write(socketFd, base.advanced(by: written), buffer.count - written)
            if writeCount <= 0 {
                writeErrno = errno
                break
            }
            written += writeCount
        }
    }
    if written < requestBytes.count {
        let writeMessage = String(cString: strerror(writeErrno))
        return "connect ok; http write stopped at \(written)/\(requestBytes.count) "
            + "(errno \(writeErrno): \(writeMessage))"
    }
    var buffer = [UInt8](repeating: 0, count: 1024)
    var readTotal = 0
    let readDeadline = Date.now.addingTimeInterval(timeout)
    while Date.now < readDeadline && readTotal < buffer.count {
        let readCount = read(socketFd, &buffer[readTotal], 1)
        if readCount == 0 { break }
        if readCount < 0 {
            return "connect ok; http read failed: \(String(cString: strerror(errno)))"
        }
        readTotal += 1
        let tail = Array(buffer[(readTotal - 4)..<readTotal])
        if readTotal >= 4 && tail == [13, 10, 13, 10] {
            break
        }
    }
    let head = String(bytes: Array(buffer.prefix(readTotal)), encoding: .utf8) ?? ""
        .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    guard head.hasPrefix("HTTP") else {
        return "connect ok; http read timed out or empty after \(readTotal) bytes"
    }
    return "ok \(host):\(port) \(head)"
}

/// Resolves the pi executable: `PI_RC_E2E_PI_BIN` env override, then
/// fixed candidate paths, then `~/.npm/_npx/*/node_modules/.bin/pi` (the
/// most recently used npx cache first), then a login-shell lookup. `~`
/// is the host home — the simulator test process sees the container home.
func resolvePiBinary() -> String? {
    let manager = FileManager.default
    if let env = ProcessInfo.processInfo.environment["PI_RC_E2E_PI_BIN"],
       manager.fileExists(atPath: env) {
        return env
    }
    let home = hostHomeDirectory()
    let candidates = [
        "/opt/homebrew/bin/pi",
        "/usr/local/bin/pi",
        home + "/.npm-global/bin/pi",
    ]
    for candidate in candidates where manager.fileExists(atPath: candidate) {
        return candidate
    }
    let npxDir = home + "/.npm/_npx"
    if let entries = try? manager.contentsOfDirectory(atPath: npxDir) {
        // Several pi caches can coexist (the package was renamed
        // @mariozechner to @earendil-works); prefer the most recently
        // used npx cache, which is the one the user is running.
        let dated = entries.compactMap { entry -> (String, Date)? in
            let path = npxDir + "/\(entry)"
            guard let attrs = try? manager.attributesOfItem(atPath: path) else { return nil }
            return (entry, attrs[.modificationDate] as? Date ?? .distantPast)
        }
        for (entry, _) in dated.sorted(by: { $0.1 > $1.1 }) {
            let path = npxDir + "/\(entry)/node_modules/.bin/pi"
            if manager.fileExists(atPath: path) {
                return path
            }
        }
    }
    return shellLookup("pi")
}

/// Diagnostic of the pi search context, embedded in skip messages.
func diagnosePiSearch() -> String {
    "home=[\(hostHomeDirectory())]"
}

/// Whether `~/.pi/agent/models.json` (host home) defines the E2E provider.
func modelProviderConfigured() -> Bool {
    modelBaseUrl() != nil
}

func envModelBaseUrlOverride() -> String? {
    let value = ProcessInfo.processInfo.environment["PI_RC_E2E_MODEL_BASE_URL"]
    return value?.isEmpty == false ? value : nil
}

/// The baseUrl the child pi will use: test-side override, env override
/// (`PI_RC_E2E_MODEL_BASE_URL`), or the real one from models.json.
func effectiveModelBaseUrl(override: String? = nil) -> String? {
    override ?? envModelBaseUrlOverride() ?? modelBaseUrl()
}

/// Copies the host models.json with the e2e provider baseUrl replaced.
func writeRewrittenModelsJson(agentDest: URL, override: String) throws {
    let source = hostHomeDirectory() + "/.pi/agent/models.json"
    guard let data = FileManager.default.contents(atPath: source),
          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var providers = json["providers"] as? [String: Any],
          var provider = providers[RcE2eServer.e2eProvider] as? [String: Any] else {
        return
    }
    provider["baseUrl"] = override
    providers[RcE2eServer.e2eProvider] = provider
    json["providers"] = providers
    let rewritten = try JSONSerialization.data(withJSONObject: json)
    try rewritten.write(to: agentDest.appendingPathComponent("models.json"))
}

/// Copies an agent-dir entry (directory or symlink to one); missing is ok.
func copyAgentDirectory(_ source: String, to destination: URL) {
    let manager = FileManager.default
    guard manager.fileExists(atPath: source) else { return }
    try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
    guard let entries = try? manager.contentsOfDirectory(atPath: source) else { return }
    for entry in entries where entry != ".DS_Store" {
        try? manager.copyItem(
            atPath: source + "/\(entry)", toPath: destination.appendingPathComponent(entry).path
        )
    }
}

/// Restores env vars staged by `start()` around the spawn.
/// Finds node: fixed nix/homebrew candidates, then a login-shell lookup.
func resolveNode() -> String? {
    let manager = FileManager.default
    let nodeCandidates = [
        "/run/current-system/sw/bin/node", "/opt/homebrew/bin/node",
        "/usr/local/bin/node", hostHomeDirectory() + "/.npm-global/bin/node",
    ]
    return nodeCandidates.first(where: manager.fileExists) ?? shellLookup("node")
}

/// mkdtemp-equivalent in NSTemporaryDirectory: unique `rc-e2e-XXXXXX`
/// directory.
func makeTempDirectory() -> URL {
    let manager = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
    for _ in 0..<32 {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let url = base.appendingPathComponent("rc-e2e-" + suffix)
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch {
            // Name collision: retry with a fresh name.
        }
    }
    fatalError("could not create rc-e2e temp directory")
}

/// This file lives at openclient-llm-test/Features/Code/, so the repo
/// root is three levels above its directory.
func testProjectSourceDir() -> URL {
    let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = fileDir.deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return root.appendingPathComponent("pi-extensions/rc/test-project")
}

/// Writes all of `text` to the pipe; `write(contentsOf:)` retries partial
/// writes internally and throws on EPIPE (SIGPIPE is ignored process-wide).
func writeAll(_ text: String, to handle: FileHandle) throws {
    try handle.write(contentsOf: Data(text.utf8))
}

/// The host user's home directory. Inside the simulator the test process
/// sees the app container for HOME and `getpwuid`, so the host home is
/// derived from the container path, which lives under the host home.
func hostHomeDirectory() -> String {
    let raw = NSHomeDirectory()
    let parts = (raw as NSString).pathComponents
    if parts.count >= 6, parts[3] == "Library", parts[4] == "Developer",
       parts[5] == "CoreSimulator" {
        return parts[0] + parts[1] + "/" + parts[2]
    }
    if let pwd = getpwuid(getuid()), let dir = pwd.pointee.pw_dir {
        return String(cString: dir)
    }
    return raw
}

/// Runs `command -v <name>` in a login shell and returns the resolved
/// path, if any.
func shellLookup(_ name: String) -> String? {
    let output = Pipe()
    let errOutput = Pipe()
    guard let argvBase = charArgs(["/bin/zsh", "-lc", "command -v " + name]) else {
        return nil
    }
    var argv = argvBase
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, 1)
    posix_spawn_file_actions_adddup2(&actions, errOutput.fileHandleForWriting.fileDescriptor, 2)
    close(output.fileHandleForWriting.fileDescriptor)
    close(errOutput.fileHandleForWriting.fileDescriptor)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var pid: pid_t = 0
    guard let execPath = ("/bin/zsh" as NSString).utf8String else {
        return nil
    }
    let rcValue = posix_spawn(&pid, execPath, &actions, &attr, &argv, nil)
    guard rcValue == 0 else {
        return nil
    }
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    let line = String(
        data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    output.fileHandleForReading.closeFile()
    errOutput.fileHandleForReading.closeFile()
    guard let path = line, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
        return nil
    }
    return path
}

/// Reads a pipe until EOF, invoking `onLine` per newline-terminated line
/// on a detached thread so the caller can continue.
func readLines(from handle: FileHandle, onLine: @escaping @Sendable (String) -> Void) {
    let reader = Thread {
        var buffer = ""
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer += String(data: chunk, encoding: .utf8) ?? ""
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                onLine(line)
            }
        }
    }
    reader.name = "rc.e2e.stdout"
    reader.start()
}

/// Reads a pipe until EOF, appending chunks to the stderr tail.
func readTail(from handle: FileHandle, onChunk: @escaping @Sendable (String) -> Void) {
    let reader = Thread {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            onChunk(String(data: chunk, encoding: .utf8) ?? "")
        }
    }
    reader.name = "rc.e2e.stderr"
    reader.start()
}

/// A provider's baseUrl from the host `~/.pi/agent/models.json`.

/// A provider's baseUrl from the host `~/.pi/agent/models.json`.
func modelBaseUrl(provider: String = RcE2eServer.e2eProvider) -> String? {
    let path = hostHomeDirectory() + "/.pi/agent/models.json"
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let providers = json["providers"] as? [String: Any],
          let provider = providers[provider] as? [String: Any],
          let baseUrl = provider["baseUrl"] as? String,
          !baseUrl.isEmpty else {
        return nil
    }
    return baseUrl
}

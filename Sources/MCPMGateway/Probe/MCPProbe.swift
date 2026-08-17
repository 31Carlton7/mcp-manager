import Foundation

/// Outcome of a "Test connection": the MCP `initialize` handshake plus a best-effort `tools/list`.
public struct ProbeResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var serverName: String?
    public var serverVersion: String?
    public var protocolVersion: String?
    public var toolCount: Int?
    public var error: String?
    public var durationMs: Int

    public init(ok: Bool, serverName: String? = nil, serverVersion: String? = nil,
                protocolVersion: String? = nil, toolCount: Int? = nil, error: String? = nil,
                durationMs: Int) {
        self.ok = ok; self.serverName = serverName; self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion; self.toolCount = toolCount; self.error = error
        self.durationMs = durationMs
    }
}

/// Speaks just enough MCP to identify a server: `initialize` → `notifications/initialized` →
/// `tools/list`. Never throws; every failure is folded into `ProbeResult.error`.
public enum MCPProbe {
    static let protocolVersion = "2025-06-18"
    static var clientInfo: [String: Any] { ["name": "MCP Manager", "version": "0.1.0"] }

    // MARK: - JSON-RPC helpers

    static func initializeMessage() -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": ["protocolVersion": protocolVersion, "capabilities": [String: Any](),
                    "clientInfo": clientInfo]]
    }
    static var initializedNotification: [String: Any] { ["jsonrpc": "2.0", "method": "notifications/initialized"] }
    static var toolsListMessage: [String: Any] { ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()] }

    static func encode(_ message: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    }

    /// Fills the identity fields of `result` from an `initialize` response object.
    static func applyInitialize(_ response: [String: Any], to result: inout ProbeResult) -> Bool {
        guard let res = response["result"] as? [String: Any] else {
            if let err = response["error"] as? [String: Any] {
                result.error = (err["message"] as? String) ?? "initialize failed"
            } else {
                result.error = "initialize returned no result"
            }
            return false
        }
        let info = res["serverInfo"] as? [String: Any]
        result.serverName = info?["name"] as? String
        result.serverVersion = info?["version"] as? String
        result.protocolVersion = res["protocolVersion"] as? String
        result.ok = true
        return true
    }

    static func toolCount(from response: [String: Any]) -> Int? {
        ((response["result"] as? [String: Any])?["tools"] as? [Any])?.count
    }

    /// Extracts the JSON-RPC response object with the given id from a body that is either plain
    /// JSON or an SSE stream (`data:` lines).
    static func responseObject(id: Int, in body: Data, contentType: String?) -> [String: Any]? {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], matches(obj, id: id) {
            return obj
        }
        // SSE: concatenate consecutive `data:` lines per event, try each event.
        let text = String(decoding: body, as: UTF8.self)
        var current: [String] = []
        func flush() -> [String: Any]? {
            defer { current.removeAll() }
            guard !current.isEmpty else { return nil }
            let joined = current.joined(separator: "\n")
            if let obj = try? JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [String: Any],
               matches(obj, id: id) { return obj }
            return nil
        }
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty { if let hit = flush() { return hit }; continue }
            if line.hasPrefix("data:") {
                current.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        return flush()
    }

    static func matches(_ obj: [String: Any], id: Int) -> Bool {
        if let n = obj["id"] as? Int { return n == id }
        if let n = obj["id"] as? Double { return Int(n) == id }
        if let s = obj["id"] as? String { return s == String(id) }
        return false
    }

    static func millis(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - Remote (Streamable HTTP)

    public static func remote(url: URL, headers: [String: String] = [:],
                              timeout: Duration = .seconds(10)) async -> ProbeResult {
        let start = ContinuousClock.now
        var result = ProbeResult(ok: false, durationMs: 0)
        defer { result.durationMs = millis(since: start) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(timeout.components.seconds)
        config.timeoutIntervalForResource = TimeInterval(timeout.components.seconds)
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var sessionID: String?

        func request(_ method: String, body: Data?) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            req.httpBody = body
            return req
        }

        // 1. initialize
        let initData: Data
        let initResponse: HTTPURLResponse
        do {
            let (data, resp) = try await session.data(for: request("POST", body: encode(initializeMessage())))
            guard let http = resp as? HTTPURLResponse else {
                result.error = "no HTTP response"; return result
            }
            initData = data; initResponse = http
        } catch {
            result.error = (error as NSError).localizedDescription
            return result
        }
        switch initResponse.statusCode {
        case 200...299: break
        case 401, 403: result.error = "needs sign-in"; return result
        default: result.error = "HTTP \(initResponse.statusCode)"; return result
        }
        sessionID = initResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
        guard let initObj = responseObject(id: 1, in: initData,
                                           contentType: initResponse.value(forHTTPHeaderField: "Content-Type")) else {
            result.error = "could not parse initialize response"; return result
        }
        guard applyInitialize(initObj, to: &result) else { return result }

        // 2. initialized notification (fire and forget)
        _ = try? await session.data(for: request("POST", body: encode(initializedNotification)))

        // 3. tools/list (best effort)
        if let (data, resp) = try? await session.data(for: request("POST", body: encode(toolsListMessage))),
           let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let obj = responseObject(id: 2, in: data, contentType: http.value(forHTTPHeaderField: "Content-Type")) {
            result.toolCount = toolCount(from: obj)
        }

        // 4. close the session (best effort)
        if sessionID != nil {
            _ = try? await session.data(for: request("DELETE", body: nil))
        }
        return result
    }

    // MARK: - Stdio

    /// PATH from the user's login shell, so `npx`/`uvx`/`python3` installed via Homebrew or
    /// nvm resolve the same way they do in Terminal. Computed once.
    private static let loginPATH: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "echo $PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    }()

    static func resolveExecutable(_ command: String) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for dir in loginPATH.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func stdio(command: String, args: [String], env: [String: String],
                             timeout: Duration = .seconds(10)) async -> ProbeResult {
        let start = ContinuousClock.now
        var result = ProbeResult(ok: false, durationMs: 0)
        defer { result.durationMs = millis(since: start) }

        guard let exe = resolveExecutable(command) else {
            result.error = "command not found: \(command)"
            return result
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = loginPATH
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Line reader over stdout: a detached task feeds an AsyncStream so we can race it against
        // the timeout without blocking on `readLine`.
        let (lines, cont) = AsyncStream<String>.makeStream()
        let stdoutHandle = stdout.fileHandleForReading
        let readerTask = Task.detached {
            var buffer = Data()
            while true {
                let chunk = stdoutHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { cont.yield(line) }
                }
            }
            cont.finish()
        }

        do { try process.run() } catch {
            readerTask.cancel(); cont.finish()
            result.error = "could not launch \(command): \((error as NSError).localizedDescription)"
            return result
        }

        func write(_ message: [String: Any]) {
            var data = encode(message); data.append(0x0A)
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
        func firstStderrLine() -> String? {
            let data = stderr.fileHandleForReading.availableData
            let text = String(decoding: data, as: UTF8.self)
            return text.split(whereSeparator: \.isNewline).first.map(String.init)
        }
        func shutdown() {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                Task.detached {
                    try? await Task.sleep(for: .seconds(1))
                    if process.isRunning { process.interrupt(); kill(process.processIdentifier, SIGKILL) }
                }
            }
        }

        /// Partial progress, so a handshake that identifies the server but never gets a tools/list
        /// answer still reports what it learned when the deadline hits.
        actor Progress {
            var result: ProbeResult?
            func set(_ r: ProbeResult) { result = r }
        }
        let progress = Progress()

        let handshake = Task { () -> ProbeResult in
            var partial = ProbeResult(ok: false, durationMs: 0)
            var iterator = lines.makeAsyncIterator()
            func awaitResponse(id: Int) async -> [String: Any]? {
                while let line = await iterator.next() {
                    if Task.isCancelled { return nil }
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                       matches(obj, id: id) { return obj }
                }
                return nil
            }
            write(initializeMessage())
            guard let initObj = await awaitResponse(id: 1) else {
                partial.error = "no initialize response"
                return partial
            }
            guard applyInitialize(initObj, to: &partial) else { return partial }
            await progress.set(partial)
            write(initializedNotification)
            write(toolsListMessage)
            if let obj = await awaitResponse(id: 2) { partial.toolCount = toolCount(from: obj) }
            return partial
        }

        // Race the handshake against the deadline.
        let outcome: ProbeResult? = await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { await handshake.value }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            handshake.cancel()
            return first
        }
        shutdown()
        readerTask.cancel()

        /// A child that closes stdout is usually exiting; give the kernel a moment to reap it so
        /// `isRunning`/`terminationStatus`/stderr are meaningful.
        func settle() async {
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        }

        if let outcome {
            if outcome.ok { result = outcome; return result }
            // initialize never came back or came back as an error
            await settle()
            if !process.isRunning, let err = firstStderrLine() {
                result.error = err
            } else if !process.isRunning {
                result.error = "server exited (status \(process.terminationStatus)) before answering initialize"
            } else {
                result.error = outcome.error ?? "no initialize response"
            }
            return result
        }
        // Timed out.
        if let partial = await progress.result {
            result = partial   // identified, tools/list just never arrived
            return result
        }
        await settle()
        if !process.isRunning, let err = firstStderrLine() {
            result.error = err
        } else {
            result.error = "timed out waiting for initialize"
        }
        return result
    }
}

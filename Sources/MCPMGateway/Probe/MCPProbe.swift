import Darwin
import Foundation
import MCPMCore

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

/// Partial progress, so a handshake that identifies the server but never gets a `tools/list`
/// answer still reports what it learned when the deadline hits.
private actor Progress {
    var result: ProbeResult?
    func set(_ r: ProbeResult) { result = r }
}

/// A finished stdio handshake. `answered` separates "the server said no" (a JSON-RPC error, which
/// is the message worth showing) from "the server never said anything".
private struct Handshake: Sendable {
    var result: ProbeResult
    var answered: Bool
}

/// One read off a pipe, straight through `read(2)`. `FileHandle.availableData` raises an
/// Objective-C exception on a closed descriptor, and the handler that calls it can still be in
/// flight when the probe shuts the pipe down; this returns nothing instead.
private func readAvailable(_ fd: Int32) -> Data {
    var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        return n > 0 ? Data(scratch[0..<n]) : Data()
    }
}

/// Splits a child's stdout into lines off the pipe's readability handler. The handler runs on a
/// GCD queue rather than a task, so nothing here can be `await`ed — hence the lock.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var eof = false

    var reachedEOF: Bool { lock.withLock { eof } }
    func markEOF() { lock.withLock { eof = true } }

    func take(_ chunk: Data) -> [String] {
        lock.withLock {
            buffer.append(chunk)
            var lines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
            }
            return lines
        }
    }
}

/// Keeps the useful ends of a child's stderr — the first line, which is nearly always the real
/// error, and the last few KiB — while still reading everything. A server that logs a banner on
/// every startup must not be able to fill its stderr pipe and block on the write.
private final class StderrTail: @unchecked Sendable {
    private static let headLimit = 1024
    private static let tailLimit = 4096

    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            if head.count < Self.headLimit { head.append(chunk.prefix(Self.headLimit - head.count)) }
            tail.append(chunk)
            if tail.count > Self.tailLimit { tail.removeFirst(tail.count - Self.tailLimit) }
        }
    }

    var firstLine: String? {
        lock.withLock {
            String(decoding: head, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }
    }

    /// Picks up whatever the child wrote after the handler was detached. Non-blocking and bounded,
    /// so a live child that is still writing cannot hold the probe here.
    func drain(fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        for _ in 0..<64 {
            let chunk = readAvailable(fd)
            if chunk.isEmpty { return }
            append(chunk)
        }
    }
}

/// Speaks just enough MCP to identify a server: `initialize` → `notifications/initialized` →
/// `tools/list`. Never throws; every failure is folded into `ProbeResult.error`.
public enum MCPProbe {
    static let protocolVersion = "2025-06-18"
    /// The most of a response body worth holding on to. An `initialize` answer is a few hundred
    /// bytes; anything past this is not one.
    static let maxBodyBytes = 1024 * 1024
    static var clientInfo: [String: Any] { ["name": "MCP Manager", "version": MCPMVersion.current] }

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
    /// JSON or an SSE stream (`data:` lines). `contentType` picks the shape when the server says
    /// which one it sent; both are tried when it doesn't.
    static func responseObject(id: Int, in body: Data, contentType: String?) -> [String: Any]? {
        let type = (contentType ?? "").lowercased()
        if !type.contains("text/event-stream") {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], matches(obj, id: id) {
                return obj
            }
            if type.contains("application/json") { return nil }
        }
        var event: [String] = []
        for rawLine in String(decoding: body, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty {
                if let hit = sseEvent(event, id: id) { return hit }
                event.removeAll()
                continue
            }
            if line.hasPrefix("data:") {
                event.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        return sseEvent(event, id: id)
    }

    /// The `data:` lines of one SSE event, which the spec says are joined with newlines.
    static func sseObject(_ dataLines: [String]) -> [String: Any]? {
        guard !dataLines.isEmpty else { return nil }
        let joined = dataLines.joined(separator: "\n")
        return try? JSONSerialization.jsonObject(with: Data(joined.utf8)) as? [String: Any]
    }

    static func sseEvent(_ dataLines: [String], id: Int) -> [String: Any]? {
        guard let obj = sseObject(dataLines), matches(obj, id: id) else { return nil }
        return obj
    }

    static func matches(_ obj: [String: Any], id: Int) -> Bool {
        if let n = obj["id"] as? Int { return n == id }
        if let n = obj["id"] as? Double { return Int(n) == id }
        if let s = obj["id"] as? String { return s == String(id) }
        // A server that fails before it can echo the id answers with `"id": null`. Only one
        // request is ever in flight here, so that error is the answer to it.
        if obj["error"] != nil, obj["id"] == nil || obj["id"] is NSNull { return true }
        return false
    }

    static func millis(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Remote (Streamable HTTP)

    /// Sends one request. With an `id`, reads the body only until that response has been parsed —
    /// a Streamable-HTTP server is allowed to hold its SSE stream open long after it has answered,
    /// and waiting for the end of it would hang the probe. With no `id` the body is left unread.
    static func send(_ session: URLSession, _ request: URLRequest,
                     expecting id: Int?) async throws -> (HTTPURLResponse, [String: Any]?) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard let id, (200...299).contains(http.statusCode) else { return (http, nil) }

        if contentType?.lowercased().contains("text/event-stream") == true {
            var event: [String] = []
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else {
                    event.removeAll()   // any other field belongs to the next event
                    continue
                }
                event.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                // `AsyncLineSequence` drops the blank line that ends an SSE event, so an event is
                // over when its `data:` lines parse — which a half-delivered one cannot do.
                guard let obj = sseObject(event) else { continue }
                if matches(obj, id: id) { return (http, obj) }
                event.removeAll()
            }
            return (http, nil)
        }
        // Plain JSON: buffer the body, up to a point. Rejoining the lines is lossless, since a
        // newline inside a JSON string has to be escaped. A body past the cap is not an MCP
        // answer — it is a docs page or something trying to make us hold it in memory.
        var text = ""
        var size = 0
        for try await line in bytes.lines {
            size += line.utf8.count + 1
            guard size <= maxBodyBytes else { return (http, nil) }
            text += line
            text += "\n"
        }
        return (http, responseObject(id: id, in: Data(text.utf8), contentType: contentType))
    }

    /// `transport` is what the library recorded for the server. `.sse` goes straight to the legacy
    /// flow; nil means "never recorded", which is the case for every server imported before
    /// transports were, so the POST is tried first and the legacy flow is the fallback.
    public static func remote(url: URL, headers: [String: String] = [:], transport: Transport? = nil,
                              timeout: Duration = .seconds(10)) async -> ProbeResult {
        let start = ContinuousClock.now
        var r: ProbeResult
        if transport == .sse {
            r = await remoteSSEImpl(url: url, headers: headers, timeout: timeout)
        } else {
            r = await remoteImpl(url: url, headers: headers, timeout: timeout)
            if !r.ok, looksLikeLegacyTransport(r.error) {
                let legacy = await remoteSSEImpl(url: url, headers: headers, timeout: timeout)
                if legacy.ok { r = legacy }
            }
        }
        r.durationMs = millis(since: start)
        return r
    }

    /// The failures worth a second attempt over the legacy transport: a server that only speaks it
    /// refuses the POST outright. A refusal, a timeout or a dead host says nothing about transports
    /// and is reported as it stands.
    static func looksLikeLegacyTransport(_ error: String?) -> Bool {
        switch error {
        case "HTTP 404", "HTTP 405", "HTTP 400", "HTTP 406", "could not parse initialize response": true
        default: false
        }
    }

    static func remoteImpl(url: URL, headers: [String: String], timeout: Duration) async -> ProbeResult {
        var result = ProbeResult(ok: false, durationMs: 0)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = seconds(timeout)
        config.timeoutIntervalForResource = seconds(timeout)
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let progress = Progress()
        let flow = Task { () -> ProbeResult in
            var partial = ProbeResult(ok: false, durationMs: 0)
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
            let initHTTP: HTTPURLResponse
            let initObj: [String: Any]?
            do {
                (initHTTP, initObj) = try await send(session, request("POST", body: encode(initializeMessage())),
                                                     expecting: 1)
            } catch {
                partial.error = (error as NSError).localizedDescription
                return partial
            }
            switch initHTTP.statusCode {
            case 200...299: break
            case 401, 403: partial.error = "needs sign-in"; return partial
            default: partial.error = "HTTP \(initHTTP.statusCode)"; return partial
            }
            sessionID = initHTTP.value(forHTTPHeaderField: "Mcp-Session-Id")
            guard let initObj else {
                partial.error = "could not parse initialize response"; return partial
            }
            guard applyInitialize(initObj, to: &partial) else { return partial }
            await progress.set(partial)

            // 2. initialized notification (fire and forget)
            _ = try? await send(session, request("POST", body: encode(initializedNotification)), expecting: nil)

            // 3. tools/list (best effort)
            if let (http, obj) = try? await send(session, request("POST", body: encode(toolsListMessage)),
                                                 expecting: 2),
               (200...299).contains(http.statusCode), let obj {
                partial.toolCount = toolCount(from: obj)
            }

            // 4. close the session (best effort)
            if sessionID != nil {
                _ = try? await send(session, request("DELETE", body: nil), expecting: nil)
            }
            return partial
        }

        // `timeout` is the deadline for the whole exchange, not for each request in it.
        let outcome: ProbeResult? = await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { await flow.value }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            flow.cancel()
            return first
        }
        if let outcome { result = outcome; return result }
        if let partial = await progress.result {
            result = partial   // identified, the rest just never arrived
            return result
        }
        result.error = "timed out"
        return result
    }

    // MARK: - Remote (legacy HTTP+SSE)

    /// One SSE event, reassembled from the lines of a stream.
    struct SSEEvent {
        var name: String?
        var data: [String]
    }

    /// Reads `bytes.lines` as SSE. `AsyncLineSequence` drops the blank line that ends an event, so
    /// an event is finished when what it carries can be read: an `endpoint` event is one line, and
    /// a `message` event ends when its `data:` lines parse.
    static func sseEvents(_ lines: AsyncLineSequence<URLSession.AsyncBytes>) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var name: String?
                var data: [String] = []
                var size = 0
                func reset() { name = nil; data.removeAll(); size = 0 }
                do {
                    for try await line in lines {
                        if line.hasPrefix("event:") {
                            reset()
                            name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        data.append(payload)
                        size += payload.utf8.count
                        // An event whose `data:` lines never parse would otherwise grow without
                        // bound; past the cap it is not a JSON-RPC answer and never will be.
                        if size > maxBodyBytes { reset(); continue }
                        if name == "endpoint" || sseObject(data) != nil {
                            continuation.yield(SSEEvent(name: name, data: data))
                            reset()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The message endpoint an SSE server names, resolved against the stream's URL. Kept on the
    /// stream's own origin: that address is where this probe's headers — an API key, in the common
    /// case — are about to be posted, and a server does not get to redirect them elsewhere.
    static func messageEndpoint(_ raw: String, stream url: URL) throws -> URL {
        guard let resolved = URL(string: raw, relativeTo: url)?.absoluteURL else {
            throw ProbeFailure("the server named an unusable message endpoint: \(raw)")
        }
        guard resolved.scheme == url.scheme, resolved.host == url.host, resolved.port == url.port else {
            throw ProbeFailure("the server pointed its message endpoint at another host: \(resolved.host ?? raw)")
        }
        return resolved
    }

    struct ProbeFailure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// The 2024-11-05 transport: GET opens a stream, the server answers with an `endpoint` event
    /// naming where to post, and every response comes back down the stream rather than as the
    /// body of the POST that asked for it.
    static func remoteSSEImpl(url: URL, headers: [String: String], timeout: Duration) async -> ProbeResult {
        var result = ProbeResult(ok: false, durationMs: 0)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = seconds(timeout)
        config.timeoutIntervalForResource = seconds(timeout)
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let progress = Progress()
        let flow = Task { () -> ProbeResult in
            var partial = ProbeResult(ok: false, durationMs: 0)

            /// Posts one message to the endpoint the server named. The answer arrives on the
            /// stream, so the response body here is drained and discarded.
            func post(_ message: [String: Any], to endpoint: URL) async throws {
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                req.httpBody = encode(message)
                let (bytes, response) = try await session.bytes(for: req)
                for try await _ in bytes {}
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    throw ProbeFailure(status == 401 || status == 403 ? "needs sign-in" : "HTTP \(status)")
                }
            }

            var open = URLRequest(url: url)
            open.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            for (k, v) in headers { open.setValue(v, forHTTPHeaderField: k) }

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await session.bytes(for: open)
            } catch {
                partial.error = (error as NSError).localizedDescription
                return partial
            }
            guard let http = response as? HTTPURLResponse else {
                partial.error = "not an HTTP response"; return partial
            }
            switch http.statusCode {
            case 200...299: break
            case 401, 403: partial.error = "needs sign-in"; return partial
            default: partial.error = "HTTP \(http.statusCode)"; return partial
            }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                .contains("text/event-stream") == true else {
                partial.error = "the server did not open an event stream"; return partial
            }

            var endpoint: URL?
            do {
                for try await event in sseEvents(bytes.lines) {
                    if event.name == "endpoint" {
                        guard let raw = event.data.first else { continue }
                        let resolved = try messageEndpoint(raw, stream: url)
                        endpoint = resolved
                        try await post(initializeMessage(), to: resolved)
                        continue
                    }
                    guard let endpoint, let obj = sseObject(event.data) else { continue }
                    if !partial.ok, matches(obj, id: 1) {
                        guard applyInitialize(obj, to: &partial) else { return partial }
                        await progress.set(partial)
                        try? await post(initializedNotification, to: endpoint)
                        try await post(toolsListMessage, to: endpoint)
                    } else if matches(obj, id: 2) {
                        partial.toolCount = toolCount(from: obj)
                        return partial
                    }
                }
            } catch let failure as ProbeFailure {
                partial.error = failure.description
                return partial
            } catch {
                if partial.ok { return partial }   // the stream ended after the handshake
                partial.error = (error as NSError).localizedDescription
                return partial
            }
            if !partial.ok, partial.error == nil {
                partial.error = endpoint == nil ? "the server never named a message endpoint"
                                                : "no initialize response"
            }
            return partial
        }

        let outcome: ProbeResult? = await withTaskGroup(of: ProbeResult?.self) { group in
            group.addTask { await flow.value }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            flow.cancel()
            return first
        }
        if let outcome { result = outcome; return result }
        if let partial = await progress.result { result = partial; return result }
        result.error = "timed out"
        return result
    }

    // MARK: - Stdio

    /// PATH from the user's login shell, so `npx`/`uvx`/`python3` installed via Homebrew or
    /// nvm resolve the same way they do in Terminal. Computed once.
    private static let loginPATH: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return inherited }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // Interactive as well as login: nvm, pyenv and rbenv put themselves on PATH from .zshrc,
        // which a login-only shell never reads.
        p.arguments = ["-ilc", #"printf "%s" "$PATH""#]
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return inherited }

        // A shell rc that blocks (a prompt, a hung version manager) must not wedge the daemon.
        let deadline = DispatchWorkItem {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        try? out.fileHandleForReading.close()

        // The last line, because an interactive rc is free to print things before we get a word in.
        let path = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return path ?? inherited
    }()

    /// `path` is the caller's own PATH, if it set one: a server configured with a PATH expects its
    /// command to be looked up there first.
    static func resolveExecutable(_ command: String, path: String? = nil) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for dir in (path ?? "").split(separator: ":") + loginPATH.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func stdio(command: String, args: [String], env: [String: String],
                             timeout: Duration = .seconds(10)) async -> ProbeResult {
        let start = ContinuousClock.now
        var r = await stdioImpl(command: command, args: args, env: env, timeout: timeout)
        r.durationMs = millis(since: start)
        return r
    }

    static func stdioImpl(command: String, args: [String], env: [String: String], timeout: Duration) async -> ProbeResult {
        var result = ProbeResult(ok: false, durationMs: 0)

        guard let exe = resolveExecutable(command, path: env["PATH"]) else {
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

        // A server that answers and exits leaves us writing into a pipe with no reader; without
        // this that write raises SIGPIPE, which would kill the daemon rather than the probe.
        let stdinFD = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)

        // Both pipes are drained by readability handlers on GCD's queues: no thread parked on a
        // blocking read, and a child that chatters on stderr can never fill that pipe and stall.
        let (lines, cont) = AsyncStream<String>.makeStream()
        let reader = LineReader()
        let stderrTail = StderrTail()
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let chunk = readAvailable(handle.fileDescriptor)
            guard !chunk.isEmpty else {
                reader.markEOF()
                handle.readabilityHandler = nil
                cont.finish()
                return
            }
            for line in reader.take(chunk) { cont.yield(line) }
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = readAvailable(handle.fileDescriptor)
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            stderrTail.append(chunk)
        }

        func shutdown() {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            stderrTail.drain(fd: stderrHandle.fileDescriptor)
            cont.finish()
            try? stdin.fileHandleForWriting.close()
            try? stdoutHandle.close()
            try? stderrHandle.close()
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            // Only the child itself, not its process group: `Process` does not make the child a
            // group leader, so `kill(-pid)` would signal the daemon's own group. A server that
            // spawns grandchildren (npx) leaves them to be reaped by launchd.
            Task.detached {
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        do { try process.run() } catch {
            shutdown()
            result.error = "could not launch \(command): \((error as NSError).localizedDescription)"
            return result
        }

        func write(_ message: [String: Any]) {
            var data = encode(message)
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(stdinFD, base.advanced(by: offset), raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    // EPIPE and friends: the child is gone. The handshake fails on its own when
                    // stdout closes, and there is nothing useful to say about the write itself.
                    if n <= 0 { return }
                    offset += n
                }
            }
        }

        let progress = Progress()
        let handshake = Task { () -> Handshake in
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
                return Handshake(result: partial, answered: false)
            }
            guard applyInitialize(initObj, to: &partial) else {
                return Handshake(result: partial, answered: true)
            }
            await progress.set(partial)
            write(initializedNotification)
            write(toolsListMessage)
            if let obj = await awaitResponse(id: 2) { partial.toolCount = toolCount(from: obj) }
            return Handshake(result: partial, answered: true)
        }

        // Race the handshake against the deadline.
        let outcome: Handshake? = await withTaskGroup(of: Handshake?.self) { group in
            group.addTask { await handshake.value }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            handshake.cancel()
            return first
        }

        // A child that closed stdout is on its way out; give the kernel a moment to reap it so
        // `isRunning`, `terminationStatus` and stderr all say something meaningful. After a
        // deadline the child is by definition still alive, and waiting would only cost time.
        if reader.reachedEOF {
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        }
        // Whether the child died by itself, decided before `shutdown()` gets a chance to kill it.
        let exitedOnItsOwn = !process.isRunning
        let status = exitedOnItsOwn ? process.terminationStatus : 0
        shutdown()

        if let outcome {
            if outcome.result.ok { result = outcome.result; return result }
            // The server answered `initialize` with an error: its own message beats any guess we
            // could make from stderr or an exit status.
            if outcome.answered {
                result.error = outcome.result.error ?? "initialize failed"
                return result
            }
        } else if let partial = await progress.result {
            result = partial   // identified, tools/list just never arrived
            return result
        }
        if exitedOnItsOwn {
            result.error = stderrTail.firstLine
                ?? "server exited (status \(status)) before answering initialize"
            return result
        }
        result.error = outcome?.result.error ?? "timed out waiting for initialize"
        return result
    }
}

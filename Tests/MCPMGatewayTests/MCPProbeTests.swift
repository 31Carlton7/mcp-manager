import Testing
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
@testable import MCPMGateway

// MARK: - The fake remote MCP server

/// The ways a Streamable-HTTP server may answer a POST: a plain JSON body, a one-event stream, or
/// a stream that carries the answer and then stays open. The probe has to read all three.
private enum Wire {
    case json
    case sse
    case sseHeldOpen
}

/// What the fake server was asked, in order — the probe's side of the handshake is only really
/// checkable from here.
private struct Seen: Sendable {
    var httpMethod: String
    var rpcMethod: String?
    var sessionID: String?
    var accept: String?
    var apiKey: String?
}

private actor Recorder {
    private(set) var seen: [Seen] = []
    func add(_ item: Seen) { seen.append(item) }
}

private let probeToolNames = ["search", "fetch", "create"]

private func probeRouter(wire: Wire, status: HTTPResponse.Status, delay: Duration,
                         recorder: Recorder) -> Router<BasicRequestContext> {
    let router = Router()
    let apiKeyName = HTTPField.Name("X-Api-Key")!

    router.post("/mcp") { request, _ in
        let buffer = try await request.body.collect(upTo: 1024 * 1024)
        if delay > .zero { try await Task.sleep(for: delay) }
        let (message, data) = mcpResponse(to: buffer, toolNames: probeToolNames)
        await recorder.add(Seen(httpMethod: "POST", rpcMethod: message?["method"] as? String,
                                sessionID: request.headers[.mcpSessionID],
                                accept: request.headers[.accept],
                                apiKey: request.headers[apiKeyName]))

        guard status == .ok else {
            return Response(status: status, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_token"}"#)))
        }
        guard let data else { return Response(status: .accepted, body: .init()) }

        var headers = HTTPFields()
        headers[.mcpSessionID] = "sess-7"
        switch wire {
        case .json:
            headers[.contentType] = "application/json"
            return Response(status: .ok, headers: headers,
                            body: .init(byteBuffer: ByteBuffer(bytes: data)))
        case .sse:
            headers[.contentType] = "text/event-stream"
            // A comment and an event name before the payload, so a parser that just grabbed the
            // first line would fail here.
            let event = ": keep-alive\n\nevent: message\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: event)))
        case .sseHeldOpen:
            headers[.contentType] = "text/event-stream"
            let event = "event: message\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
            // The answer, and then a stream that goes on well past it — which is allowed, and
            // which a probe that waits for the end of the body would sit through three times.
            return Response(status: .ok, headers: headers, body: .init(contentLength: nil) { writer in
                try await writer.write(ByteBuffer(string: event))
                for _ in 0..<12 {
                    try await Task.sleep(for: .milliseconds(250))
                    try await writer.write(ByteBuffer(string: ": keep-alive\n\n"))
                }
                try await writer.finish(nil)
            })
        }
    }

    router.delete("/mcp") { request, _ in
        await recorder.add(Seen(httpMethod: "DELETE", rpcMethod: nil,
                                sessionID: request.headers[.mcpSessionID],
                                accept: request.headers[.accept], apiKey: nil))
        return Response(status: .ok, body: .init())
    }

    return router
}

private func withRemoteServer(wire: Wire = .json, status: HTTPResponse.Status = .ok,
                              delay: Duration = .zero,
                              _ body: (URL, Recorder) async throws -> Void) async throws {
    let recorder = Recorder()
    try await withServer(probeRouter(wire: wire, status: status, delay: delay, recorder: recorder)) { base in
        try await body(base.appendingPathComponent("mcp"), recorder)
    }
}

// MARK: - Remote

@Test func aRemoteServerIsIdentifiedAndItsToolsCounted() async throws {
    try await withRemoteServer { url, recorder in
        let result = await MCPProbe.remote(url: url, headers: ["X-Api-Key": "k-1"])

        #expect(result.ok)
        #expect(result.serverName == "fake-remote")
        #expect(result.serverVersion == "2.3")
        #expect(result.protocolVersion == "2025-06-18")
        #expect(result.toolCount == 3)
        #expect(result.error == nil)
        #expect(result.durationMs > 0)   // a real round trip took measurable time

        let seen = await recorder.seen
        #expect(seen.map(\.rpcMethod) == ["initialize", "notifications/initialized", "tools/list", nil])
        #expect(seen.map(\.httpMethod) == ["POST", "POST", "POST", "DELETE"])
        // Both shapes are advertised up front, because the server picks which one it sends.
        #expect(seen.first?.accept == "application/json, text/event-stream")
        #expect(seen.first?.apiKey == "k-1")
        // The id the server handed out on initialize rides along on everything after it.
        #expect(seen.first?.sessionID == nil)
        #expect(seen.dropFirst().allSatisfy { $0.sessionID == "sess-7" })
    }
}

@Test func aRemoteServerThatAnswersWithAnEventStreamIsReadJustTheSame() async throws {
    try await withRemoteServer(wire: .sse) { url, _ in
        let result = await MCPProbe.remote(url: url)

        #expect(result.ok)
        #expect(result.serverName == "fake-remote")
        #expect(result.serverVersion == "2.3")
        #expect(result.toolCount == 3)
    }
}

@Test(arguments: [HTTPResponse.Status.unauthorized, .forbidden])
func aRejectedProbeAsksForASignIn(status: HTTPResponse.Status) async throws {
    try await withRemoteServer(status: status) { url, recorder in
        let result = await MCPProbe.remote(url: url)

        #expect(!result.ok)
        #expect(result.error == "needs sign-in")
        #expect(result.serverName == nil)
        // Nothing follows a refusal: no notification, no tools/list, no session to delete.
        #expect(await recorder.seen.count == 1)
    }
}

@Test func anyOtherRefusalIsReportedAsItsStatusCode() async throws {
    try await withRemoteServer(status: .internalServerError) { url, _ in
        let result = await MCPProbe.remote(url: url)
        #expect(!result.ok)
        #expect(result.error == "HTTP 500")
    }
}

@Test func aStreamThatStaysOpenAfterAnsweringDoesNotHoldTheProbe() async throws {
    try await withRemoteServer(wire: .sseHeldOpen) { url, _ in
        let started = ContinuousClock.now
        let result = await MCPProbe.remote(url: url, timeout: .seconds(10))
        let elapsed = ContinuousClock.now - started

        #expect(result.ok)
        #expect(result.toolCount == 3)
        // Three requests against a stream that runs for three seconds each: reading to the end
        // would blow the ten-second deadline, never mind this one.
        #expect(elapsed < .seconds(3))
    }
}

@Test func aSlowRemoteServerIsGivenUpOnAtTheOverallDeadlineWithWhatItAlreadySaid() async throws {
    // Every answer costs 700ms, so the handshake fits inside a one-second deadline and the
    // tools/list that follows it cannot. The timeout covers the exchange, not each request in it.
    try await withRemoteServer(delay: .milliseconds(700)) { url, _ in
        let started = ContinuousClock.now
        let result = await MCPProbe.remote(url: url, timeout: .seconds(1))
        let elapsed = ContinuousClock.now - started

        #expect(result.ok)
        #expect(result.serverName == "fake-remote")
        #expect(result.toolCount == nil)
        #expect(elapsed < .milliseconds(1500))
    }
}

@Test func aRemoteServerThatIsNotThereIsAnError() async throws {
    // Port 1 on loopback: nothing listens, and the connection is refused rather than hanging.
    let result = await MCPProbe.remote(url: URL(string: "http://127.0.0.1:1/mcp")!,
                                       timeout: .seconds(5))
    #expect(!result.ok)
    #expect(result.error?.isEmpty == false)
}

// MARK: - Stdio

private func fixtureScript() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "fake_stdio_server", withExtension: "py",
                                             subdirectory: "Fixtures"))
    return url.path
}

@Test func aStdioServerIsIdentifiedOverItsPipes() async throws {
    // `python3` is deliberately not an absolute path: this is the PATH lookup the daemon does for
    // every `npx`/`uvx` server it launches.
    let result = await MCPProbe.stdio(command: "python3", args: [try fixtureScript()], env: [:])

    #expect(result.ok)
    #expect(result.error == nil)
    #expect(result.serverName == "fake")
    #expect(result.serverVersion == "1.0")
    #expect(result.protocolVersion == "2025-06-18")
    #expect(result.toolCount == 2)
}

@Test func aCommandThatIsNotInstalledIsReportedRatherThanThrown() async {
    let result = await MCPProbe.stdio(command: "mcpm-no-such-command", args: [], env: [:])

    #expect(!result.ok)
    #expect(result.toolCount == nil)
    #expect(result.error?.contains("mcpm-no-such-command") == true)
}

@Test func aServerThatNeverAnswersIsGivenUpOnAtTheTimeout() async {
    let started = ContinuousClock.now
    // `sleep` reads nothing and writes nothing — the handshake can only end in the timeout.
    let result = await MCPProbe.stdio(command: "sleep", args: ["30"], env: [:], timeout: .seconds(1))
    let elapsed = ContinuousClock.now - started

    #expect(!result.ok)
    #expect(result.error?.contains("timed out") == true)
    #expect(elapsed < .seconds(6))
}

@Test func aServerThatDiesReportsWhatItSaidOnStderr() async {
    let script = "import sys; sys.stdin.readline(); sys.stderr.write('boom: missing API key\\n'); sys.exit(3)"
    let result = await MCPProbe.stdio(command: "python3", args: ["-c", script], env: [:],
                                      timeout: .seconds(10))

    #expect(!result.ok)
    #expect(result.error == "boom: missing API key")
}

@Test func theSuppliedEnvironmentReachesTheServerAndAMissingToolListIsNotFatal() async {
    // Answers initialize from the environment and then goes quiet, so this also pins down that a
    // tools/list that never arrives costs a count and not the whole probe.
    let script = """
        import json, os, sys
        sys.stdin.readline()
        print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {
            "protocolVersion": "2025-06-18",
            "serverInfo": {"name": os.environ.get("PROBE_NAME", "unset"), "version": "9"}}}),
            flush=True)
        sys.stdin.read()
        """
    let result = await MCPProbe.stdio(command: "python3", args: ["-c", script],
                                      env: ["PROBE_NAME": "from-env"], timeout: .seconds(2))

    #expect(result.ok)
    #expect(result.serverName == "from-env")
    #expect(result.toolCount == nil)
}

@Test func aServerThatAnswersAndExitsAtOnceIsStillIdentified() async {
    // The dangerous shape: by the time the probe writes the notification and tools/list, nothing
    // is holding the read end of stdin. That write must not raise SIGPIPE on this process.
    let script = """
        import json, sys
        sys.stdin.readline()
        print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {
            "protocolVersion": "2025-06-18",
            "serverInfo": {"name": "quitter", "version": "1"}}}), flush=True)
        sys.exit(0)
        """
    let result = await MCPProbe.stdio(command: "python3", args: ["-c", script], env: [:],
                                      timeout: .seconds(5))

    #expect(result.ok)
    #expect(result.serverName == "quitter")
    #expect(result.toolCount == nil)
    #expect(result.error == nil)
}

@Test func aServerThatOnlyLogsIsATimeoutRatherThanItsLogLine() async {
    let script = """
        import sys, time
        sys.stderr.write("INFO starting\\n")
        sys.stderr.flush()
        time.sleep(30)
        """
    let started = ContinuousClock.now
    let result = await MCPProbe.stdio(command: "python3", args: ["-c", script], env: [:],
                                      timeout: .seconds(1))
    let elapsed = ContinuousClock.now - started

    #expect(!result.ok)
    #expect(result.error?.contains("timed out") == true)
    // A live server's chatter is not a diagnosis: stderr only speaks for a server that died.
    #expect(result.error?.contains("INFO") == false)
    #expect(elapsed < .seconds(6))
}

@Test func aServerThatFillsItsErrorPipeBeforeAnsweringIsNotBlockedByIt() async {
    // ~240 KiB, several times the pipe buffer. A probe that does not drain stderr leaves the
    // child blocked on this write, and never gets an answer at all.
    let script = """
        import json, sys
        sys.stderr.write("noise\\n" * 40000)
        sys.stderr.flush()
        sys.stdin.readline()
        print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {
            "protocolVersion": "2025-06-18",
            "serverInfo": {"name": "chatty", "version": "1"}}}), flush=True)
        sys.exit(0)
        """
    let result = await MCPProbe.stdio(command: "python3", args: ["-c", script], env: [:],
                                      timeout: .seconds(5))

    #expect(result.ok)
    #expect(result.serverName == "chatty")
}

@Test func anInitializeErrorIsReportedEvenWhenTheServerCannotEchoTheId() async {
    // `"id": null` is what a server sends when it fails before it has parsed the request. The
    // error message it carries beats both the stderr line and the exit status that follow it.
    let script = """
        import json, sys
        sys.stdin.readline()
        print(json.dumps({"jsonrpc": "2.0", "id": None,
                          "error": {"code": -32600, "message": "missing API key"}}), flush=True)
        sys.stderr.write("Traceback (most recent call last)\\n")
        sys.exit(1)
        """
    let result = await MCPProbe.stdio(command: "python3", args: ["-c", script], env: [:],
                                      timeout: .seconds(5))

    #expect(!result.ok)
    #expect(result.error == "missing API key")
    #expect(result.toolCount == nil)
}

// MARK: - Wire formats

@Test func anEventSpreadOverSeveralDataLinesIsStitchedBackTogether() throws {
    // The SSE spec joins the `data:` lines of one event with newlines; a server is free to break
    // a long JSON-RPC answer across them.
    let body = """
        event: message
        data: {"jsonrpc":"2.0","id":2,
        data:  "result":{"tools":[{"name":"a"},{"name":"b"}]}}

        """
    let obj = try #require(MCPProbe.responseObject(id: 2, in: Data(body.utf8),
                                                   contentType: "text/event-stream"))
    #expect(MCPProbe.toolCount(from: obj) == 2)
}

// MARK: - The result the daemon sends on

@Test func aProbeResultSurvivesTheControlProtocolsJSON() throws {
    let result = ProbeResult(ok: true, serverName: "fake", serverVersion: "1.0",
                             protocolVersion: "2025-06-18", toolCount: 2, error: nil, durationMs: 41)
    let round = try JSONDecoder().decode(ProbeResult.self, from: JSONEncoder().encode(result))
    #expect(round == result)
}

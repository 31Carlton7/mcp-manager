import Testing
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
@testable import MCPMGateway

// MARK: - The fake remote MCP server

/// The two ways a Streamable-HTTP server may answer a POST: a plain JSON body, or a one-event
/// stream. The probe has to read both.
private enum Wire {
    case json
    case sse
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

private func probeResult(for rpcMethod: String?, params: [String: Any]) -> [String: Any]? {
    switch rpcMethod {
    case "initialize":
        return [
            // Echoed, so the test can tell the server saw the version the probe offered.
            "protocolVersion": params["protocolVersion"] as? String ?? "?",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "fake-remote", "version": "2.3"],
        ]
    case "tools/list":
        return ["tools": [["name": "search"], ["name": "fetch"], ["name": "create"]]]
    default:
        return nil
    }
}

private func probeRouter(wire: Wire, status: HTTPResponse.Status,
                         recorder: Recorder) -> Router<BasicRequestContext> {
    let router = Router()
    let apiKeyName = HTTPField.Name("X-Api-Key")!

    router.post("/mcp") { request, _ in
        let buffer = try await request.body.collect(upTo: 1024 * 1024)
        let message = (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)))
            as? [String: Any]
        let rpcMethod = message?["method"] as? String
        await recorder.add(Seen(httpMethod: "POST", rpcMethod: rpcMethod,
                                sessionID: request.headers[.mcpSessionID],
                                accept: request.headers[.accept],
                                apiKey: request.headers[apiKeyName]))

        guard status == .ok else {
            return Response(status: status, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_token"}"#)))
        }
        // A notification carries no id and gets no answer, exactly as in the MCP spec.
        guard let id = message?["id"] else { return Response(status: .accepted, body: .init()) }

        let params = message?["params"] as? [String: Any] ?? [:]
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "result": probeResult(for: rpcMethod, params: params) as Any,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

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

/// Runs the fake on an ephemeral loopback port for the duration of one test.
private func withRemoteServer(wire: Wire = .json, status: HTTPResponse.Status = .ok,
                              _ body: (URL, Recorder) async throws -> Void) async throws {
    let recorder = Recorder()
    let server = TestHTTPServer()
    try await server.start(probeRouter(wire: wire, status: status, recorder: recorder))
    let url = await server.baseURL.appendingPathComponent("mcp")
    do {
        try await body(url, recorder)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
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
        #expect(result.durationMs >= 0)

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

// MARK: - The result the daemon sends on

@Test func aProbeResultSurvivesTheControlProtocolsJSON() throws {
    let result = ProbeResult(ok: true, serverName: "fake", serverVersion: "1.0",
                             protocolVersion: "2025-06-18", toolCount: 2, error: nil, durationMs: 41)
    let round = try JSONDecoder().decode(ProbeResult.self, from: JSONEncoder().encode(result))
    #expect(round == result)
}

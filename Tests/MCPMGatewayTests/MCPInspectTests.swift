import Testing
import Foundation
import HTTPTypes
import Hummingbird
import MCPMCore
import NIOCore
@testable import MCPMGateway

// MARK: - Fakes

private let inspectToolNames = ["search", "fetch"]

/// A Streamable-HTTP endpoint at `/mcp` that answers in plain JSON.
private func mcpRoute(_ router: Router<BasicRequestContext>, path: String = "/mcp") {
    router.post(RouterPath(path)) { request, _ in
        let buffer = try await request.body.collect(upTo: 1024 * 1024)
        let (_, data) = mcpResponse(to: buffer, toolNames: inspectToolNames)
        guard let data else { return Response(status: .accepted, body: .init()) }
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// A docs page: it is there, it answers, and it is not an MCP server.
private func htmlRoute(_ router: Router<BasicRequestContext>, path: String) {
    router.post(RouterPath(path)) { _, _ in
        Response(status: .methodNotAllowed, headers: [.contentType: "text/html; charset=utf-8"],
                 body: .init(byteBuffer: ByteBuffer(string: "<!doctype html><html><body>docs</body></html>")))
    }
    router.get(RouterPath(path)) { _, _ in
        Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8"],
                 body: .init(byteBuffer: ByteBuffer(string: "<!doctype html><html><body>docs</body></html>")))
    }
}

/// An endpoint that refuses without a token, the way PostHog's does: a `WWW-Authenticate` naming
/// the protected-resource metadata, and metadata that names an authorization server.
private func protectedRoute(_ router: Router<BasicRequestContext>, publishMetadata: Bool) {
    router.post("/mcp") { request, _ in
        let host = request.head.authority ?? "127.0.0.1"
        let prm = "http://\(host)/.well-known/oauth-protected-resource/mcp"
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.wwwAuthenticate] = #"Bearer resource_metadata="\#(prm)""#
        return Response(status: .unauthorized, headers: headers,
                        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_token"}"#)))
    }
    guard publishMetadata else { return }
    router.get("/.well-known/oauth-protected-resource/mcp") { request, _ in
        let host = request.head.authority ?? "127.0.0.1"
        let json = """
            {"resource":"http://\(host)/mcp","authorization_servers":["https://as.example.com"]}
            """
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: json)))
    }
}

private actor SSEBus {
    private var cont: AsyncStream<String>.Continuation?
    func attach(_ c: AsyncStream<String>.Continuation) { cont = c }
    func send(_ s: String) { cont?.yield(s) }
    func finish() { cont?.finish() }
}

/// The 2024-11-05 HTTP+SSE transport: a GET that names a message endpoint and then carries every
/// response back down the same stream.
private func legacySSERoutes(_ router: Router<BasicRequestContext>, path: String = "/sse") {
    let bus = SSEBus()
    router.get(RouterPath(path)) { _, _ in
        let (stream, cont) = AsyncStream<String>.makeStream()
        await bus.attach(cont)
        return Response(status: .ok, headers: [.contentType: "text/event-stream"],
                        body: .init(contentLength: nil) { writer in
            try await writer.write(ByteBuffer(string: "event: endpoint\ndata: /messages?sessionId=abc\n\n"))
            for await chunk in stream { try await writer.write(ByteBuffer(string: chunk)) }
            try await writer.finish(nil)
        })
    }
    router.post("/messages") { request, _ in
        let buffer = try await request.body.collect(upTo: 1024 * 1024)
        let (message, data) = mcpResponse(to: buffer, toolNames: inspectToolNames)
        if let data {
            await bus.send("event: message\ndata: \(String(decoding: data, as: UTF8.self))\n\n")
        }
        // tools/list is the last thing the probe asks for; closing here keeps the fake from
        // holding a stream open past the end of the test.
        if message?["method"] as? String == "tools/list" { await bus.finish() }
        return Response(status: .accepted, body: .init())
    }
}

// MARK: - inspect

@Test func anEndpointThatAnswersInitializeIsIdentifiedAsOne() async throws {
    try await withServer({ mcpRoute($0) }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("mcp"))

        #expect(result.verdict == .mcpEndpoint)
        #expect(result.transport == .http)
        #expect(!result.authRequired)
        #expect(result.authKind == AuthKind.none)
        #expect(result.serverName == "fake-remote")
        #expect(result.serverVersion == "2.3")
        #expect(result.suggestion == nil)
    }
}

@Test func aRefusalThatNamesProtectedResourceMetadataIsOAuth() async throws {
    try await withServer({ protectedRoute($0, publishMetadata: true) }) { base in
        let url = base.appendingPathComponent("mcp")
        let result = await MCPProbe.inspect(url: url)

        #expect(result.verdict == .mcpEndpoint)
        #expect(result.transport == .http)
        #expect(result.authRequired)
        #expect(result.authKind == .oauth)
        #expect(result.statusCode == 401)
        #expect(result.resourceMetadataURL?.hasSuffix("/.well-known/oauth-protected-resource/mcp") == true)
    }
}

/// No metadata anywhere: the endpoint wants a credential, and the only kind we can offer without
/// an authorization server to talk to is a header the user pastes.
@Test func aRefusalWithNoMetadataFallsBackToHeaderAuth() async throws {
    try await withServer({ protectedRoute($0, publishMetadata: false) }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("mcp"))

        #expect(result.verdict == .mcpEndpoint)
        #expect(result.authRequired)
        #expect(result.authKind == .header)
    }
}

/// A docs page pasted into the Add sheet — the case this whole check exists for.
@Test func aDocsPageIsNotAnEndpointAndTheSiblingEndpointIsSuggested() async throws {
    try await withServer({ router in
        htmlRoute(router, path: "/docs/model-context-protocol")
        mcpRoute(router)
    }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("docs/model-context-protocol"))

        #expect(result.verdict == .notMCP)
        #expect(result.statusCode == 405)
        #expect(result.contentType?.contains("text/html") == true)
        #expect(result.suggestion == base.appendingPathComponent("mcp"))
    }
}

@Test func aPageWithNoEndpointAnywhereNearItGetsNoSuggestion() async throws {
    try await withServer({ htmlRoute($0, path: "/docs") }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("docs"))

        #expect(result.verdict == .notMCP)
        #expect(result.suggestion == nil)
    }
}

@Test func aLegacySSEEndpointIsIdentifiedByItsEndpointEvent() async throws {
    try await withServer({ legacySSERoutes($0) }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("sse"))

        #expect(result.verdict == .mcpEndpoint)
        #expect(result.transport == .sse)
        #expect(!result.authRequired)
    }
}

@Test func nothingListeningIsUnreachableRatherThanNotAnEndpoint() async {
    let result = await MCPProbe.inspect(url: URL(string: "http://127.0.0.1:1/mcp")!, timeout: .seconds(5))

    #expect(result.verdict == .unreachable)
    #expect(result.suggestion == nil)
    #expect(!result.detail.isEmpty)
}

@Test func anInspectionSurvivesTheControlProtocolsJSON() throws {
    let inspection = URLInspection(verdict: .mcpEndpoint, transport: .sse, authRequired: true,
                                   authKind: .oauth, resourceMetadataURL: "https://x.dev/.well-known/y",
                                   serverName: "n", serverVersion: "1", toolCount: 3, statusCode: 401,
                                   contentType: "application/json",
                                   suggestion: URL(string: "https://mcp.x.dev/mcp"), detail: "d")
    let round = try JSONDecoder().decode(URLInspection.self, from: JSONEncoder().encode(inspection))
    #expect(round == inspection)
}

// MARK: - Legacy SSE in `remote`

@Test func testConnectionWorksAgainstALegacySSEServer() async throws {
    try await withServer({ legacySSERoutes($0) }) { base in
        let result = await MCPProbe.remote(url: base.appendingPathComponent("sse"), transport: .sse)

        #expect(result.ok)
        #expect(result.serverName == "fake-remote")
        #expect(result.serverVersion == "2.3")
        #expect(result.toolCount == 2)
        #expect(result.error == nil)
    }
}

/// A library server recorded before transports were known says nothing about which one it speaks.
/// The POST comes back 405, and the probe tries the legacy flow rather than reporting that.
@Test func aServerWithNoRecordedTransportFallsBackToTheLegacyFlow() async throws {
    try await withServer({ router in
        router.post("/sse") { _, _ in Response(status: .methodNotAllowed, body: .init()) }
        legacySSERoutes(router)
    }) { base in
        let result = await MCPProbe.remote(url: base.appendingPathComponent("sse"), transport: nil)

        #expect(result.ok)
        #expect(result.toolCount == 2)
    }
}

/// The message endpoint an SSE server names is where our headers get sent; a server that points it
/// at another host must not be followed there.
@Test func aMessageEndpointOnAnotherOriginIsRefused() async throws {
    try await withServer({ router in
        router.get("/sse") { _, _ in
            Response(status: .ok, headers: [.contentType: "text/event-stream"],
                     body: .init(byteBuffer: ByteBuffer(string: "event: endpoint\ndata: https://evil.example/messages\n\n")))
        }
    }) { base in
        let result = await MCPProbe.remote(url: base.appendingPathComponent("sse"), transport: .sse,
                                           timeout: .seconds(5))

        #expect(!result.ok)
        #expect(result.error?.contains("evil.example") == true)
    }
}

// MARK: - Walls that are not endpoints

/// A login wall, a paywall, a WAF: they all answer a POST with a refusal, and none of them is an
/// MCP server. Without a challenge that says how to authenticate, a refusal proves nothing.
private func walledRoute(_ router: Router<BasicRequestContext>, path: String,
                         status: HTTPResponse.Status, contentType: String,
                         challenge: String? = nil) {
    router.post(RouterPath(path)) { _, _ in
        var headers = HTTPFields()
        headers[.contentType] = contentType
        if let challenge { headers[.wwwAuthenticate] = challenge }
        return Response(status: status, headers: headers,
                        body: .init(byteBuffer: ByteBuffer(string: "<html>sign in</html>")))
    }
}

@Test(arguments: [HTTPResponse.Status.forbidden, .unauthorized])
func aRefusalFromAWebPageIsNotAnEndpoint(status: HTTPResponse.Status) async throws {
    try await withServer({ walledRoute($0, path: "/app", status: status,
                                       contentType: "text/html; charset=utf-8") }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("app"))

        #expect(result.verdict == .notMCP)
        #expect(!result.authRequired)
        #expect(result.authKind == AuthKind.none)
        #expect(result.suggestion == nil)
    }
}

/// No challenge, but a JSON body: that is an MCP server that simply did not say how to sign in,
/// and the credential it wants is a header someone pastes.
@Test func aJSONRefusalWithNoChallengeIsStillAnEndpoint() async throws {
    try await withServer({ walledRoute($0, path: "/mcp", status: .unauthorized,
                                       contentType: "application/json") }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("mcp"))

        #expect(result.verdict == .mcpEndpoint)
        #expect(result.authRequired)
        #expect(result.authKind == .header)
    }
}

/// The wall is at the pasted URL; the endpoint is next door. Refusing to call the wall an endpoint
/// is what lets the suggestion be found at all.
@Test func aWalledPageStillGetsTheSiblingEndpointSuggested() async throws {
    try await withServer({ router in
        walledRoute(router, path: "/dashboard", status: .forbidden, contentType: "text/html")
        mcpRoute(router)
    }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("dashboard"))

        #expect(result.verdict == .notMCP)
        #expect(result.suggestion == base.appendingPathComponent("mcp"))
    }
}

/// Plaintext metadata is metadata anyone on the path can write, and whether a server uses OAuth at
/// all is not a question to answer from that.
@Test func aPlaintextResourceMetadataURLIsNotFollowed() async throws {
    let challenge = #"Bearer resource_metadata="http://metadata.example.com/prm""#
    try await withServer({ walledRoute($0, path: "/mcp", status: .unauthorized,
                                       contentType: "application/json", challenge: challenge) }) { base in
        let result = await MCPProbe.inspect(url: base.appendingPathComponent("mcp"))

        #expect(result.verdict == .mcpEndpoint)
        #expect(result.authRequired)
        #expect(result.authKind == .header)
        #expect(result.resourceMetadataURL == nil)
    }
}

// MARK: - Reading a challenge

@Test(arguments: [
    (#"Bearer resource_metadata="https://x.dev/.well-known/oauth-protected-resource""#,
     "https://x.dev/.well-known/oauth-protected-resource"),
    (#"Bearer resource_metadata=https://x.dev/prm, error="invalid_token""#, "https://x.dev/prm"),
    (#"Bearer realm="mcp", error="invalid_token", resource_metadata="https://x.dev/prm""#,
     "https://x.dev/prm"),
    (#"Basic realm="x", Bearer resource_metadata="https://x.dev/prm""#, "https://x.dev/prm"),
    (#"Bearer RESOURCE_METADATA="https://x.dev/prm""#, "https://x.dev/prm"),
])
func aChallengeIsReadForTheMetadataItNames(header: String, expected: String) {
    #expect(MCPProbe.resourceMetadataURL(in: header) == expected)
}

@Test(arguments: [#"Bearer realm="mcp""#, "Basic", "", #"Bearer resource_metadata=""#])
func aChallengeWithNoUsableMetadataNamesNothing(header: String) {
    let found = MCPProbe.resourceMetadataURL(in: header)
    #expect(found == nil || found?.isEmpty == true)
}

@Test func noChallengeAtAllNamesNothing() {
    #expect(MCPProbe.resourceMetadataURL(in: nil) == nil)
}

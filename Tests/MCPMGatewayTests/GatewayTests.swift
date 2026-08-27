import Testing
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MCPMCore
import NIOCore
import ServiceLifecycle
@testable import MCPMGateway

// MARK: - Test doubles

/// Counts how many times the guarded upstream route was hit, so "retried once" is measurable.
actor Hits {
    private(set) var count = 0
    func bump() { count += 1 }
}

actor FakeServerSource: GatewayServerSource {
    private var servers: [String: Server] = [:]
    private(set) var flagged: [String] = []

    func add(_ server: Server) { servers[server.id] = server }
    func server(id: String) async -> Server? { servers[id] }
    func markNeedsAuth(id: String) async { flagged.append(id) }
}

private func remote(id: String, name: String, url: String, auth: AuthKind) -> Server {
    Server(id: id, name: name, kind: .remote, url: url, auth: auth, source: "test",
           createdAt: Date(timeIntervalSince1970: 1_800_000_000))
}

private let asTokenEndpoint = "https://as.example.com/token"

private func storedToken(access: String, refresh: String? = "rt-1",
                         expiresAt: Date? = Date(timeIntervalSince1970: 4_000_000_000)) -> TokenRecord {
    TokenRecord(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, clientID: "cid-1",
                tokenEndpoint: URL(string: asTokenEndpoint)!)
}

// MARK: - The fake upstream MCP server

/// Echoes what it was sent, streams SSE, and guards one route behind a specific bearer token.
private func upstreamRouter(hits: Hits, guardedToken: String) -> Router<BasicRequestContext> {
    let router = Router()

    for method in [HTTPRequest.Method.get, .post, .delete] {
        router.on("/mcp", method: method) { request, _ in
            await hits.bump()
            var seen: [String: String] = [:]
            for field in request.headers { seen[field.name.canonicalName] = field.value }
            let body = try await request.body.collect(upTo: 4 * 1024 * 1024)
            let payload: [String: Any] = [
                "method": request.method.rawValue,
                "headers": seen,
                "body": String(buffer: body),
                "query": request.uri.query ?? "",
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var headers: HTTPFields = [.contentType: "application/json"]
            headers[.mcpSessionID] = seen["mcp-session-id"] ?? "sess-42"
            headers[.setCookie] = "sid=1; Path=/"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
    }

    // Points at /mcp, so a proxy that followed it would show up as a hit there.
    router.get("/redirect") { _, _ in
        Response(status: .found, headers: [.location: "/mcp"], body: .init())
    }

    router.get("/sse") { _, _ in
        Response(status: .ok,
                 headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                 body: ResponseBody { writer in
                     for n in 1...3 {
                         try await writer.write(ByteBuffer(string: "event: message\ndata: {\"n\":\(n)}\n\n"))
                         try await Task.sleep(for: .milliseconds(100))
                     }
                     try await writer.finish(nil)
                 })
    }

    router.post("/guarded") { request, _ in
        await hits.bump()
        guard request.headers[.authorization] == "Bearer \(guardedToken)" else {
            return Response(status: .unauthorized, headers: [.contentType: "application/json"],
                            body: .init(byteBuffer: ByteBuffer(string: #"{"error":"invalid_token"}"#)))
        }
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: #"{"ok":true}"#)))
    }

    return router
}

// MARK: - Fixture

private struct Fixture {
    var base: URL
    var upstream: URL
    var source: FakeServerSource
    var store: any TokenStore
    var http: FakeHTTPClient
    var auth: AuthManager
    var hits: Hits
    var client: URLSession

    func url(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }

    /// Sends one request to the gateway and buffers the answer.
    func send(_ path: String, method: String = "POST", headers: [String: String] = [:],
              body: Data? = nil) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        let (data, response) = try await client.data(for: request)
        return (response as! HTTPURLResponse, data)
    }
}

/// Starts the fake upstream and a gateway on ephemeral ports, runs the test, and tears both down.
private func withGateway(
    guardedToken: String = "at-2",
    maxRequestBytes: Int = 10 * 1024 * 1024,
    servers: (URL) -> [Server],
    store: (any TokenStore)? = nil,
    setUp: (any TokenStore, FakeHTTPClient) throws -> Void = { _, _ in },
    _ body: (Fixture) async throws -> Void
) async throws {
    let hits = Hits()
    try await withServer(upstreamRouter(hits: hits, guardedToken: guardedToken)) { upstreamBase in
        let store = try store ?? FileTokenStore(url: tmpDir().appendingPathComponent("tokens.json"))
        let http = FakeHTTPClient()
        try setUp(store, http)
        let auth = AuthManager(store: store, oauth: OAuthClient(http: http),
                               redirectURI: URL(string: "http://localhost:7337/oauth/callback")!)

        let source = FakeServerSource()
        for server in servers(upstreamBase) { await source.add(server) }

        // No `upstream:` — the tests exercise the hardened session the daemon actually proxies
        // through.
        let gateway = Gateway(config: GatewayConfig(port: 0, maxRequestBytes: maxRequestBytes),
                              auth: auth, servers: source)
        try await gateway.start()
        let port = await gateway.boundPort

        let fixture = Fixture(base: URL(string: "http://127.0.0.1:\(port)")!, upstream: upstreamBase,
                              source: source, store: store, http: http, auth: auth, hits: hits,
                              client: URLSession(configuration: .ephemeral))
        do { try await body(fixture) } catch { await gateway.stop(); throw error }
        await gateway.stop()
    }
}

/// The upstream's echo, decoded.
private struct Echo {
    var method: String
    var headers: [String: String]
    var body: String
    var query: String

    init(_ data: Data) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        method = object["method"] as? String ?? ""
        headers = object["headers"] as? [String: String] ?? [:]
        body = object["body"] as? String ?? ""
        query = object["query"] as? String ?? ""
    }
}

private func oauthServers(_ upstream: URL) -> [Server] {
    [remote(id: "notion", name: "Notion", url: upstream.appendingPathComponent("mcp").absoluteString,
            auth: .oauth)]
}

// MARK: - Liveness

@Test func healthzAnswersOk() async throws {
    try await withGateway(servers: oauthServers) { fixture in
        let (response, data) = try await fixture.send("/healthz", method: "GET")
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
    }
}

@Test func anEphemeralPortIsReportedBackAfterStart() async throws {
    try await withGateway(servers: oauthServers) { fixture in
        #expect(fixture.base.port ?? 0 > 0)
    }
}

@Test func aPortAlreadyInUseFailsToStartAndIsFreedAgainByStop() async throws {
    let store = FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
    let auth = AuthManager(store: store, oauth: OAuthClient(http: FakeHTTPClient()),
                           redirectURI: URL(string: "http://localhost:7337/oauth/callback")!)
    let source = FakeServerSource()

    let first = Gateway(config: GatewayConfig(port: 0), auth: auth, servers: source)
    try await first.start()
    let port = await first.boundPort

    let second = Gateway(config: GatewayConfig(port: port), auth: auth, servers: source)
    await #expect(throws: GatewayError.self) { try await second.start() }

    // The daemon's recovery path: stop the old one, and the port is available again.
    await first.stop()
    try await second.start()
    #expect(await second.boundPort == port)
    await second.stop()
}

// MARK: - Proxying

@Test func theProxyDropsTheClientsAuthorizationAndInjectsTheStoredToken() async throws {
    try await withGateway(servers: oauthServers) { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
    } _: { fixture in
        let (response, data) = try await fixture.send(
            "/s/notion/mcp",
            headers: ["Authorization": "Bearer junk-from-the-client", "Content-Type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","method":"initialize"}"#.utf8))

        #expect(response.statusCode == 200)
        let echo = try Echo(data)
        #expect(echo.method == "POST")
        #expect(echo.headers["authorization"] == "Bearer at-1")
        #expect(echo.headers["content-type"] == "application/json")
        #expect(echo.body == #"{"jsonrpc":"2.0","method":"initialize"}"#)
        // The hop-by-hop header naming us is not passed along.
        #expect(echo.headers["host"] == nil)
    }
}

@Test func theProxyForwardsTheMethodAndQueryString() async throws {
    try await withGateway(servers: oauthServers) { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
    } _: { fixture in
        let (response, data) = try await fixture.send("/s/notion/mcp?sessionId=abc&x=1", method: "DELETE")
        #expect(response.statusCode == 200)
        let echo = try Echo(data)
        #expect(echo.method == "DELETE")
        #expect(echo.query == "sessionId=abc&x=1")
    }
}

@Test func theSessionIdTravelsInBothDirections() async throws {
    try await withGateway(servers: oauthServers) { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
    } _: { fixture in
        let (response, data) = try await fixture.send("/s/notion/mcp", headers: ["Mcp-Session-Id": "s-9"])
        #expect(try Echo(data).headers["mcp-session-id"] == "s-9")
        #expect(response.value(forHTTPHeaderField: "Mcp-Session-Id") == "s-9")
    }
}

@Test func serverSentEventsArriveOneAtATimeRatherThanAllAtTheEnd() async throws {
    try await withGateway(servers: { upstream in
        [remote(id: "sse", name: "Streamer", url: upstream.appendingPathComponent("sse").absoluteString,
                auth: .oauth)]
    }, setUp: { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "sse")
    }) { fixture in
        var request = URLRequest(url: fixture.url("/s/sse/mcp"))
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let started = ContinuousClock.now
        let (bytes, response) = try await fixture.client.bytes(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")

        var arrivals: [Duration] = []
        for try await line in bytes.lines where line.hasPrefix("data:") {
            arrivals.append(ContinuousClock.now - started)
        }

        #expect(arrivals.count == 3)
        // The upstream spends 300 ms producing the three events. A buffering proxy would deliver
        // the first one only at the end.
        #expect(arrivals[0] < .milliseconds(250))
        #expect(arrivals[2] - arrivals[0] > .milliseconds(150))
    }
}

@Test func aHeaderAuthServerGetsItsStoredSecret() async throws {
    try await withGateway(servers: { upstream in
        [remote(id: "linear", name: "Linear", url: upstream.appendingPathComponent("mcp").absoluteString,
                auth: .header)]
    }, setUp: { store, _ in
        try store.setHeader(HeaderSecret(name: "X-Api-Key", value: "sekret"), for: "linear")
    }) { fixture in
        let (response, data) = try await fixture.send("/s/linear/mcp")
        #expect(response.statusCode == 200)
        let echo = try Echo(data)
        #expect(echo.headers["x-api-key"] == "sekret")
        #expect(echo.headers["authorization"] == nil)
    }
}

@Test func cookiesAreStrippedInBothDirections() async throws {
    try await withGateway(servers: oauthServers) { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
    } _: { fixture in
        let (response, data) = try await fixture.send(
            "/s/notion/mcp", headers: ["Cookie": "session=abc", "X-Custom": "kept"])

        let echo = try Echo(data)
        // An ordinary header still travels, so the absence of the cookie is the policy and not an
        // accident of how the request was built.
        #expect(echo.headers["x-custom"] == "kept")
        #expect(echo.headers["cookie"] == nil)
        #expect(response.value(forHTTPHeaderField: "Set-Cookie") == nil)
    }
}

@Test func anUpstreamRedirectIsRefusedInsteadOfFollowedWithTheToken() async throws {
    try await withGateway(servers: { upstream in
        [remote(id: "notion", name: "Notion",
                url: upstream.appendingPathComponent("redirect").absoluteString, auth: .oauth)]
    }, setUp: { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
    }) { fixture in
        let (response, data) = try await fixture.send("/s/notion/mcp", method: "GET")

        #expect(response.statusCode == 502)
        #expect(String(decoding: data, as: UTF8.self).contains("upstream_redirect"))
        // The Location target was never requested: the bearer stayed with the host we vetted.
        #expect(await fixture.hits.count == 0)
    }
}

@Test func anUnreadableStoreAnswers503AndDoesNotAskForASignIn() async throws {
    try await withGateway(servers: oauthServers, store: BrokenTokenStore()) { fixture in
        let (response, data) = try await fixture.send("/s/notion/mcp")

        #expect(response.statusCode == 503)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["error"] == "unavailable")
        #expect(json["message"] == "token store unavailable")
        // A locked keychain is not a reason to tell the user their sign-in expired.
        #expect(await fixture.source.flagged.isEmpty)
        #expect(await fixture.hits.count == 0)
    }
}

// MARK: - Refresh on 401

@Test func anUpstream401IsRetriedOnceWithARefreshedToken() async throws {
    try await withGateway(guardedToken: "at-2", servers: { upstream in
        [remote(id: "notion", name: "Notion",
                url: upstream.appendingPathComponent("guarded").absoluteString, auth: .oauth)]
    }, setUp: { store, http in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
        http.stub(asTokenEndpoint, json: #"{"access_token":"at-2","token_type":"Bearer","expires_in":3600}"#)
    }) { fixture in
        let (response, data) = try await fixture.send("/s/notion/mcp")

        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(await fixture.hits.count == 2)
        #expect(await fixture.source.flagged.isEmpty)
        #expect(try fixture.store.token(for: "notion")?.accessToken == "at-2")
    }
}

@Test func aRefreshTheServerRejectsAnswers401AndFlagsTheServerForSignIn() async throws {
    try await withGateway(guardedToken: "at-2", servers: { upstream in
        [remote(id: "notion", name: "Notion",
                url: upstream.appendingPathComponent("guarded").absoluteString, auth: .oauth)]
    }, setUp: { store, http in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
        http.stub(asTokenEndpoint, status: 400, json: #"{"error":"invalid_grant"}"#)
    }) { fixture in
        let (response, data) = try await fixture.send("/s/notion/mcp")

        #expect(response.statusCode == 401)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["error"] == "unauthorized")
        #expect(json["message"] == "Sign in to Notion in MCP Manager")
        #expect(await fixture.source.flagged == ["notion"])
        // The dead grant is gone, so the UI can offer a fresh sign-in.
        #expect(try fixture.store.token(for: "notion") == nil)
        #expect(await fixture.hits.count == 1)
    }
}

@Test func aServerWithNoStoredTokenAnswers401WithoutTouchingTheUpstream() async throws {
    try await withGateway(servers: oauthServers) { fixture in
        let (response, data) = try await fixture.send("/s/notion/mcp")
        #expect(response.statusCode == 401)
        #expect(String(decoding: data, as: UTF8.self).contains("Sign in to Notion"))
        #expect(await fixture.source.flagged == ["notion"])
        #expect(await fixture.hits.count == 0)
    }
}

// MARK: - Refusals

@Test func anUnknownServerIdIs404() async throws {
    try await withGateway(servers: oauthServers) { fixture in
        let (response, data) = try await fixture.send("/s/nope/mcp")
        #expect(response.statusCode == 404)
        #expect(String(decoding: data, as: UTF8.self).contains("unknown_server"))
    }
}

@Test func aServerWithoutAuthIsNotProxied() async throws {
    try await withGateway(servers: { upstream in
        [remote(id: "plain", name: "Plain", url: upstream.appendingPathComponent("mcp").absoluteString,
                auth: .none)]
    }) { fixture in
        // Clients are given this server's real URL, so nothing should ever ask the gateway for it.
        let (response, _) = try await fixture.send("/s/plain/mcp")
        #expect(response.statusCode == 404)
        #expect(await fixture.hits.count == 0)
    }
}

@Test func aBodyOverTheLimitIsRefused() async throws {
    try await withGateway(maxRequestBytes: 512, servers: oauthServers) { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
    } _: { fixture in
        let (response, _) = try await fixture.send("/s/notion/mcp",
                                                   body: Data(repeating: UInt8(ascii: "x"), count: 4096))
        #expect(response.statusCode == 413)
        #expect(await fixture.hits.count == 0)
    }
}

/// URLSession will not let a caller forge `Host`, so the DNS-rebinding guard is exercised where it
/// lives: on a request built by hand.
@Test(arguments: [("evil.example.com", 403), ("localhost:7337", 200), ("127.0.0.1", 200), ("", 403)])
func theHostHeaderMustNameLoopback(host: String, expected: Int) async throws {
    try await withGateway(servers: oauthServers) { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "notion")
    } _: { fixture in
        let proxy = Proxy(config: GatewayConfig(), auth: fixture.auth, servers: fixture.source,
                          upstream: URLSession(configuration: .ephemeral))
        let head = HTTPRequest(method: .post, scheme: "http",
                               authority: host.isEmpty ? nil : host, path: "/s/notion/mcp")
        let response = await proxy.forward(Request(head: head, body: .init(buffer: ByteBuffer())),
                                           id: "notion")
        #expect(response.status.code == expected)
    }
}

@Test func anUpstreamThatIsNeitherHTTPSNorLoopbackIsRefused() async throws {
    try await withGateway(servers: { _ in
        [remote(id: "plain", name: "Plain", url: "http://mcp.example.com/mcp", auth: .oauth)]
    }, setUp: { store, _ in
        try store.setToken(storedToken(access: "at-1"), for: "plain")
    }) { fixture in
        let (response, data) = try await fixture.send("/s/plain/mcp")
        #expect(response.statusCode == 502)
        #expect(String(decoding: data, as: UTF8.self).contains("insecure_upstream"))
    }
}

// MARK: - OAuth callback

@Test func theCallbackPageConfirmsAConnectedServer() async throws {
    try await withGateway(servers: oauthServers, setUp: { _, http in
        http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", json: notionPRMJSON)
        http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)
        http.stub("https://mcp.notion.com/register", json: #"{"client_id":"cid-1"}"#)
        http.stub("https://mcp.notion.com/token",
                  json: #"{"access_token":"at-1","token_type":"Bearer","expires_in":3600}"#)
    }) { fixture in
        let authorize = try await fixture.auth.startAuth(id: "notion",
                                                         serverURL: URL(string: "https://mcp.notion.com/mcp")!)
        let state = try #require(queryPairs(authorize)["state"])

        let (response, data) = try await fixture.send(
            "/oauth/callback?state=\(state.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&code=abc",
            method: "GET")

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
        #expect(String(decoding: data, as: UTF8.self).contains("signed in"))
        #expect(await fixture.auth.state(for: "notion", auth: .oauth) == .connected)
    }
}

@Test func theCallbackPageReportsASignInThatDidNotComplete() async throws {
    try await withGateway(servers: oauthServers) { fixture in
        let (response, data) = try await fixture.send("/oauth/callback?state=never-issued&code=abc",
                                                      method: "GET")
        #expect(response.statusCode == 400)
        let html = String(decoding: data, as: UTF8.self)
        #expect(html.contains("Sign-in failed"))
        #expect(await fixture.auth.state(for: "notion", auth: .oauth) == .needsAuth)
    }
}

@Test func theCallbackPageEscapesWhateverTheProviderSaid() async throws {
    try await withGateway(servers: oauthServers, setUp: { _, http in
        http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", json: notionPRMJSON)
        http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)
        http.stub("https://mcp.notion.com/register", json: #"{"client_id":"cid-1"}"#)
    }) { fixture in
        let authorize = try await fixture.auth.startAuth(id: "notion",
                                                         serverURL: URL(string: "https://mcp.notion.com/mcp")!)
        let state = try #require(queryPairs(authorize)["state"])
        var components = URLComponents(url: fixture.url("/oauth/callback"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "error_description", value: "<script>alert(1)</script>"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        let (data, response) = try await fixture.client.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        let html = String(decoding: data, as: UTF8.self)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }
}

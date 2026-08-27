import Foundation
import MCPMCore

/// What a URL turned out to be. The Add sheet asks for this before it will add anything: the URL
/// people paste is as often a docs page as an endpoint, and the difference is only visible by
/// asking the server.
public struct URLInspection: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// An MCP server answered — possibly with "sign in first", which is still an answer.
        case mcpEndpoint
        /// Something is there and it is not an MCP server.
        case notMCP
        /// Nothing answered at all: no DNS, no route, no listener.
        case unreachable
    }

    public var verdict: Verdict
    public var transport: Transport?
    public var authRequired: Bool
    /// What kind of credential to set the server up with. `.none` unless `authRequired`.
    public var authKind: AuthKind
    /// The RFC 9728 document that named the authorization server, when one was found.
    public var resourceMetadataURL: String?
    public var serverName: String?
    public var serverVersion: String?
    public var toolCount: Int?
    public var statusCode: Int?
    public var contentType: String?
    /// A URL that did verify, for a `notMCP` verdict — the `/mcp` next door, or the `mcp.` host of
    /// the same site. nil when nothing nearby answered either.
    public var suggestion: URL?
    /// One line for a human, whatever the verdict.
    public var detail: String

    public init(verdict: Verdict, transport: Transport? = nil, authRequired: Bool = false,
                authKind: AuthKind = .none, resourceMetadataURL: String? = nil,
                serverName: String? = nil, serverVersion: String? = nil, toolCount: Int? = nil,
                statusCode: Int? = nil, contentType: String? = nil, suggestion: URL? = nil,
                detail: String) {
        self.verdict = verdict
        self.transport = transport
        self.authRequired = authRequired
        self.authKind = authKind
        self.resourceMetadataURL = resourceMetadataURL
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.toolCount = toolCount
        self.statusCode = statusCode
        self.contentType = contentType
        self.suggestion = suggestion
        self.detail = detail
    }
}

extension MCPProbe {

    // MARK: - What one URL is

    /// The outcome of asking a single URL what it is. Not the verdict itself: a URL that is not an
    /// endpoint still has to be shopped around its neighbours before anything is decided.
    enum EndpointCheck {
        case endpoint(Transport, Reply)
        case notEndpoint(status: Int?, contentType: String?, location: URL?, detail: String)
        case unreachable(String)
    }

    struct Reply {
        var status: Int
        var contentType: String?
        var authRequired = false
        var wwwAuthenticate: String?
        var sessionID: String?
        var serverName: String?
        var serverVersion: String?
        var detail: String = ""
    }

    /// How much of an event stream to read before deciding it is not naming an endpoint.
    static let maxInspectedEvents = 16
    static let maxInspectedStreamBytes = 64 * 1024

    static func inspectSession(timeout: Duration) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = seconds(timeout)
        config.timeoutIntervalForResource = seconds(timeout)
        config.httpShouldSetCookies = false
        config.urlCache = nil
        // A redirect is a fact worth reporting — `https://host/sse` answering 308 is how a server
        // says its endpoint moved — and chasing it would hide that behind whatever it landed on.
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// POSTs an `initialize` and reads what comes back as a statement about what this URL is.
    static func checkHTTP(_ session: URLSession, _ url: URL) async -> EndpointCheck {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encode(initializeMessage())

        let http: HTTPURLResponse
        let object: [String: Any]?
        do {
            (http, object) = try await send(session, request, expecting: 1)
        } catch {
            return .unreachable((error as NSError).localizedDescription)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        var reply = Reply(status: http.statusCode, contentType: contentType,
                          sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id"))
        switch http.statusCode {
        case 200...299:
            guard let object else {
                return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                                    detail: "answered, but not with an MCP handshake")
            }
            var probe = ProbeResult(ok: false, durationMs: 0)
            if applyInitialize(object, to: &probe) {
                reply.serverName = probe.serverName
                reply.serverVersion = probe.serverVersion
                reply.detail = "MCP endpoint"
            } else {
                // A JSON-RPC error is still an MCP server talking — it just did not like our
                // handshake. Worth adding, and worth saying why it complained.
                reply.detail = probe.error ?? "the server refused the handshake"
            }
            return .endpoint(.http, reply)
        case 401, 403:
            reply.authRequired = true
            reply.wwwAuthenticate = http.value(forHTTPHeaderField: "WWW-Authenticate")
            reply.detail = "MCP endpoint, needs sign-in"
            // Any gated page answers 401 to a POST — a paywall, a login wall, a WAF. Only a
            // challenge that says how to authenticate, or a body in a shape an MCP server sends,
            // makes this an endpoint rather than a wall to look behind.
            guard verifies(reply) || speaksMCP(contentType) else {
                return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                                    detail: "refused the request without an MCP challenge")
            }
            return .endpoint(.http, reply)
        case 300...399:
            let location = http.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            return .notEndpoint(status: http.statusCode, contentType: contentType, location: location,
                                detail: "redirected to \(location?.absoluteString ?? "somewhere else")")
        default:
            return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                                detail: "answered HTTP \(http.statusCode)")
        }
    }

    /// Opens the URL the way a legacy HTTP+SSE client would. The `endpoint` event is the proof:
    /// an event stream that never names one is not that transport.
    static func checkSSE(_ session: URLSession, _ url: URL) async -> EndpointCheck {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            return .unreachable((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .notEndpoint(status: nil, contentType: nil, location: nil, detail: "not an HTTP response")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        var reply = Reply(status: http.statusCode, contentType: contentType)
        if http.statusCode == 401 || http.statusCode == 403 {
            reply.authRequired = true
            reply.wwwAuthenticate = http.value(forHTTPHeaderField: "WWW-Authenticate")
            reply.detail = "MCP endpoint, needs sign-in"
            // Only a server that says it serves a stream: everything else answers 401 to a GET too.
            guard contentType?.lowercased().contains("text/event-stream") == true else {
                return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                                    detail: "refused the request")
            }
            return .endpoint(.sse, reply)
        }
        guard (200...299).contains(http.statusCode),
              contentType?.lowercased().contains("text/event-stream") == true else {
            return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                                detail: "answered HTTP \(http.statusCode)")
        }
        do {
            // The `endpoint` event comes first in any server that sends one. Reading on past a
            // handful of events, or past a handful of kilobytes, is reading someone else's stream.
            var events = 0
            var read = 0
            for try await event in sseEvents(bytes.lines) {
                if event.name == "endpoint" {
                    reply.detail = "MCP endpoint (legacy SSE transport)"
                    return .endpoint(.sse, reply)
                }
                events += 1
                read += event.data.reduce(0) { $0 + $1.utf8.count }
                guard events < Self.maxInspectedEvents, read < Self.maxInspectedStreamBytes else {
                    return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                                        detail: "the stream named no message endpoint")
                }
            }
        } catch {
            return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                                detail: (error as NSError).localizedDescription)
        }
        return .notEndpoint(status: http.statusCode, contentType: contentType, location: nil,
                            detail: "the stream named no message endpoint")
    }

    // MARK: - Auth

    /// The `resource_metadata` parameter of an RFC 9728 challenge, quoted or bare.
    static func resourceMetadataURL(in header: String?) -> String? {
        guard let header,
              let marker = header.range(of: "resource_metadata=", options: .caseInsensitive) else { return nil }
        var rest = header[marker.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let end = rest.firstIndex { $0 == "," || $0 == " " } ?? rest.endIndex
        return String(rest[..<end])
    }

    /// OAuth when the resource names an authorization server we could actually talk to; a pasted
    /// header otherwise, which is the only credential left when there is no flow to run.
    static func resolveAuthKind(_ http: any HTTPClient, url: URL,
                                challenge: String?) async -> (AuthKind, String?) {
        var candidates: [URL] = []
        // The challenge names the document, and a server that names a plaintext one is naming
        // somewhere a network can rewrite: whether this resource uses OAuth at all would then be
        // whatever the wire said it was.
        if let named = resourceMetadataURL(in: challenge), let parsed = URL(string: named),
           (parsed.scheme ?? "").lowercased() == "https" || isLoopback(parsed) {
            candidates.append(parsed)
        }
        for candidate in discoveryCandidates(resource: url) where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        for candidate in candidates {
            var request = URLRequest(url: candidate)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // Through the OAuth client's session: a size cap, and no redirect chasing.
            guard let (data, response) = try? await http.send(request),
                  (200...299).contains(response.statusCode),
                  let prm = try? JSONDecoder().decode(ProtectedResourceMetadata.self, from: data),
                  resourceMatches(prm.resource, requested: url),
                  !prm.authorizationServers.isEmpty else { continue }
            return (.oauth, candidate.absoluteString)
        }
        return (.header, nil)
    }

    // MARK: - Suggestions

    /// Whether a host is an address rather than a name: `mcp.127.0.0.1` is not a place.
    static func isAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        return host.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Where an MCP endpoint would be if this URL is not one: the redirect the server named, the
    /// conventional paths at the same origin, then the `mcp.` host of the same site — which is
    /// where most vendors actually put theirs.
    static func candidateURLs(for url: URL, redirect: URL?) -> [URL] {
        var out: [URL] = []
        func add(_ candidate: URL?) {
            guard let candidate, candidate != url, !out.contains(candidate) else { return }
            out.append(candidate)
        }
        add(redirect)
        add(originURL(url, path: "/mcp"))
        add(originURL(url, path: "/sse"))
        if let host = url.host?.lowercased(), !isLoopback(url), !isAddress(host) {
            let root = IconSource.rootDomain(host)
            if host != "mcp.\(root)" {
                add(URL(string: "https://mcp.\(root)/mcp"))
                add(URL(string: "https://mcp.\(root)/sse"))
            }
        }
        return out
    }

    /// The content types an MCP server answers in. Anything else is a web page.
    static func speaksMCP(_ contentType: String?) -> Bool {
        let type = (contentType ?? "").lowercased()
        return type.contains("json") || type.contains("text/event-stream")
    }

    /// A candidate counts only if it behaves like an endpoint: a handshake, or a refusal that says
    /// how to sign in. Sites answer 401 to all sorts of things, and a bare one proves nothing.
    static func verifies(_ reply: Reply) -> Bool {
        guard reply.authRequired else { return true }
        let challenge = (reply.wwwAuthenticate ?? "").lowercased()
        return challenge.contains("bearer") || challenge.contains("resource_metadata")
    }

    static func suggestion(for url: URL, redirect: URL?, timeout: Duration) async -> URL? {
        let candidates = candidateURLs(for: url, redirect: redirect)
        guard !candidates.isEmpty else { return nil }
        let session = inspectSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        for candidate in candidates {
            let check = candidate.path.hasSuffix("/sse")
                ? await checkSSE(session, candidate)
                : await checkHTTP(session, candidate)
            if case let .endpoint(_, reply) = check, verifies(reply) { return candidate }
        }
        return nil
    }

    // MARK: - inspect

    /// Asks a URL what it is: an MCP endpoint (over which transport, behind which kind of sign-in),
    /// something else entirely, or nothing at all. Never throws.
    public static func inspect(url: URL, timeout: Duration = .seconds(12)) async -> URLInspection {
        // Same watchdog as the probe, and for the same reason: racing a cancelled
        // `Task.sleep(for:)` inside a task group aborts the process in optimized builds.
        let outcome = await withDeadline(timeout) { await inspectImpl(url: url, timeout: timeout) }
        return outcome ?? URLInspection(verdict: .unreachable, detail: "timed out")
    }

    static func inspectImpl(url: URL, timeout: Duration) async -> URLInspection {
        let session = inspectSession(timeout: timeout)
        defer { session.invalidateAndCancel() }
        let metadata = URLSessionHTTPClient(timeout: seconds(timeout))

        switch await checkHTTP(session, url) {
        case let .endpoint(transport, reply):
            return await endpointFound(session, metadata: metadata, url: url,
                                       transport: transport, reply: reply)
        case let .unreachable(why):
            return URLInspection(verdict: .unreachable, detail: why)
        case let .notEndpoint(status, contentType, location, detail):
            // The same URL over the older transport, before writing it off: a `/sse` server
            // refuses the POST that a Streamable-HTTP one answers.
            if case let .endpoint(transport, reply) = await checkSSE(session, url) {
                return await endpointFound(session, metadata: metadata, url: url,
                                           transport: transport, reply: reply)
            }
            // A third of the deadline per candidate, so a slow neighbour cannot eat the whole
            // inspection and leave the answer we already have unreported.
            let suggested = await suggestion(for: url, redirect: location, timeout: timeout / 3)
            return URLInspection(verdict: .notMCP, statusCode: status, contentType: contentType,
                                 suggestion: suggested,
                                 detail: "not an MCP endpoint — \(detail)")
        }
    }

    /// Fills in what is only worth asking for once a URL has turned out to be an endpoint: which
    /// credential it wants, and how many tools it has.
    static func endpointFound(_ session: URLSession, metadata: any HTTPClient, url: URL,
                              transport: Transport, reply: Reply) async -> URLInspection {
        var inspection = URLInspection(verdict: .mcpEndpoint, transport: transport,
                                       authRequired: reply.authRequired,
                                       serverName: reply.serverName, serverVersion: reply.serverVersion,
                                       statusCode: reply.status, contentType: reply.contentType,
                                       detail: reply.detail)
        if reply.authRequired {
            let (kind, document) = await resolveAuthKind(metadata, url: url,
                                                         challenge: reply.wwwAuthenticate)
            inspection.authKind = kind
            inspection.resourceMetadataURL = document
        } else if transport == .http, reply.serverName != nil {
            inspection.toolCount = await toolCount(session, url: url, sessionID: reply.sessionID)
        }
        return inspection
    }

    /// Best effort, and only for a server that answered `initialize`: a count is a nice thing to
    /// show and never a reason to fail an inspection.
    static func toolCount(_ session: URLSession, url: URL, sessionID: String?) async -> Int? {
        func request(_ message: [String: Any]) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            request.httpBody = encode(message)
            return request
        }
        _ = try? await send(session, request(initializedNotification), expecting: nil)
        guard let (http, object) = try? await send(session, request(toolsListMessage), expecting: 2),
              (200...299).contains(http.statusCode), let object else { return nil }
        return toolCount(from: object)
    }
}

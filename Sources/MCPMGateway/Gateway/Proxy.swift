import Foundation
import HTTPTypes
import Hummingbird
import MCPMCore
import NIOCore

/// Forwards one `/s/<id>/mcp` request to the server's real URL with a live credential attached, and
/// streams the answer back untouched. Bodies are never logged, in either direction (spec §11).
struct Proxy: Sendable {
    let config: GatewayConfig
    let auth: AuthManager
    let servers: any GatewayServerSource
    let upstream: URLSession

    /// Written by the client, meaningful only for the hop it arrived on. `Authorization` is in the
    /// list because whatever a client sent us is not what the upstream server should see —
    /// the gateway is the only thing that knows the real credential.
    static let strippedRequestHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "keep-alive", "te", "trailer",
        "upgrade", "authorization", "proxy-authorization", "proxy-authenticate", "proxy-connection",
        // A cookie jar belongs to a browser origin, not to a proxy holding someone's OAuth token,
        // and `Expect: 100-continue` is a negotiation with this hop only.
        "cookie", "expect",
        // URLSession negotiates and transparently decodes its own compression; passing the client's
        // preference through would leave us describing a body we already decoded.
        "accept-encoding",
    ]

    /// The mirror image, plus the two headers that describe an encoding URLSession already undid.
    static let strippedResponseHeaders: Set<String> = [
        "connection", "content-length", "transfer-encoding", "keep-alive", "te", "trailer",
        "upgrade", "content-encoding", "proxy-authenticate", "proxy-connection", "set-cookie",
    ]

    /// The session the gateway proxies through. Deliberately not `URLSession.shared`:
    /// - redirects are not followed, so a 3xx cannot re-send the bearer token to whatever host the
    ///   upstream names — possibly over plain HTTP;
    /// - cookies are neither stored nor sent, and nothing is cached;
    /// - the timeouts are long, because a healthy SSE stream is idle for minutes at a time and the
    ///   60-second default would tear it down.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 86400
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Big enough that a streamed answer is never held back waiting for it to fill, since any line
    /// ending flushes early — see `streamed(_:)`.
    static let chunkBytes = 16 * 1024

    func forward(_ request: Request, id: String) async -> Response {
        guard hostIsAllowed(request.head.authority) else {
            return Self.error(.forbidden, "forbidden",
                              "the gateway only answers requests addressed to localhost")
        }
        // `auth: none` remote servers are written into client configs with their real URL, so a
        // request for one arriving here is as much a mistake as an unknown id.
        guard let server = await servers.server(id: id), server.usesGateway,
              let urlString = server.url, let target = upstreamURL(urlString, query: request.uri.query)
        else {
            return Self.error(.notFound, "unknown_server", "no server \"\(id)\" is routed through the gateway")
        }
        do {
            try requireSecure(target)
        } catch {
            return Self.error(.badGateway, "insecure_upstream",
                              "refusing to send \(server.name)'s credential over \(target.scheme ?? "?")")
        }

        let body: ByteBuffer
        do {
            body = try await request.body.collect(upTo: config.maxRequestBytes)
        } catch {
            return Self.error(.contentTooLarge, "body_too_large",
                              "request bodies are limited to \(config.maxRequestBytes) bytes")
        }

        var upstreamRequest = URLRequest(url: target)
        upstreamRequest.httpMethod = request.method.rawValue
        // Everything the client sent — `Accept`, `Content-Type`, `Mcp-Session-Id`, `Last-Event-ID`
        // and anything the MCP spec adds later — travels on unchanged.
        for field in request.headers where !Self.strippedRequestHeaders.contains(field.name.canonicalName) {
            upstreamRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
        }
        if body.readableBytes > 0 { upstreamRequest.httpBody = Data(body.readableBytesView) }

        // The token we end up sending is remembered, so a 401 can say which one was refused.
        var sentToken: String?
        do {
            switch server.auth {
            case .oauth:
                let token = try await auth.bearer(for: id)
                sentToken = token
                upstreamRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .header:
                guard let secret = try await auth.header(for: id), !secret.value.isEmpty else {
                    return await needsSignIn(server)
                }
                upstreamRequest.setValue(secret.value, forHTTPHeaderField: secret.name)
            case .none:
                return Self.error(.notFound, "unknown_server",
                                  "no server \"\(id)\" is routed through the gateway")
            }
        } catch let error as AuthError {
            guard case .storeUnavailable = error else { return await needsSignIn(server) }
            return Self.unavailable()
        } catch {
            return await needsSignIn(server)
        }

        return await send(upstreamRequest, server: server, sentToken: sentToken)
    }

    /// One upstream attempt, with a single refresh-and-retry when the server rejects the token we
    /// had. Anything past that is the user's problem to solve by signing in again. `sentToken` is
    /// the bearer this attempt carried; nil means there is nothing a refresh could improve — header
    /// auth, or the retry that has already happened.
    private func send(_ request: URLRequest, server: Server, sentToken: String?) async -> Response {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await upstream.bytes(for: request)
        } catch {
            return Self.error(.badGateway, "upstream_unreachable", "\(server.name): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            return Self.error(.badGateway, "upstream_unreachable", "\(server.name) did not answer with HTTP")
        }

        // The session does not follow redirects: chasing one would re-send the credential to a host
        // that has passed none of our checks, and could be plain HTTP.
        if (300..<400).contains(http.statusCode) {
            bytes.task.cancel()
            return Self.error(.badGateway, "upstream_redirect",
                              "\(server.name) redirected the request; the gateway does not follow redirects")
        }

        if http.statusCode == 401 {
            // The body of a rejection is of no use to the client, and reading it would delay the
            // retry.
            bytes.task.cancel()
            guard let sentToken else { return await needsSignIn(server) }

            var retry = request
            do {
                let fresh = try await auth.forceRefresh(id: server.id, rejectedAccessToken: sentToken)
                retry.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            } catch let error as AuthError {
                guard case .storeUnavailable = error else { return await needsSignIn(server) }
                return Self.unavailable()
            } catch {
                return await needsSignIn(server)
            }
            return await send(retry, server: server, sentToken: nil)
        }

        return Response(status: .init(code: http.statusCode),
                        headers: responseHeaders(http),
                        body: Self.streamed(bytes))
    }

    // MARK: - Pieces

    /// A `Host` of anything but loopback means the request reached us through a name that resolves
    /// here — the DNS-rebinding path a web page would use to talk to the gateway.
    private func hostIsAllowed(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        // Strip the port, and the brackets around a literal IPv6 address.
        var name = host
        if name.hasPrefix("[") {
            name = String(name.dropFirst().prefix(while: { $0 != "]" }))
        } else if let colon = name.lastIndex(of: ":"), !name.contains("::") {
            name = String(name[name.startIndex..<colon])
        }
        return config.hostAllowlist.contains(name.lowercased())
    }

    /// The server's real URL, carrying over the query the client sent us (MCP servers use it for
    /// session and transport hints).
    private func upstreamURL(_ base: String, query: String?) -> URL? {
        guard var comps = URLComponents(string: base), comps.host != nil else { return nil }
        if let query, !query.isEmpty {
            comps.percentEncodedQuery = [comps.percentEncodedQuery, query].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: "&")
        }
        return comps.url
    }

    private func responseHeaders(_ http: HTTPURLResponse) -> HTTPFields {
        var headers = HTTPFields()
        for (rawName, rawValue) in http.allHeaderFields {
            guard let name = rawName as? String, let value = rawValue as? String,
                  !Self.strippedResponseHeaders.contains(name.lowercased()),
                  let field = HTTPField.Name(name)
            else { continue }
            headers.append(HTTPField(name: field, value: value))
        }
        return headers
    }

    /// Passes the upstream body through as it arrives. A chunk is flushed at every line ending as
    /// well as at `chunkBytes`, which is what keeps SSE and newline-delimited JSON-RPC live: an
    /// event of a few bytes reaches the client immediately instead of waiting for a full buffer.
    private static func streamed(_ bytes: URLSession.AsyncBytes) -> ResponseBody {
        return ResponseBody { writer in
            var chunk = ByteBuffer()
            chunk.reserveCapacity(chunkBytes)
            for try await byte in bytes {
                chunk.writeInteger(byte)
                if byte == UInt8(ascii: "\n") || chunk.readableBytes >= chunkBytes {
                    try await writer.write(chunk)
                    chunk.clear()
                }
            }
            if chunk.readableBytes > 0 { try await writer.write(chunk) }
            try await writer.finish(nil)
        }
    }

    /// The one answer a client can act on: it means "the human has to go and sign in".
    private func needsSignIn(_ server: Server) async -> Response {
        await servers.markNeedsAuth(id: server.id)
        return Self.error(.unauthorized, "unauthorized", "Sign in to \(server.name) in MCP Manager")
    }

    /// The store is broken, not the credential: the client should retry later, and nobody should be
    /// told to sign in again.
    static func unavailable() -> Response {
        error(.serviceUnavailable, "unavailable", "token store unavailable")
    }

    static func error(_ status: HTTPResponse.Status, _ code: String, _ message: String) -> Response {
        let json = #"{"error":"\#(code)","message":"\#(jsonEscape(message))"}"#
        return Response(status: status, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: json)))
    }
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 {
                out += String(format: "\\u%04x", c.value)
            } else {
                out.unicodeScalars.append(c)
            }
        }
    }
    return out
}

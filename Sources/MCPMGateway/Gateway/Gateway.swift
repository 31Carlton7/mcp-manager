import Foundation
import HTTPTypes
import Hummingbird
import Logging
import MCPMCore
import NIOCore
import ServiceLifecycle
import Synchronization

public struct GatewayConfig: Sendable {
    public var host: String
    /// 0 binds an ephemeral port; read `Gateway.boundPort` after `start()` for the real one.
    public var port: Int
    /// DNS-rebinding guard: a browser pointed at an attacker's domain that resolves to 127.0.0.1
    /// still sends that domain in `Host`, and is refused here (spec §11).
    public var hostAllowlist: Set<String>
    /// Request bodies are buffered before they go upstream; MCP calls are small, and a client that
    /// sends more than this is not one.
    public var maxRequestBytes: Int

    public init(host: String = "127.0.0.1", port: Int = 7337,
                hostAllowlist: Set<String> = ["localhost", "127.0.0.1"],
                maxRequestBytes: Int = 10 * 1024 * 1024) {
        self.host = host
        self.port = port
        self.hostAllowlist = hostAllowlist
        self.maxRequestBytes = maxRequestBytes
    }

    public static let callbackPath = "/oauth/callback"

    /// The redirect URI registered with every authorization server. Loopback with a fixed path, so
    /// an exact-match redirect check on the provider's side keeps working.
    public func redirectURI() -> URL {
        URL(string: "http://localhost:\(port)\(Self.callbackPath)")!
    }
}

/// Where the gateway looks up what it is proxying. The daemon backs this with its library
/// coordinator; tests back it with a dictionary.
public protocol GatewayServerSource: Sendable {
    func server(id: String) async -> Server?
    /// Called when a proxied request could not be authenticated, so the UI can show "Sign in".
    func markNeedsAuth(id: String) async
}

public enum GatewayError: Error, CustomStringConvertible {
    case startFailed(String)

    public var description: String {
        switch self {
        case let .startFailed(why): return "the gateway could not start: \(why)"
        }
    }
}

/// The loopback HTTP server every MCP client talks to: `/s/<id>/mcp` is proxied to the real server
/// with a live credential attached, `/oauth/callback` finishes sign-ins, `/healthz` proves the
/// daemon is up.
public actor Gateway {
    private let config: GatewayConfig
    private let auth: AuthManager
    private let proxy: Proxy
    private var runTask: Task<Void, Never>?
    private var group: ServiceGroup?

    /// The port actually bound. Equals `config.port` unless that was 0.
    public private(set) var boundPort: Int = 0

    public init(config: GatewayConfig, auth: AuthManager, servers: any GatewayServerSource,
                upstream: URLSession = .shared) {
        self.config = config
        self.auth = auth
        self.proxy = Proxy(config: config, auth: auth, servers: servers, upstream: upstream)
    }

    /// Binds the socket and starts serving. Returns once the port is known, so callers can write
    /// gateway URLs into client configs immediately; throws if the port is taken.
    public func start() async throws {
        guard runTask == nil else { return }

        // Hummingbird's own logging is startup chatter; the daemon reports the gateway's state
        // itself, so only real faults come through here.
        var logger = Logger(label: "mcpm.gateway")
        logger.logLevel = .warning

        let (stream, ports) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: makeRouter(),
            configuration: .init(address: .hostname(config.host, port: config.port),
                                 serverName: "mcpm-gateway"),
            onServerRunning: { channel in ports.yield(channel.localAddress?.port ?? 0) },
            logger: logger)

        // The service group owns the shutdown handshake. No signals: `mcpmd` handles those and
        // calls `stop()` itself.
        var configuration = ServiceGroupConfiguration(services: [app], logger: logger)
        // A client parked on an SSE stream must not be able to hold a shutdown open.
        configuration.maximumGracefulShutdownDuration = .seconds(2)
        let group = ServiceGroup(configuration: configuration)
        self.group = group

        // A bind failure never reaches `onServerRunning`; it comes back here instead, and finishing
        // the stream is what unblocks the wait below.
        let failure = Mutex<String?>(nil)
        runTask = Task {
            do { try await group.run() }
            catch { failure.withLock { $0 = "\(error)" } }
            ports.finish()
        }

        var iterator = stream.makeAsyncIterator()
        guard let port = await iterator.next() else {
            runTask = nil
            self.group = nil
            throw GatewayError.startFailed(failure.withLock { $0 } ?? "the server stopped immediately")
        }
        boundPort = port
    }

    public func stop() async {
        await group?.triggerGracefulShutdown()
        await runTask?.value
        group = nil
        runTask = nil
        boundPort = 0
    }

    // MARK: - Routes

    private func makeRouter() -> Router<BasicRequestContext> {
        let router = Router()
        let proxy = self.proxy
        let auth = self.auth

        router.get("/healthz") { _, _ in
            Response(status: .ok, headers: [.contentType: "application/json"],
                     body: .init(byteBuffer: ByteBuffer(string: #"{"ok":true}"#)))
        }

        router.get(RouterPath(GatewayConfig.callbackPath)) { request, _ in
            await Self.callback(request, auth: auth)
        }

        for method in [HTTPRequest.Method.get, .post, .delete] {
            router.on("/s/{id}/mcp", method: method) { request, context in
                await proxy.forward(request, id: try context.parameters.require("id"))
            }
        }
        return router
    }

    /// The browser lands here after the provider redirect. Whatever happens, the answer is a page a
    /// human reads — the app learns the outcome from the pushed status, not from this response.
    private static func callback(_ request: Request, auth: AuthManager) async -> Response {
        var query: [String: String] = [:]
        for (name, value) in request.uri.queryParameters { query[String(name)] = String(value) }

        do {
            let id = try await auth.handleCallback(query: query)
            return page(.ok, title: "Connected", detail: "\(id) is signed in — you can close this tab.")
        } catch {
            return page(.badRequest, title: "Sign-in failed", detail: "\(error)")
        }
    }

    private static func page(_ status: HTTPResponse.Status, title: String, detail: String) -> Response {
        // `detail` can carry text the provider chose, so it is escaped rather than interpolated.
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>MCP Manager</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;margin:20vh auto;max-width:26rem;\
        text-align:center;color:#111}p{color:#666}@media(prefers-color-scheme:dark){\
        body{background:#111;color:#eee}p{color:#999}}</style></head>
        <body><h1>\(escapeHTML(title))</h1><p>\(escapeHTML(detail))</p></body></html>
        """
        return Response(status: status, headers: [.contentType: "text/html; charset=utf-8"],
                        body: .init(byteBuffer: ByteBuffer(string: html)))
    }
}

func escapeHTML(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(c)
        }
    }
    return out
}

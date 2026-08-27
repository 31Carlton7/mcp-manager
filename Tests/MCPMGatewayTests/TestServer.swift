import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import ServiceLifecycle

/// A Hummingbird app on an ephemeral loopback port, so the tests exercise real sockets without
/// reaching the network. Use `withServer` unless a test needs to stop the server mid-body.
actor TestHTTPServer {
    private var runTask: Task<Void, Never>?
    private var group: ServiceGroup?
    private(set) var port = 0

    struct DidNotStart: Error {}

    func start(_ router: Router<BasicRequestContext>) async throws {
        var logger = Logger(label: "test-upstream")
        logger.logLevel = .warning

        let (stream, ports) = AsyncStream<Int>.makeStream()
        let app = Application(router: router,
                              configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                              onServerRunning: { ports.yield($0.localAddress?.port ?? 0) },
                              logger: logger)
        var configuration = ServiceGroupConfiguration(services: [app], logger: logger)
        configuration.maximumGracefulShutdownDuration = .seconds(2)
        let group = ServiceGroup(configuration: configuration)
        self.group = group
        runTask = Task {
            try? await group.run()
            ports.finish()
        }
        var iterator = stream.makeAsyncIterator()
        guard let bound = await iterator.next() else { throw DidNotStart() }
        port = bound
    }

    func stop() async {
        await group?.triggerGracefulShutdown()
        await runTask?.value
        group = nil
        runTask = nil
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

/// Serves `router` on an ephemeral loopback port for the duration of `body`, handing it the base
/// URL. The server is torn down on the way out, including when `body` throws — a leaked one holds
/// its port and its Hummingbird threads for the rest of the run.
func withServer<T>(_ router: sending Router<BasicRequestContext>,
                   _ body: (URL) async throws -> T) async throws -> T {
    let server = TestHTTPServer()
    try await server.start(router)
    let base = await server.baseURL
    do {
        let value = try await body(base)
        await server.stop()
        return value
    } catch {
        await server.stop()
        throw error
    }
}

/// The same, for tests that describe their fake by configuring a fresh router.
func withServer<T>(_ configure: (Router<BasicRequestContext>) -> Void,
                   _ body: (URL) async throws -> T) async throws -> T {
    let router = Router()
    configure(router)
    return try await withServer(router, body)
}

// MARK: - A fake MCP server

extension HTTPField.Name {
    static let mcpSessionID = HTTPField.Name("Mcp-Session-Id")!
    static let wwwAuthenticate = HTTPField.Name("WWW-Authenticate")!
}

/// The `result` an MCP server would send for one JSON-RPC method, or nil for a method the fakes do
/// not implement. `toolNames` is per-fake so a test can assert on a count it chose.
func mcpResult(for method: String?, params: [String: Any], toolNames: [String]) -> [String: Any]? {
    switch method {
    case "initialize":
        return [
            // Echoed, so a test can tell the server saw the version the probe offered.
            "protocolVersion": params["protocolVersion"] as? String ?? "?",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "fake-remote", "version": "2.3"],
        ]
    case "tools/list":
        return ["tools": toolNames.map { ["name": $0] }]
    default:
        return nil
    }
}

/// The JSON-RPC answer to one request body, or nil for a notification — which carries no id and
/// gets no answer, exactly as in the MCP spec.
func mcpResponse(to buffer: ByteBuffer, toolNames: [String]) -> (message: [String: Any]?, data: Data?) {
    let message = (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))) as? [String: Any]
    guard let id = message?["id"] else { return (message, nil) }
    let payload: [String: Any] = [
        "jsonrpc": "2.0", "id": id,
        "result": mcpResult(for: message?["method"] as? String,
                            params: message?["params"] as? [String: Any] ?? [:],
                            toolNames: toolNames) as Any,
    ]
    return (message, try? JSONSerialization.data(withJSONObject: payload))
}

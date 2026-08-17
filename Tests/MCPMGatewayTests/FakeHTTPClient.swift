import Foundation
@testable import MCPMGateway

/// An `HTTPClient` backed by a URL→response table. Anything unstubbed answers 404, which is what
/// discovery walking a candidate list actually meets in the wild. Records every request so tests
/// can assert on bodies and ordering. No sockets are opened.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    private let lock = NSLock()
    private var stubs: [String: [Stub]] = [:]
    private var recorded: [URLRequest] = []

    init() {}

    /// Stubs one URL. Calling it repeatedly for the same URL queues responses: each request
    /// consumes the next, and the last one repeats.
    func stub(_ url: String, status: Int = 200, json: String) {
        lock.lock()
        defer { lock.unlock() }
        stubs[url, default: []].append(Stub(status: status, body: Data(json.utf8)))
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var requestedURLs: [String] {
        requests.compactMap { $0.url?.absoluteString }
    }

    func request(to url: String) -> URLRequest? {
        requests.last { $0.url?.absoluteString == url }
    }

    func requestCount(to url: String) -> Int {
        requests.filter { $0.url?.absoluteString == url }.count
    }

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let stub = lock.withLock {
            recorded.append(req)
            let key = req.url?.absoluteString ?? ""
            guard var queued = stubs[key], !queued.isEmpty else {
                return Stub(status: 404, body: Data("not found".utf8), headers: [:])
            }
            let next = queued.removeFirst()
            if !queued.isEmpty { stubs[key] = queued }
            return next
        }

        let response = HTTPURLResponse(url: req.url!, statusCode: stub.status,
                                       httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        return (stub.body, response)
    }
}

// MARK: - Fixtures

let notionASJSON = """
{"issuer":"https://mcp.notion.com",
 "authorization_endpoint":"https://mcp.notion.com/authorize",
 "token_endpoint":"https://mcp.notion.com/token",
 "registration_endpoint":"https://mcp.notion.com/register",
 "revocation_endpoint":"https://mcp.notion.com/token",
 "scopes_supported":["default"],
 "response_types_supported":["code"],
 "grant_types_supported":["authorization_code","refresh_token"],
 "code_challenge_methods_supported":["S256"],
 "token_endpoint_auth_methods_supported":["client_secret_post","client_secret_basic","none"]}
"""

let notionPRMJSON = """
{"resource":"https://mcp.notion.com/mcp",
 "authorization_servers":["https://mcp.notion.com"],
 "scopes_supported":["default"],
 "bearer_methods_supported":["header"]}
"""

/// Splits an `application/x-www-form-urlencoded` body into pairs.
func formPairs(_ data: Data?) -> [String: String] {
    guard let data, let s = String(data: data, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let value = parts.count > 1 ? (String(parts[1]).replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? String(parts[1])) : ""
        out[key] = value
    }
    return out
}

func queryPairs(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
}

func jsonObject(_ data: Data?) -> [String: Any] {
    guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}

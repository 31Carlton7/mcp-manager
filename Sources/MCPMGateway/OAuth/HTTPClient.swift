import Foundation

/// The one-shot HTTP the OAuth flows need, behind a protocol so tests can answer without a socket.
/// Streaming (the proxy, SSE) does not go through here — it uses `URLSession.bytes(for:)` directly.
public protocol HTTPClient: Sendable {
    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPClientError: Error, CustomStringConvertible {
    case notHTTP(URL?)

    public var description: String {
        switch self {
        case let .notHTTP(url): return "not an HTTP response from \(url?.absoluteString ?? "-")"
        }
    }
}

/// Hands the 3xx back to the caller instead of chasing it. A redirect from a metadata or token
/// endpoint would otherwise re-send the request — and any credential on it — to whatever host the
/// server named in `Location`, after our HTTPS and issuer checks have already run.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    /// OAuth metadata and token responses are small. A larger body is a misrouted request or an
    /// attempt to make us buffer something big, and never a document we want to parse.
    static let maxResponseBytes = 1024 * 1024

    private let session: URLSession

    /// The default: a private session with no cache and no redirect following. Nothing here shares
    /// state with `URLSession.shared`, where token responses have no business.
    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Injection point for callers that own their session.
    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.notHTTP(req.url) }
        try Self.checkSize(data, from: req.url)
        return (data, http)
    }

    static func checkSize(_ data: Data, from url: URL?) throws {
        guard data.count <= maxResponseBytes else {
            throw OAuthError.invalidResponse(
                "\(url?.absoluteString ?? "response") returned \(data.count) bytes, over the \(maxResponseBytes) limit")
        }
    }
}

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

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A session that never writes to the shared URL cache — token responses have no business in it.
    public static func ephemeral(timeout: TimeInterval = 15) -> URLSessionHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionHTTPClient(session: URLSession(configuration: config))
    }

    public func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.notHTTP(req.url) }
        return (data, http)
    }
}

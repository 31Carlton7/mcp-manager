import Testing
import Foundation
@testable import MCPMGateway

/// The redirect refusal cannot be exercised through `FakeHTTPClient` — it lives in URLSession's
/// delegate callback, below the `HTTPClient` protocol. Driving it end to end would need a real
/// listening socket, which belongs with the Hummingbird-backed gateway tests in Task 4; here we
/// invoke the delegate the way URLSession does.
@Test func theSessionDelegateRefusesToFollowRedirects() async throws {
    let delegate = NoRedirectDelegate()
    let response = HTTPURLResponse(url: URL(string: "https://as.example/token")!, statusCode: 302,
                                   httpVersion: "HTTP/1.1", headerFields: ["Location": "https://evil.example/token"])!
    let proposed = URLRequest(url: URL(string: "https://evil.example/token")!)
    // Never resumed, so nothing leaves the machine.
    let task = URLSession.shared.dataTask(with: URLRequest(url: URL(string: "https://as.example/token")!))

    let followed: URLRequest? = await withCheckedContinuation { continuation in
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                            newRequest: proposed) { continuation.resume(returning: $0) }
    }
    // nil means "hand me the 3xx instead of chasing it" — a token or metadata response must not be
    // silently re-requested against a Location the server chose.
    #expect(followed == nil)
}

@Test func oversizedResponsesAreRejected() throws {
    let url = URL(string: "https://as.example/token")!
    #expect(throws: Never.self) {
        try URLSessionHTTPClient.checkSize(Data(count: 1024), from: url)
    }
    #expect(throws: OAuthError.self) {
        try URLSessionHTTPClient.checkSize(Data(count: URLSessionHTTPClient.maxResponseBytes + 1), from: url)
    }
}

import Foundation
import MCPMCore

/// What the daemon found when it asked a URL what it is, on its way to the app. Mirrors the
/// gateway's `URLInspection` — the daemon converts — so the app and the control protocol stay
/// independent of the gateway module, the same way `TestResult` mirrors `ProbeResult`.
public struct URLInspection: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case mcpEndpoint, notMCP, unreachable
    }

    /// A `Verdict` raw value. Kept a `String` so a verdict added later doesn't break an older
    /// app's decode; `parsedVerdict` is the typed reading of it.
    public var verdict: String
    public var transport: Transport?
    public var authRequired: Bool
    public var authKind: AuthKind
    public var resourceMetadataURL: String?
    public var serverName: String?
    public var serverVersion: String?
    public var toolCount: Int?
    public var statusCode: Int?
    public var contentType: String?
    /// A URL that did answer, when the one asked about did not.
    public var suggestion: String?
    public var detail: String

    public var parsedVerdict: Verdict? { Verdict(rawValue: verdict) }

    public init(verdict: String, transport: Transport? = nil, authRequired: Bool = false,
                authKind: AuthKind = .none, resourceMetadataURL: String? = nil,
                serverName: String? = nil, serverVersion: String? = nil, toolCount: Int? = nil,
                statusCode: Int? = nil, contentType: String? = nil, suggestion: String? = nil,
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

public struct InspectURLParams: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}

import Foundation

/// Everything needed to use — and later refresh or revoke — one server's OAuth token, without
/// re-running discovery. The endpoints travel with the record because the authorization server's
/// metadata may be unreachable at the moment a refresh is due.
public struct TokenRecord: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String
    public var scope: String?
    public var clientID: String
    public var clientSecret: String?
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL?
    /// RFC 8707 resource indicator the token was issued for.
    public var resource: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                tokenType: String = "Bearer", scope: String? = nil, clientID: String,
                clientSecret: String? = nil, tokenEndpoint: URL, revocationEndpoint: URL? = nil,
                resource: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        // The store encodes dates as whole-second ISO 8601, so round here too — otherwise an
        // in-memory record never equals the one that comes back off disk.
        self.expiresAt = expiresAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.tokenType = tokenType
        self.scope = scope
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.resource = resource
    }

    /// True when the token has no expiry, or expires later than `now + slack`.
    public func isFresh(now: Date, slack: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(slack)
    }
}

/// A static header credential for `auth: header` servers ("X-Api-Key: …").
public struct HeaderSecret: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The client identity we registered (or the user pasted) with one authorization server.
public struct ClientRegistration: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?
    public var issuer: URL
    public init(clientID: String, clientSecret: String? = nil, issuer: URL) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.issuer = issuer
    }
}

/// Secret storage for the gateway, keyed by server id. Keychain in production, a 0600 file in
/// development and tests.
public protocol TokenStore: Sendable {
    func token(for id: String) throws -> TokenRecord?
    func setToken(_ token: TokenRecord, for id: String) throws
    func removeToken(for id: String) throws

    func header(for id: String) throws -> HeaderSecret?
    func setHeader(_ header: HeaderSecret, for id: String) throws
    func removeHeader(for id: String) throws

    func clientRegistration(for id: String) throws -> ClientRegistration?
    func setClientRegistration(_ registration: ClientRegistration, for id: String) throws
}

enum TokenCoding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

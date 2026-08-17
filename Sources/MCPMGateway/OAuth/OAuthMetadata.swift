import Foundation

/// RFC 9728 protected-resource metadata: what an MCP server publishes about who authorizes it.
public struct ProtectedResourceMetadata: Codable, Equatable, Sendable {
    public var resource: String
    public var authorizationServers: [String]
    public var scopesSupported: [String]?

    public init(resource: String, authorizationServers: [String], scopesSupported: [String]? = nil) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
    }

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

/// RFC 8414 authorization-server metadata (a superset of the OpenID discovery document, for the
/// fields we use).
public struct AuthorizationServerMetadata: Codable, Equatable, Sendable {
    public var issuer: URL
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var revocationEndpoint: URL?
    public var scopesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?
    public var tokenEndpointAuthMethodsSupported: [String]?

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL,
                registrationEndpoint: URL? = nil, revocationEndpoint: URL? = nil,
                scopesSupported: [String]? = nil, codeChallengeMethodsSupported: [String]? = nil,
                tokenEndpointAuthMethodsSupported: [String]? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.scopesSupported = scopesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.tokenEndpointAuthMethodsSupported = tokenEndpointAuthMethodsSupported
    }

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }

    /// What to assume when a server publishes no metadata at all: the conventional endpoint names
    /// at the issuer's origin. Several MCP servers in the wild only implement these.
    public static func fallback(issuer: URL) -> AuthorizationServerMetadata {
        AuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: originURL(issuer, path: "/authorize"),
            tokenEndpoint: originURL(issuer, path: "/token"),
            registrationEndpoint: originURL(issuer, path: "/register"))
    }

    /// Whether the server advertises PKCE S256. Absent metadata means "assume yes" — S256 is
    /// mandatory for MCP clients, and a server that ignores the parameter still works.
    public var supportsS256: Bool {
        codeChallengeMethodsSupported?.contains("S256") ?? true
    }
}

// MARK: - Discovery URL rules

/// RFC 9728 §3: the resource's path is inserted *after* the well-known segment, with a bare
/// well-known URL as the fallback.
public func discoveryCandidates(resource: URL) -> [URL] {
    let path = discoveryPath(of: resource)
    var out: [URL] = []
    if !path.isEmpty {
        out.append(originURL(resource, path: "/.well-known/oauth-protected-resource" + path))
    }
    out.append(originURL(resource, path: "/.well-known/oauth-protected-resource"))
    return out
}

/// RFC 8414 §3 plus the OpenID Connect discovery layout: for an issuer with a path both the
/// inserted and the appended forms are legal, and issuers disagree about which they serve.
public func asCandidates(issuer: URL) -> [URL] {
    let path = discoveryPath(of: issuer)
    guard !path.isEmpty else {
        return [
            originURL(issuer, path: "/.well-known/oauth-authorization-server"),
            originURL(issuer, path: "/.well-known/openid-configuration"),
        ]
    }
    return [
        originURL(issuer, path: "/.well-known/oauth-authorization-server" + path),
        originURL(issuer, path: "/.well-known/openid-configuration" + path),
        originURL(issuer, path: path + "/.well-known/openid-configuration"),
    ]
}

/// The URL's path with any trailing slash removed, so `https://h/mcp/` and `https://h/mcp` produce
/// the same candidates and `https://h/` produces none.
func discoveryPath(of url: URL) -> String {
    var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.path
    while path.hasSuffix("/") { path.removeLast() }
    return path
}

/// Rebuilds `url` at the same scheme/host/port with a new path, dropping query and fragment.
func originURL(_ url: URL, path: String) -> URL {
    var comps = URLComponents()
    comps.scheme = url.scheme
    comps.host = url.host
    comps.port = url.port
    comps.path = path
    return comps.url ?? url
}

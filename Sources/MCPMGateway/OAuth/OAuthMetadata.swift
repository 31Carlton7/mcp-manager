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

    /// Every endpoint we might send a request to, for transport checks.
    public var endpoints: [URL] {
        [authorizationEndpoint, tokenEndpoint, registrationEndpoint, revocationEndpoint].compactMap { $0 }
    }
}

// MARK: - Identity and transport checks

/// Scheme, host, port and path, normalized for comparison: lowercased scheme and host, default
/// ports and a trailing slash removed, query and fragment dropped.
func normalizedIdentity(_ url: URL) -> String {
    let scheme = (url.scheme ?? "").lowercased()
    let host = (url.host ?? "").lowercased()
    var port = ""
    if let p = url.port, !((scheme == "https" && p == 443) || (scheme == "http" && p == 80)) {
        port = ":\(p)"
    }
    return "\(scheme)://\(host)\(port)\(discoveryPath(of: url))"
}

/// RFC 8414 §3.3: the `issuer` in the document must be the issuer whose well-known URL we asked.
/// Anything else is an authorization-server mix-up.
func issuerMatches(_ documentIssuer: URL, expected: URL) -> Bool {
    normalizedIdentity(documentIssuer) == normalizedIdentity(expected)
}

/// RFC 9728 §3.3, loosened by one step that servers actually rely on: metadata may name a prefix of
/// the resource — most commonly the bare origin covering every path under it.
func resourceMatches(_ advertised: String, requested: URL) -> Bool {
    guard let advertisedURL = URL(string: advertised), advertisedURL.host != nil else { return false }
    let a = normalizedIdentity(advertisedURL)
    let r = normalizedIdentity(requested)
    return r == a || r.hasPrefix(a + "/")
}

/// Loopback is the one place plain HTTP is allowed: local MCP servers under development, and our
/// own `http://localhost:7337/oauth/callback` redirect.
func isLoopback(_ url: URL) -> Bool {
    switch (url.host ?? "").lowercased() {
    case "localhost", "127.0.0.1", "::1", "[::1]": return true
    default: return false
    }
}

/// Tokens must never cross a plaintext hop. Throws `OAuthError.insecureEndpoint` for anything that
/// is not HTTPS or loopback.
func requireSecure(_ url: URL) throws {
    guard (url.scheme ?? "").lowercased() != "https" else { return }
    guard isLoopback(url) else { throw OAuthError.insecureEndpoint(url) }
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

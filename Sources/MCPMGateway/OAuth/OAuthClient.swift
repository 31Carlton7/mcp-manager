import Foundation

public enum OAuthError: Error, Equatable, CustomStringConvertible {
    /// The authorization server has no registration endpoint, or refused to register us. The user
    /// has to paste a client id instead.
    case registrationUnsupported
    /// The refresh token (or authorization code) is dead — sign in again.
    case invalidGrant
    case noRefreshToken
    /// An OAuth endpoint that is neither HTTPS nor loopback — we will not send a token over it.
    case insecureEndpoint(URL)
    /// An `error` / `error_description` pair from an OAuth endpoint.
    case server(status: Int, code: String?, description: String?)
    /// The authorization server redirected back with an `error` parameter.
    case providerError(String)
    case invalidResponse(String)

    public var description: String {
        switch self {
        case .registrationUnsupported:
            return "the server does not support dynamic client registration"
        case .invalidGrant:
            return "the stored grant is no longer valid"
        case .noRefreshToken:
            return "no refresh token was issued"
        case let .insecureEndpoint(url):
            return "refusing to use \(url.absoluteString) — OAuth endpoints must use HTTPS"
        case let .server(status, code, description):
            return "OAuth error \(status)" + [code, description].compactMap { $0 }
                .reduce("") { $0 + ": " + $1 }
        case let .providerError(message):
            return message
        case let .invalidResponse(what):
            return "unexpected response: \(what)"
        }
    }
}

/// A token endpoint's success response (RFC 6749 §5.1).
public struct TokenResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Double?
    public var refreshToken: String?
    public var scope: String?

    public init(accessToken: String, tokenType: String = "Bearer", expiresIn: Double? = nil,
                refreshToken: String? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        expiresIn = try c.decodeIfPresent(Double.self, forKey: .expiresIn)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
    }
}

/// The OAuth half of the gateway: metadata discovery, dynamic client registration, and the
/// authorization-code + refresh + revoke calls. Stateless — the caller owns the PKCE values and
/// the stored `TokenRecord`.
public struct OAuthClient: Sendable {
    public static let clientName = "MCP Manager"

    private let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    public struct Discovery: Equatable, Sendable {
        public var prm: ProtectedResourceMetadata?
        public var asMeta: AuthorizationServerMetadata
        /// Scopes to ask for, preferring what the resource asks for over what the server offers.
        public var scopes: [String]?

        public init(prm: ProtectedResourceMetadata?, asMeta: AuthorizationServerMetadata, scopes: [String]?) {
            self.prm = prm
            self.asMeta = asMeta
            self.scopes = scopes
        }

        /// The space-delimited `scope` parameter, or nil when there is nothing to ask for.
        public var scopeParameter: String? {
            guard let scopes, !scopes.isEmpty else { return nil }
            return scopes.joined(separator: " ")
        }
    }

    // MARK: - Discovery

    /// Walks the RFC 9728 → RFC 8414 chain. Every step is optional: a server that publishes
    /// nothing still resolves, to the conventional endpoints at its origin. Documents that do not
    /// identify themselves as the resource or issuer we asked for are skipped rather than trusted.
    public func discover(resource: URL) async throws -> Discovery {
        var broken: OAuthError?

        var prm: ProtectedResourceMetadata?
        for candidate in discoveryCandidates(resource: resource) {
            guard let found: ProtectedResourceMetadata = try await fetchJSON(candidate, broken: &broken),
                  resourceMatches(found.resource, requested: resource) else { continue }
            prm = found
            break
        }

        let issuer: URL
        if let advertised = prm?.authorizationServers.first {
            guard let url = URL(string: advertised), url.host != nil else {
                throw OAuthError.invalidResponse("authorization_servers entry \"\(advertised)\" is not a URL")
            }
            issuer = url
        } else {
            issuer = originURL(resource, path: "")
        }
        try requireSecure(issuer)

        var asMeta: AuthorizationServerMetadata?
        for candidate in asCandidates(issuer: issuer) {
            guard let found: AuthorizationServerMetadata = try await fetchJSON(candidate, broken: &broken),
                  issuerMatches(found.issuer, expected: issuer) else { continue }
            asMeta = found
            break
        }

        // Guessing the conventional endpoints is only safe when the server genuinely publishes no
        // metadata. If one of its well-known URLs failed, say so instead of inventing endpoints.
        if asMeta == nil, let broken { throw broken }

        let meta = asMeta ?? .fallback(issuer: issuer)
        for endpoint in meta.endpoints { try requireSecure(endpoint) }
        return Discovery(prm: prm, asMeta: meta, scopes: prm?.scopesSupported ?? meta.scopesSupported)
    }

    /// A discovery GET. Transport failures propagate — a dead network must not look like "this
    /// server publishes no metadata". "Not here" (404/410) and documents that do not parse return
    /// nil so the next candidate is tried; a server-side fault is remembered in `broken` so the
    /// caller can refuse to fall back on a guess.
    private func fetchJSON<T: Decodable>(_ url: URL, broken: inout OAuthError?) async throws -> T? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await http.send(req)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode != 404 && response.statusCode != 410 {
                broken = broken ?? error(status: response.statusCode, body: data)
            }
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Dynamic client registration (RFC 7591)

    public func register(asMeta: AuthorizationServerMetadata, redirectURI: URL) async throws -> ClientRegistration {
        guard let endpoint = asMeta.registrationEndpoint else { throw OAuthError.registrationUnsupported }
        try requireSecure(endpoint)

        let body: [String: Any] = [
            "client_name": Self.clientName,
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await http.send(req)
        // A refusal is a fact about the server, not a transport failure: the app falls back to
        // asking the user for a client id.
        if (400..<500).contains(response.statusCode) { throw OAuthError.registrationUnsupported }
        guard (200..<300).contains(response.statusCode) else {
            throw error(status: response.statusCode, body: data)
        }

        struct Registered: Decodable {
            let clientID: String
            let clientSecret: String?
            enum CodingKeys: String, CodingKey {
                case clientID = "client_id"
                case clientSecret = "client_secret"
            }
        }
        guard let registered = try? JSONDecoder().decode(Registered.self, from: data) else {
            throw OAuthError.invalidResponse("registration response had no client_id")
        }
        return ClientRegistration(clientID: registered.clientID, clientSecret: registered.clientSecret,
                                  issuer: asMeta.issuer)
    }

    // MARK: - Authorization

    public func authorizeURL(asMeta: AuthorizationServerMetadata, clientID: String, redirectURI: URL,
                             scope: String?, state: String, challenge: String, resource: String?) -> URL {
        var comps = URLComponents(url: asMeta.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        if let resource, !resource.isEmpty { items.append(URLQueryItem(name: "resource", value: resource)) }
        comps?.queryItems = items
        return comps?.url ?? asMeta.authorizationEndpoint
    }

    // MARK: - Token endpoint

    public func exchange(asMeta: AuthorizationServerMetadata, code: String, verifier: String,
                         clientID: String, clientSecret: String?, redirectURI: URL,
                         resource: String?) async throws -> TokenResponse {
        var form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("client_id", clientID),
            ("redirect_uri", redirectURI.absoluteString),
        ]
        let basic = basicCredential(clientID: clientID, clientSecret: clientSecret,
                                    methods: asMeta.tokenEndpointAuthMethodsSupported)
        if basic == nil, let clientSecret { form.append(("client_secret", clientSecret)) }
        if let resource { form.append(("resource", resource)) }
        return try await postForm(asMeta.tokenEndpoint, form, basic: basic)
    }

    /// `authMethods` is the authorization server's `token_endpoint_auth_methods_supported`, when the
    /// caller still has the metadata: a stored `TokenRecord` does not carry it, and the default
    /// (secret in the body) is what nearly every server accepts.
    public func refresh(_ record: TokenRecord, authMethods: [String]? = nil) async throws -> TokenResponse {
        guard let refreshToken = record.refreshToken else { throw OAuthError.noRefreshToken }
        var form: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", record.clientID),
        ]
        let basic = basicCredential(clientID: record.clientID, clientSecret: record.clientSecret,
                                    methods: authMethods)
        if basic == nil, let secret = record.clientSecret { form.append(("client_secret", secret)) }
        if let resource = record.resource { form.append(("resource", resource)) }
        return try await postForm(record.tokenEndpoint, form, basic: basic)
    }

    /// RFC 6749 §2.3.1 HTTP Basic, used only when the server offers `client_secret_basic` and not
    /// `client_secret_post`. Both halves are form-urlencoded before base64.
    private func basicCredential(clientID: String, clientSecret: String?, methods: [String]?) -> String? {
        guard let clientSecret, let methods,
              methods.contains("client_secret_basic"), !methods.contains("client_secret_post")
        else { return nil }
        let pair = "\(formEscape(clientID)):\(formEscape(clientSecret))"
        return "Basic " + Data(pair.utf8).base64EncodedString()
    }

    /// Best effort: a failed revocation must not stop a sign-out, and plenty of servers do not
    /// implement the endpoint they advertise.
    public func revoke(_ record: TokenRecord) async {
        guard let endpoint = record.revocationEndpoint, (try? requireSecure(endpoint)) != nil else { return }
        let hint = record.refreshToken != nil ? "refresh_token" : "access_token"
        var form: [(String, String)] = [
            ("token", record.refreshToken ?? record.accessToken),
            ("token_type_hint", hint),
            ("client_id", record.clientID),
        ]
        if let secret = record.clientSecret { form.append(("client_secret", secret)) }
        _ = try? await http.send(formRequest(endpoint, form))
    }

    private func postForm(_ url: URL, _ form: [(String, String)],
                          basic: String? = nil) async throws -> TokenResponse {
        try requireSecure(url)
        let (data, response) = try await http.send(formRequest(url, form, basic: basic))
        // Anything outside 2xx — including a 3xx, which the HTTP client refuses to follow — is a
        // failure, not something to re-request somewhere else.
        guard (200..<300).contains(response.statusCode) else {
            throw error(status: response.statusCode, body: data)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.invalidResponse("token response had no access_token")
        }
    }

    private func formRequest(_ url: URL, _ form: [(String, String)], basic: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let basic { req.setValue(basic, forHTTPHeaderField: "Authorization") }
        req.httpBody = Data(form.map { "\(formEscape($0.0))=\(formEscape($0.1))" }
            .joined(separator: "&").utf8)
        return req
    }

    private func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Maps an OAuth error body onto our cases. `invalid_grant` is the one callers branch on: it
    /// means the stored refresh token is dead and the user must sign in again.
    private func error(status: Int, body: Data) -> OAuthError {
        struct Failure: Decodable {
            let error: String?
            let errorDescription: String?
            enum CodingKeys: String, CodingKey {
                case error
                case errorDescription = "error_description"
            }
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: body)
        if failure?.error == "invalid_grant" { return .invalidGrant }
        return .server(status: status, code: failure?.error, description: failure?.errorDescription)
    }
}

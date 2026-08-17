import Foundation
import MCPMCore

/// What the UI shows next to a server, and what the gateway does about it.
public enum AuthState: String, Codable, Sendable {
    /// Not an authenticated server at all.
    case none
    /// No usable credential — the user has to sign in (or paste a header).
    case needsAuth
    case connected
    /// Signed in, but the access token is inside the refresh window (or already past it).
    case expiring
    /// The credential store itself is unreadable.
    case error
}

public enum AuthError: Error, Equatable, Sendable, CustomStringConvertible {
    /// There is no credential for this server, or the one we had is dead. The caller's move is to
    /// send the user through `startAuth` again.
    case needsAuth(id: String)
    /// A callback whose `state` we never issued, already redeemed, or that timed out.
    case invalidState
    case missingCode

    public var description: String {
        switch self {
        case let .needsAuth(id): return "\(id) needs to be signed in again"
        case .invalidState: return "the authorization response did not match a pending sign-in"
        case .missingCode: return "the authorization response carried no code"
        }
    }
}

/// Owns every server's credentials: it starts sign-ins, redeems the callbacks, hands the proxy a
/// live bearer token, and refreshes on the way. One actor so a burst of proxied requests cannot
/// turn into a burst of refreshes.
public actor AuthManager {
    /// How long an authorization redirect may take to come back before the pending PKCE values are
    /// dropped (spec §4.5).
    static let pendingTTL: TimeInterval = 600
    /// Refresh this far ahead of expiry rather than waiting for the upstream 401.
    static let refreshSlack: TimeInterval = 60

    private let store: any TokenStore
    private let oauth: OAuthClient
    private let redirectURI: URL
    private let now: @Sendable () -> Date

    /// One in-flight authorization, keyed by the `state` we put in the redirect. Never persisted:
    /// a daemon restart cancels any sign-in that was mid-browser.
    private struct Pending {
        var id: String
        var verifier: String
        var asMeta: AuthorizationServerMetadata
        var registration: ClientRegistration
        var resource: String?
        var createdAt: Date
    }
    private var pending: [String: Pending] = [:]
    /// At most one refresh per server at a time; everyone else waits on the same task.
    private var refreshing: [String: Task<TokenRecord, Error>] = [:]

    /// Server ids whose stored credentials just changed, so the daemon can push a status update.
    public nonisolated let stateChanged: AsyncStream<String>
    private nonisolated let changes: AsyncStream<String>.Continuation

    public init(store: any TokenStore, oauth: OAuthClient, redirectURI: URL,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.oauth = oauth
        self.redirectURI = redirectURI
        self.now = now
        // Buffered, so a transition that happens before the daemon starts listening is not lost.
        (stateChanged, changes) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    deinit { changes.finish() }

    // MARK: - State

    /// A credential that has slipped inside the refresh window still reads as `expiring` rather than
    /// `needsAuth`: the refresh token is probably fine, and the proxy will use it on the next call.
    public func state(for id: String, auth: AuthKind) -> AuthState {
        do {
            switch auth {
            case .none:
                return .none
            case .header:
                guard let header = try store.header(for: id), !header.value.isEmpty else { return .needsAuth }
                return .connected
            case .oauth:
                guard let token = try store.token(for: id) else { return .needsAuth }
                return token.isFresh(now: now(), slack: Self.refreshSlack) ? .connected : .expiring
            }
        } catch {
            // An unreadable store is not "signed out" — a locked Keychain must not look like a
            // reason to re-run OAuth.
            return .error
        }
    }

    // MARK: - Sign in

    /// Discovers the server's authorization server, makes sure we have a client registered with it,
    /// and returns the URL the user's browser should visit. The PKCE verifier stays here.
    public func startAuth(id: String, serverURL: URL) async throws -> URL {
        let discovery = try await oauth.discover(resource: serverURL)

        let registration: ClientRegistration
        if let existing = try? store.clientRegistration(for: id),
           issuerMatches(existing.issuer, expected: discovery.asMeta.issuer) {
            registration = existing
        } else {
            registration = try await oauth.register(asMeta: discovery.asMeta, redirectURI: redirectURI)
            try store.setClientRegistration(registration, for: id)
        }

        let verifier = PKCE.verifier()
        let state = PKCE.state()
        // RFC 8707. The canonical spelling comes from the resource's own metadata when it publishes
        // any; a server that advertises nothing is not asked to understand the parameter.
        let resource = discovery.prm?.resource

        dropPending { $0.id == id || self.now().timeIntervalSince($0.createdAt) > Self.pendingTTL }
        pending[state] = Pending(id: id, verifier: verifier, asMeta: discovery.asMeta,
                                 registration: registration, resource: resource, createdAt: now())

        return oauth.authorizeURL(asMeta: discovery.asMeta, clientID: registration.clientID,
                                  redirectURI: redirectURI, scope: discovery.scopeParameter,
                                  state: state, challenge: PKCE.challenge(for: verifier),
                                  resource: resource)
    }

    /// Redeems an `/oauth/callback` query. Returns the server id that just connected.
    public func handleCallback(query: [String: String]) async throws -> String {
        // Take the pending entry first, whatever the outcome: a state is single-use even when the
        // provider answered with a refusal.
        let entry = query["state"].flatMap { pending.removeValue(forKey: $0) }

        if let failure = query["error"] {
            throw OAuthError.providerError(query["error_description"] ?? failure)
        }
        guard let entry, now().timeIntervalSince(entry.createdAt) <= Self.pendingTTL else {
            throw AuthError.invalidState
        }
        guard let code = query["code"], !code.isEmpty else { throw AuthError.missingCode }

        let response = try await oauth.exchange(
            asMeta: entry.asMeta, code: code, verifier: entry.verifier,
            clientID: entry.registration.clientID, clientSecret: entry.registration.clientSecret,
            redirectURI: redirectURI, resource: entry.resource)

        let record = TokenRecord(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: response.expiresIn.map { now().addingTimeInterval($0) },
            tokenType: response.tokenType,
            scope: response.scope,
            clientID: entry.registration.clientID,
            clientSecret: entry.registration.clientSecret,
            tokenEndpoint: entry.asMeta.tokenEndpoint,
            revocationEndpoint: entry.asMeta.revocationEndpoint,
            resource: entry.resource)
        try store.setToken(record, for: entry.id)
        changes.yield(entry.id)
        return entry.id
    }

    // MARK: - Tokens

    /// The `Authorization: Bearer` value for a proxied request, refreshed first if it is about to
    /// expire.
    public func bearer(for id: String) async throws -> String {
        guard let record = try? store.token(for: id) else { throw AuthError.needsAuth(id: id) }
        if record.isFresh(now: now(), slack: Self.refreshSlack) { return record.accessToken }
        return try await refresh(id: id, record: record).accessToken
    }

    /// After an upstream 401: refresh regardless of what the stored expiry claims. A grant the
    /// server has already rejected is deleted, so the UI can ask for a new sign-in.
    public func forceRefresh(id: String) async throws -> String {
        guard let record = try? store.token(for: id) else { throw AuthError.needsAuth(id: id) }
        return try await refresh(id: id, record: record).accessToken
    }

    /// Coalesces concurrent refreshes: whoever arrives while one is in flight waits for its result
    /// instead of spending a second (single-use, rotating) refresh token.
    private func refresh(id: String, record: TokenRecord) async throws -> TokenRecord {
        if let inFlight = refreshing[id] { return try await inFlight.value }

        let task = Task { try await self.performRefresh(id: id, record: record) }
        refreshing[id] = task
        defer { refreshing[id] = nil }
        return try await task.value
    }

    private func performRefresh(id: String, record: TokenRecord) async throws -> TokenRecord {
        guard record.refreshToken != nil else { throw signedOut(id) }
        let response: TokenResponse
        do {
            response = try await oauth.refresh(record)
        } catch OAuthError.invalidGrant {
            throw signedOut(id)
        }

        // Rotation is optional: a server that returns no new refresh token means "keep using the
        // one you have". Dropping it here would lock the user out at the next expiry.
        let updated = TokenRecord(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? record.refreshToken,
            expiresAt: response.expiresIn.map { now().addingTimeInterval($0) },
            tokenType: response.tokenType,
            scope: response.scope ?? record.scope,
            clientID: record.clientID,
            clientSecret: record.clientSecret,
            tokenEndpoint: record.tokenEndpoint,
            revocationEndpoint: record.revocationEndpoint,
            resource: record.resource)
        try store.setToken(updated, for: id)
        changes.yield(id)
        return updated
    }

    /// Deletes a grant the authorization server no longer honours.
    private func signedOut(_ id: String) -> AuthError {
        try? store.removeToken(for: id)
        changes.yield(id)
        return .needsAuth(id: id)
    }

    // MARK: - Sign out

    /// Drops every credential we hold for a server, revoking the token first when the authorization
    /// server offers somewhere to revoke it.
    public func signOut(id: String) async {
        if let record = try? store.token(for: id) {
            await oauth.revoke(record)
        }
        try? store.removeToken(for: id)
        try? store.removeHeader(for: id)
        pending = pending.filter { $0.value.id != id }
        changes.yield(id)
    }

    /// Sign out, and forget the client we registered — the next sign-in registers a fresh one.
    public func forget(id: String) async {
        await signOut(id: id)
        try? store.removeClientRegistration(for: id)
        changes.yield(id)
    }

    // MARK: - Header auth

    public func setHeader(id: String, name: String, value: String) throws {
        try store.setHeader(HeaderSecret(name: name, value: value), for: id)
        changes.yield(id)
    }

    public func header(for id: String) -> HeaderSecret? {
        try? store.header(for: id)
    }

    // MARK: -

    private func dropPending(_ isStale: (Pending) -> Bool) {
        for (state, entry) in pending where isStale(entry) { pending[state] = nil }
    }
}

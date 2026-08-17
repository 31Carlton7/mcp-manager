import Testing
import Foundation
import MCPMCore
@testable import MCPMGateway

private let notionResource = URL(string: "https://mcp.notion.com/mcp")!
private let callbackURI = URL(string: "http://localhost:7337/oauth/callback")!
private let tokenEndpoint = "https://mcp.notion.com/token"
private let registerEndpoint = "https://mcp.notion.com/register"

/// A clock the tests move by hand, so TTLs and expiries are exact instead of slept for.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    var closure: @Sendable () -> Date { { [self] in now } }
}

private func stubNotionDiscovery(_ http: FakeHTTPClient) {
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", json: notionPRMJSON)
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)
    http.stub(registerEndpoint, json: #"{"client_id":"cid-1"}"#)
}

private func stubToken(_ http: FakeHTTPClient, access: String, refresh: String? = "rt-1",
                       expiresIn: Int? = 3600, replacing: Bool = false) {
    var fields = ["\"access_token\":\"\(access)\"", "\"token_type\":\"Bearer\""]
    if let refresh { fields.append("\"refresh_token\":\"\(refresh)\"") }
    if let expiresIn { fields.append("\"expires_in\":\(expiresIn)") }
    let json = "{" + fields.joined(separator: ",") + "}"
    if replacing { http.restub(tokenEndpoint, json: json) } else { http.stub(tokenEndpoint, json: json) }
}

private func makeManager(_ http: FakeHTTPClient, _ store: FileTokenStore,
                         clock: TestClock = TestClock()) -> AuthManager {
    AuthManager(store: store, oauth: OAuthClient(http: http), redirectURI: callbackURI, now: clock.closure)
}

private func newStore() throws -> FileTokenStore {
    FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
}

/// Runs a full sign-in and hands back the state parameter the manager issued.
private func signIn(_ mgr: AuthManager, _ http: FakeHTTPClient, id: String = "notion") async throws -> String {
    let url = try await mgr.startAuth(id: id, serverURL: notionResource)
    let state = queryPairs(url)["state"] ?? ""
    _ = try await mgr.handleCallback(query: ["state": state, "code": "the-code"])
    return state
}

// MARK: - Authorization

@Test func startAuthRegistersAClientAndBuildsAnAuthorizeURL() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    let store = try newStore()
    let mgr = makeManager(http, store)

    let url = try await mgr.startAuth(id: "notion", serverURL: notionResource)

    let q = queryPairs(url)
    #expect(url.absoluteString.hasPrefix("https://mcp.notion.com/authorize?"))
    #expect(q["response_type"] == "code")
    #expect(q["client_id"] == "cid-1")
    #expect(q["redirect_uri"] == callbackURI.absoluteString)
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["code_challenge"]?.isEmpty == false)
    #expect(q["state"]?.isEmpty == false)
    #expect(q["scope"] == "default")
    // RFC 8707: the resource the token is meant for, as the resource itself advertises it.
    #expect(q["resource"] == "https://mcp.notion.com/mcp")
    #expect(try store.clientRegistration(for: "notion")?.clientID == "cid-1")
    // Nothing is signed in until the callback arrives.
    #expect(await mgr.state(for: "notion", auth: .oauth) == .needsAuth)
}

@Test func startAuthReusesAClientAlreadyRegisteredWithTheSameIssuer() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    let mgr = makeManager(http, try newStore())

    _ = try await mgr.startAuth(id: "notion", serverURL: notionResource)
    _ = try await mgr.startAuth(id: "notion", serverURL: notionResource)

    #expect(http.requestCount(to: registerEndpoint) == 1)
}

@Test func startAuthRegistersAgainWhenTheStoredClientBelongsToAnotherIssuer() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    let store = try newStore()
    try store.setClientRegistration(
        ClientRegistration(clientID: "stale", issuer: URL(string: "https://old.example.com")!), for: "notion")
    let mgr = makeManager(http, store)

    let url = try await mgr.startAuth(id: "notion", serverURL: notionResource)

    #expect(queryPairs(url)["client_id"] == "cid-1")
    #expect(http.requestCount(to: registerEndpoint) == 1)
}

// MARK: - Callback

@Test func handleCallbackExchangesTheCodeAndStoresAConnectedToken() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let clock = TestClock()
    let store = try newStore()
    let mgr = makeManager(http, store, clock: clock)

    let url = try await mgr.startAuth(id: "notion", serverURL: notionResource)
    let q = queryPairs(url)
    let id = try await mgr.handleCallback(query: ["state": q["state"]!, "code": "the-code"])

    #expect(id == "notion")
    #expect(await mgr.state(for: "notion", auth: .oauth) == .connected)
    #expect(try await mgr.bearer(for: "notion") == "at-1")

    let form = formPairs(http.request(to: tokenEndpoint)?.httpBody)
    #expect(form["grant_type"] == "authorization_code")
    #expect(form["code"] == "the-code")
    #expect(form["code_verifier"]?.isEmpty == false)
    #expect(form["redirect_uri"] == callbackURI.absoluteString)
    #expect(form["resource"] == "https://mcp.notion.com/mcp")
    // The verifier that was sent must hash to the challenge that was shown.
    #expect(PKCE.challenge(for: form["code_verifier"]!) == q["code_challenge"])

    let stored = try #require(try store.token(for: "notion"))
    #expect(stored.refreshToken == "rt-1")
    #expect(stored.expiresAt == clock.now.addingTimeInterval(3600))
    #expect(stored.tokenEndpoint == URL(string: tokenEndpoint)!)
    #expect(stored.revocationEndpoint == URL(string: tokenEndpoint)!)
    #expect(stored.clientID == "cid-1")
}

@Test func handleCallbackRejectsAStateItNeverIssued() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    let mgr = makeManager(http, try newStore())
    _ = try await mgr.startAuth(id: "notion", serverURL: notionResource)

    await #expect(throws: AuthError.invalidState) {
        _ = try await mgr.handleCallback(query: ["state": "not-ours", "code": "c"])
    }
    #expect(http.requestCount(to: tokenEndpoint) == 0)
}

@Test func handleCallbackRejectsAStateThatWasAlreadyUsed() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let mgr = makeManager(http, try newStore())
    let state = try await signIn(mgr, http)

    await #expect(throws: AuthError.invalidState) {
        _ = try await mgr.handleCallback(query: ["state": state, "code": "the-code"])
    }
    #expect(http.requestCount(to: tokenEndpoint) == 1)
}

@Test func handleCallbackRejectsAStateOlderThanTenMinutes() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let clock = TestClock()
    let mgr = makeManager(http, try newStore(), clock: clock)

    let url = try await mgr.startAuth(id: "notion", serverURL: notionResource)
    clock.advance(601)

    await #expect(throws: AuthError.invalidState) {
        _ = try await mgr.handleCallback(query: ["state": queryPairs(url)["state"]!, "code": "c"])
    }
}

@Test func startingAuthAgainInvalidatesTheEarlierPendingRequest() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let mgr = makeManager(http, try newStore())

    let first = try await mgr.startAuth(id: "notion", serverURL: notionResource)
    let second = try await mgr.startAuth(id: "notion", serverURL: notionResource)

    await #expect(throws: AuthError.invalidState) {
        _ = try await mgr.handleCallback(query: ["state": queryPairs(first)["state"]!, "code": "c"])
    }
    let id = try await mgr.handleCallback(query: ["state": queryPairs(second)["state"]!, "code": "c"])
    #expect(id == "notion")
}

@Test func startingAuthForAnotherServerLeavesTheFirstPendingRequestAlone() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let mgr = makeManager(http, try newStore())

    let first = try await mgr.startAuth(id: "notion", serverURL: notionResource)
    _ = try await mgr.startAuth(id: "other", serverURL: notionResource)

    let id = try await mgr.handleCallback(query: ["state": queryPairs(first)["state"]!, "code": "c"])
    #expect(id == "notion")
}

@Test func handleCallbackSurfacesTheProvidersErrorParameter() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    let mgr = makeManager(http, try newStore())
    let url = try await mgr.startAuth(id: "notion", serverURL: notionResource)

    await #expect(throws: OAuthError.providerError("the user said no")) {
        _ = try await mgr.handleCallback(query: [
            "state": queryPairs(url)["state"]!,
            "error": "access_denied",
            "error_description": "the user said no",
        ])
    }
    #expect(http.requestCount(to: tokenEndpoint) == 0)
    #expect(await mgr.state(for: "notion", auth: .oauth) == .needsAuth)
}

@Test func handleCallbackRejectsAResponseWithNoCode() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    let mgr = makeManager(http, try newStore())
    let url = try await mgr.startAuth(id: "notion", serverURL: notionResource)

    await #expect(throws: AuthError.missingCode) {
        _ = try await mgr.handleCallback(query: ["state": queryPairs(url)["state"]!])
    }
}

// MARK: - Bearer and refresh

@Test func bearerThrowsNeedsAuthWhenThereIsNoToken() async throws {
    let mgr = makeManager(FakeHTTPClient(), try newStore())
    await #expect(throws: AuthError.needsAuth(id: "notion")) {
        _ = try await mgr.bearer(for: "notion")
    }
}

@Test func bearerRefreshesATokenThatIsAboutToExpire() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 30)
    let clock = TestClock()
    let store = try newStore()
    let mgr = makeManager(http, store, clock: clock)
    _ = try await signIn(mgr, http)

    #expect(await mgr.state(for: "notion", auth: .oauth) == .expiring)
    stubToken(http, access: "at-2", refresh: "rt-2", expiresIn: 3600, replacing: true)

    #expect(try await mgr.bearer(for: "notion") == "at-2")
    #expect(await mgr.state(for: "notion", auth: .oauth) == .connected)

    let form = formPairs(http.request(to: tokenEndpoint)?.httpBody)
    #expect(form["grant_type"] == "refresh_token")
    #expect(form["refresh_token"] == "rt-1")
    #expect(try store.token(for: "notion")?.refreshToken == "rt-2")
}

@Test func bearerKeepsTheOldRefreshTokenWhenTheServerDoesNotRotateIt() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 30)
    let store = try newStore()
    let mgr = makeManager(http, store)
    _ = try await signIn(mgr, http)

    stubToken(http, access: "at-2", refresh: nil, expiresIn: 3600, replacing: true)
    #expect(try await mgr.bearer(for: "notion") == "at-2")
    #expect(try store.token(for: "notion")?.refreshToken == "rt-1")
}

@Test func concurrentBearerCallsShareASingleRefresh() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 30)
    let mgr = makeManager(http, try newStore())
    _ = try await signIn(mgr, http)
    let exchanges = http.requestCount(to: tokenEndpoint)

    stubToken(http, access: "at-2", expiresIn: 3600, replacing: true)
    async let a = mgr.bearer(for: "notion")
    async let b = mgr.bearer(for: "notion")
    async let c = mgr.bearer(for: "notion")
    let tokens = try await [a, b, c]

    #expect(tokens == ["at-2", "at-2", "at-2"])
    #expect(http.requestCount(to: tokenEndpoint) - exchanges == 1)
}

@Test func bearerDoesNotRefreshATokenWithPlentyOfLifeLeft() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 3600)
    let mgr = makeManager(http, try newStore())
    _ = try await signIn(mgr, http)
    let exchanges = http.requestCount(to: tokenEndpoint)

    #expect(try await mgr.bearer(for: "notion") == "at-1")
    #expect(http.requestCount(to: tokenEndpoint) == exchanges)
}

@Test func forceRefreshExchangesTheRefreshTokenEvenWhileTheAccessTokenLooksFresh() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 3600)
    let mgr = makeManager(http, try newStore())
    _ = try await signIn(mgr, http)

    stubToken(http, access: "at-2", expiresIn: 3600, replacing: true)
    #expect(try await mgr.forceRefresh(id: "notion") == "at-2")
}

@Test func forceRefreshOnAnInvalidGrantDropsTheTokenAndAsksForSignIn() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 3600)
    let store = try newStore()
    let mgr = makeManager(http, store)
    _ = try await signIn(mgr, http)

    http.restub(tokenEndpoint, status: 400, json: #"{"error":"invalid_grant"}"#)
    await #expect(throws: AuthError.needsAuth(id: "notion")) {
        _ = try await mgr.forceRefresh(id: "notion")
    }
    #expect(try store.token(for: "notion") == nil)
    #expect(await mgr.state(for: "notion", auth: .oauth) == .needsAuth)
}

@Test func forceRefreshWithoutARefreshTokenDropsTheTokenAndAsksForSignIn() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", refresh: nil, expiresIn: 3600)
    let store = try newStore()
    let mgr = makeManager(http, store)
    _ = try await signIn(mgr, http)

    await #expect(throws: AuthError.needsAuth(id: "notion")) {
        _ = try await mgr.forceRefresh(id: "notion")
    }
    #expect(try store.token(for: "notion") == nil)
    // No pointless call to the token endpoint: there was nothing to send.
    #expect(http.requestCount(to: tokenEndpoint) == 1)
}

@Test func aFailedRefreshThatIsNotTheGrantsFaultKeepsTheToken() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 3600)
    let store = try newStore()
    let mgr = makeManager(http, store)
    _ = try await signIn(mgr, http)

    http.restub(tokenEndpoint, status: 503, json: #"{"error":"temporarily_unavailable"}"#)
    await #expect(throws: (any Error).self) { _ = try await mgr.forceRefresh(id: "notion") }
    #expect(try store.token(for: "notion")?.accessToken == "at-1")
}

// MARK: - Sign out, header auth, state

@Test func signOutRevokesAndForgetsTheTokenButKeepsTheClientRegistration() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let store = try newStore()
    let mgr = makeManager(http, store)
    _ = try await signIn(mgr, http)

    await mgr.signOut(id: "notion")

    #expect(try store.token(for: "notion") == nil)
    #expect(try store.clientRegistration(for: "notion")?.clientID == "cid-1")
    #expect(await mgr.state(for: "notion", auth: .oauth) == .needsAuth)
    let revocation = formPairs(http.request(to: tokenEndpoint)?.httpBody)
    #expect(revocation["token"] == "rt-1")
    #expect(revocation["token_type_hint"] == "refresh_token")
}

@Test func forgetAlsoDropsTheRegisteredClient() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let store = try newStore()
    let mgr = makeManager(http, store)
    _ = try await signIn(mgr, http)

    await mgr.forget(id: "notion")

    #expect(try store.token(for: "notion") == nil)
    #expect(try store.clientRegistration(for: "notion") == nil)
}

@Test func headerAuthIsConnectedOnceASecretIsStored() async throws {
    let store = try newStore()
    let mgr = makeManager(FakeHTTPClient(), store)

    #expect(await mgr.state(for: "linear", auth: .header) == .needsAuth)
    try await mgr.setHeader(id: "linear", name: "X-Api-Key", value: "sekret")

    #expect(await mgr.state(for: "linear", auth: .header) == .connected)
    #expect(await mgr.header(for: "linear") == HeaderSecret(name: "X-Api-Key", value: "sekret"))
    #expect(try store.header(for: "linear")?.value == "sekret")
}

@Test func signOutClearsAHeaderSecretToo() async throws {
    let store = try newStore()
    let mgr = makeManager(FakeHTTPClient(), store)
    try await mgr.setHeader(id: "linear", name: "X-Api-Key", value: "sekret")

    await mgr.signOut(id: "linear")

    #expect(await mgr.state(for: "linear", auth: .header) == .needsAuth)
    #expect(try store.header(for: "linear") == nil)
}

@Test func aServerWithoutAuthHasNoAuthState() async throws {
    let mgr = makeManager(FakeHTTPClient(), try newStore())
    #expect(await mgr.state(for: "fs", auth: .none) == AuthState.none)
}

@Test func anExpiredTokenReadsAsExpiringRatherThanGone() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1", expiresIn: 60)
    let clock = TestClock()
    let mgr = makeManager(http, try newStore(), clock: clock)
    _ = try await signIn(mgr, http)

    clock.advance(120)
    // The refresh token may still work, so this is not "signed out" — it is "needs a refresh".
    #expect(await mgr.state(for: "notion", auth: .oauth) == .expiring)
}

// MARK: - Change notifications

@Test func stateChangedReportsEveryServerWhoseCredentialsMoved() async throws {
    let http = FakeHTTPClient()
    stubNotionDiscovery(http)
    stubToken(http, access: "at-1")
    let mgr = makeManager(http, try newStore())

    _ = try await signIn(mgr, http)
    try await mgr.setHeader(id: "linear", name: "X-Api-Key", value: "k")
    await mgr.signOut(id: "notion")

    var seen: [String] = []
    for await id in mgr.stateChanged {
        seen.append(id)
        if seen.count == 3 { break }
    }
    #expect(seen == ["notion", "linear", "notion"])
}

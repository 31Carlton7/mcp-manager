import Testing
import Foundation
@testable import MCPMGateway

private let notionResource = URL(string: "https://mcp.notion.com/mcp")!
private let redirectURI = URL(string: "http://localhost:7337/oauth/callback")!

private func notionMeta() throws -> AuthorizationServerMetadata {
    try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(notionASJSON.utf8))
}

// MARK: - Discovery

@Test func discoverFollowsTheProtectedResourceToItsAuthorizationServer() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource", json: notionPRMJSON)
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)

    #expect(found.prm?.resource == "https://mcp.notion.com/mcp")
    #expect(found.asMeta.tokenEndpoint == URL(string: "https://mcp.notion.com/token")!)
    #expect(found.asMeta.registrationEndpoint == URL(string: "https://mcp.notion.com/register")!)
    #expect(found.scopes == ["default"])
    // The path-scoped candidate is tried first, per RFC 9728.
    #expect(http.requestedURLs.first == "https://mcp.notion.com/.well-known/oauth-protected-resource/mcp")
    #expect(http.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func discoverUsesThePathScopedMetadataWhenItExists() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", json: notionPRMJSON)
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)

    #expect(found.prm != nil)
    // Having found it, it must not keep walking the list.
    #expect(http.requestCount(to: "https://mcp.notion.com/.well-known/oauth-protected-resource") == 0)
}

@Test func discoverFallsBackToTheResourceOriginWhenThereIsNoProtectedResourceMetadata() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)

    #expect(found.prm == nil)
    #expect(found.asMeta.authorizationEndpoint == URL(string: "https://mcp.notion.com/authorize")!)
    #expect(found.scopes == ["default"])
}

@Test func discoverFallsBackToOpenIDConfigurationWhenTheOAuthWellKnownIsMissing() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource", json: notionPRMJSON)
    http.stub("https://mcp.notion.com/.well-known/openid-configuration", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.asMeta.tokenEndpoint == URL(string: "https://mcp.notion.com/token")!)
}

@Test func discoverSynthesizesOriginEndpointsWhenEveryCandidateIs404() async throws {
    let http = FakeHTTPClient()
    let found = try await OAuthClient(http: http).discover(resource: notionResource)

    #expect(found.prm == nil)
    #expect(found.asMeta.authorizationEndpoint == URL(string: "https://mcp.notion.com/authorize")!)
    #expect(found.asMeta.tokenEndpoint == URL(string: "https://mcp.notion.com/token")!)
    #expect(found.asMeta.registrationEndpoint == URL(string: "https://mcp.notion.com/register")!)
    #expect(found.scopes == nil)
}

@Test func discoverIgnoresMetadataThatDoesNotParse() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", json: "{\"nope\":1}")
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource", json: notionPRMJSON)
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: "not json at all")
    http.stub("https://mcp.notion.com/.well-known/openid-configuration", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.prm?.resource == "https://mcp.notion.com/mcp")
    #expect(found.asMeta.issuer == URL(string: "https://mcp.notion.com")!)
}

@Test func discoverUsesTheAuthorizationServerNamedByTheResourceMetadata() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.example.com/.well-known/oauth-protected-resource/mcp", json: """
    {"resource":"https://mcp.example.com/mcp","authorization_servers":["https://auth.example.com/tenant"]}
    """)
    http.stub("https://auth.example.com/.well-known/oauth-authorization-server/tenant", json: """
    {"issuer":"https://auth.example.com/tenant",
     "authorization_endpoint":"https://auth.example.com/tenant/authorize",
     "token_endpoint":"https://auth.example.com/tenant/token"}
    """)

    let found = try await OAuthClient(http: http).discover(resource: URL(string: "https://mcp.example.com/mcp")!)
    #expect(found.asMeta.tokenEndpoint == URL(string: "https://auth.example.com/tenant/token")!)
}

// MARK: - Dynamic client registration

@Test func registerPostsTheDCRBodyAndReturnsTheClientID() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/register", status: 201,
              json: #"{"client_id":"cid-1","client_secret":"sec-1","client_id_issued_at":1}"#)

    let reg = try await OAuthClient(http: http).register(asMeta: try notionMeta(), redirectURI: redirectURI)

    #expect(reg == ClientRegistration(clientID: "cid-1", clientSecret: "sec-1",
                                      issuer: URL(string: "https://mcp.notion.com")!))
    let req = try #require(http.request(to: "https://mcp.notion.com/register"))
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = jsonObject(req.httpBody)
    #expect(body["client_name"] as? String == "MCP Manager")
    #expect(body["redirect_uris"] as? [String] == ["http://localhost:7337/oauth/callback"])
    #expect(body["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
    #expect(body["response_types"] as? [String] == ["code"])
    #expect(body["token_endpoint_auth_method"] as? String == "none")
}

@Test func registerWithoutASecretIsAPublicClient() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/register", json: #"{"client_id":"cid-1"}"#)
    let reg = try await OAuthClient(http: http).register(asMeta: try notionMeta(), redirectURI: redirectURI)
    #expect(reg.clientSecret == nil)
}

@Test func registerThrowsRegistrationUnsupportedWhenTheServerRejectsIt() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/register", status: 400, json: #"{"error":"invalid_client_metadata"}"#)
    await #expect(throws: OAuthError.registrationUnsupported) {
        try await OAuthClient(http: http).register(asMeta: try notionMeta(), redirectURI: redirectURI)
    }
}

@Test func registerThrowsRegistrationUnsupportedWhenThereIsNoEndpoint() async throws {
    var meta = try notionMeta()
    meta.registrationEndpoint = nil
    await #expect(throws: OAuthError.registrationUnsupported) {
        try await OAuthClient(http: FakeHTTPClient()).register(asMeta: meta, redirectURI: redirectURI)
    }
}

// MARK: - Authorize URL

@Test func authorizeURLCarriesTheFullPKCEQuery() throws {
    let url = OAuthClient(http: FakeHTTPClient()).authorizeURL(
        asMeta: try notionMeta(), clientID: "cid-1", redirectURI: redirectURI, scope: "default",
        state: "st-1", challenge: "ch-1", resource: "https://mcp.notion.com/mcp")

    #expect(url.absoluteString.hasPrefix("https://mcp.notion.com/authorize?"))
    #expect(queryPairs(url) == [
        "response_type": "code",
        "client_id": "cid-1",
        "redirect_uri": "http://localhost:7337/oauth/callback",
        "code_challenge": "ch-1",
        "code_challenge_method": "S256",
        "state": "st-1",
        "scope": "default",
        "resource": "https://mcp.notion.com/mcp",
    ])
}

@Test func authorizeURLOmitsScopeAndResourceWhenAbsentAndKeepsExistingQuery() throws {
    var meta = try notionMeta()
    meta.authorizationEndpoint = URL(string: "https://as.example/authorize?tenant=acme")!
    let url = OAuthClient(http: FakeHTTPClient()).authorizeURL(
        asMeta: meta, clientID: "cid", redirectURI: redirectURI, scope: nil,
        state: "st", challenge: "ch", resource: nil)

    let q = queryPairs(url)
    #expect(q["scope"] == nil)
    #expect(q["resource"] == nil)
    #expect(q["tenant"] == "acme")
    #expect(q["code_challenge_method"] == "S256")
}

// MARK: - Code exchange

@Test func exchangePostsTheAuthorizationCodeForm() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: """
    {"access_token":"at-1","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-1","scope":"default"}
    """)

    let token = try await OAuthClient(http: http).exchange(
        asMeta: try notionMeta(), code: "code 1", verifier: "ver-1", clientID: "cid-1", clientSecret: nil,
        redirectURI: redirectURI, resource: "https://mcp.notion.com/mcp")

    #expect(token == TokenResponse(accessToken: "at-1", tokenType: "Bearer", expiresIn: 3600,
                                   refreshToken: "rt-1", scope: "default"))
    let req = try #require(http.request(to: "https://mcp.notion.com/token"))
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(formPairs(req.httpBody) == [
        "grant_type": "authorization_code",
        "code": "code 1",
        "code_verifier": "ver-1",
        "client_id": "cid-1",
        "redirect_uri": "http://localhost:7337/oauth/callback",
        "resource": "https://mcp.notion.com/mcp",
    ])
}

@Test func exchangeSendsTheClientSecretInTheBodyWhenThereIsOne() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: #"{"access_token":"at","token_type":"Bearer"}"#)

    _ = try await OAuthClient(http: http).exchange(
        asMeta: try notionMeta(), code: "c", verifier: "v", clientID: "cid", clientSecret: "sec",
        redirectURI: redirectURI, resource: nil)

    let pairs = formPairs(http.request(to: "https://mcp.notion.com/token")?.httpBody)
    #expect(pairs["client_secret"] == "sec")
    #expect(pairs["resource"] == nil)
}

@Test func tokenResponseDefaultsTheTypeToBearer() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: #"{"access_token":"at"}"#)
    let token = try await OAuthClient(http: http).exchange(
        asMeta: try notionMeta(), code: "c", verifier: "v", clientID: "cid", clientSecret: nil,
        redirectURI: redirectURI, resource: nil)
    #expect(token.tokenType == "Bearer")
    #expect(token.expiresIn == nil)
}

// MARK: - Refresh

@Test func refreshPostsTheRefreshGrant() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: """
    {"access_token":"at-2","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-2"}
    """)
    let record = sampleRecord()

    let token = try await OAuthClient(http: http).refresh(record)

    #expect(token.accessToken == "at-2")
    #expect(token.refreshToken == "rt-2")
    #expect(formPairs(http.request(to: "https://mcp.notion.com/token")?.httpBody) == [
        "grant_type": "refresh_token",
        "refresh_token": "rt-1",
        "client_id": "client-1",
        "resource": "https://mcp.notion.com/mcp",
    ])
}

@Test func refreshWithoutARefreshTokenThrowsRatherThanCallingTheServer() async throws {
    let http = FakeHTTPClient()
    var record = sampleRecord()
    record.refreshToken = nil
    await #expect(throws: OAuthError.noRefreshToken) { try await OAuthClient(http: http).refresh(record) }
    #expect(http.requests.isEmpty)
}

@Test func refreshMapsInvalidGrantToItsOwnError() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", status: 400,
              json: #"{"error":"invalid_grant","error_description":"expired"}"#)
    await #expect(throws: OAuthError.invalidGrant) { try await OAuthClient(http: http).refresh(sampleRecord()) }
}

@Test func otherTokenErrorsCarryTheServersMessage() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", status: 401,
              json: #"{"error":"invalid_client","error_description":"unknown client"}"#)

    await #expect(throws: OAuthError.self) { try await OAuthClient(http: http).refresh(sampleRecord()) }
    do {
        _ = try await OAuthClient(http: http).refresh(sampleRecord())
        Issue.record("expected a throw")
    } catch let error as OAuthError {
        #expect("\(error)".contains("invalid_client"))
        #expect("\(error)".contains("unknown client"))
    }
}

@Test func nonJSONErrorBodiesStillProduceAnError() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", status: 500, json: "upstream exploded")
    await #expect(throws: OAuthError.self) { try await OAuthClient(http: http).refresh(sampleRecord()) }
}

// MARK: - Revocation

@Test func revokePostsTheTokenToTheRevocationEndpoint() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: "{}")

    await OAuthClient(http: http).revoke(sampleRecord())

    let pairs = formPairs(http.request(to: "https://mcp.notion.com/token")?.httpBody)
    #expect(pairs["token"] == "rt-1")
    #expect(pairs["token_type_hint"] == "refresh_token")
    #expect(pairs["client_id"] == "client-1")
}

@Test func revokeIsBestEffortAndSwallowsFailures() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", status: 500, json: "boom")
    await OAuthClient(http: http).revoke(sampleRecord())   // must not throw

    var noEndpoint = sampleRecord()
    noEndpoint.revocationEndpoint = nil
    await OAuthClient(http: http).revoke(noEndpoint)
    #expect(http.requestCount(to: "https://mcp.notion.com/token") == 1)
}

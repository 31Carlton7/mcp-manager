import Testing
import Foundation
@testable import MCPMGateway

private let notionResource = URL(string: "https://mcp.notion.com/mcp")!

// MARK: - Issuer identity (RFC 8414 §3.3)

@Test func metadataWhoseIssuerDoesNotMatchTheFetchURLIsSkipped() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource", json: notionPRMJSON)
    // A document served from Notion's well-known URL that claims to be someone else: an
    // authorization-server mix-up attack. Skip it and keep walking the candidate list.
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: """
    {"issuer":"https://evil.example",
     "authorization_endpoint":"https://evil.example/authorize",
     "token_endpoint":"https://evil.example/token"}
    """)
    http.stub("https://mcp.notion.com/.well-known/openid-configuration", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.asMeta.issuer == URL(string: "https://mcp.notion.com")!)
    #expect(found.asMeta.tokenEndpoint == URL(string: "https://mcp.notion.com/token")!)
}

@Test func aMismatchedIssuerOnEveryCandidateFallsBackToTheOriginEndpoints() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: """
    {"issuer":"https://evil.example","authorization_endpoint":"https://evil.example/authorize",
     "token_endpoint":"https://evil.example/token"}
    """)
    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.asMeta.tokenEndpoint == URL(string: "https://mcp.notion.com/token")!)
}

@Test func issuerComparisonIgnoresCaseAndATrailingSlash() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: """
    {"issuer":"HTTPS://MCP.Notion.com/",
     "authorization_endpoint":"https://mcp.notion.com/authorize",
     "token_endpoint":"https://mcp.notion.com/token",
     "registration_endpoint":"https://mcp.notion.com/register"}
    """)
    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.asMeta.registrationEndpoint == URL(string: "https://mcp.notion.com/register")!)
}

// MARK: - Resource identity (RFC 9728 §3.3)

@Test func protectedResourceMetadataForAnotherResourceIsRejected() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", json: """
    {"resource":"https://attacker.example/mcp","authorization_servers":["https://attacker.example"]}
    """)
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.prm == nil)
    // …and the attacker's authorization server is never contacted.
    #expect(found.asMeta.issuer == URL(string: "https://mcp.notion.com")!)
    #expect(http.requestedURLs.allSatisfy { !$0.contains("attacker.example") })
}

@Test func protectedResourceMetadataMayNameAPrefixOfTheRequestedResource() async throws {
    let http = FakeHTTPClient()
    // The origin covering every path under it is the common real-world shape.
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource", json: """
    {"resource":"https://mcp.notion.com","authorization_servers":["https://mcp.notion.com"],
     "scopes_supported":["default"]}
    """)
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.prm?.resource == "https://mcp.notion.com")
    #expect(found.scopes == ["default"])
}

@Test func aSiblingPathIsNotAPrefixOfTheRequestedResource() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource", json: """
    {"resource":"https://mcp.notion.com/mcp-other","authorization_servers":["https://mcp.notion.com"]}
    """)
    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.prm == nil)
}

// MARK: - Transport security

@Test func aPlainHTTPAuthorizationServerIsRefused() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", json: """
    {"resource":"https://mcp.notion.com/mcp","authorization_servers":["http://as.example"]}
    """)
    await #expect(throws: OAuthError.insecureEndpoint(URL(string: "http://as.example")!)) {
        try await OAuthClient(http: http).discover(resource: notionResource)
    }
}

@Test func aPlainHTTPTokenEndpointIsRefused() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: """
    {"issuer":"https://mcp.notion.com","authorization_endpoint":"https://mcp.notion.com/authorize",
     "token_endpoint":"http://mcp.notion.com/token"}
    """)
    await #expect(throws: OAuthError.insecureEndpoint(URL(string: "http://mcp.notion.com/token")!)) {
        try await OAuthClient(http: http).discover(resource: notionResource)
    }
}

@Test func aPlainHTTPRevocationEndpointIsRefused() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", json: """
    {"issuer":"https://mcp.notion.com","authorization_endpoint":"https://mcp.notion.com/authorize",
     "token_endpoint":"https://mcp.notion.com/token",
     "revocation_endpoint":"http://mcp.notion.com/revoke"}
    """)
    await #expect(throws: OAuthError.self) {
        try await OAuthClient(http: http).discover(resource: notionResource)
    }
}

@Test func loopbackServersMayUsePlainHTTP() async throws {
    let http = FakeHTTPClient()
    http.stub("http://127.0.0.1:8080/.well-known/oauth-protected-resource/mcp", json: """
    {"resource":"http://127.0.0.1:8080/mcp","authorization_servers":["http://localhost:9000"]}
    """)
    http.stub("http://localhost:9000/.well-known/oauth-authorization-server", json: """
    {"issuer":"http://localhost:9000","authorization_endpoint":"http://localhost:9000/authorize",
     "token_endpoint":"http://localhost:9000/token"}
    """)

    let found = try await OAuthClient(http: http).discover(resource: URL(string: "http://127.0.0.1:8080/mcp")!)
    #expect(found.asMeta.tokenEndpoint == URL(string: "http://localhost:9000/token")!)
}

@Test func loopbackFallbackEndpointsAreAllowedToo() async throws {
    let found = try await OAuthClient(http: FakeHTTPClient())
        .discover(resource: URL(string: "http://localhost:8080/mcp")!)
    #expect(found.asMeta.tokenEndpoint == URL(string: "http://localhost:8080/token")!)
}

// MARK: - Failure handling during discovery

@Test func discoveryPropagatesTransportErrorsInsteadOfGuessing() async throws {
    let http = FakeHTTPClient()
    http.stubTransportFailure("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp")
    await #expect(throws: FakeHTTPClient.TransportFailure.self) {
        try await OAuthClient(http: http).discover(resource: notionResource)
    }
}

@Test func aBrokenAuthorizationServerIsAnErrorRatherThanAGuessedFallback() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", status: 503, json: "down")
    await #expect(throws: OAuthError.self) {
        try await OAuthClient(http: http).discover(resource: notionResource)
    }
}

@Test func a404OrGoneStillFallsThroughToTheNextCandidate() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", status: 410, json: "gone")
    http.stub("https://mcp.notion.com/.well-known/oauth-protected-resource", json: notionPRMJSON)
    http.stub("https://mcp.notion.com/.well-known/oauth-authorization-server", status: 404, json: "nope")
    http.stub("https://mcp.notion.com/.well-known/openid-configuration", json: notionASJSON)

    let found = try await OAuthClient(http: http).discover(resource: notionResource)
    #expect(found.prm != nil)
    #expect(found.asMeta.issuer == URL(string: "https://mcp.notion.com")!)
}

// MARK: - Token endpoint hardening

@Test func aRedirectFromTheTokenEndpointIsAnError() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", status: 302, json: "{}")
    await #expect(throws: OAuthError.self) { try await OAuthClient(http: http).refresh(sampleRecord()) }
}

@Test func exchangeRefusesAnInsecureTokenEndpoint() async throws {
    var meta = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(notionASJSON.utf8))
    meta.tokenEndpoint = URL(string: "http://mcp.notion.com/token")!
    let http = FakeHTTPClient()
    await #expect(throws: OAuthError.insecureEndpoint(meta.tokenEndpoint)) {
        try await OAuthClient(http: http).exchange(
            asMeta: meta, code: "c", verifier: "v", clientID: "cid", clientSecret: nil,
            redirectURI: URL(string: "http://localhost:7337/oauth/callback")!, resource: nil)
    }
    #expect(http.requests.isEmpty)
}

// MARK: - Client authentication style

@Test func basicAuthIsUsedWhenTheServerOnlyOffersClientSecretBasic() async throws {
    var meta = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(notionASJSON.utf8))
    meta.tokenEndpointAuthMethodsSupported = ["client_secret_basic", "none"]
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: #"{"access_token":"at"}"#)

    _ = try await OAuthClient(http: http).exchange(
        asMeta: meta, code: "c", verifier: "v", clientID: "cid/1", clientSecret: "sec ret",
        redirectURI: URL(string: "http://localhost:7337/oauth/callback")!, resource: nil)

    let req = try #require(http.request(to: "https://mcp.notion.com/token"))
    // RFC 6749 §2.3.1: form-urlencode each half before base64.
    let expected = Data("cid%2F1:sec%20ret".utf8).base64EncodedString()
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")
    #expect(formPairs(req.httpBody)["client_secret"] == nil)
    #expect(formPairs(req.httpBody)["client_id"] == "cid/1")
}

@Test func theSecretStaysInTheBodyWhenTheServerSupportsPost() async throws {
    var meta = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(notionASJSON.utf8))
    meta.tokenEndpointAuthMethodsSupported = ["client_secret_basic", "client_secret_post"]
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: #"{"access_token":"at"}"#)

    _ = try await OAuthClient(http: http).exchange(
        asMeta: meta, code: "c", verifier: "v", clientID: "cid", clientSecret: "sec",
        redirectURI: URL(string: "http://localhost:7337/oauth/callback")!, resource: nil)

    let req = try #require(http.request(to: "https://mcp.notion.com/token"))
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(formPairs(req.httpBody)["client_secret"] == "sec")
}

@Test func refreshCanUseBasicAuthWhenToldWhichMethodsTheServerOffers() async throws {
    let http = FakeHTTPClient()
    http.stub("https://mcp.notion.com/token", json: #"{"access_token":"at-2"}"#)
    var record = sampleRecord()
    record.clientSecret = "sec"

    _ = try await OAuthClient(http: http).refresh(record, authMethods: ["client_secret_basic"])

    let req = try #require(http.request(to: "https://mcp.notion.com/token"))
    #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    #expect(formPairs(req.httpBody)["client_secret"] == nil)
}

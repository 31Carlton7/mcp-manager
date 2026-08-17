import Testing
import Foundation
@testable import MCPMGateway

// MARK: - Protected-resource candidates (RFC 9728 §3)

@Test func prmCandidatesInsertThePathAfterTheWellKnownSegment() {
    let c = discoveryCandidates(resource: URL(string: "https://mcp.notion.com/mcp")!)
    #expect(c.map(\.absoluteString) == [
        "https://mcp.notion.com/.well-known/oauth-protected-resource/mcp",
        "https://mcp.notion.com/.well-known/oauth-protected-resource",
    ])
}

@Test func prmCandidatesKeepMultiSegmentPaths() {
    let c = discoveryCandidates(resource: URL(string: "https://h.example/p/q")!)
    #expect(c.map(\.absoluteString) == [
        "https://h.example/.well-known/oauth-protected-resource/p/q",
        "https://h.example/.well-known/oauth-protected-resource",
    ])
}

@Test func prmCandidatesForAnOriginAreASingleURL() {
    #expect(discoveryCandidates(resource: URL(string: "https://h.example")!).map(\.absoluteString)
            == ["https://h.example/.well-known/oauth-protected-resource"])
    #expect(discoveryCandidates(resource: URL(string: "https://h.example/")!).map(\.absoluteString)
            == ["https://h.example/.well-known/oauth-protected-resource"])
}

@Test func prmCandidatesDropQueryAndFragmentAndTrailingSlashAndKeepPort() {
    let c = discoveryCandidates(resource: URL(string: "https://h.example:8443/mcp/?x=1#f")!)
    #expect(c.map(\.absoluteString) == [
        "https://h.example:8443/.well-known/oauth-protected-resource/mcp",
        "https://h.example:8443/.well-known/oauth-protected-resource",
    ])
}

// MARK: - Authorization-server candidates (RFC 8414 §3)

@Test func asCandidatesForAnIssuerWithAPathTryAllThreeForms() {
    let c = asCandidates(issuer: URL(string: "https://h.example/x")!)
    #expect(c.map(\.absoluteString) == [
        "https://h.example/.well-known/oauth-authorization-server/x",
        "https://h.example/.well-known/openid-configuration/x",
        "https://h.example/x/.well-known/openid-configuration",
    ])
}

@Test func asCandidatesForABareIssuerAreTheTwoWellKnownURLs() {
    let c = asCandidates(issuer: URL(string: "https://mcp.notion.com")!)
    #expect(c.map(\.absoluteString) == [
        "https://mcp.notion.com/.well-known/oauth-authorization-server",
        "https://mcp.notion.com/.well-known/openid-configuration",
    ])
    #expect(asCandidates(issuer: URL(string: "https://mcp.notion.com/")!) == c)
}

// MARK: - Decoding

@Test func protectedResourceMetadataDecodesNotionShape() throws {
    let json = """
    {"resource":"https://mcp.notion.com/mcp",
     "authorization_servers":["https://mcp.notion.com"],
     "scopes_supported":["default"],
     "bearer_methods_supported":["header"]}
    """
    let prm = try JSONDecoder().decode(ProtectedResourceMetadata.self, from: Data(json.utf8))
    #expect(prm.resource == "https://mcp.notion.com/mcp")
    #expect(prm.authorizationServers == ["https://mcp.notion.com"])
    #expect(prm.scopesSupported == ["default"])
}

@Test func authorizationServerMetadataDecodesNotionShape() throws {
    let meta = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(notionASJSON.utf8))
    #expect(meta.issuer == URL(string: "https://mcp.notion.com")!)
    #expect(meta.authorizationEndpoint == URL(string: "https://mcp.notion.com/authorize")!)
    #expect(meta.tokenEndpoint == URL(string: "https://mcp.notion.com/token")!)
    #expect(meta.registrationEndpoint == URL(string: "https://mcp.notion.com/register")!)
    #expect(meta.revocationEndpoint == URL(string: "https://mcp.notion.com/token")!)
    #expect(meta.codeChallengeMethodsSupported == ["S256"])
    #expect(meta.tokenEndpointAuthMethodsSupported?.contains("none") == true)
    #expect(meta.scopesSupported == ["default"])
}

@Test func authorizationServerMetadataDecodesWithOnlyTheRequiredFields() throws {
    let json = """
    {"issuer":"https://as.example","authorization_endpoint":"https://as.example/authorize",
     "token_endpoint":"https://as.example/token"}
    """
    let meta = try JSONDecoder().decode(AuthorizationServerMetadata.self, from: Data(json.utf8))
    #expect(meta.registrationEndpoint == nil)
    #expect(meta.revocationEndpoint == nil)
    #expect(meta.scopesSupported == nil)
}

@Test func fallbackMetadataPutsTheEndpointsAtTheIssuerOrigin() {
    let meta = AuthorizationServerMetadata.fallback(issuer: URL(string: "https://h.example/x")!)
    #expect(meta.issuer == URL(string: "https://h.example/x")!)
    #expect(meta.authorizationEndpoint == URL(string: "https://h.example/authorize")!)
    #expect(meta.tokenEndpoint == URL(string: "https://h.example/token")!)
    #expect(meta.registrationEndpoint == URL(string: "https://h.example/register")!)
}

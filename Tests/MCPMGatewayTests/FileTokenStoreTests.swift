import Testing
import Foundation
@testable import MCPMGateway

func tmpDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-gw-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func sampleRecord(access: String = "at-1", expires: Date? = Date(timeIntervalSince1970: 1_800_000_000)) -> TokenRecord {
    TokenRecord(accessToken: access, refreshToken: "rt-1", expiresAt: expires, tokenType: "Bearer",
                scope: "default", clientID: "client-1", clientSecret: nil,
                tokenEndpoint: URL(string: "https://mcp.notion.com/token")!,
                revocationEndpoint: URL(string: "https://mcp.notion.com/token")!,
                resource: "https://mcp.notion.com/mcp")
}

@Test func fileTokenStoreReturnsNilForMissingEntries() throws {
    let store = FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
    #expect(try store.token(for: "notion") == nil)
    #expect(try store.header(for: "notion") == nil)
    #expect(try store.clientRegistration(for: "notion") == nil)
}

@Test func fileTokenStoreRoundTripsATokenRecord() throws {
    let store = FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
    let record = sampleRecord()
    try store.setToken(record, for: "notion")
    #expect(try store.token(for: "notion") == record)
    // A second store over the same file sees it: the state is the file, not memory.
    #expect(try FileTokenStore(url: store.url).token(for: "notion") == record)
}

@Test func fileTokenStoreRoundTripsRecordsWithoutOptionalFields() throws {
    let store = FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
    let record = TokenRecord(accessToken: "at", tokenType: "Bearer", clientID: "c",
                             tokenEndpoint: URL(string: "https://as.example/token")!)
    try store.setToken(record, for: "s")
    #expect(try store.token(for: "s") == record)
}

@Test func fileTokenStoreKeepsEntriesForOtherServers() throws {
    let store = FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
    try store.setToken(sampleRecord(access: "a"), for: "notion")
    try store.setToken(sampleRecord(access: "b"), for: "linear")
    try store.setHeader(HeaderSecret(name: "X-Api-Key", value: "k"), for: "notion")
    try store.setClientRegistration(
        ClientRegistration(clientID: "cid", clientSecret: "sec", issuer: URL(string: "https://as.example")!),
        for: "notion")

    #expect(try store.token(for: "notion")?.accessToken == "a")
    #expect(try store.token(for: "linear")?.accessToken == "b")
    #expect(try store.header(for: "notion") == HeaderSecret(name: "X-Api-Key", value: "k"))
    #expect(try store.clientRegistration(for: "notion")?.clientID == "cid")
    #expect(try store.clientRegistration(for: "notion")?.clientSecret == "sec")
}

@Test func fileTokenStoreRemovesEntries() throws {
    let store = FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
    try store.setToken(sampleRecord(), for: "notion")
    try store.setHeader(HeaderSecret(name: "n", value: "v"), for: "notion")

    try store.removeToken(for: "notion")
    #expect(try store.token(for: "notion") == nil)
    #expect(try store.header(for: "notion") != nil)

    try store.removeHeader(for: "notion")
    #expect(try store.header(for: "notion") == nil)

    // Removing what is not there is not an error.
    try store.removeToken(for: "nope")
    try store.removeHeader(for: "nope")
}

@Test func signingOutKeepsTheClientRegistrationButForgettingDropsIt() throws {
    let store = FileTokenStore(url: try tmpDir().appendingPathComponent("tokens.json"))
    let registration = ClientRegistration(clientID: "cid", clientSecret: nil,
                                          issuer: URL(string: "https://as.example")!)
    try store.setToken(sampleRecord(), for: "notion")
    try store.setClientRegistration(registration, for: "notion")

    // Sign out: the token goes, the registration stays so the next sign-in reuses the client id.
    try store.removeToken(for: "notion")
    #expect(try store.clientRegistration(for: "notion") == registration)

    // Forget: the registration goes too.
    try store.removeClientRegistration(for: "notion")
    #expect(try store.clientRegistration(for: "notion") == nil)
    try store.removeClientRegistration(for: "never-registered")
}

@Test func fileTokenStoreWritesMode0600() throws {
    let url = try tmpDir().appendingPathComponent("tokens.json")
    let store = FileTokenStore(url: url)
    try store.setToken(sampleRecord(), for: "notion")
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)

    // And still 0600 after an overwrite, even if something loosened it in between.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try store.setToken(sampleRecord(access: "at-2"), for: "notion")
    let after = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((after[.posixPermissions] as? Int) == 0o600)
}

@Test func fileTokenStoreThrowsOnACorruptFile() throws {
    let url = try tmpDir().appendingPathComponent("tokens.json")
    try Data("{not json".utf8).write(to: url)
    let store = FileTokenStore(url: url)
    #expect(throws: (any Error).self) { try store.token(for: "notion") }
}

// Runnable by hand (`swift test --filter keychainTokenStore`) but never in CI: it writes to the
// developer's real login keychain and pops the "wants to use your confidential information" panel.
@Test(.disabled("touches login keychain")) func keychainTokenStoreRoundTrips() throws {
    let store = KeychainTokenStore(service: "co.charmtechnologies.mcpm.tests")
    let id = "test-\(UUID().uuidString)"
    defer {
        try? store.removeToken(for: id)
        try? store.removeHeader(for: id)
        try? store.removeClientRegistration(for: id)
    }
    #expect(try store.token(for: id) == nil)

    let record = sampleRecord()
    try store.setToken(record, for: id)
    #expect(try store.token(for: id) == record)

    try store.setToken(sampleRecord(access: "at-2"), for: id)
    #expect(try store.token(for: id)?.accessToken == "at-2")

    try store.setHeader(HeaderSecret(name: "X-Api-Key", value: "k"), for: id)
    #expect(try store.header(for: id)?.value == "k")

    try store.setClientRegistration(
        ClientRegistration(clientID: "cid", clientSecret: nil, issuer: URL(string: "https://as.example")!), for: id)
    #expect(try store.clientRegistration(for: id)?.clientID == "cid")

    try store.removeToken(for: id)
    #expect(try store.token(for: id) == nil)
}

import Testing
import Foundation
import MCPMCore
import MCPMControl
import MCPMGateway
@testable import MCPMDaemon

/// No handler exercised here reaches the network. Anything that tries fails loudly rather than
/// quietly dialling out from a test.
private struct OfflineHTTP: HTTPClient {
    struct Refused: Error {}
    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) { throw Refused() }
}

private struct Env {
    let root: URL
    let store: FileTokenStore
    let handlers: Handlers
}

private func makeEnv() async throws -> Env {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-h-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let coord = SyncCoordinator(store: Store(url: root.appendingPathComponent("servers.json")),
                                adapters: [], backups: BackupStore(root: root.appendingPathComponent("backups")),
                                gatewayPort: 7337)
    try await coord.runOnce()

    let store = FileTokenStore(url: root.appendingPathComponent("tokens.json"))
    let auth = AuthManager(store: store, oauth: OAuthClient(http: OfflineHTTP()),
                           redirectURI: GatewayConfig(port: 7337).redirectURI())
    return Env(root: root, store: store, handlers: Handlers(coord: coord, auth: auth, gatewayPort: nil))
}

private func add(_ p: AddServerParams, to handlers: Handlers) async throws {
    #expect(try await handlers.handle(ControlRequest(id: 1, command: .addServer(p))) == .ack)
}

private func remoteServer(name: String, auth: AuthKind) -> AddServerParams {
    AddServerParams(name: name, kind: .remote, url: "https://mcp.example.dev/mcp", auth: auth)
}

private func state(of id: String, in handlers: Handlers) async -> String? {
    await handlers.status().servers.first { $0.id == id }?.state
}

private func record(_ token: String) -> TokenRecord {
    TokenRecord(accessToken: token, refreshToken: "r", clientID: "c",
                tokenEndpoint: URL(string: "https://as.example.dev/token")!)
}

@Test func aHeaderServerIsUnauthenticatedUntilItsHeaderIsStored() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "acme", auth: .header), to: e.handlers)
    #expect(await state(of: "acme", in: e.handlers) == "needsAuth")

    let set = ControlCommand.authSetHeader(.init(id: "acme", name: "X-Api-Key", value: "s3cret"))
    #expect(try await e.handlers.handle(ControlRequest(id: 2, command: set)) == .ack)
    #expect(await state(of: "acme", in: e.handlers) == "connected")
    #expect(try e.store.header(for: "acme")?.value == "s3cret")
}

@Test func aServerWithNoAuthReportsNoState() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "plain", auth: .none), to: e.handlers)
    #expect(await state(of: "plain", in: e.handlers) == "none")
}

/// Ids are slugs of the name, so a credential outliving its server would be handed to whatever
/// server next claims that id.
@Test func removingAServerForgetsItsCredentials() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "acme", auth: .header), to: e.handlers)
    let set = ControlCommand.authSetHeader(.init(id: "acme", name: "X-Api-Key", value: "s3cret"))
    _ = try await e.handlers.handle(ControlRequest(id: 2, command: set))
    try e.store.setClientRegistration(
        ClientRegistration(clientID: "c", issuer: URL(string: "https://as.example.dev")!), for: "acme")

    #expect(try await e.handlers.handle(ControlRequest(id: 3, command: .removeServer(.init(id: "acme")))) == .ack)
    #expect(try e.store.header(for: "acme") == nil)
    #expect(try e.store.token(for: "acme") == nil)
    #expect(try e.store.clientRegistration(for: "acme") == nil)
}

@Test func changingTheAuthKindForgetsTheCredentialItWasIssuedFor() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "acme", auth: .oauth), to: e.handlers)
    try e.store.setToken(record("old"), for: "acme")
    #expect(await state(of: "acme", in: e.handlers) == "connected")

    let update = ControlCommand.updateServer(.init(id: "acme", auth: AuthKind.none))
    #expect(try await e.handlers.handle(ControlRequest(id: 2, command: update)) == .ack)
    #expect(try e.store.token(for: "acme") == nil)
    #expect(await state(of: "acme", in: e.handlers) == "none")
}

@Test func anEditThatLeavesTheAuthKindAloneKeepsTheCredential() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "acme", auth: .oauth), to: e.handlers)
    try e.store.setToken(record("keep"), for: "acme")

    let update = ControlCommand.updateServer(.init(id: "acme", name: "Acme Corp"))
    #expect(try await e.handlers.handle(ControlRequest(id: 2, command: update)) == .ack)
    #expect(try e.store.token(for: "acme")?.accessToken == "keep")
}

@Test(arguments: [("X Api Key", "v"), ("X-Api-Key:", "v"), ("", "v"),
                  ("X-Api-Key", "one\r\nInjected: two"), ("X-Api-Key", "one\nInjected: two")])
func aHeaderThatCannotGoOnTheWireIsRejected(name: String, value: String) async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "acme", auth: .header), to: e.handlers)

    let set = ControlCommand.authSetHeader(.init(id: "acme", name: name, value: value))
    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 2, command: set))
    }
    #expect(try e.store.header(for: "acme") == nil)
}

@Test func settingAHeaderOnAServerThatIsNotHeaderAuthedIsRejected() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "acme", auth: .oauth), to: e.handlers)

    let set = ControlCommand.authSetHeader(.init(id: "acme", name: "X-Api-Key", value: "v"))
    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 2, command: set))
    }
}

/// The static headers a client writes into its own config, as opposed to the credential the
/// gateway injects — the inspector edits these for a plain remote server.
@Test func updateCanReplaceStaticHeaders() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "plain", auth: .none), to: e.handlers)

    let update = ControlCommand.updateServer(.init(id: "plain", headers: ["X-Trace": "on"]))
    #expect(try await e.handlers.handle(ControlRequest(id: 2, command: update)) == .ack)
    #expect(await e.handlers.status().servers.first?.server.headers == ["X-Trace": "on"])
}

@Test func testingAServerWithoutAGatewaySaysSoRatherThanDiallingADeadPort() async throws {
    let e = try await makeEnv()
    try await add(remoteServer(name: "acme", auth: .oauth), to: e.handlers)

    let result = try await e.handlers.handle(ControlRequest(id: 2, command: .testServer(.init(id: "acme"))))
    guard case .testResult(let r) = result else { Issue.record("expected a test result"); return }
    #expect(!r.ok)
    #expect(r.error == "gateway not running")
}

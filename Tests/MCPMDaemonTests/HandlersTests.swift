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
    let coord: SyncCoordinator
    let settings: SettingsStore
    let handlers: Handlers
}

private func makeEnv(runningPort: Int = 7337, initial: Settings = Settings()) async throws -> Env {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-h-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let coord = SyncCoordinator(store: Store(url: root.appendingPathComponent("servers.json")),
                                adapters: [], backups: BackupStore(root: root.appendingPathComponent("backups")),
                                gatewayPort: 7337)
    try await coord.runOnce()

    let store = FileTokenStore(url: root.appendingPathComponent("tokens.json"))
    let auth = AuthManager(store: store, oauth: OAuthClient(http: OfflineHTTP()),
                           redirectURI: GatewayConfig(port: 7337).redirectURI())
    let settings = SettingsStore(url: root.appendingPathComponent("settings.json"))
    let service = SettingsService(store: settings, initial: initial, runningPort: runningPort,
                                  applyRetention: { keep in await coord.setBackupRetention(keep) })
    return Env(root: root, store: store, coord: coord, settings: settings,
               handlers: Handlers(coord: coord, auth: auth, gatewayPort: nil, settings: service))
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

/// The credential rides along with the add so the caller never has to guess the id the daemon is
/// about to mint — the whole point of carrying it in `servers.add`.
@Test func anAddCarryingAHeaderCredentialStoresItAgainstTheMintedID() async throws {
    let e = try await makeEnv()
    // Two servers wanting the same slug: the second gets "acme-2", which a caller predicting ids
    // from the name alone would have got wrong.
    try await add(remoteServer(name: "acme", auth: .none), to: e.handlers)
    var p = remoteServer(name: "acme", auth: .header)
    p.headerName = "X-Api-Key"
    p.headerValue = "s3cret"
    try await add(p, to: e.handlers)

    #expect(try e.store.header(for: "acme") == nil)
    #expect(try e.store.header(for: "acme-2")?.name == "X-Api-Key")
    #expect(try e.store.header(for: "acme-2")?.value == "s3cret")
    #expect(await state(of: "acme-2", in: e.handlers) == "connected")
}

@Test(arguments: [("X Api Key", "v"), ("X-Api-Key", "one\r\nInjected: two")])
func anAddWithAnUnsendableHeaderAddsNothingAtAll(name: String, value: String) async throws {
    let e = try await makeEnv()
    var p = remoteServer(name: "acme", auth: .header)
    p.headerName = name
    p.headerValue = value

    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: .addServer(p)))
    }
    #expect(await e.handlers.status().servers.isEmpty)
    #expect(try e.store.header(for: "acme") == nil)
}

@Test func anAddCarryingACredentialForNonHeaderAuthIsRejected() async throws {
    let e = try await makeEnv()
    var p = remoteServer(name: "acme", auth: .oauth)
    p.headerName = "X-Api-Key"
    p.headerValue = "v"

    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: .addServer(p)))
    }
    #expect(await e.handlers.status().servers.isEmpty)
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

// MARK: - Settings

@Test func settingsGetReturnsTheDefaultsUntilSomethingIsSaved() async throws {
    let e = try await makeEnv()
    guard case .settings(let s) = try await e.handlers.handle(ControlRequest(id: 1, command: .getSettings)) else {
        Issue.record("expected settings"); return
    }
    #expect(s == Settings())
    #expect(await e.handlers.status().settingsPendingRestart == false)
}

@Test func settingsSetSavesAndAnswersWithTheStoredValue() async throws {
    let e = try await makeEnv()
    let cmd = ControlCommand.setSettings(.init(gatewayPort: 9001, backupRetention: 9))
    guard case .settings(let s) = try await e.handlers.handle(ControlRequest(id: 1, command: cmd)) else {
        Issue.record("expected settings"); return
    }
    #expect(s.gatewayPort == 9001)
    #expect(s.backupRetention == 9)
    // Not just in memory: a restart has to find it.
    #expect(try e.settings.load() == s)
}

/// The gateway is already bound to the old port and every client config points at it, so the new
/// one is recorded and applied on the next start rather than rebound underneath them.
@Test func changingTheGatewayPortAsksForARestartWithoutMovingTheRunningOne() async throws {
    let e = try await makeEnv(runningPort: 7337)
    _ = try await e.handlers.handle(ControlRequest(id: 1, command: .setSettings(.init(gatewayPort: 9001))))

    let status = await e.handlers.status()
    #expect(status.settingsPendingRestart)
    #expect(status.lastError == SettingsService.restartNote)
    #expect(await e.coord.gatewayPort == 7337)
}

/// Setting the port back to the one that is running is not a pending change.
@Test func settingTheGatewayPortBackToTheRunningOneClearsTheRestartFlag() async throws {
    let e = try await makeEnv(runningPort: 7337)
    _ = try await e.handlers.handle(ControlRequest(id: 1, command: .setSettings(.init(gatewayPort: 9001))))
    #expect(await e.handlers.status().settingsPendingRestart)

    _ = try await e.handlers.handle(ControlRequest(id: 2, command: .setSettings(.init(gatewayPort: 7337))))
    let status = await e.handlers.status()
    #expect(status.settingsPendingRestart == false)
    #expect(status.lastError == nil)
}

/// Retention has no such problem: it only decides what the next write prunes.
@Test func changingBackupRetentionTakesEffectWithoutARestart() async throws {
    let e = try await makeEnv()
    _ = try await e.handlers.handle(ControlRequest(id: 1, command: .setSettings(.init(backupRetention: 2))))
    #expect(await e.coord.backups.keep == 2)
    #expect(await e.handlers.status().settingsPendingRestart == false)
}

@Test(arguments: [0, -1, 65536, 99999])
func settingsSetRefusesAPortOutsideTheValidRange(port: Int) async throws {
    let e = try await makeEnv()
    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: .setSettings(.init(gatewayPort: port))))
    }
    // A refused set leaves nothing behind — not in memory and not on disk.
    #expect(await e.handlers.status().settingsPendingRestart == false)
    #expect(try e.settings.load().gatewayPort == Settings.defaultGatewayPort)
}

@Test func settingsSetRefusesANegativeBackupRetention() async throws {
    let e = try await makeEnv()
    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: .setSettings(.init(backupRetention: -1))))
    }
}

/// One invalid field must not let the other half through: the caller was told the whole set failed.
@Test func aSetWithOneBadFieldSavesNeither() async throws {
    let e = try await makeEnv()
    let bad = ControlCommand.setSettings(.init(gatewayPort: 9001, backupRetention: -3))
    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: bad))
    }
    guard case .settings(let s) = try await e.handlers.handle(ControlRequest(id: 2, command: .getSettings)) else {
        Issue.record("expected settings"); return
    }
    #expect(s == Settings())
}

/// A patch is partial: the field the caller left out keeps its stored value.
@Test func aPatchOnlyChangesTheFieldsItCarries() async throws {
    let e = try await makeEnv(initial: Settings(gatewayPort: 8080, backupRetention: 7))
    _ = try await e.handlers.handle(ControlRequest(id: 1, command: .setSettings(.init(backupRetention: 3))))
    guard case .settings(let s) = try await e.handlers.handle(ControlRequest(id: 2, command: .getSettings)) else {
        Issue.record("expected settings"); return
    }
    #expect(s.gatewayPort == 8080)
    #expect(s.backupRetention == 3)
}

/// A transport read off a paste has nowhere else to be learned, so `servers.add` has to carry it
/// into the library or every SSE server would be added as an HTTP one.
@Test func addingAServerKeepsTheTransportItWasPastedWith() async throws {
    let e = try await makeEnv()
    var p = remoteServer(name: "streamy", auth: .none)
    p.transport = .sse
    try await add(p, to: e.handlers)
    #expect(await e.handlers.status().servers.first { $0.id == "streamy" }?.server.transport == .sse)
}

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

/// The gateway's inspection, which is what `Handlers` is handed; `MCPMControl` mirrors the type
/// under the same name for the wire, so both are in scope here.
private typealias GatewayInspection = MCPMGateway.URLInspection

/// What a URL turned out to be, without one being dialled. Records what it was asked, so a test
/// can pin down that an inspection did or did not happen.
private final class FakeInspector: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: GatewayInspection] = [:]
    private var fallback: GatewayInspection
    private(set) var asked: [String] = []

    /// Unreachable by default: a test that is not about detection wants the add to behave the way
    /// it did before there was any, and nothing about these URLs is real.
    init(fallback: GatewayInspection = GatewayInspection(verdict: .unreachable,
                                                         detail: "nothing answered")) {
        self.fallback = fallback
    }

    func answer(_ url: String, with inspection: GatewayInspection) {
        lock.withLock { answers[url] = inspection }
    }

    var askedURLs: [String] { lock.withLock { asked } }

    var inspect: @Sendable (URL, Duration) async -> GatewayInspection {
        { url, _ in
            self.lock.withLock {
                self.asked.append(url.absoluteString)
                return self.answers[url.absoluteString] ?? self.fallback
            }
        }
    }
}

private struct Env {
    let root: URL
    let store: FileTokenStore
    let coord: SyncCoordinator
    let settings: SettingsStore
    let handlers: Handlers
    let inspector: FakeInspector
}

private func makeEnv(runningPort: Int = 7337, initial: Settings = Settings(),
                     inspector: FakeInspector = FakeInspector(),
                     catalog: CatalogService? = nil) async throws -> Env {
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
               handlers: Handlers(coord: coord, auth: auth, gatewayPort: nil, settings: service,
                                  catalog: catalog, inspect: inspector.inspect),
               inspector: inspector)
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

// MARK: - Onboarding: preview, hold, confirm

private struct ImportEnv {
    let root: URL
    let library: Store
    let cursor: CursorAdapter
    let claude: ClaudeCodeAdapter
    let settings: SettingsStore
    let handlers: Handlers
}

/// Two real JSON adapters over temporary files, and a daemon holding its first import.
private func makeImportEnv(importConfirmed: Bool = false) async throws -> ImportEnv {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-i-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("cursor"), withIntermediateDirectories: true)
    let cursor = CursorAdapter(configPath: root.appendingPathComponent("cursor/mcp.json"))
    let claude = ClaudeCodeAdapter(configPath: root.appendingPathComponent("claude.json"))
    let library = Store(url: root.appendingPathComponent("servers.json"))
    let coord = SyncCoordinator(store: library, adapters: [cursor, claude],
                                backups: BackupStore(root: root.appendingPathComponent("backups")),
                                gatewayPort: 7337, readOnly: !importConfirmed)
    let auth = AuthManager(store: FileTokenStore(url: root.appendingPathComponent("tokens.json")),
                           oauth: OAuthClient(http: OfflineHTTP()),
                           redirectURI: GatewayConfig(port: 7337).redirectURI())
    let settings = SettingsStore(url: root.appendingPathComponent("settings.json"))
    let service = SettingsService(store: settings, initial: Settings(importConfirmed: importConfirmed),
                                  runningPort: 7337)
    return ImportEnv(root: root, library: library, cursor: cursor, claude: claude, settings: settings,
                     handlers: Handlers(coord: coord, auth: auth, gatewayPort: nil, settings: service))
}

/// The two clients describe "shared" differently. Claude Code sorts first, so its shape wins and
/// Cursor's file is the one that would be rewritten — the exact thing the user has to be shown.
private func writeConflictingConfigs(_ e: ImportEnv) throws {
    try Data(#"{"mcpServers":{"shared":{"command":"claude-version"},"only-claude":{"command":"c"}}}"#.utf8)
        .write(to: e.claude.configPath)
    try Data(#"{"mcpServers":{"shared":{"command":"cursor-version"}}}"#.utf8)
        .write(to: e.cursor.configPath)
}

private func preview(_ handlers: Handlers) async throws -> SyncPreview {
    guard case .syncPreview(let p) = try await handlers.handle(ControlRequest(id: 1, command: .syncPreview)) else {
        throw HandlerError.invalid("expected a preview")
    }
    return p
}

@Test func anUnconfirmedDaemonReportsItAndImportsNothing() async throws {
    let e = try await makeImportEnv()
    let before = try Data(#"{"mcpServers":{"a":{"command":"x"}}}"#.utf8)
    try before.write(to: e.cursor.configPath)
    try await e.handlers.coord.runOnce()

    let status = await e.handlers.status()
    #expect(status.importConfirmed == false)
    #expect(status.servers.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: e.library.url.path))
    #expect(try Data(contentsOf: e.cursor.configPath) == before)
}

@Test func thePreviewNamesEveryServerItWouldAdoptAndTheClientsItFoundThemIn() async throws {
    let e = try await makeImportEnv()
    try writeConflictingConfigs(e)

    let p = try await preview(e.handlers)
    #expect(p.adopted.map(\.name) == ["only-claude", "shared"])
    #expect(p.adopted.first { $0.name == "only-claude" }?.clients == [.claudeCode])
    // One library entry, found in both files.
    #expect(p.adopted.first { $0.name == "shared" }?.clients == [.claudeCode, .cursor])
    #expect(p.adopted.allSatisfy { $0.kind == .stdio })
}

/// The gap the whole feature exists to close: without a preview, this rewrite happens on first run
/// with nobody told about it.
@Test func thePreviewReportsTheConfigRewriteACollisionWouldCause() async throws {
    let e = try await makeImportEnv()
    try writeConflictingConfigs(e)

    let p = try await preview(e.handlers)
    // Claude Code's own file already says what the library would say, so it is left alone.
    #expect(p.writes.map(\.client) == [.cursor])
    let write = try #require(p.writes.first)
    #expect(write.changes == ["shared"])
    // A first import spreads nothing: every server keeps the clients it was found in, so
    // "only-claude" does not appear in Cursor's file and a rewrite is the only thing on offer.
    #expect(write.adds.isEmpty)
    #expect(write.removes.isEmpty)
}

/// The same server under two names is matched by URL and collapses to one library entry, which
/// means one client's entry is renamed — it disappears under the name that client gave it and
/// reappears under the other's. Worth naming as an add and a remove rather than a "change".
@Test func aPreviewNamesAnEntryARenameWouldDropAndTheOneItWouldAdd() async throws {
    let e = try await makeImportEnv()
    try Data(#"{"mcpServers":{"notion":{"url":"https://mcp.notion.com/mcp"}}}"#.utf8)
        .write(to: e.claude.configPath)
    try Data(#"{"mcpServers":{"notion-mcp":{"url":"https://mcp.notion.com/mcp"}}}"#.utf8)
        .write(to: e.cursor.configPath)

    let p = try await preview(e.handlers)
    #expect(p.adopted.map(\.name) == ["notion"])
    let write = try #require(p.writes.first { $0.client == .cursor })
    #expect(write.adds == ["notion"])
    #expect(write.removes == ["notion-mcp"])
    #expect(write.changes.isEmpty)
}

/// Nothing to report is a thing the sheet says out loud, so it has to be distinguishable from a
/// preview that failed.
@Test func aPreviewOfMatchingConfigsListsNoWrites() async throws {
    let e = try await makeImportEnv()
    let same = #"{"mcpServers":{"shared":{"command":"same"}}}"#
    try Data(same.utf8).write(to: e.claude.configPath)
    try Data(same.utf8).write(to: e.cursor.configPath)

    let p = try await preview(e.handlers)
    #expect(p.adopted.map(\.name) == ["shared"])
    #expect(p.writes.isEmpty)
}

@Test func askingForAPreviewTwiceStillChangesNothing() async throws {
    let e = try await makeImportEnv()
    try writeConflictingConfigs(e)
    let cursorBefore = try Data(contentsOf: e.cursor.configPath)

    #expect(try await preview(e.handlers) == (try await preview(e.handlers)))
    #expect(try Data(contentsOf: e.cursor.configPath) == cursorBefore)
    #expect(!FileManager.default.fileExists(atPath: e.library.url.path))
}

@Test func confirmingTheImportPerformsItAndRecordsTheAnswer() async throws {
    let e = try await makeImportEnv()
    try writeConflictingConfigs(e)

    #expect(try await e.handlers.handle(ControlRequest(id: 1, command: .confirmImport)) == .ack)

    let status = await e.handlers.status()
    #expect(status.importConfirmed)
    #expect(status.servers.map(\.server.name).sorted() == ["only-claude", "shared"])
    #expect(try e.library.load().servers.count == 2)
    // The rewrite the preview promised, now that it has been agreed to.
    let cursor = try String(contentsOf: e.cursor.configPath, encoding: .utf8)
    #expect(cursor.contains("claude-version"))
    #expect(!cursor.contains("cursor-version"))
    // And a restart must not ask again.
    #expect(try e.settings.load().importConfirmed)
}

/// A held daemon is not a broken one: it answers, it just refuses to write. The refusal has to say
/// why, since the app puts it in front of the user.
@Test func aHeldDaemonRefusesMutationsWithAReasonAndAcceptsThemAfterConfirming() async throws {
    let e = try await makeImportEnv()
    try Data(#"{"mcpServers":{}}"#.utf8).write(to: e.cursor.configPath)
    try await e.handlers.coord.runOnce()

    let add = ControlCommand.addServer(AddServerParams(name: "acme", kind: .remote,
                                                       url: "https://mcp.example.dev/mcp"))
    await #expect(throws: SyncCoordinatorError.readOnly) {
        try await e.handlers.handle(ControlRequest(id: 1, command: add))
    }
    #expect(SyncCoordinatorError.readOnly.description.contains("setup is not finished"))

    _ = try await e.handlers.handle(ControlRequest(id: 2, command: .confirmImport))
    #expect(try await e.handlers.handle(ControlRequest(id: 3, command: add)) == .ack)
    #expect(await e.handlers.status().servers.map(\.id) == ["acme"])
}

/// Confirming twice is what a double-click on Import looks like from here.
@Test func confirmingAnAlreadyConfirmedImportIsHarmless() async throws {
    let e = try await makeImportEnv(importConfirmed: true)
    try Data(#"{"mcpServers":{"a":{"command":"x"}}}"#.utf8).write(to: e.cursor.configPath)

    _ = try await e.handlers.handle(ControlRequest(id: 1, command: .confirmImport))
    _ = try await e.handlers.handle(ControlRequest(id: 2, command: .confirmImport))
    #expect(await e.handlers.status().servers.map(\.id) == ["a"])
    #expect(await e.handlers.status().importConfirmed)
}

// MARK: - Migration

/// The upgrade path: an install running before onboarding existed has a library it did not have to
/// be asked about, and must not come back gated.
@Test func anExistingLibraryCountsAsAnAnsweredImport() async throws {
    let e = try await makeImportEnv()
    try e.library.save(Library(servers: [Server(id: "a", name: "a", kind: .stdio, command: "x",
                                                source: "manual", createdAt: .init())]))

    let migrated = SettingsService.confirmingExistingInstall(Settings(), library: e.library, into: e.settings)
    #expect(migrated.importConfirmed)
    // Written down, so emptying the library later does not re-open the question.
    #expect(try e.settings.load().importConfirmed)
}

@Test func aFreshInstallWithNoLibraryIsStillAsked() async throws {
    let e = try await makeImportEnv()
    let migrated = SettingsService.confirmingExistingInstall(Settings(), library: e.library, into: e.settings)
    #expect(migrated.importConfirmed == false)
    #expect(!FileManager.default.fileExists(atPath: e.settings.url.path))
}

/// An empty library file is a daemon that has run and found nothing, which is not evidence that
/// anyone was ever asked.
@Test func anEmptyLibraryIsNotEvidenceOfAnAnsweredImport() async throws {
    let e = try await makeImportEnv()
    try e.library.save(Library())
    let migrated = SettingsService.confirmingExistingInstall(Settings(), library: e.library, into: e.settings)
    #expect(migrated.importConfirmed == false)
}

@Test func migrationLeavesAnAlreadyConfirmedSettingAlone() async throws {
    let e = try await makeImportEnv()
    let settings = Settings(gatewayPort: 8080, importConfirmed: true)
    #expect(SettingsService.confirmingExistingInstall(settings, library: e.library, into: e.settings) == settings)
}

/// A settings file that did not parse must not be replaced by one the migration invented: the
/// store throws on a corrupt file precisely so a hand-edited typo survives to be fixed.
@Test func migrationDoesNotOverwriteASettingsFileItCouldNotRead() async throws {
    let e = try await makeImportEnv()
    let corrupt = Data("{ gatewayPort: 8O80".utf8)
    try corrupt.write(to: e.settings.url)
    try e.library.save(Library(servers: [Server(id: "a", name: "a", kind: .stdio, command: "x",
                                                source: "manual", createdAt: .init())]))

    let migrated = SettingsService.confirmingExistingInstall(Settings(), library: e.library,
                                                             into: e.settings, persist: false)
    // The install is still not gated…
    #expect(migrated.importConfirmed)
    // …and the file the user has to repair is still there to repair.
    #expect(try Data(contentsOf: e.settings.url) == corrupt)
}

// MARK: - Inspecting a URL on the way in

private func inspection(_ verdict: GatewayInspection.Verdict, transport: Transport? = nil,
                        authRequired: Bool = false, authKind: AuthKind = .none,
                        suggestion: String? = nil, detail: String = "") -> GatewayInspection {
    GatewayInspection(verdict: verdict, transport: transport, authRequired: authRequired,
                  authKind: authKind, suggestion: suggestion.flatMap(URL.init(string:)), detail: detail)
}

/// The bug this came from: the PostHog docs page pasted into the Add sheet, added, and dead.
@Test func aURLThatIsNotAnEndpointIsRefusedAndTheAlternativeIsNamed() async throws {
    let inspector = FakeInspector()
    inspector.answer("https://posthog.com/docs/model-context-protocol",
                     with: inspection(.notMCP, suggestion: "https://mcp.posthog.com/mcp",
                                      detail: "not an MCP endpoint — answered HTTP 405"))
    let e = try await makeEnv(inspector: inspector)

    let params = AddServerParams(name: "PostHog", kind: .remote,
                                 url: "https://posthog.com/docs/model-context-protocol")
    let failure = await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: .addServer(params)))
    }
    #expect(String(describing: failure).contains("https://mcp.posthog.com/mcp"))
    // Nothing was added, so nothing has to be cleaned up.
    #expect(await e.coord.currentLibrary().servers.isEmpty)
}

@Test func anEndpointThatAsksForASignInIsAddedWithTheAuthKindItAsksFor() async throws {
    let inspector = FakeInspector()
    inspector.answer("https://mcp.posthog.com/mcp",
                     with: inspection(.mcpEndpoint, transport: .http, authRequired: true, authKind: .oauth))
    let e = try await makeEnv(inspector: inspector)

    try await add(AddServerParams(name: "PostHog", kind: .remote, url: "https://mcp.posthog.com/mcp"),
                  to: e.handlers)
    let server = try #require(await e.coord.currentLibrary().server(id: "posthog"))
    #expect(server.auth == .oauth)
    #expect(server.transport == .http)
    #expect(await state(of: "posthog", in: e.handlers) == "needsAuth")
}

@Test func theTransportTheEndpointActuallySpeaksIsRecorded() async throws {
    let inspector = FakeInspector()
    inspector.answer("https://mcp.asana.com/sse",
                     with: inspection(.mcpEndpoint, transport: .sse, authRequired: true, authKind: .oauth))
    let e = try await makeEnv(inspector: inspector)

    try await add(AddServerParams(name: "Asana", kind: .remote, url: "https://mcp.asana.com/sse"),
                  to: e.handlers)
    #expect(await e.coord.currentLibrary().server(id: "asana")?.transport == .sse)
}

/// A pasted `Authorization` header is a decision the endpoint does not get to overrule: it may
/// well advertise OAuth and still accept the token the user already has.
@Test func anAuthKindTheCallerChoseIsNotOverwritten() async throws {
    let inspector = FakeInspector()
    inspector.answer("https://mcp.acme.dev/mcp",
                     with: inspection(.mcpEndpoint, transport: .http, authRequired: true, authKind: .oauth))
    let e = try await makeEnv(inspector: inspector)

    try await add(AddServerParams(name: "Acme", kind: .remote, url: "https://mcp.acme.dev/mcp",
                                  auth: .header, headerName: "X-Api-Key", headerValue: "k"),
                  to: e.handlers)
    #expect(await e.coord.currentLibrary().server(id: "acme")?.auth == .header)
    #expect(try e.store.header(for: "acme")?.value == "k")
}

@Test func anUnreachableURLIsAddedAnyway() async throws {
    let inspector = FakeInspector()
    inspector.answer("https://vpn.internal/mcp", with: inspection(.unreachable, detail: "no route"))
    let e = try await makeEnv(inspector: inspector)

    try await add(AddServerParams(name: "Internal", kind: .remote, url: "https://vpn.internal/mcp"),
                  to: e.handlers)
    #expect(await e.coord.currentLibrary().server(id: "internal")?.auth == AuthKind.none)
}

@Test func autoDetectCanBeTurnedOff() async throws {
    let inspector = FakeInspector()
    let e = try await makeEnv(inspector: inspector)

    try await add(AddServerParams(name: "Acme", kind: .remote, url: "https://mcp.acme.dev/mcp",
                                  auth: .oauth, autoDetectAuth: false), to: e.handlers)
    #expect(inspector.askedURLs.isEmpty)
    #expect(await e.coord.currentLibrary().server(id: "acme")?.auth == .oauth)
}

/// A stdio server has no URL to ask anything of.
@Test func aStdioServerIsNeverInspected() async throws {
    let inspector = FakeInspector()
    let e = try await makeEnv(inspector: inspector)

    try await add(AddServerParams(name: "Fetch", kind: .stdio, command: "uvx", args: ["mcp-server-fetch"]),
                  to: e.handlers)
    #expect(inspector.askedURLs.isEmpty)
}

@Test func inspectURLReportsWhatWasFound() async throws {
    let inspector = FakeInspector()
    inspector.answer("https://posthog.com/docs/model-context-protocol",
                     with: inspection(.notMCP, suggestion: "https://mcp.posthog.com/mcp",
                                      detail: "not an MCP endpoint — answered HTTP 405"))
    let e = try await makeEnv(inspector: inspector)

    let command = ControlCommand.inspectURL(.init(url: "https://posthog.com/docs/model-context-protocol"))
    let result = try await e.handlers.handle(ControlRequest(id: 1, command: command))
    guard case .inspection(let found) = result else { Issue.record("expected an inspection"); return }
    #expect(found.parsedVerdict == .notMCP)
    #expect(found.suggestion == "https://mcp.posthog.com/mcp")
    #expect(found.detail.contains("405"))
}

@Test func somethingThatIsNotAURLIsRejectedBeforeAnythingIsDialled() async throws {
    let e = try await makeEnv()
    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: .inspectURL(.init(url: "not a url"))))
    }
    #expect(e.inspector.askedURLs.isEmpty)
}

// MARK: - The catalog over the wire

@Test func catalogSearchAnswersWithEntries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-cat-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let catalog = CatalogService(bundled: BundledCatalog.entries, http: OfflineHTTP(),
                                 cacheURL: root.appendingPathComponent("catalog-cache.json"))
    let e = try await makeEnv(catalog: catalog)

    let result = try await e.handlers.handle(
        ControlRequest(id: 1, command: .catalogSearch(.init(query: "posthog"))))
    guard case .catalog(let entries) = result else { Issue.record("expected a catalog"); return }
    #expect(entries.first?.slug == "posthog")
    #expect(entries.first?.auth == .oauth)
}

@Test func catalogSearchSaysSoWhenThereIsNoCatalog() async throws {
    let e = try await makeEnv()
    await #expect(throws: HandlerError.self) {
        try await e.handlers.handle(ControlRequest(id: 1, command: .catalogSearch(.init(query: "x"))))
    }
}

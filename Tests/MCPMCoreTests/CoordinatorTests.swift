import Testing
import Foundation
@testable import MCPMCore

private struct Env {
    let root: URL, store: Store, cursor: CursorAdapter, codex: CodexAdapter, coord: SyncCoordinator
}

private func makeEnv() throws -> Env {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-c-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("cursor"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("codex"), withIntermediateDirectories: true)
    let cursor = CursorAdapter(configPath: root.appendingPathComponent("cursor/mcp.json"))
    let codex = CodexAdapter(configPath: root.appendingPathComponent("codex/config.toml"))
    let store = Store(url: root.appendingPathComponent("servers.json"))
    let coord = SyncCoordinator(store: store, adapters: [cursor, codex],
                                backups: BackupStore(root: root.appendingPathComponent("backups")), gatewayPort: 7337)
    return Env(root: root, store: store, cursor: cursor, codex: codex, coord: coord)
}

/// Parses as empty, refuses to render. Stands in for an adapter that chokes on the file it is
/// asked to write.
private struct ExplodingAdapter: ClientAdapter {
    let id = ClientID.claudeDesktop
    let displayName = "Exploding"
    let configPath: URL
    func isInstalled() -> Bool { true }
    func parse(_ data: Data?) throws -> [ExternalServer] { [] }
    func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        throw AdapterError.parse("cannot render")
    }
}

@Test func coordinatorRefusesToMutateWhenTheStoreNeverLoaded() async throws {
    let e = try makeEnv()
    let garbage = Data("{ not json at all".utf8)
    try garbage.write(to: e.store.url)

    await #expect(throws: StoreError.self) { try await e.coord.runOnce() }
    await #expect(throws: SyncCoordinatorError.notLoaded) {
        try await e.coord.mutate { lib in lib.servers.removeAll() }
    }
    // The corrupt library is still there to be recovered, not replaced with an empty one.
    #expect(try Data(contentsOf: e.store.url) == garbage)
    #expect(await e.coord.lastSyncError() != nil)
}

@Test func coordinatorKeepsWritingOtherClientsWhenOneAdapterFailsToRender() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-c-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("cursor"), withIntermediateDirectories: true)
    let cursor = CursorAdapter(configPath: root.appendingPathComponent("cursor/mcp.json"))
    let boom = ExplodingAdapter(configPath: root.appendingPathComponent("boom/config.json"))
    let coord = SyncCoordinator(store: Store(url: root.appendingPathComponent("servers.json")),
                                adapters: [cursor, boom],
                                backups: BackupStore(root: root.appendingPathComponent("backups")), gatewayPort: 7337)
    try Data(#"{"mcpServers":{"a":{"command":"x"}}}"#.utf8).write(to: cursor.configPath)
    _ = try await coord.runOnce()

    try await coord.mutate { lib in
        lib.servers[0].clients[.cursor] = false
        lib.servers[0].clients[.claudeDesktop] = true
    }

    let health = await coord.clientHealth()
    #expect(health[.claudeDesktop]?.healthy == false)
    #expect(await coord.lastSyncError()?.contains("claude-desktop") == true)
    // Cursor's write went through despite the other adapter blowing up in the same pass.
    #expect(health[.cursor]?.healthy == true)
    #expect(try !String(contentsOf: cursor.configPath, encoding: .utf8).contains("\"a\""))
    #expect(!FileManager.default.fileExists(atPath: boom.configPath.path))
}

private actor Counter {
    var count = 0
    var last: SyncCoordinator.Snapshot?
    func bump(_ snapshot: SyncCoordinator.Snapshot? = nil) { count += 1; last = snapshot }
}

@Test func coordinatorNotifiesListenersOnlyWhenTheLibraryChanges() async throws {
    let e = try makeEnv()
    try Data(#"{"mcpServers":{"a":{"command":"x"}}}"#.utf8).write(to: e.cursor.configPath)
    _ = try await e.coord.runOnce()   // adoption happens here, before any listener exists

    let counter = Counter()
    _ = await e.coord.addListener { _ in Task { await counter.bump() } }
    _ = try await e.coord.runOnce()   // steady state → nothing to report
    try await Task.sleep(for: .milliseconds(150))
    #expect(await counter.count == 0)

    try await e.coord.mutate { lib in lib.servers[0].clients[.codex] = true }
    try await Task.sleep(for: .milliseconds(150))
    #expect(await counter.count == 1)
}

@Test func coordinatorNotifiesWhenOnlyClientHealthChanges() async throws {
    let e = try makeEnv()
    try Data(#"{"mcpServers":{"a":{"command":"x"}}}"#.utf8).write(to: e.cursor.configPath)
    _ = try await e.coord.runOnce()
    let libraryBefore = try e.store.load()

    let counter = Counter()
    _ = await e.coord.addListener { snapshot in Task { await counter.bump(snapshot) } }
    // Nothing about the library changes here — codex simply stops being readable.
    try Data("this is = not toml [[[".utf8).write(to: e.codex.configPath)
    _ = try await e.coord.runOnce()
    try await Task.sleep(for: .milliseconds(150))

    #expect(await counter.count == 1)
    #expect(await counter.last?.health[.codex]?.healthy == false)
    #expect(await counter.last?.health[.codex]?.error != nil)
    #expect(try e.store.load() == libraryBefore)
}

@Test func coordinatorHealthCoversOnlyInstalledClients() async throws {
    let e = try makeEnv()
    try Data(#"{"mcpServers":{}}"#.utf8).write(to: e.cursor.configPath)
    _ = try await e.coord.runOnce()
    #expect(await e.coord.clientHealth().keys.sorted() == [.codex, .cursor])
}

@Test func coordinatorImportsThenProjectsToOtherClients() async throws {
    let e = try makeEnv()
    try Data(#"{"mcpServers":{"ctx":{"url":"https://c/mcp"}}}"#.utf8).write(to: e.cursor.configPath)
    _ = try await e.coord.runOnce()
    let lib = try e.store.load()
    #expect(lib.servers.map(\.id) == ["ctx"])
    #expect(lib.servers[0].clients == [.cursor: true])          // adopted → only cursor
    #expect(!FileManager.default.fileExists(atPath: e.codex.configPath.path))   // nothing to write for codex

    try await e.coord.mutate { lib in lib.servers[0].clients[.codex] = true }
    let toml = try String(contentsOf: e.codex.configPath, encoding: .utf8)
    #expect(toml.contains("[mcp_servers.ctx]"))
    let backups = try BackupStore(root: e.root.appendingPathComponent("backups")).list(for: .codex)
    #expect(backups.isEmpty)   // there was no prior file to back up
}

@Test func coordinatorBacksUpBeforeOverwriteAndReportsUnhealthyAdapter() async throws {
    let e = try makeEnv()
    try Data(#"{"mcpServers":{"a":{"command":"x"}}}"#.utf8).write(to: e.cursor.configPath)
    try Data("this is = not toml [[[".utf8).write(to: e.codex.configPath)
    _ = try await e.coord.runOnce()
    let health = await e.coord.clientHealth()
    #expect(health[.codex]?.healthy == false)
    #expect(health[.cursor]?.healthy == true)
    try await e.coord.mutate { lib in lib.servers[0].clients[.cursor] = false }
    #expect(try BackupStore(root: e.root.appendingPathComponent("backups")).list(for: .cursor).count == 1)
    // codex file untouched despite being unhealthy
    #expect(try String(contentsOf: e.codex.configPath, encoding: .utf8) == "this is = not toml [[[")
}

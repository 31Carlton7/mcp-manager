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

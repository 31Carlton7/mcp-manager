import Testing
import Foundation
@testable import MCPMCore

/// A client config file and a backup store beside it, in a directory of their own.
private func makeStore(keep: Int = 5) throws -> (config: URL, store: BackupStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-b-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root.appendingPathComponent("mcp.json"),
            BackupStore(root: root.appendingPathComponent("backups"), keep: keep))
}

@Test func backupKeepsLastFive() throws {
    let (cfg, b) = try makeStore()
    for i in 0..<7 {
        try Data("v\(i)".utf8).write(to: cfg)
        try b.backup(cfg, for: .cursor, at: Date(timeIntervalSince1970: TimeInterval(i)))
    }
    let files = try b.list(for: .cursor)
    #expect(files.count == 5)
    #expect(files.map(\.lastPathComponent) == ["1970-01-01T00-00-06Z.json", "1970-01-01T00-00-05Z.json",
                                                "1970-01-01T00-00-04Z.json", "1970-01-01T00-00-03Z.json",
                                                "1970-01-01T00-00-02Z.json"])
    #expect(try String(contentsOf: files[0], encoding: .utf8) == "v6")
}

@Test func backupOfMissingFileIsNoop() throws {
    let (neverWritten, b) = try makeStore()
    try b.backup(neverWritten, for: .codex, at: .init())
    #expect(try b.list(for: .codex).isEmpty)
}

/// Two backups of the same config in the same second: the second must not overwrite the first.
private func backupTwiceInOneSecond() throws -> BackupStore {
    let (cfg, b) = try makeStore()
    let date = Date(timeIntervalSince1970: 0)
    try Data("v0".utf8).write(to: cfg)
    try b.backup(cfg, for: .cursor, at: date)
    try Data("v1".utf8).write(to: cfg)
    try b.backup(cfg, for: .cursor, at: date)
    return b
}

@Test func backupHandlesSameSecondCollisionWithoutDataLoss() throws {
    let files = try backupTwiceInOneSecond().list(for: .cursor)
    #expect(files.count == 2)
    #expect(Set(files.map(\.lastPathComponent)) == ["1970-01-01T00-00-00Z.json", "1970-01-01T00-00-00Z-2.json"])
    #expect(Set(try files.map { try String(contentsOf: $0, encoding: .utf8) }) == ["v0", "v1"])
}

@Test func backupListIsNewestFirstAcrossSameSecondCollisions() throws {
    // "…00Z-2.json" is the newer one even though it sorts *after* "…00Z.json" by name.
    let files = try backupTwiceInOneSecond().list(for: .cursor)
    #expect(try files.map { try String(contentsOf: $0, encoding: .utf8) } == ["v1", "v0"])
}

@Test func backupFileIsPrivate() throws {
    let (cfg, b) = try makeStore()
    try Data("v0".utf8).write(to: cfg)
    try b.backup(cfg, for: .cursor, at: Date(timeIntervalSince1970: 0))

    let files = try b.list(for: .cursor)
    let perms = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

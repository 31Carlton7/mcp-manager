import Testing
import Foundation
@testable import MCPMCore

@Test func backupKeepsLastFive() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-b-\(UUID().uuidString)")
    let cfg = root.appendingPathComponent("mcp.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let b = BackupStore(root: root.appendingPathComponent("backups"), keep: 5)
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-b-\(UUID().uuidString)")
    let b = BackupStore(root: root, keep: 5)
    try b.backup(root.appendingPathComponent("nope.toml"), for: .codex, at: .init())
    #expect(try b.list(for: .codex).isEmpty)
}

@Test func backupHandlesSameSecondCollisionWithoutDataLoss() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-b-\(UUID().uuidString)")
    let cfg = root.appendingPathComponent("mcp.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let b = BackupStore(root: root.appendingPathComponent("backups"), keep: 5)
    let date = Date(timeIntervalSince1970: 0)

    try Data("v0".utf8).write(to: cfg)
    try b.backup(cfg, for: .cursor, at: date)
    try Data("v1".utf8).write(to: cfg)
    try b.backup(cfg, for: .cursor, at: date)

    let files = try b.list(for: .cursor)
    #expect(files.count == 2)
    #expect(Set(files.map(\.lastPathComponent)) == ["1970-01-01T00-00-00Z.json", "1970-01-01T00-00-00Z-2.json"])
    let contents = Set(try files.map { try String(contentsOf: $0, encoding: .utf8) })
    #expect(contents == ["v0", "v1"])
}

@Test func backupFileIsPrivate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-b-\(UUID().uuidString)")
    let cfg = root.appendingPathComponent("mcp.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("v0".utf8).write(to: cfg)
    let b = BackupStore(root: root.appendingPathComponent("backups"), keep: 5)
    try b.backup(cfg, for: .cursor, at: Date(timeIntervalSince1970: 0))

    let files = try b.list(for: .cursor)
    let perms = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

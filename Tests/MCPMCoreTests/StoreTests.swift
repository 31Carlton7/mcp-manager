import Testing
import Foundation
@testable import MCPMCore

private func tmpDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Test func storeReturnsEmptyLibraryWhenMissing() throws {
    let store = Store(url: try tmpDir().appendingPathComponent("servers.json"))
    #expect(try store.load() == Library())
}

@Test func storeSavesAtomicallyWith0600() throws {
    let url = try tmpDir().appendingPathComponent("servers.json")
    let store = Store(url: url)
    var lib = Library()
    lib.servers.append(Server(id: "a", name: "A", kind: .stdio, command: "x", source: "manual", createdAt: .init()))
    try store.save(lib)
    #expect(try store.load() == lib)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    #expect(!FileManager.default.fileExists(atPath: url.path + ".tmp"))
}

@Test func storeThrowsCorruptOnGarbage() throws {
    let url = try tmpDir().appendingPathComponent("servers.json")
    try Data("{nope".utf8).write(to: url)
    let store = Store(url: url)
    #expect(throws: StoreError.self) { try store.load() }
}

@Test func storeSaveEnforcesModeOnOverwrite() throws {
    let url = try tmpDir().appendingPathComponent("servers.json")
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    let store = Store(url: url)
    try store.save(Library())
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
}

@Test func storeThrowsUnreadableWhenPathIsDirectory() throws {
    let url = try tmpDir().appendingPathComponent("servers.json")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let store = Store(url: url)
    #expect(throws: StoreError.self) { try store.load() }
}

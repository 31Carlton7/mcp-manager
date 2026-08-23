import Testing
import Foundation
@testable import MCPMCore

private func tempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpm-settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func aMissingSettingsFileReadsAsDefaults() throws {
    let store = SettingsStore(url: try tempRoot().appendingPathComponent("settings.json"))
    let s = try store.load()
    #expect(s == Settings())
    #expect(s.gatewayPort == 7337)
    #expect(s.backupRetention == 5)
    // Reading must not create the file: a daemon that only ever reads defaults leaves no trace.
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
}

@Test func settingsRoundTripThroughTheStore() throws {
    let store = SettingsStore(url: try tempRoot().appendingPathComponent("settings.json"))
    try store.save(Settings(gatewayPort: 9001, backupRetention: 12))
    let back = try store.load()
    #expect(back.gatewayPort == 9001)
    #expect(back.backupRetention == 12)
}

/// The file sits next to the token store in `~/.mcpm`; it is not a secret, but nothing in that
/// directory is another user's business either.
@Test func savedSettingsAreOwnerOnly() throws {
    let store = SettingsStore(url: try tempRoot().appendingPathComponent("settings.json"))
    try store.save(Settings())
    let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.int16Value == 0o600)
}

/// A pre-existing file with laxer permissions must not keep them across a save.
@Test func savingOverAWorldReadableFileTightensIt() throws {
    let url = try tempRoot().appendingPathComponent("settings.json")
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    try SettingsStore(url: url).save(Settings(gatewayPort: 8080, backupRetention: 3))
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.int16Value == 0o600)
}

/// Unlike a missing file, a file we cannot parse is not "no settings yet": overwriting it with
/// defaults would throw away a port the user hand-edited and mistyped.
@Test func aCorruptSettingsFileThrows() throws {
    let url = try tempRoot().appendingPathComponent("settings.json")
    try Data("{ not json".utf8).write(to: url)
    #expect(throws: StoreError.self) { try SettingsStore(url: url).load() }
}

/// Fields added in a later release must not make an older file unreadable, and vice versa.
@Test func settingsDecodeFromAFileMissingKeys() throws {
    let url = try tempRoot().appendingPathComponent("settings.json")
    try Data(#"{"gatewayPort":8123}"#.utf8).write(to: url)
    let s = try SettingsStore(url: url).load()
    #expect(s.gatewayPort == 8123)
    #expect(s.backupRetention == 5)
}

/// A fresh install has answered nothing, so the first import is held rather than performed.
@Test func importIsUnconfirmedUntilSomethingSaysOtherwise() throws {
    #expect(Settings().importConfirmed == false)
    let url = try tempRoot().appendingPathComponent("settings.json")
    try Data(#"{"gatewayPort":8123}"#.utf8).write(to: url)
    #expect(try SettingsStore(url: url).load().importConfirmed == false)
}

@Test func importConfirmationSurvivesASaveAndLoad() throws {
    let store = SettingsStore(url: try tempRoot().appendingPathComponent("settings.json"))
    try store.save(Settings(importConfirmed: true))
    #expect(try store.load().importConfirmed)
}

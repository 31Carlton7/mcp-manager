import Foundation
public struct CodexAdapter: ClientAdapter {
    public let id = ClientID.codex
    public let displayName = "Codex"
    public let configPath: URL
    public init(configPath: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")) { self.configPath = configPath }
    public func isInstalled() -> Bool { FileManager.default.fileExists(atPath: configPath.deletingLastPathComponent().path) }
    public func parse(_ data: Data?) throws -> [ExternalServer] { fatalError("Task 6") }
    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data { fatalError("Task 6") }
}

import Foundation

public struct Paths: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mcpm")) {
        self.root = root
    }
    public var library: URL { root.appendingPathComponent("servers.json") }
    public var backups: URL { root.appendingPathComponent("backups") }
    public var socket: URL { root.appendingPathComponent("mcpmd.sock") }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

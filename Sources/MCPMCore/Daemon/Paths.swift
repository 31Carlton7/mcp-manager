import Foundation

/// The home directory every default path hangs off. `homeDirectoryForCurrentUser` reads the
/// password database on macOS and ignores `$HOME`, so it would send a daemon launched against a
/// scratch home straight at the real one — including the client configs it rewrites.
public enum HomeDirectory {
    public static var url: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

public struct Paths: Sendable {
    public let root: URL
    public init(root: URL = HomeDirectory.url.appendingPathComponent(".mcpm")) {
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

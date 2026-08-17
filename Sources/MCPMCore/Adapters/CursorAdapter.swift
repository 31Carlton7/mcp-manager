import Foundation

public struct CursorAdapter: ClientAdapter {
    public let id = ClientID.cursor
    public let displayName = "Cursor"
    public let configPath: URL
    public init(configPath: URL = HomeDirectory.url.appendingPathComponent(".cursor/mcp.json")) {
        self.configPath = configPath
    }
    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: configPath.deletingLastPathComponent().path)
            || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
    }
    public func parse(_ data: Data?) throws -> [ExternalServer] { try JSONMCPServers.parse(data) }
    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        try JSONMCPServers.render(servers, over: data, writeTypeKey: false)
    }
}

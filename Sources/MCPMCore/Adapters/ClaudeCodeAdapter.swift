import Foundation

public struct ClaudeCodeAdapter: ClientAdapter {
    public let id = ClientID.claudeCode
    public let displayName = "Claude Code"
    public let configPath: URL
    public init(configPath: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")) {
        self.configPath = configPath
    }
    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: configPath.path)
            || FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }
    public func parse(_ data: Data?) throws -> [ExternalServer] { try JSONMCPServers.parse(data) }
    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        try JSONMCPServers.render(servers, over: data, writeTypeKey: true)
    }
}

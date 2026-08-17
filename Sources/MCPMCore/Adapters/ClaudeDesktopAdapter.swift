import Foundation

/// Claude Desktop's config is stdio-only; remote servers are bridged with `npx -y mcp-remote <url>`.
public struct ClaudeDesktopAdapter: ClientAdapter {
    public let id = ClientID.claudeDesktop
    public let displayName = "Claude Desktop"
    public let configPath: URL
    public init(configPath: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")) {
        self.configPath = configPath
    }
    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: configPath.path)
    }
    public func parse(_ data: Data?) throws -> [ExternalServer] {
        try JSONMCPServers.parse(data).map { s in
            if s.kind == .stdio, s.command == "npx", s.args.count == 3, s.args[0] == "-y", s.args[1] == "mcp-remote" {
                return ExternalServer(name: s.name, kind: .remote, url: s.args[2])
            }
            return s
        }
    }
    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        let bridged = servers.map { s -> ExternalServer in
            guard s.kind == .remote else { return s }
            return ExternalServer(name: s.name, kind: .stdio, command: "npx", args: ["-y", "mcp-remote", s.url ?? ""])
        }
        return try JSONMCPServers.render(bridged, over: data, writeTypeKey: false)
    }
}

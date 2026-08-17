import Foundation

/// Claude Desktop's config is stdio-only; remote servers are bridged with `npx -y mcp-remote <url>`.
public struct ClaudeDesktopAdapter: ClientAdapter {
    public let id = ClientID.claudeDesktop
    public let displayName = "Claude Desktop"
    public let configPath: URL
    public init(configPath: URL = HomeDirectory.url
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")) {
        self.configPath = configPath
    }
    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: configPath.path)
    }
    public func parse(_ data: Data?) throws -> [ExternalServer] {
        try JSONMCPServers.parse(data).map { s in
            guard s.kind == .stdio, s.command == "npx", s.args.count >= 3,
                  s.args[0] == "-y", s.args[1] == "mcp-remote" else { return s }
            let url = s.args[2]
            var headers: [String: String] = [:]
            var i = 3
            while i < s.args.count {
                guard s.args[i] == "--header", i + 1 < s.args.count,
                      let range = s.args[i + 1].range(of: ": ") else {
                    // unrecognized trailing arg — don't lose it; leave this server as stdio
                    return s
                }
                let pair = s.args[i + 1]
                headers[String(pair[pair.startIndex..<range.lowerBound])] = String(pair[range.upperBound...])
                i += 2
            }
            return ExternalServer(name: s.name, kind: .remote, url: url, headers: headers)
        }
    }
    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        let bridged = try servers.map { s -> ExternalServer in
            guard s.kind == .remote else { return s }
            guard let url = s.url, !url.isEmpty else {
                throw AdapterError.parse("remote server '\(s.name)' has no url")
            }
            var args = ["-y", "mcp-remote", url]
            for key in s.headers.keys.sorted() {
                args.append("--header")
                args.append("\(key): \(s.headers[key]!)")
            }
            return ExternalServer(name: s.name, kind: .stdio, command: "npx", args: args)
        }
        return try JSONMCPServers.render(bridged, over: data, writeTypeKey: false)
    }
}

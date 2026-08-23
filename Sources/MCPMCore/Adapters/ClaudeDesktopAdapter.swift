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
            var transport: Transport?
            var i = 3
            while i < s.args.count {
                guard i + 1 < s.args.count else { return s }
                let value = s.args[i + 1]
                switch s.args[i] {
                case "--header":
                    guard let range = value.range(of: ": ") else { return s }
                    headers[String(value[value.startIndex..<range.lowerBound])] = String(value[range.upperBound...])
                case "--transport":
                    guard let t = Self.transport(fromMcpRemote: value) else { return s }
                    transport = t
                default:
                    // unrecognized trailing arg — don't lose it; leave this server as stdio
                    return s
                }
                i += 2
            }
            return ExternalServer(name: s.name, kind: .remote, url: url, headers: headers, transport: transport)
        }
    }

    /// mcp-remote's `--transport` takes a preference, not just a protocol: `sse-first` means "try
    /// SSE, fall back to HTTP", which is not something this model can hold. Only the two committed
    /// forms round-trip; a preference stays a stdio command line we never rewrite, since writing
    /// it back as `sse-only` would quietly take the fallback away.
    static func transport(fromMcpRemote value: String) -> Transport? {
        switch value {
        case "sse-only": .sse
        case "http-only": Transport.http
        default: nil
        }
    }

    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        let bridged = try servers.map { s -> ExternalServer in
            guard s.kind == .remote else { return s }
            guard let url = s.url, !url.isEmpty else {
                throw AdapterError.parse("remote server '\(s.name)' has no url")
            }
            var args = ["-y", "mcp-remote", url]
            // Claude Desktop itself has no transport key; the bridge is where the choice is made,
            // and `sse-only` rather than `sse-first` because we already know which one this is.
            if s.transport == .sse { args += ["--transport", "sse-only"] }
            for key in s.headers.keys.sorted() {
                args.append("--header")
                args.append("\(key): \(s.headers[key]!)")
            }
            return ExternalServer(name: s.name, kind: .stdio, command: "npx", args: args)
        }
        return try JSONMCPServers.render(bridged, over: data, writeTypeKey: false)
    }
}

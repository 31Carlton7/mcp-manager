import Foundation

/// Turns whatever a user pastes (URL, command line, README JSON) into servers.
public enum SmartPasteParser {
    public struct Result: Equatable, Sendable {
        public var servers: [ExternalServer]
        /// One-line human description of what was detected ("" for empty input).
        public var summary: String

        public init(servers: [ExternalServer], summary: String) {
            self.servers = servers
            self.summary = summary
        }
    }

    public static func parse(_ raw: String) -> Result {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return Result(servers: [], summary: "") }
        if text.hasPrefix("{") || text.hasPrefix("[") { return parseJSON(text) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host {
            return Result(servers: [ExternalServer(name: nameFromHost(host), kind: .remote, url: text)],
                          summary: "Remote server · \(host)")
        }
        let tokens = shellSplit(text)
        guard let command = tokens.first, !command.isEmpty else { return Result(servers: [], summary: "") }
        let args = Array(tokens.dropFirst())
        return Result(servers: [ExternalServer(name: nameFromCommand(command, args: args), kind: .stdio, command: command, args: args)],
                      summary: "Local server · \((command as NSString).lastPathComponent)")
    }

    // MARK: JSON

    static func parseJSON(_ text: String) -> Result {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return Result(servers: [], summary: "Couldn't parse that JSON")
        }
        var servers: [ExternalServer] = []
        if let section = obj["mcpServers"] as? [String: Any] {
            servers = section.compactMap { k, v in (v as? [String: Any]).flatMap { JSONMCPServers.external(name: k, dict: $0) } }
        } else if let one = JSONMCPServers.external(name: "", dict: obj) {
            // bare server object → derive a name
            let name = one.kind == .remote ? nameFromHost(URL(string: one.url ?? "")?.host ?? "server")
                                           : nameFromCommand(one.command ?? "server", args: one.args)
            servers = [ExternalServer(name: name, kind: one.kind, command: one.command, args: one.args, env: one.env, url: one.url, headers: one.headers)]
        } else {
            servers = obj.compactMap { k, v in (v as? [String: Any]).flatMap { JSONMCPServers.external(name: k, dict: $0) } }
        }
        servers.sort { $0.name < $1.name }
        let summary = servers.isEmpty ? "No servers found in that JSON"
                    : servers.count == 1 ? (servers[0].kind == .remote ? "Remote server · \(URL(string: servers[0].url ?? "")?.host ?? "")" : "Local server · \(servers[0].command ?? "")")
                    : "\(servers.count) servers from JSON"
        return Result(servers: servers, summary: summary)
    }

    // MARK: naming

    static func nameFromHost(_ host: String) -> String {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        if parts.first == "www" || parts.first == "mcp" || parts.first == "api" { parts.removeFirst() }
        if parts.count >= 2 { parts.removeLast() }           // drop TLD
        return parts.first ?? host
    }

    /// `npx -y @playwright/mcp@latest` → "playwright-mcp"; `uvx mcp-server-fetch` → "mcp-server-fetch";
    /// else the command's basename.
    static func nameFromCommand(_ command: String, args: [String]) -> String {
        let base = (command as NSString).lastPathComponent
        if ["npx", "uvx", "pipx", "bunx", "pnpx"].contains(base),
           let pkg = args.first(where: { !$0.hasPrefix("-") && $0 != "run" }),
           let name = nameFromPackage(pkg) {
            return name
        }
        return base
    }

    /// Package names that say nothing on their own, so the npm scope stays attached
    /// (`@playwright/mcp` → "playwright-mcp", but `@upstash/context7-mcp` → "context7-mcp").
    static let genericPackageNames: Set<String> = ["mcp", "server", "mcp-server", "cli"]

    /// `@scope/pkg@version` → "pkg" (or "scope-pkg"); `pkg@version` → "pkg".
    static func nameFromPackage(_ raw: String) -> String? {
        var scope: String?
        var p = raw
        if p.hasPrefix("@"), let slash = p.firstIndex(of: "/") {
            scope = String(p[p.index(after: p.startIndex)..<slash])
            p = String(p[p.index(after: slash)...])
        }
        if let at = p.firstIndex(of: "@") { p = String(p[..<at]) }   // drop the version
        if p.isEmpty { return nil }
        if let scope, genericPackageNames.contains(p) { return "\(scope)-\(p)" }
        return p
    }

    /// Minimal POSIX-ish splitter: whitespace separated, honours "double" and 'single' quotes and backslash escapes.
    public static func shellSplit(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inS = false, inD = false, esc = false, has = false
        for ch in s {
            if esc { cur.append(ch); esc = false; continue }
            switch ch {
            case "\\" where !inS: esc = true
            case "'" where !inD: inS.toggle(); has = true
            case "\"" where !inS: inD.toggle(); has = true
            case " ", "\t", "\n":
                if inS || inD { cur.append(ch); has = true }
                else if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            default: cur.append(ch); has = true
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
}

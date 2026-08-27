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
        if let host = remoteHost(text) {
            return Result(servers: [ExternalServer(name: nameFromHost(host), kind: .remote, url: text,
                                                   transport: transportFromPath(text))],
                          summary: "Remote server · \(host)")
        }
        let tokens = shellSplit(text)
        if tokens.count > 3, Array(tokens.prefix(3)) == ["claude", "mcp", "add"] {
            return parseClaudeAdd(Array(tokens.dropFirst(3)))
        }
        guard let command = tokens.first, !command.isEmpty else { return Result(servers: [], summary: "") }
        return commandLine(name: nil, command: command, args: Array(tokens.dropFirst()), env: [:])
    }

    // MARK: command lines

    /// One stdio command line as a server — except when the command is only a bridge to a remote
    /// URL, in which case the URL is the server and the bridge is an implementation detail.
    static func commandLine(name: String?, command: String, args: [String],
                            env: [String: String]) -> Result {
        if let url = bridgedRemoteURL(command: command, args: args), let host = remoteHost(url) {
            return Result(servers: [ExternalServer(name: name ?? nameFromHost(host), kind: .remote, url: url,
                                                   transport: transportFromPath(url))],
                          summary: "Remote server · \(host)")
        }
        let server = ExternalServer(name: name ?? nameFromCommand(command, args: args), kind: .stdio,
                                    command: command, args: args, env: env)
        return Result(servers: [server], summary: "Local server · \((command as NSString).lastPathComponent)")
    }

    static let packageRunners: Set<String> = ["npx", "uvx", "pipx", "bunx", "pnpx"]

    /// `npx -y mcp-remote https://…` is a stdio wrapper around a remote server.
    static func bridgedRemoteURL(command: String, args: [String]) -> String? {
        guard packageRunners.contains((command as NSString).lastPathComponent),
              args.contains(where: { nameFromPackage($0) == "mcp-remote" })
        else { return nil }
        return args.first { remoteHost($0) != nil }
    }

    /// A pasted URL says which transport to dial only through its path: `/sse` is where servers
    /// that still speak the legacy transport put it, by convention every SDK follows. Nothing else
    /// in a bare URL carries that, and dialling Streamable HTTP at an SSE endpoint fails outright.
    /// Only pastes go through here — a client config that meant SSE spells it out with `"type"`.
    static func transportFromPath(_ text: String) -> Transport? {
        guard let path = URL(string: text)?.path.lowercased() else { return nil }
        return path.hasSuffix("/sse") ? .sse : nil
    }

    static func remoteHost(_ text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty
        else { return nil }
        return host
    }

    // MARK: claude mcp add

    /// Flags of `claude mcp add` that take a following value. Scope is read and dropped — which
    /// clients get the server is the sheet's own question.
    static let claudeValueFlags: Set<String> = ["--scope", "-s", "--transport", "-t", "--env", "-e", "--header", "-H"]

    /// `claude mcp add [flags] <name> [--] <url | command…>`, as copy-pasted from a README.
    static func parseClaudeAdd(_ tokens: [String]) -> Result {
        var env: [String: String] = [:], headers: [String: String] = [:]
        var transport: Transport?
        var i = 0

        while i < tokens.count, tokens[i].hasPrefix("-"), tokens[i] != "--" {
            var flag = tokens[i], value: String?
            if let eq = flag.firstIndex(of: "="), flag.hasPrefix("--") {
                value = String(flag[flag.index(after: eq)...])
                flag = String(flag[..<eq])
            }
            if claudeValueFlags.contains(flag), value == nil, i + 1 < tokens.count {
                value = tokens[i + 1]
                i += 1
            }
            switch (flag, value) {
            case ("--env", let v?), ("-e", let v?): if let (k, v) = pair(v, separator: "=") { env[k] = v }
            case ("--header", let v?), ("-H", let v?): if let (k, v) = pair(v, separator: ":") { headers[k] = v }
            // `--transport stdio` says nothing a command line doesn't already say. `http` is kept
            // even though it is the default, so that an explicit choice outranks the guess
            // `transportFromPath` would otherwise make from an `/sse` URL.
            case ("--transport", "sse"), ("-t", "sse"): transport = .sse
            case ("--transport", "http"), ("-t", "http"): transport = .http
            default: break
            }
            i += 1
        }

        guard i < tokens.count, tokens[i] != "--" else {
            return Result(servers: [], summary: "Couldn't read that claude mcp add command")
        }
        let name = tokens[i]
        i += 1
        if i < tokens.count, tokens[i] == "--" { i += 1 }
        let rest = Array(tokens[i...])

        if let first = rest.first, let host = remoteHost(first) {
            return Result(servers: [ExternalServer(name: name, kind: .remote, url: first,
                                                   headers: headers,
                                                   transport: transport ?? transportFromPath(first))],
                          summary: "Remote server · \(host)")
        }
        guard let command = rest.first else {
            return Result(servers: [], summary: "Couldn't read that claude mcp add command")
        }
        return commandLine(name: name, command: command, args: Array(rest.dropFirst()), env: env)
    }

    /// `KEY=value` / `Header: value` → its two halves, split at the first separator only.
    static func pair(_ raw: String, separator: Character) -> (String, String)? {
        guard let index = raw.firstIndex(of: separator) else { return nil }
        let key = String(raw[..<index]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, String(raw[raw.index(after: index)...]).trimmingCharacters(in: .whitespaces))
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
            let name = one.kind == .remote ? nameFromHost(URL(string: one.url ?? "")?.host ?? "server")
                                           : nameFromCommand(one.command ?? "server", args: one.args)
            servers = [ExternalServer(name: name, kind: one.kind, command: one.command, args: one.args,
                                      env: one.env, url: one.url, headers: one.headers,
                                      transport: one.transport)]
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
        if packageRunners.contains(base),
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

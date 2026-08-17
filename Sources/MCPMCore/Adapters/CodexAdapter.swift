import Foundation
import TOMLKit

/// Codex `~/.codex/config.toml`: `[mcp_servers.<name>]` tables (+ optional `[mcp_servers.<name>.env]`).
/// Reads with TOMLKit; writes by text-splicing so comments and unrelated tables survive verbatim.
public struct CodexAdapter: ClientAdapter {
    public let id = ClientID.codex
    public let displayName = "Codex"
    public let configPath: URL

    public init(configPath: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")) {
        self.configPath = configPath
    }

    public func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: configPath.deletingLastPathComponent().path)
    }

    // MARK: parse

    public func parse(_ data: Data?) throws -> [ExternalServer] {
        guard let data, !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let table: TOMLTable
        do { table = try TOMLTable(string: text) } catch { throw AdapterError.parse(String(describing: error)) }
        guard let servers = table["mcp_servers"]?.table else { return [] }
        var out: [ExternalServer] = []
        for (name, value) in servers {
            guard let t = value.table else { continue }
            if let url = t["url"]?.string {
                var headers: [String: String] = [:]
                if let h = t["http_headers"]?.table { for (k, v) in h { if let s = v.string { headers[k] = s } } }
                out.append(ExternalServer(name: name, kind: .remote, url: url, headers: headers))
            } else if let command = t["command"]?.string {
                let args = t["args"]?.array?.compactMap { $0.string } ?? []
                var env: [String: String] = [:]
                if let e = t["env"]?.table { for (k, v) in e { if let s = v.string { env[k] = s } } }
                out.append(ExternalServer(name: name, kind: .stdio, command: command, args: args, env: env))
            }
        }
        return out
    }

    // MARK: render

    /// A contiguous run of lines starting at a `[mcp_servers...]` header.
    /// `name` is `nil` for the bare `[mcp_servers]` header, whose contents we regenerate rather than keep.
    private struct Block { let name: String?; var lines: [String] }

    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let existing = try parse(data)
        if let data, Set(existing) == Set(servers) { return data }
        let existingByName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. split into "other" lines and per-server blocks
        var other: [String] = []
        var blocks: [String: Block] = [:]
        var current: Block? = nil
        func flush() {
            guard let c = current, let name = c.name else { current = nil; return }
            blocks[name, default: Block(name: name, lines: [])].lines += c.lines
            current = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let name = Self.serverName(inHeader: line) {
                flush()
                current = Block(name: name, lines: [line])
            } else if trimmed == "[mcp_servers]" {
                flush()
                current = Block(name: nil, lines: [line])
            } else if trimmed.hasPrefix("["), current != nil {
                // a non-mcp_servers table header ends the block
                flush()
                other.append(line)
            } else if current != nil {
                current!.lines.append(line)
            } else {
                other.append(line)
            }
        }
        flush()

        // 2. untouched blocks stay verbatim, edited ones keep their unmodeled keys, new ones are generated
        var rendered: [String] = []
        for s in servers.sorted(by: { $0.name < $1.name }) {
            if let b = blocks[s.name] {
                if let old = existingByName[s.name], old == s {
                    rendered.append(contentsOf: Self.trimmed(b.lines))
                } else {
                    rendered.append(contentsOf: Self.renderBlock(s, over: b.lines))
                }
            } else {
                rendered.append(contentsOf: Self.renderBlock(s))
            }
            rendered.append("")
        }

        // 3. assemble: other (trimmed of trailing blanks) + blank + rendered
        var out = Self.trimmed(other)
        if !rendered.isEmpty {
            if !out.isEmpty { out.append("") }
            out.append(contentsOf: Self.trimmed(rendered))
        }
        var s = out.joined(separator: "\n")
        if !s.isEmpty && !s.hasSuffix("\n") { s += "\n" }
        return Data(s.utf8)
    }

    /// `[mcp_servers.foo]` or `[mcp_servers.foo.env]` or `[mcp_servers."a b"]` → "foo" / "a b".
    static func serverName(inHeader line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[mcp_servers."), let close = t.firstIndex(of: "]") else { return nil }
        var key = String(t[t.index(t.startIndex, offsetBy: "[mcp_servers.".count)..<close])
        if key.hasPrefix("\"") {
            guard let end = key.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(key[key.index(after: key.startIndex)..<end])
        }
        if let dot = key.firstIndex(of: ".") { key = String(key[..<dot]) }
        return key
    }

    /// Keys this adapter owns: they are rewritten from `ExternalServer`, so old copies are dropped on edit.
    static let modeledKeys: Set<String> = ["command", "args", "env", "url", "http_headers"]

    /// A whole block for a server we have no previous text for.
    static func renderBlock(_ s: ExternalServer) -> [String] {
        shapeLines(s) + envLines(s)
    }

    /// A block for a server whose shape changed: our keys, then every line of the old block we don't own.
    static func renderBlock(_ s: ExternalServer, over old: [String]) -> [String] {
        let kept = preserved(old)
        var lines = shapeLines(s)
        lines += kept.keys
        if !kept.subTables.isEmpty {
            lines.append("")
            lines += kept.subTables
        }
        return lines + envLines(s)
    }

    /// Header plus the keys we model, minus `env` (which is written as a sub-table).
    static func shapeLines(_ s: ExternalServer) -> [String] {
        var lines = ["[mcp_servers.\(key(s.name))]"]
        switch s.kind {
        case .remote:
            lines.append("url = \(str(s.url ?? ""))")
            if !s.headers.isEmpty {
                let pairs = s.headers.keys.sorted().map { "\(str($0)) = \(str(s.headers[$0]!))" }
                lines.append("http_headers = { \(pairs.joined(separator: ", ")) }")
            }
        case .stdio:
            lines.append("command = \(str(s.command ?? ""))")
            lines.append("args = [\(s.args.map(str).joined(separator: ", "))]")
        }
        return lines
    }

    static func envLines(_ s: ExternalServer) -> [String] {
        guard s.kind == .stdio, !s.env.isEmpty else { return [] }
        var lines = ["", "[mcp_servers.\(key(s.name)).env]"]
        for k in s.env.keys.sorted() { lines.append("\(key(k)) = \(str(s.env[k]!))") }
        return lines
    }

    /// Splits an old block into the lines we must not lose: key lines of the main table (minus `modeledKeys`)
    /// and whole sub-tables other than the ones we rewrite (`.env`, `.http_headers`).
    static func preserved(_ lines: [String]) -> (keys: [String], subTables: [String]) {
        enum Region { case main, dropSub, keepSub }
        var region = Region.main
        var keys: [String] = []
        var subTables: [String] = []
        var dropDepth = 0
        for line in lines {
            if let sub = headerSubPath(line) {
                dropDepth = 0
                switch sub {
                case "": region = .main                                 // the block header itself
                case "env", "http_headers": region = .dropSub
                default: region = .keepSub; subTables.append(line)
                }
                continue
            }
            switch region {
            case .main:
                if dropDepth > 0 {                                      // continuation of a dropped value
                    dropDepth = openDepth(line, from: dropDepth)
                } else if let k = topLevelKey(of: line), modeledKeys.contains(k) {
                    dropDepth = openDepth(line, from: 0)
                } else {
                    keys.append(line)
                }
            case .dropSub: continue
            case .keepSub: subTables.append(line)
            }
        }
        return (trimmed(keys), trimmed(subTables))
    }

    /// `[mcp_servers.foo]` → "", `[mcp_servers.foo.env]` → "env"; `nil` if not an `mcp_servers` header.
    static func headerSubPath(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[mcp_servers."), let close = t.firstIndex(of: "]") else { return nil }
        var rest = String(t[t.index(t.startIndex, offsetBy: "[mcp_servers.".count)..<close])
        if rest.hasPrefix("\"") {
            guard let end = rest.dropFirst().firstIndex(of: "\"") else { return nil }
            rest = String(rest[rest.index(after: end)...])
        } else if let dot = rest.firstIndex(of: ".") {
            rest = String(rest[dot...])
        } else {
            rest = ""
        }
        return rest.hasPrefix(".") ? String(rest.dropFirst()) : rest
    }

    /// The key of a `key = value` line, unquoted; `nil` for comments, blanks and anything else.
    static func topLevelKey(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        var k = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
        if k.count >= 2, k.hasPrefix("\""), k.hasSuffix("\"") { k = String(k.dropFirst().dropLast()) }
        return k.isEmpty ? nil : k
    }

    /// Bracket/brace nesting left open at the end of `line`, so multi-line values are dropped whole.
    static func openDepth(_ line: String, from start: Int) -> Int {
        var depth = start, inString = false, escaped = false
        for c in line {
            if escaped { escaped = false; continue }
            if inString {
                if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "[", "{": depth += 1
            case "]", "}": depth = max(0, depth - 1)
            case "#": return depth                                      // comment runs to end of line
            default: break
            }
        }
        return depth
    }

    static func key(_ k: String) -> String {
        k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) ? k : str(k)
    }

    static func str(_ v: String) -> String {
        var o = "\""
        for c in v.unicodeScalars {
            switch c {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            default: o.unicodeScalars.append(c)
            }
        }
        return o + "\""
    }

    static func trimmed(_ lines: [String]) -> [String] {
        var l = lines
        while let last = l.last, last.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        while let first = l.first, first.trimmingCharacters(in: .whitespaces).isEmpty { l.removeFirst() }
        return l
    }
}

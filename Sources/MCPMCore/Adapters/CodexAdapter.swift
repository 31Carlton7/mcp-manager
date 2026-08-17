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
                out.append(ExternalServer(name: name, kind: .remote, url: url))
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

        // 2. keep untouched blocks verbatim, regenerate changed/new ones, drop removed
        var rendered: [String] = []
        for s in servers.sorted(by: { $0.name < $1.name }) {
            if let old = existingByName[s.name], old == s, let b = blocks[s.name] {
                rendered.append(contentsOf: Self.trimmed(b.lines))
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

    static func renderBlock(_ s: ExternalServer) -> [String] {
        var lines = ["[mcp_servers.\(key(s.name))]"]
        switch s.kind {
        case .remote:
            lines.append("url = \(str(s.url ?? ""))")
        case .stdio:
            lines.append("command = \(str(s.command ?? ""))")
            lines.append("args = [\(s.args.map(str).joined(separator: ", "))]")
            if !s.env.isEmpty {
                lines.append("")
                lines.append("[mcp_servers.\(key(s.name)).env]")
                for k in s.env.keys.sorted() { lines.append("\(key(k)) = \(str(s.env[k]!))") }
            }
        }
        return lines
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

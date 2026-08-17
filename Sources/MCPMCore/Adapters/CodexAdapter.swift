import Foundation
import TOMLKit

/// Codex `~/.codex/config.toml`: `[mcp_servers.<name>]` tables (+ optional `[mcp_servers.<name>.env]`).
/// Reads with TOMLKit; writes by text-splicing (see `CodexTOMLSplicer`) so comments, unrelated tables
/// and per-server keys we don't model survive verbatim.
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

    // MARK: - parse

    public func parse(_ data: Data?) throws -> [ExternalServer] {
        guard let data, !data.isEmpty else { return [] }
        let table = try Self.table(String(decoding: data, as: UTF8.self))
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

    // MARK: - render

    public func render(_ servers: [ExternalServer], over data: Data?) throws -> Data {
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let existing = try parse(data)
        if let data, Set(existing) == Set(servers) { return data }
        let existingByName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let split = CodexTOMLSplicer.split(text)
        let wanted = Set(servers.map(\.name))

        var region: [String] = []
        for s in servers.sorted(by: { $0.name < $1.name }) {
            if let block = split.blocks[s.name] {
                if let old = existingByName[s.name], old == s {
                    region += CodexTOMLSplicer.trimmed(block)               // untouched: byte-for-byte
                } else {
                    region += Self.renderBlock(s, over: block)              // edited: keep what we don't model
                }
            } else {
                region += Self.renderBlock(s)
            }
            region.append("")
        }
        // Blocks TOMLKit gave us no server for (no `url`/`command`) are not ours to drop.
        for name in split.order where !wanted.contains(name) && existingByName[name] == nil {
            region += CodexTOMLSplicer.trimmed(split.blocks[name]!)
            region.append("")
        }

        var out = CodexTOMLSplicer.trimmed(split.other)
        if !region.isEmpty {
            if !out.isEmpty { out.append("") }
            out += CodexTOMLSplicer.trimmed(region)
        }
        let nl = CodexTOMLSplicer.terminator(of: text)
        var s = out.joined(separator: nl)
        if !s.isEmpty && !s.hasSuffix(nl) { s += nl }
        try Self.assertValidTOML(s)
        return Data(s.utf8)
    }

    /// A whole block for a server we have no previous text for.
    static func renderBlock(_ s: ExternalServer) -> [String] {
        shapeLines(s) + envLines(s)
    }

    /// A block for a server whose shape changed: our keys, then everything in the old block we don't own.
    static func renderBlock(_ s: ExternalServer, over old: [String]) -> [String] {
        let kept = CodexTOMLSplicer.preserved(old)
        var lines = shapeLines(s) + kept.keys
        if !kept.subTables.isEmpty {
            lines.append("")
            lines += kept.subTables
        }
        return lines + envLines(s)
    }

    /// Header plus the keys we model, except `env` (written as a sub-table so it reads like Codex's own files).
    static func shapeLines(_ s: ExternalServer) -> [String] {
        let key = CodexTOMLSplicer.key, str = CodexTOMLSplicer.str
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
        let key = CodexTOMLSplicer.key, str = CodexTOMLSplicer.str
        var lines = ["", "[mcp_servers.\(key(s.name)).env]"]
        for k in s.env.keys.sorted() { lines.append("\(key(k)) = \(str(s.env[k]!))") }
        return lines
    }

    // MARK: - TOML

    static func table(_ text: String) throws -> TOMLTable {
        do { return try TOMLTable(string: text) } catch { throw AdapterError.parse(String(describing: error)) }
    }

    /// Last line of defence: a splice that produced invalid TOML must never reach the user's config.
    static func assertValidTOML(_ text: String) throws {
        do { _ = try TOMLTable(string: text) } catch {
            throw AdapterError.parse("render produced invalid TOML: \(error)")
        }
    }
}

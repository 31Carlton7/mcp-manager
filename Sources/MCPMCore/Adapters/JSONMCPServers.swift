import Foundation

/// Shared codec for the `{"mcpServers": {...}}` shape used by Claude Code, Claude Desktop and Cursor.
public enum JSONMCPServers {
    public static func parse(_ data: Data?, key: String = "mcpServers") throws -> [ExternalServer] {
        guard let data, !data.isEmpty else { return [] }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw AdapterError.parse(String(describing: error)) }
        guard let obj = root as? [String: Any] else { throw AdapterError.parse("root is not an object") }
        guard let section = obj[key] as? [String: Any] else { return [] }
        return section.compactMap { name, raw in
            guard let d = raw as? [String: Any] else { return nil }
            return external(name: name, dict: d)
        }
    }

    static func external(name: String, dict d: [String: Any]) -> ExternalServer? {
        if let url = d["url"] as? String {
            return ExternalServer(name: name, kind: .remote, url: url,
                                  headers: d["headers"] as? [String: String] ?? [:])
        }
        if let command = d["command"] as? String {
            return ExternalServer(name: name, kind: .stdio, command: command,
                                  args: d["args"] as? [String] ?? [],
                                  env: d["env"] as? [String: String] ?? [:])
        }
        return nil
    }

    /// Merges `servers` into the existing section: keeps unknown fields of servers we keep,
    /// removes servers not in `servers`, adds new ones, and never touches entries we don't
    /// recognize as a server shape. Everything outside `key` is untouched.
    public static func render(_ servers: [ExternalServer], over data: Data?, key: String = "mcpServers",
                              writeTypeKey: Bool) throws -> Data {
        var root: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AdapterError.parse("root is not an object")
            }
            root = obj
        }
        let existing = root[key] as? [String: Any] ?? [:]
        var section: [String: Any] = [:]
        // Never delete entries whose shape we don't understand (not a dict, or neither url nor command).
        for (name, raw) in existing {
            guard let d = raw as? [String: Any] else { section[name] = raw; continue }
            if external(name: name, dict: d) == nil { section[name] = d }
        }
        for s in servers {
            var d = existing[s.name] as? [String: Any] ?? [:]
            let priorType = d["type"] as? String
            // always strip both shapes' keys so a stdio<->remote flip is clean; `type` is re-added below if requested
            for k in ["command", "args", "env", "url", "headers", "type"] { d.removeValue(forKey: k) }
            switch s.kind {
            case .stdio:
                guard let command = s.command, !command.isEmpty else {
                    throw AdapterError.parse("stdio server '\(s.name)' has no command")
                }
                d["command"] = command
                d["args"] = s.args
                d["env"] = s.env
                if writeTypeKey { d["type"] = "stdio" }
            case .remote:
                guard let url = s.url, !url.isEmpty else {
                    throw AdapterError.parse("remote server '\(s.name)' has no url")
                }
                d["url"] = url
                // The library has one `remote` kind but clients distinguish http from sse, so
                // whichever the file already had survives a rewrite; only a flip to stdio and
                // back resets it. Otherwise the first write would move an sse server to http.
                if writeTypeKey { d["type"] = priorType == "sse" ? "sse" : "http" }
                if !s.headers.isEmpty { d["headers"] = s.headers }
            }
            section[s.name] = d
        }
        root[key] = section
        do {
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw AdapterError.parse(String(describing: error))
        }
    }
}

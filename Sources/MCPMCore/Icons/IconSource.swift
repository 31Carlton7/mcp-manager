import Foundation

public enum IconSource: Equatable, Sendable {
    case symbol(String)               // SF Symbol name
    case favicon(host: String)        // fetch https://host/favicon.ico (app-side)
    case monogram(String, hue: Int)   // 1–2 letters + background hue 0..<360

    /// Generic, kind-agnostic symbols for well-known reference servers (brand marks come from favicons).
    static let symbols: [String: String] = [
        "filesystem": "folder", "fetch": "arrow.down.doc", "memory": "brain", "playwright": "theatermasks",
        "puppeteer": "theatermasks", "postgres": "cylinder", "sqlite": "cylinder", "git": "arrow.triangle.branch",
        "time": "clock", "sequential-thinking": "list.number", "everything": "sparkles",
    ]

    public static func resolve(name: String, kind: ServerKind, url: String?, command: String?) -> IconSource {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "-")
        if let s = symbol(forKey: key) { return .symbol(s) }
        if kind == .remote, let u = URL(string: url ?? ""), let host = u.host?.lowercased(),
           !(host == "localhost" || host.hasPrefix("127.") || host.hasSuffix(".local")) {
            return .favicon(host: host)
        }
        return .monogram(monogram(for: name), hue: hue(name))
    }

    /// Matches whole words only: `server-filesystem` gets the folder, `github` does not get git's branch.
    static func symbol(forKey key: String) -> String? {
        if let s = symbols[key] { return s }
        for word in key.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }) {
            if let s = symbols[String(word)] { return s }
        }
        return nil
    }

    public static func monogram(for name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }).filter { !$0.isEmpty }
        if words.count >= 2, let a = words[0].first, let b = words[1].first { return String([a, b]).uppercased() }
        return String(name.first.map { String($0) } ?? "?").uppercased()
    }

    public static func hue(_ name: String) -> Int {
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % 360)
    }
}

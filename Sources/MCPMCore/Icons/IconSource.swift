import Foundation

public enum IconSource: Equatable, Sendable {
    case symbol(String)                 // SF Symbol name
    case favicon(hosts: [String])       // ordered candidates, tried in turn (app-side)
    case monogram(String, hue: Int)     // 1–2 letters + background hue 0..<360

    /// Generic, kind-agnostic symbols for reference servers that have no brand behind them.
    static let symbols: [String: String] = [
        "filesystem": "folder", "fetch": "arrow.down.doc", "memory": "brain",
        "time": "clock", "sequential-thinking": "list.number", "everything": "sparkles",
    ]

    /// The site a server belongs to, keyed by a token of its name or of its package. MCP hosts are
    /// nearly always subdomains that serve no icon of their own, and stdio servers have no host at
    /// all, so the brand's own domain is what actually has a favicon.
    public static let brandDomains: [String: String] = [
        "notion": "notion.com", "notionhq": "notion.com",
        "linear": "linear.app", "github": "github.com", "figma": "figma.com",
        "slack": "slack.com", "sentry": "sentry.io", "stripe": "stripe.com",
        "supabase": "supabase.com", "vercel": "vercel.com", "cloudflare": "cloudflare.com",
        "atlassian": "atlassian.com", "jira": "atlassian.com", "confluence": "atlassian.com",
        "asana": "asana.com", "hubspot": "hubspot.com",
        "context7": "context7.com", "exa": "exa.ai", "mobbin": "mobbin.com", "nia": "trynia.ai",
        "playwright": "playwright.dev", "puppeteer": "pptr.dev",
        "postgres": "postgresql.org", "postgresql": "postgresql.org",
        "upstash": "upstash.com", "firecrawl": "firecrawl.dev", "brave": "brave.com",
        "tavily": "tavily.com", "perplexity": "perplexity.ai",
        "openai": "openai.com", "chatgpt": "openai.com", "codex": "openai.com",
        "anthropic": "anthropic.com",
        "google": "google.com", "gdrive": "google.com", "gmail": "google.com",
        "aws": "aws.amazon.com", "azure": "azure.microsoft.com",
        "docker": "docker.com", "kubernetes": "kubernetes.io",
        "neon": "neon.tech", "planetscale": "planetscale.com", "mongodb": "mongodb.com",
        "redis": "redis.io", "sqlite": "sqlite.org", "git": "git-scm.com",
    ]

    public static func resolve(name: String, kind: ServerKind, url: String?, command: String?,
                               args: [String]) -> IconSource {
        if let domain = brandDomain(name: name, args: args) { return .favicon(hosts: [domain]) }
        if let s = symbol(forKey: name.lowercased().replacingOccurrences(of: " ", with: "-")) { return .symbol(s) }
        if kind == .remote, let u = URL(string: url ?? ""), let host = u.host?.lowercased(),
           !(host == "localhost" || host.hasPrefix("127.") || host.hasSuffix(".local")) {
            let root = rootDomain(host)
            return .favicon(hosts: host == root ? [host] : [host, root])
        }
        return .monogram(monogram(for: name), hue: hue(name))
    }

    // MARK: brands

    /// The server's name is the better signal, so it is asked first; the package in `args` covers
    /// the servers people name after the tool ("pw", "docs") rather than after the vendor.
    static func brandDomain(name: String, args: [String]) -> String? {
        for token in tokens(in: name) {
            if let domain = brandDomains[token] { return domain }
        }
        for arg in args where !arg.hasPrefix("-") {
            for token in packageTokens(in: arg) {
                if let domain = brandDomains[token] { return domain }
            }
        }
        return nil
    }

    private static let tokenSeparators: Set<Character> = ["-", "_", ".", " ", "/", "@", ":"]

    static func tokens(in s: String) -> [String] {
        s.lowercased().split(whereSeparator: { tokenSeparators.contains($0) }).map(String.init)
    }

    /// The scope is the publisher and the package is the product, so `@upstash/context7-mcp` is
    /// Context7 rather than Upstash. Reading right of the last slash first says so.
    static func packageTokens(in arg: String) -> [String] {
        guard let slash = arg.lastIndex(of: "/") else { return tokens(in: arg) }
        return tokens(in: String(arg[arg.index(after: slash)...])) + tokens(in: String(arg[..<slash]))
    }

    // MARK: hosts

    /// Second-level domains that are really part of the suffix, so `x.co.uk` keeps three labels.
    static let compoundSecondLevels: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]

    /// `mcp.notion.com` → `notion.com`. The registrable domain is the one that serves an icon.
    public static func rootDomain(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        while labels.count > 2, ["www", "mcp", "api", "app"].contains(labels[0]) { labels.removeFirst() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let keep = compoundSecondLevels.contains(labels[labels.count - 2]) && labels[labels.count - 1].count == 2 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    // MARK: symbols and fallbacks

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

    /// FNV-1a rather than `hashValue`, whose seed changes every process: a monogram that changed
    /// colour on each launch would read as a different server.
    public static func hue(_ name: String) -> Int {
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % 360)
    }
}

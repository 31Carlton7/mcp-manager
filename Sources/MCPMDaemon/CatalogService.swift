import Foundation
import MCPMControl
import MCPMCore
import MCPMGateway

/// The curated list that ships inside the daemon. It is the whole catalog when the network is
/// gone, and the top of it when the network is there.
///
/// `Bundle.module` is deliberately not used: it traps when the resource bundle is missing, and the
/// app embeds `mcpmd` as a bare executable next to its own binary. A missing catalog has to be
/// survivable, so the bundle is looked for by hand and an empty list is the worst case.
public enum BundledCatalog {
    private final class BundleToken {}

    public static let entries: [CatalogEntry] = load()

    struct File: Decodable {
        var version: Int
        var servers: [CatalogEntry]
    }

    static func load() -> [CatalogEntry] {
        guard let url = url(), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.servers
    }

    /// `MCPM_CATALOG` points at a JSON file in the same shape, for a machine that wants its own
    /// list — and for checking a change to the shipped one without a rebuild.
    static func url() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MCPM_CATALOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let bundleName = "mcp-manager_MCPMDaemon.bundle"
        var roots: [URL] = []
        for bundle in [Bundle.main, Bundle(for: BundleToken.self)] + Bundle.allBundles {
            roots.append(bundle.bundleURL)
            if let resources = bundle.resourceURL { roots.append(resources) }
            // A resource bundle sits beside its `.xctest` or `.app`, not inside it.
            roots.append(bundle.bundleURL.deletingLastPathComponent())
        }
        let executableDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "/")
            .deletingLastPathComponent()
        roots.append(executableDirectory)
        // Embedded in the app: `mcpmd` sits in Contents/MacOS and its resource bundle is copied
        // into Contents/Resources, which is where a bundle belongs and where `Bundle.main` does
        // not point when the running executable is not the bundle's own.
        roots.append(executableDirectory.deletingLastPathComponent().appending(path: "Resources"))
        for root in roots {
            for relative in ["\(bundleName)/Resources/catalog.json", "\(bundleName)/catalog.json",
                             "Resources/catalog.json", "catalog.json"] {
                let candidate = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}

// MARK: - The registry's shape

/// What `GET /v0/servers` answers with. Everything past `name` is optional: the registry carries
/// third-party submissions, and one malformed entry must not lose the whole list.
struct RegistryResponse: Decodable {
    var servers: [Item]

    struct Item: Decodable {
        var server: Server
        var meta: Meta?
        enum CodingKeys: String, CodingKey { case server, meta = "_meta" }
    }

    struct Server: Decodable {
        var name: String
        var description: String?
        var version: String?
        var remotes: [Remote]?
        var packages: [Package]?
    }

    struct Remote: Decodable {
        var type: String?
        var url: String
    }

    struct Package: Decodable {
        var registryType: String?
        var identifier: String?
        var version: String?
        var runtimeHint: String?
    }

    struct Meta: Decodable {
        var official: Official?
        enum CodingKeys: String, CodingKey { case official = "io.modelcontextprotocol.registry/official" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Other publishers put their own shapes under `_meta`; only this key is ours to read.
            official = try? c.decodeIfPresent(Official.self, forKey: .official)
        }
    }

    struct Official: Decodable {
        var status: String?
        var isLatest: Bool?
    }
}

// MARK: - Normalization

enum CatalogNormalizer {
    /// Names that say nothing about the server: `com.notion/mcp` is Notion, not "mcp".
    static let genericLeaves: Set<String> = ["mcp", "server", "mcp-server", "server-mcp", "mcp-servers"]

    /// `com.notion/mcp` → `Notion`, `ai.smithery/exa-search` → `exa-search`.
    static func displayName(_ registryName: String) -> String {
        let parts = registryName.split(separator: "/", maxSplits: 1)
        let namespace = String(parts.first ?? "")
        let leaf = parts.count > 1 ? String(parts[1]) : ""
        if !leaf.isEmpty, !genericLeaves.contains(leaf.lowercased()) { return leaf }
        return namespace.split(separator: ".").last.map(String.init) ?? registryName
    }

    /// The namespace read as a domain: `com.notion` → `notion.com`. What makes an entry the
    /// vendor's own rather than someone else's wrapper of it.
    static func namespaceDomain(_ registryName: String) -> String {
        let namespace = String(registryName.split(separator: "/", maxSplits: 1).first ?? "")
        return namespace.split(separator: ".").reversed().joined(separator: ".").lowercased()
    }

    static func isVendorPublished(_ registryName: String, url: String?) -> Bool {
        guard let host = URL(string: url ?? "")?.host?.lowercased() else { return false }
        return IconSource.rootDomain(host) == namespaceDomain(registryName)
    }

    static func transport(_ type: String?) -> Transport {
        (type ?? "").lowercased() == "sse" ? .sse : .http
    }

    /// One registry entry as something the Add sheet could fill itself in from, or nil when there
    /// is nothing here a client on this machine could run: a container image and no more.
    static func entry(_ item: RegistryResponse.Item) -> CatalogEntry? {
        let server = item.server
        // A deleted entry is still served, so that clients can notice it went away.
        if item.meta?.official?.status?.lowercased() == "deleted" { return nil }

        let name = displayName(server.name)
        let common = (slug: Slug.make(server.name), name: name,
                      description: server.description ?? "", version: server.version)

        if let remote = server.remotes?.first, URL(string: remote.url)?.host != nil {
            return CatalogEntry(slug: common.slug, name: common.name, description: common.description,
                                kind: .remote, url: remote.url, transport: transport(remote.type),
                                // Whether it wants a sign-in is the endpoint's to say, and the
                                // daemon asks it on the way in rather than guessing here.
                                auth: .none,
                                iconDomain: URL(string: remote.url)?.host.map(IconSource.rootDomain),
                                source: .registry,
                                official: isVendorPublished(server.name, url: remote.url),
                                verified: false, version: common.version)
        }

        for package in server.packages ?? [] {
            guard let identifier = package.identifier, !identifier.isEmpty else { continue }
            switch (package.runtimeHint ?? "").lowercased() {
            case "npx":
                return CatalogEntry(slug: common.slug, name: common.name, description: common.description,
                                    kind: .stdio, command: "npx", args: ["-y", identifier],
                                    source: .registry, official: false, verified: false,
                                    version: common.version)
            case "uvx":
                return CatalogEntry(slug: common.slug, name: common.name, description: common.description,
                                    kind: .stdio, command: "uvx", args: [identifier],
                                    source: .registry, official: false, verified: false,
                                    version: common.version)
            default:
                continue   // docker and friends: nothing we can hand a client as a command
            }
        }
        return nil
    }

    /// Registry search returns every published version of a server. Only the newest is worth
    /// showing, and `isLatest` is not always set.
    static func normalize(_ response: RegistryResponse) -> [CatalogEntry] {
        var best: [String: (item: RegistryResponse.Item, entry: CatalogEntry)] = [:]
        var order: [String] = []
        for item in response.servers {
            guard let entry = entry(item) else { continue }
            let key = item.server.name.lowercased()
            guard let existing = best[key] else {
                best[key] = (item, entry)
                order.append(key)
                continue
            }
            if item.meta?.official?.isLatest == true
                || isNewer(item.server.version, than: existing.item.server.version) {
                best[key] = (item, entry)
            }
        }
        return order.compactMap { best[$0]?.entry }
    }

    /// Version comparison for strings the registry does not promise anything about. Numeric
    /// components compare as numbers, and a component with no leading digit — `v1.2`, `main`,
    /// `latest` — sorts below every numbered one, which is why this is not just
    /// `compare(options: .numeric)`: that ranks `main` above `9.0.0`.
    static func isNewer(_ lhs: String?, than rhs: String?) -> Bool {
        guard let lhs else { return false }
        guard let rhs else { return true }
        let a = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) }
        let b = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : nil
            let y = i < b.count ? b[i] : nil
            guard let x, let y else { return (x ?? -1) > (y ?? -1) }
            if x != y { return x > y }
        }
        return lhs.compare(rhs, options: .numeric) == .orderedDescending
    }

    /// Vendor entries above wrappers, and alphabetical within each — the registry's own order is
    /// publication order, which puts whoever submitted last on top. The slug breaks a tie between
    /// two entries that display the same name, so the order is total and the same every time.
    static func ranked(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.sorted { a, b in
            if a.official != b.official { return a.official }
            let (x, y) = (a.name.lowercased(), b.name.lowercased())
            return x == y ? a.slug < b.slug : x < y
        }
    }

    static func normalizedURL(_ raw: String?) -> String? {
        guard var url = raw?.lowercased() else { return nil }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// Registry entries that the curated list already covers, dropped. The curated one carries a
    /// checked URL and the right auth kind; the registry's copy of it carries neither.
    static func removing(_ curated: [CatalogEntry], from entries: [CatalogEntry]) -> [CatalogEntry] {
        let urls = Set(curated.compactMap { normalizedURL($0.url) })
        let names = Set(curated.map(\.slug))
        return entries.filter { entry in
            if let url = normalizedURL(entry.url), urls.contains(url) { return false }
            return !names.contains(Slug.make(entry.name))
        }
    }

    static func score(_ entry: CatalogEntry, query: String) -> Int {
        let name = entry.name.lowercased()
        if entry.slug == query || name == query { return 0 }
        if entry.slug.hasPrefix(query) || name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        return 3
    }

    static func matching(_ entries: [CatalogEntry], query: String) -> [CatalogEntry] {
        guard !query.isEmpty else { return entries.sorted { $0.name < $1.name } }
        let q = query.lowercased()
        return entries.filter { entry in
            entry.slug.contains(q) || entry.name.lowercased().contains(q)
                || entry.description.lowercased().contains(q)
                || (entry.command?.lowercased().contains(q) ?? false)
                || entry.args.contains { $0.lowercased().contains(q) }
        }.sorted {
            (score($0, query: q), $0.name) < (score($1, query: q), $1.name)
        }
    }
}

// MARK: - The service

/// Curated first, registry after, and a day's worth of cache in between.
public actor CatalogService {
    /// A day: the registry is a list of things that exist, and things stop existing slowly.
    public static let cacheLifetime: TimeInterval = 24 * 60 * 60
    /// Enough to cover a session's worth of typing without the cache file growing without bound.
    static let cachedQueryLimit = 50
    public static let defaultRegistry = URL(string: "https://registry.modelcontextprotocol.io/v0/servers")!

    private let bundled: [CatalogEntry]
    private let http: any HTTPClient
    private let cacheURL: URL
    private let registry: URL
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: Cache?

    public init(bundled: [CatalogEntry] = BundledCatalog.entries,
                http: any HTTPClient = URLSessionHTTPClient(timeout: 10),
                cacheURL: URL, registry: URL = CatalogService.defaultRegistry,
                lifetime: TimeInterval = CatalogService.cacheLifetime,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.bundled = bundled
        self.http = http
        self.cacheURL = cacheURL
        self.registry = registry
        self.lifetime = lifetime
        self.now = now
    }

    struct Cache: Codable {
        var version = 1
        var queries: [String: Query] = [:]
        struct Query: Codable {
            var fetchedAt: Date
            var entries: [CatalogEntry]
        }
    }

    /// An empty query is the curated list; anything else is the curated matches followed by
    /// whatever the registry knows that they do not already cover.
    public func search(query: String, limit: Int = 30) async -> [CatalogEntry] {
        // `prefix` traps on a negative length, and a caller is not the one who decides how much of
        // this daemon's memory a search gets to use.
        let limit = CatalogSearchParams.clamp(limit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let curated = CatalogNormalizer.matching(bundled, query: trimmed)
        guard !trimmed.isEmpty else { return Array(curated.prefix(limit)) }
        let found = await registryEntries(for: trimmed)
        return Array((curated + CatalogNormalizer.ranked(
            CatalogNormalizer.removing(bundled, from: found))).prefix(limit))
    }

    private func registryEntries(for query: String) async -> [CatalogEntry] {
        let key = query.lowercased()
        var cache = loadCache()
        if let hit = cache.queries[key], now().timeIntervalSince(hit.fetchedAt) < lifetime {
            return hit.entries
        }
        guard let fresh = try? await fetch(query) else {
            // A stale answer beats no answer: the alternative is a search box that empties itself
            // the moment the network hiccups.
            return cache.queries[key]?.entries ?? []
        }
        cache.queries[key] = Cache.Query(fetchedAt: now(), entries: fresh)
        if cache.queries.count > Self.cachedQueryLimit {
            let oldest = cache.queries.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(cache.queries.count - Self.cachedQueryLimit)
            for (key, _) in oldest { cache.queries.removeValue(forKey: key) }
        }
        save(cache)
        return fresh
    }

    private func fetch(_ query: String) async throws -> [CatalogEntry] {
        var components = URLComponents(url: registry, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "search", value: query),
                                  URLQueryItem(name: "limit", value: "30")]
        guard let url = components?.url else { throw HandlerError.invalid("bad registry URL") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw HandlerError.invalid("the registry answered HTTP \(response.statusCode)")
        }
        return CatalogNormalizer.normalize(try JSONDecoder().decode(RegistryResponse.self, from: data))
    }

    // MARK: cache file

    private func loadCache() -> Cache {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONDecoder.mcpm.decode(Cache.self, from: $0) } ?? Cache()
        cache = loaded
        return loaded
    }

    /// Best effort. A catalog that cannot write its cache is a catalog that asks again next time,
    /// which is not worth failing a search over. Written 0600 like everything else under
    /// `~/.mcpm`: what someone searched for is theirs.
    private func save(_ next: Cache) {
        cache = next
        guard let data = try? JSONEncoder.mcpm.encode(next) else { return }
        try? AtomicFile.write(data, to: cacheURL, mode: 0o600)
    }
}

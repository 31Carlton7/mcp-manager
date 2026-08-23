import Testing
import Foundation
import MCPMControl
import MCPMCore
import MCPMGateway
@testable import MCPMDaemon

/// Answers one canned body, and counts how many times it was asked.
private final class StubRegistry: HTTPClient, @unchecked Sendable {
    struct Offline: Error {}

    private let lock = NSLock()
    private var body: String?
    private(set) var calls: [URL] = []

    init(json: String?) { self.body = json }

    var callCount: Int { lock.withLock { calls.count } }
    var lastURL: URL? { lock.withLock { calls.last } }

    func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { if let url = req.url { calls.append(url) } }
        guard let body = lock.withLock({ self.body }) else { throw Offline() }
        let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

/// The shapes that actually come back from `registry.modelcontextprotocol.io`: a vendor entry with
/// a remote, the same entry at an older version, a third-party wrapper of it, an npx package, a
/// uvx package, and a container image that no client here could run.
private let registryJSON = """
{"servers":[
  {"server":{"name":"io.github.mcparmory/notion","description":"Notion, wrapped","version":"0.4.0",
             "remotes":[{"type":"streamable-http","url":"https://notion-proxy.fly.dev/mcp"}]}},
  {"server":{"name":"com.notion/mcp","description":"Official Notion MCP","version":"1.0.0",
             "remotes":[{"type":"streamable-http","url":"https://mcp.notion.com/mcp"}]},
   "_meta":{"io.modelcontextprotocol.registry/official":{"status":"active","isLatest":false}}},
  {"server":{"name":"com.notion/mcp","description":"Official Notion MCP","version":"1.2.0",
             "remotes":[{"type":"streamable-http","url":"https://mcp.notion.com/mcp"}]},
   "_meta":{"io.modelcontextprotocol.registry/official":{"status":"active","isLatest":true}}},
  {"server":{"name":"io.github.acme/notion-tools","description":"Notion helpers","version":"2.1.0",
             "packages":[{"registryType":"npm","identifier":"@acme/notion-tools","version":"2.1.0",
                          "runtimeHint":"npx","transport":{"type":"stdio"}}]}},
  {"server":{"name":"dev.tooling/notion-py","description":"Notion in python","version":"0.2.0",
             "packages":[{"registryType":"pypi","identifier":"notion-mcp","version":"0.2.0",
                          "runtimeHint":"uvx","transport":{"type":"stdio"}}]}},
  {"server":{"name":"com.containers/notion-oci","description":"Notion in a box","version":"1.0.0",
             "packages":[{"registryType":"oci","identifier":"ghcr.io/x/notion","version":"1.0.0"}]}},
  {"server":{"name":"com.gone/notion-old","description":"Withdrawn","version":"1.0.0",
             "remotes":[{"type":"sse","url":"https://gone.example/sse"}]},
   "_meta":{"io.modelcontextprotocol.registry/official":{"status":"deleted","isLatest":true}}}
]}
"""

private func tmpCache() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcpm-catalog-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("catalog-cache.json")
}

private let curated = [
    CatalogEntry(slug: "notion", name: "Notion", description: "Notion pages and databases",
                 kind: .remote, url: "https://mcp.notion.com/mcp", transport: .http, auth: .oauth),
    CatalogEntry(slug: "posthog", name: "PostHog", description: "Product analytics",
                 kind: .remote, url: "https://mcp.posthog.com/mcp", transport: .http, auth: .oauth),
]

// MARK: - The list that ships with the daemon

@Test func theBundledCatalogLoadsAndIsWellFormed() throws {
    let entries = BundledCatalog.entries
    #expect(entries.count >= 25)
    #expect(Set(entries.map(\.slug)).count == entries.count)
    for entry in entries {
        #expect(!entry.name.isEmpty)
        #expect(!entry.description.isEmpty)
        switch entry.kind {
        case .remote:
            let url = try #require(URL(string: entry.url ?? ""))
            #expect(url.scheme == "https")
        case .stdio:
            #expect(entry.command?.isEmpty == false)
            #expect(entry.auth == AuthKind.none)   // a stdio server has no gateway hop to authenticate
        }
    }
    let posthog = try #require(entries.first { $0.slug == "posthog" })
    #expect(posthog.url == "https://mcp.posthog.com/mcp")
    #expect(posthog.auth == .oauth)
}

@Test func anEmptyQueryIsTheCuratedListAndNeverTheNetwork() async {
    let registry = StubRegistry(json: registryJSON)
    let service = CatalogService(bundled: curated, http: registry, cacheURL: tmpCache())

    let results = await service.search(query: "  ")
    #expect(results.map(\.slug) == ["notion", "posthog"])
    #expect(results.allSatisfy { $0.source == .bundled })
    #expect(registry.callCount == 0)
}

@Test func aCuratedEntryComesBeforeAnythingTheRegistryKnows() async {
    let registry = StubRegistry(json: registryJSON)
    let service = CatalogService(bundled: curated, http: registry, cacheURL: tmpCache())

    let results = await service.search(query: "notion")
    #expect(results.first?.slug == "notion")
    #expect(results.first?.source == .bundled)
    #expect(results.first?.auth == .oauth)
    #expect(registry.lastURL?.query?.contains("search=notion") == true)
}

// MARK: - Normalizing the registry

@Test func aRemoteIsPreferredAndAPackageIsTheFallback() async {
    let registry = StubRegistry(json: registryJSON)
    let service = CatalogService(bundled: [], http: registry, cacheURL: tmpCache())

    let results = await service.search(query: "notion")
    let bySlug = Dictionary(results.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })

    let vendor = bySlug["com-notion-mcp"]
    #expect(vendor?.kind == .remote)
    #expect(vendor?.url == "https://mcp.notion.com/mcp")
    #expect(vendor?.transport == .http)
    #expect(vendor?.name == "notion")
    #expect(vendor?.source == .registry)

    let npm = bySlug["io-github-acme-notion-tools"]
    #expect(npm?.kind == .stdio)
    #expect(npm?.command == "npx")
    #expect(npm?.args == ["-y", "@acme/notion-tools"])

    let pypi = bySlug["dev-tooling-notion-py"]
    #expect(pypi?.command == "uvx")
    #expect(pypi?.args == ["notion-mcp"])

    // An image is not something any client on this machine can be pointed at, and a withdrawn
    // entry is not something to offer at all.
    #expect(bySlug["com-containers-notion-oci"] == nil)
    #expect(bySlug["com-gone-notion-old"] == nil)
}

@Test func onlyTheNewestVersionOfAServerSurvives() async {
    let registry = StubRegistry(json: registryJSON)
    let service = CatalogService(bundled: [], http: registry, cacheURL: tmpCache())

    let results = await service.search(query: "notion")
    let notion = results.filter { $0.slug == "com-notion-mcp" }
    #expect(notion.count == 1)
    #expect(notion.first?.version == "1.2.0")
}

@Test func theVendorsOwnEntryOutranksSomeoneElsesWrapperOfIt() async {
    let registry = StubRegistry(json: registryJSON)
    let service = CatalogService(bundled: [], http: registry, cacheURL: tmpCache())

    let results = await service.search(query: "notion")
    let vendor = try? #require(results.firstIndex { $0.slug == "com-notion-mcp" })
    let wrapper = try? #require(results.firstIndex { $0.slug == "io-github-mcparmory-notion" })
    #expect(vendor! < wrapper!)
    #expect(results.first { $0.slug == "com-notion-mcp" }?.official == true)
    #expect(results.first { $0.slug == "io-github-mcparmory-notion" }?.official == false)
}

@Test func theRegistrysCopyOfACuratedServerIsDropped() async {
    let registry = StubRegistry(json: registryJSON)
    let service = CatalogService(bundled: curated, http: registry, cacheURL: tmpCache())

    let results = await service.search(query: "notion")
    #expect(results.filter { $0.url == "https://mcp.notion.com/mcp" }.count == 1)
    #expect(results.first { $0.url == "https://mcp.notion.com/mcp" }?.source == .bundled)
}

// MARK: - Cache and offline

@Test func theRegistryIsAskedOncePerDay() async {
    let registry = StubRegistry(json: registryJSON)
    let cache = tmpCache()
    let clock = Clock()
    let service = CatalogService(bundled: [], http: registry, cacheURL: cache,
                                 now: { clock.now })

    _ = await service.search(query: "notion")
    _ = await service.search(query: "notion")
    #expect(registry.callCount == 1)
    #expect(FileManager.default.fileExists(atPath: cache.path))

    clock.advance(by: 25 * 60 * 60)
    _ = await service.search(query: "notion")
    #expect(registry.callCount == 2)
}

/// A cache written by an earlier run is read by the next one, so a restart does not cost a
/// round trip to the registry.
@Test func aCacheOnDiskIsReadBackByANewService() async {
    let cache = tmpCache()
    let first = CatalogService(bundled: [], http: StubRegistry(json: registryJSON), cacheURL: cache)
    _ = await first.search(query: "notion")

    let offline = StubRegistry(json: nil)
    let second = CatalogService(bundled: [], http: offline, cacheURL: cache)
    let results = await second.search(query: "notion")
    #expect(results.contains { $0.slug == "com-notion-mcp" })
    #expect(offline.callCount == 0)
}

@Test func offlineFallsBackToTheCuratedListAlone() async {
    let offline = StubRegistry(json: nil)
    let service = CatalogService(bundled: curated, http: offline, cacheURL: tmpCache())

    let results = await service.search(query: "notion")
    #expect(results.map(\.slug) == ["notion"])
    #expect(results.allSatisfy { $0.source == .bundled })
    #expect(offline.callCount == 1)
}

@Test func aStaleCacheIsBetterThanNothingWhenTheRegistryIsDown() async {
    let cache = tmpCache()
    let clock = Clock()
    let warm = CatalogService(bundled: [], http: StubRegistry(json: registryJSON), cacheURL: cache,
                              now: { clock.now })
    _ = await warm.search(query: "notion")

    clock.advance(by: 25 * 60 * 60)
    let offline = CatalogService(bundled: [], http: StubRegistry(json: nil), cacheURL: cache,
                                 now: { clock.now })
    #expect(await offline.search(query: "notion").contains { $0.slug == "com-notion-mcp" })
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(by seconds: TimeInterval) { lock.withLock { date += seconds } }
}

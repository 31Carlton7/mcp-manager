import Testing
import Foundation
@testable import MCPMCore

// MARK: - Model

/// A library written before transport existed has no key. It decodes as nil, which means "never
/// recorded" rather than HTTP — the sync fills it in from the clients.
@Test func serverDecodesWithoutTransportField() throws {
    let s = try JSONDecoder.mcpm.decode(Server.self, from: Data(legacyLibraryServerJSON().utf8))
    #expect(s.transport == nil)
}

/// The JSON a pre-transport release wrote for a remote server: every key but `transport`.
private func legacyLibraryServerJSON(clients: [String] = []) -> String {
    let on = clients.map { "\"\($0)\":true" }.joined(separator: ",")
    return """
    {"id":"a","name":"A","kind":"remote","args":[],"env":{},"url":"https://a/mcp","auth":"none",
    "clients":{\(on)},"source":"manual","createdAt":"2026-08-17T10:00:00Z"}
    """
}

@Test func serverRoundTripsAnSSETransport() throws {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .sse,
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    let data = try JSONEncoder.mcpm.encode(s)
    #expect((try JSONSerialization.jsonObject(with: data) as! [String: Any])["transport"] as? String == "sse")
    #expect(try JSONDecoder.mcpm.decode(Server.self, from: data) == s)
}

/// A library server records HTTP rather than leaving it implicit, so that a missing key can go on
/// meaning "written before transport existed" and nothing else.
@Test func aLibraryServerRecordsHTTPExplicitly() throws {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .http,
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    #expect(s.transport == .http)
    #expect((try JSONSerialization.jsonObject(with: try JSONEncoder.mcpm.encode(s)) as! [String: Any])["transport"] as? String == "http")
}

/// A remote server built in memory always knows its transport; only a legacy file can be silent.
@Test func aRemoteServerDefaultsToHTTPRatherThanToNothing() {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp",
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    #expect(s.transport == .http)
    #expect(Server.imported(ExternalServer(name: "a", kind: .remote, url: "u"), id: "a", from: .cursor,
                            now: Date(timeIntervalSince1970: 0)).transport == .http)
}

/// In a client file there is no such distinction: nil and `.http` are the same server, and two
/// spellings of it would compare unequal and make the sync write for nothing.
@Test func httpIsTheAbsenceOfATransportInAClientFile() {
    #expect(ExternalServer(name: "a", kind: .remote, url: "u", transport: .http).transport == nil)
    #expect(ExternalServer(name: "a", kind: .remote, url: "u", transport: .http)
            == ExternalServer(name: "a", kind: .remote, url: "u"))
    // ...and the projection of a recorded `.http` is that same single spelling.
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .http,
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    #expect(s.external(gatewayPort: 7337).transport == nil)
}

/// A transport on a stdio server is meaningless — there is no HTTP connection to make.
@Test func aStdioServerHasNoTransport() {
    #expect(ExternalServer(name: "a", kind: .stdio, command: "x", transport: .sse).transport == nil)
    let s = Server(id: "a", name: "A", kind: .stdio, command: "x", transport: .sse,
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    #expect(s.transport == nil)
}

@Test func externalServerDecodesWithoutTransportField() throws {
    let json = #"{"name":"a","kind":"remote","args":[],"env":{},"url":"u","headers":{}}"#
    #expect(try JSONDecoder.mcpm.decode(ExternalServer.self, from: Data(json.utf8)).transport == nil)
}

// MARK: - Projection

@Test func theGatewayURLProjectionKeepsTheTransport() {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .sse,
                   auth: .oauth, source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    let e = s.external(gatewayPort: 7337)
    #expect(e.url == GatewayURL.make(port: 7337, serverID: "a"))
    // The proxy speaks whatever the upstream does, so the client still has to be told which.
    #expect(e.transport == .sse)
}

@Test func aDirectRemoteProjectionKeepsTheTransport() {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .sse,
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    #expect(s.external(gatewayPort: 7337).transport == .sse)
}

@Test func anImportedServerKeepsTheTransportItWasFoundWith() {
    let e = ExternalServer(name: "a", kind: .remote, url: "u", transport: .sse)
    #expect(Server.imported(e, id: "a", from: .cursor, now: Date(timeIntervalSince1970: 0)).transport == .sse)
}

/// A transport change has to reach the client's file, which means the sync's diff has to see it.
@Test func changingOnlyTheTransportPlansAWrite() {
    let now = Date(timeIntervalSince1970: 0)
    let s = Server(id: "a", name: "a", kind: .remote, url: "https://a/mcp", transport: .sse,
                   clients: [.cursor: true], source: "manual", createdAt: now)
    let stale = [ExternalServer(name: "a", kind: .remote, url: "https://a/mcp")]
    let out = SyncEngine.plan(SyncInput(library: Library(servers: [s]), snapshots: [.cursor: stale],
                                        suppressed: [.cursor], gatewayPort: 7337, now: now))
    #expect(out.writes[.cursor]?.first?.transport == .sse)
}

// MARK: - JSON adapters

@Test func jsonParseReadsTheTypeKeyAsATransport() throws {
    let json = #"{"mcpServers":{"a":{"type":"sse","url":"u"},"b":{"type":"http","url":"u"},"c":{"url":"u"}}}"#
    let byName = Dictionary(uniqueKeysWithValues: try JSONMCPServers.parse(Data(json.utf8)).map { ($0.name, $0) })
    #expect(byName["a"]?.transport == .sse)
    #expect(byName["b"]?.transport == nil)
    #expect(byName["c"]?.transport == nil)
}

@Test func jsonRenderWritesTheTypeKeyFromTheTransport() throws {
    func type(_ s: ExternalServer, writeTypeKey: Bool) throws -> String? {
        let out = try JSONMCPServers.render([s], over: nil, writeTypeKey: writeTypeKey)
        let section = (try JSONSerialization.jsonObject(with: out) as! [String: Any])["mcpServers"] as! [String: Any]
        return (section[s.name] as! [String: Any])["type"] as? String
    }
    #expect(try type(ExternalServer(name: "a", kind: .remote, url: "u", transport: .sse), writeTypeKey: true) == "sse")
    #expect(try type(ExternalServer(name: "a", kind: .remote, url: "u"), writeTypeKey: true) == "http")
    // Cursor writes no `type` of its own, but it does understand "sse" — the only way to say so.
    #expect(try type(ExternalServer(name: "a", kind: .remote, url: "u", transport: .sse), writeTypeKey: false) == "sse")
    #expect(try type(ExternalServer(name: "a", kind: .remote, url: "u"), writeTypeKey: false) == nil)
}

/// The transport in the model wins over whatever the file happens to say: switching a server from
/// SSE to HTTP has to actually move it.
@Test func jsonRenderOverwritesAStaleTypeKey() throws {
    let existing = #"{"mcpServers":{"a":{"type":"sse","url":"u"}}}"#
    let out = try JSONMCPServers.render([ExternalServer(name: "a", kind: .remote, url: "u2")],
                                        over: Data(existing.utf8), writeTypeKey: true)
    let a = ((try JSONSerialization.jsonObject(with: out) as! [String: Any])["mcpServers"] as! [String: Any])["a"] as! [String: Any]
    #expect(a["type"] as! String == "http")
}

@Test func anSSEServerRoundTripsThroughEveryJSONClient() throws {
    let adapters: [any ClientAdapter] = [
        ClaudeCodeAdapter(configPath: URL(fileURLWithPath: "/dev/null")),
        CursorAdapter(configPath: URL(fileURLWithPath: "/dev/null")),
        ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null")),
    ]
    let servers = [ExternalServer(name: "a", kind: .remote, url: "https://a/mcp", transport: .sse)]
    for a in adapters {
        #expect(try a.parse(try a.render(servers, over: nil)) == servers, "\(a.id.rawValue)")
    }
}

// MARK: - Claude Desktop bridge

@Test func claudeDesktopBridgesSSEWithTheMcpRemoteFlag() throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let servers = [ExternalServer(name: "x", kind: .remote, url: "https://x/mcp", headers: ["A": "1"], transport: .sse)]
    let out = try a.render(servers, over: nil)
    let x = ((try JSONSerialization.jsonObject(with: out) as! [String: Any])["mcpServers"] as! [String: Any])["x"] as! [String: Any]
    #expect(x["args"] as! [String] == ["-y", "mcp-remote", "https://x/mcp", "--transport", "sse-only",
                                       "--header", "A: 1"])
    #expect(try a.parse(out) == servers)
}

@Test func claudeDesktopDoesNotWriteATransportFlagForHTTP() throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let out = try a.render([ExternalServer(name: "x", kind: .remote, url: "https://x/mcp")], over: nil)
    let x = ((try JSONSerialization.jsonObject(with: out) as! [String: Any])["mcpServers"] as! [String: Any])["x"] as! [String: Any]
    #expect(x["args"] as! [String] == ["-y", "mcp-remote", "https://x/mcp"])
}

@Test func claudeDesktopReadsAnSSETransportFlagBack() throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let json = """
    {"mcpServers":{"x":{"command":"npx","args":["-y","mcp-remote","https://x","--transport","sse-only"]}}}
    """
    #expect(try a.parse(Data(json.utf8))
            == [ExternalServer(name: "x", kind: .remote, url: "https://x", transport: .sse)])
}

/// `sse-first` means "try SSE, fall back to HTTP" — a preference the model can't hold, so the
/// bridge stays a stdio command line rather than being rewritten as the committed `sse-only`.
@Test(arguments: ["sse-first", "http-first"])
func claudeDesktopLeavesATransportPreferenceAsStdio(value: String) throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let json = """
    {"mcpServers":{"x":{"command":"npx","args":["-y","mcp-remote","https://x","--transport","\(value)"]}}}
    """
    #expect(try a.parse(Data(json.utf8)).first?.kind == .stdio)
}

@Test func claudeDesktopReadsAnHTTPTransportFlagAsTheDefault() throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let json = """
    {"mcpServers":{"x":{"command":"npx","args":["-y","mcp-remote","https://x","--transport","http-only"]}}}
    """
    #expect(try a.parse(Data(json.utf8)) == [ExternalServer(name: "x", kind: .remote, url: "https://x")])
}

/// An mcp-remote transport we don't model is not a bridge we can rewrite without losing it.
@Test func claudeDesktopLeavesAnUnknownTransportFlagAsStdio() throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let json = """
    {"mcpServers":{"x":{"command":"npx","args":["-y","mcp-remote","https://x","--transport","carrier-pigeon"]}}}
    """
    #expect(try a.parse(Data(json.utf8)).first?.kind == .stdio)
}

// MARK: - Codex

/// Codex's remote servers are Streamable HTTP only, so its TOML has nowhere to put a transport.
/// It must not lose track of one set elsewhere, and it must not rewrite the file over it either.
@Test func codexIgnoresTransportRatherThanRewritingItsFile() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let toml = """
    [mcp_servers.x]
    url = "https://x/mcp"

    """
    let data = Data(toml.utf8)
    #expect(try a.parse(data) == [ExternalServer(name: "x", kind: .remote, url: "https://x/mcp")])
    let out = try a.render([ExternalServer(name: "x", kind: .remote, url: "https://x/mcp", transport: .sse)],
                           over: data)
    #expect(out == data)
}

// MARK: - Smart paste

@Test func smartPasteReadsAnSSETypeFromPastedJSON() {
    let one = SmartPasteParser.parse(#"{"type":"sse","url":"https://mcp.example.dev/sse"}"#)
    #expect(one.servers.first?.transport == .sse)

    let section = SmartPasteParser.parse(#"{"mcpServers":{"a":{"type":"sse","url":"https://a.example.dev/sse"}}}"#)
    #expect(section.servers.first?.transport == .sse)
}

@Test func smartPasteReadsTheClaudeAddTransportFlag() {
    #expect(SmartPasteParser.parse("claude mcp add --transport sse acme https://acme.example.dev/sse")
            .servers.first?.transport == .sse)
    #expect(SmartPasteParser.parse("claude mcp add --transport http acme https://acme.example.dev/mcp")
            .servers.first?.transport == nil)
}

// MARK: - Upgrading a pre-transport library

/// The regression this all exists for: before transport was modelled, the library had no key for
/// it, so the first sync after the upgrade projected the default over an SSE server and rewrote
/// the user's client file to HTTP. A silent library must instead learn the transport from the
/// client that still has it on record.
@Test func aPreTransportLibraryAdoptsSSEFromClaudeCodeInsteadOfBeingRewritten() throws {
    let s = try JSONDecoder.mcpm.decode(Server.self, from: Data(legacyLibraryServerJSON(clients: ["claude-code"]).utf8))
    #expect(s.transport == nil)
    let snapshot = try ClaudeCodeAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
        .parse(Data(#"{"mcpServers":{"A":{"type":"sse","url":"https://a/mcp"}}}"#.utf8))
    let out = SyncEngine.plan(SyncInput(library: Library(servers: [s]), snapshots: [.claudeCode: snapshot],
                                        suppressed: [], gatewayPort: 7337, now: Date(timeIntervalSince1970: 0)))
    #expect(out.writes.isEmpty)
    #expect(out.library.server(id: "a")?.transport == .sse)
}

/// Same for Claude Desktop, where the transport lives in the mcp-remote bridge's arguments.
@Test func aPreTransportLibraryAdoptsSSEFromTheClaudeDesktopBridge() throws {
    let s = try JSONDecoder.mcpm.decode(Server.self, from: Data(legacyLibraryServerJSON(clients: ["claude-desktop"]).utf8))
    let json = """
    {"mcpServers":{"A":{"command":"npx","args":["-y","mcp-remote","https://a/mcp","--transport","sse-only"]}}}
    """
    let snapshot = try ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null")).parse(Data(json.utf8))
    let out = SyncEngine.plan(SyncInput(library: Library(servers: [s]), snapshots: [.claudeDesktop: snapshot],
                                        suppressed: [], gatewayPort: 7337, now: Date(timeIntervalSince1970: 0)))
    #expect(out.writes.isEmpty)
    #expect(out.library.server(id: "a")?.transport == .sse)
}

/// A client that says nothing means HTTP, so the backfill settles on that and stops being silent —
/// otherwise the same guess would be made again on every sync.
@Test func aPreTransportLibraryBackfillsHTTPFromASilentClient() throws {
    let s = try JSONDecoder.mcpm.decode(Server.self, from: Data(legacyLibraryServerJSON(clients: ["cursor"]).utf8))
    let out = SyncEngine.plan(SyncInput(library: Library(servers: [s]),
                                        snapshots: [.cursor: [ExternalServer(name: "A", kind: .remote, url: "https://a/mcp")]],
                                        suppressed: [], gatewayPort: 7337, now: Date(timeIntervalSince1970: 0)))
    #expect(out.writes.isEmpty)
    #expect(out.library.server(id: "a")?.transport == .http)
}

/// A recorded `.http` is not silence, it is the user having moved the server off SSE — so it wins
/// over the client and the write goes out.
@Test func anExplicitHTTPLibraryStillRewritesAnSSEClient() {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .http,
                   clients: [.claudeCode: true], source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    let snapshot = [ExternalServer(name: "A", kind: .remote, url: "https://a/mcp", transport: .sse)]
    let out = SyncEngine.plan(SyncInput(library: Library(servers: [s]), snapshots: [.claudeCode: snapshot],
                                        suppressed: [], gatewayPort: 7337, now: Date(timeIntervalSince1970: 0)))
    #expect(out.library.server(id: "a")?.transport == .http)
    #expect(out.writes[.claudeCode]?.first?.transport == nil)
}

import Testing
import Foundation
@testable import MCPMCore

// MARK: - Model

/// A library written before transport existed has no key; that means HTTP, not "undecodable".
@Test func serverDecodesWithoutTransportField() throws {
    let json = """
    {"id":"a","name":"A","kind":"remote","args":[],"env":{},"url":"https://a/mcp","auth":"none",
    "clients":{},"source":"manual","createdAt":"2026-08-17T10:00:00Z"}
    """
    let s = try JSONDecoder.mcpm.decode(Server.self, from: Data(json.utf8))
    #expect(s.transport == nil)
}

@Test func serverRoundTripsAnSSETransport() throws {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .sse,
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    let data = try JSONEncoder.mcpm.encode(s)
    #expect((try JSONSerialization.jsonObject(with: data) as! [String: Any])["transport"] as? String == "sse")
    #expect(try JSONDecoder.mcpm.decode(Server.self, from: data) == s)
}

/// nil and `.http` mean the same thing, so they are stored the same way — otherwise two servers
/// that behave identically would compare unequal and the sync would write for no reason.
@Test func httpIsStoredAsTheAbsenceOfATransport() throws {
    let s = Server(id: "a", name: "A", kind: .remote, url: "https://a/mcp", transport: .http,
                   source: "manual", createdAt: Date(timeIntervalSince1970: 0))
    #expect(s.transport == nil)
    #expect((try JSONSerialization.jsonObject(with: try JSONEncoder.mcpm.encode(s)) as! [String: Any])["transport"] == nil)
    #expect(ExternalServer(name: "a", kind: .remote, url: "u", transport: .http)
            == ExternalServer(name: "a", kind: .remote, url: "u"))
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

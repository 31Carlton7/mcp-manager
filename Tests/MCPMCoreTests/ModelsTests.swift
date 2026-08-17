import Testing
@testable import MCPMCore

@Test func clientIDsAreStableStrings() {
    #expect(ClientID.claudeCode.rawValue == "claude-code")
    #expect(ClientID.claudeDesktop.rawValue == "claude-desktop")
    #expect(ClientID.cursor.rawValue == "cursor")
    #expect(ClientID.codex.rawValue == "codex")
    #expect(ClientID.allCases.count == 4)
}

import Foundation

@Test func serverRoundTripsThroughJSONWithClientMatrixAsObject() throws {
    let s = Server(id: "notion", name: "Notion", kind: .remote, url: "https://mcp.notion.com/mcp",
                   auth: .oauth, clients: [.claudeCode: true, .cursor: false], source: "manual",
                   createdAt: Date(timeIntervalSince1970: 0))
    let data = try JSONEncoder.mcpm.encode(s)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let clients = json["clients"] as! [String: Bool]
    #expect(clients["claude-code"] == true)
    #expect(clients["cursor"] == false)
    #expect(json["createdAt"] as? String == "1970-01-01T00:00:00Z")
    let back = try JSONDecoder.mcpm.decode(Server.self, from: data)
    #expect(back == s)
}

@Test func libraryDecodesSpecExample() throws {
    let json = """
    {"version":1,"servers":[{"id":"playwright","name":"Playwright","kind":"stdio","command":"npx",
    "args":["-y","@playwright/mcp@latest"],"env":{},"auth":"none",
    "clients":{"claude-code":true},"source":"imported:cursor","createdAt":"2026-08-17T10:00:00Z"}]}
    """
    let lib = try JSONDecoder.mcpm.decode(Library.self, from: Data(json.utf8))
    #expect(lib.servers.count == 1)
    #expect(lib.servers[0].isEnabled(for: .claudeCode))
    #expect(!lib.servers[0].isEnabled(for: .codex))
}

@Test func slugs() {
    #expect(Slug.make("Figma Desktop") == "figma-desktop")
    #expect(Slug.make("  --Hello__World!! ") == "hello-world")
    #expect(Slug.make("") == "server")
    #expect(Slug.unique("notion", existing: ["notion", "notion-2"]) == "notion-3")
}

@Test func externalProjectionForStdioAndRemote() {
    let stdio = Server(id: "pw", name: "Playwright", kind: .stdio, command: "npx", args: ["-y", "x"],
                       env: ["A": "1"], auth: .none, clients: [:], source: "manual", createdAt: .init())
    #expect(stdio.external(gatewayPort: 7337) ==
            ExternalServer(name: "Playwright", kind: .stdio, command: "npx", args: ["-y", "x"], env: ["A": "1"]))
    let oauth = Server(id: "notion", name: "Notion", kind: .remote, url: "https://mcp.notion.com/mcp",
                       auth: .oauth, clients: [:], source: "manual", createdAt: .init())
    #expect(oauth.external(gatewayPort: 7337).url == "http://localhost:7337/s/notion/mcp")
    let plain = Server(id: "ctx", name: "Context7", kind: .remote, url: "https://mcp.context7.com/mcp",
                       auth: .none, clients: [:], source: "manual", createdAt: .init())
    #expect(plain.external(gatewayPort: 7337).url == "https://mcp.context7.com/mcp")
}

@Test func gatewayURLServerIDParsing() {
    #expect(GatewayURL.serverID(from: "http://localhost:7337/s/notion/mcp", port: 7337) == "notion")
    #expect(GatewayURL.serverID(from: "http://127.0.0.1:7337/s/notion/mcp", port: 7337) == "notion")
    #expect(GatewayURL.serverID(from: "http://localhost:9999/s/notion/mcp", port: 7337) == nil)
    #expect(GatewayURL.serverID(from: "https://mcp.notion.com/mcp", port: 7337) == nil)
    #expect(GatewayURL.serverID(from: "http://localhost:7337/other/notion/mcp", port: 7337) == nil)
}

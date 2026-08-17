import Testing
import Foundation
@testable import MCPMCore

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

@Test func claudeCodeReadsOnlyTopLevelServersAndWritesType() throws {
    let a = ClaudeCodeAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let servers = try a.parse(try fixture("claude.json"))
    #expect(Set(servers.map(\.name)) == ["claudestory", "mobbin"])
    let out = try a.render([ExternalServer(name: "ctx", kind: .remote, url: "https://c/mcp")], over: try fixture("claude.json"))
    let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
    #expect(obj["numStartups"] as! Int == 42)
    #expect(((obj["projects"] as! [String: Any])["/Users/me/proj"] as! [String: Any])["mcpServers"] != nil)
    let ctx = (obj["mcpServers"] as! [String: Any])["ctx"] as! [String: Any]
    #expect(ctx["type"] as! String == "http")
}

@Test func cursorReadsSpacesInNamesAndDoesNotWriteType() throws {
    let a = CursorAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let servers = try a.parse(try fixture("cursor-mcp.json"))
    #expect(servers.contains { $0.name == "Figma Desktop" && $0.url == "http://127.0.0.1:3845/mcp" })
    #expect(servers.first { $0.name == "nia" }?.env["NIA_API_KEY"] == "nk_REDACTED")
    let out = try a.render([ExternalServer(name: "a", kind: .stdio, command: "x")], over: nil)
    let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
    #expect(((obj["mcpServers"] as! [String: Any])["a"] as! [String: Any])["type"] == nil)
}

@Test func claudeDesktopBridgesRemoteViaMcpRemote() throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let servers = try a.parse(try fixture("claude_desktop_config.json"))
    // parse turns the mcp-remote bridge back into a remote ExternalServer
    #expect(servers.contains(ExternalServer(name: "notion", kind: .remote, url: "http://localhost:7337/s/notion/mcp")))
    #expect(servers.contains { $0.name == "filesystem" && $0.kind == .stdio })
    // render turns remote into the bridge
    let out = try a.render([ExternalServer(name: "linear", kind: .remote, url: "http://localhost:7337/s/linear/mcp")], over: try fixture("claude_desktop_config.json"))
    let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
    #expect(obj["coworkUserFilesPath"] as! String == "/Users/me/Documents/Claude")
    let linear = (obj["mcpServers"] as! [String: Any])["linear"] as! [String: Any]
    #expect(linear["command"] as! String == "npx")
    #expect(linear["args"] as! [String] == ["-y", "mcp-remote", "http://localhost:7337/s/linear/mcp"])
    #expect(linear["url"] == nil)
    // and parse(render(x)) == x
    #expect(try a.parse(out) == [ExternalServer(name: "linear", kind: .remote, url: "http://localhost:7337/s/linear/mcp")])
}

@Test func claudeDesktopBridgeRoundTripsHeaders() throws {
    let a = ClaudeDesktopAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let servers = [ExternalServer(name: "linear", kind: .remote, url: "http://localhost:7337/s/linear/mcp",
                                   headers: ["Authorization": "Bearer t", "X-Id": "1"])]
    let out = try a.render(servers, over: nil)
    let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
    let linear = (obj["mcpServers"] as! [String: Any])["linear"] as! [String: Any]
    #expect(linear["args"] as! [String] == ["-y", "mcp-remote", "http://localhost:7337/s/linear/mcp",
                                             "--header", "Authorization: Bearer t", "--header", "X-Id: 1"])
    #expect(try a.parse(out) == servers)
}

@Test func allAdaptersCoversEveryClientID() {
    #expect(Set(AllAdapters.make().map(\.id)) == Set(ClientID.allCases))
}

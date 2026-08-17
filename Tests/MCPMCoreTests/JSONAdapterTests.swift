import Testing
import Foundation
@testable import MCPMCore

private let sample = """
{"other":{"keep":1},"mcpServers":{
  "claudestory":{"type":"stdio","command":"claudestory","args":["--mcp"],"env":{}},
  "mobbin":{"type":"http","url":"https://api.mobbin.com/mcp"},
  "exa":{"name":"exa","type":"http","url":"https://mcp.exa.ai/mcp","headers":{"X":"1"}}
}}
"""

@Test func jsonParseReadsStdioAndRemote() throws {
    let servers = try JSONMCPServers.parse(Data(sample.utf8)).sorted { $0.name < $1.name }
    #expect(servers.map(\.name) == ["claudestory", "exa", "mobbin"])
    #expect(servers[0] == ExternalServer(name: "claudestory", kind: .stdio, command: "claudestory", args: ["--mcp"]))
    #expect(servers[1].url == "https://mcp.exa.ai/mcp")
    #expect(servers[1].headers == ["X": "1"])
    #expect(servers[2].kind == .remote)
}

@Test func jsonParseOfMissingSectionIsEmpty() throws {
    #expect(try JSONMCPServers.parse(Data("{}".utf8)).isEmpty)
    #expect(try JSONMCPServers.parse(nil).isEmpty)
}

@Test func jsonRenderPreservesUnrelatedKeysAndUnknownServerFields() throws {
    let desired = [
        ExternalServer(name: "exa", kind: .remote, url: "https://mcp.exa.ai/mcp", headers: ["X": "1"]),   // headers are ours now, must be passed explicitly
        ExternalServer(name: "new", kind: .stdio, command: "npx", args: ["-y", "z"], env: ["K": "v"]),
    ]
    let out = try JSONMCPServers.render(desired, over: Data(sample.utf8), writeTypeKey: true)
    let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
    #expect((obj["other"] as! [String: Any])["keep"] as! Int == 1)
    let ms = obj["mcpServers"] as! [String: Any]
    #expect(Set(ms.keys) == ["exa", "new"])              // mobbin + claudestory removed
    let exa = ms["exa"] as! [String: Any]
    #expect(exa["headers"] as! [String: String] == ["X": "1"])
    #expect(exa["name"] as! String == "exa")   // genuinely unknown field preserved
    let new = ms["new"] as! [String: Any]
    #expect(new["type"] as! String == "stdio")
    #expect(new["args"] as! [String] == ["-y", "z"])
    #expect(new["env"] as! [String: String] == ["K": "v"])
    // round trip
    #expect(Set(try JSONMCPServers.parse(out)) == Set(desired))
}

@Test func jsonRenderKindFlipIsCleanForBothTypeKeyModes() throws {
    let existing = """
    {"mcpServers":{"a":{"type":"http","url":"u","headers":{"A":"b"}}}}
    """
    let desired = [ExternalServer(name: "a", kind: .stdio, command: "x")]

    let withType = try JSONMCPServers.render(desired, over: Data(existing.utf8), writeTypeKey: true)
    let aWithType = ((try JSONSerialization.jsonObject(with: withType) as! [String: Any])["mcpServers"] as! [String: Any])["a"] as! [String: Any]
    #expect(aWithType["type"] as! String == "stdio")
    #expect(aWithType["url"] == nil)
    #expect(aWithType["headers"] == nil)

    let withoutType = try JSONMCPServers.render(desired, over: Data(existing.utf8), writeTypeKey: false)
    let aWithoutType = ((try JSONSerialization.jsonObject(with: withoutType) as! [String: Any])["mcpServers"] as! [String: Any])["a"] as! [String: Any]
    #expect(aWithoutType["type"] == nil)
    #expect(aWithoutType["url"] == nil)
    #expect(aWithoutType["headers"] == nil)
}

@Test func jsonRenderKeepsAnExistingSSETransport() throws {
    let existing = """
    {"mcpServers":{"a":{"type":"sse","url":"u"}}}
    """
    let out = try JSONMCPServers.render([ExternalServer(name: "a", kind: .remote, url: "u2")],
                                        over: Data(existing.utf8), writeTypeKey: true)
    let a = ((try JSONSerialization.jsonObject(with: out) as! [String: Any])["mcpServers"] as! [String: Any])["a"] as! [String: Any]
    #expect(a["type"] as! String == "sse")
    #expect(a["url"] as! String == "u2")

    // A flip to stdio is not a transport we can keep, so it resets to the default.
    let flipped = try JSONMCPServers.render([ExternalServer(name: "a", kind: .stdio, command: "x")],
                                            over: Data(existing.utf8), writeTypeKey: true)
    let b = ((try JSONSerialization.jsonObject(with: flipped) as! [String: Any])["mcpServers"] as! [String: Any])["a"] as! [String: Any]
    #expect(b["type"] as! String == "stdio")
}

@Test func jsonRenderPreservesUnrecognizedEntries() throws {
    let existing = """
    {"mcpServers":{"weird":{"foo":1}}}
    """
    let out = try JSONMCPServers.render([ExternalServer(name: "b", kind: .stdio, command: "y")], over: Data(existing.utf8), writeTypeKey: true)
    let ms = (try JSONSerialization.jsonObject(with: out) as! [String: Any])["mcpServers"] as! [String: Any]
    #expect((ms["weird"] as! [String: Any])["foo"] as! Int == 1)
    #expect(ms["b"] != nil)
}

@Test func jsonRenderThrowsOnStdioWithoutCommand() throws {
    #expect(throws: AdapterError.self) {
        _ = try JSONMCPServers.render([ExternalServer(name: "a", kind: .stdio)], over: nil, writeTypeKey: true)
    }
}

@Test func jsonRenderWithoutTypeKeyOmitsIt() throws {
    let out = try JSONMCPServers.render([ExternalServer(name: "a", kind: .stdio, command: "x")], over: nil, writeTypeKey: false)
    let obj = try JSONSerialization.jsonObject(with: out) as! [String: Any]
    let a = (obj["mcpServers"] as! [String: Any])["a"] as! [String: Any]
    #expect(a["type"] == nil)
    #expect(a["command"] as! String == "x")
}

@Test func jsonRenderIsStableWhenNothingChanges() throws {
    let parsed = try JSONMCPServers.parse(Data(sample.utf8))
    let once = try JSONMCPServers.render(parsed, over: Data(sample.utf8), writeTypeKey: true)
    let twice = try JSONMCPServers.render(parsed, over: once, writeTypeKey: true)
    #expect(once == twice)
}

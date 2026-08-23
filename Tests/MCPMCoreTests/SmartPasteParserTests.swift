import Testing
import Foundation
@testable import MCPMCore

@Test func parsesBareURLAsRemote() throws {
    let r = SmartPasteParser.parse("  https://mcp.notion.com/mcp \n")
    #expect(r.servers == [ExternalServer(name: "notion", kind: .remote, url: "https://mcp.notion.com/mcp")])
    #expect(r.summary == "Remote server · mcp.notion.com")
}

@Test func parsesCommandLineWithQuotes() throws {
    let r = SmartPasteParser.parse(#"npx -y @playwright/mcp@latest --browser "chrome canary""#)
    #expect(r.servers == [ExternalServer(name: "playwright-mcp", kind: .stdio, command: "npx", args: ["-y", "@playwright/mcp@latest", "--browser", "chrome canary"])])
    #expect(r.summary == "Local server · npx")
}

@Test func nameFromCommandBasenameWhenNoPackage() {
    let r = SmartPasteParser.parse("/usr/local/bin/my-server --port 3")
    #expect(r.servers.first?.name == "my-server")
}

@Test func parsesReadmeJSONWithMcpServersWrapper() throws {
    let json = #"{"mcpServers":{"context7":{"url":"https://mcp.context7.com/mcp"},"fs":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"],"env":{"A":"1"}}}}"#
    let r = SmartPasteParser.parse(json)
    #expect(Set(r.servers.map(\.name)) == ["context7", "fs"])
    #expect(r.summary == "2 servers from JSON")
}

@Test func parsesNameMapAndBareObject() {
    #expect(SmartPasteParser.parse(#"{"exa":{"url":"https://mcp.exa.ai/mcp","headers":{"X":"1"}}}"#).servers ==
            [ExternalServer(name: "exa", kind: .remote, url: "https://mcp.exa.ai/mcp", headers: ["X": "1"])])
    let bare = SmartPasteParser.parse(#"{"command":"uvx","args":["mcp-server-fetch"]}"#)
    #expect(bare.servers == [ExternalServer(name: "mcp-server-fetch", kind: .stdio, command: "uvx", args: ["mcp-server-fetch"])])
}

@Test func parsesClaudeMCPAddCommands() {
    #expect(SmartPasteParser.parse("claude mcp add --scope user notion https://mcp.notion.com/mcp").servers ==
            [ExternalServer(name: "notion", kind: .remote, url: "https://mcp.notion.com/mcp")])
    #expect(SmartPasteParser.parse("claude mcp add --transport http linear https://mcp.linear.app/mcp").servers ==
            [ExternalServer(name: "linear", kind: .remote, url: "https://mcp.linear.app/mcp")])
    #expect(SmartPasteParser.parse("claude mcp add pw -- npx -y @playwright/mcp@latest").servers ==
            [ExternalServer(name: "pw", kind: .stdio, command: "npx", args: ["-y", "@playwright/mcp@latest"])])
    #expect(SmartPasteParser.parse("claude mcp add -e KEY=v pw -- npx x").servers ==
            [ExternalServer(name: "pw", kind: .stdio, command: "npx", args: ["x"], env: ["KEY": "v"])])
    #expect(SmartPasteParser.parse(#"claude mcp add -H "Authorization: Bearer t" ex https://mcp.exa.ai/mcp"#).servers ==
            [ExternalServer(name: "ex", kind: .remote, url: "https://mcp.exa.ai/mcp", headers: ["Authorization": "Bearer t"])])
    #expect(SmartPasteParser.parse("claude mcp add --scope user").summary == "Couldn't read that claude mcp add command")
}

@Test func sseEndpointsAreDialledWithTheLegacyTransport() {
    // A bare URL: only the path says so.
    #expect(SmartPasteParser.parse("https://mcp.sentry.dev/sse").servers ==
            [ExternalServer(name: "sentry", kind: .remote, url: "https://mcp.sentry.dev/sse", transport: .sse)])
    #expect(SmartPasteParser.parse("https://mcp.sentry.dev/mcp").servers.first?.transport == nil)
    // A path that merely contains "sse" is not an SSE endpoint.
    #expect(SmartPasteParser.parse("https://example.com/sse-docs").servers.first?.transport == nil)
    // Spelled out on the command, and inferred when it isn't.
    #expect(SmartPasteParser.parse("claude mcp add --transport sse sentry https://mcp.sentry.dev/stream").servers ==
            [ExternalServer(name: "sentry", kind: .remote, url: "https://mcp.sentry.dev/stream", transport: .sse)])
    #expect(SmartPasteParser.parse("claude mcp add sentry https://mcp.sentry.dev/sse").servers.first?.transport == .sse)
    #expect(SmartPasteParser.parse("claude mcp add -t http sentry https://mcp.sentry.dev/sse").servers.first?.transport == .sse)
    // Through an mcp-remote bridge, where the URL is still the server.
    #expect(SmartPasteParser.parse("npx -y mcp-remote https://mcp.sentry.dev/sse").servers ==
            [ExternalServer(name: "sentry", kind: .remote, url: "https://mcp.sentry.dev/sse", transport: .sse)])
}

@Test func mcpRemoteBridgeIsJustARemoteServer() {
    #expect(SmartPasteParser.parse("npx -y mcp-remote https://mcp.notion.com/mcp").servers ==
            [ExternalServer(name: "notion", kind: .remote, url: "https://mcp.notion.com/mcp")])
    #expect(SmartPasteParser.parse("claude mcp add notes -- npx mcp-remote@latest https://mcp.notion.com/mcp").servers ==
            [ExternalServer(name: "notes", kind: .remote, url: "https://mcp.notion.com/mcp")])
}

@Test func emptyAndGarbageYieldNothing() {
    #expect(SmartPasteParser.parse("").servers.isEmpty)
    #expect(SmartPasteParser.parse("{not json").servers.isEmpty)
    #expect(SmartPasteParser.parse("{not json").summary == "Couldn't parse that JSON")
    #expect(SmartPasteParser.parse("   ").summary == "")
}

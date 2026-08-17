import Testing
import Foundation
@testable import MCPMCore

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!)
}

@Test func codexParsesTablesAndEnvSubtables() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let s = try a.parse(try fixture("codex-config.toml")).sorted { $0.name < $1.name }
    #expect(s.map(\.name) == ["computer-use", "context7", "node_repl"])
    #expect(s[2].command == "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl")
    #expect(s[2].env["NODE_REPL_NODE_PATH"] == "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node")
    #expect(s[0].args == ["mcp"])
    #expect(s[1] == ExternalServer(name: "context7", kind: .remote, url: "https://mcp.context7.com/mcp"))
}

@Test func codexRenderPreservesUnrelatedTablesCommentsAndUntouchedServerBlocks() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let orig = try fixture("codex-config.toml")
    let parsed = try a.parse(orig)
    // keep node_repl and computer-use unchanged, drop context7, add linear
    var desired = parsed.filter { $0.name != "context7" }
    desired.append(ExternalServer(name: "linear", kind: .remote, url: "http://localhost:7337/s/linear/mcp"))
    let out = String(decoding: try a.render(desired, over: orig), as: UTF8.self)
    #expect(out.contains("# top comment"))
    #expect(out.contains("model = \"gpt-5\""))
    #expect(out.contains("[projects.\"/Users/me/proj\"]"))
    #expect(out.contains("[shell_environment_policy.set]\nFOO = \"bar\""))
    #expect(out.contains("startup_timeout_sec = 120"))          // untouched block kept verbatim
    #expect(out.contains("enabled = false"))
    #expect(!out.contains("context7"))
    #expect(out.contains("[mcp_servers.linear]\nurl = \"http://localhost:7337/s/linear/mcp\""))
    #expect(Set(try a.parse(Data(out.utf8))) == Set(desired))
}

@Test func codexRenderFromEmptyFile() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let out = String(decoding: try a.render([ExternalServer(name: "pw", kind: .stdio, command: "npx", args: ["-y", "@playwright/mcp@latest"], env: ["A": "b \"q\""])], over: nil), as: UTF8.self)
    #expect(out.contains("[mcp_servers.pw]"))
    #expect(out.contains("command = \"npx\""))
    #expect(out.contains("args = [\"-y\", \"@playwright/mcp@latest\"]"))
    #expect(out.contains("[mcp_servers.pw.env]\nA = \"b \\\"q\\\"\""))
    #expect(try a.parse(Data(out.utf8)) == [ExternalServer(name: "pw", kind: .stdio, command: "npx", args: ["-y", "@playwright/mcp@latest"], env: ["A": "b \"q\""])])
}

@Test func codexRenderIsIdempotent() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let orig = try fixture("codex-config.toml")
    let once = try a.render(try a.parse(orig), over: orig)
    #expect(once == orig)   // nothing changed → byte-identical
}

@Test func codexParsesInlineEnvTable() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let toml = """
    [mcp_servers.pw]
    command = "npx"
    args = ["-y", "pw"]
    env = { A = "b", C = "d" }
    """
    #expect(try a.parse(Data(toml.utf8)) == [
        ExternalServer(name: "pw", kind: .stdio, command: "npx", args: ["-y", "pw"], env: ["A": "b", "C": "d"])
    ])
}

@Test func codexBareMCPServersHeaderIsRegeneratedNotKept() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let toml = """
    model = "gpt-5"

    [mcp_servers]
    ctx = { url = "https://c/mcp" }

    [other]
    keep = 1
    """
    let parsed = try a.parse(Data(toml.utf8))
    #expect(parsed == [ExternalServer(name: "ctx", kind: .remote, url: "https://c/mcp")])
    let desired = parsed + [ExternalServer(name: "linear", kind: .remote, url: "https://l/mcp")]
    let out = String(decoding: try a.render(desired, over: Data(toml.utf8)), as: UTF8.self)
    #expect(out.contains("model = \"gpt-5\""))
    #expect(out.contains("[other]\nkeep = 1"))
    #expect(!out.contains("[mcp_servers]\n"))              // bare header not left behind
    #expect(!out.contains("ctx = {"))                      // inline definition regenerated
    #expect(out.contains("[mcp_servers.ctx]\nurl = \"https://c/mcp\""))
    #expect(Set(try a.parse(Data(out.utf8))) == Set(desired))
}

@Test func codexRenderQuotesNonBareNamesAndDropsAllWhenEmpty() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let out = String(decoding: try a.render([ExternalServer(name: "my server", kind: .remote, url: "https://x/mcp")], over: nil), as: UTF8.self)
    #expect(out.contains("[mcp_servers.\"my server\"]"))
    #expect(try a.parse(Data(out.utf8)) == [ExternalServer(name: "my server", kind: .remote, url: "https://x/mcp")])

    let cleared = String(decoding: try a.render([], over: try fixture("codex-config.toml")), as: UTF8.self)
    #expect(!cleared.contains("mcp_servers"))
    #expect(cleared.contains("# top comment"))
    #expect(cleared.contains("[shell_environment_policy.set]"))
}

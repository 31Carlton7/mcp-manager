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

@Test func codexEditPreservesUnmodeledKeys() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let orig = try fixture("codex-config.toml")
    var desired = try a.parse(orig)
    let i = desired.firstIndex { $0.name == "node_repl" }!
    desired[i].command = "/usr/local/bin/node_repl"
    let out = String(decoding: try a.render(desired, over: orig), as: UTF8.self)
    #expect(out.contains("startup_timeout_sec = 120"))                  // unmodeled key survives the edit
    #expect(out.contains("command = \"/usr/local/bin/node_repl\""))
    #expect(!out.contains("cua_node/bin/node_repl\""))                  // old command gone
    #expect(out.components(separatedBy: "[mcp_servers.node_repl.env]").count - 1 == 1)
    #expect(out.contains("NODE_REPL_NODE_PATH = \"/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node\""))
    #expect(out.contains("cwd = \".\""))                                // computer-use untouched, still verbatim
    #expect(out.contains("enabled = false"))
    #expect(Set(try a.parse(Data(out.utf8))) == Set(desired))
}

@Test func codexEditDropsMultiLineModeledValuesWhole() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let toml = """
    [mcp_servers.x]
    # keep me
    command = "old"
    args = [
      "a",
      "b",
    ]
    startup_timeout_sec = 5
    """
    let desired = [ExternalServer(name: "x", kind: .stdio, command: "new", args: ["c"])]
    let out = String(decoding: try a.render(desired, over: Data(toml.utf8)), as: UTF8.self)
    #expect(out.contains("# keep me"))
    #expect(out.contains("startup_timeout_sec = 5"))
    #expect(!out.contains("\"a\""))                                     // no orphaned array elements
    #expect(try a.parse(Data(out.utf8)) == desired)
}

@Test func codexRemoteHeadersRoundTrip() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let s = ExternalServer(name: "exa", kind: .remote, url: "https://mcp.exa.ai/mcp",
                           headers: ["Authorization": "Bearer x", "X-Trace": "1"])
    let out = String(decoding: try a.render([s], over: nil), as: UTF8.self)
    #expect(out.contains("http_headers = { \"Authorization\" = \"Bearer x\", \"X-Trace\" = \"1\" }"))
    #expect(try a.parse(Data(out.utf8)) == [s])

    let subTable = """
    [mcp_servers.exa]
    url = "https://mcp.exa.ai/mcp"

    [mcp_servers.exa.http_headers]
    Authorization = "Bearer x"
    """
    #expect(try a.parse(Data(subTable.utf8)) == [
        ExternalServer(name: "exa", kind: .remote, url: "https://mcp.exa.ai/mcp", headers: ["Authorization": "Bearer x"])
    ])

    // editing a server whose headers lived in a sub-table must not leave a duplicate definition
    let edited = [ExternalServer(name: "exa", kind: .remote, url: "https://mcp.exa.ai/mcp", headers: ["X-Trace": "2"])]
    let out2 = String(decoding: try a.render(edited, over: Data(subTable.utf8)), as: UTF8.self)
    #expect(!out2.contains("[mcp_servers.exa.http_headers]"))
    #expect(try a.parse(Data(out2.utf8)) == edited)
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
    #expect(try a.parse(Data(cleared.utf8)) == [])
}

@Test func codexPreservesCRLFLineEndings() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let lf = String(decoding: try fixture("codex-config.toml"), as: UTF8.self)
    let crlf = Data(lf.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    var desired = try a.parse(crlf)
    let i = desired.firstIndex { $0.name == "node_repl" }!
    desired[i].command = "/usr/local/bin/node_repl"
    let out = String(decoding: try a.render(desired, over: crlf), as: UTF8.self)
    #expect(out.contains("\r\n"))
    #expect(!out.contains("\n\n"))                                      // no bare LF survived
    #expect(out.contains("# top comment"))
    #expect(out.contains("[projects.\"/Users/me/proj\"]"))
    #expect(out.contains("[shell_environment_policy.set]"))
    #expect(out.contains("startup_timeout_sec = 120"))
    #expect(Set(try a.parse(Data(out.utf8))) == Set(desired))
}

@Test func codexEditSurvivesLiteralAndMultiLineStrings() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let toml = """
    [mcp_servers.x]
    args = [ "a", 'single ] quoted', "b" ]
    command = \"\"\"
    a multi-line [mcp_servers.fake] command
    \"\"\"
    cwd = 'literal ] path'
    startup_timeout_sec = 5

    [other]
    keep = 1
    """
    #expect(try a.parse(Data(toml.utf8)).map(\.args) == [["a", "single ] quoted", "b"]])
    let desired = [ExternalServer(name: "x", kind: .stdio, command: "new", args: ["c"])]
    let out = String(decoding: try a.render(desired, over: Data(toml.utf8)), as: UTF8.self)
    #expect(out.contains("cwd = 'literal ] path'"))                     // literal string preserved verbatim
    #expect(out.contains("startup_timeout_sec = 5"))
    #expect(out.contains("[other]\nkeep = 1"))
    #expect(!out.contains("single ] quoted"))                           // old args gone, not orphaned
    #expect(!out.contains("multi-line"))                                // old multi-line command gone whole
    #expect(try a.parse(Data(out.utf8)) == desired)
}

@Test func codexEditDropsDottedModeledKeys() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let toml = """
    [mcp_servers.x]
    command = "old"
    args = []
    env.A = "1"
    http_headers.X = "y"
    enabled = false
    """
    #expect(try a.parse(Data(toml.utf8)) == [
        ExternalServer(name: "x", kind: .stdio, command: "old", args: [], env: ["A": "1"])
    ])
    let desired = [ExternalServer(name: "x", kind: .stdio, command: "new", args: [], env: ["B": "2"])]
    let out = String(decoding: try a.render(desired, over: Data(toml.utf8)), as: UTF8.self)
    #expect(out.components(separatedBy: "[mcp_servers.x.env]").count - 1 == 1)
    #expect(!out.contains("env.A"))
    #expect(!out.contains("http_headers.X"))
    #expect(out.contains("enabled = false"))
    #expect(try a.parse(Data(out.utf8)) == desired)
}

@Test func codexKeepsBlocksItCannotParse() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    let toml = """
    [mcp_servers.mystery]
    # neither url nor command: not ours to understand, and not ours to delete
    enabled = false

    [mcp_servers.x]
    url = "https://x/mcp"
    """
    #expect(try a.parse(Data(toml.utf8)) == [ExternalServer(name: "x", kind: .remote, url: "https://x/mcp")])
    let desired = [ExternalServer(name: "x", kind: .remote, url: "https://x/mcp2")]
    let out = String(decoding: try a.render(desired, over: Data(toml.utf8)), as: UTF8.self)
    #expect(out.contains("[mcp_servers.mystery]"))
    #expect(out.contains("enabled = false"))
    #expect(out.contains("# neither url nor command"))
    #expect(try a.parse(Data(out.utf8)) == desired)
}

@Test func codexRejectsInvalidTOML() throws {
    let a = CodexAdapter(configPath: URL(fileURLWithPath: "/dev/null"))
    // a config we cannot understand is never rewritten
    #expect(throws: AdapterError.self) { try a.parse(Data("[mcp_servers.x\ncommand =".utf8)) }
    #expect(throws: AdapterError.self) { try a.render([], over: Data("[mcp_servers.x\ncommand =".utf8)) }
    // and the render guard rejects any splice that would have produced invalid TOML
    #expect(throws: AdapterError.self) { try CodexAdapter.assertValidTOML("[mcp_servers.x]\ncommand =") }
    #expect(throws: Never.self) { try CodexAdapter.assertValidTOML("[mcp_servers.x]\ncommand = \"ok\"") }
}

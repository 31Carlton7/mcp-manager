import Testing
@testable import MCPMCore

@Test func brandNamesBeatHostsAndSymbols() {
    #expect(IconSource.resolve(name: "GitHub", kind: .remote, url: "https://api.githubcopilot.com/mcp", command: nil, args: []) == .favicon(hosts: ["github.com"]))
    #expect(IconSource.resolve(name: "notion-mcp-server", kind: .stdio, url: nil, command: "npx", args: []) == .favicon(hosts: ["notion.com"]))
    #expect(IconSource.resolve(name: "nia", kind: .stdio, url: nil, command: "pipx", args: []) == .favicon(hosts: ["trynia.ai"]))
    // The name says nothing; the package does.
    #expect(IconSource.resolve(name: "Playwright", kind: .stdio, url: nil, command: "npx", args: ["-y", "@playwright/mcp@latest"]) == .favicon(hosts: ["playwright.dev"]))
    #expect(IconSource.resolve(name: "docs", kind: .stdio, url: nil, command: "npx", args: ["-y", "@upstash/context7-mcp"]) == .favicon(hosts: ["context7.com"]))
}

@Test func genericServersKeepTheirSymbols() {
    #expect(IconSource.resolve(name: "filesystem", kind: .stdio, url: nil, command: "npx", args: []) == .symbol("folder"))
    #expect(IconSource.resolve(name: "server-fetch", kind: .stdio, url: nil, command: "uvx", args: []) == .symbol("arrow.down.doc"))
    #expect(IconSource.resolve(name: "time", kind: .stdio, url: nil, command: "uvx", args: []) == .symbol("clock"))
}

@Test func remoteWithoutABrandTriesHostThenRoot() {
    #expect(IconSource.resolve(name: "Anything", kind: .remote, url: "https://mcp.example.com/mcp", command: nil, args: []) == .favicon(hosts: ["mcp.example.com", "example.com"]))
    #expect(IconSource.resolve(name: "Anything", kind: .remote, url: "https://example.com/mcp", command: nil, args: []) == .favicon(hosts: ["example.com"]))
}

@Test func rootDomainStripsServiceSubdomains() {
    #expect(IconSource.rootDomain("mcp.notion.com") == "notion.com")
    #expect(IconSource.rootDomain("api.githubcopilot.com") == "githubcopilot.com")
    #expect(IconSource.rootDomain("mcp.exa.ai") == "exa.ai")
    #expect(IconSource.rootDomain("x.co.uk") == "x.co.uk")
    #expect(IconSource.rootDomain("notion.com") == "notion.com")
    #expect(IconSource.rootDomain("a.b.example.org") == "example.org")
}

@Test func localhostRemoteAndUnknownStdioFallBackToMonogram() {
    #expect(IconSource.resolve(name: "local bridge", kind: .remote, url: "http://127.0.0.1:3845/mcp", command: nil, args: []) == .monogram("LB", hue: IconSource.hue("local bridge")))
    // A brand is a brand even when it is served from localhost.
    #expect(IconSource.resolve(name: "Figma Desktop", kind: .remote, url: "http://127.0.0.1:3845/mcp", command: nil, args: []) == .favicon(hosts: ["figma.com"]))
    #expect(IconSource.resolve(name: "node_repl", kind: .stdio, url: nil, command: "node", args: []) == .monogram("NR", hue: IconSource.hue("node_repl")))
}

@Test func monogramRules() {
    #expect(IconSource.monogram(for: "context7") == "C")
    #expect(IconSource.monogram(for: "node_repl") == "NR")
    #expect(IconSource.monogram(for: "computer-use") == "CU")
    #expect(IconSource.hue("nia") == IconSource.hue("nia"))
    #expect((0..<360).contains(IconSource.hue("anything")))
}

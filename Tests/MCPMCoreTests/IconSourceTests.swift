import Testing
@testable import MCPMCore

@Test func knownSlugsMapToSymbols() {
    #expect(IconSource.resolve(name: "GitHub", kind: .remote, url: "https://api.githubcopilot.com/mcp", command: nil) == .favicon(host: "api.githubcopilot.com"))
    #expect(IconSource.resolve(name: "filesystem", kind: .stdio, url: nil, command: "npx") == .symbol("folder"))
    #expect(IconSource.resolve(name: "Playwright", kind: .stdio, url: nil, command: "npx") == .symbol("theatermasks"))
}

@Test func remoteWithoutKnownSymbolUsesFavicon() {
    #expect(IconSource.resolve(name: "Anything", kind: .remote, url: "https://mcp.example.com/mcp", command: nil) == .favicon(host: "mcp.example.com"))
}

@Test func localhostRemoteAndStdioFallBackToMonogram() {
    #expect(IconSource.resolve(name: "Figma Desktop", kind: .remote, url: "http://127.0.0.1:3845/mcp", command: nil) == .monogram("FD", hue: IconSource.hue("Figma Desktop")))
    #expect(IconSource.resolve(name: "nia", kind: .stdio, url: nil, command: "pipx") == .monogram("N", hue: IconSource.hue("nia")))
}

@Test func monogramRules() {
    #expect(IconSource.monogram(for: "context7") == "C")
    #expect(IconSource.monogram(for: "node_repl") == "NR")
    #expect(IconSource.monogram(for: "computer-use") == "CU")
    #expect(IconSource.hue("nia") == IconSource.hue("nia"))
    #expect((0..<360).contains(IconSource.hue("anything")))
}

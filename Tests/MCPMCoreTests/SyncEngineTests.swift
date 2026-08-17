import Testing
import Foundation
@testable import MCPMCore

private let now = Date(timeIntervalSince1970: 1_000)
private func srv(_ id: String, kind: ServerKind = .stdio, auth: AuthKind = .none, url: String? = nil,
                 clients: [ClientID: Bool]) -> Server {
    Server(id: id, name: id, kind: kind, command: kind == .stdio ? "cmd-\(id)" : nil, url: url, auth: auth,
           clients: clients, source: "manual", createdAt: now)
}

@Test func projectsEnabledServersAndSkipsUnchangedClients() {
    let lib = Library(servers: [srv("a", clients: [.cursor: true, .codex: false])])
    let input = SyncInput(library: lib, snapshots: [
        .cursor: [ExternalServer(name: "a", kind: .stdio, command: "cmd-a")],   // already correct
        .codex: [],
    ], suppressed: [], gatewayPort: 7337, now: now)
    let out = SyncEngine.plan(input)
    #expect(out.writes.isEmpty)
    #expect(out.library == lib)
}

@Test func writesWhenClientDiffers() {
    let lib = Library(servers: [srv("a", clients: [.cursor: true])])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [.cursor: []], suppressed: [.cursor], gatewayPort: 7337, now: now))
    #expect(out.writes[.cursor] == [ExternalServer(name: "a", kind: .stdio, command: "cmd-a")])
}

@Test func adoptsUnknownServersFromClients() {
    let out = SyncEngine.plan(SyncInput(library: Library(), snapshots: [
        .cursor: [ExternalServer(name: "Figma Desktop", kind: .remote, url: "http://127.0.0.1:3845/mcp")],
    ], suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.adopted.count == 1)
    let s = out.library.servers[0]
    #expect(s.id == "figma-desktop")
    #expect(s.source == "imported:cursor")
    #expect(s.clients == [.cursor: true])
    #expect(out.writes.isEmpty)   // client already has it exactly
}

@Test func matchesByNameThenUrlThenCommand() {
    let lib = Library(servers: [
        srv("ctx", kind: .remote, url: "https://c/mcp", clients: [.cursor: true]),
        srv("pw", clients: [.cursor: true]),
    ])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [
        .codex: [ExternalServer(name: "context-seven", kind: .remote, url: "https://c/mcp"),   // url match → ctx
                 ExternalServer(name: "playwright", kind: .stdio, command: "cmd-pw")],          // command match → pw
    ], suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.adopted.isEmpty)
    #expect(out.library.server(id: "ctx")?.clients[.codex] == true)
    #expect(out.library.server(id: "pw")?.clients[.codex] == true)
    // library wins on shape: codex gets rewritten with our names
    #expect(Set(out.writes[.codex]!.map(\.name)) == ["ctx", "pw"])
}

@Test func gatewayURLMapsBackToServerAndIsNotAdopted() {
    let lib = Library(servers: [srv("notion", kind: .remote, auth: .oauth, url: "https://mcp.notion.com/mcp", clients: [.cursor: true])])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [
        .cursor: [ExternalServer(name: "notion", kind: .remote, url: "http://localhost:7337/s/notion/mcp")],
    ], suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.adopted.isEmpty)
    #expect(out.writes.isEmpty)
}

@Test func clientWinsOnPresence_removalDisablesClient() {
    let lib = Library(servers: [srv("a", clients: [.cursor: true, .codex: true])])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [.cursor: [], .codex: [ExternalServer(name: "a", kind: .stdio, command: "cmd-a")]],
                                        suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.library.server(id: "a")?.clients[.cursor] == false)
    #expect(out.library.server(id: "a")?.clients[.codex] == true)
    #expect(out.writes.isEmpty)
}

@Test func suppressedClientSkipsPresenceCheckButStillProjects() {
    let lib = Library(servers: [srv("a", clients: [.cursor: true])])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [.cursor: []], suppressed: [.cursor], gatewayPort: 7337, now: now))
    #expect(out.library.server(id: "a")?.clients[.cursor] == true)
    #expect(out.writes[.cursor]?.count == 1)
}

@Test func missingSnapshotMeansUntouched() {
    let lib = Library(servers: [srv("a", clients: [.cursor: true, .codex: true])])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [.cursor: [ExternalServer(name: "a", kind: .stdio, command: "cmd-a")]],
                                        suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.writes[.codex] == nil)
    #expect(out.library.server(id: "a")?.clients[.codex] == true)
}

@Test func libraryWinsOnShape() {
    let lib = Library(servers: [srv("a", clients: [.cursor: true])])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [.cursor: [ExternalServer(name: "a", kind: .stdio, command: "OLD")]],
                                        suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.writes[.cursor]?.first?.command == "cmd-a")
    #expect(out.library == lib)
}

@Test func suppressedClientCannotReenableViaStaleSnapshot() {
    let lib = Library(servers: [srv("a", clients: [.cursor: false])])
    let out = SyncEngine.plan(SyncInput(library: lib, snapshots: [.cursor: [ExternalServer(name: "a", kind: .stdio, command: "cmd-a")]],
                                        suppressed: [.cursor], gatewayPort: 7337, now: now))
    #expect(out.library.server(id: "a")?.clients[.cursor] == false)
    #expect(out.writes[.cursor] == [])
}

@Test func suppressedClientDoesNotReadoptRemovedServer() {
    let out = SyncEngine.plan(SyncInput(library: Library(), snapshots: [
        .cursor: [ExternalServer(name: "notion", kind: .remote, url: "http://localhost:7337/s/notion/mcp")],
    ], suppressed: [.cursor], gatewayPort: 7337, now: now))
    #expect(out.adopted.isEmpty)
    #expect(out.writes[.cursor] == [])
}

@Test func importKeepsHeadersAndProducesNoWrite() {
    let out = SyncEngine.plan(SyncInput(library: Library(), snapshots: [
        .cursor: [ExternalServer(name: "exa", kind: .remote, url: "https://mcp.exa.ai/mcp", headers: ["Authorization": "Bearer x"])],
    ], suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.adopted.count == 1)
    #expect(out.adopted[0].headers == ["Authorization": "Bearer x"])
    #expect(out.writes.isEmpty)
}

@Test func adoptionSlugSuffixIsDeterministicRegardlessOfSnapshotOrder() {
    // "foo bar" and "Foo Bar" both slugify to "foo-bar"; sorting by name before adopting means
    // whichever comes first alphabetically ("Foo Bar") always claims the base slug.
    let snapshot = [ExternalServer(name: "foo bar", kind: .stdio, command: "cmd-2"),
                     ExternalServer(name: "Foo Bar", kind: .stdio, command: "cmd-1")]
    let out = SyncEngine.plan(SyncInput(library: Library(), snapshots: [.cursor: snapshot],
                                        suppressed: [], gatewayPort: 7337, now: now))
    #expect(out.library.server(id: "foo-bar")?.command == "cmd-1")
    #expect(out.library.server(id: "foo-bar-2")?.command == "cmd-2")
}

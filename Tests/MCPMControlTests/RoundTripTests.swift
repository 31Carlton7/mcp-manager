import Testing
import Foundation
import MCPMCore
@testable import MCPMControl

/// Unix domain socket paths are capped near 104 bytes, and the per-test temporary
/// directory is well past that, so socket tests bind under /tmp directly.
private func tempSocketPath() -> String {
    "/tmp/mcpm-\(UUID().uuidString.prefix(8)).sock"
}

@Test func serverAndClientRoundTripWithEvents() async throws {
    let sock = tempSocketPath()
    let status = DaemonStatus(daemonVersion: "t", apiVersion: 1, servers: [], clients: [])
    let server = ControlServer(socketPath: sock) { req in
        switch req.command {
        case .hello: return .hello(daemonVersion: "t", apiVersion: 1)
        case .status: return .status(status)
        default: throw ControlServerError.unsupported(req.command.method)
        }
    }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()
    let hello = try await client.send(.hello(.init(appVersion: "t")))
    #expect(hello == .hello(daemonVersion: "t", apiVersion: 1))
    #expect(try await client.send(.status) == .status(status))

    // events
    let evTask = Task { () -> [ControlEvent] in
        var got: [ControlEvent] = []
        for await e in client.events { got.append(e); break }
        return got
    }
    try await Task.sleep(for: .milliseconds(50))
    await server.broadcast(.status(status))
    #expect(try await evTask.value == [.status(status)])

    // error path
    await #expect(throws: ControlClientError.self) { try await client.send(.listServers) }

    await client.close()
    try await server.stop()
    #expect(!FileManager.default.fileExists(atPath: sock))
}

@Test func serverChmodsSocketTo600() async throws {
    let sock = tempSocketPath()
    let server = ControlServer(socketPath: sock) { _ in .ack }
    try await server.start()
    let mode = try FileManager.default.attributesOfItem(atPath: sock)[.posixPermissions] as? NSNumber
    #expect(mode?.int16Value == 0o600)
    try await server.stop()
    #expect(!FileManager.default.fileExists(atPath: sock))
}

@Test func sendAfterDaemonGoesAwayThrowsRatherThanHanging() async throws {
    let sock = tempSocketPath()
    let server = ControlServer(socketPath: sock) { _ in .ack }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()
    #expect(try await client.send(.status) == .ack)

    try await server.stop()
    try await Task.sleep(for: .milliseconds(20))
    await #expect(throws: ControlClientError.self) { try await client.send(.status) }
    await client.close()
}

@Test func clientSendWithoutConnectingThrows() async throws {
    let client = ControlClient(socketPath: tempSocketPath())
    await #expect(throws: ControlClientError.notConnected) { try await client.send(.status) }
}

@Test func concurrentRequestsMatchTheirOwnResponses() async throws {
    let sock = tempSocketPath()
    let server = ControlServer(socketPath: sock) { req in
        guard case .removeServer(let p) = req.command else { throw ControlServerError.unsupported(req.command.method) }
        // Stagger completions so responses cannot come back in request order.
        try await Task.sleep(for: .milliseconds(p.id == "slow" ? 60 : 1))
        return .servers([Server(id: p.id, name: p.id, kind: .stdio, source: "t", createdAt: Date())])
    }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()
    async let slow = client.send(.removeServer(.init(id: "slow")))
    async let fast = client.send(.removeServer(.init(id: "fast")))
    guard case .servers(let a) = try await slow, case .servers(let b) = try await fast else {
        Issue.record("wrong result kind"); return
    }
    #expect(a.first?.id == "slow")
    #expect(b.first?.id == "fast")

    await client.close()
    try await server.stop()
}

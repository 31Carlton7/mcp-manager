import Testing
import Foundation
import MCPMCore
@testable import MCPMControl

/// Unix domain socket paths are capped near 104 bytes, and the per-test temporary
/// directory is well past that, so socket tests bind under /tmp directly.
private func tempSocketPath() -> String {
    "/tmp/mcpm-\(UUID().uuidString.prefix(8)).sock"
}

/// What a stub handler answers with when a test hands it a command it does not serve.
private struct Unserved: Error { let method: String }

@Test func serverAndClientRoundTripWithEvents() async throws {
    let sock = tempSocketPath()
    let status = aStatus(version: "t")
    let server = ControlServer(socketPath: sock) { req in
        switch req.command {
        case .hello: return .hello(daemonVersion: "t", apiVersion: 1)
        case .status: return .status(status)
        default: throw Unserved(method: req.command.method)
        }
    }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()
    let hello = try await client.send(.hello(.init(appVersion: "t")))
    #expect(hello == .hello(daemonVersion: "t", apiVersion: 1))
    #expect(try await client.send(.status) == .status(status))

    let events = await client.events()
    let evTask = Task { () -> [ControlEvent] in
        var got: [ControlEvent] = []
        for await e in events { got.append(e); break }
        return got
    }
    try await Task.sleep(for: .milliseconds(50))
    await server.broadcast(.status(status))
    #expect(await evTask.value == [.status(status)])

    // A command the handler refuses comes back as a remote error rather than as a hang.
    await #expect(throws: ControlClientError.self) { try await client.send(.subscribe) }

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
        guard case .removeServer(let p) = req.command else { throw Unserved(method: req.command.method) }
        // Stagger handling so a request that is slow to answer cannot swallow another's reply.
        try await Task.sleep(for: .milliseconds(p.id == "slow" ? 60 : 1))
        return .authorizeURL(p.id)
    }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()
    async let slow = client.send(.removeServer(.init(id: "slow")))
    async let fast = client.send(.removeServer(.init(id: "fast")))
    guard case .authorizeURL(let a) = try await slow, case .authorizeURL(let b) = try await fast else {
        Issue.record("wrong result kind"); return
    }
    #expect(a == "slow")
    #expect(b == "fast")

    await client.close()
    try await server.stop()
}

@Test func eventStreamEndsWithTheConnectionAndReconnectStartsAFreshOne() async throws {
    let sock = tempSocketPath()
    let status = aStatus(version: "t")
    let server = ControlServer(socketPath: sock) { _ in .ack }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()

    // A loop over the first connection's events must end when that connection dies,
    // so a reconnect loop in the app can fall through instead of hanging forever.
    let first = await client.events()
    let drained = Task { () -> Int in
        var n = 0
        for await _ in first { n += 1 }
        return n
    }
    try await Task.sleep(for: .milliseconds(50))
    await server.broadcast(.status(status))
    try await server.stop()
    #expect(await drained.value == 1)

    // Reconnecting yields a new, live stream.
    try await server.start()
    try await client.connect()
    let second = await client.events()
    let next = Task { () -> ControlEvent? in
        for await e in second { return e }
        return nil
    }
    try await Task.sleep(for: .milliseconds(50))
    await server.broadcast(.status(status))
    #expect(await next.value == .status(status))

    await client.close()
    try await server.stop()
}

@Test func eventsBeforeConnectingIsAFinishedStream() async throws {
    let client = ControlClient(socketPath: tempSocketPath())
    var count = 0
    for await _ in await client.events() { count += 1 }
    #expect(count == 0)
}

@Test func requestsFromOneConnectionAreHandledInOrder() async throws {
    actor Recorder {
        var ids: [Int] = []
        func record(_ id: Int) { ids.append(id) }
    }
    let recorder = Recorder()
    let sock = tempSocketPath()
    let server = ControlServer(socketPath: sock) { req in
        // Later requests are quicker to answer, so handling them concurrently would record
        // them out of order. Sequential per-connection dispatch keeps ids increasing.
        try await Task.sleep(for: .milliseconds(max(1, 21 - req.id)))
        await recorder.record(req.id)
        return .ack
    }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<20 { group.addTask { _ = try await client.send(.status) } }
        try await group.waitForAll()
    }

    let ids = await recorder.ids
    #expect(ids.count == 20)
    #expect(ids == ids.sorted(), "handler saw ids out of order: \(ids)")

    await client.close()
    try await server.stop()
}

@Test func eventsArriveInWireOrder() async throws {
    let sock = tempSocketPath()
    let server = ControlServer(socketPath: sock) { _ in .ack }
    try await server.start()
    let client = ControlClient(socketPath: sock)
    try await client.connect()

    let events = await client.events()
    let collected = Task { () -> [String] in
        var versions: [String] = []
        for await case .status(let s) in events {
            versions.append(s.daemonVersion)
            if versions.count == 20 { break }
        }
        return versions
    }
    try await Task.sleep(for: .milliseconds(50))
    for i in 1...20 {
        await server.broadcast(.status(aStatus(version: "\(i)")))
    }

    // A stale status landing after a newer one would show the wrong state in the UI.
    #expect(await collected.value == (1...20).map(String.init))

    await client.close()
    try await server.stop()
}

@Test func malformedLineIsRejectedAndTheConnectionKeepsWorking() async throws {
    let sock = tempSocketPath()
    let server = ControlServer(socketPath: sock) { _ in .ack }
    try await server.start()

    let raw = try RawConnection(path: sock)
    defer { raw.close() }

    try raw.writeLine("{not json")
    let bad = try JSONDecoder.mcpm.decode(ControlResponse.self, from: Data(try #require(raw.readLine()).utf8))
    #expect(bad.id == -1)
    #expect(!bad.ok)
    #expect(bad.error != nil)

    try raw.writeLine(#"{"id":9,"method":"status"}"#)
    let good = try JSONDecoder.mcpm.decode(ControlResponse.self, from: Data(try #require(raw.readLine()).utf8))
    #expect(good.id == 9)
    #expect(good.ok)
    #expect(good.result == .ack)

    try await server.stop()
}

/// A plain blocking Unix socket, so tests can put bytes on the wire that `ControlClient`
/// would never produce. Reads time out after two seconds rather than hanging the suite.
private struct RawConnection {
    enum Failure: Error { case socket(Int32), connect(Int32), write(Int32) }

    let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            precondition(bytes.count < dst.count)
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard rc == 0 else { let e = errno; close(); throw Failure.connect(e) }
    }

    func writeLine(_ line: String) throws {
        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            guard n > 0 else { throw Failure.write(errno) }
            sent += n
        }
    }

    /// One newline-terminated line, or nil on timeout/EOF.
    func readLine() -> String? {
        var out = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == UInt8(ascii: "\n") { return String(decoding: out, as: UTF8.self) }
            out.append(byte)
        }
        return nil
    }

    func close() { _ = Darwin.close(fd) }
}

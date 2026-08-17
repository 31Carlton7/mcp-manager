import Foundation
import NIO
import NIOExtras
import MCPMCore

public enum ControlClientError: Error, Equatable { case notConnected, remote(String), badResponse }

/// Async client for the daemon. `send` awaits the matching response; `events` streams pushed events.
public actor ControlClient {
    private let socketPath: String
    /// Singleton group: shared across clients, never shut down, so `close()` followed by a
    /// later `connect()` works and a dropped client leaks no threads.
    private let group = MultiThreadedEventLoopGroup.singleton
    private var channel: Channel?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<ControlResult, Error>] = [:]
    private let eventStream: AsyncStream<ControlEvent>
    private let eventCont: AsyncStream<ControlEvent>.Continuation
    /// Events pushed by the daemon. The stream outlives `close()` so a reconnect keeps delivering.
    public nonisolated var events: AsyncStream<ControlEvent> { eventStream }
    public private(set) var isConnected = false

    public init(socketPath: String) {
        self.socketPath = socketPath
        (eventStream, eventCont) = AsyncStream<ControlEvent>.makeStream()
    }

    deinit { eventCont.finish() }

    public func connect() async throws {
        let bootstrap = ClientBootstrap(group: group).channelInitializer { ch in
            ch.pipeline.addHandlers([ByteToMessageHandler(LineBasedFrameDecoder()), InboundHandler(client: self)])
        }
        channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
        isConnected = true
    }

    public func close() async {
        try? await channel?.close().get()
        channel = nil
        isConnected = false
        failPending()
    }

    public func send(_ command: ControlCommand) async throws -> ControlResult {
        guard let channel else { throw ControlClientError.notConnected }
        let id = nextID
        nextID += 1
        let data = try JSONEncoder.mcpmWire.encode(ControlRequest(id: id, command: command))
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            var buf = channel.allocator.buffer(capacity: data.count + 1)
            buf.writeBytes(data)
            buf.writeString("\n")
            let written = channel.eventLoop.makePromise(of: Void.self)
            // Writing to a channel the daemon just closed fails silently with `promise: nil`,
            // which would leave `send` awaiting a response that can never arrive.
            written.futureResult.whenFailure { error in
                Task { await self.fail(id, with: error) }
            }
            channel.writeAndFlush(buf, promise: written)
        }
    }

    private func fail(_ id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    fileprivate func receive(_ data: Data) {
        guard let inbound = try? ControlInbound.decode(data) else { return }
        switch inbound {
        case .event(let e):
            eventCont.yield(e)
        case .response(let r):
            guard let cont = pending.removeValue(forKey: r.id) else { return }
            if r.ok, let res = r.result { cont.resume(returning: res) }
            else { cont.resume(throwing: ControlClientError.remote(r.error ?? "unknown")) }
        }
    }

    fileprivate func disconnected() {
        isConnected = false
        channel = nil
        failPending()
    }

    private func failPending() {
        for (_, c) in pending { c.resume(throwing: ControlClientError.notConnected) }
        pending.removeAll()
    }
}

private final class InboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let client: ControlClient
    init(client: ControlClient) { self.client = client }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        Task { await client.receive(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) { Task { await client.disconnected() } }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

import Foundation
import NIO
import NIOExtras
import MCPMCore

public enum ControlClientError: Error, Equatable { case notConnected, remote(String), badResponse }

/// Async client for the daemon. `send` awaits the matching response; `events()` streams pushed events.
public actor ControlClient {
    private let socketPath: String
    /// Singleton group: shared across clients, never shut down, so `close()` followed by a
    /// later `connect()` works and a dropped client leaks no threads.
    private let group = MultiThreadedEventLoopGroup.singleton
    private var channel: Channel?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<ControlResult, Error>] = [:]
    private var eventCont: AsyncStream<ControlEvent>.Continuation?
    private var eventStream: AsyncStream<ControlEvent>?
    public private(set) var isConnected = false

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Events pushed by the daemon over the current connection. The stream finishes when that
    /// connection ends, so a caller looping over it can fall through to reconnect and call this
    /// again for the next connection's stream. Returns a finished stream when not connected.
    public func events() -> AsyncStream<ControlEvent> {
        eventStream ?? AsyncStream { $0.finish() }
    }

    public func connect() async throws {
        if channel != nil { await close() }
        let (stream, cont) = AsyncStream<ControlEvent>.makeStream()
        eventStream = stream
        eventCont = cont
        let bootstrap = ClientBootstrap(group: group).channelInitializer { ch in
            ch.eventLoop.makeCompletedFuture {
                try ch.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(LineBasedFrameDecoder(), maximumBufferSize: ControlServer.maximumFrameSize),
                    InboundHandler(client: self),
                ])
            }
        }
        do {
            channel = try await bootstrap.connect(unixDomainSocketPath: socketPath).get()
        } catch {
            endConnection()
            throw error
        }
        isConnected = true
    }

    public func close() async {
        let old = channel
        channel = nil
        try? await old?.close().get()
        endConnection()
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

    fileprivate func receive(_ data: Data, from ch: Channel) {
        guard ch === channel else { return }  // a line from a connection we already replaced
        guard let inbound = try? ControlInbound.decode(data) else { return }
        switch inbound {
        case .event(let e):
            eventCont?.yield(e)
        case .response(let r):
            guard let cont = pending.removeValue(forKey: r.id) else { return }
            if !r.ok { cont.resume(throwing: ControlClientError.remote(r.error ?? "unknown")) }
            else if let res = r.result { cont.resume(returning: res) }
            else { cont.resume(throwing: ControlClientError.badResponse) }
        }
    }

    fileprivate func disconnected(_ ch: Channel) {
        guard ch === channel else { return }  // a previous connection going away after we moved on
        channel = nil
        endConnection()
    }

    /// Tear down state tied to one connection: no more events, and nothing left awaiting a reply.
    private func endConnection() {
        isConnected = false
        eventCont?.finish()
        eventCont = nil
        eventStream = nil
        for (_, c) in pending { c.resume(throwing: ControlClientError.notConnected) }
        pending.removeAll()
    }
}

/// Feeds the connection's lines through one stream with a single consumer, so events reach
/// `events()` in the order the daemon sent them — a stale status must never land after a newer
/// one. Draining finishes before `disconnected`, so lines already received are still handled.
private final class InboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let client: ControlClient
    private let lines: AsyncStream<Data>
    private let lineCont: AsyncStream<Data>.Continuation
    private var consumer: Task<Void, Never>?

    init(client: ControlClient) {
        self.client = client
        (lines, lineCont) = AsyncStream<Data>.makeStream()
    }

    func channelActive(context: ChannelHandlerContext) {
        let ch = context.channel
        let lines = self.lines
        consumer = Task { [client] in
            for await line in lines { await client.receive(line, from: ch) }
            await client.disconnected(ch)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lineCont.yield(Data(unwrapInboundIn(data).readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        lineCont.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

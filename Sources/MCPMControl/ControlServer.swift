import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOExtras
import MCPMCore

public enum ControlServerError: Error, Equatable {
    case socketPermissions(Int32)
}

public typealias ControlHandler = @Sendable (ControlRequest) async throws -> ControlResult

/// Newline-delimited JSON over a Unix domain socket. One handler serves all requests;
/// `broadcast` pushes events to every open connection.
public actor ControlServer {
    /// Longest line the framer will buffer before tearing the connection down.
    static let maximumFrameSize = 1 << 20

    private let socketPath: String
    private let handler: ControlHandler
    /// The process-wide singleton group: it never needs shutting down, so a server that is
    /// dropped without `stop()` leaves no threads behind, and `start()` works again after a stop.
    private let group = MultiThreadedEventLoopGroup.singleton
    private var channel: Channel?
    /// Held under a lock rather than in actor state so that `channelActive`/`channelInactive`
    /// register and unregister synchronously — hopping onto the actor lets a late `unregister`
    /// for a dead channel land after a new one registered, leaking the dead channel.
    private nonisolated let connections = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])

    public init(socketPath: String, handler: @escaping ControlHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { ch in
                // syncOperations rather than `pipeline.addHandlers`: the handlers are not Sendable
                // and this closure already runs on the channel's event loop.
                ch.eventLoop.makeCompletedFuture {
                    try ch.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(LineBasedFrameDecoder(), maximumBufferSize: Self.maximumFrameSize),
                        ConnectionHandler(server: self),
                    ])
                }
            }
        channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        guard chmod(socketPath, 0o600) == 0 else {
            let code = errno
            try? await stop()
            throw ControlServerError.socketPermissions(code)
        }
    }

    public func stop() async throws {
        for c in connections.withLockedValue({ let all = $0; $0.removeAll(); return all }).values {
            try? await c.close().get()
        }
        try? await channel?.close().get()
        channel = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    public func broadcast(_ event: ControlEvent) {
        guard let data = try? JSONEncoder.mcpmWire.encode(event) else { return }
        for c in connections.withLockedValue({ $0 }).values { Self.writeLine(data, to: c) }
    }

    fileprivate nonisolated func register(_ c: Channel) {
        connections.withLockedValue { $0[ObjectIdentifier(c)] = c }
    }

    fileprivate nonisolated func unregister(_ c: Channel) {
        connections.withLockedValue { $0[ObjectIdentifier(c)] = nil }
    }

    fileprivate func handleLine(_ data: Data, on c: Channel) async {
        let response: ControlResponse
        do {
            let req = try JSONDecoder.mcpm.decode(ControlRequest.self, from: data)
            do { response = ControlResponse(id: req.id, result: try await handler(req)) }
            catch { response = ControlResponse(id: req.id, error: String(describing: error)) }
        } catch {
            response = ControlResponse(id: -1, error: "bad request: \(error)")
        }
        if let out = try? JSONEncoder.mcpmWire.encode(response) { Self.writeLine(out, to: c) }
    }

    static func writeLine(_ data: Data, to c: Channel) {
        var buf = c.allocator.buffer(capacity: data.count + 1)
        buf.writeBytes(data)
        buf.writeString("\n")
        c.writeAndFlush(buf, promise: nil)
    }
}

/// Feeds each connection's lines through one stream with a single consumer, so requests from a
/// connection are handled in the order they were sent even though handling is async.
private final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let server: ControlServer
    private let lines: AsyncStream<Data>
    private let lineCont: AsyncStream<Data>.Continuation
    private var consumer: Task<Void, Never>?

    init(server: ControlServer) {
        self.server = server
        (lines, lineCont) = AsyncStream<Data>.makeStream()
    }

    func channelActive(context: ChannelHandlerContext) {
        let ch = context.channel
        server.register(ch)
        let lines = self.lines
        consumer = Task { [server] in
            for await line in lines { await server.handleLine(line, on: ch) }
        }
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.unregister(context.channel)
        lineCont.finish()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lineCont.yield(Data(unwrapInboundIn(data).readableBytesView))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

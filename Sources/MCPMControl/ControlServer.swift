import Foundation
import NIO
import NIOExtras
import MCPMCore

public enum ControlServerError: Error, Equatable { case unsupported(String) }

public typealias ControlHandler = @Sendable (ControlRequest) async throws -> ControlResult

/// Newline-delimited JSON over a Unix domain socket. One handler serves all requests;
/// `broadcast` pushes events to every open connection.
public actor ControlServer {
    private let socketPath: String
    private let handler: ControlHandler
    /// The process-wide singleton group: it never needs shutting down, so a server that is
    /// dropped without `stop()` leaves no threads behind, and `start()` works again after a stop.
    private let group = MultiThreadedEventLoopGroup.singleton
    private var channel: Channel?
    private var connections: [ObjectIdentifier: Channel] = [:]

    public init(socketPath: String, handler: @escaping ControlHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { ch in
                ch.pipeline.addHandlers([
                    ByteToMessageHandler(LineBasedFrameDecoder()),
                    ConnectionHandler(server: self),
                ])
            }
        channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        _ = chmod(socketPath, 0o600)
    }

    public func stop() async throws {
        for c in connections.values { try? await c.close().get() }
        connections.removeAll()
        try? await channel?.close().get()
        channel = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    public func broadcast(_ event: ControlEvent) {
        guard let data = try? JSONEncoder.mcpmWire.encode(event) else { return }
        for c in connections.values { Self.writeLine(data, to: c) }
    }

    fileprivate func register(_ c: Channel) { connections[ObjectIdentifier(c)] = c }
    fileprivate func unregister(_ c: Channel) { connections[ObjectIdentifier(c)] = nil }

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

private final class ConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let server: ControlServer
    init(server: ControlServer) { self.server = server }

    func channelActive(context: ChannelHandlerContext) {
        let ch = context.channel
        Task { await server.register(ch) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let ch = context.channel
        Task { await server.unregister(ch) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        let ch = context.channel
        Task { await server.handleLine(bytes, on: ch) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

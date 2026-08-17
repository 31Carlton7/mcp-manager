import Foundation
import Observation
import MCPMCore
import MCPMControl

/// The app's view of the background service: connection state, the latest pushed status, and
/// the commands the UI can issue.
@MainActor @Observable
final class DaemonClient {
    enum Connection: Equatable { case connecting, connected, disconnected(String) }

    private(set) var connection: Connection = .connecting
    private(set) var status: DaemonStatus?
    private(set) var lastError: String?

    private let appVersion: String
    private let client: ControlClient
    private var connectTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    /// One stream with one consumer, so commands reach the daemon in the order the UI issued
    /// them — a detached task per toggle would let two writes to the same server race.
    private let commands: AsyncStream<ControlCommand>
    private let commandCont: AsyncStream<ControlCommand>.Continuation

    init(socketPath: String = Paths().socket.path, appVersion: String = "0.1.0") {
        self.appVersion = appVersion
        client = ControlClient(socketPath: socketPath)
        (commands, commandCont) = AsyncStream<ControlCommand>.makeStream()
    }

    /// Idempotent: several views call this from `onAppear`.
    func start() {
        guard connectTask == nil else { return }
        connectTask = Task { [weak self] in await self?.connectLoop() }
        commandTask = Task { [weak self] in await self?.drainCommands() }
    }

    private func connectLoop() async {
        while !Task.isCancelled {
            do {
                try await client.connect()
                connection = .connected
                let hello = try await client.send(.hello(.init(appVersion: appVersion)))
                if case .hello(_, let api) = hello, api != controlAPIVersion {
                    connection = .disconnected(
                        "Daemon API v\(api) ≠ app v\(controlAPIVersion). Restart the background service.")
                    await client.close()
                    return
                }
                if case .status(let s) = try await client.send(.subscribe) { status = s }
                // events() is per-connection and finishes when the socket drops → loop ends → reconnect
                for await ev in await client.events() {
                    if case .status(let s) = ev { status = s }
                }
                connection = .disconnected("Lost connection")
            } catch {
                connection = .disconnected(String(describing: error))
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func drainCommands() async {
        for await cmd in commands {
            do {
                _ = try await client.send(cmd)
                lastError = nil
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    // MARK: commands

    func setClient(_ id: String, _ client: ClientID, _ enabled: Bool) {
        run(.setClient(.init(id: id, client: client, enabled: enabled)))
    }
    func setAll(_ id: String, _ enabled: Bool) { run(.setAll(.init(id: id, enabled: enabled))) }
    func remove(_ id: String) { run(.removeServer(.init(id: id))) }
    func add(_ p: AddServerParams) { run(.addServer(p)) }
    func reimport(_ c: ClientID) { run(.reimport(.init(client: c))) }

    private func run(_ cmd: ControlCommand) { commandCont.yield(cmd) }
}

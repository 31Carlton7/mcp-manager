import Foundation
import Observation
import MCPMCore
import MCPMControl

/// The app's view of the background service: connection state, the latest pushed status, and
/// the commands the UI can issue.
@MainActor @Observable
final class DaemonClient {
    enum Connection: Equatable { case connecting, connected, disconnected(String) }
    /// What the menu bar icon and the popover dot report, in one place so they can't disagree.
    enum Health: Equatable { case ok, warning, error }

    private(set) var connection: Connection = .connecting
    private(set) var status: DaemonStatus?
    private(set) var lastError: String?
    /// Toggles the user has flipped but the daemon hasn't confirmed yet, so a checkbox moves
    /// under the pointer instead of waiting a round trip. Cleared by the status that follows,
    /// or reverted if the command fails.
    private(set) var pendingToggles: [String: [ClientID: Bool]] = [:]

    var isConnected: Bool { if case .connected = connection { true } else { false } }
    var disconnectReason: String? { if case .disconnected(let why) = connection { why } else { nil } }

    var health: Health {
        guard isConnected, let s = status else { return .error }
        if s.clients.contains(where: { $0.installed && !$0.healthy }) { return .error }
        if s.servers.contains(where: { $0.state == "needsAuth" }) { return .warning }
        return .ok
    }

    /// The state to draw for one checkbox: what the user asked for, else what the daemon reports.
    func isEnabled(_ server: Server, for client: ClientID) -> Bool {
        pendingToggles[server.id]?[client] ?? server.isEnabled(for: client)
    }

    /// Whether any installed client has this server on — the popover's single switch.
    func isEnabledAnywhere(_ server: Server, installed: [ClientID]) -> Bool {
        installed.contains { isEnabled(server, for: $0) }
    }

    // MARK: derived

    /// The only clients the UI ever shows: the ones actually on this Mac.
    var installedClients: [ClientStatus] { status?.clients.filter(\.installed) ?? [] }

    /// Every server, ordered for display. Deliberately unfiltered: a client filter names the client
    /// a row's switch writes to, and a server that is off everywhere is exactly what the user
    /// opened the popover to turn on. The main window filters this list itself.
    var servers: [ServerStatus] {
        (status?.servers ?? []).sorted { $0.server.name.localizedStandardCompare($1.server.name) == .orderedAscending }
    }

    /// Servers switched on in `filter`, or in any installed client when the filter is off.
    /// Reads through the optimistic overlay so the number moves with the switch the user just flipped.
    func activeCount(filter: ClientID?) -> Int {
        let servers = status?.servers ?? []
        guard let filter else {
            let installed = installedClients.map(\.id)
            return servers.count { isEnabledAnywhere($0.server, installed: installed) }
        }
        return servers.count { isEnabled($0.server, for: filter) }
    }

    /// Everything asking for a human: servers waiting on a sign-in, plus clients the daemon can't
    /// write to.
    var attentionCount: Int {
        guard let s = status else { return 0 }
        return s.servers.count { $0.state == "needsAuth" } + s.clients.count { $0.installed && !$0.healthy }
    }

    /// The most recent sync across installed clients — the footer's "Synced HH:mm".
    var lastSynced: Date? { installedClients.compactMap(\.lastSync).max() }

    private struct Queued {
        let command: ControlCommand
        /// Overlay entries this command owns, reverted if it fails.
        let keys: [(server: String, client: ClientID)]
    }

    private let appVersion: String
    private let client: ControlClient
    private var connectTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var inFlight = 0
    /// One stream with one consumer, so commands reach the daemon in the order the UI issued
    /// them — a detached task per toggle would let two writes to the same server race.
    private let commands: AsyncStream<Queued>
    private let commandCont: AsyncStream<Queued>.Continuation

    init(socketPath: String = Paths().socket.path, appVersion: String? = nil) {
        self.appVersion = appVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.1.0"
        client = ControlClient(socketPath: socketPath)
        (commands, commandCont) = AsyncStream<Queued>.makeStream()
    }

    /// Idempotent: the menu bar label and both views call this from `onAppear`.
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
                    // Not fatal: the user can restart the background service, so keep trying —
                    // slower, since only a new daemon can change the answer.
                    connection = .disconnected(
                        "Daemon API v\(api) ≠ app v\(controlAPIVersion). Restart the background service.")
                    await client.close()
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                if case .status(let s) = try await client.send(.subscribe) { apply(s) }
                // events() is per-connection and finishes when the socket drops → loop ends → reconnect
                for await ev in await client.events() {
                    if case .status(let s) = ev { apply(s) }
                }
                connection = .disconnected("Lost connection")
            } catch {
                connection = .disconnected(String(describing: error))
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// A status only speaks for commands the daemon has already answered; while others are in
    /// flight the overlay stays, or the checkbox would snap back and forth.
    private func apply(_ s: DaemonStatus) {
        status = s
        if inFlight == 0 { pendingToggles.removeAll() }
    }

    private func drainCommands() async {
        for await q in commands {
            do {
                _ = try await client.send(q.command)
                lastError = nil
            } catch {
                lastError = String(describing: error)
                revert(q.keys)
            }
            inFlight -= 1
        }
    }

    private func revert(_ keys: [(server: String, client: ClientID)]) {
        for k in keys {
            pendingToggles[k.server]?[k.client] = nil
            if pendingToggles[k.server]?.isEmpty == true { pendingToggles[k.server] = nil }
        }
    }

    // MARK: commands

    func setClient(_ id: String, _ client: ClientID, _ enabled: Bool) {
        pendingToggles[id, default: [:]][client] = enabled
        run(.setClient(.init(id: id, client: client, enabled: enabled)), keys: [(id, client)])
    }

    func setAll(_ id: String, _ enabled: Bool) {
        let installed = status?.clients.filter(\.installed).map(\.id) ?? []
        for c in installed { pendingToggles[id, default: [:]][c] = enabled }
        run(.setAll(.init(id: id, enabled: enabled)), keys: installed.map { (id, $0) })
    }

    func remove(_ id: String) { run(.removeServer(.init(id: id))) }
    func add(_ p: AddServerParams) { run(.addServer(p)) }
    /// Only the fields set on `p` change; everything left nil keeps its stored value.
    func update(_ p: UpdateServerParams) { run(.updateServer(p)) }
    func reimport(_ c: ClientID) { run(.reimport(.init(client: c))) }

    private func run(_ cmd: ControlCommand, keys: [(server: String, client: ClientID)] = []) {
        inFlight += 1
        commandCont.yield(Queued(command: cmd, keys: keys))
    }
}

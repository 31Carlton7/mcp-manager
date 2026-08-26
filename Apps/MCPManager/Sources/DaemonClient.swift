import AppKit
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
    /// The last test connection result per server, kept until the next test replaces it. Not
    /// persisted: a result describes the server as it was a moment ago, not as it is.
    private(set) var testResults: [String: TestResult] = [:]
    /// Servers with a test in flight — the button's spinner, and the guard against a second one.
    private(set) var testing: Set<String> = []
    /// The daemon's saved settings, fetched on demand. Deliberately not part of the pushed status:
    /// that arrives on every sync, and these change only when someone changes them.
    private(set) var settings: Settings?
    /// Why the last `settings.set` was refused, so the field can say so instead of silently
    /// snapping back. Cleared when the next one is attempted.
    private(set) var settingsError: String?
    private(set) var savingSettings = false

    var isConnected: Bool { if case .connected = connection { true } else { false } }
    var disconnectReason: String? { if case .disconnected(let why) = connection { why } else { nil } }

    /// The port the daemon's auth gateway bound, or nil when it never started — in which case
    /// nothing that needs a credential can be reached and the UI says so instead of offering a
    /// sign-in that would fail.
    var gatewayPort: Int? { status?.gatewayPort }

    /// A saved setting the running daemon hasn't picked up — the gateway port, which only moves on
    /// a restart because every client config already points at the port it is bound to.
    var settingsPendingRestart: Bool { status?.settingsPendingRestart ?? false }

    /// Whether the first import has been approved. Optimistic while we have no status: an app that
    /// opened setup every time it started before the daemon answered would flash it at everyone.
    var importConfirmed: Bool { status?.importConfirmed ?? true }
    /// The daemon is reading and planning but writing nothing until setup is finished.
    var needsSetup: Bool { status != nil && !importConfirmed }

    var health: Health {
        guard isConnected, let s = status else { return .error }
        if s.clients.contains(where: { $0.installed && !$0.healthy }) { return .error }
        if s.servers.contains(where: { AuthStatus($0.state).needsAttention }) { return .warning }
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

    /// Everything asking for a human: servers waiting on a sign-in or stuck on an auth error, plus
    /// clients the daemon can't write to.
    var attentionCount: Int {
        guard let s = status else { return 0 }
        return s.servers.count { AuthStatus($0.state).needsAttention }
            + s.clients.count { $0.installed && !$0.healthy }
    }

    /// The most recent sync across installed clients — the footer's "Synced HH:mm".
    var lastSynced: Date? { installedClients.compactMap(\.lastSync).max() }

    private struct Queued {
        let command: ControlCommand
        /// Overlay entries this command owns, reverted if it fails.
        let keys: [(server: String, client: ClientID)]
        /// Set for the commands whose answer the UI needs — a sign-in URL, a test result. Left nil
        /// by the fire-and-forget ones, which are the majority.
        let reply: CheckedContinuation<ControlResult, Error>?
    }

    private let appVersion: String
    private let client: ControlClient
    /// A second connection on the same socket, for the calls that can take seconds — a sign-in that
    /// waits on the authorization server, a test that dials the server itself. On the ordered
    /// connection those would hold every toggle behind them.
    private let aux: ControlClient
    /// The in-flight or settled connect for the aux link, shared by everyone who needs it, and nil
    /// whenever the link is down.
    private var auxConnect: Task<Void, Error>?
    /// Which aux connection is current. A drain or a failed send only takes the link down if it is
    /// still talking about the connection we actually have.
    private var auxGeneration = 0
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
            ?? MCPMVersion.current
        client = ControlClient(socketPath: socketPath)
        aux = ControlClient(socketPath: socketPath)
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
                let result = try await client.send(q.command)
                lastError = nil
                q.reply?.resume(returning: result)
            } catch {
                lastError = String(describing: error)
                revert(q.keys)
                q.reply?.resume(throwing: error)
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

    /// Adds and waits, answering with the new server's id — which the daemon mints and only
    /// reports through the status that follows, so it is found again as the server that wasn't
    /// there before. The Add sheet needs it to offer the sign-in a fresh OAuth server waits on.
    ///
    /// On the aux link, because the daemon may inspect the URL on its way in and that dials the
    /// internet: on the ordered connection a slow endpoint would hold every toggle behind it for
    /// as long as the probe takes. `auxSend`'s status barrier still puts this after every mutation
    /// issued before it.
    @discardableResult
    func addAwaiting(_ p: AddServerParams) async throws -> String? {
        let existing = Set((status?.servers ?? []).map(\.id))
        _ = try await auxSend(.addServer(p), retryOnDroppedLink: false)
        // The add syncs, so a status is already on its way; asking closes the gap in which the
        // sheet would look for a server the app has not been told about yet.
        if case .status(let s) = try await send(.status) { apply(s) }
        // By id and name both: nothing stops two servers sharing a name, and the one that matters
        // is the one this call brought into being.
        return status?.servers.first { !existing.contains($0.id) && $0.server.name == p.name }?.id
    }

    /// What a URL is, before anyone commits to adding it. On the aux link: it dials the internet,
    /// and the user is still typing into a form whose toggles must stay live.
    func inspect(_ url: String) async throws -> URLInspection {
        guard case .inspection(let i) = try await auxSend(.inspectURL(.init(url: url))) else {
            throw ControlClientError.remote("The background service did not answer with an inspection")
        }
        return i
    }

    /// Curated list plus the registry. Also slow — it may go to the network — so also on the aux
    /// link, where a search per keystroke can't hold up a toggle.
    func searchCatalog(query: String, limit: Int = 30) async throws -> [CatalogEntry] {
        guard case .catalog(let entries) = try await auxSend(.catalogSearch(.init(query: query, limit: limit))) else {
            throw ControlClientError.remote("The background service did not answer with a catalog")
        }
        return entries
    }

    /// Only the fields set on `p` change; everything left nil keeps its stored value.
    func update(_ p: UpdateServerParams) { run(.updateServer(p)) }
    func reimport(_ c: ClientID) { run(.reimport(.init(client: c))) }

    func updateAuth(_ id: String, _ auth: AuthKind) { update(UpdateServerParams(id: id, auth: auth)) }
    func updateHeaders(_ id: String, _ headers: [String: String]) {
        update(UpdateServerParams(id: id, headers: headers))
    }

    // MARK: auth

    /// Sends the user to the authorization server. The daemon builds the URL but deliberately does
    /// not open it — the browser has to belong to the logged-in GUI session, which is us.
    func startAuth(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard case .authorizeURL(let raw) = try await auxSend(.authStart(.init(id: id))) else { return }
                guard let url = URL(string: raw) else {
                    lastError = "The background service returned an authorization URL we can't open"
                    return
                }
                NSWorkspace.shared.open(url)
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    /// Drops the token but keeps the client registration, so signing back in skips re-registering.
    func signOut(_ id: String) { run(.authSignOut(.init(id: id))) }
    /// Drops everything, registration included — the escape hatch when a server's registration has
    /// gone stale on the other end.
    func forget(_ id: String) { run(.authForget(.init(id: id))) }
    func setHeader(_ id: String, name: String, value: String) {
        run(.authSetHeader(.init(id: id, name: name, value: value)))
    }

    /// Runs an MCP `initialize` against the server the way its clients reach it. Concurrent tests of
    /// the same server are dropped rather than queued: the second would only re-answer the first.
    func test(_ id: String) async {
        guard !testing.contains(id) else { return }
        testing.insert(id)
        defer { testing.remove(id) }
        do {
            if case .testResult(let r) = try await auxSend(.testServer(.init(id: id))) {
                testResults[id] = r
            }
        } catch {
            testResults[id] = TestResult(ok: false, error: String(describing: error), durationMs: 0)
        }
    }

    // MARK: onboarding

    /// What the first sync would do, without doing any of it. Throws with the daemon's own words,
    /// which the sheet shows rather than an Import button that would act on nothing.
    func importPreview() async throws -> SyncPreview {
        guard case .syncPreview(let p) = try await send(.syncPreview) else {
            throw ControlClientError.remote("The background service did not return a preview")
        }
        return p
    }

    /// Approves the first import: the daemon records it, leaves read-only mode and syncs. The
    /// status that follows carries `importConfirmed`, so the caller has nothing to update itself.
    func confirmImport() async -> Bool {
        do {
            _ = try await send(.confirmImport)
            // The import writes files, so a status push is coming — but asking for one closes the
            // window in which the sheet's last step still reads as unconfirmed.
            if case .status(let s) = try await send(.status) { apply(s) }
            return true
        } catch {
            lastError = reason(error)
            return false
        }
    }

    // MARK: settings

    /// Idempotent, and safe to call from `onAppear`: a failure leaves `settings` nil, which the
    /// view reads as "not loaded yet" and shows a disabled field for.
    func loadSettings() async {
        guard case .settings(let s)? = try? await send(.getSettings) else { return }
        settings = s
    }

    /// Saves the fields it is given and leaves the rest alone. Returns false when the daemon
    /// refused, with `settingsError` carrying its reason.
    @discardableResult
    func saveSettings(gatewayPort: Int? = nil, backupRetention: Int? = nil) async -> Bool {
        settingsError = nil
        savingSettings = true
        defer { savingSettings = false }
        do {
            let cmd = ControlCommand.setSettings(.init(gatewayPort: gatewayPort, backupRetention: backupRetention))
            if case .settings(let s) = try await send(cmd) { settings = s }
            // A settings change moves no file, so nothing on the daemon's side would push a new
            // status — and `settingsPendingRestart` lives on the status. Ask for one.
            if case .status(let s) = try await send(.status) { apply(s) }
            return true
        } catch {
            settingsError = reason(error)
            return false
        }
    }

    /// The daemon's own words for a refusal; anything else is a transport failure and gets the
    /// generic description, since there is no sentence in it worth showing on its own.
    private func reason(_ error: Error) -> String {
        if case ControlClientError.remote(let why) = error { return why }
        return String(describing: error)
    }

    // MARK: demo capture only

    /// Pulls a status rather than waiting for one. The capture driver changes the credential store
    /// from outside the daemon, which is not a change anything on that side would push.
    func _demoRefreshStatus() async {
        guard DemoCapture.isActive, case .status(let s)? = try? await send(.status) else { return }
        apply(s)
    }

    /// A test result without dialling anything. `testResults` is otherwise only written by `test`,
    /// and this is the one caller that isn't a real probe.
    func _demoInjectTestResult(_ id: String, _ result: TestResult) {
        guard DemoCapture.isActive else { return }
        testResults[id] = result
    }

    private func run(_ cmd: ControlCommand, keys: [(server: String, client: ClientID)] = []) {
        inFlight += 1
        commandCont.yield(Queued(command: cmd, keys: keys, reply: nil))
    }

    /// The same queue as `run`, so a command that needs its answer still can't overtake the writes
    /// issued before it — a sign-in must land after the `auth` switch that made it possible.
    private func send(_ cmd: ControlCommand) async throws -> ControlResult {
        inFlight += 1
        return try await withCheckedThrowingContinuation { cont in
            commandCont.yield(Queued(command: cmd, keys: [], reply: cont))
        }
    }

    /// A slow call, off the ordered connection. The cheap `status` first is the barrier: it is the
    /// last thing in the ordered queue, so when it answers, every mutation issued before this call
    /// — the `auth` switch a sign-in depends on — has already been applied.
    ///
    /// `retryOnDroppedLink` is for the commands that can be asked twice. A command that changes
    /// the library cannot: the link dying after the daemon acted on it and before the answer got
    /// back is indistinguishable from it never arriving, and asking again would add the server
    /// twice.
    private func auxSend(_ cmd: ControlCommand, retryOnDroppedLink: Bool = true) async throws -> ControlResult {
        _ = try await send(.status)
        let generation = auxGeneration
        do {
            return try await auxRequest(cmd)
        } catch {
            // The daemon answered and said no; asking again would only hear it twice.
            if case ControlClientError.remote = error { throw error }
            // Otherwise the link died in the gap between the send leaving and the drain noticing.
            // Guarded by the generation, so this can't drop a connection someone else just made.
            auxDisconnected(generation)
            guard retryOnDroppedLink else { throw error }
            return try await auxRequest(cmd)
        }
    }

    private func auxRequest(_ cmd: ControlCommand) async throws -> ControlResult {
        try await auxReady()
        return try await aux.send(cmd)
    }

    /// Connects the aux link if it isn't up, with concurrent callers sharing the one attempt:
    /// `ControlClient.connect()` closes whatever is open before dialling, so two of them racing
    /// would tear each other's connection down and neither would settle.
    private func auxReady() async throws {
        let connect = auxConnect ?? startAuxConnect()
        do {
            try await connect.value
        } catch {
            if auxConnect == connect { auxConnect = nil }
            throw error
        }
    }

    private func startAuxConnect() -> Task<Void, Error> {
        auxGeneration += 1
        let generation = auxGeneration
        let connect = Task { [aux] in
            try await aux.connect()
            // Nobody here wants this connection's events, but an unread `AsyncStream` keeps every
            // status the daemon ever pushes — so they are read and dropped. The stream ends with
            // the connection, which is also how this side learns the link is gone.
            Task { [weak self] in
                for await _ in await aux.events() {}
                self?.auxDisconnected(generation)
            }
        }
        auxConnect = connect
        return connect
    }

    /// Marks the aux link down, unless it has already been replaced by a newer one.
    private func auxDisconnected(_ generation: Int) {
        guard generation == auxGeneration else { return }
        auxConnect = nil
    }
}
